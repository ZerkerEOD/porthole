/// Data types mirroring the daemon's wire protocol (proto/protocol.md).
library;

import 'dart:convert';

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
  });

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
        stale = j['_stale'] as bool? ?? false;

  final String key, id, provider, title, cwd, repo, branch, status, model, account, lastPrompt;
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
        meta = j['meta'] as Map<String, dynamic>?;

  final int seq;
  final String type, id, messageId, text, status, model, level;
  final DateTime? ts;
  final bool sidechain, truncated, isError;
  final ToolUse? tool;
  final String? resultFor;
  final Map<String, dynamic>? usage, meta;
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

class PermissionRequest {
  PermissionRequest.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        sessionKey = j['session_key'] as String? ?? '',
        toolName = j['tool_name'] as String? ?? '',
        toolInput = j['tool_input'] as Map<String, dynamic>?,
        cwd = j['cwd'] as String? ?? '',
        expiresAt = DateTime.tryParse(j['expires_at'] as String? ?? '');
  final String id, sessionKey, toolName, cwd;
  final Map<String, dynamic>? toolInput;
  final DateTime? expiresAt;
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
