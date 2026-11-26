import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/client.dart';
import 'package:porthole/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const vpn = '100.100.24.89';
const lan = '10.133.70.251';

DaemonInfo info({List<String> hosts = const [vpn, lan], String? lastHost}) =>
    DaemonInfo(id: 'm', name: 'desk', hosts: List.of(hosts), port: 7433, fingerprint: 'fp', token: 't', deviceId: 'd', lastHost: lastHost);

/// A fake transport: a loopback WebSocket server so a winning connect hands
/// the client a real socket, plus per-host scripts for delay and failure.
class FakeNet {
  late HttpServer server;
  final Map<String, Duration> delay = {};
  final Map<String, Object> fail = {};
  final List<String> dialed = [];
  int accepted = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      accepted++;
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((_) {}, onDone: () {});
    });
  }

  Future<WebSocket> connect(String host) async {
    dialed.add(host);
    await Future<void>.delayed(delay[host] ?? Duration.zero);
    final f = fail[host];
    if (f != null) throw f;
    return WebSocket.connect('ws://127.0.0.1:${server.port}/');
  }

  Future<void> stop() => server.close(force: true);
}

class ProbeClient extends DaemonClient {
  ProbeClient(super.info);
  void inject(Map<String, dynamic> m) => handleFrame(m);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('ignored hosts', ignoredHostsTests);
  late FakeNet net;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    net = FakeNet();
    await net.start();
  });

  tearDown(() => net.stop());

  test('fast LAN host wins while the VPN host is still dialing', () async {
    net.delay[vpn] = const Duration(seconds: 2);
    net.delay[lan] = const Duration(milliseconds: 10);
    final c = DaemonClient(info(), connector: net.connect);
    final sw = Stopwatch()..start();
    await c.connect(manual: true);
    expect(sw.elapsedMilliseconds, lessThan(300));
    expect(c.online, isTrue);
    expect(c.info.lastHost, lan);
    expect(c.hostStatus[lan]?.reachable, isTrue);
    expect(c.hostStatus[lan]?.latencyMs, isNotNull);
    expect(net.dialed, unorderedEquals([vpn, lan]));
    // The slow loser still completes, is recorded, and its socket is dropped.
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    expect(c.hostStatus[vpn]?.reachable, isTrue);
    expect(c.online, isTrue);
    expect(c.info.lastHost, lan);
    c.close();
  });

  test('every host failing yields one line naming each host and its error', () async {
    net.fail[vpn] = TimeoutException('connect');
    net.fail[lan] = const SocketException('Connection failed', osError: OSError('Connection refused', 61));
    final c = DaemonClient(info(), connector: net.connect);
    await c.connect(manual: true);
    expect(c.online, isFalse);
    expect(c.needsRepair, isFalse);
    expect(c.state, ConnState.disconnected);
    expect(c.lastError, '$vpn: timed out · $lan: connection refused');
    expect(c.hostStatus[vpn]?.kind, HostErrorKind.timeout);
    expect(c.hostStatus[lan]?.kind, HostErrorKind.refused);
    c.close();
  });

  test('a 401 from one host means pair again even when the other timed out', () async {
    net.fail[vpn] = TimeoutException('connect');
    net.delay[lan] = const Duration(milliseconds: 20);
    net.fail[lan] = const WebSocketException("Connection to 'wss://x' was not upgraded to websocket", 401);
    final c = DaemonClient(info(), connector: net.connect);
    await c.connect(manual: true);
    expect(c.needsRepair, isTrue);
    expect(c.state, ConnState.offline);
    expect(c.lastError, 'This device was revoked. Pair again.');
    expect(c.hostStatus[lan]?.needsRepair, isTrue);
    c.close();
  });

  test('a certificate mismatch on one host means pair again', () async {
    net.fail[vpn] = const HandshakeException('Handshake error in client', OSError('CERTIFICATE_VERIFY_FAILED: self signed certificate', 1));
    net.fail[lan] = const SocketException('No route to host', osError: OSError('No route to host', 65));
    final c = DaemonClient(info(), connector: net.connect);
    await c.connect(manual: true);
    expect(c.needsRepair, isTrue);
    expect(c.lastError, 'Certificate changed. Pair again.');
    expect(c.hostStatus[vpn]?.error, 'certificate changed');
    expect(c.hostStatus[lan]?.error, 'no route to host');
    c.close();
  });

  test('the preferred host keeps the connection when both answer', () async {
    net.delay[vpn] = const Duration(milliseconds: 20);
    net.delay[lan] = const Duration(milliseconds: 20);
    final c = DaemonClient(info(lastHost: vpn), connector: net.connect);
    await c.connect(manual: true);
    expect(c.online, isTrue);
    expect(c.info.lastHost, vpn);
    expect(net.dialed, [vpn], reason: 'the LAN dial never started');
    // The host that never ran is recorded as skipped, not left untested.
    expect(c.hostStatus[lan]?.reachable, isNull);
    expect(c.hostStatus[lan]?.label, 'not needed ($vpn answered first)');
    expect(c.hostStatus[lan]?.needsRepair, isFalse);
    expect(c.routeNote, '', reason: 'connected over the first address, nothing failed');
    c.close();
  });

  test('the route note names a fallback address and the ones that failed', () {
    final c = ProbeClient(info(lastHost: lan));
    expect(c.routeNote, '', reason: 'offline');
    c.state = ConnState.connected;
    expect(c.routeNote, 'via $lan');
    c.hostStatus[vpn] = HostStatus(reachable: false, checkedAt: DateTime.now(), error: 'timed out', kind: HostErrorKind.timeout);
    expect(c.routeNote, 'via $lan · $vpn unreachable (timed out)');
    c.hostStatus[vpn] = HostStatus(reachable: null, checkedAt: DateTime.now(), error: 'not needed');
    expect(c.routeNote, 'via $lan', reason: 'a skipped address is not a failed one');
    c.info.lastHost = vpn;
    c.hostStatus[lan] = HostStatus(reachable: false, checkedAt: DateTime.now(), error: 'no route to host');
    expect(c.routeNote, '$lan unreachable (no route to host)');
    c.close();
  });

  test('a single host behaves as before', () async {
    net.delay[lan] = const Duration(milliseconds: 10);
    final c = DaemonClient(info(hosts: [lan], lastHost: lan), connector: net.connect);
    final sw = Stopwatch()..start();
    await c.connect(manual: true);
    expect(sw.elapsedMilliseconds, lessThan(200));
    expect(c.online, isTrue);
    expect(net.dialed, [lan]);
    c.close();
  });

  test('hello hosts replace the stored list; a hello without hosts changes nothing', () async {
    final c = ProbeClient(info(hosts: ['10.0.0.9', vpn]));
    c.inject({
      'type': 'hello',
      'payload': {'name': 'desk', 'version': '1', 'hosts': [vpn, lan]},
    });
    expect(c.info.hosts, [vpn, lan]);
    c.inject({
      'type': 'hello',
      'payload': {'name': 'desk', 'version': '1'},
    });
    expect(c.info.hosts, [vpn, lan]);
    c.close();
    expect(mergeHosts([' a ', 'b', 'a'], ['c', 'b', '']), ['a', 'b', 'c']);
    expect(mergeHosts([], ['c']), ['c']);
  });

  test('probeHosts records latency without touching the connection state', () async {
    final c = DaemonClient(
      info(),
      prober: (host) async {
        if (host == vpn) throw const SocketException('x', osError: OSError('No route to host', 113));
      },
    );
    final probing = <Set<String>>[];
    c.addListener(() => probing.add(Set.of(c.probingHosts)));
    await c.probeHosts();
    expect(c.hostStatus[lan]?.reachable, isTrue);
    expect(c.hostStatus[vpn]?.error, 'no route to host');
    expect(c.state, ConnState.disconnected);
    expect(c.lastError, isNull);
    expect(probing.first, isNotEmpty, reason: 'listeners see the probe in flight');
    expect(c.probingHosts, isEmpty);
    c.close();
  });

  test('pair races hosts and takes the first answer', () async {
    final p = PairPayload(name: 'desk', hosts: const [vpn, lan], port: 7433, fingerprint: 'fp', code: 'ABCDEFGH');
    final d = await pair(p, 'phone', 'local-1', poster: (host) async {
      if (host == vpn) {
        await Future<void>.delayed(const Duration(seconds: 1));
        throw TimeoutException('connect');
      }
      return {'token': 'tok', 'device_id': 'dev', 'name': 'desk'};
    });
    expect(d.lastHost, lan);
    expect(d.hosts, [vpn, lan]);
    expect(d.token, 'tok');

    final rejected = pair(p, 'phone', 'local-2', poster: (host) async {
      if (host == vpn) throw TimeoutException('connect');
      throw HttpStatusException(401);
    });
    await expectLater(rejected, throwsA(predicate((e) => '$e' == 'Invalid or expired code')));

    final unreachable = pair(p, 'phone', 'local-3', poster: (host) async {
      throw const SocketException('x', osError: OSError('Connection refused', 111));
    });
    await expectLater(unreachable, throwsA(predicate((e) => '$e' == "Can't reach desk: $vpn: connection refused · $lan: connection refused")));
  });

  group('error text', () {
    HostError d(Object e, {String host = lan, bool ios = false}) => describeHostError(e, host: host, ios: ios);

    test('maps socket errors to short messages', () {
      expect(d(TimeoutException('x')).text, 'timed out');
      expect(d(const SocketException('x', osError: OSError('Connection refused', 61))).text, 'connection refused');
      expect(d(const SocketException('x', osError: OSError('Connection refused', 111))).kind, HostErrorKind.refused);
      expect(d(const SocketException('x', osError: OSError('No route to host', 65))).text, 'no route to host');
      expect(d(const SocketException('x', osError: OSError('Network is unreachable', 101))).text, 'network unreachable');
      expect(d(const SocketException('x', osError: OSError('Operation timed out', 60))).kind, HostErrorKind.timeout);
      expect(d(const SocketException('HTTP connection timed out after 0:00:06.000000, host: 10.0.0.1, port: 7433')).text, 'timed out');
      expect(d(const SocketException('Failed host lookup: desk.example', osError: OSError('Name or service not known', -2))).text, 'name not found');
      expect(d(const WebSocketException('not upgraded', 401)).kind, HostErrorKind.unauthorized);
      expect(d(const WebSocketException('not upgraded', 503)).text, 'HTTP 503');
      expect(d(HttpStatusException(401)).text, 'revoked (401)');
      expect(d(const HandshakeException('Handshake error', OSError('CERTIFICATE_VERIFY_FAILED', 1))).kind, HostErrorKind.certificate);
      expect(d(const HandshakeException('Handshake error', OSError('WRONG_VERSION_NUMBER', 1))).text, 'TLS error');
      expect(d(StateError('something else entirely')).text, 'Bad state: something else entirely');
    });

    test('iOS local-network hint only for on-link addresses with route or permission errors', () {
      const noRoute = SocketException('x', osError: OSError('No route to host', 65));
      const denied = SocketException('x', osError: OSError('Operation not permitted', 1));
      const refused = SocketException('x', osError: OSError('Connection refused', 61));
      expect(d(noRoute, host: lan, ios: true).localNetworkHint, isTrue);
      expect(d(denied, host: '192.168.4.20', ios: true).localNetworkHint, isTrue);
      expect(d(noRoute, host: 'desk.local', ios: true).localNetworkHint, isTrue);
      expect(d(noRoute, host: vpn, ios: true).localNetworkHint, isFalse);
      expect(d(refused, host: lan, ios: true).localNetworkHint, isFalse);
      expect(d(noRoute, host: lan, ios: false).localNetworkHint, isFalse);
      expect(isOnLinkAddress('172.20.1.1'), isTrue);
      expect(isOnLinkAddress('172.32.1.1'), isFalse);
      expect(isOnLinkAddress('169.254.1.1'), isTrue);
      expect(isOnLinkAddress('fe80::1'), isTrue);
      expect(isOnLinkAddress('fd7a:115c:a1e0::1'), isFalse);
      expect(isOnLinkAddress('100.64.0.5'), isFalse);
    });

    test('the summary appends the hint once', () async {
      final race = await raceHosts<int>(
        [lan, vpn],
        (host) async => throw const SocketException('x', osError: OSError('No route to host', 65)),
        discard: (_) {},
        ios: true,
      );
      expect(race.winner, isNull);
      expect(race.summary(), '$lan: no route to host · $vpn: no route to host. $localNetworkHint');
    });
  });
}

