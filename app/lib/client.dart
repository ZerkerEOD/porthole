/// WebSocket client for one daemon: pinned TLS, bearer token, request ids,
/// reconnect with backoff, and a race across the daemon's addresses.
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

/// A non-200 answer from the daemon's HTTP endpoints.
class HttpStatusException implements IOException {
  HttpStatusException(this.status);
  final int status;
  @override
  String toString() => 'HTTP $status';
}

/// Why a host could not be used, reduced from the socket error.
enum HostErrorKind { timeout, refused, unreachable, blocked, unauthorized, certificate, other }

/// What the last attempt against one address found: a probe, a connect, or
/// a pairing request.
class HostStatus {
  const HostStatus({
    required this.reachable,
    required this.checkedAt,
    this.latencyMs,
    this.error,
    this.kind,
    this.localNetworkHint = false,
  });

  final bool reachable;
  final DateTime checkedAt;
  final int? latencyMs;
  /// Short text for a failed host ("timed out", "connection refused").
  final String? error;
  final HostErrorKind? kind;
  /// True when the failure looks like iOS blocking local-network access.
  final bool localNetworkHint;

  /// A 401 or a certificate mismatch: retrying cannot fix it.
  bool get needsRepair => kind == HostErrorKind.unauthorized || kind == HostErrorKind.certificate;

  /// What the host row shows: latency when reachable, the error otherwise.
  String get label => reachable ? '${latencyMs ?? 0} ms' : (error ?? 'unreachable');
}

/// A socket error reduced to a kind and a short message.
class HostError {
  const HostError(this.kind, this.text, {this.localNetworkHint = false});
  final HostErrorKind kind;
  final String text;
  final bool localNetworkHint;
}

/// Shown when iOS appears to be blocking an on-link address.
const localNetworkHint = 'Allow Porthole under Settings → Privacy & Security → Local Network';

/// True for addresses that live on the local segment (RFC 1918, link-local,
/// `.local` names). CGNAT space (100.64/10) is routed through the VPN and
/// does not count.
bool isOnLinkAddress(String host) {
  final h = host.trim().toLowerCase();
  if (h.endsWith('.local')) return true;
  final addr = InternetAddress.tryParse(h);
  if (addr == null) return false;
  final b = addr.rawAddress;
  if (addr.type == InternetAddressType.IPv4) {
    if (b[0] == 10) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 169 && b[1] == 254) return true;
    return false;
  }
  return b[0] == 0xfe && (b[1] & 0xc0) == 0x80;
}

/// Maps a connect or request failure to a short message. [ios] defaults to
/// the running platform; there a no-route or permission error against an
/// on-link address usually means the Local Network permission is off.
HostError describeHostError(Object? e, {String host = '', bool? ios}) {
  final onIos = ios ?? Platform.isIOS;
  HostError local(HostErrorKind kind, String text) => HostError(kind, text, localNetworkHint: onIos && isOnLinkAddress(host));
  if (e is TimeoutException) return const HostError(HostErrorKind.timeout, 'timed out');
  if (e is HttpStatusException) {
    return e.status == 401 ? const HostError(HostErrorKind.unauthorized, 'revoked (401)') : HostError(HostErrorKind.other, 'HTTP ${e.status}');
  }
  if (e is WebSocketException) {
    final code = e.httpStatusCode;
    if (code == 401) return const HostError(HostErrorKind.unauthorized, 'revoked (401)');
    if (code != null) return HostError(HostErrorKind.other, 'HTTP $code');
    return const HostError(HostErrorKind.other, 'handshake failed');
  }
  if (e is TlsException) {
    final m = e.osError?.message ?? e.message;
    if (m.contains('CERTIFICATE')) return const HostError(HostErrorKind.certificate, 'certificate changed');
    return const HostError(HostErrorKind.other, 'TLS error');
  }
  if (e is SocketException) {
    final code = e.osError?.errorCode;
    final msg = (e.osError?.message ?? e.message).toLowerCase();
    if (code == 61 || code == 111 || msg.contains('refused')) return const HostError(HostErrorKind.refused, 'connection refused');
    if (code == 65 || code == 113 || msg.contains('no route')) return local(HostErrorKind.unreachable, 'no route to host');
    if (code == 51 || code == 101 || msg.contains('network is unreachable')) return local(HostErrorKind.unreachable, 'network unreachable');
    if (code == 60 || code == 110 || msg.contains('timed out')) return const HostError(HostErrorKind.timeout, 'timed out');
    if (code == 1 || code == 13 || msg.contains('permission') || msg.contains('not permitted')) return local(HostErrorKind.blocked, 'not permitted');
    if (code == 54 || code == 104 || msg.contains('reset')) return const HostError(HostErrorKind.other, 'connection reset');
    if (msg.contains('lookup') || msg.contains('nodename') || msg.contains('not known')) return const HostError(HostErrorKind.other, 'name not found');
    return HostError(HostErrorKind.other, _shortError(e.osError?.message ?? e.message));
  }
  final s = '$e';
  if (s.contains('CERTIFICATE')) return const HostError(HostErrorKind.certificate, 'certificate changed');
  return HostError(HostErrorKind.other, _shortError(s));
}

