import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/client.dart';
import 'package:porthole/models.dart';
import 'package:porthole/screens/session.dart';
import 'package:porthole/widgets/question_card.dart';
import 'package:porthole/widgets/terminal.dart';
import 'package:shared_preferences/shared_preferences.dart';

DaemonInfo info() => DaemonInfo(id: 'm', name: 'desk', hosts: ['10.0.0.2'], port: 7433, fingerprint: 'fp', token: 't', deviceId: 'd');

Map<String, dynamic> session(String key, {bool pending = false, String pane = '%5', String tmux = 'ph-x', String title = '', String status = 'busy', Map<String, dynamic>? question}) => {
      'key': key,
      'id': key.split(':').last,
      'provider': 'claude',
      'title': title,
      'status': status,
      'running': true,
      'controllable': true,
      'pane_id': pane,
      'tmux_session': tmux,
      'pending': pending,
      'question': ?question,
    };

Map<String, dynamic> questionJson({String id = 'toolu_q1', bool multi = false, bool two = false}) => {
      'id': id,
      'questions': [
        {
          'question': 'Which transport should the relay use?',
          'header': 'Transport',
          'multiSelect': multi,
          'options': [
            {'label': 'WebSocket', 'description': 'Keeps one socket open'},
            {'label': 'Polling', 'description': 'Simpler, more battery'},
          ],
        },
        if (two)
          {
            'question': 'Ship it today?',
            'header': 'Timing',
            'multiSelect': false,
            'options': [
              {'label': 'Yes', 'description': ''},
              {'label': 'No', 'description': ''},
            ],
          },
      ],
    };

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

/// An in-process client for widget tests: answers requests itself and
/// injects daemon frames through the real parser.
class FakeClient extends DaemonClient {
  FakeClient() : super(info()) {
    state = ConnState.connected;
  }
  final List<(String, Map<String, dynamic>)> requests = [];
  final Map<String, List<Map<String, dynamic>>> transcripts = {};
  String? refuseQuestion;
  String? failPane;

