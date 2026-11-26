/// The built-in demo machines: a DaemonClient with no transport. It answers
/// every request from the scripted fixture (keyed by the machine's local id,
/// so demo-box and build-box differ) and injects frames through the same
/// parser a real machine's frames go through, so every screen behaves exactly
/// as it does against a daemon. Used by store reviewers, screenshots and
/// anyone who wants to look around before pairing.
library;

import 'dart:async';
import 'dart:convert';

import '../client.dart';
import 'fixture.dart' as fx;

class DemoDaemonClient extends DaemonClient {
  DemoDaemonClient(super.info);

  @override
  bool get isDemo => true;

  /// How long after hello demo-box raises its permission prompt. The
  /// screenshot flow sets this high and calls [askPermission] itself so the
  /// prompt lands on the screen it wants.
  static Duration permissionDelay = const Duration(seconds: 4);

  /// True for demo-box, the machine that carries the scripted prompt.
  bool get _primary => info.id == fx.demoDaemonId;

  bool _done = false;
  final List<Timer> _timers = [];
  final Map<String, Timer> _tickers = {};
  final Map<String, Map<String, dynamic>> _json = {};
  final Map<String, List<Map<String, dynamic>>> _events = {};
  final Map<String, int> _seq = {};
  final Map<String, String> _typed = {};
  int _tick = 0;
  int _spawned = 0;
  int _runs = 0;
  final Set<String> _stoppedRuns = {};
  bool _permissionShown = false;
  bool _codexAsked = false;

  void _later(Duration d, void Function() f) {
    final t = Timer(d, () {
      if (!_done) f();
    });
    _timers.add(t);
  }

  void _push(String type, Map<String, dynamic> payload) {
    if (_done) return;
    handleFrame({'type': type, 'payload': payload});
  }

  void _upsert(String key, Map<String, dynamic> patch) {
    final j = _json[key];
    if (j == null) return;
    j.addAll(patch);
    j['updated_at'] = DateTime.now().toUtc().toIso8601String();
    _push('session.upsert', Map<String, dynamic>.from(j));
  }

  void _append(String key, String type, {String? text, Map<String, dynamic>? tool, Map<String, dynamic>? result, String? level, Map<String, dynamic>? meta}) {
    final seq = (_seq[key] ?? 0) + 1;
    _seq[key] = seq;
    final ev = <String, dynamic>{
      'seq': seq,
      'type': type,
      'ts': DateTime.now().toUtc().toIso8601String(),
      'id': 'ev-$key-$seq',
      'text': ?text,
      'tool': ?tool,
      'result': ?result,
      'level': ?level,
      'meta': ?meta,
    };
    (_events[key] ??= []).add(ev);
    _push('event', {'key': key, 'events': [ev]});
  }

  bool _busy(String key) => _json[key]?['status'] == 'busy';

  void _pane(String key) {
    _push('pane.snapshot', {'key': key, 'screen': fx.screen(key, tick: _tick, busy: _busy(key), typed: _typed[key] ?? '')});
  }

  @override
  Future<void> connect({bool manual = false}) async {
    if (_done) return;
    if (!manual && !info.autoConnect) return;
    if (state == ConnState.connecting || state == ConnState.connected) return;
    state = ConnState.connecting;
    notifyListeners();
    _later(const Duration(milliseconds: 300), () {
      final h = fx.hello(info.id);
      for (final s in (h['sessions'] as List)) {
        final m = Map<String, dynamic>.from(s as Map);
        _json[m['key'] as String] = m;
        _events[m['key'] as String] = fx.transcript(m['key'] as String).map((e) => Map<String, dynamic>.from(e)).toList();
        _seq[m['key'] as String] = _events[m['key'] as String]!.length;
      }
      state = ConnState.connected;
      lastSeen = DateTime.now();
      lastError = null;
      _push('hello', h);
      if (_primary && !_permissionShown) _later(permissionDelay, askPermission);
    });
  }

