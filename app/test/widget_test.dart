import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/client.dart';
import 'package:porthole/models.dart';
import 'package:porthole/widgets/session_tile.dart';

void main() {
  test('session parses', () {
    final s = Session.fromJson({'key': 'claude:x', 'id': 'x', 'provider': 'claude', 'status': 'waiting_input', 'running': true});
    expect(s.needsAttention, isTrue);
    expect(s.displayTitle, 'x');
    expect(s.stale, isFalse);
    final cached = Session.fromJson(s.toCacheJson());
    expect(cached.stale, isTrue);
    expect(cached.key, 'claude:x');
  });

  test('daemon info round-trips per-machine settings', () {
    final d = DaemonInfo(id: 'a', name: 'desk', hosts: ['100.64.0.1'], port: 7433, fingerprint: 'fp', token: 't', deviceId: 'dev', alias: 'Workstation', muted: true, autoConnect: false);
    final back = DaemonInfo.fromJson(d.toJson());
    expect(back.alias, 'Workstation');
    expect(back.displayName, 'Workstation');
    expect(back.muted, isTrue);
    expect(back.autoConnect, isFalse);
    final plain = DaemonInfo.fromJson({'id': 'b', 'name': 'lap', 'hosts': [], 'port': 1, 'fp': 'f', 'token': 't'});
    expect(plain.displayName, 'lap');
    expect(plain.autoConnect, isTrue);
    expect(plain.muted, isFalse);
  });

  test('machine order: attention, online, transient, offline, then name', () {
    DaemonClient mk(String name, ConnState st, {bool attention = false}) {
      final c = DaemonClient(DaemonInfo(id: name, name: name, hosts: [], port: 1, fingerprint: 'f', token: 't', deviceId: 'd'));
      c.state = st;
      if (attention) {
        c.sessions['claude:x'] = Session.fromJson({'key': 'claude:x', 'id': 'x', 'provider': 'claude', 'status': 'waiting_permission', 'running': true});
      }
      return c;
    }
    final list = [
      mk('zeta', ConnState.offline),
      mk('beta', ConnState.connected),
      mk('alpha', ConnState.connected),
      mk('gamma', ConnState.connecting),
      mk('omega', ConnState.offline, attention: true),
    ]..sort(machineOrder);
    expect(list.map((c) => c.info.name).toList(), ['omega', 'alpha', 'beta', 'gamma', 'zeta']);
  });
}