  void setState(ConnState s) {
    state = s;
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> request(String type, [Map<String, dynamic>? payload]) async {
    final p = payload ?? const <String, dynamic>{};
    requests.add((type, p));
    await null; // a microtask, so a plain pump() delivers the answer
    switch (type) {
      case 'session.subscribe':
        return {'ok': true, 'data': {'events': transcripts[p['key']] ?? const [], 'has_more': false}};
      case 'pane.subscribe':
        if (failPane != null) throw StateError(failPane!);
        return {'ok': true, 'data': {'screen': {'lines': ['\$ waiting'], 'width': 80, 'height': 24}}};
      case 'skills.list':
        return {'ok': true, 'data': const []};
      case 'question.answer':
        if (refuseQuestion != null) throw StateError(refuseQuestion!);
        return {'ok': true};
      default:
        return {'ok': true};
    }
  }

  void inject(String type, Map<String, dynamic> payload) => handleFrame({'type': type, 'payload': payload});
  List<Map<String, dynamic>> sent(String type) => [for (final r in requests) if (r.$1 == type) r.$2];
}

Future<FakeClient> pumpSession(WidgetTester tester, String key, {List<Map<String, dynamic>>? sessions, FakeClient? client}) async {
  final c = client ?? FakeClient();
  c.inject('hello', {'name': 'desk', 'version': '1', 'sessions': sessions ?? [session(key)]});
  await tester.pumpWidget(MaterialApp(home: SessionScreen(client: c, sessionKey: key)));
  await tester.pump();
  await tester.pump();
  return c;
}

/// Tears the screen down and cancels the client's cache timer, which would
/// otherwise still be pending when the test ends.
Future<void> finish(WidgetTester tester, FakeClient c) async {
  await tester.pumpWidget(const SizedBox());
  c.close();
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

    testWidgets('the question card answers a single choice and hides when the daemon clears it', (tester) async {
      final c = await pumpSession(tester, 'claude:a', sessions: [session('claude:a', status: 'waiting_input', question: questionJson())]);
      expect(find.byType(QuestionCard), findsOneWidget);
      expect(find.text('Transport'), findsOneWidget);
      expect(find.text('Which transport should the relay use?'), findsOneWidget);
      expect(find.text('WebSocket'), findsOneWidget);
      expect(find.text('Keeps one socket open'), findsOneWidget);
      expect(find.text('Waiting for your answer'), findsNothing, reason: 'the card replaces the banner');
      final submit = find.widgetWithText(FilledButton, 'Submit');
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(find.text('Polling'));
      await tester.pump();
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.tap(submit);
      await tester.pump();
      await tester.pump();
      expect(c.sent('question.answer'), [
        {'key': 'claude:a', 'id': 'toolu_q1', 'answers': [{'index': 1}]},
      ]);
      // Answered from here: the card is gone before the daemon catches up.
      expect(find.byType(QuestionCard), findsNothing);
      c.inject('session.upsert', session('claude:a', status: 'busy'));
      await tester.pump();
      expect(find.byType(QuestionCard), findsNothing);
      await finish(tester, c);
    });

    testWidgets('multi-select and typed answers, a refusal, and the terminal shortcut', (tester) async {
      final c = await pumpSession(tester, 'claude:a', sessions: [session('claude:a', status: 'waiting_input', question: questionJson(multi: true, two: true))]);
      c.refuseQuestion = 'the session moved on';
      final submit = find.widgetWithText(FilledButton, 'Submit');
      await tester.tap(find.text('WebSocket'));
      await tester.tap(find.text('Polling'));
      await tester.pump();
      expect(tester.widget<FilledButton>(submit).onPressed, isNull, reason: 'the second question is unanswered');
      await tester.enterText(find.widgetWithText(TextField, 'Other').last, 'Only if the tests pass');
      await tester.pump();
      await tester.tap(submit);
      await tester.pump();
      await tester.pump();
      expect(c.sent('question.answer').single['answers'], [
        {'indices': [0, 1]},
        {'text': 'Only if the tests pass'},
      ]);
      expect(find.text('the session moved on'), findsOneWidget);
      expect(find.byType(QuestionCard), findsOneWidget);
      await tester.tap(find.text('Open terminal'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.byType(QuestionCard), findsOneWidget, reason: 'pinned in terminal mode too');
      await finish(tester, c);
    });

    testWidgets('a question tool use without a result pins the card until its result arrives', (tester) async {
      final c = FakeClient();
      c.transcripts['claude:a'] = [
        {'seq': 1, 'type': 'user', 'text': 'Pick a transport'},
        {'seq': 2, 'type': 'tool.use', 'tool': {'id': 'toolu_q1', 'name': 'AskUserQuestion', 'input': {'questions': questionJson()['questions']}}},
      ];
      await pumpSession(tester, 'claude:a', sessions: [session('claude:a', status: 'waiting_input')], client: c);
      expect(find.byType(QuestionCard), findsOneWidget);
      expect(find.text('Question'), findsNWidgets(2), reason: 'the pinned card and the transcript tile');
      c.inject('event', {
        'key': 'claude:a',
        'events': [
          {'seq': 3, 'type': 'tool.result', 'text': 'Your questions have been answered: "Which transport should the relay use?"="WebSocket"', 'result': {'tool_use_id': 'toolu_q1', 'is_error': false}},
        ],
      });
      await tester.pump();
      expect(find.byType(QuestionCard), findsNothing);
      expect(find.text('Answered: WebSocket'), findsOneWidget);
      // Replayed history (a reconnect) adds nothing twice.
      c.inject('event', {'key': 'claude:a', 'events': c.transcripts['claude:a']!});
      await tester.pump();
      expect(find.text('Pick a transport'), findsOneWidget);
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
