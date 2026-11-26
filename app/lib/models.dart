/// Data types mirroring the daemon's wire protocol (proto/protocol.md).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class DaemonInfo {
  DaemonInfo({
    required this.id,
    required this.name,
    required this.hosts,
    required this.port,
    required this.fingerprint,
    required this.token,
    required this.deviceId,
    this.lastHost,
    this.alias,
    this.muted = false,
    this.autoConnect = true,
    List<String>? ignoredHosts,
  }) : ignoredHosts = ignoredHosts ?? [];

  final String id; // local id (uuid)
  String name;
  List<String> hosts;
  int port;
  final String fingerprint;
  final String token;
  final String deviceId;
  String? lastHost;
  /// Local display-name override ("Laptop", "Workstation").
  String? alias;
  /// Suppress attention notifications and push for this machine.
  bool muted;
  /// Connect on launch; off for machines that are usually asleep.
  bool autoConnect;
  /// Addresses the user asked the app never to dial or probe (a long press
  /// in Manage machines). They stay listed there, struck through.
  List<String> ignoredHosts;

  /// The addresses the app may dial, in the daemon's order.
  List<String> get activeHosts => [for (final h in hosts) if (!ignoredHosts.contains(h)) h];

  String get displayName => (alias != null && alias!.trim().isNotEmpty) ? alias!.trim() : name;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hosts': hosts,
        'port': port,
        'fp': fingerprint,
        'token': token,
        'device_id': deviceId,
        'last_host': lastHost,
        'alias': alias,
        'muted': muted,
        'auto_connect': autoConnect,
        'ignored_hosts': ignoredHosts,
      };

  static DaemonInfo fromJson(Map<String, dynamic> j) => DaemonInfo(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'daemon',
        hosts: (j['hosts'] as List).cast<String>(),
        port: j['port'] as int,
        fingerprint: j['fp'] as String,
        token: j['token'] as String,
        deviceId: j['device_id'] as String? ?? '',
        lastHost: j['last_host'] as String?,
        alias: j['alias'] as String?,
        muted: j['muted'] as bool? ?? false,
        autoConnect: j['auto_connect'] as bool? ?? true,
        ignoredHosts: (j['ignored_hosts'] as List?)?.cast<String>(),
      );
}

class PairPayload {
  PairPayload({required this.name, required this.hosts, required this.port, required this.fingerprint, required this.code, this.expiresAt});
  final String name;
  final List<String> hosts;
  final int port;
  final String fingerprint;
  final String code;
  final DateTime? expiresAt;

  static PairPayload fromJson(Map<String, dynamic> j) => PairPayload(
        name: j['name'] as String? ?? 'daemon',
        hosts: (j['hosts'] as List? ?? []).cast<String>(),
        port: j['port'] as int,
        fingerprint: j['fp'] as String,
        code: j['code'] as String,
        expiresAt: j['exp'] != null ? DateTime.tryParse(j['exp'] as String) : null,
      );
}

class Session {
  Session.fromJson(Map<String, dynamic> j)
      : key = j['key'] as String,
        id = j['id'] as String? ?? '',
        provider = j['provider'] as String? ?? 'claude',
        title = j['title'] as String? ?? '',
        cwd = j['cwd'] as String? ?? '',
        repo = j['repo'] as String? ?? '',
        branch = j['branch'] as String? ?? '',
        status = j['status'] as String? ?? 'unknown',
        running = j['running'] as bool? ?? false,
        controllable = j['controllable'] as bool? ?? false,
        paneId = j['pane_id'] as String?,
        tmuxSession = j['tmux_session'] as String?,
        model = j['model'] as String? ?? '',
        account = j['account'] as String? ?? '',
        lastPrompt = j['last_prompt'] as String? ?? '',
        startedAt = DateTime.tryParse(j['started_at'] as String? ?? ''),
        updatedAt = DateTime.tryParse(j['updated_at'] as String? ?? ''),
        spawned = j['spawned'] as bool? ?? false,
        pending = j['pending'] as bool? ?? false,
        question = j['question'] is Map ? PendingQuestion.fromJson((j['question'] as Map).cast<String, dynamic>()) : null,
        permissionMode = j['permission_mode'] as String? ?? '',
        lastDenied = j['last_denied'] is Map ? DeniedTool.fromJson((j['last_denied'] as Map).cast<String, dynamic>()) : null,
        agents = [for (final a in (j['agents'] as List? ?? const [])) AgentInfo.fromJson((a as Map).cast<String, dynamic>())],
        agentsTotal = (j['agents_total'] as num?)?.toInt() ?? 0,
        usage = j['usage'] is Map ? (j['usage'] as Map).cast<String, dynamic>() : null,
        stale = j['_stale'] as bool? ?? false;