String _shortError(String s) {
  final t = s.trim().split('\n').first;
  return t.length > 48 ? '${t.substring(0, 47)}…' : (t.isEmpty ? 'failed' : t);
}

/// Fresh addresses from the daemon first, then any older ones it no longer
/// lists, without duplicates.
List<String> mergeHosts(List<String> fresh, List<String> old) {
  final out = <String>[];
  for (final h in [...fresh, ...old]) {
    final t = h.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }
  return out;
}

typedef HostAttempt<T> = Future<T> Function(String host);

/// Result of [raceHosts]: the first host that answered, and what every host
/// that got to run reported.
class HostRace<T> {
  HostRace(this.hosts, this.winner, this.outcomes, this.errors);
  final List<String> hosts;
  final (String, T)? winner;
  final Map<String, HostStatus> outcomes;
  final Map<String, Object> errors;

  bool get needsRepair => outcomes.values.any((s) => s.needsRepair);

  /// One line, "host: error · host: error", with the iOS hint when a
  /// local address looks blocked.
  String summary() {
    final parts = [
      for (final h in hosts)
        if (outcomes[h] case final s?) '$h: ${s.label}',
    ];
    final hint = outcomes.values.any((s) => s.localNetworkHint);
    return '${parts.join(' · ')}${hint ? '. $localNetworkHint' : ''}';
  }
}

/// Starts [attempt] against every host at once, the first host [headStart]
/// ahead of the rest, and settles on the first success. Late successes go to
/// [discard]; each attempt gets at most [budget] measured from the start of
/// the race. A host that never started because a winner arrived during the
/// head start is left out of the outcomes. [onOutcome] fires for every host
/// as it finishes, including losers that finish after the race is settled.
Future<HostRace<T>> raceHosts<T>(
  List<String> hosts,
  HostAttempt<T> attempt, {
  required void Function(T value) discard,
  Duration headStart = Duration.zero,
  Duration budget = const Duration(seconds: 8),
  void Function(String host, HostStatus status)? onOutcome,
  bool? ios,
}) async {
  final outcomes = <String, HostStatus>{};
  final errors = <String, Object>{};
  final done = Completer<(String, T)?>();
  var pending = hosts.length;
  if (pending == 0) return HostRace(hosts, null, outcomes, errors);

  Future<void> run(String host, Duration delay) async {
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (done.isCompleted) return;
      final sw = Stopwatch()..start();
      final result = Completer<T>();
      var settled = false;
      Future<T>(() => attempt(host)).then((v) {
        if (settled) {
          discard(v);
          return;
        }
        settled = true;
        result.complete(v);
      }, onError: (Object e, StackTrace st) {
        if (settled) return;
        settled = true;
        result.completeError(e, st);
      });
      final limit = budget - delay;
      final timer = Timer(limit, () {
        if (settled) return;
        settled = true;
        result.completeError(TimeoutException('connect', limit));
      });
      HostStatus status;
      try {
        final v = await result.future;
        status = HostStatus(reachable: true, checkedAt: DateTime.now(), latencyMs: sw.elapsedMilliseconds);
        if (done.isCompleted) {
          discard(v);
        } else {
          done.complete((host, v));
        }
      } catch (e) {
        final err = describeHostError(e, host: host, ios: ios);
        status = HostStatus(
          reachable: false,
          checkedAt: DateTime.now(),
          latencyMs: sw.elapsedMilliseconds,
          error: err.text,
          kind: err.kind,
          localNetworkHint: err.localNetworkHint,
        );
        errors[host] = e;
      }
      timer.cancel();
      outcomes[host] = status;
      onOutcome?.call(host, status);
    } finally {
      pending--;
      if (pending == 0 && !done.isCompleted) done.complete(null);
    }
  }

  for (var i = 0; i < hosts.length; i++) {
    unawaited(run(hosts[i], i == 0 ? Duration.zero : headStart));
  }
  return HostRace(hosts, await done.future, outcomes, errors);
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

