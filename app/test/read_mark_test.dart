import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/client.dart';
import 'package:porthole/prefs.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_helpers.dart';
import 'fakes.dart';

const key = 'claude:read1';

Future<Map<String, dynamic>?> storedMark() async {
  final raw = (await SharedPreferences.getInstance()).getString('reads.m');
  if (raw == null) return null;
  return (jsonDecode(raw) as Map<String, dynamic>)[key] as Map<String, dynamic>?;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('scrolling up and leaving stores the first visible event', (tester) async {
    final l = ItemPositionsListener.create();
    final c = FakeClient()..transcripts[key] = transcript(1, 60);
    await pumpSession(tester, key, client: c, prefs: ChatPrefs(), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, 500));
    await settle(tester);
    expect(atEnd(l, 60), isFalse);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    final top = l.itemPositions.value.where((p) => p.index >= 1 && p.index <= 60 && p.itemTrailingEdge > 0).reduce((a, b) => a.index < b.index ? a : b);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    final m = await storedMark();
    expect(m, isNotNull);
    expect(m!['seq'], top.index);
    expect(m['id'], 'e${top.index}');
    expect((m['align'] as num).toDouble(), closeTo(top.itemLeadingEdge, 0.01));
    expect(m['newest_seq'], 60);
    expect(DateTime.tryParse(m['at'] as String), isNotNull);

    // A new client on the same machine reads it back.
    final again = FakeClient();
    await again.restored;
    expect(again.readMarks[key]!.seq, top.index);
    again.close();
    c.close();
  });

  testWidgets('leaving at the bottom stores the last event', (tester) async {
    final l = ItemPositionsListener.create();
    final c = FakeClient()..transcripts[key] = transcript(1, 60);
    await pumpSession(tester, key, client: c, prefs: ChatPrefs(), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    expect(atEnd(l, 60), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    final m = await storedMark();
    expect(m!['seq'], 60);
    expect(m['align'], 0);
    c.close();
  });

  testWidgets('the Go to bottom button scrolls back and follows again', (tester) async {
    final l = ItemPositionsListener.create();
    final c = FakeClient()..transcripts[key] = transcript(1, 60);
    await pumpSession(tester, key, client: c, prefs: ChatPrefs(), positions: l, sessions: [session(key, status: 'idle')]);
    await settle(tester);
    await tester.drag(find.byType(ScrollablePositionedList), const Offset(0, 2000));
    await settle(tester);
    expect(atEnd(l, 60), isFalse);
    // Not following: a new event does not move the list.
    c.inject('event', {
      'key': key,
      'events': [ev(61, 'user')],
    });
    await settle(tester);
    expect(atEnd(l, 61), isFalse);
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await settle(tester);
    expect(atEnd(l, 61), isTrue);
    expect(find.byIcon(Icons.arrow_downward), findsNothing);
    c.inject('event', {
      'key': key,
      'events': [ev(62, 'assistant.text', lines: 8)],
    });
    await settle(tester);
    expect(atEnd(l, 62), isTrue);
    await finish(tester, c);
  });

  test('marks older than 7 days are dropped and at most 200 are kept', () async {
    final old = DateTime.now().subtract(const Duration(days: 9));
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'reads.m': jsonEncode({
        'stale': ReadMark(seq: 1, id: 'a', align: 0, newestSeq: 1, at: old).toJson(),
        for (var i = 0; i < 210; i++) 's$i': ReadMark(seq: i, id: 'e$i', align: 0, newestSeq: i, at: now.subtract(Duration(minutes: 300 - i))).toJson(),
      }),
    });
    final c = FakeClient();
    await c.restored;
    expect(c.readMarks.containsKey('stale'), isFalse);
    expect(c.readMarks.length, 200);
    expect(c.readMarks.containsKey('s0'), isFalse);
    expect(c.readMarks.containsKey('s209'), isTrue);
    c.close();
  });
}
