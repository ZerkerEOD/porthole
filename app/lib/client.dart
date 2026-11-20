/// WebSocket client for one daemon: pinned TLS, bearer token, request ids,
/// reconnect with backoff, and host fallback.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'push.dart';
import 'push_crypto.dart';

/// `offline` is reached after repeated failures and is shown quietly;
/// `disconnected`/`connecting` are transient.
enum ConnState { disconnected, connecting, connected, offline }

class PairingException implements Exception {
  PairingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Builds an HttpClient that only trusts the daemon's exact certificate.
HttpClient pinnedClient(String fingerprint) {
  final c = HttpClient(context: SecurityContext(withTrustedRoots: false));
  c.connectionTimeout = const Duration(seconds: 6);
  c.badCertificateCallback = (cert, host, port) {
    final fp = base64Url.encode(sha256.convert(cert.der).bytes).replaceAll('=', '');
    return fp == fingerprint;
  };
  return c;
}

/// Pairs with a daemon, trying each host, and returns the stored info.
Future<DaemonInfo> pair(PairPayload p, String deviceName, String localId) async {
  Object? last;
  final keys = await PushKeys.generate();
  for (final host in p.hosts) {
    try {
      final client = pinnedClient(p.fingerprint);
      final req = await client.postUrl(Uri.parse('https://${_hostLit(host)}:${p.port}/v1/pair'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'code': p.code, 'device_name': deviceName, 'push_key': keys.publicKeyB64}));
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp.transform(utf8.decoder).join();
      client.close();
      if (resp.statusCode != 200) {
        throw PairingException(resp.statusCode == 401 ? 'Invalid or expired code' : 'Pairing failed (${resp.statusCode})');
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['push_pub'] is String) {
        await rememberPushKey(localId, await keys.derive(j['push_pub'] as String));
      }
      return DaemonInfo(
        id: localId,
        name: j['name'] as String? ?? p.name,
        hosts: p.hosts,
        port: p.port,
        fingerprint: p.fingerprint,
        token: j['token'] as String,
        deviceId: j['device_id'] as String? ?? '',
        lastHost: host,
      );
    } on PairingException {
      rethrow;
    } catch (e) {
      last = e;
    }
  }
  throw PairingException("Can't reach ${p.name} at ${p.hosts.join(', ')}. Is your VPN connected? ($last)");
}

String _hostLit(String h) => h.contains(':') ? '[$h]' : h;

class DaemonClient extends ChangeNotifier {
  DaemonClient(this.info) {
    _restoreCache();
  }

  final DaemonInfo info;
  ConnState state = ConnState.disconnected;
  String? lastError;
  /// Set when the daemon rejected us (revoked token or changed certificate):
  /// a loud state that retrying cannot fix.
  bool needsRepair = false;
  DateTime? lastSeen;
  int _failures = 0;
  String daemonName = '';
  String daemonVersion = '';
  Map<String, bool> features = {};
  final Map<String, Session> sessions = {};
  final Map<String, PermissionRequest> permissions = {};
  Map<String, dynamic>? accounts;

  /// Per-session event streams and pane streams.
  final _eventCtl = StreamController<(String, List<Event>)>.broadcast();
  final _paneCtl = StreamController<(String, ScreenSnapshot)>.broadcast();
  Stream<(String, List<Event>)> get events => _eventCtl.stream;
  Stream<(String, ScreenSnapshot)> get panes => _paneCtl.stream;

  WebSocket? _ws;
  int _nextId = 1;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  bool _closed = false;
  int _backoff = 1;
  Timer? _reconnect;

  bool get online => state == ConnState.connected;

