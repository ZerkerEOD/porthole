import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:porthole/attention.dart';
import 'package:porthole/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// A watcher in the background whose notices land in [shown].
  (AttentionWatcher, List<(String, String)>) watcher() {
    final shown = <(String, String)>[];
    final w = AttentionWatcher(AppStore(), show: ({required id, required title, required body, sessionKey, urgent = false}) => shown.add((id, body)))..foreground = false;
    return (w, shown);
  }

  testWidgets('a live alert goes out on the change into waiting, once, for sessions opened here', (tester) async {
    final (w, shown) = watcher();
    final c = FakeClient();
    c.inject('hello', {'name': 'desk', 'version': '1', 'sessions': [session('claude:a'), session('claude:b')]});
    await c.subscribe('claude:a');
    expect(c.isOpened('claude:a'), isTrue);
    expect(c.isOpened('claude:b'), isFalse);
    w.check(c);
    expect(shown, isEmpty);

    c.inject('session.upsert', {...session('claude:a', status: 'waiting_input'), 'updated_at': '2026-11-24T10:00:00Z'});
    c.inject('session.upsert', session('claude:b', status: 'waiting_input'));
    w.check(c);
    expect(shown, [('claude:a', 'Waiting for your input')], reason: 'claude:b was never opened here');

    // A refresh that only moves updated_at is not a new alert.
    c.inject('session.upsert', {...session('claude:a', status: 'waiting_input'), 'updated_at': '2026-11-24T10:05:00Z'});
    w.check(c);
    w.check(c);
    expect(shown, hasLength(1));

    // Busy again, then waiting again: a second alert under the same id.
    c.inject('session.upsert', session('claude:a', status: 'busy'));
    w.check(c);
    c.inject('session.upsert', session('claude:a', status: 'waiting_permission'));
    w.check(c);
    expect(shown, [('claude:a', 'Waiting for your input'), ('claude:a', 'Waiting for a permission approval')]);

    // Started from this phone counts as opened.
    c.inject('session.upsert', {...session('claude:c'), 'spawned': true});
    w.check(c);
    c.inject('session.upsert', {...session('claude:c', status: 'waiting_input'), 'spawned': true});
    w.check(c);
    expect(shown.last, ('claude:c', 'Waiting for your input'));

    // Muted machines and the switch being off stay quiet.
    w.enabled = false;
    c.inject('session.upsert', session('claude:a', status: 'busy'));
    w.check(c);
    c.inject('session.upsert', session('claude:a', status: 'waiting_input'));
    w.check(c);
    expect(shown, hasLength(3));

    await tester.pumpWidget(const SizedBox());
    c.close();
  });

  testWidgets('the opened mark follows session.replaced and survives a restart', (tester) async {
    final (w, shown) = watcher();
    final c = FakeClient();
    c.inject('hello', {'name': 'desk', 'version': '1', 'sessions': [session('claude:pending:%5', pending: true)]});
    await c.subscribe('claude:pending:%5');
    c.inject('session.upsert', session('claude:real'));
    c.inject('session.replaced', {'old': 'claude:pending:%5', 'new': 'claude:real'});
    c.inject('session.removed', {'key': 'claude:pending:%5'});
    expect(c.isOpened('claude:real'), isTrue);
    expect(c.isOpened('claude:pending:%5'), isFalse);
    w.check(c);
    c.inject('session.upsert', session('claude:real', status: 'waiting_input'));
    w.check(c);
    expect(shown, [('claude:real', 'Waiting for your input')]);

    await tester.pump(const Duration(seconds: 6)); // the cache snapshot debounce
    final c2 = FakeClient();
    await c2.restored;
    expect(c2.isOpened('claude:real'), isTrue);
    c.close();
    c2.close();
  });
}
