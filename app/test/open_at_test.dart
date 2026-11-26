import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/client.dart';
import 'package:porthole/prefs.dart';
import 'package:porthole/screens/session.dart';
import 'package:porthole/screens/settings.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_helpers.dart';
import 'fakes.dart';

const key = 'claude:open1';

ChatPrefs prefsAt(OpenAt o) => ChatPrefs()..openAt = o;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('bottom: opens at the end and stays there as events, a banner and a smaller view arrive', (tester) async {
    final l = ItemPositionsListener.create();
    final c = FakeClient()..transcripts[key] = transcript(1, 60);
    await pumpSession(tester, key, client: c, prefs: prefsAt(OpenAt.bottom), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    expect(atEnd(l, 60), isTrue);
    expect(pos(l, 60), isNotNull);
    expect(find.byIcon(Icons.arrow_downward), findsNothing);

    // A new event follows the end.
    c.inject('event', {
      'key': key,
      'events': [ev(61, 'assistant.text', lines: 6)],
    });
    await settle(tester);
    expect(atEnd(l, 61), isTrue);
    expect(pos(l, 61), isNotNull);

    // A banner above the list.
    c.inject('session.upsert', session(key, status: 'waiting_input'));
    await settle(tester);
    expect(find.textContaining('waiting'), findsWidgets);
    expect(atEnd(l, 61), isTrue);

    // The view loses 200 px, as when the keyboard opens.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 400);
    addTearDown(tester.view.reset);
    await settle(tester);
    expect(atEnd(l, 61), isTrue);
    await finish(tester, c);
  });

  testWidgets('bottom is the default without a provider', (tester) async {
    final l = ItemPositionsListener.create();
    final c = FakeClient()..transcripts[key] = transcript(1, 60);
    await pumpSession(tester, key, client: c, positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    expect(atEnd(l, 60), isTrue);
    await finish(tester, c);
  });

  testWidgets('last message: opens with the first block of the last reply at the top', (tester) async {
    final l = ItemPositionsListener.create();
    final c = FakeClient()
      ..transcripts[key] = [
        ...transcript(1, 56),
        ev(57, 'user'),
        ev(58, 'assistant.text', lines: 16, mid: 'mz'),
        ev(59, 'tool.use', mid: 'mz'),
        ev(60, 'assistant.text', lines: 16, mid: 'mz'),
      ];
    await pumpSession(tester, key, client: c, prefs: prefsAt(OpenAt.lastMessage), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    final p = pos(l, 58);
    expect(p, isNotNull);
    expect(p!.itemLeadingEdge, closeTo(0, 0.01));
    expect(atEnd(l, 60), isFalse);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    await finish(tester, c);
  });

  testWidgets('last message falls back to the end without a reply', (tester) async {
    final l = ItemPositionsListener.create();
    final c = FakeClient()..transcripts[key] = [for (var i = 1; i <= 40; i++) ev(i, 'user')];
    await pumpSession(tester, key, client: c, prefs: prefsAt(OpenAt.lastMessage), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    expect(atEnd(l, 40), isTrue);
    await finish(tester, c);
  });

  testWidgets('last read: opens at the mark with the divider above the first newer event, once', (tester) async {
    final l = ItemPositionsListener.create();
    final c = FakeClient()..transcripts[key] = transcript(1, 60);
    c.readMarks[key] = ReadMark(seq: 30, id: 'e30', align: 0, newestSeq: 31);
    await pumpSession(tester, key, client: c, prefs: prefsAt(OpenAt.lastRead), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    expect(pos(l, 30)!.itemLeadingEdge, closeTo(0, 0.01));
    expect(find.text(NewSinceDivider.caption), findsOneWidget);
    // The divider sits above event 32, below event 31.
    final divider = tester.getRect(find.byType(NewSinceDivider));
    final p31 = pos(l, 31)!, p32 = pos(l, 32)!;
    final top = tester.getRect(find.byType(ScrollablePositionedList)).top;
    final h = tester.getRect(find.byType(ScrollablePositionedList)).height;
    expect(divider.top, greaterThanOrEqualTo(top + p31.itemTrailingEdge * h - 1));
    expect(divider.top, closeTo(top + p32.itemLeadingEdge * h, 2));
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);

    // Leaving records the mark with everything loaded; the next open has
    // nothing new and no divider.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(c.readMarks[key]!.seq, 30);
    expect(c.readMarks[key]!.newestSeq, 60);
    await pumpSession(tester, key, client: c, prefs: prefsAt(OpenAt.lastRead), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    expect(pos(l, 30)!.itemLeadingEdge, closeTo(0, 0.01));
    expect(find.text(NewSinceDivider.caption), findsNothing);
    await finish(tester, c);
  });

  testWidgets('last read: a mark older than the page pages back once, then opens at it', (tester) async {
    final l = ItemPositionsListener.create();
    final c = PagedClient(transcript(151, 300));
    c.readMarks[key] = ReadMark(seq: 40, id: 'e40', align: 0.2, newestSeq: 300);
    await pumpSession(tester, key, client: c, prefs: prefsAt(OpenAt.lastRead), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    expect(c.sent('history.page').map((p) => p['before']).toList(), [151]);
    expect(pos(l, 40)!.itemLeadingEdge, closeTo(0.2, 0.01));
    expect(find.text(lostReadMarkNotice), findsNothing);
    await finish(tester, c);
  });

  testWidgets('last read: a mark that cannot be found opens at the end and says so', (tester) async {
    final l = ItemPositionsListener.create();
    final c = PagedClient(transcript(1001, 1150), endless: true);
    c.readMarks[key] = ReadMark(seq: 5, id: 'gone', align: 0, newestSeq: 6);
    await pumpSession(tester, key, client: c, prefs: prefsAt(OpenAt.lastRead), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    expect(c.sent('history.page').length, 5);
    expect(find.text(lostReadMarkNotice), findsOneWidget);
    expect(atEnd(l, 150 * 6), isTrue);
    await finish(tester, c);
  });

  testWidgets('loading earlier events keeps the top event where it was', (tester) async {
    final l = ItemPositionsListener.create();
    final c = PagedClient(transcript(151, 300));
    // Opens near the start of the page, so the Load earlier row is in view
    // and the next page loads by itself.
    c.readMarks[key] = ReadMark(seq: 152, id: 'e152', align: 0.6, newestSeq: 300);
    await pumpSession(tester, key, client: c, prefs: prefsAt(OpenAt.lastRead), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    expect(c.sent('history.page').map((p) => p['before']).toList(), [151]);
    expect(pos(l, 152)!.itemLeadingEdge, closeTo(0.6, 0.01));
    expect(pos(l, 150), isNotNull);
    await finish(tester, c);
  });

  testWidgets('settings: the sheet changes where chats open and keeps it', (tester) async {
    final prefs = ChatPrefs();
    await prefs.load();
    expect(prefs.openAt, OpenAt.bottom);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showOpenAtSheet(context, prefs), child: const Text('open')))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Last read position'), findsOneWidget);
    expect(find.text('Where you left off, with new messages below.'), findsOneWidget);
    expect(find.text("The start of Claude's latest reply."), findsOneWidget);
    expect(find.text('The newest message.'), findsOneWidget);
    await tester.tap(find.text('Top of the last message'));
    await tester.pumpAndSettle();
    expect(prefs.openAt, OpenAt.lastMessage);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString(ChatPrefs.openAtKey), 'last_message');
    final again = ChatPrefs();
    await again.load();
    expect(again.openAt, OpenAt.lastMessage);
  });
}