/// Pairs with a daemon, racing its hosts, and returns the stored info.
/// [poster] replaces the HTTPS POST in tests.
Future<DaemonInfo> pair(PairPayload p, String deviceName, String localId, {HostAttempt<Map<String, dynamic>>? poster}) async {
  final hosts = mergeHosts(p.hosts, const []);
  if (hosts.isEmpty) throw PairingException('No host address to pair with.');
  final keys = await PushKeys.generate();
  Future<Map<String, dynamic>> post(String host) async {
    final client = pinnedClient(p.fingerprint);
    try {
      final req = await client.postUrl(Uri.parse('https://${_hostLit(host)}:${p.port}/v1/pair'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'code': p.code, 'device_name': deviceName, 'push_key': keys.publicKeyB64}));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) throw HttpStatusException(resp.statusCode);
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  final race = await raceHosts<Map<String, dynamic>>(hosts, poster ?? post, discard: (_) {});
  final winner = race.winner;
  if (winner == null) {
    final rejected = race.errors.values.whereType<HttpStatusException>().firstOrNull;
    if (rejected != null) {
      throw PairingException(rejected.status == 401 ? 'Invalid or expired code' : 'Pairing failed (${rejected.status})');
    }
    throw PairingException("Can't reach ${p.name}: ${race.summary()}");
  }
  final (host, j) = winner;
  if (j['push_pub'] is String) {
    await rememberPushKey(localId, await keys.derive(j['push_pub'] as String));
  }
  return DaemonInfo(
    id: localId,
    name: j['name'] as String? ?? p.name,
    hosts: hosts,
    port: p.port,
    fingerprint: p.fingerprint,
    token: j['token'] as String,
    deviceId: j['device_id'] as String? ?? '',
    lastHost: host,
  );
}

String _hostLit(String h) => h.contains(':') ? '[$h]' : h;

typedef HostConnector = Future<WebSocket> Function(String host);
typedef HostProbe = Future<void> Function(String host);

class DaemonClient extends ChangeNotifier {
  /// [connector] and [prober] replace the pinned WebSocket connect and the
  /// health GET in tests.
  DaemonClient(this.info, {HostConnector? connector, HostProbe? prober})
      : _connector = connector,
        _prober = prober {
    _restoreCache();
  }

  final DaemonInfo info;
  final HostConnector? _connector;
  final HostProbe? _prober;
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
  /// Latest result per address, from connects and probes.
  final Map<String, HostStatus> hostStatus = {};

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
  bool _probing = false;

  bool get online => state == ConnState.connected;

  /// The preferred address first, then the rest in the daemon's order.
  List<String> get orderedHosts => mergeHosts([?info.lastHost], info.hosts);

  Future<WebSocket> _connectHost(String host) {
    final connector = _connector;
    if (connector != null) return connector(host);
    return WebSocket.connect(
      'wss://${_hostLit(host)}:${info.port}/v1/ws',
      headers: {'Authorization': 'Bearer ${info.token}'},
      protocols: ['porthole.v1'],
      customClient: pinnedClient(info.fingerprint),
    );
  }

