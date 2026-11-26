/// Persisted daemon list (tokens in the platform keystore) and live clients.
library;

import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'client.dart';
import 'config.dart';
import 'demo/demo_client.dart';
import 'demo/fixture.dart';
import 'models.dart';
import 'notifications.dart';
import 'push.dart';

class AppStore extends ChangeNotifier {
  AppStore();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  static const _key = 'daemons.v1';

  final List<DaemonInfo> daemons = [];
  final Map<String, DaemonClient> clients = {};
  bool loaded = false;
  String? lastUsedDaemonId;
  /// Called when a machine's mute flag changes so push grants can follow.
  void Function(DaemonInfo d, bool muted)? onMuteChanged;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _wake;

  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw != null) {
        for (final j in (jsonDecode(raw) as List)) {
          daemons.add(DaemonInfo.fromJson(j as Map<String, dynamic>));
        }
      }
    } catch (_) {
      // Keychain unavailable (fresh install, locked device): start empty.
    }
    try {
      lastUsedDaemonId = (await SharedPreferences.getInstance()).getString('daemons.last_used');
    } catch (_) {}
    loaded = true;
    for (final d in daemons) {
      _client(d).connect();
    }
    if (BuildConfig.demo && !hasDemo) {
      for (final d in demoDaemonInfos()) {
        await add(d);
      }
    }
    notifyListeners();
    _watchConnectivity();
  }

  void _watchConnectivity() {
    try {
      _connectivity = Connectivity().onConnectivityChanged.listen((_) => wake(), onError: (Object _) {}, cancelOnError: true);
    } catch (_) {
      // No connectivity plugin on this platform: resume still triggers wake().
    }
  }

  /// How long a connected machine may stay silent before a wake dials it
  /// again: a socket that died while the phone slept looks open until then.
  static const staleAfter = Duration(seconds: 30);

  /// The network changed or the app came back to the foreground: retry every
  /// machine that is not online, and redial the ones that look online but
  /// have been silent too long. Debounced so a burst of events becomes one
  /// attempt. Machines with auto-connect off are left alone.
  void wake() {
    if (!loaded) return;
    _wake?.cancel();
    _wake = Timer(const Duration(milliseconds: 500), () {
      for (final d in daemons) {
        final c = _client(d);
        if (c.isDemo || !d.autoConnect) continue;
        if (!c.online) {
          c.connect(manual: true);
          continue;
        }
        final last = c.lastFrameAt;
        if (last != null && DateTime.now().difference(last) > staleAfter) c.reconnect();
      }
    });
  }

  @override
  void dispose() {
    _wake?.cancel();
    _connectivity?.cancel();
    super.dispose();
  }

  bool get hasDemo => daemons.any((d) => d.id == demoDaemonId);

  /// Adds the built-in demo machine (sample sessions, no network) so the app
  /// can be explored without a daemon. It persists like any machine and can be
  /// forgotten from the Machines screen.
  Future<void> addDemo() async {
    for (final d in demoDaemonInfos()) {
      await add(d);
    }
    try {
      await Notifier.instance.requestPermission();
    } catch (_) {}
  }

  /// The machine new sessions default to: last used if online, else the only
  /// online machine, else the first paired one.
  DaemonInfo? get defaultDaemon {
    if (daemons.isEmpty) return null;
    final last = daemons.where((d) => d.id == lastUsedDaemonId).firstOrNull;
    if (last != null && clients[last.id]?.online == true) return last;
    final online = daemons.where((d) => clients[d.id]?.online == true).toList();
    if (online.length == 1) return online.first;
    return last ?? daemons.first;
  }

  Future<void> markUsed(DaemonInfo d) async {
    lastUsedDaemonId = d.id;
    try {
      await (await SharedPreferences.getInstance()).setString('daemons.last_used', d.id);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setAlias(DaemonInfo d, String? alias) async {
    d.alias = (alias == null || alias.trim().isEmpty) ? null : alias.trim();
    await _save();
    notifyListeners();
  }

  Future<void> setMuted(DaemonInfo d, bool muted) async {
    d.muted = muted;
    await _save();
    onMuteChanged?.call(d, muted);
    notifyListeners();
  }

  Future<void> setAutoConnect(DaemonInfo d, bool on) async {
    d.autoConnect = on;
    await _save();
    if (on) _client(d).connect();
    notifyListeners();
  }

  void connectNow(DaemonInfo d) {
    final c = _client(d);
    c.probeHosts();
    c.connect(manual: true);
  }

  /// Makes [host] the address tried first and dials through it now.
  Future<void> preferHost(DaemonInfo d, String host) async {
    if (!d.hosts.contains(host)) return;
    final c = _client(d);
    if (c.online && d.lastHost == host) return;
    d.lastHost = host;
    await _save();
    notifyListeners();
    await c.reconnect();
  }

  /// Marks an address as never to be dialled or probed, or lifts that. A
  /// connection that currently runs through it is redialled elsewhere.
  Future<void> ignoreHost(DaemonInfo d, String host, bool ignore) async {
    if (!d.hosts.contains(host)) return;
    final c = _client(d);
    if (ignore) {
      if (!d.ignoredHosts.contains(host)) d.ignoredHosts.add(host);
      c.hostStatus.remove(host);
    } else {
      d.ignoredHosts.remove(host);
    }
    await _save();
    notifyListeners();
    if (ignore && c.online && d.lastHost == host) {
      d.lastHost = null;
      await _save();
      await c.reconnect();
    } else if (!ignore && c.online) {
      unawaited(c.probeHosts());
    }
  }

  /// Checks every address of every paired machine (Machines screen).
  void probeAll() {
    for (final d in daemons) {
      _client(d).probeHosts();
    }
  }

  int get onlineCount => clients.values.where((c) => c.online).length;

  Future<void> _save() async {
    try {
      await _storage.write(key: _key, value: jsonEncode(daemons.map((d) => d.toJson()).toList()));
    } catch (_) {}
  }

  DaemonClient _client(DaemonInfo d) {
    return clients.putIfAbsent(d.id, () {
      final c = isDemoDaemonId(d.id) ? DemoDaemonClient(d) : DaemonClient(d);
      // The client mutates the same DaemonInfo; persist when the preferred
      // address or the address list changes.
      var savedHost = d.lastHost;
      var savedHosts = List.of(d.hosts);
      c.addListener(() {
        if (d.lastHost != savedHost || !listEquals(d.hosts, savedHosts)) {
          savedHost = d.lastHost;
          savedHosts = List.of(d.hosts);
          _save();
        }
        notifyListeners();
      });
      return c;
    });
  }

  DaemonClient clientFor(DaemonInfo d) => _client(d);

  String newLocalId() => const Uuid().v4();

  Future<void> add(DaemonInfo d) async {
    daemons.removeWhere((x) => x.fingerprint == d.fingerprint && x.deviceId == d.deviceId);
    daemons.add(d);
    await _save();
    _client(d).connect();
    notifyListeners();
  }

  Future<void> remove(DaemonInfo d) async {
    daemons.removeWhere((x) => x.id == d.id);
    final c = clients.remove(d.id);
    await c?.clearCache();
    c?.close();
    await forgetPushKey(d.id);
    await _save();
    notifyListeners();
  }

  int get attentionCount => clients.values.fold(0, (n, c) => n + c.permissions.length + c.sessions.values.where((s) => s.running && s.needsAttention).length);
}
