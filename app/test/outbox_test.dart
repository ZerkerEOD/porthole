import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/widgets/event_tile.dart';

import 'fakes.dart';

const key = 'claude:ob1';
const queuedLabel = 'Queued · sends when Claude finishes the current turn';

Map<String, dynamic> ev(int seq, String type, {String text = ''}) => {
  'seq': seq,
  'type': type,
  'ts': DateTime.now().toUtc().toIso8601String(),
  'id': 'e$seq',
  'text': text,
};

/// A client whose session.input fails while [failInput] is set and waits
/// for [hold] while that is set.
class FlakyClient extends FakeClient {
  String? failInput;
  Completer<void>? hold;
  @override
  Future<Map<String, dynamic>> request(String type, [Map<String, dynamic>? payload]) async {
    if (type == 'session.input' && hold != null) await hold!.future;
    if (type == 'session.input' && failInput != null) {
      requests.add((type, payload ?? const {}));
      await null;
      throw StateError(failInput!);
    }
    return super.request(type, payload);
  }
}

Future<void> send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byIcon(Icons.send));
  await tester.pump();
}

void main() {
  testWidgets('daemon-queued messages show as queued bubbles, in order, under the transcript', (tester) async {
    final c = FakeClient();
    c.transcripts[key] = [ev(1, 'user', text: 'start'), ev(2, 'assistant.text', text: 'On it.')];
    await pumpSession(tester, key, client: c, sessions: [{...session(key), 'queued': ['a', 'b']}]);
    expect(find.byType(PendingBubble), findsNWidgets(2));
    expect(find.text(queuedLabel), findsNWidgets(2));
    final lastEvent = tester.getTopLeft(find.text('On it.')).dy;
    final a = tester.getTopLeft(find.text('a')).dy;
    final b = tester.getTopLeft(find.text('b')).dy;
    expect(lastEvent, lessThan(a));
    expect(a, lessThan(b));

    // Run with ! waits for the queue and says why.
    c.inject('session.upsert', {...session(key, status: 'idle'), 'queued': ['a', 'b']});
    c.inject('event', {'key': key, 'events': [ev(3, 'assistant.text', text: 'Run:\n\n```sh\nmake\n```')]});
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('2 messages are queued ahead of this; wait for them to send, or use Run in a window.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('run-bang')));
    await tester.pump();
    expect(find.text('2 messages are queued ahead of this; wait for them to send, or use Run in a window.'), findsOneWidget);
    expect(c.sent('session.input'), isEmpty);

    c.inject('session.upsert', {...session(key, status: 'idle'), 'queued': const []});
    await tester.pump();
    expect(find.byType(PendingBubble), findsNothing);
    await finish(tester, c);
  });

  testWidgets('a sent message is Sending…, then Queued while busy, then gone when the transcript has it', (tester) async {
    final c = FlakyClient()..hold = Completer<void>();
    c.transcripts[key] = [ev(1, 'user', text: 'start')];
    await pumpSession(tester, key, client: c, sessions: [session(key, status: 'busy')]);
    await send(tester, 'also   fix the tests');
    await tester.pump();
    expect(find.text('Sending…'), findsOneWidget);
    // The composer keeps the text until the send answers; the bubble has it too.
    final bubble = find.descendant(of: find.byType(PendingBubble), matching: find.text('also   fix the tests'));
    expect(bubble, findsOneWidget);
    expect(tester.getTopLeft(bubble).dy, greaterThan(tester.getTopLeft(find.text('start')).dy));
    expect(tester.getTopLeft(find.text('Sending…')).dy, lessThan(tester.getTopLeft(find.text('Working…')).dy));

    c.hold!.complete();
    c.hold = null;
    await tester.pump();
    await tester.pump();
    expect(c.sent('session.input').single['text'], 'also   fix the tests');
    expect(find.text('Sending…'), findsNothing);
    expect(find.text(queuedLabel), findsOneWidget);
    expect(find.byType(PendingBubble), findsOneWidget);

    c.inject('event', {'key': key, 'events': [ev(2, 'user', text: 'also fix the tests\n')]});
    await tester.pump();
    await tester.pump();
    expect(find.byType(PendingBubble), findsNothing);
    expect(find.text(queuedLabel), findsNothing);
    await finish(tester, c);
  });

  testWidgets('a message sent while idle reads Sent; a ! command settles on its command event', (tester) async {
    final c = FakeClient();
    c.transcripts[key] = [ev(1, 'user', text: 'start')];
    await pumpSession(tester, key, client: c, sessions: [session(key, status: 'idle')]);
    await send(tester, '!git status');
    await tester.pump();
    await tester.pump();
    expect(find.text('Sent'), findsOneWidget);
    c.inject('event', {'key': key, 'events': [ev(2, 'command', text: 'git status')]});
    await tester.pump();
    await tester.pump();
    expect(find.byType(PendingBubble), findsNothing);
    await finish(tester, c);
  });

  testWidgets('a failed send says why and offers Retry and Dismiss', (tester) async {
    final c = FlakyClient()..failInput = 'pane is gone';
    c.transcripts[key] = [ev(1, 'user', text: 'start')];
    await pumpSession(tester, key, client: c, sessions: [session(key, status: 'idle')]);
    await send(tester, 'try this');
    await tester.pump();
    await tester.pump();
    expect(find.text('Could not send: pane is gone'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);

    c.failInput = null;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(c.sent('session.input').length, 2);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await finish(tester, c);
  });

  testWidgets('a message both sent from here and queued by the daemon shows once', (tester) async {
    final c = FakeClient();
    c.transcripts[key] = [ev(1, 'user', text: 'start')];
    await pumpSession(tester, key, client: c, sessions: [{...session(key, status: 'busy'), 'queued': ['first']}]);
    await send(tester, 'second  one');
    await tester.pump();
    await tester.pump();
    c.inject('session.upsert', {...session(key, status: 'busy'), 'queued': ['first', 'second one']});
    await tester.pump();
    expect(find.byType(PendingBubble), findsNWidgets(2));
    expect(find.text(queuedLabel), findsNWidgets(2));
    expect(tester.getTopLeft(find.text('first')).dy, lessThan(tester.getTopLeft(find.text('second  one')).dy));
    await finish(tester, c);
  });
}
