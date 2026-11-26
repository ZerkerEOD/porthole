import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/screens/agents.dart';

import 'fakes.dart';

Map<String, dynamic> agent(String id, {bool running = false, bool finished = true}) => {
      'id': id,
      'type': running ? 'general-purpose' : 'Explore',
      'description': running ? 'Add the cache step' : 'Find module downloads',
      'finished': finished,
      'running': running,
      'started_at': DateTime.now().subtract(const Duration(minutes: 3)).toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'turns': 3,
      'tool_uses': 4,
      'usage': {'input_tokens': 22000, 'output_tokens': 900, 'cache_read_tokens': 51000},
      'last_text': 'Editing ci.yml',
    };

void main() {
  testWidgets('the agents strip summarises and the sheet lists each agent', (tester) async {
    final c = await pumpSession(tester, 'claude:a1', sessions: [
      {...session('claude:a1'), 'agents': [agent('x', running: true, finished: false), agent('y')], 'usage': {'input_tokens': 182000, 'output_tokens': 9400}},
    ]);
    expect(find.text('2 agents · 1 working · 148k tokens'), findsOneWidget);
    expect(find.textContaining('191k tokens'), findsOneWidget, reason: 'the session total sits in the header row');
    await tester.tap(find.byKey(const ValueKey('agents-strip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Add the cache step'), findsOneWidget);
    expect(find.text('Find module downloads'), findsOneWidget);
    expect(find.textContaining('working · 3m'), findsOneWidget);
    expect(find.textContaining('finished · 3m'), findsOneWidget);
    await finish(tester, c);
  });

  testWidgets('the agent screen is read-only, tails events and hands a prefill back', (tester) async {
    final c = FakeClient();
    c.inject('hello', {'name': 'desk', 'version': '1', 'sessions': [{...session('claude:a2'), 'agents': [agent('x', running: true, finished: false)]}]});
    final s = c.sessions['claude:a2']!;
    String? prefill;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => TextButton(onPressed: () async {
      prefill = await Navigator.of(ctx).push<String>(MaterialPageRoute(builder: (_) => AgentScreen(client: c, sessionKey: 'claude:a2', agent: s.agents.first)));
    }, child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(c.sent('agent.subscribe').single['agent_id'], 'x');
    expect(find.byType(TextField), findsNothing, reason: 'no composer on an agent');
    c.inject('agent.events', {'key': 'claude:a2', 'agent_id': 'x', 'events': [{'seq': 1, 'type': 'system', 'level': 'info', 'id': 'e1', 'text': 'Reading ci.yml now', 'sidechain': true}]});
    await tester.pump(); // the stream delivers in a microtask
    await tester.pump();
    expect(find.text('Reading ci.yml now'), findsOneWidget);
    await tester.tap(find.text('Message the session'));
    await tester.pumpAndSettle();
    expect(prefill, startsWith('About the agent working on "Add the cache step"'));
    expect(c.sent('agent.unsubscribe').single['agent_id'], 'x');
    await finish(tester, c);
  });
}
