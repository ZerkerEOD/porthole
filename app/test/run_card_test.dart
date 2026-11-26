import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/main.dart';
import 'package:porthole/screens/session.dart';
import 'package:porthole/widgets/terminal.dart';

import 'fakes.dart';

const key = 'claude:rc1';

Map<String, dynamic> run({
  String id = 'r1',
  String state = 'running',
  int? exit,
  String tail = 'compiling\nlinking',
  bool fed = false,
  bool queued = false,
  bool recovered = false,
  String sessionKey = key,
}) => {
  'key': sessionKey,
  'id': id,
  'command': 'make build',
  'state': state,
  'exit': ?exit,
  'tail': tail,
  'started_at': DateTime.now().subtract(const Duration(seconds: 75)).toUtc().toIso8601String(),
  if (state != 'running') 'ended_at': DateTime.now().toUtc().toIso8601String(),
  'fed': fed,
  'queued': queued,
  'pane_id': '%42',
  'device': 'phone',
  'recovered': ?(recovered ? true : null),
};

final ring = find.byKey(const ValueKey('state-ring'));

void main() {
  testWidgets('a running command shows its tail and Stop', (tester) async {
    final c = await pumpSession(tester, key, sessions: [session(key, status: 'idle')]);
    c.inject('run.update', run());
    await tester.pump();
    expect(find.text('\$ make build'), findsOneWidget);
    expect(find.text('compiling\nlinking'), findsOneWidget);
    expect(find.textContaining('running · 1m 15s'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('runcard-r1')), matching: ring), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Dismiss'), findsNothing);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(c.sent('run.stop').single, {'key': key, 'id': 'r1'});
    await finish(tester, c);
  });

  testWidgets('a failed command turns crimson and can be dismissed', (tester) async {
    final c = await pumpSession(tester, key, sessions: [session(key, status: 'idle')]);
    c.inject('run.update', run());
    await tester.pump();
    c.inject('run.update', run(state: 'done', exit: 2, tail: 'error: no rule'));
    await tester.pump();
    final icon = tester.widget<Icon>(find.byKey(const ValueKey('run-state')));
    expect(icon.color, crimsonBright);
    expect(find.textContaining('exit 2'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    await tester.pump();
    expect(c.sent('run.dismiss').single, {'key': key, 'id': 'r1'});
    expect(find.text('\$ make build'), findsNothing);
    await finish(tester, c);
  });

  testWidgets('a clean exit is green; the footer says where the output went', (tester) async {
    final c = await pumpSession(tester, key, sessions: [session(key, status: 'idle')]);
    c.inject('run.update', run(state: 'done', exit: 0, queued: true));
    await tester.pump();
    expect(tester.widget<Icon>(find.byKey(const ValueKey('run-state'))).color, readyGreen);
    expect(find.text('Output queued for the next turn'), findsOneWidget);
    c.inject('run.update', run(state: 'done', exit: 0, fed: true));
    await tester.pump();
    expect(find.text('Output sent to the session'), findsOneWidget);
    expect(find.text('Output queued for the next turn'), findsNothing);
    await finish(tester, c);
  });

  testWidgets('runs come from hello, newest first, only for this session', (tester) async {
    final c = FakeClient();
    c.inject('hello', {
      'name': 'desk',
      'version': '1',
      'sessions': [session(key, status: 'idle')],
      'runs': [
        {...run(id: 'old'), 'command': 'echo old', 'started_at': DateTime.now().subtract(const Duration(minutes: 5)).toUtc().toIso8601String()},
        {...run(id: 'new'), 'command': 'echo new'},
        run(id: 'other', sessionKey: 'claude:else'),
      ],
    });
    expect(c.runs.length, 3);
    await tester.pumpWidget(
      MaterialApp(
        home: SessionScreen(client: c, sessionKey: key),
      ),
    );
    await tester.pump();
    await tester.pump();
    final newY = tester.getTopLeft(find.text('\$ echo new')).dy;
    final oldY = tester.getTopLeft(find.text('\$ echo old')).dy;
    expect(newY, lessThan(oldY));
    expect(find.byKey(const ValueKey('runcard-other')), findsNothing);
    await finish(tester, c);
  });

  testWidgets('Open window subscribes the run pane; a refusal shows in a snack', (tester) async {
    final c = await pumpSession(tester, key, sessions: [session(key, status: 'idle')]);
    c.inject('run.update', run());
    await tester.pump();
    await tester.tap(find.text('Open window'));
    await tester.pump();
    await tester.pump();
    expect(c.sent('pane.subscribe').last, {'key': key, 'pane_id': '%42'});
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.text('Back to session'), findsOneWidget);
    await tester.tap(find.text('Back to session'));
    await tester.pump();
    await tester.pump();
    expect(c.sent('pane.subscribe').last, {'key': key});
    c.failPane = 'unknown pane';
    await tester.tap(find.text('Open window'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Could not open the window: unknown pane'), findsOneWidget);
    await finish(tester, c);
  });

  testWidgets('a vanished run window after a reconnect falls back to the session pane with a notice', (tester) async {
    final c = await pumpSession(tester, key, sessions: [session(key, status: 'idle')]);
    final notices = <(String, String)>[];
    final sub = c.notices.listen(notices.add);
    c.inject('run.update', run());
    await tester.pump();
    await tester.tap(find.text('Open window'));
    await tester.pump();
    await tester.pump();
    expect(c.paneTarget(key), '%42');

    // The same run is still running: the window is subscribed again.
    c.inject('hello', {'name': 'desk', 'version': '1', 'sessions': [session(key, status: 'idle')], 'runs': [run()]});
    await tester.pump();
    await tester.pump();
    expect(c.paneTarget(key), '%42');
    expect(c.sent('pane.subscribe').last, {'key': key, 'pane_id': '%42'});
    expect(notices, isEmpty);

    // The daemon restarted and no longer lists the run.
    c.inject('hello', {'name': 'desk', 'version': '1', 'sessions': [session(key, status: 'idle')]});
    await tester.pump();
    await tester.pump();
    expect(c.paneTarget(key), isNull);
    expect(c.sent('pane.subscribe').last, {'key': key});
    expect(notices, [(key, "The command's window has closed; its output is on the card")]);
    expect(find.text("The command's window has closed; its output is on the card"), findsOneWidget);
    expect(find.text('Back to session'), findsNothing);
    expect(find.byType(TerminalView), findsOneWidget);
    unawaited(sub.cancel());
    await finish(tester, c);
  });

  testWidgets('a finished run offers Full output instead of Open window', (tester) async {
    final c = await pumpSession(tester, key, sessions: [session(key, status: 'idle')]);
    c.inject('run.update', run(state: 'done', exit: 0, recovered: true));
    await tester.pump();
    expect(find.text('Open window'), findsNothing);
    expect(find.text('Full output'), findsOneWidget);
    expect(find.text('recovered after the daemon restarted'), findsOneWidget);
    c.runLogText = 'all\nof\nthe output';
    c.runLogTruncated = true;
    await tester.tap(find.text('Full output'));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(c.sent('run.log').single, {'key': key, 'id': 'r1'});
    expect(c.sent('pane.subscribe'), isEmpty);
    expect(find.byKey(const ValueKey('run-log')), findsOneWidget);
    expect(find.text('all\nof\nthe output'), findsOneWidget);
    expect(find.textContaining('Truncated'), findsOneWidget);
    await finish(tester, c);
  });
}
