/// Scripted content for the built-in demo machine: wire-shaped JSON exactly
/// as the daemon would send it (proto/protocol.md), so the demo goes through
/// the same parsers as a real machine. Functions, not constants, so the
/// timestamps are relative to now.
library;

import '../models.dart';

const demoDaemonId = 'demo';

DaemonInfo demoDaemonInfo() => DaemonInfo(id: demoDaemonId, name: 'demo-box', hosts: ['demo'], port: 0, fingerprint: 'demo', token: 'demo', deviceId: 'demo');

const claude1 = 'claude:demo-claude-1';
const codex1 = 'codex:demo-codex-1';
const claude0 = 'claude:demo-claude-0';

String _iso(Duration ago) => DateTime.now().subtract(ago).toUtc().toIso8601String();

Map<String, dynamic> hello() => {
      'name': 'demo-box',
      'version': '0.9.0-demo',
      'protocol': 1,
      'device': 'demo',
      'features': {'claude': true, 'codex': true, 'push': false, 'tmux': true},
      'sessions': sessions(),
      'permissions': <Map<String, dynamic>>[],
      'accounts': accounts(),
    };

List<Map<String, dynamic>> sessions() => [
      {
        'key': claude1,
        'id': 'demo-claude-1',
        'provider': 'claude',
        'title': 'Add rate limiting to the pairing endpoint',
        'cwd': '/home/dev/src/porthole/daemon',
        'repo': 'porthole/daemon',
        'branch': 'feat/pair-ratelimit',
        'status': 'busy',
        'running': true,
        'controllable': true,
        'pane_id': '%3',
        'tmux_session': 'ph-claude-1',
        'model': 'claude-opus-5-5',
        'account': 'dev@example.com',
        'last_prompt': 'Add per-source rate limiting to POST /v1/pair',
        'started_at': _iso(const Duration(minutes: 25)),
        'updated_at': _iso(const Duration(minutes: 1)),
        'spawned': true,
      },
      {
        'key': codex1,
        'id': 'demo-codex-1',
        'provider': 'codex',
        'title': 'Fix flaky websocket reconnect test',
        'cwd': '/home/dev/src/porthole/app',
        'repo': 'porthole/app',
        'branch': 'main',
        'status': 'idle',
        'running': true,
        'controllable': true,
        'pane_id': '%5',
        'tmux_session': 'ph-codex-1',
        'model': 'gpt-5-codex',
        'account': 'dev@example.com',
        'last_prompt': 'The reconnect test fails about one run in ten; find out why',
        'started_at': _iso(const Duration(hours: 1, minutes: 10)),
        'updated_at': _iso(const Duration(minutes: 12)),
      },
      {
        'key': claude0,
        'id': 'demo-claude-0',
        'provider': 'claude',
        'title': 'Write the wire protocol doc',
        'cwd': '/home/dev/src/porthole',
        'repo': 'porthole',
        'branch': 'main',
        'status': 'exited',
        'running': false,
        'controllable': false,
        'model': 'claude-opus-5-5',
        'account': 'dev@example.com',
        'last_prompt': 'Document every frame type in proto/protocol.md',
        'started_at': _iso(const Duration(days: 2, hours: 3)),
        'updated_at': _iso(const Duration(days: 2)),
      },
    ];

Map<String, dynamic> _ev(int seq, String type, Duration ago, {String? text, Map<String, dynamic>? tool, Map<String, dynamic>? result, String? level}) => {
      'seq': seq,
      'type': type,
      'ts': _iso(ago),
      'id': 'ev-$seq',
      'message_id': 'msg-${(seq + 1) ~/ 2}',
      'text': ?text,
      'tool': ?tool,
      'result': ?result,
      'level': ?level,
    };