  /// Dials every address at once; the preferred one gets a 250 ms head
  /// start so a working route is kept when both answer.
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
    final hosts = orderedHosts;
    final race = await raceHosts<WebSocket>(
      hosts,
      _connectHost,
      discard: (ws) => ws.close(),
      headStart: hosts.length > 1 && hosts.first == info.lastHost ? const Duration(milliseconds: 250) : Duration.zero,
      onOutcome: (host, status) {
        hostStatus[host] = status;
        if (!_closed) notifyListeners();
      },
    );
    final winner = race.winner;
    if (winner != null) {
      final (host, ws) = winner;
      if (_closed || state != ConnState.connecting) {
        ws.close();
        return;
      }
      _ws = ws;
      info.lastHost = host;
      state = ConnState.connected;
      lastError = null;
      needsRepair = false;
      _backoff = 1;
      _failures = 0;
      lastSeen = DateTime.now();
      notifyListeners();
      ws.listen(_onMessage, onDone: () => _onClosed(ws), onError: (Object e) {
        lastError = '$host: ${describeHostError(e, host: host).text}';
        _onClosed(ws);
      });
      return;
    }
    if (_closed || state != ConnState.connecting) return;
    _failures++;
    needsRepair = race.needsRepair;
    lastError = _failureMessage(race);
    state = (_failures >= 3 || needsRepair) ? ConnState.offline : ConnState.disconnected;
    notifyListeners();
    if (!needsRepair) _scheduleReconnect();
  }

  String _failureMessage(HostRace<WebSocket> race) {
    final kinds = race.outcomes.values.map((s) => s.kind).toSet();
    if (kinds.contains(HostErrorKind.unauthorized)) return 'This device was revoked. Pair again.';
    if (kinds.contains(HostErrorKind.certificate)) return 'Certificate changed. Pair again.';
    if (race.outcomes.isEmpty) return 'No address to reach ${info.displayName}.';
    return race.summary();
  }

  /// Drops the current socket, if any, and dials again right away. Used when
  /// the preferred address changes.
  Future<void> reconnect() async {
    _reconnect?.cancel();
    final ws = _ws;
    if (ws != null) {
      _ws = null;
      state = ConnState.disconnected;
      _failPending();
      notifyListeners();
      ws.close();
    }
    await connect(manual: true);
  }

  /// Checks every address with `GET /v1/health` in parallel, 3 s each, and
  /// records latency or the error. Never counts toward the backoff.
  Future<void> probeHosts() async {
    if (isDemo || _closed || _probing || info.hosts.isEmpty) return;
    _probing = true;
    try {
      await Future.wait([for (final h in mergeHosts(info.hosts, const [])) _probeOne(h)]);
    } finally {
      _probing = false;
    }
  }

  Future<void> _probeOne(String host) async {
    final sw = Stopwatch()..start();
    HostStatus status;
    try {
      await (_prober ?? _probeHealth)(host).timeout(const Duration(seconds: 3));
      status = HostStatus(reachable: true, checkedAt: DateTime.now(), latencyMs: sw.elapsedMilliseconds);
    } catch (e) {
      final err = describeHostError(e, host: host);
      status = HostStatus(
        reachable: false,
        checkedAt: DateTime.now(),
        latencyMs: sw.elapsedMilliseconds,
        error: err.text,
        kind: err.kind,
        localNetworkHint: err.localNetworkHint,
      );
    }
    if (_closed) return;
    hostStatus[host] = status;
    notifyListeners();
  }

  Future<void> _probeHealth(String host) async {
    final client = pinnedClient(info.fingerprint);
    try {
      final req = await client.getUrl(Uri.parse('https://${_hostLit(host)}:${info.port}/v1/health'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${info.token}');
      final resp = await req.close();
      await resp.drain<void>();
      if (resp.statusCode != 200) throw HttpStatusException(resp.statusCode);
    } finally {
      client.close(force: true);
    }
  }

  /// 1, 2, 4 s for a brief blip, then doubling up to 60 s while offline.
  void _scheduleReconnect() {
    if (_closed) return;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(seconds: _backoff), () => connect());
    _backoff = (_backoff * 2).clamp(1, 60);
  }

  void _failPending() {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('disconnected'));
    }
    _pending.clear();
  }

  /// Ignores sockets that were already replaced by [reconnect].
  void _onClosed(WebSocket ws) {
    if (_ws != ws) return;
    _ws = null;
    state = ConnState.disconnected;
    _snapshot();
    _failPending();
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
        final fresh = (p['hosts'] as List?)?.whereType<String>().toList();
        if (fresh != null && fresh.isNotEmpty) {
          final merged = mergeHosts(fresh, info.hosts);
          if (!listEquals(merged, info.hosts)) info.hosts = merged;
        }
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