  Future<void> connect({bool manual = false}) async {
    if (_closed) return;
    if (!manual && !info.autoConnect) return;
    if (state == ConnState.connecting || state == ConnState.connected) return;
    if (manual) {
      _reconnect?.cancel();
      _failures = 0;
      _backoff = 1;
      needsRepair = false;
    }
    state = ConnState.connecting;
    notifyListeners();
    final hosts = [if (info.lastHost != null) info.lastHost!, ...info.hosts.where((h) => h != info.lastHost)];
    Object? last;
    for (final host in hosts) {
      try {
        final client = pinnedClient(info.fingerprint);
        final ws = await WebSocket.connect(
          'wss://${_hostLit(host)}:${info.port}/v1/ws',
          headers: {'Authorization': 'Bearer ${info.token}'},
          protocols: ['porthole.v1'],
          customClient: client,
        ).timeout(const Duration(seconds: 8));
        _ws = ws;
        info.lastHost = host;
        state = ConnState.connected;
        lastError = null;
        needsRepair = false;
        _backoff = 1;
        _failures = 0;
        lastSeen = DateTime.now();
        notifyListeners();
        ws.listen(_onMessage, onDone: _onClosed, onError: (e) {
          lastError = '$e';
          _onClosed();
        });
        return;
      } catch (e) {
        last = e;
      }
    }
    _failures++;
    lastError = _friendly(last);
    final s = '$last';
    needsRepair = s.contains('401') || s.contains('CERTIFICATE') || s.contains('HandshakeException');
    state = (_failures >= 3 || needsRepair) ? ConnState.offline : ConnState.disconnected;
    notifyListeners();
    if (!needsRepair) _scheduleReconnect();
  }

  String _friendly(Object? e) {
    final s = '$e';
    if (s.contains('401')) return 'This device was revoked. Pair again.';
    if (s.contains('CERTIFICATE') || s.contains('HandshakeException')) return 'Certificate changed. Pair again.';
    return "Can't reach ${info.displayName}. Is your VPN connected?";
  }

