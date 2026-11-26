/// Scripted content for the built-in demo machines: wire-shaped JSON exactly
/// as the daemon would send it (proto/protocol.md), so the demo goes through
/// the same parsers as a real machine. Functions, not constants, so the
/// timestamps are relative to now.
///
/// Two machines: `demo-box` (the one "Try the demo" has always added; it
/// carries the permission prompt and the waiting-input session) and
/// `build-box` (a second machine so the Machines list and the machine filter
/// have more than one entry). Every function takes the machine's local id and
/// defaults to demo-box.
library;

import 'dart:io' show zlib;
import 'dart:typed_data';

import '../models.dart';

/// The screenshot the build-box CI session shows in its last message.
const demoShotPath = '/srv/ci/porthole/shot.png';

/// A small PNG built in code (green bars on a dark ground), served for
/// [demoShotPath].
Uint8List demoPng({int width = 48, int height = 32}) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // no filter
    for (var x = 0; x < width; x++) {
      final bar = (x ~/ 8).isEven && y > height - 4 - (x * 3 % height);
      raw.add(bar ? const [0x3C, 0xC8, 0x78] : const [0x1E, 0x22, 0x2A]);
    }
  }
  final out = BytesBuilder()..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    out
      ..add(_u32(data.length))
      ..add(body)
      ..add(_u32(_crc32(body)));
  }

  chunk('IHDR', [..._u32(width), ..._u32(height), 8, 2, 0, 0, 0]);
  chunk('IDAT', zlib.encode(raw.toBytes()));
  chunk('IEND', const []);
  return out.toBytes();
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xFFFFFFFF;
}

const demoDaemonId = 'demo';
const demoBuildBoxId = 'demo-build-box';

DaemonInfo demoDaemonInfo() => DaemonInfo(id: demoDaemonId, name: 'demo-box', hosts: ['demo'], port: 0, fingerprint: 'demo', token: 'demo', deviceId: 'demo');
DaemonInfo demoBuildBoxInfo() => DaemonInfo(id: demoBuildBoxId, name: 'build-box', hosts: ['demo'], port: 0, fingerprint: 'demo-build-box', token: 'demo', deviceId: 'demo-build-box');

/// Every built-in machine, demo-box first.
List<DaemonInfo> demoDaemonInfos() => [demoDaemonInfo(), demoBuildBoxInfo()];

/// True for the local id of any built-in machine (they get a DemoDaemonClient).
bool isDemoDaemonId(String id) => id == demoDaemonId || id == demoBuildBoxId;

// demo-box
const claude1 = 'claude:demo-claude-1';
const codex1 = 'codex:demo-codex-1';
const claude2 = 'claude:demo-claude-2';
const claude0 = 'claude:demo-claude-0';
const codex0 = 'codex:demo-codex-0';
// build-box
const bbClaude1 = 'claude:demo-bb-claude-1';
const bbCodex1 = 'codex:demo-bb-codex-1';

String _iso(Duration ago) => DateTime.now().subtract(ago).toUtc().toIso8601String();

String _nameOf(String machine) => machine == demoBuildBoxId ? 'build-box' : 'demo-box';

Map<String, dynamic> hello([String machine = demoDaemonId]) => {
      'name': _nameOf(machine),
      'version': '0.9.0-demo',
      'protocol': 1,
      'device': 'demo',
      'features': {'claude': true, 'codex': true, 'push': false, 'tmux': true},
      'sessions': sessions(machine),
      'permissions': <Map<String, dynamic>>[],
      'accounts': accounts(machine),
    };

