/// Push relay and grant lifecycle. Inert unless the build has Firebase
/// options compiled in (BuildConfig.pushCapable) and the user has entered a
/// relay URL. The relay URL may carry a credential as URL userinfo
/// (https://credential@relay.example); the app sends it to that relay as a
/// bearer token and never interprets it. Who may use a relay is the relay
/// operator's business: the app only keeps the grant fresh.
library;

import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'client.dart';
import 'config.dart';
import 'models.dart';
import 'notifications.dart';
import 'push_crypto.dart';
import 'store.dart';

enum RelayState { none, active, inactive, error }

/// A parsed relay URL: the base the app talks to and the optional credential
/// that travelled as userinfo.
class RelayTarget {
  const RelayTarget(this.base, this.credential);
  final Uri base;
  final String credential;
  String get host => base.port == 443 || !base.hasPort ? base.host : '${base.host}:${base.port}';

  /// Accepts https://[credential@]host[:port][/path]. Query strings and
  /// fragments are refused so a pasted link cannot smuggle parameters.
  static RelayTarget? parse(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final u = Uri.tryParse(t.contains('://') ? t : 'https://$t');
    if (u == null || u.scheme != 'https' || u.host.isEmpty || u.hasQuery || u.hasFragment) return null;
    final cred = Uri.decodeComponent(u.userInfo);
    if (cred.length > 128 || cred.contains(RegExp(r'\s'))) return null;
    final base = u.replace(userInfo: '', path: u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path);
    return RelayTarget(base, cred);
  }
}

class PushService extends ChangeNotifier {
  PushService(this.store);
  final AppStore store;

  bool get capable => BuildConfig.pushCapable;
  bool enabled = false; // user toggle
  String? relayUrl;
  RelayState relayState = RelayState.none;
  String? grant;
  DateTime? grantExpires;
  DateTime? lastValidated;
  String? lastError;
  String? _fcmToken;
  late final String deviceId;

  static const _secure = FlutterSecureStorage();