  final String key, id, provider, title, cwd, repo, branch, status, model, account, lastPrompt;
  /// Claude Code permission mode (default, acceptEdits, plan, auto, dontAsk,
  /// bypassPermissions) from the daemon; empty when unknown.
  final String permissionMode;
  /// The last action auto mode refused without a prompt, if any.
  final DeniedTool? lastDenied;
  /// Subagents of this session, from the daemon: every running one and the
  /// most recent finished ones. [agentsTotal] counts them all.
  final List<AgentInfo> agents;
  final int agentsTotal;
  int get agentCount => agentsTotal > agents.length ? agentsTotal : agents.length;
  /// The session's own token totals (input_tokens, output_tokens,
  /// cache_read_tokens, cache_creation_tokens), without its subagents.
  final Map<String, dynamic>? usage;

  /// Input + output + cache reads for this session alone, or 0 when unknown.
  int get totalTokens => usage == null ? 0 : tokensOf(usage!);
  final bool running, controllable, spawned, pending;
  /// True for sessions restored from the last-seen cache while the machine
  /// is unreachable; replaced by live data on the next hello.
  final bool stale;
  final String? paneId, tmuxSession;
  final DateTime? startedAt, updatedAt;
  /// Set while the session is waiting on a multiple-choice question.
  final PendingQuestion? question;

  /// Trimmed form persisted in the last-seen cache.
  Map<String, dynamic> toCacheJson() => {
        'key': key,
        'id': id,
        'provider': provider,
        'title': title,
        'cwd': cwd,
        'repo': repo,
        'branch': branch,
        'status': status,
        'running': running,
        'controllable': controllable,
        'model': model,
        'account': account,
        'last_prompt': lastPrompt,
        'updated_at': updatedAt?.toIso8601String(),
        '_stale': true,
      };

  String get displayTitle => title.isNotEmpty ? title : (lastPrompt.isNotEmpty ? lastPrompt : id);
  bool get needsAttention => status == 'waiting_permission' || status == 'waiting_input';

  /// Subagents still working, from the daemon's agent list.
  int get agentsRunning => agents.where((a) => a.running).length;

  /// True when the open permission prompt is the plan approval dialog.
  bool get planReady => status == 'waiting_permission' && planPending;

  /// Set by the client when a recovered permission prompt for this session
  /// is the plan approval dialog.
  bool planPending = false;
}

class ToolUse {
  ToolUse.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String? ?? '',
        name = j['name'] as String? ?? '',
        input = j['input'];
  final String id, name;
  final dynamic input;

  /// The tool that asks the user to pick from options.
  static const questionTool = 'AskUserQuestion';
  bool get isQuestion => name == questionTool;
}

class QuestionOption {
  const QuestionOption({required this.label, this.description = '', this.preview = ''});
  QuestionOption.fromJson(Map<String, dynamic> j)
      : label = j['label'] as String? ?? '',
        description = j['description'] as String? ?? '',
        preview = j['preview'] as String? ?? '';
  final String label, description;
  /// Optional code or text sample the daemon attaches to an option; shown
  /// in a monospace block under it.
  final String preview;
}

