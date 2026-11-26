import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/demo/fixture.dart' as fx;
import 'package:porthole/widgets/composer.dart';
import 'package:porthole/widgets/images.dart';

import 'fakes.dart';

const key = 'claude:img1';

Map<String, dynamic> ev(int seq, String type, {String text = '', List<Map<String, dynamic>>? images}) => {
  'seq': seq,
  'type': type,
  'ts': DateTime.now().toUtc().toIso8601String(),
  'text': text,
  'images': ?images,
};

void main() {
  final png = fx.demoPng(width: 4, height: 4);

  test('bare image paths are found outside code and image syntax', () {
    const text = 'Saved to `/tmp/a.png` and ~/shots/b.JPG.\n\n![x](/tmp/c.png)\n\n```\n/tmp/d.png\n```\nnot rel/e.png or https://x.io/f.png';
    expect(bareImagePaths(text), ['/tmp/a.png', '~/shots/b.JPG']);
    expect(sniffImageType(png), 'image/png');
    expect(withAttachedImage('', '/p.png'), 'Attached image: /p.png');
    expect(withAttachedImage('look', '/p.png'), 'look\n\nAttached image: /p.png');
  });

  testWidgets('a user message shows its image and a placeholder for an omitted one', (tester) async {
    final c = FakeClient();
    c.transcripts[key] = [
      ev(
        1,
        'user',
        text: 'what is wrong here',
        images: [
          {'media_type': 'image/png', 'data': base64Encode(png), 'bytes': png.length},
          {'media_type': 'image/jpeg', 'omitted': true, 'bytes': 2411725},
        ],
      ),
    ];
    await pumpSession(tester, key, client: c);
    expect(find.text('what is wrong here'), findsOneWidget);
    expect(find.descendant(of: find.byType(ImageThumb), matching: find.byType(Image)), findsOneWidget);
    expect(find.text('image not shown (2.3 MB)'), findsOneWidget);
    await finish(tester, c);
  });

  testWidgets('an attached image is uploaded, then the message names its path', (tester) async {
    final c = await pumpSession(tester, key, sessions: [session(key, status: 'idle')]);
    final state = tester.state<ComposerState>(find.byType(Composer));
    state.attachForTest(PendingImage(bytes: Uint8List.fromList(png), name: 'shot.png', mediaType: 'image/png'));
    await tester.pump();
    expect(find.byKey(const ValueKey('pending-image')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'what is wrong here');

    // A refusal keeps the draft and the image.
    c.failPut = 'image too large';
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();
    expect(find.text('Image not sent: image too large'), findsOneWidget);
    expect(c.sent('session.input'), isEmpty);
    expect(find.byKey(const ValueKey('pending-image')), findsOneWidget);
    expect(find.text('what is wrong here'), findsOneWidget);

    c.failPut = null;
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final put = c.sent('file.put').last;
    expect(put['key'], key);
    expect(put['name'], 'shot.png');
    expect(put['media_type'], 'image/png');
    expect(base64Decode(put['data'] as String), png);
    expect(c.sent('session.input').single, {'key': key, 'text': 'what is wrong here\n\nAttached image: /work/.porthole/uploads/shot.png', 'enter': true});
    final order = [for (final r in c.requests) r.$1].where((t) => t == 'file.put' || t == 'session.input').toList();
    expect(order, ['file.put', 'file.put', 'session.input']);
    expect(find.byKey(const ValueKey('pending-image')), findsNothing);
    await finish(tester, c);
  });

  testWidgets('a markdown image path is fetched once and drawn', (tester) async {
    final c = FakeClient();
    c.files['/work/shot.png'] = ('image/png', png);
    c.transcripts[key] = [ev(1, 'assistant.text', text: 'Here it is:\n\n![Screenshot](/work/shot.png)\n\nAlso /work/missing.png')];
    await pumpSession(tester, key, client: c);
    await tester.pump();
    await tester.pump();
    expect(c.sent('file.get').where((p) => p['path'] == '/work/shot.png').toList(), [
      {'key': key, 'path': '/work/shot.png'},
    ]);
    expect(find.descendant(of: find.byType(RemoteImage), matching: find.byType(Image)), findsOneWidget);
    expect(find.text('/work/missing.png'), findsOneWidget);
    expect(find.text('not available'), findsOneWidget);
    // A rebuild does not fetch again.
    c.inject('session.upsert', session(key, status: 'idle'));
    await tester.pump();
    await tester.pump();
    expect(c.sent('file.get').where((p) => p['path'] == '/work/shot.png').length, 1);
    await finish(tester, c);
  });
}