  /// 1, 2, 4 s for a brief blip, then doubling up to 60 s while offline.
  void _scheduleReconnect() {
    if (_closed) return;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(seconds: _backoff), () => connect());
    _backoff = (_backoff * 2).clamp(1, 60);
  }

  void _onClosed() {
    _ws = null;
    state = ConnState.disconnected;
    _snapshot();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('disconnected'));
    }
    _pending.clear();
    notifyListeners();
    _scheduleReconnect();
  }

  void _onMessage(dynamic data) => handleFrame(jsonDecode(data as String) as Map<String, dynamic>);

  /// True for the built-in demo machine (no network, no push).
  bool get isDemo => false;

  /// Applies one daemon-to-client frame. Protected so a fake transport (the
  /// demo machine) can inject frames through the same parser.
  @protected
  void handleFrame(Map<String, dynamic> m) {
    final type = m['type'] as String;
    final payload = m['payload'];
    switch (type) {
      case 'hello':
        final p = payload as Map<String, dynamic>;
        daemonName = p['name'] as String? ?? info.name;
        daemonVersion = p['version'] as String? ?? '';
        features = (p['features'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v == true));
        sessions.clear();
        for (final s in (p['sessions'] as List? ?? [])) {
          final ss = Session.fromJson(s as Map<String, dynamic>);
          sessions[ss.key] = ss;
        }
        permissions.clear();
        for (final pr in (p['permissions'] as List? ?? [])) {
          final r = PermissionRequest.fromJson(pr as Map<String, dynamic>);
          permissions[r.id] = r;
        }
        accounts = p['accounts'] as Map<String, dynamic>?;
        lastSeen = DateTime.now();
        notifyListeners();
        _snapshot();
      case 'session.upsert':
        final s = Session.fromJson(payload as Map<String, dynamic>);
        sessions[s.key] = s;
        notifyListeners();
        _snapshotSoon();
      case 'session.removed':
        sessions.remove((payload as Map<String, dynamic>)['key']);
        notifyListeners();
      case 'event':
        final p = payload as Map<String, dynamic>;
        _eventCtl.add((p['key'] as String, (p['events'] as List).map((e) => Event.fromJson(e as Map<String, dynamic>)).toList()));
      case 'pane.snapshot':
        final p = payload as Map<String, dynamic>;
        _paneCtl.add((p['key'] as String, ScreenSnapshot.fromJson(p['screen'] as Map<String, dynamic>)));
      case 'permission.pending':
        final r = PermissionRequest.fromJson(payload as Map<String, dynamic>);
        permissions[r.id] = r;
        notifyListeners();
      case 'permission.resolved':
        permissions.remove((payload as Map<String, dynamic>)['id']);
        notifyListeners();
      case 'accounts.update':
        accounts = payload as Map<String, dynamic>?;
        notifyListeners();
      case 'result':
        final id = m['id'] as String?;
        final c = id == null ? null : _pending.remove(id);
        if (c != null && !c.isCompleted) {
          final r = payload as Map<String, dynamic>;
          if (r['ok'] == true) {
            c.complete(r);
          } else {
            c.completeError(StateError(r['error'] as String? ?? 'error'));
          }
        }
    }
  }

  Future<Map<String, dynamic>> request(String type, [Map<String, dynamic>? payload]) {
    final ws = _ws;
    if (ws == null) return Future.error(StateError('Not connected'));
    final id = '${_nextId++}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    ws.add(jsonEncode({'type': type, 'id': id, 'payload': payload ?? {}}));
    return c.future.timeout(const Duration(seconds: 30), onTimeout: () {
      _pending.remove(id);
      throw TimeoutException(type);
    });
  }

  Future<(List<Event>, bool)> subscribe(String key, {int before = 0, int limit = 200}) async {
    final r = await request('session.subscribe', {'key': key, 'before': before, 'limit': limit});
    return _history(r);
  }

  Future<(List<Event>, bool)> history(String key, {int before = 0, int limit = 200}) async {
    final r = await request('history.page', {'key': key, 'before': before, 'limit': limit});
    return _history(r);
  }

  (List<Event>, bool) _history(Map<String, dynamic> r) {
    final d = r['data'] as Map<String, dynamic>? ?? {};
    final evs = (d['events'] as List? ?? []).map((e) => Event.fromJson(e as Map<String, dynamic>)).toList();
    return (evs, d['has_more'] == true);
  }

  Future<void> unsubscribe(String key) => request('session.unsubscribe', {'key': key}).catchError((_) => <String, dynamic>{});
  Future<void> sendText(String key, String text, {bool enter = true}) => request('session.input', {'key': key, 'text': text, 'enter': enter});
  Future<void> sendKeys(String key, List<String> keys) => request('session.keys', {'key': key, 'keys': keys});
  Future<void> answerPermission(String id, String behavior) => request('permission.answer', {'id': id, 'behavior': behavior});

  Future<ScreenSnapshot?> subscribePane(String key) async {
    final r = await request('pane.subscribe', {'key': key});
    final d = r['data'] as Map<String, dynamic>?;
    return d?['screen'] != null ? ScreenSnapshot.fromJson(d!['screen'] as Map<String, dynamic>) : null;
  }

  Future<void> unsubscribePane(String key) => request('pane.unsubscribe', {'key': key}).catchError((_) => <String, dynamic>{});
  Future<void> resizePane(String key, int cols, int rows) => request('pane.resize', {'key': key, 'cols': cols, 'rows': rows}).catchError((_) => <String, dynamic>{});

  Future<List<Skill>> skills(String provider, String repo) async {
    final r = await request('skills.list', {'provider': provider, 'repo': repo});
    return (r['data'] as List? ?? []).map((e) => Skill.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Repo>> repos() async {
    final r = await request('repos.list');
    return (r['data'] as List? ?? []).map((e) => Repo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Session> spawn({required String provider, required String dir, String? resume, String? prompt, String? permissionMode}) async {
    final r = await request('session.spawn', {
      'provider': provider,
      'dir': dir,
      'resume': ?resume,
      if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
      'permission_mode': ?permissionMode,
    });
    return Session.fromJson(r['data'] as Map<String, dynamic>);
  }

  // ---- last-seen cache (SharedPreferences: titles and paths only) ----

  String get _cacheKey => 'sessions.${info.id}';
  Timer? _snapTimer;

  void _snapshotSoon() {
    _snapTimer?.cancel();
    _snapTimer = Timer(const Duration(seconds: 5), _snapshot);
  }

  Future<void> _snapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final running = sessions.values.where((s) => s.running && !s.stale).take(50).map((s) => s.toCacheJson()).toList();
      await prefs.setString(_cacheKey, jsonEncode({'at': (lastSeen ?? DateTime.now()).toIso8601String(), 'sessions': running}));
    } catch (_) {}
  }

  Future<void> _restoreCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.tryParse(j['at'] as String? ?? '');
      if (at == null || DateTime.now().difference(at).inDays > 7) {
        await prefs.remove(_cacheKey);
        return;
      }
      if (state == ConnState.connected) return; // live data already arrived
      lastSeen ??= at;
      for (final s in (j['sessions'] as List? ?? [])) {
        final ss = Session.fromJson(s as Map<String, dynamic>);
        sessions.putIfAbsent(ss.key, () => ss);
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
    } catch (_) {}
  }

  void close() {
    _closed = true;
    _snapTimer?.cancel();
    _reconnect?.cancel();
    _ws?.close();
    _eventCtl.close();
    _paneCtl.close();
  }
}