/// One question inside a pending question set.
class QuestionSpec {
  const QuestionSpec({required this.question, this.header = '', this.multiSelect = false, this.options = const []});
  QuestionSpec.fromJson(Map<String, dynamic> j)
      : question = j['question'] as String? ?? '',
        header = j['header'] as String? ?? '',
        multiSelect = j['multiSelect'] as bool? ?? false,
        options = [for (final o in (j['options'] as List? ?? [])) if (o is Map) QuestionOption.fromJson(o.cast<String, dynamic>())];
  final String question, header;
  final bool multiSelect;
  final List<QuestionOption> options;
}

/// A question set the session is waiting on, from `Session.question` or
/// from an unanswered question tool use in the transcript.
class PendingQuestion {
  PendingQuestion({required this.id, required this.questions, this.recovered = false, this.remaining = 0});
  PendingQuestion.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String? ?? '',
        questions = _specs(j['questions']),
        recovered = j['recovered'] == true,
        remaining = (j['remaining'] as num?)?.toInt() ?? 0;
  PendingQuestion.fromToolUse(ToolUse t)
      : id = t.id,
        questions = _specs(t.input is Map ? (t.input as Map)['questions'] : null),
        recovered = false,
        remaining = 0;
  final String id;
  final List<QuestionSpec> questions;

  /// True when the daemon read the question off the terminal rather than from
  /// the hook; it then serves the dialog one question at a time.
  final bool recovered;

  /// How many more questions follow a recovered one.
  final int remaining;

  /// A stable digest of the questions themselves (not the id), so a draft
  /// survives the daemon re-issuing the same set and is dropped when the
  /// set changes.
  late final String hash = _digest();

  String _digest() {
    final canon = jsonEncode([
      for (final q in questions)
        {
          'q': q.question,
          'h': q.header,
          'm': q.multiSelect,
          'o': [for (final o in q.options) [o.label, o.description, o.preview]],
        },
    ]);
    return sha1.convert(utf8.encode(canon)).toString().substring(0, 16);
  }

  static List<QuestionSpec> _specs(dynamic raw) => [for (final q in (raw as List? ?? [])) if (q is Map) QuestionSpec.fromJson(q.cast<String, dynamic>())];
}

/// Answers in progress for one question set, kept per machine until they are
/// submitted or the question goes away. Keys are question indices.
class QuestionDraft {
  QuestionDraft({Map<int, int>? single, Map<int, Set<int>>? multi, Map<int, String>? other, Map<int, String>? notes, this.page = 0})
      : single = single ?? {},
        multi = multi ?? {},
        other = other ?? {},
        notes = notes ?? {};

  final Map<int, int> single;
  final Map<int, Set<int>> multi;
  final Map<int, String> other;
  /// Free text attached to the choice on a single-select question.
  final Map<int, String> notes;
  /// The page the flow was on when it was last closed.
  int page;

  bool answered(int i) => single[i] != null || (multi[i]?.isNotEmpty ?? false) || (other[i]?.trim().isNotEmpty ?? false);

  Map<String, dynamic> toJson() => {
        'single': single.map((k, v) => MapEntry('$k', v)),
        'multi': multi.map((k, v) => MapEntry('$k', (v.toList()..sort()))),
        'other': other.map((k, v) => MapEntry('$k', v)),
        'notes': notes.map((k, v) => MapEntry('$k', v)),
        'page': page,
      };

  static QuestionDraft fromJson(Map<String, dynamic> j) => QuestionDraft(
        single: {for (final e in (j['single'] as Map? ?? {}).entries) if (e.value is int) int.parse('${e.key}'): e.value as int},
        multi: {for (final e in (j['multi'] as Map? ?? {}).entries) int.parse('${e.key}'): {...(e.value as List? ?? []).whereType<int>()}},
        other: {for (final e in (j['other'] as Map? ?? {}).entries) if (e.value is String) int.parse('${e.key}'): e.value as String},
        notes: {for (final e in (j['notes'] as Map? ?? {}).entries) if (e.value is String) int.parse('${e.key}'): e.value as String},
        page: j['page'] as int? ?? 0,
      );
}

