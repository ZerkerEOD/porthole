import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/demo/demo_client.dart';
import 'package:porthole/demo/fixture.dart' as fx;
import 'package:porthole/models.dart';
import 'package:porthole/push.dart';
import 'package:porthole/screens/home.dart';
import 'package:porthole/store.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('relay URL parsing keeps the credential out of the base', () {
    final t = RelayTarget.parse('https://PH-7K3M-Q9ZD-X2VH-R8TB@relay.example')!;
    expect(t.base.toString(), 'https://relay.example');
    expect(t.credential, 'PH-7K3M-Q9ZD-X2VH-R8TB');
    expect(t.host, 'relay.example');
    expect(RelayTarget.parse('relay.example/base/')!.base.path, '/base');
    expect(RelayTarget.parse('http://relay.example'), isNull);
    expect(RelayTarget.parse('https://relay.example/?x=1'), isNull);
    expect(RelayTarget.parse(''), isNull);
  });

  test('demo client answers requests from the fixture without a network', () async {
    final c = DemoDaemonClient(fx.demoDaemonInfo());
    await c.connect();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.online, isTrue);
    expect(c.daemonName, 'demo-box');
    expect(c.sessions.keys, containsAll([fx.claude1, fx.codex1, fx.claude0]));
    final (evs, more) = await c.subscribe(fx.claude1);
    expect(more, isFalse);
    expect(evs.map((e) => e.type), contains('tool.use'));
    final s = await c.spawn(provider: 'codex', dir: '/home/dev/src/porthole/app', prompt: 'Tidy the imports');
    expect(c.sessions[s.key]?.title, 'Tidy the imports');
    final repos = await c.repos();
    expect(repos.map((r) => r.name), contains('porthole/daemon'));
    c.close();
  });

  testWidgets('Try the demo adds a machine whose permission can be approved', (tester) async {
    final store = AppStore();
    await store.load();
    await tester.pumpWidget(ChangeNotifierProvider.value(value: store, child: const MaterialApp(home: HomeScreen())));
    await tester.pump();
    expect(find.text('Try the demo'), findsOneWidget);
    await tester.tap(find.text('Try the demo'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(store.hasDemo, isTrue);
    expect(find.text('Add rate limiting to the pairing endpoint'), findsOneWidget);
    expect(find.text('Fix flaky websocket reconnect test'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining('wants to run Bash'), findsOneWidget);
    await tester.tap(find.text('Allow'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('wants to run Bash'), findsNothing);
    final client = store.clients[fx.demoDaemonId]!;
    expect(client.permissions, isEmpty);
    expect(client.sessions[fx.claude1]?.status, 'busy');
    await tester.pump(const Duration(seconds: 3));
    expect(client.sessions[fx.claude1]?.status, 'idle');

    await store.remove(fx.demoDaemonInfo());
    expect(store.hasDemo, isFalse);
    await tester.pump();
  });

  test('demo machine info survives a round-trip like any other machine', () {
    final back = DaemonInfo.fromJson(fx.demoDaemonInfo().toJson());
    expect(back.id, fx.demoDaemonId);
    expect(back.hosts, ['demo']);
  });
}