  /// Raises demo-box's one permission prompt now (no-op once shown).
  void askPermission() {
    if (_done || !_primary || _permissionShown) return;
    _permissionShown = true;
    _push('permission.pending', fx.permissionRequest());
    _upsert(fx.claude1, {'status': 'waiting_permission'});
  }

  void _askCodex() {
    if (_codexAsked) return;
    _codexAsked = true;
    _append(fx.codex1, 'assistant.text', text: 'Shall I apply the fix to `_onClosed` and re-run the loop?');
    _upsert(fx.codex1, {'status': 'waiting_input'});
  }

  @override
  Future<Map<String, dynamic>> request(String type, [Map<String, dynamic>? payload]) async {
    if (_done) throw StateError('Not connected');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (_done) throw StateError('Not connected');
    final p = payload ?? const <String, dynamic>{};
    final key = p['key'] as String? ?? '';
    switch (type) {
      case 'session.list':
        return {'ok': true, 'data': _json.values.map((j) => Map<String, dynamic>.from(j)).toList()};
      case 'session.subscribe':
        return {'ok': true, 'data': {'key': key, 'events': _events[key] ?? const [], 'has_more': false}};
      case 'history.page':
        return {'ok': true, 'data': {'key': key, 'events': const [], 'has_more': false}};
      case 'session.input':
        final text = (p['text'] as String? ?? '').trim();
        if (p['enter'] == false) {
          _typed[key] = '${_typed[key] ?? ''}$text';
          _pane(key);
          return {'ok': true};
        }
        _typed[key] = '';
        if (text.startsWith('!')) {
          // A `!` command: the CLI runs it and records its output.
          final cmd = text.substring(1).trim();
          final out = fx.runTail(cmd).last;
          _append(key, 'command', text: cmd, meta: {'source': 'bang', 'stdout': out, 'stderr': ''});
          _pane(key);
          return {'ok': true};
        }
        if (text.isNotEmpty) _append(key, 'user', text: text);
        _upsert(key, {'status': 'busy'});
        _pane(key);
        _later(const Duration(milliseconds: 1500), () {
          _append(key, 'assistant.text', text: fx.cannedReply(text));
          _upsert(key, {'status': 'idle', 'queued': const <String>[]});
          _pane(key);
        });
        return {'ok': true};
      case 'session.run':
        final cmd = (p['command'] as String? ?? '').trim();
        final feed = p['feed'] != false;
        final id = 'run-${++_runs}';
        final started = DateTime.now().toUtc().toIso8601String();
        final tail = fx.runTail(cmd);
        Map<String, dynamic> run(String state, String t, {int? exit, bool fed = false}) => {
          'key': key,
          'id': id,
          'command': cmd,
          'state': state,
          'exit': ?exit,
          'tail': t,
          'started_at': started,
          if (state != 'running') 'ended_at': DateTime.now().toUtc().toIso8601String(),
          'fed': fed,
          'queued': false,
          'pane_id': '%${40 + _runs}',
          'device': 'phone',
        };
        _later(const Duration(milliseconds: 200), () {
          if (!_stoppedRuns.contains(id)) _push('run.update', run('running', tail[0]));
        });
        _later(const Duration(milliseconds: 1500), () {
          if (!_stoppedRuns.contains(id)) _push('run.update', run('running', tail[1]));
        });
        _later(const Duration(seconds: 3), () {
          if (_stoppedRuns.contains(id)) return;
          _push('run.update', run('done', tail[2], exit: 0, fed: feed));
          if (feed) _append(key, 'user', text: 'I ran this in a separate window: `$cmd`\n\n```\n${tail[2]}\n```');
        });
        return {
          'ok': true,
          'data': {'id': id},
        };
      case 'run.stop':
        final id = p['id'] as String? ?? '';
        final r = runs[id];
        _stoppedRuns.add(id);
        if (r != null && !r.isDone) {
          _push('run.update', {
            'key': r.key,
            'id': id,
            'command': r.command,
            'state': 'stopped',
            'tail': r.tail,
            'started_at': r.startedAt?.toIso8601String(),
            'ended_at': DateTime.now().toUtc().toIso8601String(),
            'fed': false,
            'queued': false,
            'pane_id': r.paneId,
            'device': r.device,
          });
        }
        return {'ok': true};
      case 'run.dismiss':
        return {'ok': true};
      case 'run.log':
        final r = runs[p['id'] as String? ?? ''];
        return {
          'ok': true,
          'data': {'id': p['id'], 'text': r == null ? '' : fx.runTail(r.command).last, 'truncated': false},
        };
      case 'file.get':
        if (p['path'] != fx.demoShotPath) throw StateError('Not an image under the session folder');
        final png = fx.demoPng();
        return {
          'ok': true,
          'data': {'media_type': 'image/png', 'data': base64Encode(png), 'bytes': png.length},
        };
      case 'file.put':
        final name = (p['name'] as String? ?? 'image.png').split('/').last;
        final dir = _json[key]?['cwd'] as String? ?? '/home/dev/src/porthole';
        return {
          'ok': true,
          'data': {'path': '$dir/.porthole/uploads/$name'},
        };
      case 'session.keys':
        final keys = (p['keys'] as List? ?? const []).cast<String>();
        if (keys.contains('Escape') && _busy(key)) {
          _append(key, 'system', text: 'Interrupted', level: 'info');
          _upsert(key, {'status': 'idle'});
          _pane(key);
        }
        return {'ok': true};
      case 'permission.answer':
        final id = p['id'] as String? ?? '';
        final allow = p['behavior'] == 'allow';
        _push('permission.resolved', {'id': id, 'behavior': allow ? 'allow' : 'deny'});
        if (allow) {
          _append(fx.claude1, 'tool.use', tool: {'id': 'tu_3', 'name': 'Bash', 'input': {'command': 'go test ./internal/pair/...'}});
          _upsert(fx.claude1, {'status': 'busy'});
          _later(const Duration(seconds: 2), () {
            _append(fx.claude1, 'tool.result', result: {'tool_use_id': 'tu_3', 'is_error': false}, text: 'ok  porthole/daemon/internal/pair  0.412s');
            _append(fx.claude1, 'assistant.text', text: 'Tests pass, including the new lockout case. The change is ready to commit when you are.');
            _upsert(fx.claude1, {'status': 'idle'});
            _pane(fx.claude1);
          });
        } else {
          _append(fx.claude1, 'system', text: 'Permission denied for Bash', level: 'info');
          _append(fx.claude1, 'assistant.text', text: 'Understood, I will not run the tests. Tell me when you want to continue.');
          _upsert(fx.claude1, {'status': 'idle'});
        }
        _pane(fx.claude1);
        _later(const Duration(seconds: 45), _askCodex);
        return {'ok': true};
      case 'agent.subscribe':
        final evs = fx.agentTranscript(p['agent_id'] as String);
        return {'ok': true, 'data': {'key': p['key'], 'agent_id': p['agent_id'], 'events': evs, 'has_more': false}};
      case 'agent.unsubscribe':
        return {'ok': true};
      case 'session.mode':
        final key = p['key'] as String;
        final mode = p['mode'] as String;
        // Bypass is not in the demo machines' cycle, like a real account without it.
        if (mode == 'bypassPermissions') throw StateError('mode bypassPermissions is not in this session\'s cycle (stopped at ${sessions[key]?.permissionMode ?? 'default'})');
        _upsert(key, {'permission_mode': mode});
        return {'ok': true, 'data': {'key': key, 'mode': mode}};
      case 'question.answer':
        final answers = (p['answers'] as List?) ?? const [];
        final first = answers.isEmpty ? const <String, dynamic>{} : Map<String, dynamic>.from(answers.first as Map);
        final labels = ['Three-segment button', 'Keep the radios', 'Dropdown'];
        final idx = first['index'];
        final chosen = first['text'] as String? ?? (idx is int && idx >= 0 && idx < labels.length ? labels[idx] : labels.first);
        _append(fx.claude2, 'tool.result', result: {'tool_use_id': 'tu_q1', 'is_error': false}, text: 'Your questions have been answered: "The theme picker has three options and SegmentedButton fits two. How should it look?"="$chosen". You can now continue with these answers in mind.');
        _upsert(fx.claude2, {'status': 'busy', 'question': null});
        _later(const Duration(seconds: 2), () {
          _append(fx.claude2, 'assistant.text', text: 'Going with "$chosen". Updating the theme picker now.');
          _upsert(fx.claude2, {'status': 'idle'});
          _pane(fx.claude2);
        });
        return {'ok': true, 'data': {'ok': true}};
      case 'pane.subscribe':
        _tickers[key]?.cancel();
        _tickers[key] = Timer.periodic(const Duration(seconds: 2), (_) {
          if (_done) return;
          _tick++;
          if (_busy(key)) _pane(key);
        });
        return {'ok': true, 'data': {'key': key, 'screen': fx.screen(key, tick: _tick, busy: _busy(key), typed: _typed[key] ?? '')}};
      case 'pane.unsubscribe':
        _tickers.remove(key)?.cancel();
        return {'ok': true};
      case 'repos.list':
        return {'ok': true, 'data': fx.repos(info.id)};
      case 'skills.list':
        return {'ok': true, 'data': fx.skills(p['provider'] as String? ?? 'claude')};
      case 'accounts.get':
        return {'ok': true, 'data': fx.accounts(info.id)};
      case 'session.spawn':
        _spawned++;
        final provider = p['provider'] as String? ?? 'claude';
        final dir = p['dir'] as String? ?? (_primary ? '/home/dev/src/porthole' : '/srv/ci/porthole');
        final prompt = (p['prompt'] as String? ?? '').trim();
        final id = 'demo-$provider-${2 + _spawned}';
        final k = '$provider:$id';
        final repo = dir.split('/').where((s) => s.isNotEmpty).toList();
        final j = <String, dynamic>{
          'key': k,
          'id': id,
          'provider': provider,
          'title': prompt.isNotEmpty ? prompt : 'New session',
          'cwd': dir,
          'repo': repo.length >= 2 ? '${repo[repo.length - 2]}/${repo.last}' : (repo.isEmpty ? '' : repo.last),
          'branch': 'main',
          'status': 'busy',
          'running': true,
          'controllable': true,
          'pane_id': '%${8 + _spawned}',
          'tmux_session': 'ph-$id',
          'model': provider == 'claude' ? 'claude-opus-5-5' : 'gpt-5-codex',
          'account': 'dev@example.com',
          'last_prompt': prompt,
          'started_at': DateTime.now().toUtc().toIso8601String(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'spawned': true,
        };
        _json[k] = j;
        _events[k] = [];
        _seq[k] = 0;
        _push('session.upsert', Map<String, dynamic>.from(j));
        _later(const Duration(milliseconds: 1500), () {
          _append(k, 'user', text: prompt.isNotEmpty ? prompt : 'Start here');
          _append(k, 'assistant.text', text: fx.cannedReply(prompt));
          _upsert(k, {'status': 'idle'});
        });
        return {'ok': true, 'data': Map<String, dynamic>.from(j)};
      default:
        // ping, session.unsubscribe, pane.resize, push.register, push.unregister, …
        return {'ok': true};
    }
  }

  @override
  void close() {
    _done = true;
    for (final t in _timers) {
      t.cancel();
    }
    for (final t in _tickers.values) {
      t.cancel();
    }
    _tickers.clear();
    super.close();
  }
}