/// One answer per question, in order: `index` for a single choice,
/// `indices` for a multi-select, `text` for a typed answer, `notes` for
/// free text attached to a single choice. Empty values are left out.
class QuestionAnswer {
  const QuestionAnswer({this.index, this.indices, this.text, this.notes});
  final int? index;
  final List<int>? indices;
  final String? text;
  final String? notes;

  Map<String, dynamic> toJson() => {'index': ?index, 'indices': ?indices, 'text': ?text, 'notes': ?notes};
}

final _answerPair = RegExp(r'"((?:[^"\\]|\\.)*)"="((?:[^"\\]|\\.)*)"');

/// Parses a question tool result (`Your questions have been answered:
/// "question"="answer", …`) into (question, answer) pairs.
List<(String, String)> parseQuestionAnswers(String text) => [for (final m in _answerPair.allMatches(text)) (m.group(1)!, m.group(2)!)];

class Event {
  Event.fromJson(Map<String, dynamic> j)
      : seq = (j['seq'] as num?)?.toInt() ?? 0,
        type = j['type'] as String,
        ts = DateTime.tryParse(j['ts'] as String? ?? ''),
        id = j['id'] as String? ?? '',
        messageId = j['message_id'] as String? ?? '',
        sidechain = j['sidechain'] as bool? ?? false,
        text = j['text'] as String? ?? '',
        truncated = j['truncated'] as bool? ?? false,
        tool = j['tool'] != null ? ToolUse.fromJson(j['tool'] as Map<String, dynamic>) : null,
        resultFor = (j['result'] as Map<String, dynamic>?)?['tool_use_id'] as String?,
        isError = (j['result'] as Map<String, dynamic>?)?['is_error'] as bool? ?? false,
        status = j['status'] as String? ?? '',
        model = j['model'] as String? ?? '',
        level = j['level'] as String? ?? '',
        usage = j['usage'] as Map<String, dynamic>?,
        meta = j['meta'] as Map<String, dynamic>?,
        images = [for (final i in (j['images'] as List? ?? const [])) if (i is Map) EventImage.fromJson(i.cast<String, dynamic>())];

  /// Images carried by a user message or a tool result.
  final List<EventImage> images;

  final int seq;
  final String type, id, messageId, text, status, model, level;
  final DateTime? ts;
  final bool sidechain, truncated, isError;
  final ToolUse? tool;
  final String? resultFor;
  final Map<String, dynamic>? usage, meta;
}

/// An image attached to an event. The daemon leaves [data] out and sets
/// [omitted] when the image is too large to send; [bytes] is its size.
class EventImage {
  EventImage({required this.mediaType, this.data, this.omitted = false, this.bytes = 0});
  EventImage.fromJson(Map<String, dynamic> j)
      : mediaType = j['media_type'] as String? ?? '',
        data = j['data'] as String?,
        omitted = j['omitted'] as bool? ?? false,
        bytes = (j['bytes'] as num?)?.toInt() ?? 0;
  final String mediaType;

  /// Base64 image bytes.
  final String? data;
  final bool omitted;
  final int bytes;

  Uint8List? _decoded;
  bool _tried = false;

  /// [data] decoded once; null when absent or not valid base64.
  Uint8List? get bytesDecoded {
    if (!_tried) {
      _tried = true;
      final d = data;
      if (d != null && d.isNotEmpty) {
        try {
          _decoded = base64Decode(d);
        } catch (_) {}
      }
    }
    return _decoded;
  }
}

/// "830 B", "12 KB", "2.3 MB".
String compactBytes(int n) {
  if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (n >= 1024) return '${(n / 1024).round()} KB';
  return '$n B';
}

class ScreenSnapshot {
  ScreenSnapshot.fromJson(Map<String, dynamic> j)
      : lines = (j['lines'] as List? ?? []).cast<String>(),
        cursorX = j['cursor_x'] as int? ?? 0,
        cursorY = j['cursor_y'] as int? ?? 0,
        width = j['width'] as int? ?? 80,
        height = j['height'] as int? ?? 24;
  final List<String> lines;
  final int cursorX, cursorY, width, height;
}

