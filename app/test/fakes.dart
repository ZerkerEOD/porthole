/// Test doubles shared by the widget tests: a daemon record, session and
/// question payloads, and an in-process client.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/client.dart';
import 'package:porthole/models.dart';
import 'package:porthole/screens/session.dart';

DaemonInfo info() => DaemonInfo(id: 'm', name: 'desk', hosts: ['10.0.0.2'], port: 7433, fingerprint: 'fp', token: 't', deviceId: 'd');

Map<String, dynamic> session(String key, {bool pending = false, String pane = '%5', String tmux = 'ph-x', String title = '', String status = 'busy', Map<String, dynamic>? question}) => {
      'key': key,
      'id': key.split(':').last,
      'provider': 'claude',
      'title': title,
      'status': status,
      'running': true,
      'controllable': true,
      'pane_id': pane,
      'tmux_session': tmux,
      'pending': pending,
      'question': ?question,
    };

/// One or two questions; [preview] goes on the first option of the first.
Map<String, dynamic> questionJson({String id = 'toolu_q1', bool multi = false, bool two = false, String? preview}) => {
      'id': id,
      'questions': [
        {
          'question': 'Which transport should the relay use?',
          'header': 'Transport',
          'multiSelect': multi,
          'options': [
            {'label': 'WebSocket', 'description': 'Keeps one socket open', 'preview': ?preview},
            {'label': 'Polling', 'description': 'Simpler, more battery'},
          ],
        },
        if (two)
          {
            'question': 'Ship it today?',
            'header': 'Timing',
            'multiSelect': false,
            'options': [
              {'label': 'Yes', 'description': ''},
              {'label': 'No', 'description': ''},
            ],
          },
      ],
    };

/// An in-process client for widget tests: answers requests itself and
/// injects daemon frames through the real parser.
class FakeClient extends DaemonClient {
  FakeClient() : super(info()) {
    state = ConnState.connected;
  }
  final List<(String, Map<String, dynamic>)> requests = [];
  final Map<String, List<Map<String, dynamic>>> transcripts = {};
  String? refuseQuestion;
  String? failPane;
  /// When set, session.subscribe fails with this message.
  String? failSubscribe;

  void setState(ConnState s) {
    state = s;
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> request(String type, [Map<String, dynamic>? payload]) async {
    final p = payload ?? const <String, dynamic>{};
    requests.add((type, p));
    await null; // a microtask, so a plain pump() delivers the answer
    switch (type) {
      case 'session.subscribe':
        if (failSubscribe != null) throw StateError(failSubscribe!);
        return {'ok': true, 'data': {'events': transcripts[p['key']] ?? const [], 'has_more': false}};
      case 'pane.subscribe':
        if (failPane != null) throw StateError(failPane!);
        return {'ok': true, 'data': {'screen': {'lines': ['\$ waiting'], 'width': 80, 'height': 24}}};
      case 'agent.subscribe':
        return {'ok': true, 'data': {'key': p['key'], 'agent_id': p['agent_id'], 'events': const [], 'has_more': false}};
      case 'skills.list':
        return {'ok': true, 'data': const []};
      case 'question.answer':
        if (refuseQuestion != null) throw StateError(refuseQuestion!);
        return {'ok': true};
      default:
        return {'ok': true};
    }
  }

  void inject(String type, Map<String, dynamic> payload) => handleFrame({'type': type, 'payload': payload});
  List<Map<String, dynamic>> sent(String type) => [for (final r in requests) if (r.$1 == type) r.$2];
}

Future<FakeClient> pumpSession(WidgetTester tester, String key, {List<Map<String, dynamic>>? sessions, FakeClient? client}) async {
  final c = client ?? FakeClient();
  c.inject('hello', {'name': 'desk', 'version': '1', 'sessions': sessions ?? [session(key)]});
  await tester.pumpWidget(MaterialApp(home: SessionScreen(client: c, sessionKey: key)));
  await tester.pump();
  await tester.pump();
  return c;
}

/// Tears the screen down and cancels the client's timers (cache snapshot,
/// draft save), which would otherwise still be pending when the test ends.
Future<void> finish(WidgetTester tester, FakeClient c) async {
  await tester.pumpWidget(const SizedBox());
  c.close();
}
