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

/// The typed-answer field on a single-select page.
Finder get otherSingle => find.widgetWithText(TextField, 'Other (instead of the options above)');
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
    await tester.enterText(otherSingle, 'Only if the tests pass');
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
      await tester.enterText(otherSingle, 'Tomorrow');
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
      await tester.enterText(otherSingle, 'Use QUIC');
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
    await tester.enterText(otherSingle, 'Soon');
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

  testWidgets('with the keyboard up, Next sits above it and a tap outside the field puts it away', (tester) async {
    final c = await pumpFlow(tester, questionJson(two: true));
    await tester.tap(find.text('Polling'));
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    await tester.tap(otherSingle);
    await tester.pump();
    EditableTextState field() => tester.state<EditableTextState>(find.descendant(of: otherSingle, matching: find.byType(EditableText)));
    expect(field().widget.focusNode.hasFocus, isTrue);

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.getRect(next).bottom, lessThanOrEqualTo(size.height - 300), reason: 'above the keyboard');
    expect(next.hitTestable(), findsOneWidget);

    // The empty strip between Back and Next.
    final back = tester.getCenter(find.text('Back'));
    await tester.tapAt(Offset((back.dx + tester.getCenter(next).dx) / 2, back.dy));
    await tester.pump();
    expect(field().widget.focusNode.hasFocus, isFalse, reason: 'a tap outside unfocuses');

    await tester.enterText(otherSingle, 'Tomorrow');
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    expect(find.text('Review'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.context?.widget, isNot(isA<EditableText>()));
    await finishFlow(tester, c);
  });

  testWidgets('on a single-select page, Other and the options exclude each other; notes ride along', (tester) async {
    final c = await pumpFlow(tester, questionJson());
    int? choice() => tester.widget<RadioGroup<int>>(find.byType(RadioGroup<int>)).groupValue;
    await tester.tap(find.text('Polling'));
    await tester.pump();
    expect(choice(), 1);
    await tester.enterText(otherSingle, 'Use QUIC');
    await tester.pump();
    expect(choice(), isNull, reason: 'typing replaces the choice');
    expect(enabled(tester, next), isTrue);
    await tester.tap(find.text('WebSocket'));
    await tester.pump();
    expect(choice(), 0);
    expect(find.text('Use QUIC'), findsNothing, reason: 'a choice clears the typed answer');

    expect(find.widgetWithText(TextField, 'Notes'), findsNothing, reason: 'collapsed until asked for');
    await tester.tap(find.text('Add notes (optional)'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Notes'), 'Behind the proxy');
    await tester.pump();
    expect(choice(), 0, reason: 'notes keep the choice');
    await tester.tap(next);
    await tester.pump();
    expect(find.text('WebSocket'), findsOneWidget);
    expect(find.text('Notes: Behind the proxy'), findsOneWidget);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(c.sent('question.answer').single['answers'], [
      {'index': 0, 'notes': 'Behind the proxy'},
    ]);
    await finishFlow(tester, c);
  });

  testWidgets('the review page names each question that needs an answer and holds Submit', (tester) async {
    final c = FakeClient();
    c.inject('hello', {'name': 'desk', 'version': '1', 'sessions': [session(key, status: 'waiting_input', question: questionJson(two: true))]});
    // A restored draft that both chose and typed on the first question and
    // left the second empty.
    c.questionDrafts[DaemonClient.questionDraftKey(key, c.sessions[key]!.question!)] = QuestionDraft(single: {0: 1}, other: {0: 'Both'}, page: 2);
    await pumpFlow(tester, questionJson(two: true), client: c);
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Question 1 needs an answer'), findsOneWidget);
    expect(find.text('Question 2 needs an answer'), findsOneWidget);
    expect(enabled(tester, submit), isFalse);
    await tester.tap(find.text('Edit').last);
    await tester.pump();
    expect(find.text('Question 2 of 2'), findsOneWidget);
    await tester.tap(find.text('Yes'));
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    expect(find.text('Question 1 needs an answer'), findsOneWidget);
    expect(find.text('Question 2 needs an answer'), findsNothing);
    expect(find.text('Yes'), findsOneWidget);
    expect(enabled(tester, submit), isFalse);
    await tester.tap(find.text('Edit').first);
    await tester.pump();
    await tester.tap(find.text('WebSocket'));
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    await tester.tap(next);
    await tester.pump();
    expect(find.textContaining('needs an answer'), findsNothing);
    expect(enabled(tester, submit), isTrue);
    await finishFlow(tester, c);
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