/// A permission prompt the phone can answer. Hook-held requests carry the
/// tool input and take Allow/Deny; recovered ones describe the dialog the CLI
/// drew in the terminal and are answered by picking one of its [options].
class PermissionRequest {
  PermissionRequest.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        sessionKey = j['session_key'] as String? ?? '',
        toolName = j['tool_name'] as String? ?? '',
        toolInput = j['tool_input'] as Map<String, dynamic>?,
        cwd = j['cwd'] as String? ?? '',
        expiresAt = DateTime.tryParse(j['expires_at'] as String? ?? ''),
        recovered = j['recovered'] as bool? ?? false,
        prompt = j['prompt'] as String? ?? '',
        description = j['description'] as String? ?? '',
        detail = j['detail'] as String? ?? '',
        options = [for (final o in (j['options'] as List? ?? const [])) '$o'];
  final String id, sessionKey, toolName, cwd, prompt, description, detail;
  final Map<String, dynamic>? toolInput;
  final DateTime? expiresAt;
  final bool recovered;
  final List<String> options;
}

/// One subagent (Agent tool run) of a session, read from its own transcript.
class AgentInfo {
  AgentInfo.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String? ?? '',
        type = j['type'] as String? ?? 'agent',
        description = j['description'] as String? ?? '',
        background = j['background'] as bool? ?? false,
        finished = j['finished'] as bool? ?? false,
        running = j['running'] as bool? ?? false,
        startedAt = DateTime.tryParse(j['started_at'] as String? ?? ''),
        updatedAt = DateTime.tryParse(j['updated_at'] as String? ?? ''),
        turns = (j['turns'] as num?)?.toInt() ?? 0,
        toolUses = (j['tool_uses'] as num?)?.toInt() ?? 0,
        model = j['model'] as String? ?? '',
        lastText = j['last_text'] as String? ?? '',
        usage = j['usage'] is Map ? (j['usage'] as Map).cast<String, dynamic>() : const {};
  final String id, type, description, model, lastText;
  final bool background, finished, running;
  final DateTime? startedAt, updatedAt;
  final int turns, toolUses;
  final Map<String, dynamic> usage;

  int get inputTokens => (usage['input_tokens'] as num?)?.toInt() ?? 0;
  int get outputTokens => (usage['output_tokens'] as num?)?.toInt() ?? 0;
  int get totalTokens => tokensOf(usage);

  /// Wall-clock time the agent has run, to now while running.
  Duration? get elapsed {
    final a = startedAt;
    if (a == null) return null;
    final end = running || updatedAt == null ? DateTime.now() : updatedAt!;
    return end.difference(a);
  }
}

/// Input + output + cache reads of a usage map from the daemon.
int tokensOf(Map<String, dynamic> u) {
  int n(String k) => (u[k] as num?)?.toInt() ?? 0;
  return n('input_tokens') + n('output_tokens') + n('cache_read_tokens');
}

/// "45s", "1m 32s", "1h 2m".
String compactDuration(Duration d) {
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}

/// "412k", "1.2M", "830".
String compactTokens(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$n';
}

/// An action auto mode refused, reported by the PermissionDenied hook.
class DeniedTool {
  DeniedTool.fromJson(Map<String, dynamic> j)
      : tool = j['tool'] as String? ?? '',
        at = DateTime.tryParse(j['at'] as String? ?? '');
  final String tool;
  final DateTime? at;
}

/// One Claude Code permission mode, as the CLI names it and as the app shows it.
class PermissionMode {
  const PermissionMode(this.value, this.label, this.short, this.glyph, this.description);
  final String value, label, short, glyph, description;