/// The transcript page returned by `session.subscribe`.
List<Map<String, dynamic>> transcript(String key) {
  switch (key) {
    case claude1:
      return [
        _ev(1, 'user', const Duration(minutes: 25), text: 'Add per-source rate limiting to POST /v1/pair: five failures per minute per source address, then lock that source out for a minute. Keep it in-memory.'),
        _ev(2, 'assistant.thinking', const Duration(minutes: 24, seconds: 50), text: 'The pairing handler lives in internal/pair/handler.go. A small token bucket keyed by the remote address, swept every minute, will do; no new dependency.'),
        _ev(3, 'assistant.text', const Duration(minutes: 24, seconds: 40), text: 'I\'ll add a small in-memory limiter keyed by source address and wire it into the pairing handler. Reading the handler first.'),
        _ev(4, 'tool.use', const Duration(minutes: 24, seconds: 30), tool: {'id': 'tu_1', 'name': 'Read', 'input': {'file_path': 'internal/pair/handler.go'}}),
        _ev(5, 'tool.result', const Duration(minutes: 24, seconds: 28), result: {'tool_use_id': 'tu_1', 'is_error': false}, text: 'package pair\n\n// Handler issues single-use pairing codes and exchanges them for device tokens.\ntype Handler struct {\n\tcodes  *codeStore\n\tlog    *slog.Logger\n}\n\nfunc (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {\n\t// ... 61 more lines'),
        _ev(6, 'tool.use', const Duration(minutes: 3), tool: {
          'id': 'tu_2',
          'name': 'Edit',
          'input': {
            'file_path': 'internal/pair/handler.go',
            'old_string': 'func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {',
            'new_string': 'func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {\n\tif !h.limiter.allow(sourceOf(r)) {\n\t\thttp.Error(w, "too many attempts", http.StatusTooManyRequests)\n\t\treturn\n\t}',
          },
        }),
        _ev(7, 'tool.result', const Duration(minutes: 2, seconds: 58), result: {'tool_use_id': 'tu_2', 'is_error': false}, text: 'The file internal/pair/handler.go has been updated.'),
        _ev(8, 'assistant.text', const Duration(minutes: 1), text: 'Limiter added with a one-minute sweep. Next I want to run the package tests to confirm the lockout behaves.'),
      ];
    case codex1:
      return [
        _ev(1, 'user', const Duration(hours: 1, minutes: 10), text: 'The reconnect test fails about one run in ten; find out why.'),
        _ev(2, 'assistant.text', const Duration(hours: 1, minutes: 9), text: 'Running the test in a loop to catch the failing run.'),
        _ev(3, 'tool.use', const Duration(hours: 1, minutes: 8), tool: {'id': 'tu_c1', 'name': 'Bash', 'input': {'command': 'flutter test test/reconnect_test.dart --repeat 20'}}),
        _ev(4, 'tool.result', const Duration(minutes: 14), result: {'tool_use_id': 'tu_c1', 'is_error': false}, text: '00:41 +19 -1: reconnect backs off after three failures [E]\n  Expected: <4>\n    Actual: <2>\n'),
        _ev(5, 'assistant.text', const Duration(minutes: 12), text: 'Found it: the backoff timer is read before the third failure is recorded when the socket closes within the same tick. A fix is ready; it swaps the two lines in `_onClosed`. Want me to apply it?'),
      ];
    case claude0:
      return [
        _ev(1, 'user', const Duration(days: 2, hours: 3), text: 'Document every frame type in proto/protocol.md.'),
        _ev(2, 'assistant.text', const Duration(days: 2), text: 'Done. The document lists the pairing flow, every daemon-to-client and client-to-daemon frame, the shared types and the REST mirror.'),
      ];
  }
  return const [];
}

Map<String, dynamic> permissionRequest() => {
      'id': 'demo-perm-1',
      'session_key': claude1,
      'tool_name': 'Bash',
      'tool_input': {'command': 'go test ./internal/pair/...', 'description': 'Run the pair package tests'},
      'cwd': '/home/dev/src/porthole/daemon',
      'created_at': _iso(Duration.zero),
      'expires_at': DateTime.now().add(const Duration(minutes: 5)).toUtc().toIso8601String(),
    };

const spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

