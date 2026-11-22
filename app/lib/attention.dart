/// Turns live daemon state into local notifications while the app is
/// connected (foreground, or background on Android with keep-alive).
library;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'client.dart';
import 'notifications.dart';
import 'store.dart';

class AttentionWatcher with WidgetsBindingObserver {
  AttentionWatcher(this.store);
  final AppStore store;
  final Set<String> _seen = {};
  bool enabled = true;
  bool _foreground = true;
  final Map<String, VoidCallback> _subs = {};

  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool('notify.live') ?? true;
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_rewire);
    _rewire();
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notify.live', v);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed && !_foreground) store.wake();
    _foreground = resumed;
  }

  void _rewire() {
    for (final c in store.clients.values) {
      if (_subs.containsKey(c.info.id)) continue;
      void listener() => _check(c);
      c.addListener(listener);
      _subs[c.info.id] = listener;
    }
  }

  void _check(DaemonClient c) {
    if (!enabled || c.info.muted) return;
    for (final p in c.permissions.values) {
      final k = 'perm:${p.id}';
      if (_seen.add(k)) {
        final s = c.sessions[p.sessionKey];
        _notify(k, '${s?.displayTitle ?? 'Session'} · ${c.info.displayName}', 'Wants to run ${p.toolName}', p.sessionKey, true);
      }
    }
    for (final s in c.sessions.values) {
      if (!s.running) continue;
      if (s.status == 'waiting_input') {
        final k = 'input:${s.key}:${s.updatedAt?.millisecondsSinceEpoch ?? 0}';
        if (_seen.add(k)) _notify(k, '${s.displayTitle} · ${c.info.displayName}', 'Waiting for your input', s.key, true);
      }
    }
    if (_seen.length > 500) _seen.clear();
  }

  void _notify(String id, String title, String body, String sessionKey, bool urgent) {
    // In the foreground the UI already shows banners; only notify when the
    // app is not visible.
    if (_foreground) return;
    Notifier.instance.show(id: id, title: title, body: body, sessionKey: sessionKey, urgent: urgent);
  }
}