void ignoredHostsTests() {
  late FakeNet net;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    net = FakeNet();
    await net.start();
  });
  tearDown(() => net.stop());

  test('an ignored address is never dialled or probed', () async {
    final i = info()..ignoredHosts.add(vpn);
    final c = DaemonClient(i, connector: net.connect);
    await c.connect(manual: true);
    expect(c.online, isTrue);
    expect(net.dialed, [lan]);
    await c.probeHosts();
    expect(net.dialed.where((h) => h == vpn), isEmpty);
    expect(c.hostStatus.containsKey(vpn), isFalse);
    c.close();
  });

  test('hello replaces the stored addresses but keeps the one in use', () async {
    final c = ProbeClient(info(hosts: [vpn, lan, 'fd00::1'], lastHost: lan));
    c.hostStatus['fd00::1'] = HostStatus(reachable: false, checkedAt: DateTime.now(), error: 'timed out');
    c.inject({'type': 'hello', 'payload': {'name': 'desk', 'version': '1', 'hosts': [vpn, '192.168.1.9'], 'sessions': []}});
    expect(c.info.hosts, [vpn, '192.168.1.9', lan]);
    expect(c.hostStatus.containsKey('fd00::1'), isFalse);
    expect(c.routeNote, isNot(contains('fd00')));
    c.close();
  });
}