List<Map<String, dynamic>> sessions([String machine = demoDaemonId]) {
  if (machine == demoBuildBoxId) {
    return [
      {
        'key': bbClaude1,
        'id': 'demo-bb-claude-1',
        'provider': 'claude',
        'title': 'Cache the Go module download in CI',
        'cwd': '/srv/ci/porthole',
        'repo': 'porthole',
        'branch': 'ci/module-cache',
        'status': 'busy',
        'permission_mode': 'acceptEdits',
        'usage': {'input_tokens': 182000, 'output_tokens': 9400, 'cache_read_tokens': 410000},
        'agents': demoAgents(),
        'queued': ['Also keep the cache key tied to go.sum'],
        'running': true,
        'controllable': true,
        'pane_id': '%2',
        'tmux_session': 'ph-claude-1',
        'model': 'claude-opus-5-5',
        'account': 'dev@example.com',
        'last_prompt': 'The CI job downloads every Go module on each run; cache them',
        'started_at': _iso(const Duration(minutes: 9)),
        'updated_at': _iso(const Duration(seconds: 40)),
        'spawned': true,
      },
      {
        'key': bbCodex1,
        'id': 'demo-bb-codex-1',
        'provider': 'codex',
        'title': 'Nightly dependency audit',
        'cwd': '/srv/ci/porthole/relay',
        'repo': 'porthole/relay',
        'branch': 'main',
        'status': 'idle',
        'running': true,
        'controllable': true,
        'pane_id': '%4',
        'tmux_session': 'ph-codex-1',
        'model': 'gpt-5-codex',
        'account': 'dev@example.com',
        'last_prompt': 'List outdated packages with known advisories and propose bumps',
        'started_at': _iso(const Duration(hours: 6)),
        'updated_at': _iso(const Duration(hours: 5, minutes: 40)),
      },
    ];
  }
  return [
    {
      'key': claude1,
      'id': 'demo-claude-1',
      'provider': 'claude',
      'title': 'Add rate limiting to the pairing endpoint',
      'cwd': '/home/dev/src/porthole/daemon',
      'repo': 'porthole/daemon',
      'branch': 'feat/pair-ratelimit',
      'status': 'busy',
      'permission_mode': 'auto',
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
      'key': claude2,
      'id': 'demo-claude-2',
      'provider': 'claude',
      'title': 'Move the settings screen to Material 3',
      'cwd': '/home/dev/src/porthole/app',
      'repo': 'porthole/app',
      'branch': 'chore/m3-settings',
      'status': 'waiting_input',
      'permission_mode': 'default',
      'running': true,
      'controllable': true,
      'question': demoQuestion(),
      'pane_id': '%6',
      'tmux_session': 'ph-claude-2',
      'model': 'claude-sonnet-5',
      'account': 'dev@example.com',
      'last_prompt': 'Move the settings screen to Material 3 components',
      'started_at': _iso(const Duration(minutes: 41)),
      'updated_at': _iso(const Duration(minutes: 4)),
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
      'permission_mode': 'plan',
      'running': false,
      'controllable': false,
      'model': 'claude-opus-5-5',
      'account': 'dev@example.com',
      'last_prompt': 'Document every frame type in proto/protocol.md',
      'started_at': _iso(const Duration(days: 2, hours: 3)),
      'updated_at': _iso(const Duration(days: 2)),
    },
    {
      'key': codex0,
      'id': 'demo-codex-0',
      'provider': 'codex',
      'title': 'Bump dependencies and fix deprecations',
      'cwd': '/home/dev/src/porthole/app',
      'repo': 'porthole/app',
      'branch': 'chore/deps',
      'status': 'exited',
      'running': false,
      'controllable': false,
      'model': 'gpt-5-codex',
      'account': 'dev@example.com',
      'last_prompt': 'Upgrade every package to its latest minor and fix the deprecation warnings',
      'started_at': _iso(const Duration(days: 5, hours: 2)),
      'updated_at': _iso(const Duration(days: 5)),
    },
  ];
}

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

