import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/client.dart';
import 'package:porthole/models.dart';
import 'package:porthole/screens/question_flow.dart';
import 'package:porthole/widgets/composer.dart';
import 'package:porthole/widgets/terminal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// A loopback daemon: sends hello on every connection, records every frame,
/// answers requests, and can drop the socket to force a reconnect.
class FakeDaemon {
  late HttpServer server;
  final List<WebSocket> sockets = [];
  final List<Map<String, dynamic>> received = [];
  List<Map<String, dynamic>> sessions = [];
  Map<String, dynamic> Function(String type, Map<String, dynamic> payload)? reply;
  int connections = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      connections++;
      sockets.add(ws);
      ws.add(jsonEncode({
        'type': 'hello',
        'payload': {'name': 'desk', 'version': '1', 'sessions': sessions},
      }));
      ws.listen((data) {
        final m = jsonDecode(data as String) as Map<String, dynamic>;
        received.add(m);
        final id = m['id'] as String?;
        if (id == null) return;
        final type = m['type'] as String;
        final payload = (m['payload'] as Map?)?.cast<String, dynamic>() ?? {};
        final r = reply?.call(type, payload) ??
            switch (type) {
              'session.subscribe' => {'ok': true, 'data': {'events': [], 'has_more': false}},
              'pane.subscribe' => {'ok': true, 'data': {'screen': {'lines': ['\$ '], 'width': 80, 'height': 24}}},
              _ => {'ok': true},
            };
        ws.add(jsonEncode({'type': 'result', 'id': id, 'payload': r}));
      });
    });
  }

  void send(Map<String, dynamic> frame) => sockets.last.add(jsonEncode(frame));

  Future<WebSocket> connect(String host) => WebSocket.connect('ws://127.0.0.1:${server.port}/');

  List<Map<String, dynamic>> of(String type) => received.where((m) => m['type'] == type).toList();

  Future<void> stop() => server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('over a loopback daemon', () {
    late FakeDaemon net;
    setUp(() async {
      net = FakeDaemon();
      await net.start();
    });
    tearDown(() => net.stop());

    test('hello after a reconnect re-issues the event, pane and push subscriptions', () async {
      net.sessions = [session('claude:a')];
      final c = DaemonClient(info(), connector: net.connect);
      await c.connect(manual: true);
      expect(c.online, isTrue);
      await c.subscribe('claude:a');
      await c.subscribePane('claude:a');
      await c.request('push.register', {'grant': 'g1', 'expires_at': '2030-01-01T00:00:00Z'});
      expect(c.subscribedKeys, {'claude:a'});
      expect(c.subscribedPanes, {'claude:a'});
      final before = net.received.length;

      final snapshots = <String>[];
      c.panes.listen((p) => snapshots.add(p.$1));
      await net.sockets.last.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.online, isFalse);
      // The 1 s backoff, then the dial and the hello.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(c.online, isTrue);
      expect(net.connections, 2);
      final again = net.received.sublist(before);
      expect(again.where((m) => m['type'] == 'session.subscribe').map((m) => m['payload']['key']), ['claude:a']);
      expect(again.where((m) => m['type'] == 'pane.subscribe').map((m) => m['payload']['key']), ['claude:a']);
      expect(again.where((m) => m['type'] == 'push.register').map((m) => m['payload']['grant']), ['g1']);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(snapshots, ['claude:a'], reason: 'the fresh pane snapshot reaches the terminal');
      expect(c.lastFrameAt, isNotNull);
      c.close();
    });

    test('the first hello on a connection probes the other addresses once', () async {
      final probed = <String>[];
      final two = DaemonInfo(id: 'm', name: 'desk', hosts: ['10.0.0.2', '10.0.0.3'], port: 7433, fingerprint: 'fp', token: 't', deviceId: 'd');
      final c = DaemonClient(two, connector: net.connect, prober: (host) async => probed.add(host));
      await c.connect(manual: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(probed, unorderedEquals(['10.0.0.2', '10.0.0.3']));
      expect(c.hostStatus['10.0.0.3']?.reachable, isTrue);
      expect(c.probingHosts, isEmpty);
      // A reconnect probes again; nothing in between does. Both addresses
      // dial the same loopback, so the race left two server-side sockets.
      for (final ws in List.of(net.sockets)) {
        await ws.close();
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(c.online, isTrue);
      expect(probed.length, 4);
      c.close();
    });

    test('the push grant recorded while offline goes out with the first hello', () async {
      final c = DaemonClient(info(), connector: net.connect);
      await expectLater(c.request('push.register', {'grant': 'g2', 'expires_at': 'x'}), throwsStateError);
      await c.connect(manual: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(net.of('push.register').map((m) => m['payload']['grant']), ['g2']);
      c.request('push.unregister');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await net.sockets.last.close();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(net.of('push.register').length, 1, reason: 'an unregistered grant is not re-sent');
      c.close();
    });

    test('session.replaced is surfaced and drops the old key from the subscriptions', () async {
      net.sessions = [session('claude:pending:%5', pending: true)];
      final c = DaemonClient(info(), connector: net.connect);
      await c.connect(manual: true);
      await c.subscribe('claude:pending:%5');
      await c.subscribePane('claude:pending:%5');
      final seen = <(String, String)>[];
      c.replaced.listen(seen.add);
      net.send({'type': 'session.upsert', 'payload': session('claude:real')});
      net.send({'type': 'session.replaced', 'payload': {'old': 'claude:pending:%5', 'new': 'claude:real'}});
      net.send({'type': 'session.removed', 'payload': {'key': 'claude:pending:%5'}});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, [('claude:pending:%5', 'claude:real')]);
      expect(c.subscribedKeys, isEmpty);
      expect(c.subscribedPanes, isEmpty);
      expect(c.sessions.keys, ['claude:real']);
      c.close();
    });

    test('question.answer carries single, multi and text answers; a refusal carries the reason', () async {
      final c = DaemonClient(info(), connector: net.connect);
      await c.connect(manual: true);
      await c.answerQuestion('claude:a', 'q1', const [QuestionAnswer(index: 1)]);
      await c.answerQuestion('claude:a', 'q2', const [QuestionAnswer(indices: [0, 2])]);
      await c.answerQuestion('claude:a', 'q3', const [QuestionAnswer(text: 'Use QUIC'), QuestionAnswer(index: 0, text: 'but later')]);
      final sent = net.of('question.answer').map((m) => m['payload']).toList();
      expect(sent, [
        {'key': 'claude:a', 'id': 'q1', 'answers': [{'index': 1}]},
        {'key': 'claude:a', 'id': 'q2', 'answers': [{'indices': [0, 2]}]},
        {'key': 'claude:a', 'id': 'q3', 'answers': [{'text': 'Use QUIC'}, {'index': 0, 'text': 'but later'}]},
      ]);
      // The daemon acknowledges the request and reports the refusal in data.
      net.reply = (type, p) => type == 'question.answer' ? {'ok': true, 'data': {'ok': false, 'reason': 'question is not on screen'}} : {'ok': true};
      await expectLater(
        c.answerQuestion('claude:a', 'q1', const [QuestionAnswer(index: 0)]),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'question is not on screen')),
      );
      // A bad request fails at the top level.
      net.reply = (type, p) => type == 'question.answer' ? {'ok': false, 'error': 'bad payload'} : {'ok': true};
      await expectLater(
        c.answerQuestion('claude:a', 'q1', const [QuestionAnswer(index: 0)]),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'bad payload')),
      );
      net.reply = (type, p) => type == 'question.answer' ? {'ok': true, 'data': {'ok': true}} : {'ok': true};
      await c.answerQuestion('claude:a', 'q1', const [QuestionAnswer(index: 0)]);
      c.close();
    });
  });

  group('session model', () {
    test('parses a pending question and a question tool use', () {
      final s = Session.fromJson(session('claude:a', status: 'waiting_input', question: questionJson(two: true)));
      expect(s.question?.id, 'toolu_q1');
      expect(s.question?.questions.length, 2);
      expect(s.question?.questions.first.header, 'Transport');
      expect(s.question?.questions.first.options.map((o) => o.label), ['WebSocket', 'Polling']);
      expect(Session.fromJson(session('claude:a')).question, isNull);
      final t = ToolUse.fromJson({'id': 'toolu_q1', 'name': 'AskUserQuestion', 'input': {'questions': questionJson()['questions']}});
      expect(t.isQuestion, isTrue);
      expect(PendingQuestion.fromToolUse(t).questions.single.question, 'Which transport should the relay use?');
      expect(parseQuestionAnswers('Your questions have been answered: "Which transport should the relay use?"="WebSocket", "Ship it today?"="No"'), [
        ('Which transport should the relay use?', 'WebSocket'),
        ('Ship it today?', 'No'),
      ]);
      expect(parseQuestionAnswers('nothing here'), isEmpty);
    });
  });

  group('session screen', () {
    testWidgets('session.replaced moves the screen to the real session and re-subscribes in the current mode', (tester) async {
      const old = 'claude:pending:%5';
      final c = await pumpSession(tester, old, sessions: [session(old, pending: true, title: 'New session')]);
      expect(c.sent('session.subscribe').map((p) => p['key']), [old]);
      await tester.tap(find.byTooltip('Terminal view'));
      await tester.pump();
      await tester.pump();
      expect(c.sent('pane.subscribe').map((p) => p['key']), [old]);
      expect(find.byType(TerminalView), findsOneWidget);

      c.inject('session.upsert', session('claude:real', title: 'Real one'));
      c.inject('session.replaced', {'old': old, 'new': 'claude:real'});
      c.inject('session.removed', {'key': old});
      await tester.pump();
      await tester.pump();
      expect(c.sent('session.subscribe').map((p) => p['key']), [old, 'claude:real']);
      expect(c.sent('pane.subscribe').map((p) => p['key']), [old, 'claude:real']);
      expect(c.sent('session.unsubscribe').map((p) => p['key']), [old]);
      expect(find.byType(TerminalView), findsOneWidget, reason: 'the mode is kept');
      expect(find.text('Real one'), findsOneWidget);
      // Leaving the terminal is allowed even though the real session is read-only.
      c.inject('session.upsert', {...session('claude:real', title: 'Real one'), 'controllable': false});
      await tester.pump();
      await tester.tap(find.byTooltip('Chat view'));
      await tester.pump();
      expect(find.byType(TerminalView), findsNothing);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.terminal)).onPressed, isNull);
      await finish(tester, c);
    });

    testWidgets('a fresh session opens in chat with a starting notice, then shows the transcript', (tester) async {
      const old = 'claude:pending:%5';
      final c = FakeClient()..failSubscribe = 'no transcript yet';
      await pumpSession(tester, old, sessions: [{...session(old, pending: true), 'repo': 'porthole'}], client: c);
      expect(find.byType(TerminalView), findsNothing, reason: 'chat is the default');
      expect(find.text('Starting the session…'), findsOneWidget);
      expect(find.text('porthole · desk'), findsOneWidget);
      expect(find.byType(Composer), findsOneWidget);
      expect(c.sent('pane.subscribe'), isEmpty, reason: 'the pane is only watched from the terminal view');

      // The real session appears but its transcript is not written yet.
      c.inject('session.upsert', {...session('claude:real', title: 'Real one'), 'repo': 'porthole'});
      c.inject('session.replaced', {'old': old, 'new': 'claude:real'});
      c.inject('session.removed', {'key': old});
      await tester.pump();
      await tester.pump();
      expect(find.text('Starting the session…'), findsOneWidget);
      expect(find.byType(TerminalView), findsNothing);

      // A retry a few seconds later finds it.
      c.failSubscribe = null;
      c.transcripts['claude:real'] = [
        {'seq': 1, 'type': 'user', 'text': 'Fix the flaky test'},
      ];
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('Starting the session…'), findsNothing);
      expect(find.text('Fix the flaky test'), findsOneWidget);
      expect(find.byType(TerminalView), findsNothing);
      expect(c.sent('pane.subscribe'), isEmpty);
      await finish(tester, c);
    });

    testWidgets('a daemon that removes the placeholder first is matched by pane id', (tester) async {
      const old = 'claude:pending:%7';
      final c = await pumpSession(tester, old, sessions: [session(old, pending: true, pane: '%7', tmux: 'ph-y')]);
      c.inject('session.removed', {'key': old});
      await tester.pump();
      c.inject('session.upsert', session('claude:real2', pane: '%7', tmux: 'ph-y', title: 'Real two'));
      await tester.pump();
      await tester.pump();
      expect(c.sent('session.subscribe').map((p) => p['key']), [old, 'claude:real2']);
      expect(find.text('Real two'), findsOneWidget);
      await finish(tester, c);
    });

    testWidgets('the question strip shows in both views, opens the flow, and hides once answered', (tester) async {
      final c = await pumpSession(tester, 'claude:a', sessions: [session('claude:a', status: 'waiting_input', question: questionJson())]);
      expect(find.text('Claude is asking a question'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Answer'), findsOneWidget);
      expect(find.text('Polling'), findsNothing, reason: 'no pinned card');
      expect(find.text('Waiting for your answer'), findsNothing, reason: 'the strip replaces the banner');
      await tester.tap(find.byTooltip('Terminal view'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.text('Claude is asking a question'), findsOneWidget, reason: 'shown in terminal mode too');

      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      expect(find.byType(QuestionFlowScreen), findsOneWidget);
      expect(find.text('Question 1 of 1'), findsOneWidget);
      await tester.tap(find.text('Polling'));
      await tester.pump();
      await tester.tap(find.text('Next'));
      await tester.pump();
      await tester.tap(find.text('Submit'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(c.sent('question.answer'), [
        {'key': 'claude:a', 'id': 'toolu_q1', 'answers': [{'index': 1}]},
      ]);
      // Answered from here: the strip is gone before the daemon catches up.
      expect(find.byType(QuestionFlowScreen), findsNothing);
      expect(find.text('Claude is asking a question'), findsNothing);
      expect(c.questionDrafts, isEmpty);
      c.inject('session.upsert', session('claude:a', status: 'busy'));
      await tester.pump();
      expect(find.text('Claude is asking a question'), findsNothing);
      await finish(tester, c);
    });

    testWidgets('a closed flow leaves a draft on the strip; the terminal toggle says so; the daemon clearing the question drops it', (tester) async {
      final c = await pumpSession(tester, 'claude:a', sessions: [session('claude:a', status: 'waiting_input', question: questionJson(multi: true, two: true))]);
      expect(find.text('Claude is asking 2 questions'), findsOneWidget);
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('WebSocket'));
      await tester.pump();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Answer (draft saved)'), findsOneWidget);
      expect(c.questionDrafts.keys.single, startsWith('claude:a:'));
      await tester.tap(find.byTooltip('Terminal view'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Draft answers are kept until you submit. The terminal shows the live dialog.'), findsOneWidget);
      // The question was answered in the terminal: the draft goes with it.
      c.inject('session.upsert', session('claude:a', status: 'busy'));
      await tester.pump();
      expect(c.questionDrafts, isEmpty);
      expect(find.textContaining('is asking'), findsNothing);
      await finish(tester, c);
    });

    testWidgets('a question tool use without a result is not pinned; the transcript tile shows the answer', (tester) async {
      final c = FakeClient();
      c.transcripts['claude:a'] = [
        {'seq': 1, 'type': 'user', 'text': 'Pick a transport'},
        {'seq': 2, 'type': 'tool.use', 'tool': {'id': 'toolu_q1', 'name': 'AskUserQuestion', 'input': {'questions': questionJson()['questions']}}},
      ];
      await pumpSession(tester, 'claude:a', sessions: [session('claude:a', status: 'waiting_input')], client: c);
      expect(find.textContaining('is asking'), findsNothing, reason: 'the daemon has no question id to answer with');
      expect(find.text('Question'), findsOneWidget, reason: 'the transcript tile only');
      expect(find.text('Waiting for your answer'), findsOneWidget);
      c.inject('event', {
        'key': 'claude:a',
        'events': [
          {'seq': 3, 'type': 'tool.result', 'text': 'Your questions have been answered: "Which transport should the relay use?"="WebSocket"', 'result': {'tool_use_id': 'toolu_q1', 'is_error': false}},
        ],
      });
      await tester.pump();
      expect(find.text('Answered: WebSocket'), findsOneWidget);
      // Replayed history (a reconnect) adds nothing twice.
      c.inject('event', {'key': 'claude:a', 'events': c.transcripts['claude:a']!});
      await tester.pump();
      expect(find.text('Pick a transport'), findsOneWidget);
      await finish(tester, c);
    });

    testWidgets('the offline banner appears and clears; the composer draft survives the mode toggle and session.replaced', (tester) async {
      const old = 'claude:pending:%5';
      final c = await pumpSession(tester, old, sessions: [session(old, pending: true, title: 'New session')]);
      await tester.enterText(find.byType(TextField), 'hello there');
      await tester.pump();
      expect(c.composerDrafts[old], 'hello there');
      c.setState(ConnState.disconnected);
      await tester.pump();
      expect(find.text('Connection to desk lost. Reconnecting…'), findsOneWidget);
      expect(find.text('Sends when reconnected'), findsOneWidget);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send)).onPressed, isNull);
      expect(find.text('hello there'), findsOneWidget, reason: 'the composer stays editable');
      await tester.tap(find.byTooltip('Terminal view'));
      await tester.pump();
      expect(find.text('hello there'), findsOneWidget, reason: 'the terminal composer shares the draft');
      c.setState(ConnState.connected);
      await tester.pump();
      await tester.pump();
      expect(find.text('Connection to desk lost. Reconnecting…'), findsNothing);
      expect(find.text('Sends when reconnected'), findsNothing);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send)).onPressed, isNotNull);

      c.inject('session.upsert', session('claude:real', title: 'Real one'));
      c.inject('session.replaced', {'old': old, 'new': 'claude:real'});
      c.inject('session.removed', {'key': old});
      await tester.pump();
      await tester.pump();
      expect(find.text('Real one'), findsOneWidget);
      expect(find.text('hello there'), findsOneWidget, reason: 'the draft follows the real session');
      expect(c.composerDrafts, {'claude:real': 'hello there'});
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();
      expect(c.sent('session.input').single['text'], 'hello there');
      expect(c.composerDrafts, isEmpty, reason: 'cleared on send');
      expect(find.byType(Composer), findsOneWidget);
      await tester.pump(const Duration(seconds: 1)); // the draft save debounce
      await finish(tester, c);
    });

    testWidgets('waiting_input without a question shows the one-line banner', (tester) async {
      final c = await pumpSession(tester, 'claude:a', sessions: [session('claude:a', status: 'waiting_input')]);
      expect(find.text('Waiting for your answer'), findsOneWidget);
      c.inject('session.upsert', session('claude:a', status: 'busy'));
      await tester.pump();
      expect(find.text('Waiting for your answer'), findsNothing);
      await finish(tester, c);
    });

    testWidgets('losing the connection clears the pane until the next hello brings it back', (tester) async {
      final c = await pumpSession(tester, 'claude:a');
      await tester.tap(find.byTooltip('Terminal view'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('waiting'), findsOneWidget);
      c.setState(ConnState.disconnected);
      await tester.pump();
      expect(find.textContaining('waiting'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      c.setState(ConnState.connected);
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(c.sent('pane.subscribe').length, 1, reason: 'the screen leaves tracked panes to the hello');
      c.inject('hello', {'name': 'desk', 'version': '1', 'sessions': [session('claude:a')]});
      await tester.pump();
      await tester.pump();
      expect(c.sent('pane.subscribe').length, 2);
      expect(find.textContaining('waiting'), findsOneWidget);
      await finish(tester, c);
    });

    testWidgets('a failed pane subscribe shows the reason with Retry', (tester) async {
      final c = await pumpSession(tester, 'claude:a');
      c.failPane = 'pane %5 not found';
      await tester.tap(find.byTooltip('Terminal view'));
      await tester.pump();
      await tester.pump();
      expect(find.text('pane %5 not found'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      c.failPane = null;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(find.text('pane %5 not found'), findsNothing);
      expect(find.textContaining('waiting'), findsOneWidget);
      expect(c.sent('pane.subscribe').length, 2);
      await finish(tester, c);
    });
  });
}
