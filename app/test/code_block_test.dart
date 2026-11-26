import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/widgets/event_tile.dart';

import 'fakes.dart';

const key = 'claude:cb1';

Map<String, dynamic> said(String text) => {'seq': 1, 'type': 'assistant.text', 'id': 'a1', 'text': text};

Future<FakeClient> pumpBlock(WidgetTester tester, String markdown, {String status = 'idle'}) {
  final c = FakeClient();
  c.transcripts[key] = [said(markdown)];
  return pumpSession(
    tester,
    key,
    sessions: [session(key, status: status)],
    client: c,
  );
}

IconButton button(WidgetTester tester, String k) => tester.widget<IconButton>(find.byKey(ValueKey(k)));

Future<void> settleSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  group('shell detection', () {
    const table = <(String, String, String?)>[
      ('sh', 'echo hi', 'echo hi'),
      ('bash', 'ls -la\n', 'ls -la'),
      ('zsh', 'print hi', 'print hi'),
      ('shell', 'whoami', 'whoami'),
      ('BASH', 'pwd', 'pwd'),
      ('dart', 'void main() {}', null),
      ('python', 'print(1)', null),
      ('', 'git status', 'git status'),
      ('', '\n  flutter test\n', 'flutter test'),
      ('', 'go test ./...', 'go test ./...'),
      ('', './build.sh --release', './build.sh --release'),
      ('', '~/bin/tool', '~/bin/tool'),
      ('', '/usr/bin/env', '/usr/bin/env'),
      ('', 'sudo systemctl restart porthole', 'sudo systemctl restart porthole'),
      ('', 'gopher := 1', null),
      ('', 'const x = 1;', null),
      ('', 'make', 'make'),
      ('', '', null),
      ('console', '\$ npm test\n> ok\n\$ npm run build', 'npm test\nnpm run build'),
      ('console', 'npm test', 'npm test'),
    ];
    for (final (lang, code, want) in table) {
      test('"$lang" ${code.replaceAll('\n', r'\n')}', () => expect(shellCommand(lang, code), want));
    }
  });

  group('! eligibility', () {
    test('simple lines join with &&', () => expect(bangCommand('cd app\n\nflutter test'), 'cd app && flutter test'));
    test('one line passes through', () => expect(bangCommand('git status'), 'git status'));
    test('a continuation refuses', () => expect(bangCommand('docker run \\\n  -it alpine'), isNull));
    test('a heredoc refuses', () => expect(bangCommand('cat <<EOF > x\nhi\nEOF'), isNull));
    test('a comment line refuses', () => expect(bangCommand('# build it\nmake'), isNull));
  });

  testWidgets('a non-shell block only has Copy', (tester) async {
    final c = await pumpBlock(tester, 'Here:\n\n```dart\nvoid main() {}\n```');
    expect(find.byKey(const ValueKey('copy-code')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-bang')), findsNothing);
    expect(find.byKey(const ValueKey('run-window')), findsNothing);
    await finish(tester, c);
  });

  testWidgets('a shell block has Copy and both run actions', (tester) async {
    final c = await pumpBlock(tester, 'Run:\n\n```sh\ngo test ./...\n```');
    expect(find.byKey(const ValueKey('copy-code')), findsOneWidget);
    expect(button(tester, 'run-bang').onPressed, isNotNull);
    expect(button(tester, 'run-window').onPressed, isNotNull);
    await finish(tester, c);
  });

  testWidgets('Run with ! is disabled while the session is busy', (tester) async {
    final c = await pumpBlock(tester, '```bash\nmake\n```', status: 'busy');
    expect(button(tester, 'run-bang').onPressed, isNull);
    expect(find.byTooltip('The session is busy; use Run in a window'), findsOneWidget);
    expect(button(tester, 'run-window').onPressed, isNotNull);
    await finish(tester, c);
  });

  testWidgets('a multi-line block offers only the window', (tester) async {
    final c = await pumpBlock(tester, '```bash\ncat <<EOF > notes\nhi\nEOF\n```');
    expect(find.byKey(const ValueKey('run-bang')), findsNothing);
    expect(find.byTooltip('multi-line: run in a window'), findsOneWidget);
    await finish(tester, c);
  });

  testWidgets('Run with ! confirms, then types !command into the session', (tester) async {
    final c = await pumpBlock(tester, '```sh\ncd app\nflutter test\n```');
    await tester.tap(find.byKey(const ValueKey('run-bang')));
    await settleSheet(tester);
    expect(find.text('!cd app && flutter test'), findsOneWidget);
    expect(find.textContaining('Typed into the session as'), findsOneWidget);
    expect(find.text('Send output to the session'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await settleSheet(tester);
    expect(c.sent('session.input'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('run-bang')));
    await settleSheet(tester);
    await tester.tap(find.byKey(const ValueKey('run-sheet-run')));
    await settleSheet(tester);
    final sent = c.sent('session.input').single;
    expect(sent['text'], '!cd app && flutter test');
    expect(sent['enter'], true);
    expect(sent['key'], key);
    await finish(tester, c);
  });

  testWidgets('Run in a window sends session.run with the feed switch', (tester) async {
    final c = await pumpBlock(tester, '```console\n\$ npm test\n```', status: 'busy');
    await tester.tap(find.byKey(const ValueKey('run-window')));
    await settleSheet(tester);
    expect(find.textContaining('Runs in a tmux window'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('run-sheet-run')));
    await settleSheet(tester);
    expect(c.sent('session.run').single, {'key': key, 'command': 'npm test', 'feed': true});
    await tester.tap(find.byKey(const ValueKey('run-window')));
    await settleSheet(tester);
    await tester.tap(find.byKey(const ValueKey('run-sheet-feed')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('run-sheet-run')));
    await settleSheet(tester);
    expect(c.sent('session.run').last['feed'], false);
    await finish(tester, c);
  });
}
