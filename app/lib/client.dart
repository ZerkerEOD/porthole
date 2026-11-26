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

  /// True when the host answered, false when it failed, null when the
  /// attempt was never made (another address won the race first).
  final bool? reachable;
  final DateTime checkedAt;
  final int? latencyMs;
  /// Short text for a failed or skipped host ("timed out", "not needed").
  final String? error;
  final HostErrorKind? kind;
  /// True when the failure looks like iOS blocking local-network access.
  final bool localNetworkHint;

  /// A 401 or a certificate mismatch: retrying cannot fix it.
  bool get needsRepair => kind == HostErrorKind.unauthorized || kind == HostErrorKind.certificate;

  /// What the host row shows: latency when reachable, the error otherwise.
  String get label => reachable == true ? '${latencyMs ?? 0} ms' : (error ?? (reachable == null ? 'not needed' : 'unreachable'));
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
    restored = _restoreCache();
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
  /// When the last frame arrived on the current socket; a connection that
  /// has gone quiet is dialed again on wake.
  DateTime? lastFrameAt;
  int _failures = 0;
  String daemonName = '';
  String daemonVersion = '';
  Map<String, bool> features = {};
  final Map<String, Session> sessions = {};
  final Map<String, PermissionRequest> permissions = {};

  /// Commands running (or recently finished) in their own tmux windows,
  /// by run id; see [Run].
  final Map<String, Run> runs = {};
  Map<String, dynamic>? accounts;
  /// Latest result per address, from connects and probes.
  final Map<String, HostStatus> hostStatus = {};
  /// Addresses with a health probe in flight right now.
  final Set<String> probingHosts = {};
  /// Answers in progress for pending questions, keyed
  /// `'<session key>:<question hash>'`; see [QuestionDraft].
  final Map<String, QuestionDraft> questionDrafts = {};
  /// Unsent composer text per session key.
  final Map<String, String> composerDrafts = {};
  /// Sessions this phone has opened or started, so live alerts are raised
  /// for them only. Persisted with the last-seen cache.
  final Set<String> openedSessions = {};
  /// Where the chat of each session was last read on this phone, by
  /// session key; oldest first. Persisted beside the drafts.
  final Map<String, ReadMark> readMarks = {};
  /// Completes once the last-seen cache and the drafts have been read back.
  late final Future<void> restored;

  /// Per-session event streams and pane streams.
  final _eventCtl = StreamController<(String, List<Event>)>.broadcast();
  final _agentEventCtl = StreamController<(String, String, List<Event>)>.broadcast();

  /// Live events of subscribed subagents: (session key, agent id, events).
  Stream<(String, String, List<Event>)> get agentEvents => _agentEventCtl.stream;
  final _paneCtl = StreamController<(String, ScreenSnapshot)>.broadcast();
  /// `(old, new)` when a spawn placeholder becomes a real session.
  final _replacedCtl = StreamController<(String, String)>.broadcast();
  Stream<(String, List<Event>)> get events => _eventCtl.stream;
  Stream<(String, ScreenSnapshot)> get panes => _paneCtl.stream;
  Stream<(String, String)> get replaced => _replacedCtl.stream;

  /// One-line notices for the screen showing a session: (session key, text).
  final _noticeCtl = StreamController<(String, String)>.broadcast();
  Stream<(String, String)> get notices => _noticeCtl.stream;

  /// Shown when a run window the terminal view followed is gone after a
  /// reconnect.
  static const runWindowClosedNotice = "The command's window has closed; its output is on the card";

  /// Live subscriptions; the daemon drops them when the socket closes, so
  /// they are issued again after every hello.
  final Set<String> _eventKeys = {}, _paneKeys = {};
  Map<String, dynamic>? _pushRegistration;
  Set<String> get subscribedKeys => Set.unmodifiable(_eventKeys);
  Set<String> get subscribedPanes => Set.unmodifiable(_paneKeys);
  bool hasPaneSubscription(String key) => _paneKeys.contains(key);
  bool isOpened(String key) => openedSessions.contains(key);

  void _markOpened(String key) {
    if (openedSessions.contains(key)) return;
    openedSessions.add(key);
    while (openedSessions.length > 200) {
      openedSessions.remove(openedSessions.first);
    }
    _snapshotSoon();
  }

  WebSocket? _ws;
  int _nextId = 1;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  bool _closed = false;
  int _backoff = 1;
  Timer? _reconnect;
  bool _probing = false;
  bool _probedSinceHello = false;

  bool get online => state == ConnState.connected;

  /// How the connection is routed, for the machine subtitle: "via HOST"
  /// when a fallback address carries it, and any other address whose last
  /// check failed. Empty when offline or when there is nothing to say.
  /// Route detail for the Machines page only: which address carries the
  /// connection when it is not the first, and which others failed their last
  /// check. Ignored addresses are left out.
  String get routeNote {
    if (!online) return '';
    final via = info.lastHost;
    final hosts = info.activeHosts;
    final parts = <String>[];
    if (via != null && hosts.isNotEmpty && via != hosts.first) parts.add('via $via');
    for (final h in hosts) {
      if (h == via) continue;
      final st = hostStatus[h];
      if (st != null && st.reachable == false) parts.add('$h unreachable (${st.error ?? 'failed'})');
    }
    return parts.join(' · ');
  }

  /// True when the last attempt dialled every address the app may use and
  /// none answered.
  bool get allUnreachable {
    final hosts = info.activeHosts;
    return !online && hosts.isNotEmpty && hosts.every((h) => hostStatus[h]?.reachable == false);
  }

  /// The preferred address first, then the rest in the daemon's order,
  /// without the ignored ones.
  List<String> get orderedHosts => [for (final h in mergeHosts([?info.lastHost], info.hosts)) if (!info.ignoredHosts.contains(h)) h];

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
      // Addresses that never started because the winner arrived during the
      // head start are recorded too, so none stays "untested".
      for (final h in hosts) {
        if (!race.outcomes.containsKey(h)) hostStatus[h] = HostStatus(reachable: null, checkedAt: DateTime.now(), error: 'not needed ($host answered first)');
      }
      ws.pingInterval = const Duration(seconds: 20);
      _ws = ws;
      _probedSinceHello = false;
      info.lastHost = host;
      state = ConnState.connected;
      lastError = null;
      needsRepair = false;
      _backoff = 1;
      _failures = 0;
      lastSeen = DateTime.now();
      lastFrameAt = lastSeen;
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
      await Future.wait([for (final h in info.activeHosts) _probeOne(h)]);
    } finally {
      _probing = false;
    }
  }

  Future<void> _probeOne(String host) async {
    final sw = Stopwatch()..start();
    probingHosts.add(host);
    notifyListeners();
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
    probingHosts.remove(host);
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
    lastFrameAt = DateTime.now();
    switch (type) {
      case 'hello':
        final p = payload as Map<String, dynamic>;
        daemonName = p['name'] as String? ?? info.name;
        daemonVersion = p['version'] as String? ?? '';
        features = (p['features'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v == true));
        final before = Map.of(sessions);
        sessions.clear();
        for (final s in (p['sessions'] as List? ?? [])) {
          final ss = Session.fromJson(s as Map<String, dynamic>);
          sessions[ss.key] = ss;
        }
        for (final old in before.values) {
          _reconcileDraft(old, sessions[old.key]);
        }
        permissions.clear();
        for (final pr in (p['permissions'] as List? ?? [])) {
          final r = PermissionRequest.fromJson(pr as Map<String, dynamic>);
          _markPlan(r);
          permissions[r.id] = r;
        }
        runs.clear();
        for (final r in (p['runs'] as List? ?? [])) {
          final run = Run.fromJson((r as Map).cast<String, dynamic>());
          if (run.id.isNotEmpty) runs[run.id] = run;
        }
        accounts = p['accounts'] as Map<String, dynamic>?;
        // The daemon's advertised addresses replace the stored list, so an
        // address it stopped binding disappears instead of being probed
        // forever. The one that carries this connection is kept regardless.
        final fresh = (p['hosts'] as List?)?.whereType<String>().toList();
        if (fresh != null && fresh.isNotEmpty) {
          final merged = mergeHosts(fresh, [?info.lastHost]);
          if (!listEquals(merged, info.hosts)) {
            for (final h in info.hosts) {
              if (!merged.contains(h)) hostStatus.remove(h);
            }
            info.hosts = merged;
          }
        }
        lastSeen = DateTime.now();
        notifyListeners();
        _snapshot();
        _resubscribe();
        // One check of the other addresses per connection, so the machine
        // row can say which routes work right now.
        if (!_probedSinceHello && _ws != null && info.hosts.length > 1) {
          _probedSinceHello = true;
          unawaited(probeHosts());
        }
      case 'session.upsert':
        final s = Session.fromJson(payload as Map<String, dynamic>);
        _reconcileDraft(sessions[s.key], s);
        sessions[s.key] = s;
        notifyListeners();
        _snapshotSoon();
      case 'session.removed':
        final key = (payload as Map<String, dynamic>)['key'];
        _reconcileDraft(sessions[key], null);
        sessions.remove(key);
        _eventKeys.remove(key);
        _paneKeys.remove(key);
        _paneTargets.remove(key);
        notifyListeners();
      case 'session.replaced':
        final p = payload as Map<String, dynamic>;
        final old = p['old'] as String?;
        final fresh = p['new'] as String?;
        if (old != null && fresh != null) {
          _eventKeys.remove(old);
          _paneKeys.remove(old);
          if (openedSessions.remove(old)) _markOpened(fresh);
          _replacedCtl.add((old, fresh));
        }
      case 'event':
        final p = payload as Map<String, dynamic>;
        _eventCtl.add((p['key'] as String, (p['events'] as List).map((e) => Event.fromJson(e as Map<String, dynamic>)).toList()));
      case 'pane.snapshot':
        final p = payload as Map<String, dynamic>;
        _paneCtl.add((p['key'] as String, ScreenSnapshot.fromJson(p['screen'] as Map<String, dynamic>)));
      case 'agent.events':
        final ap = payload as Map<String, dynamic>;
        _agentEventCtl.add((ap['key'] as String, ap['agent_id'] as String, (ap['events'] as List).map((e) => Event.fromJson(e as Map<String, dynamic>)).toList()));
      case 'permission.pending':
        final r = PermissionRequest.fromJson(payload as Map<String, dynamic>);
        _markPlan(r);
        permissions[r.id] = r;
        notifyListeners();
      case 'permission.resolved':
        permissions.remove((payload as Map<String, dynamic>)['id']);
        notifyListeners();
      case 'run.update':
        final run = Run.fromJson((payload as Map).cast<String, dynamic>());
        if (run.id.isNotEmpty) runs[run.id] = run;
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
            c.completeError(StateError(r['error'] as String? ?? r['reason'] as String? ?? 'error'));
          }
        }
    }
  }

  /// Re-issues the transcript and pane subscriptions (and the push grant)
  /// the daemon forgot when the previous socket closed. History that
  /// arrived meanwhile is replayed on [events]; listeners drop what they
  /// already have by seq.
  void _resubscribe() {
    for (final key in List.of(_eventKeys)) {
      unawaited(() async {
        try {
          final (evs, _) = await subscribe(key, limit: 150);
          if (evs.isNotEmpty && !_closed) _eventCtl.add((key, evs));
        } catch (_) {}
      }());
    }
    for (final key in List.of(_paneKeys)) {
      // A run window survives a reconnect only while the daemon still lists
      // that run as running on that pane; after a daemon restart the window
      // is gone, so the view goes back to the session's own pane.
      final target = _paneTargets[key];
      if (target != null && !runs.values.any((r) => r.key == key && r.paneId == target && r.state == 'running')) {
        _paneTargets.remove(key);
        if (!_closed) _noticeCtl.add((key, runWindowClosedNotice));
      }
      unawaited(() async {
        try {
          final target = _paneTargets[key];
          final scr = target != null ? await subscribeRunPane(key, target) : await subscribePane(key);
          if (scr != null && !_closed) _paneCtl.add((key, scr));
        } catch (_) {}
      }());
    }
    final reg = _pushRegistration;
    if (reg != null) request('push.register', reg).catchError((_) => <String, dynamic>{});
  }

  Future<Map<String, dynamic>> request(String type, [Map<String, dynamic>? payload]) {
    // Remembered even when offline so the next hello carries it.
    if (type == 'push.register') _pushRegistration = payload;
    if (type == 'push.unregister') _pushRegistration = null;
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
    _eventKeys.add(key);
    _markOpened(key);
    try {
      final r = await request('session.subscribe', {'key': key, 'before': before, 'limit': limit});
      return _history(r);
    } catch (_) {
      _eventKeys.remove(key);
      rethrow;
    }
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

  Future<void> unsubscribe(String key) {
    _eventKeys.remove(key);
    return request('session.unsubscribe', {'key': key}).catchError((_) => <String, dynamic>{});
  }

  Future<void> sendText(String key, String text, {bool enter = true}) => request('session.input', {'key': key, 'text': text, 'enter': enter});
  Future<void> sendKeys(String key, List<String> keys) => request('session.keys', {'key': key, 'keys': keys});
  /// Flags the session whose recovered prompt is the plan approval dialog,
  /// so its state reads "plan ready" instead of "needs approval".
  void _markPlan(PermissionRequest r) {
    final s = sessions[r.sessionKey];
    if (s != null) s.planPending = r.recovered && r.toolName == 'Plan approval';
  }

  /// Opens a subagent's transcript (read-only) and starts its live stream.
  Future<(List<Event>, bool)> subscribeAgent(String key, String agentId, {int before = 0, int limit = 200}) async {
    final r = await request('agent.subscribe', {'key': key, 'agent_id': agentId, 'before': before, 'limit': limit});
    final d = r['data'] as Map<String, dynamic>;
    return ((d['events'] as List? ?? const []).map((e) => Event.fromJson(e as Map<String, dynamic>)).toList(), d['has_more'] as bool? ?? false);
  }

  Future<void> unsubscribeAgent(String key, String agentId) => request('agent.unsubscribe', {'key': key, 'agent_id': agentId}).catchError((_) => <String, dynamic>{});

  Future<(List<Event>, bool)> agentHistory(String key, String agentId, {required int before, int limit = 200}) async {
    final r = await request('history.page', {'key': key, 'agent_id': agentId, 'before': before, 'limit': limit});
    final d = r['data'] as Map<String, dynamic>;
    return ((d['events'] as List? ?? const []).map((e) => Event.fromJson(e as Map<String, dynamic>)).toList(), d['has_more'] as bool? ?? false);
  }

  /// Asks the daemon for the current account snapshot.
  Future<void> refreshAccounts() async {
    final r = await request('accounts.get');
    if (r['data'] is Map) {
      accounts = (r['data'] as Map).cast<String, dynamic>();
      notifyListeners();
    }
  }

  Future<void> answerPermission(String id, String behavior) => request('permission.answer', {'id': id, 'behavior': behavior});

  /// Picks option [index] (as the CLI numbers them, from 0) of a prompt read
  /// from the terminal.
  Future<void> answerPermissionOption(String id, int index) => request('permission.answer', {'id': id, 'option': index});

  /// Switches a Claude session's permission mode; the daemon presses
  /// Shift+Tab until the status bar names [mode]. Returns the mode reached.
  Future<String> setMode(String key, String mode) async {
    final r = await request('session.mode', {'key': key, 'mode': mode});
    return (r['data'] as Map?)?['mode'] as String? ?? mode;
  }

  /// Answers a pending question set. The daemon acknowledges the request
  /// and reports in `data` whether the answer landed; a refusal surfaces as
  /// a [StateError] carrying its reason.
  Future<void> answerQuestion(String key, String id, List<QuestionAnswer> answers) async {
    final r = await request('question.answer', {'key': key, 'id': id, 'answers': [for (final a in answers) a.toJson()]});
    final d = r['data'];
    if (d is Map && d['ok'] == false) throw StateError(d['reason'] as String? ?? 'The question could not be answered');
  }

  Future<ScreenSnapshot?> subscribePane(String key) async {
    _paneTargets.remove(key);
    _paneKeys.add(key);
    _markOpened(key);
    try {
      final r = await request('pane.subscribe', {'key': key});
      final d = r['data'] as Map<String, dynamic>?;
      return d?['screen'] != null ? ScreenSnapshot.fromJson(d!['screen'] as Map<String, dynamic>) : null;
    } catch (_) {
      _paneKeys.remove(key);
      rethrow;
    }
  }

  /// Session key -> the run window's pane shown in place of the session's
  /// own pane, so a reconnect subscribes the same one again.
  final Map<String, String> _paneTargets = {};

  /// The run window pane session [key]'s terminal view follows, if any.
  @visibleForTesting
  String? paneTarget(String key) => _paneTargets[key];

  /// Shows a run's tmux window ([paneId]) in the terminal view of session
  /// [key]: `pane.subscribe` with an extra `pane_id`. Snapshots then arrive
  /// on [panes] under the session key. The one place that knows how a run
  /// window is opened.
  Future<ScreenSnapshot?> subscribeRunPane(String key, String paneId) async {
    _paneKeys.add(key);
    _paneTargets[key] = paneId;
    try {
      final r = await request('pane.subscribe', {'key': key, 'pane_id': paneId});
      final d = r['data'] as Map<String, dynamic>?;
      return d?['screen'] != null ? ScreenSnapshot.fromJson(d!['screen'] as Map<String, dynamic>) : null;
    } catch (_) {
      _paneKeys.remove(key);
      _paneTargets.remove(key);
      rethrow;
    }
  }

  /// Runs [command] in a tmux window next to session [key]. With [feed] the
  /// daemon sends the output to the session when it finishes. Returns the
  /// run id; progress arrives as `run.update` in [runs].
  Future<String> runCommand(String key, String command, {bool feed = true}) async {
    final r = await request('session.run', {'key': key, 'command': command, 'feed': feed});
    return (r['data'] as Map?)?['id'] as String? ?? '';
  }

  Future<void> stopRun(String key, String id) => request('run.stop', {'key': key, 'id': id});

  /// Forgets a finished run here and on the daemon.
  Future<void> dismissRun(String key, String id) async {
    await request('run.dismiss', {'key': key, 'id': id});
    if (runs.remove(id) != null) notifyListeners();
  }

  /// Replaces the runs of session [key] with the daemon's list.
  Future<void> listRuns(String key) async {
    final r = await request('run.list', {'key': key});
    final list = (r['data'] as Map?)?['runs'];
    if (list is! List) return;
    runs.removeWhere((_, run) => run.key == key);
    for (final j in list) {
      final run = Run.fromJson((j as Map).cast<String, dynamic>());
      if (run.id.isNotEmpty) runs[run.id] = run;
    }
    notifyListeners();
  }

  /// The full saved output of a finished run (at most 64 KB; [truncated]
  /// when the daemon cut it).
  Future<({String text, bool truncated})> runLog(String key, String id) async {
    final r = await request('run.log', {'key': key, 'id': id});
    final d = r['data'] as Map? ?? const {};
    return (text: d['text'] as String? ?? '', truncated: d['truncated'] as bool? ?? false);
  }

  /// Uploads an image into the session's uploads folder on the machine and
  /// returns the path the daemon saved it at.
  Future<String> putFile(String key, String name, String mediaType, Uint8List bytes) async {
    final r = await request('file.put', {'key': key, 'name': name, 'media_type': mediaType, 'data': base64Encode(bytes)});
    final path = (r['data'] as Map?)?['path'] as String?;
    if (path == null || path.isEmpty) throw StateError('The machine did not say where it saved the image');
    return path;
  }

  /// Images fetched with [getFile], most recently used last, keyed
  /// `'<session key>|<path>'`.
  final Map<String, Future<({Uint8List bytes, String mediaType})>> _images = {};
  static const _imageCacheSize = 20;

  /// Fetches an image from the session's machine (only images under its
  /// working directory, uploads folder or scratchpad are served). Repeated
  /// calls for the same path share one request and its cached result.
  Future<({Uint8List bytes, String mediaType})> getFile(String key, String path) {
    final k = '$key|$path';
    final hit = _images.remove(k);
    if (hit != null) {
      _images[k] = hit;
      return hit;
    }
    final f = () async {
      final r = await request('file.get', {'key': key, 'path': path});
      final d = r['data'] as Map? ?? const {};
      return (bytes: base64Decode(d['data'] as String? ?? ''), mediaType: d['media_type'] as String? ?? '');
    }();
    _images[k] = f;
    while (_images.length > _imageCacheSize) {
      _images.remove(_images.keys.first);
    }
    // A failure is not cached, so the image can be tried again later.
    f.catchError((Object _) {
      if (identical(_images[k], f)) _images.remove(k);
      return (bytes: Uint8List(0), mediaType: '');
    });
    return f;
  }

  Future<void> unsubscribePane(String key) {
    // A run window's subscription is keyed by its pane on the daemon, so the
    // pane id has to go with the request or the subscription outlives the view.
    final target = _paneTargets.remove(key);
    _paneKeys.remove(key);
    return request('pane.unsubscribe', {'key': key, 'pane_id': ?target}).catchError((_) => <String, dynamic>{});
  }
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
    final s = Session.fromJson(r['data'] as Map<String, dynamic>);
    _markOpened(s.key);
    return s;
  }

  // ---- drafts (SharedPreferences, debounced) ----

  String get _draftsKey => 'drafts.${info.id}';
  Timer? _draftTimer;

  static String questionDraftKey(String sessionKey, PendingQuestion q) => '$sessionKey:${q.hash}';

  /// The draft for [q] on [sessionKey], if one was started.
  QuestionDraft? questionDraft(String sessionKey, PendingQuestion q) => questionDrafts[questionDraftKey(sessionKey, q)];

  /// Records [draft] under [key] (see [questionDraftKey]). Listeners hear
  /// about a draft appearing, not about every edit.
  void setQuestionDraft(String key, QuestionDraft draft) {
    final fresh = !questionDrafts.containsKey(key);
    questionDrafts[key] = draft;
    _saveDraftsSoon();
    if (fresh) notifyListeners();
  }

  void dropQuestionDraft(String key) {
    if (questionDrafts.remove(key) == null) return;
    _saveDraftsSoon();
    notifyListeners();
  }

  /// Keeps the unsent composer text for [sessionKey]; empty text forgets it.
  void setComposerDraft(String sessionKey, String text) {
    if (text.isEmpty) {
      if (composerDrafts.remove(sessionKey) == null) return;
    } else {
      if (composerDrafts[sessionKey] == text) return;
      composerDrafts[sessionKey] = text;
    }
    _saveDraftsSoon();
  }

  /// Carries the composer text over when a placeholder becomes the real
  /// session.
  void moveComposerDraft(String from, String to) {
    final t = composerDrafts.remove(from);
    if (t != null && t.isNotEmpty) composerDrafts[to] = t;
    if (t != null) _saveDraftsSoon();
  }

  /// Drops the question draft when the session's question clears or turns
  /// into a different set.
  void _reconcileDraft(Session? old, Session? fresh) {
    final oq = old?.question;
    if (oq == null) return;
    final nq = fresh?.question;
    if (nq != null && nq.hash == oq.hash) return;
    dropQuestionDraft(questionDraftKey(old!.key, oq));
  }

  void _saveDraftsSoon() {
    if (_closed) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 500), _saveDrafts);
  }

  Future<void> _saveDrafts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (questionDrafts.isEmpty && composerDrafts.isEmpty) {
        await prefs.remove(_draftsKey);
        return;
      }
      await prefs.setString(
        _draftsKey,
        jsonEncode({
          'questions': questionDrafts.map((k, v) => MapEntry(k, v.toJson())),
          'composer': composerDrafts,
        }),
      );
    } catch (_) {}
  }

  Future<void> _restoreDrafts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftsKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      for (final e in (j['questions'] as Map? ?? {}).entries) {
        if (e.value is Map) questionDrafts.putIfAbsent('${e.key}', () => QuestionDraft.fromJson((e.value as Map).cast<String, dynamic>()));
      }
      for (final e in (j['composer'] as Map? ?? {}).entries) {
        if (e.value is String && (e.value as String).isNotEmpty) composerDrafts.putIfAbsent('${e.key}', () => e.value as String);
      }
      notifyListeners();
    } catch (_) {}
  }

  // ---- read marks (SharedPreferences, debounced) ----

  String get _readsKey => 'reads.${info.id}';
  Timer? _readsTimer;

  /// Records where [sessionKey]'s chat was read up to. Keeps the 200 most
  /// recent sessions.
  void setReadMark(String sessionKey, ReadMark mark) {
    final old = readMarks[sessionKey];
    if (old != null && old.sameSpot(mark) && mark.at.difference(old.at) < const Duration(hours: 1)) return;
    readMarks.remove(sessionKey);
    readMarks[sessionKey] = mark;
    while (readMarks.length > 200) {
      readMarks.remove(readMarks.keys.first);
    }
    _saveReadsSoon();
  }

  void _saveReadsSoon() {
    if (_closed) return;
    _readsTimer?.cancel();
    _readsTimer = Timer(const Duration(milliseconds: 500), _saveReads);
  }

  Future<void> _saveReads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (readMarks.isEmpty) {
        await prefs.remove(_readsKey);
        return;
      }
      await prefs.setString(_readsKey, jsonEncode(readMarks.map((k, v) => MapEntry(k, v.toJson()))));
    } catch (_) {}
  }

  /// Reads the marks back, dropping those older than 7 days.
  Future<void> _restoreReads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_readsKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final now = DateTime.now();
      final marks = <MapEntry<String, ReadMark>>[
        for (final e in j.entries)
          if (e.value is Map) MapEntry(e.key, ReadMark.fromJson((e.value as Map).cast<String, dynamic>())),
      ]..removeWhere((e) => now.difference(e.value.at).inDays > 7);
      marks.sort((a, b) => a.value.at.compareTo(b.value.at));
      for (final e in marks.skip(marks.length > 200 ? marks.length - 200 : 0)) {
        readMarks.putIfAbsent(e.key, () => e.value);
      }
    } catch (_) {}
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
      await prefs.setString(_cacheKey, jsonEncode({'at': (lastSeen ?? DateTime.now()).toIso8601String(), 'sessions': running, 'opened': openedSessions.toList()}));
    } catch (_) {}
  }

  Future<void> _restoreCache() async {
    await _restoreDrafts();
    await _restoreReads();
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
      openedSessions.addAll((j['opened'] as List? ?? []).whereType<String>());
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
      await prefs.remove(_draftsKey);
      await prefs.remove(_readsKey);
    } catch (_) {}
  }

  void close() {
    _closed = true;
    _snapTimer?.cancel();
    _draftTimer?.cancel();
    _readsTimer?.cancel();
    _reconnect?.cancel();
    _ws?.close();
    _eventCtl.close();
    _agentEventCtl.close();
    _paneCtl.close();
    _replacedCtl.close();
    _noticeCtl.close();
  }
}

/// Where a session's chat was read up to on this phone: the top visible
/// event ([seq], and [id], the transcript uuid, which survives a daemon
/// restart that renumbers seqs), how far its top edge sat from the top of
/// the view as a fraction of the view's height ([align]), and the newest
/// event the screen had loaded ([newestSeq]).
class ReadMark {
  ReadMark({required this.seq, required this.id, required this.align, required this.newestSeq, DateTime? at}) : at = at ?? DateTime.now();
  ReadMark.fromJson(Map<String, dynamic> j)
      : seq = (j['seq'] as num?)?.toInt() ?? 0,
        id = j['id'] as String? ?? '',
        align = (j['align'] as num?)?.toDouble() ?? 0,
        newestSeq = (j['newest_seq'] as num?)?.toInt() ?? 0,
        at = DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);

  final int seq;
  final String id;
  final double align;
  final int newestSeq;
  final DateTime at;

  bool sameSpot(ReadMark o) => seq == o.seq && id == o.id && (align - o.align).abs() < 0.005 && newestSeq == o.newestSeq;

  Map<String, dynamic> toJson() => {'seq': seq, 'id': id, 'align': align, 'newest_seq': newestSeq, 'at': at.toIso8601String()};
}