  static const all = [
    PermissionMode('default', 'Manual', 'Manual', '⏸', 'Claude asks before each tool call that needs permission.'),
    PermissionMode('acceptEdits', 'Accept edits', 'Edits', '⏵⏵', 'File edits and common file commands run without asking; other tools still prompt.'),
    PermissionMode('plan', 'Plan', 'Plan', '⏸', 'Read-only: Claude explores and writes a plan, then asks before acting on it.'),
    PermissionMode('auto', 'Auto', 'Auto', '⏵⏵', 'A classifier approves routine actions and blocks risky ones; blocked actions appear under /permissions.'),
    PermissionMode('dontAsk', "Don't ask", 'No ask', '⏵⏵', 'Prompts are refused instead of shown. Set only when the session starts.'),
    PermissionMode('bypassPermissions', 'Bypass', 'Bypass', '⏵⏵', 'No permission checks at all. Available only when the session was started with it.'),
  ];

  /// Modes Shift+Tab can reach from the phone: the cycle minus the two the
  /// CLI only sets at launch (bypass joins the cycle when started with it).
  static List<PermissionMode> switchable(String current) =>
      [for (final m in all) if (m.value != 'dontAsk' && (m.value != 'bypassPermissions' || current == 'bypassPermissions')) m];

  static PermissionMode? byValue(String v) {
    for (final m in all) {
      if (m.value == v) return m;
    }
    return null;
  }
}

class Skill {
  Skill.fromJson(Map<String, dynamic> j)
      : name = j['name'] as String,
        description = j['description'] as String? ?? '',
        source = j['source'] as String? ?? '',
        provider = j['provider'] as String? ?? '';
  final String name, description, source, provider;
}

class Repo {
  Repo.fromJson(Map<String, dynamic> j)
      : name = j['name'] as String,
        path = j['path'] as String,
        branch = j['branch'] as String? ?? '',
        lastProvider = j['last_provider'] as String? ?? '',
        lastUsed = DateTime.tryParse(j['last_used'] as String? ?? '');
  final String name, path, branch, lastProvider;
  final DateTime? lastUsed;
}

/// A shell command the daemon runs in its own tmux window next to a session
/// (`session.run`), as pushed in `run.update` and listed in hello.
class Run {
  Run.fromJson(Map<String, dynamic> j)
    : key = j['key'] as String? ?? '',
      id = j['id'] as String? ?? '',
      command = j['command'] as String? ?? '',
      state = j['state'] as String? ?? 'running',
      exit = (j['exit'] as num?)?.toInt(),
      tail = j['tail'] as String? ?? '',
      startedAt = DateTime.tryParse(j['started_at'] as String? ?? ''),
      endedAt = DateTime.tryParse(j['ended_at'] as String? ?? ''),
      fed = j['fed'] as bool? ?? false,
      queued = j['queued'] as bool? ?? false,
      paneId = j['pane_id'] as String? ?? '',
      device = j['device'] as String? ?? '',
      recovered = j['recovered'] as bool? ?? false;

  final String key, id, command, state, tail, paneId, device;

  /// The exit code once the command has finished; null while running or
  /// when it was stopped before it could report one.
  final int? exit;
  final DateTime? startedAt, endedAt;

  /// The output was typed into the session.
  final bool fed;

  /// The output waits for the session's current turn to end.
  final bool queued;

  /// The daemon restarted while the command ran and recovered the run
  /// afterwards.
  final bool recovered;

  bool get isDone => state != 'running';
  bool get stopped => state == 'stopped';

  /// Finished badly: stopped, or a non-zero exit.
  bool get failed => stopped || (isDone && (exit ?? 0) != 0);

  /// The tail without trailing blank lines.
  List<String> get tailLines {
    final lines = tail.replaceAll('\r', '').split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines;
  }

  /// How long it ran, or has been running so far.
  Duration elapsed([DateTime? now]) {
    final start = startedAt;
    if (start == null) return Duration.zero;
    final end = endedAt ?? (isDone ? start : (now ?? DateTime.now()));
    final d = end.difference(start);
    return d.isNegative ? Duration.zero : d;
  }
}
