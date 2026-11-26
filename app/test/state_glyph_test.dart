import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/client.dart';
import 'package:porthole/main.dart';
import 'package:porthole/models.dart';
import 'package:porthole/widgets/session_tile.dart';

import 'fakes.dart';

Session mk(Map<String, dynamic> extra) => Session.fromJson({...session('claude:x'), ...extra});

void main() {
  testWidgets('every session state has a label, a glyph and the right colour', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    final cases = <(Map<String, dynamic>, String, Color, bool)>[
      ({'status': 'busy'}, 'working', workingBlue, false),
      ({'status': 'busy', 'agents': [{'id': 'a', 'running': true}, {'id': 'b', 'running': false}]}, 'working · 1 agent', workingBlue, false),
      ({'status': 'waiting_input', 'question': {'id': 'q', 'questions': [{'question': 'Which?', 'options': [{'label': 'A'}]}]}}, 'needs your answer', attentionAmber, true),
      ({'status': 'waiting_input'}, 'waiting for you', attentionAmber, true),
      ({'status': 'waiting_permission'}, 'needs approval', attentionAmber, true),
      ({'status': 'idle'}, 'ready', readyGreen, false),
      ({'status': 'exited', 'running': false}, 'ended', Theme.of(ctx).colorScheme.outline, false),
      ({'status': 'busy', 'pending': true}, 'starting', Theme.of(ctx).colorScheme.outline, false),
    ];
    for (final (extra, label, color, attention) in cases) {
      final st = sessionState(ctx, mk(extra));
      expect(st.label, label);
      expect(st.color, color, reason: label);
      expect(st.attention, attention, reason: label);
    }
    final plan = mk({'status': 'waiting_permission'})..planPending = true;
    expect(sessionState(ctx, plan).label, 'plan ready to approve');
    expect(sessionStateLabel(ctx, mk({'status': 'idle', 'controllable': false})), 'ready · read-only');
    expect(sessionStateLabel(ctx, mk({'status': 'idle', 'last_denied': {'tool': 'Bash', 'at': DateTime.now().toUtc().toIso8601String()}})), 'ready · blocked Bash');
    expect(sessionStateLabel(ctx, mk({'status': 'busy', '_stale': true, 'updated_at': DateTime.now().subtract(const Duration(hours: 2)).toIso8601String()})), 'last seen 2h ago');
    // Nothing paints working in crimson any more.
    expect(statusColor(ctx, 'busy'), isNot(crimsonBright));
  });

  testWidgets('the session tile shows the state label first and an amber edge when it needs you', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      SessionTile(s: mk({'status': 'waiting_permission', 'repo': 'porthole'}), onTap: () {}),
      SessionTile(s: mk({'status': 'busy', 'repo': 'porthole'}), onTap: () {}),
    ]))));
    expect(find.textContaining('needs approval · porthole'), findsOneWidget);
    expect(find.textContaining('working · porthole'), findsOneWidget);
    expect(find.byType(DecoratedBox), findsWidgets);
    expect(find.byIcon(Icons.security), findsOneWidget);
  });

  testWidgets('the machine chip says only the state, never an address', (tester) async {
    final c = FakeClient();
    c.info.hosts = ['10.0.0.2', 'fd00::2'];
    c.info.lastHost = '10.0.0.2';
    c.hostStatus['fd00::2'] = HostStatus(reachable: false, checkedAt: DateTime.now(), error: 'timed out');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MachineStateChip(client: c))));
    expect(find.text('online'), findsOneWidget);
    expect(find.textContaining('fd00'), findsNothing);
    expect(find.textContaining('unreachable'), findsNothing);
    expect(find.byIcon(Icons.link), findsOneWidget);
    c.close();
  });

  testWidgets('the legend sheet lists both vocabularies', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showLegendSheet(c), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    // The sheet carries an animated ring, so settle by hand.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Needs approval'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Pair again'), 80, scrollable: find.byType(Scrollable).last);
    expect(find.text('Pair again'), findsOneWidget);
    expect(find.text('Unreachable'), findsOneWidget);
  });
}