/// Two subagents of build-box's Claude session: one still working, one done.
List<Map<String, dynamic>> demoAgents() => [
      {
        'id': 'agent-demo-1',
        'type': 'Explore',
        'description': 'Find every place the CI config downloads modules',
        'background': true,
        'finished': true,
        'running': false,
        'started_at': _iso(const Duration(minutes: 6)),
        'updated_at': _iso(const Duration(minutes: 4)),
        'turns': 5,
        'tool_uses': 9,
        'usage': {'input_tokens': 41000, 'output_tokens': 1800, 'cache_read_tokens': 96000},
        'model': 'claude-sonnet-5-5',
        'last_text': 'Three jobs download modules: build, lint and the nightly fuzz run. Only build has a cache step.',
      },
      {
        'id': 'agent-demo-2',
        'type': 'general-purpose',
        'description': 'Add actions/cache for the Go module directory to the lint job',
        'background': true,
        'finished': false,
        'running': true,
        'started_at': _iso(const Duration(minutes: 3)),
        'updated_at': _iso(const Duration(seconds: 4)),
        'turns': 3,
        'tool_uses': 4,
        'usage': {'input_tokens': 22000, 'output_tokens': 900, 'cache_read_tokens': 51000},
        'model': 'claude-sonnet-5-5',
        'last_text': 'Editing .github/workflows/ci.yml: adding the cache step before go vet.',
      },
    ];

/// The transcript of a demo subagent.
List<Map<String, dynamic>> agentTranscript(String agentId) {
  if (agentId == 'agent-demo-1') {
    return [
      _ev(1, 'user', const Duration(minutes: 6), text: 'Find every place the CI config downloads Go modules. Report file and job names only.'),
      _ev(2, 'tool.use', const Duration(minutes: 5, seconds: 40), tool: {'id': 'tu-a1', 'name': 'Grep', 'input': {'pattern': 'go mod download', 'path': '.github'}}),
      _ev(3, 'tool.result', const Duration(minutes: 5, seconds: 38), result: {'tool_use_id': 'tu-a1', 'is_error': false}, text: '.github/workflows/ci.yml:24\n.github/workflows/ci.yml:51\n.github/workflows/nightly.yml:18'),
      _ev(4, 'assistant.text', const Duration(minutes: 4), text: 'Three jobs download modules: build, lint and the nightly fuzz run. Only build has a cache step.'),
    ];
  }
  return [
    _ev(1, 'user', const Duration(minutes: 3), text: 'Add actions/cache for the Go module directory to the lint job in .github/workflows/ci.yml, matching the build job.'),
    _ev(2, 'tool.use', const Duration(minutes: 2, seconds: 30), tool: {'id': 'tu-b1', 'name': 'Read', 'input': {'file_path': '.github/workflows/ci.yml'}}),
    _ev(3, 'tool.result', const Duration(minutes: 2, seconds: 29), result: {'tool_use_id': 'tu-b1', 'is_error': false}, text: '(62 lines)'),
    _ev(4, 'assistant.text', const Duration(seconds: 4), text: 'Editing .github/workflows/ci.yml: adding the cache step before go vet.'),
  ];
}

