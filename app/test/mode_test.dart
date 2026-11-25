import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  testWidgets('the header chip shows the mode and the sheet switches it', (tester) async {
    final c = await pumpSession(tester, 'claude:m1', sessions: [
      {...session('claude:m1', status: 'idle'), 'permission_mode': 'plan'},
    ]);
    expect(find.text('⏸ Plan'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mode-button')));
    await tester.pumpAndSettle();
    expect(find.text('Permission mode'), findsOneWidget);
    expect(find.text('⏵⏵ Accept edits'), findsOneWidget);
    expect(find.text('⏵⏵ Bypass'), findsNothing, reason: 'bypass is only offered when the session started with it');
    expect(find.text("⏵⏵ Don't ask"), findsNothing);
    await tester.tap(find.text('⏵⏵ Accept edits'));
    await tester.pumpAndSettle();
    final sent = c.sent('session.mode');
    expect(sent, hasLength(1));
    expect(sent.single, {'key': 'claude:m1', 'mode': 'acceptEdits'});
    c.inject('session.upsert', {...session('claude:m1', status: 'idle'), 'permission_mode': 'acceptEdits'});
    await tester.pump();
    expect(find.text('⏵⏵ Edits'), findsOneWidget);
    await finish(tester, c);
  });

  testWidgets('with a prompt open the chip explains instead of switching', (tester) async {
    final c = await pumpSession(tester, 'claude:m2', sessions: [
      {...session('claude:m2', status: 'waiting_permission'), 'permission_mode': 'default'},
    ]);
    c.inject('permission.pending', {'id': 'p1', 'session_key': 'claude:m2', 'tool_name': 'Bash', 'tool_input': {'command': 'ls'}, 'created_at': '2026-01-01T00:00:00Z', 'expires_at': '2026-01-01T00:01:00Z'});
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mode-button')));
    await tester.pumpAndSettle();
    expect(find.text('Answer the open prompt first, then change the mode.'), findsOneWidget);
    expect(c.sent('session.mode'), isEmpty);
    await finish(tester, c);
  });

  testWidgets('a recovered prompt shows the CLI options and answers by index', (tester) async {
    final c = await pumpSession(tester, 'claude:m3', sessions: [
      {...session('claude:m3', status: 'waiting_permission'), 'permission_mode': 'default'},
    ]);
    c.inject('permission.pending', {
      'id': 'screen:claude:m3:abc',
      'session_key': 'claude:m3',
      'tool_name': 'Bash command',
      'recovered': true,
      'description': 'Create empty probe1.txt file in the repo',
      'detail': 'touch probe1.txt',
      'prompt': 'Do you want to proceed?',
      'options': ['Yes', 'Yes, and always allow access to /repo from this project', 'Yes, and switch to auto mode', 'No'],
      'created_at': '2026-01-01T00:00:00Z',
    });
    await tester.pump();
    expect(find.text('Bash command'), findsOneWidget);
    expect(find.text('Do you want to proceed?'), findsOneWidget);
    expect(find.text('touch probe1.txt'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Yes'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'No'));
    await tester.pump();
    expect(c.sent('permission.answer').single, {'id': 'screen:claude:m3:abc', 'option': 3});
    await finish(tester, c);
  });
}
