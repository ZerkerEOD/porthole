import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/models.dart';
import 'package:porthole/widgets/event_tile.dart';

Event command(String text, {String stdout = '', String stderr = '', String source = 'bang'}) => Event.fromJson({
  'seq': 1,
  'type': 'command',
  'id': 'c1',
  'text': text,
  'meta': {'source': source, 'stdout': stdout, 'stderr': stderr},
});

Future<void> pumpTile(WidgetTester tester, Event e) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: EventTile(event: e)),
    ),
  ),
);

void main() {
  testWidgets('a command event shows the command, stdout and stderr', (tester) async {
    await pumpTile(tester, command('git status', stdout: 'On branch main\nnothing to commit', stderr: 'warning: something'));
    expect(find.text('\$ git status'), findsOneWidget);
    expect(find.text('On branch main\nnothing to commit'), findsOneWidget);
    expect(find.text('warning: something'), findsOneWidget);
    expect(find.text('ran with !'), findsOneWidget);
    final err = tester.widget<SelectableText>(find.widgetWithText(SelectableText, 'warning: something'));
    final ctx = tester.element(find.text('warning: something'));
    expect(err.style?.color, Theme.of(ctx).colorScheme.error);
  });

  testWidgets('an empty command reads as command output with a slash tag', (tester) async {
    await pumpTile(tester, command('', stdout: 'Total cost: \$0.12', source: 'slash'));
    expect(find.text('Command output'), findsOneWidget);
    expect(find.textContaining('\$ '), findsNothing, reason: 'no command line without a command');
    expect(find.text('slash command'), findsOneWidget);
  });

  testWidgets('output past 20 lines collapses and expands', (tester) async {
    final out = [for (var i = 1; i <= 25; i++) 'line $i'].join('\n');
    await pumpTile(tester, command('seq 25', stdout: out));
    expect(find.text('Show all 25 lines'), findsOneWidget);
    expect(find.textContaining('line 20'), findsOneWidget);
    expect(find.textContaining('line 21'), findsNothing);
    await tester.tap(find.text('Show all 25 lines'));
    await tester.pump();
    expect(find.textContaining('line 25'), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);
    await tester.tap(find.text('Show less'));
    await tester.pump();
    expect(find.textContaining('line 25'), findsNothing);
  });

  testWidgets('short output has no collapse control', (tester) async {
    await pumpTile(tester, command('ls', stdout: 'a\nb'));
    expect(find.textContaining('Show all'), findsNothing);
  });
}