/// The transcript page returned by `session.subscribe`.
List<Map<String, dynamic>> transcript(String key) {
  switch (key) {
    case claude1:
      return [
        _ev(1, 'user', const Duration(minutes: 25), text: 'Add per-source rate limiting to POST /v1/pair: five failures per minute per source address, then lock that source out for a minute. Keep it in-memory.'),
        _ev(2, 'assistant.thinking', const Duration(minutes: 24, seconds: 50), text: 'The pairing handler lives in internal/pair/handler.go. A small token bucket keyed by the remote address, swept every minute, will do; no new dependency. I should read the handler before touching it so the lockout sits in front of the code lookup, not after.'),
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
        _ev(8, 'assistant.text', const Duration(minutes: 1), text: 'Limiter added with a one-minute sweep. Next I want to run the package tests to confirm the lockout behaves:\n\n```sh\ngo test ./internal/pair/...\n```'),
      ];
    case claude2:
      return [
        _ev(1, 'user', const Duration(minutes: 41), text: 'Move the settings screen to Material 3 components. Keep the layout; only swap the widgets.'),
        _ev(2, 'assistant.thinking', const Duration(minutes: 40, seconds: 50), text: 'Settings uses SwitchListTile, ListTile and a handful of TextButtons. Most of these are already Material 3 under useMaterial3; the real work is the segmented control for the theme picker and the two dialogs.'),
        _ev(3, 'tool.use', const Duration(minutes: 40, seconds: 30), tool: {'id': 'tu_s1', 'name': 'Grep', 'input': {'pattern': 'RadioListTile|showDialog', 'path': 'lib/screens/settings.dart'}}),
        _ev(4, 'tool.result', const Duration(minutes: 40, seconds: 28), result: {'tool_use_id': 'tu_s1', 'is_error': false}, text: 'lib/screens/settings.dart:88: RadioListTile<String>(\nlib/screens/settings.dart:96: RadioListTile<String>(\nlib/screens/settings.dart:140: showDialog<bool>('),
        _ev(5, 'assistant.text', const Duration(minutes: 4), text: 'Two of the three theme radios map cleanly onto a SegmentedButton. The third option, "Follow system", has no equivalent in a two-segment control.'),
        _ev(6, 'tool.use', const Duration(minutes: 4), tool: {'id': 'tu_q1', 'name': 'AskUserQuestion', 'input': {'questions': demoQuestion()['questions']}}),
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
    case codex0:
      return [
        _ev(1, 'user', const Duration(days: 5, hours: 2), text: 'Upgrade every package to its latest minor and fix the deprecation warnings.'),
        _ev(2, 'tool.use', const Duration(days: 5, hours: 1, minutes: 50), tool: {'id': 'tu_d1', 'name': 'Bash', 'input': {'command': 'flutter pub upgrade && flutter analyze'}}),
        _ev(3, 'tool.result', const Duration(days: 5, hours: 1, minutes: 48), result: {'tool_use_id': 'tu_d1', 'is_error': false}, text: 'Changed 9 dependencies!\nAnalyzing app...\n   info - \'withOpacity\' is deprecated - lib/widgets/ansi.dart:41:18\n2 issues found.'),
        _ev(4, 'assistant.text', const Duration(days: 5), text: 'Nine packages bumped, both deprecations replaced with `withValues`, analyzer clean. Committed on chore/deps.'),
      ];
    case bbClaude1:
      return [
        _ev(1, 'user', const Duration(minutes: 9), text: 'The CI job downloads every Go module on each run; cache them.'),
        _ev(2, 'assistant.thinking', const Duration(minutes: 8, seconds: 50), text: 'The job runs on a self-hosted agent, so a directory under the workspace survives between runs. GOMODCACHE pointed at it plus a restore step keyed on go.sum is enough; no plugin needed.'),
        _ev(3, 'tool.use', const Duration(minutes: 8, seconds: 30), tool: {'id': 'tu_b1', 'name': 'Read', 'input': {'file_path': 'Jenkinsfile'}}),
        _ev(4, 'tool.result', const Duration(minutes: 8, seconds: 28), result: {'tool_use_id': 'tu_b1', 'is_error': false}, text: 'pipeline {\n  agent { label \'linux\' }\n  stages {\n    stage(\'build\') {\n      steps { sh \'cd daemon && go build ./...\' }\n    }\n    // ... 24 more lines'),
        _ev(5, 'assistant.text', const Duration(seconds: 40), text: 'Adding a GOMODCACHE under the workspace and a restore step keyed on go.sum. Measuring the before and after on the build stage next. The build stage timings so far:\n\n![Screenshot]($demoShotPath)'),
      ];
    case bbCodex1:
      return [
        _ev(1, 'user', const Duration(hours: 6), text: 'List outdated packages with known advisories and propose bumps.'),
        _ev(2, 'tool.use', const Duration(hours: 5, minutes: 58), tool: {'id': 'tu_n1', 'name': 'Bash', 'input': {'command': 'npm audit --omit=dev --json | jq \'.metadata.vulnerabilities\''}}),
        _ev(3, 'tool.result', const Duration(hours: 5, minutes: 57), result: {'tool_use_id': 'tu_n1', 'is_error': false}, text: '{\n  "info": 0,\n  "low": 1,\n  "moderate": 0,\n  "high": 0,\n  "critical": 0,\n  "total": 1\n}'),
        _ev(4, 'assistant.text', const Duration(hours: 5, minutes: 40), text: 'One low-severity advisory in a transitive dependency of the test runner; the fix is a patch bump of `undici`. Nothing in production code. Proposed bump is in `deps-nightly.md`.'),
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

/// The question the waiting-input demo session is asking, in the shape the
/// daemon sends (Session.question and the AskUserQuestion tool input).
Map<String, dynamic> demoQuestion() => {
      'id': 'tu_q1',
      'questions': [
        {
          'question': 'The theme picker has three options and SegmentedButton fits two. How should it look?',
          'header': 'Theme picker',
          'multiSelect': false,
          'options': [
            {'label': 'Three-segment button', 'description': 'Wider control; wraps onto two lines on small phones.'},
            {'label': 'Keep the radios', 'description': 'Leave this one setting as RadioListTiles.'},
            {'label': 'Dropdown', 'description': 'A DropdownMenu with the three choices.'},
          ],
        },
      ],
    };

const spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

const _rule = '\x1b[2m────────────────────────────────────────────────────────────────\x1b[0m';

Map<String, dynamic> _pane(List<String> lines, String typed) => {
      'lines': lines,
      'cursor_x': 2 + typed.length,
      'cursor_y': 23,
      'width': 80,
      'height': 24,
      'in_mode': false,
    };

/// Terminal pane for a session (the `screen` object of `pane.subscribe` and
/// `pane.snapshot`); [tick] rotates the spinner while busy.
Map<String, dynamic> screen(String key, {int tick = 0, bool busy = true, String typed = ''}) {
  final lines = List<String>.filled(24, '');
  final working = busy ? '${spinner[tick % spinner.length]} Working… \x1b[2m(esc to interrupt)\x1b[0m' : '';
  switch (key) {
    case codex1:
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
      lines[22] = _rule;
      lines[23] = '\x1b[36m›\x1b[0m $typed';
      return _pane(lines, typed);
    case claude2:
      lines[0] = '\x1b[1m Claude Code\x1b[0m  v2.4  ·  porthole/app (chore/m3-settings)';
      lines[2] = '\x1b[2m>\x1b[0m Move the settings screen to Material 3 components. Keep the layout;';
      lines[3] = '  only swap the widgets.';
      lines[5] = '\x1b[32m●\x1b[0m Grep(RadioListTile|showDialog in lib/screens/settings.dart)';
      lines[6] = '  \x1b[2m3 matches\x1b[0m';
      lines[8] = 'Two of the three theme radios map cleanly onto a SegmentedButton. The';
      lines[9] = 'third option, "Follow system", has no equivalent in a two-segment';
      lines[10] = 'control.';
      lines[12] = '\x1b[33m?\x1b[0m Three-segment button, or keep the radios for that one setting?';
      lines[14] = '  \x1b[1m❯\x1b[0m 1. Three-segment button';
      lines[15] = '    2. Keep the radios';
      lines[16] = '    3. Let me explain';
      lines[18] = '\x1b[2mEnter to confirm · Esc to cancel\x1b[0m';
      lines[22] = _rule;
      lines[23] = '\x1b[2m>\x1b[0m $typed';
      return _pane(lines, typed);
    case bbClaude1:
      lines[0] = '\x1b[1m Claude Code\x1b[0m  v2.4  ·  porthole (ci/module-cache)';
      lines[2] = '\x1b[2m>\x1b[0m The CI job downloads every Go module on each run; cache them.';
      lines[4] = '\x1b[32m●\x1b[0m Read(Jenkinsfile)';
      lines[5] = '  \x1b[2mRead 31 lines\x1b[0m';
      lines[7] = 'Adding a GOMODCACHE under the workspace and a restore step keyed on';
      lines[8] = 'go.sum. Measuring the before and after on the build stage next.';
      lines[10] = working;
      lines[22] = _rule;
      lines[23] = '\x1b[2m>\x1b[0m $typed';
      return _pane(lines, typed);
    case bbCodex1:
      lines[0] = '\x1b[1m Codex CLI\x1b[0m  gpt-5-codex  ·  porthole/relay (main)';
      lines[2] = '\x1b[36m›\x1b[0m List outdated packages with known advisories and propose bumps.';
      lines[4] = '\x1b[2m\$ npm audit --omit=dev --json | jq \'.metadata.vulnerabilities\'\x1b[0m';
      lines[5] = '{ "low": 1, "moderate": 0, "high": 0, "critical": 0, "total": 1 }';
      lines[7] = 'One low-severity advisory in a transitive dependency of the test';
      lines[8] = 'runner; the fix is a patch bump of undici. Proposed bump is in';
      lines[9] = 'deps-nightly.md.';
      lines[22] = _rule;
      lines[23] = '\x1b[36m›\x1b[0m $typed';
      return _pane(lines, typed);
    case claude1:
      lines[0] = '\x1b[1m Claude Code\x1b[0m  v2.4  ·  porthole/daemon (feat/pair-ratelimit)';
      lines[2] = '\x1b[2m>\x1b[0m Add per-source rate limiting to POST /v1/pair: five failures per';
      lines[3] = '  minute per source address, then lock that source out for a minute.';
      lines[5] = '\x1b[32m●\x1b[0m Read(internal/pair/handler.go)';
      lines[6] = '  \x1b[2mRead 68 lines\x1b[0m';
      lines[7] = '\x1b[32m●\x1b[0m Edit(internal/pair/handler.go)';
      lines[8] = '  \x1b[2mAdded 5 lines\x1b[0m';
      lines[10] = 'Limiter added with a one-minute sweep. Next I want to run the package';
      lines[11] = 'tests to confirm the lockout behaves.';
      lines[13] = working;
      lines[22] = _rule;
      lines[23] = '\x1b[2m>\x1b[0m $typed';
      return _pane(lines, typed);
  }
  // Sessions spawned from the app during the demo.
  final isCodex = key.startsWith('codex:');
  lines[0] = isCodex ? '\x1b[1m Codex CLI\x1b[0m  gpt-5-codex' : '\x1b[1m Claude Code\x1b[0m  v2.4';
  lines[2] = working;
  lines[22] = _rule;
  lines[23] = '${isCodex ? '\x1b[36m›\x1b[0m' : '\x1b[2m>\x1b[0m'} $typed';
  return _pane(lines, typed);
}

List<Map<String, dynamic>> repos([String machine = demoDaemonId]) {
  if (machine == demoBuildBoxId) {
    return [
      {'name': 'porthole', 'path': '/srv/ci/porthole', 'workspace': 'ci', 'source': 'workspace', 'branch': 'ci/module-cache', 'last_provider': 'claude', 'last_used': _iso(const Duration(seconds: 40))},
      {'name': 'porthole/relay', 'path': '/srv/ci/porthole/relay', 'workspace': 'ci', 'source': 'workspace', 'branch': 'main', 'last_provider': 'codex', 'last_used': _iso(const Duration(hours: 6))},
    ];
  }
  return [
    {'name': 'porthole/daemon', 'path': '/home/dev/src/porthole/daemon', 'workspace': 'src', 'source': 'workspace', 'branch': 'feat/pair-ratelimit', 'last_provider': 'claude', 'last_used': _iso(const Duration(minutes: 1))},
    {'name': 'porthole/app', 'path': '/home/dev/src/porthole/app', 'workspace': 'src', 'source': 'workspace', 'branch': 'main', 'last_provider': 'codex', 'last_used': _iso(const Duration(minutes: 12))},
    {'name': 'notes', 'path': '/home/dev/notes', 'workspace': 'home', 'source': 'recent', 'branch': 'main', 'last_provider': 'claude', 'last_used': _iso(const Duration(days: 3))},
  ];
}

List<Map<String, dynamic>> skills(String provider) => [
      {'name': 'commit', 'description': 'Stage and commit with a conventional message', 'source': 'user', 'provider': provider},
      {'name': 'review', 'description': 'Review the current diff for bugs and style', 'source': 'project', 'provider': provider},
      {'name': 'explain', 'description': 'Explain the selected code', 'source': 'builtin', 'provider': provider},
    ];

Map<String, dynamic> accounts([String machine = demoDaemonId]) {
  final bb = machine == demoBuildBoxId;
  return {
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
              'fiveHour': {'pct': bb ? 63 : 42, 'countdown': bb ? '1h 05m' : '2h 10m'},
              'sevenDay': {'pct': bb ? 27 : 18, 'resetsAt': DateTime.now().add(const Duration(days: 4)).toUtc().toIso8601String()},
            },
          },
          if (!bb)
            {
              'email': 'team@example.com',
              'organizationName': 'Example Co',
              'alias': 'work',
              'active': false,
              'usageStatus': 'ok',
              'usage': {
                'fiveHour': {'pct': 8, 'countdown': '4h 30m'},
                'sevenDay': {'pct': 55, 'resetsAt': DateTime.now().add(const Duration(days: 2)).toUtc().toIso8601String()},
              },
            },
        ],
      },
    },
    'codex': {
      'email': 'dev@example.com',
      'rate_limits': {
        'plan': 'plus',
        'primary': {'used_percent': bb ? 12 : 31, 'window_minutes': 300, 'resets_at': DateTime.now().add(const Duration(hours: 3)).toUtc().toIso8601String()},
        'secondary': {'used_percent': bb ? 40 : 12, 'window_minutes': 10080, 'resets_at': DateTime.now().add(const Duration(days: 5)).toUtc().toIso8601String()},
      },
      'seen_at': _iso(const Duration(minutes: 12)),
    },
  };
}

final _replies = [
  'On it. I\'ll start with "{q}" and report back with a diff.',
  'Understood: "{q}". Checking the relevant files before changing anything.',
  'Good call. "{q}" touches two packages; I\'ll do the smaller one first and run its tests.',
];

/// Output for a command run in a demo window, in three stages (the last
/// one is the finished tail).
List<String> runTail(String command) {
  final c = command.trim();
  if (c.startsWith('go test')) {
    return [
      '=== RUN   TestPairLimiter',
      '=== RUN   TestPairLimiter\n--- PASS: TestPairLimiter (0.01s)\n=== RUN   TestPairLockout',
      '=== RUN   TestPairLimiter\n--- PASS: TestPairLimiter (0.01s)\n=== RUN   TestPairLockout\n--- PASS: TestPairLockout (0.20s)\nPASS\nok  \tporthole/daemon/internal/pair\t0.412s',
    ];
  }
  if (c.startsWith('flutter test')) {
    return ['00:02 +0: loading', '00:05 +12: All tests passed so far', '00:07 +24: All tests passed!'];
  }
  return ['Running $c', 'Running $c\n…', 'Running $c\n…\ndone'];
}

int _replyIx = 0;

String cannedReply(String input) {
  final q = input.trim().split(RegExp(r'\s+')).take(6).join(' ');
  final r = _replies[_replyIx++ % _replies.length];
  return r.replaceAll('{q}', q.isEmpty ? 'that' : q);
}
