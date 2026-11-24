/// Turns live daemon state into local notifications while the app is
/// connected (foreground, or background on Android with keep-alive).
library;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'client.dart';
import 'notifications.dart';
import 'store.dart';

/// The shape of [Notifier.show]; replaced in tests.
typedef NotifyFn = void Function({required String id, required String title, required String body, String? sessionKey, bool urgent});

class AttentionWatcher with WidgetsBindingObserver {
  AttentionWatcher(this.store, {NotifyFn? show}) : _show = show;
  final AppStore store;
  final NotifyFn? _show;
  /// Permission ids already announced.
  final Set<String> _seen = {};
  /// The last status seen per `'<machine>:<session key>'`, so a notice goes
  /// out on the change into a waiting state and not on every refresh.
  final Map<String, String> _lastStatus = {};
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

  @visibleForTesting
  set foreground(bool v) => _foreground = v;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed && !_foreground) store.wake();
    _foreground = resumed;
  }

  void _rewire() {
    for (final c in store.clients.values) {
      if (_subs.containsKey(c.info.id)) continue;
      void listener() => check(c);
      c.addListener(listener);
      _subs[c.info.id] = listener;
    }
  }

  /// Looks at [c]'s current state and raises what is new: a permission
  /// prompt once per request, and a session's change into a waiting state,
  /// for sessions started or opened from this phone.
  @visibleForTesting
  void check(DaemonClient c) {
    final quiet = !enabled || c.info.muted;
    for (final p in c.permissions.values) {
      final k = 'perm:${p.id}';
      if (_seen.add(k) && !quiet) {
        final s = c.sessions[p.sessionKey];
        _notify(k, '${s?.displayTitle ?? 'Session'} · ${c.info.displayName}', 'Wants to run ${p.toolName}', p.sessionKey, true);
      }
    }
    for (final s in c.sessions.values) {
      final k = '${c.info.id}:${s.key}';
      final prev = _lastStatus[k];
      _lastStatus[k] = s.status;
      if (quiet || !s.running || prev == s.status) continue;
      if (!s.spawned && !c.isOpened(s.key)) continue;
      switch (s.status) {
        case 'waiting_input':
          _notify(s.key, '${s.displayTitle} · ${c.info.displayName}', 'Waiting for your input', s.key, true);
        case 'waiting_permission':
          // A hook-backed prompt is announced by the permission path above.
          if (c.permissions.values.any((p) => p.sessionKey == s.key)) continue;
          _notify(s.key, '${s.displayTitle} · ${c.info.displayName}', 'Waiting for a permission approval', s.key, true);
      }
    }
    if (_seen.length > 500) _seen.clear();
    if (_lastStatus.length > 500) {
      final prefix = '${c.info.id}:';
      _lastStatus.removeWhere((k, _) => k.startsWith(prefix) && !c.sessions.containsKey(k.substring(prefix.length)));
    }
  }

  void _notify(String id, String title, String body, String sessionKey, bool urgent) {
    // In the foreground the UI already shows banners; only notify when the
    // app is not visible.
    if (_foreground) return;
    (_show ?? Notifier.instance.show)(id: id, title: title, body: body, sessionKey: sessionKey, urgent: urgent);
  }
}
