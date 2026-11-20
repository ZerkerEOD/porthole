/// Data types mirroring the daemon's wire protocol (proto/protocol.md).
library;

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
        stale = j['_stale'] as bool? ?? false;

  final String key, id, provider, title, cwd, repo, branch, status, model, account, lastPrompt;
  final bool running, controllable, spawned, pending;
  /// True for sessions restored from the last-seen cache while the machine
  /// is unreachable; replaced by live data on the next hello.
  final bool stale;
  final String? paneId, tmuxSession;
  final DateTime? startedAt, updatedAt;

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
}

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
