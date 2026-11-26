/// Shared transcript builders for the chat positioning tests.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/demo/fixture.dart' as fx;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'fakes.dart';

/// Paragraphs enough to make an event [lines] lines tall.
String body(int seq, int lines) => List.generate(lines, (i) => 'Event $seq line $i').join('\n\n');

Map<String, dynamic> ev(int seq, String type, {int lines = 0, String? mid, bool image = false}) {
  final png = fx.demoPng(width: 4, height: 4);
  return {
    'seq': seq,
    'type': type,
    'ts': DateTime.now().toUtc().toIso8601String(),
    'id': 'e$seq',
    'message_id': mid ?? 'm$seq',
    'text': body(seq, lines > 0 ? lines : 1 + seq % 4),
    if (image)
      'images': [
        {'media_type': 'image/png', 'data': base64Encode(png), 'bytes': png.length},
      ],
  };
}

/// Events [from]..[to]: user messages (every fifth with an image) and
/// replies of varying height.
List<Map<String, dynamic>> transcript(int from, int to) => [for (var i = from; i <= to; i++) i.isOdd ? ev(i, 'user', image: i % 5 == 0) : ev(i, 'assistant.text')];

ItemPosition? pos(ItemPositionsListener l, int index) => l.itemPositions.value.where((p) => p.index == index).firstOrNull;

/// The Working row of a chat of [events] events with nothing pending ends
/// at the bottom edge of the view.
bool atEnd(ItemPositionsListener l, int events) {
  final p = pos(l, events + 1);
  return p != null && (p.itemTrailingEdge - 1.0).abs() < 0.01;
}

/// Lets layout, position reports and re-anchoring run their course. The
/// screen's animated state ring never settles, so this pumps a fixed time.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Serves the transcript a page at a time: session.subscribe returns
/// [latest] with more before it, history.page the 150 events before
/// `before` (or nothing past seq 1 unless [endless]).
class PagedClient extends FakeClient {
  PagedClient(this.latest, {this.endless = false});
  final List<Map<String, dynamic>> latest;
  final bool endless;

  @override
  Future<Map<String, dynamic>> request(String type, [Map<String, dynamic>? payload]) async {
    final p = payload ?? const <String, dynamic>{};
    if (type == 'session.subscribe') {
      requests.add((type, p));
      await null;
      return {'ok': true, 'data': {'events': latest, 'has_more': true}};
    }
    if (type == 'history.page') {
      requests.add((type, p));
      await null;
      final before = p['before'] as int;
      final from = endless ? before - 150 : (before - 150).clamp(1, before);
      return {
        'ok': true,
        'data': {'events': endless ? [for (var i = from; i < before; i++) ev(i, 'user')] : transcript(from, before - 1), 'has_more': endless || from > 1},
      };
    }
    return super.request(type, payload);
  }
}