/// Terminal pane for a session; [tick] rotates the spinner while busy.
Map<String, dynamic> screen(String key, {int tick = 0, bool busy = true, String typed = ''}) {
  final lines = List<String>.filled(24, '');
  if (key == codex1) {
    lines[0] = '\x1b[1m Codex CLI\x1b[0m  gpt-5-codex  ·  porthole/app (main)';
    lines[2] = '\x1b[36m›\x1b[0m The reconnect test fails about one run in ten; find out why.';
    lines[4] = 'Running the test in a loop to catch the failing run.';
    lines[6] = '\x1b[2m\$ flutter test test/reconnect_test.dart --repeat 20\x1b[0m';
    lines[7] = '00:41 +19 -1: reconnect backs off after three failures \x1b[31m[E]\x1b[0m';
    lines[8] = '  Expected: <4>';
    lines[9] = '    Actual: <2>';
    lines[11] = 'Found it: the backoff timer is read before the third failure is';
    lines[12] = 'recorded when the socket closes within the same tick.';
    lines[13] = 'A fix is ready. Want me to apply it?';
    lines[22] = '\x1b[2m────────────────────────────────────────────────────────────────\x1b[0m';
    lines[23] = '\x1b[36m›\x1b[0m $typed';
    return {'lines': lines, 'cursor_x': 2 + typed.length, 'cursor_y': 23, 'width': 80, 'height': 24};
  }
  lines[0] = '\x1b[1m Claude Code\x1b[0m  v2.4  ·  porthole/daemon (feat/pair-ratelimit)';
  lines[2] = '\x1b[2m>\x1b[0m Add per-source rate limiting to POST /v1/pair: five failures per';
  lines[3] = '  minute per source address, then lock that source out for a minute.';
  lines[5] = '\x1b[32m●\x1b[0m Read(internal/pair/handler.go)';
  lines[6] = '  \x1b[2mRead 68 lines\x1b[0m';
  lines[7] = '\x1b[32m●\x1b[0m Edit(internal/pair/handler.go)';
  lines[8] = '  \x1b[2mAdded 5 lines\x1b[0m';
  lines[10] = 'Limiter added with a one-minute sweep. Next I want to run the package';
  lines[11] = 'tests to confirm the lockout behaves.';
  lines[13] = busy ? '${spinner[tick % spinner.length]} Working… \x1b[2m(esc to interrupt)\x1b[0m' : '';
  lines[22] = '\x1b[2m────────────────────────────────────────────────────────────────\x1b[0m';
  lines[23] = '\x1b[2m>\x1b[0m $typed';
  return {'lines': lines, 'cursor_x': 2 + typed.length, 'cursor_y': 23, 'width': 80, 'height': 24};
}

List<Map<String, dynamic>> repos() => [
      {'name': 'porthole/daemon', 'path': '/home/dev/src/porthole/daemon', 'workspace': 'src', 'branch': 'feat/pair-ratelimit', 'last_provider': 'claude', 'last_used': _iso(const Duration(minutes: 1))},
      {'name': 'porthole/app', 'path': '/home/dev/src/porthole/app', 'workspace': 'src', 'branch': 'main', 'last_provider': 'codex', 'last_used': _iso(const Duration(minutes: 12))},
      {'name': 'notes', 'path': '/home/dev/notes', 'workspace': 'home', 'branch': 'main', 'last_provider': 'claude', 'last_used': _iso(const Duration(days: 3))},
    ];

List<Map<String, dynamic>> skills(String provider) => [
      {'name': 'commit', 'description': 'Stage and commit with a conventional message', 'source': 'user', 'provider': provider},
      {'name': 'review', 'description': 'Review the current diff for bugs and style', 'source': 'project', 'provider': provider},
      {'name': 'explain', 'description': 'Explain the selected code', 'source': 'builtin', 'provider': provider},
    ];

Map<String, dynamic> accounts() => {
      'fetched_at': _iso(const Duration(minutes: 2)),
      'claude': {
        'fetched_at': _iso(const Duration(minutes: 2)),
        'active_email': 'dev@example.com',
        'schema_version': 1,
        'raw': {
          'accounts': [
            {
              'email': 'dev@example.com',
              'organizationName': 'Personal',
              'alias': 'main',
              'active': true,
              'usageStatus': 'ok',
              'usage': {
                'fiveHour': {'pct': 42, 'countdown': '2h 10m'},
                'sevenDay': {'pct': 18, 'resetsAt': DateTime.now().add(const Duration(days: 4)).toUtc().toIso8601String()},
              },
            },
          ],
        },
      },
      'codex': {
        'email': 'dev@example.com',
        'rate_limits': {
          'plan': 'plus',
          'primary': {'used_percent': 31, 'window_minutes': 300, 'resets_at': DateTime.now().add(const Duration(hours: 3)).toUtc().toIso8601String()},
          'secondary': {'used_percent': 12, 'window_minutes': 10080, 'resets_at': DateTime.now().add(const Duration(days: 5)).toUtc().toIso8601String()},
        },
        'seen_at': _iso(const Duration(minutes: 12)),
      },
    };

final _replies = [
  'On it. I\'ll start with "{q}" and report back with a diff.',
  'Understood: "{q}". Checking the relevant files before changing anything.',
  'Good call. "{q}" touches two packages; I\'ll do the smaller one first and run its tests.',
];
int _replyIx = 0;

String cannedReply(String input) {
  final q = input.trim().split(RegExp(r'\s+')).take(6).join(' ');
  final r = _replies[_replyIx++ % _replies.length];
  return r.replaceAll('{q}', q.isEmpty ? 'that' : q);
}
