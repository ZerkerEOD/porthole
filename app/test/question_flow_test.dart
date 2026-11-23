import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/client.dart';
import 'package:porthole/models.dart';
import 'package:porthole/screens/question_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const key = 'claude:a';

/// A host screen with a button that pushes the flow, so popping and the
/// SnackBar it leaves behind can be observed.
Future<FakeClient> pumpFlow(WidgetTester tester, Map<String, dynamic> q, {FakeClient? client, bool open = true}) async {
  final c = client ?? FakeClient();
  if (!c.sessions.containsKey(key)) c.inject('hello', {'name': 'desk', 'version': '1', 'sessions': [session(key, status: 'waiting_input', question: q)]});
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () {
              final pq = c.sessions[key]!.question!;
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => QuestionFlowScreen(client: c, sessionKey: key, question: pq)));
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  ));
  if (open) {
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }
  return c;
}

Finder get next => find.widgetWithText(FilledButton, 'Next');
Finder get submit => find.widgetWithText(FilledButton, 'Submit');
bool enabled(WidgetTester tester, Finder f) => tester.widget<FilledButton>(f).onPressed != null;

Future<void> finishFlow(WidgetTester tester, FakeClient c) async {
  await tester.pump(const Duration(seconds: 1)); // the draft save debounce
  await tester.pumpWidget(const SizedBox());
  c.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the question hash follows the questions, not the id', () {
    final a = PendingQuestion.fromJson(questionJson());
    final b = PendingQuestion.fromJson(questionJson(id: 'other'));
    final c = PendingQuestion.fromJson(questionJson(two: true));
    final d = PendingQuestion.fromJson(questionJson(preview: 'x'));
    expect(a.hash, b.hash);
    expect(a.hash, isNot(c.hash));
    expect(a.hash, isNot(d.hash));
    expect(d.questions.first.options.first.preview, 'x');
    final draft = QuestionDraft(single: {0: 1}, multi: {1: {2, 0}}, other: {1: 'hi'}, page: 2);
    final back = QuestionDraft.fromJson(draft.toJson());
    expect(back.single, {0: 1});
    expect(back.multi, {1: {0, 2}});
    expect(back.other, {1: 'hi'});
    expect(back.page, 2);
  });

  testWidgets('one page per question, Next gated on an answer, review with Edit', (tester) async {
    final c = await pumpFlow(tester, questionJson(two: true));
    expect(find.text('Question 1 of 2'), findsOneWidget);
    expect(find.text('Transport'), findsOneWidget);
    expect(find.text('Select one'), findsOneWidget);
    expect(find.text('Keeps one socket open'), findsOneWidget);
    expect(find.text('Back'), findsNothing);
    expect(enabled(tester, next), isFalse);
    await tester.tap(find.text('Polling'));
    await tester.pump();
    expect(enabled(tester, next), isTrue);
    await tester.tap(next);
    await tester.pump();
    expect(find.text('Question 2 of 2'), findsOneWidget);
    expect(find.text('Ship it today?'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(enabled(tester, next), isFalse);
    await tester.enterText(find.widgetWithText(TextField, 'Other'), 'Only if the tests pass');
    await tester.pump();
    expect(enabled(tester, next), isTrue);
    await tester.tap(next);
    await tester.pump();
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Polling'), findsOneWidget);
    expect(find.text('Only if the tests pass'), findsOneWidget);
    expect(find.text('Edit'), findsNWidgets(2));
    await tester.tap(find.text('Edit').first);
    await tester.pump();
    expect(find.text('Question 1 of 2'), findsOneWidget);
    expect(find.text('Back'), findsNothing, reason: 'hidden on the first page');
    await finishFlow(tester, c);
  });

  testWidgets('a long preview is capped at 12 lines until Show more', (tester) async {
    final lines = [for (var i = 1; i <= 20; i++) 'line $i'];
    final c = await pumpFlow(tester, questionJson(preview: lines.join('\n')));
    expect(find.text(lines.take(12).join('\n')), findsOneWidget);
    expect(find.text('Show more'), findsOneWidget);
    await tester.tap(find.text('Show more'));
    await tester.pump();
    expect(find.text(lines.join('\n')), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);
    await tester.ensureVisible(find.text('Show less'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show less'));
    await tester.pump();
    expect(find.text(lines.take(12).join('\n')), findsOneWidget);
    final style = tester.widget<Text>(find.text(lines.take(12).join('\n'))).style!;
    expect(style.fontFamily, 'monospace');
    expect(style.fontSize, 12);
    await finishFlow(tester, c);
  });

  testWidgets('a short preview has no toggle', (tester) async {
    final c = await pumpFlow(tester, questionJson(preview: 'a\nb'));
    expect(find.text('a\nb'), findsOneWidget);
    expect(find.text('Show more'), findsNothing);
    await finishFlow(tester, c);
  });

  group('submit payloads', () {
    testWidgets('single choice, then a typed answer on the second question', (tester) async {
      final c = await pumpFlow(tester, questionJson(two: true));
      await tester.tap(find.text('Polling'));
      await tester.pump();
      await tester.tap(next);
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Other'), 'Tomorrow');
      await tester.pump();
      await tester.tap(next);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(submit);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'spinner while waiting');
      await tester.pumpAndSettle();
      expect(c.sent('question.answer'), [
        {'key': key, 'id': 'toolu_q1', 'answers': [{'index': 1}, {'text': 'Tomorrow'}]},
      ]);
      expect(find.byType(QuestionFlowScreen), findsNothing, reason: 'popped on success');
      expect(c.questionDrafts, isEmpty);
      await finishFlow(tester, c);
    });

    testWidgets('multi-select with a typed answer, then a single choice', (tester) async {
      final c = await pumpFlow(tester, questionJson(multi: true, two: true));
      expect(find.text('Select all that apply'), findsOneWidget);
      await tester.tap(find.text('Polling'));
      await tester.tap(find.text('WebSocket'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Other'), 'QUIC later');
      await tester.pump();
      await tester.tap(next);
      await tester.pump();
      await tester.tap(find.text('Yes'));
      await tester.pump();
      await tester.tap(next);
      await tester.pump();
      expect(find.text('WebSocket, Polling, QUIC later'), findsOneWidget);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(c.sent('question.answer').single['answers'], [
        {'indices': [0, 1], 'text': 'QUIC later'},
        {'index': 0},
      ]);
      await finishFlow(tester, c);
    });

    testWidgets('a typed answer alone', (tester) async {
      final c = await pumpFlow(tester, questionJson());
      await tester.enterText(find.widgetWithText(TextField, 'Other'), 'Use QUIC');
      await tester.pump();
      await tester.tap(next);
      await tester.pump();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(c.sent('question.answer').single['answers'], [
        {'text': 'Use QUIC'},
      ]);
      await finishFlow(tester, c);
    });
  });

  testWidgets('the draft survives closing the flow and a new client reading the same preferences', (tester) async {
    final c = await pumpFlow(tester, questionJson(two: true));
    await tester.tap(find.text('Polling'));
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Other'), 'Soon');
    await tester.pump();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionFlowScreen), findsNothing);
    final draftKey = c.questionDrafts.keys.single;
    expect(draftKey, 'claude:a:${c.sessions[key]!.question!.hash}');
    expect(c.questionDrafts[draftKey]!.single, {0: 1});
    expect(c.questionDrafts[draftKey]!.other, {1: 'Soon'});
    expect(c.questionDrafts[draftKey]!.page, 1);

    // Reopened: back on the page it was closed on, with the answers in place.
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Question 2 of 2'), findsOneWidget);
    expect(find.text('Soon'), findsOneWidget);
    expect(enabled(tester, next), isTrue);
    await tester.tap(next);
    await tester.pump();
    expect(find.text('Polling'), findsOneWidget);
    expect(find.text('Soon'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1)); // the save debounce

    // A fresh client (an app restart) reads it back from SharedPreferences.
    final c2 = FakeClient();
    await c2.restored;
    expect(c2.questionDrafts.keys, [draftKey]);
    expect(c2.questionDrafts[draftKey]!.other, {1: 'Soon'});
    await pumpFlow(tester, questionJson(two: true), client: c2);
    expect(find.text('Review'), findsOneWidget, reason: 'closed on the review page');
    expect(find.text('Soon'), findsOneWidget);
    expect(enabled(tester, submit), isTrue);
    c.close();
    await finishFlow(tester, c2);
  });

  testWidgets('offline disables Submit and keeps the draft; back online it is enabled again', (tester) async {
    final c = await pumpFlow(tester, questionJson());
    await tester.tap(find.text('WebSocket'));
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    expect(enabled(tester, submit), isTrue);
    c.setState(ConnState.disconnected);
    await tester.pump();
    expect(find.text('Connection to desk lost. Reconnecting… Your answers are kept.'), findsOneWidget);
    expect(enabled(tester, submit), isFalse);
    expect(c.questionDrafts.values.single.single, {0: 0});
    c.setState(ConnState.connected);
    await tester.pump();
    expect(find.text('Connection to desk lost. Reconnecting… Your answers are kept.'), findsNothing);
    expect(enabled(tester, submit), isTrue);
    expect(c.sent('question.answer'), isEmpty);
    await finishFlow(tester, c);
  });

  testWidgets('a refusal is shown inline on the review page and the draft stays', (tester) async {
    final c = await pumpFlow(tester, questionJson());
    c.refuseQuestion = 'question is not on screen';
    await tester.tap(find.text('WebSocket'));
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('question is not on screen'), findsOneWidget);
    expect(find.byType(QuestionFlowScreen), findsOneWidget);
    expect(c.questionDrafts, hasLength(1));
    expect(enabled(tester, submit), isTrue, reason: 'can try again');
    await finishFlow(tester, c);
  });

  testWidgets('the question clearing underneath the flow pops it with the notice', (tester) async {
    final c = await pumpFlow(tester, questionJson());
    await tester.tap(find.text('WebSocket'));
    await tester.pump();
    c.inject('session.upsert', session(key, status: 'busy'));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionFlowScreen), findsNothing);
    expect(find.text(questionGoneNotice), findsOneWidget);
    expect(c.questionDrafts, isEmpty, reason: 'dropped with the question');
    await finishFlow(tester, c);
  });

  testWidgets('a different question set replacing the open one also pops the flow', (tester) async {
    final c = await pumpFlow(tester, questionJson());
    c.inject('session.upsert', session(key, status: 'waiting_input', question: questionJson(id: 'toolu_q2', two: true)));
    await tester.pumpAndSettle();
    expect(find.byType(QuestionFlowScreen), findsNothing);
    expect(find.text(questionGoneNotice), findsOneWidget);
    await finishFlow(tester, c);
  });
}