  bool get hasRelay => relayUrl != null;
  RelayTarget? get target => relayUrl == null ? null : RelayTarget.parse(relayUrl!);
  String get relayHost => target?.host ?? '';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    deviceId = prefs.getString('push.device_id') ?? const Uuid().v4().replaceAll('-', '');
    await prefs.setString('push.device_id', deviceId);
    enabled = prefs.getBool('push.enabled') ?? true;
    grant = prefs.getString('push.grant');
    final exp = prefs.getString('push.grant_exp');
    grantExpires = exp == null ? null : DateTime.tryParse(exp);
    lastValidated = DateTime.tryParse(prefs.getString('push.validated') ?? '');
    try {
      relayUrl = await _secure.read(key: 'relay.url');
    } catch (_) {}
    if (relayUrl != null) relayState = grant != null ? RelayState.active : RelayState.inactive;
    if (!capable) {
      notifyListeners();
      return;
    }
    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: BuildConfig.platformApiKey,
          appId: BuildConfig.platformAppId,
          messagingSenderId: BuildConfig.fbSenderId,
          projectId: BuildConfig.fbProjectId,
          iosBundleId: Platform.isIOS ? BuildConfig.fbIosBundleId : null,
        ),
      );
      FirebaseMessaging.onMessage.listen(_onMessage);
      FirebaseMessaging.onBackgroundMessage(_backgroundHandler);
      if (enabled && relayUrl != null) await refreshGrant();
    } catch (e) {
      lastError = '$e';
    }
    notifyListeners();
  }

  /// Validates and stores a relay URL, then fetches a grant from it.
  Future<bool> setRelay(String raw) async {
    final t = RelayTarget.parse(raw);
    if (t == null) {
      lastError = 'Enter an https:// relay URL, optionally with a credential before the @.';
      notifyListeners();
      return false;
    }
    relayUrl = t.base.replace(userInfo: t.credential.isEmpty ? '' : Uri.encodeComponent(t.credential)).toString();
    try {
      await _secure.write(key: 'relay.url', value: relayUrl!);
    } catch (_) {}
    enabled = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('push.enabled', true);
    await Notifier.instance.requestPermission();
    await refreshGrant(force: true);
    return relayState == RelayState.active;
  }

  /// Forgets the relay and tells every machine to stop pushing.
  Future<void> clearRelay() async {
    relayUrl = null;
    relayState = RelayState.none;
    grant = null;
    grantExpires = null;
    lastError = null;
    try {
      await _secure.delete(key: 'relay.url');
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('push.grant');
    await prefs.remove('push.grant_exp');
    _unregisterAll();
    await _dropToken();
    notifyListeners();
  }

  Iterable<DaemonClient> get _pushClients => store.clients.values.where((c) => !c.isDemo);

  void _unregisterAll() {
    for (final c in _pushClients) {
      c.request('push.unregister').catchError((_) => <String, dynamic>{});
    }
  }

  /// Follows a machine's mute toggle: drop or restore its grant.
  void onMuteChanged(DaemonInfo d, bool muted) {
    final c = store.clients[d.id];
    if (c == null || c.isDemo || grant == null || !enabled) return;
    if (muted) {
      c.request('push.unregister').catchError((_) => <String, dynamic>{});
    } else {
      c.request('push.register', {'grant': grant, 'expires_at': grantExpires!.toUtc().toIso8601String()}).catchError((_) => <String, dynamic>{});
    }
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('push.enabled', v);
    if (v) {
      await Notifier.instance.requestPermission();
      await refreshGrant();
    } else {
      _unregisterAll();
    }
    notifyListeners();
  }

  /// Obtains (or renews) a grant from the relay and registers it with every
  /// unmuted paired machine. Hits the relay when the grant is missing, within
  /// 3 days of expiry, or when forced; otherwise re-registers the cached one.
  Future<void> refreshGrant({bool force = false}) async {
    final t = target;
    if (!capable || !enabled || t == null) return;
    try {
      final token = await _obtainToken();
      final needs = force || grant == null || grantExpires == null || grantExpires!.difference(DateTime.now()).inDays < 3;
      if (needs) {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
        final req = await client.postUrl(t.base.replace(path: '${t.base.path}/v1/grant'));
        req.headers.contentType = ContentType.json;
        if (t.credential.isNotEmpty) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${t.credential}');
        req.write(jsonEncode({'device_id': deviceId, 'platform': Platform.isIOS ? 'ios' : 'android', 'push_token': token}));
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        client.close();
        final prefs = await SharedPreferences.getInstance();
        if (resp.statusCode == 402 || resp.statusCode == 400 || resp.statusCode == 403) {
          relayState = RelayState.inactive;
          grant = null;
          grantExpires = null;
          await prefs.remove('push.grant');
          await prefs.remove('push.grant_exp');
          lastError = 'The relay refused this URL. Check it with whoever runs the relay.';
          _unregisterAll();
          notifyListeners();
          return;
        }
        if (resp.statusCode != 200) throw Exception('relay ${resp.statusCode}');
        final j = jsonDecode(body) as Map<String, dynamic>;
        grant = j['grant'] as String;
        grantExpires = DateTime.parse(j['expires_at'] as String);
        lastValidated = DateTime.now();
        await prefs.setString('push.grant', grant!);
        await prefs.setString('push.grant_exp', grantExpires!.toIso8601String());
        await prefs.setString('push.validated', lastValidated!.toIso8601String());
      }
      relayState = RelayState.active;
      for (final c in _pushClients) {
        if (c.info.muted) continue;
        c.request('push.register', {'grant': grant, 'expires_at': grantExpires!.toUtc().toIso8601String()}).catchError((_) => <String, dynamic>{});
      }
      lastError = null;
    } on _TokenUnavailable catch (e) {
      relayState = grant != null ? RelayState.active : RelayState.error;
      lastError = e.message;
    } catch (e) {
      relayState = grant != null ? RelayState.active : RelayState.error;
      lastError = "Couldn't reach the relay: $e";
    }
    notifyListeners();
  }

  /// Returns the FCM registration token, minting one on first use.
  ///
  /// The builds ship with FCM auto-init off (Info.plist / manifest) so no push
  /// token exists until the user turns push on. Enabling auto-init here is the
  /// opt-in: on iOS it is also what makes the plugin register with APNs, and
  /// FCM cannot mint a token until that registration completes, so the APNs
  /// token is awaited first.
  Future<String> _obtainToken() async {
    final cached = _fcmToken;
    if (cached != null) return cached;
    final fm = FirebaseMessaging.instance;
    try {
      if (!fm.isAutoInitEnabled) await fm.setAutoInitEnabled(true);
      if (Platform.isIOS) {
        String? apns;
        for (var i = 0; i < 40 && apns == null; i++) {
          apns = await fm.getAPNSToken();
          if (apns == null) await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        if (apns == null) {
          throw const _TokenUnavailable("Apple has not issued this phone a push token yet. Check the phone is online, then save the relay URL again.");
        }
      }
      final t = await fm.getToken();
      if (t == null) throw const _TokenUnavailable("Couldn't get a push token for this phone. Try again in a moment.");
      _fcmToken = t;
      return t;
    } on _TokenUnavailable {
      rethrow;
    } catch (e) {
      throw _TokenUnavailable("Couldn't get a push token for this phone: $e");
    }
  }

  /// Reverses the opt-in from [_obtainToken]: no token is kept for a phone
  /// that is not using a relay.
  Future<void> _dropToken() async {
    _fcmToken = null;
    if (!capable) return;
    try {
      await FirebaseMessaging.instance.setAutoInitEnabled(false);
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  Future<void> _onMessage(RemoteMessage m) async {
    await _handle(m.data);
  }

  static Future<void> _handle(Map<String, dynamic> data) async {
    final ct = data['ct'] as String?;
    if (ct == null) return;
    // Try every paired daemon's key; the first that decrypts wins.
    final keys = await _loadKeys();
    for (final entry in keys) {
      final parts = entry.split(':');
      if (parts.length != 2) continue;
      final key = base64Url.decode(parts[1]);
      final n = await decryptNotice(key, ct);
      if (n == null) continue;
      final kind = n['k'] as String? ?? 'done';
      final title = n['t'] as String? ?? 'Session';
      final daemon = n['d'] as String? ?? '';
      final body = switch (kind) {
        'permission' => 'needs a permission approval',
        'input' => 'is waiting for your input',
        'error' => 'hit an error',
        _ => 'finished and is waiting for you',
      };
      await Notifier.instance.init();
      await Notifier.instance.show(id: '${n['s']}', title: '$title${daemon.isNotEmpty ? ' · $daemon' : ''}', body: body, sessionKey: n['s'] as String?, urgent: kind == 'permission' || kind == 'input');
      return;
    }
  }
}

@pragma('vm:entry-point')
Future<void> _backgroundHandler(RemoteMessage m) async {
  await PushService._handle(m.data);
}

/// The platform could not provide a push token; the message is user-facing.
class _TokenUnavailable implements Exception {
  const _TokenUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

const _keysKey = 'push.keys.v1';

Future<List<String>> _loadKeys() async {
  try {
    final raw = await PushService._secure.read(key: _keysKey);
    if (raw == null) return const [];
    return (jsonDecode(raw) as List).cast<String>();
  } catch (_) {
    return const [];
  }
}

/// Persists a daemon's derived push key (keystore) so the background
/// message handler can decrypt notices.
Future<void> rememberPushKey(String daemonId, List<int> key) async {
  final list = (await _loadKeys()).where((e) => !e.startsWith('$daemonId:')).toList();
  list.add('$daemonId:${base64Url.encode(key)}');
  try {
    await PushService._secure.write(key: _keysKey, value: jsonEncode(list));
  } catch (_) {}
}

Future<void> forgetPushKey(String daemonId) async {
  final list = (await _loadKeys()).where((e) => !e.startsWith('$daemonId:')).toList();
  try {
    await PushService._secure.write(key: _keysKey, value: jsonEncode(list));
  } catch (_) {}
}
