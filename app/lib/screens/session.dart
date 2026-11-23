import 'dart:async';

import 'package:flutter/material.dart';

import '../client.dart';
import '../main.dart';
import '../models.dart';
import '../widgets/composer.dart';
import '../widgets/event_tile.dart';
import '../widgets/question_card.dart';
import '../widgets/terminal.dart';
import 'new_session.dart';

/// A key or text send that failed; the message is fit for a SnackBar.
class _SendError implements Exception {
  _SendError(this.message);
  final String message;
  @override
  String toString() => message;
}

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.client, required this.sessionKey});
  final DaemonClient client;
  final String sessionKey;
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final List<Event> _events = [];
  final Map<String, Event> _results = {}; // tool_use_id -> result
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  bool _terminal = false;
  bool _showThinking = false;
  ScreenSnapshot? _screen;
  String? _paneError;
  List<Skill> _skills = const [];
  StreamSubscription? _evSub, _paneSub, _replacedSub;
  final _scroll = ScrollController();
  bool _stickToBottom = true;
  String _key = '';
  /// The spawn placeholder's pane and tmux session, kept so the real
  /// session can be matched even after the placeholder is removed.
  String? _pendingPane, _pendingTmux;
  /// The question set answered from here, so its card stays hidden until
  /// the transcript catches up.
  String? _answeredId;

  Session? get _session => widget.client.sessions[_key];

  @override
  void initState() {
    super.initState();
    _key = widget.sessionKey;
    final s = _session;
    if (s != null && s.pending) {
      _pendingPane = s.paneId;
      _pendingTmux = s.tmuxSession;
    }
    widget.client.addListener(_onClient);
    _evSub = widget.client.events.listen((e) {
      if (e.$1 != _key) return;
      _append(e.$2);
    });
    _paneSub = widget.client.panes.listen((p) {
      if (p.$1 != _key || !_terminal) return;
      setState(() {
        _screen = p.$2;
        _paneError = null;
      });
    });
    _replacedSub = widget.client.replaced.listen((r) {
      if (r.$1 == _key) _switchTo(r.$2);
    });
    _scroll.addListener(() {
      final atBottom = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
      if (atBottom != _stickToBottom) setState(() => _stickToBottom = atBottom);
      if (_scroll.position.pixels <= 40 && _hasMore && !_loadingMore) _loadMore();
    });
    _subscribe();
    _loadSkills();
  }

  void _onClient() {
    final c = widget.client;
    final s = _session;
    // A spawn placeholder becomes the real session on the same pane. The
    // daemon announces it with session.replaced; this is the fallback for
    // one that removes the placeholder first, or lists the real session
    // while the placeholder is still here.
    if (s != null && s.pending) {
      _pendingPane = s.paneId;
      _pendingTmux = s.tmuxSession;
    }
    if (s == null || s.pending) {
      final real = _realSession();
      if (real != null) _switchTo(real.key);
    }
    if (!c.online && (_screen != null || _paneError != null)) {
      // The pane is gone with the socket; show the connecting state.
      _screen = null;
      _paneError = null;
    }
    if (c.online && _terminal && _session?.controllable == true && _screen == null && _paneError == null && !c.hasPaneSubscription(_key)) _subscribePane();
    if (mounted) setState(() {});
  }

  Session? _realSession() {
    final pane = _pendingPane;
    final tmux = _pendingTmux;
    if (pane == null && tmux == null) return null;
    return widget.client.sessions.values.where((x) => !x.pending && x.key != _key && ((pane != null && x.paneId == pane) || (tmux != null && x.tmuxSession == tmux))).firstOrNull;
  }

  /// Moves the screen to [key] (the real session behind a placeholder):
  /// reloads the transcript and, in terminal mode, the pane, keeping the mode.
  void _switchTo(String key) {
    if (key == _key || !mounted) return;
    final old = _key;
    setState(() {
      _key = key;
      _pendingPane = null;
      _pendingTmux = null;
      _events.clear();
      _results.clear();
      _screen = null;
      _paneError = null;
    });
    widget.client.unsubscribe(old);
    if (_terminal) widget.client.unsubscribePane(old);
    _subscribe();
    if (_terminal) _subscribePane();
  }

  Future<void> _subscribe() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (evs, more) = await widget.client.subscribe(_key, limit: 150);
      _events.clear();
      _results.clear();
      _append(evs, initial: true);
      _hasMore = more;
    } catch (e) {
      final s = _session;
      if (s != null && (s.pending || (s.running && '$e'.contains('no transcript')))) {
        // Fresh session: nothing written yet. Show the terminal until it is.
        _error = null;
        if (!_terminal && s.controllable) {
          _terminal = true;
          _subscribePane();
        }
        Timer(const Duration(seconds: 3), () {
          if (mounted && _events.isEmpty) _subscribe();
        });
      } else {
        _error = '$e';
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_events.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final before = _events.first.seq;
      final (evs, more) = await widget.client.history(_key, before: before, limit: 150);
      final prevMax = _scroll.position.maxScrollExtent;
      setState(() {
        _events.insertAll(0, evs);
        for (final e in evs) {
          if (e.type == 'tool.result' && e.resultFor != null) _results[e.resultFor!] = e;
        }
        _hasMore = more;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.pixels + (_scroll.position.maxScrollExtent - prevMax));
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _append(List<Event> evs, {bool initial = false}) {
    setState(() {
      for (final e in evs) {
        // A reconnect replays recent history; keep only what is new.
        if (!initial && e.seq > 0 && _events.isNotEmpty && e.seq <= _events.last.seq) continue;
        if (e.type == 'tool.result' && e.resultFor != null) _results[e.resultFor!] = e;
        _events.add(e);
      }
    });
    if (initial || _stickToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  Future<void> _loadSkills() async {
    try {
      final s = _session;
      final sk = await widget.client.skills(s?.provider ?? '', s?.cwd ?? '');
      if (mounted) setState(() => _skills = sk);
    } catch (_) {}
  }

  Future<void> _subscribePane() async {
    final key = _key;
    if (mounted && _paneError != null) setState(() => _paneError = null);
    try {
      final scr = await widget.client.subscribePane(key);
      if (mounted && key == _key) setState(() => _screen = scr);
    } catch (e) {
      if (mounted && key == _key) {
        setState(() {
          _screen = null;
          _paneError = _describe(e);
        });
      }
    }
  }

  void _toggleTerminal() {
    final on = !_terminal;
    setState(() {
      _terminal = on;
      _screen = null;
      _paneError = null;
    });
    if (on) {
      _subscribePane();
    } else {
      widget.client.unsubscribePane(_key);
    }
  }

  String _describe(Object e) => switch (e) {
        TimeoutException() => 'No reply from ${widget.client.info.displayName} after 5 s',
        StateError() => e.message,
        _ => '$e',
      };

  /// Waits at most 5 s for the daemon to accept a send and turns any
  /// failure into a [_SendError] with a short message.
  Future<void> _guard(Future<void> f) async {
    try {
      await f.timeout(const Duration(seconds: 5));
    } catch (e) {
      throw _SendError(_describe(e));
    }
  }

  Future<void> _sendText(String text, {required bool enter}) => _guard(widget.client.sendText(_key, text, enter: enter));

  Future<void> _sendKeys(List<String> keys) async {
    try {
      await _guard(widget.client.sendKeys(_key, keys));
    } on _SendError catch (e) {
      _toast('Keys not sent: ${e.message}');
    }
  }

  Future<void> _typeText(String text, bool enter) async {
    try {
      await _sendText(text, enter: enter);
    } on _SendError catch (e) {
      _toast('Text not sent: ${e.message}');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<String?> _answer(String id, List<QuestionAnswer> answers) async {
    try {
      await _guard(widget.client.answerQuestion(_key, id, answers));
    } on _SendError catch (e) {
      return e.message;
    }
    if (mounted) setState(() => _answeredId = id);
    return null;
  }

  /// The question the session is waiting on: the daemon's record first, else
  /// the newest question tool use that has no result yet (nothing may have
  /// happened in the transcript since it).
  PendingQuestion? _pendingQuestion() {
    final s = _session;
    if (s == null) return null;
    final q = s.question;
    if (q != null && q.id != _answeredId) return q;
    if (!s.running) return null;
    for (var i = _events.length - 1; i >= 0; i--) {
      final e = _events[i];
      switch (e.type) {
        case 'tool.use':
          final t = e.tool;
          if (t == null || !t.isQuestion || _results.containsKey(t.id) || t.id == _answeredId) return null;
          final pq = PendingQuestion.fromToolUse(t);
          return pq.questions.isEmpty ? null : pq;
        case 'user':
        case 'assistant.text':
        case 'tool.result':
        case 'system':
        case 'compact':
          return null;
      }
    }
    return null;
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClient);
    _evSub?.cancel();
    _paneSub?.cancel();
    _replacedSub?.cancel();
    widget.client.unsubscribe(_key);
    if (_terminal) widget.client.unsubscribePane(_key);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final cs = Theme.of(context).colorScheme;
    final controllable = s?.controllable ?? false;
    final perms = widget.client.permissions.values.where((p) => p.sessionKey == _key).toList();
    final question = _pendingQuestion();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s?.displayTitle ?? _key, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
          Row(children: [
            if (s != null) providerBadge(context, s.provider),
            const SizedBox(width: 6),
            Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor(context, s?.status ?? 'unknown'))),
            const SizedBox(width: 4),
            Flexible(child: Text('${widget.client.info.displayName} · ${statusLabel(s?.status ?? 'unknown')} · ${s?.repo ?? ''}${(s?.model ?? '').isNotEmpty ? ' · ${_shortModel(s!.model)}' : ''}${(s?.account ?? '').isNotEmpty ? ' · ${s!.account}' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant))),
          ]),
        ]),
        actions: [
          // Leaving the terminal is always allowed; entering it needs a pane.
          IconButton(tooltip: _terminal ? 'Chat view' : 'Terminal view', icon: Icon(_terminal ? Icons.chat_bubble_outline : Icons.terminal), onPressed: controllable || _terminal ? _toggleTerminal : null),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'thinking':
                  setState(() => _showThinking = !_showThinking);
                case 'resume':
                  final ns = await Navigator.of(context).push<Session>(MaterialPageRoute(builder: (_) => NewSessionScreen(client: widget.client, resume: s)));
                  if (ns != null && context.mounted) {
                    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => SessionScreen(client: widget.client, sessionKey: ns.key)));
                  }
                case 'interrupt':
                  _sendKeys(['Escape']);
                case 'reload':
                  _subscribe();
              }
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'thinking', checked: _showThinking, child: const Text('Show thinking')),
              if (s != null && !s.running) const PopupMenuItem(value: 'resume', child: Text('Resume in tmux…')),
              if (controllable) const PopupMenuItem(value: 'interrupt', child: Text('Interrupt (Esc)')),
              const PopupMenuItem(value: 'reload', child: Text('Reload')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        for (final p in perms) _PermissionCard(client: widget.client, req: p),
        if (question != null)
          QuestionCard(
            key: ValueKey('question-$_key-${question.id}'),
            question: question,
            onSubmit: (a) => _answer(question.id, a),
            onOpenTerminal: () {
              if (!_terminal) _toggleTerminal();
            },
          ),
        if (question == null && s != null && s.running && s.status == 'waiting_input')
          Material(
            color: cs.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Icon(Icons.keyboard_outlined, size: 18, color: cs.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(child: Text('Waiting for your answer', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onTertiaryContainer, fontWeight: FontWeight.w500))),
              ]),
            ),
          ),
        if (s != null && s.running && !controllable)
          MaterialBanner(
            leading: const Icon(Icons.visibility_outlined),
            content: const Text('This session is not running inside tmux, so it is read-only here. Start sessions with `porthole wrap` or from the app to control them.'),
            actions: const [SizedBox.shrink()],
          ),
        Expanded(child: _terminal ? _terminalBody() : _chatBody()),
        if (!_terminal)
          Composer(
            key: ValueKey('composer-$_key'),
            enabled: controllable,
            skills: _skills,
            hint: s?.status == 'waiting_input' ? 'The session is waiting for you' : 'Message ${s?.provider == 'codex' ? 'Codex' : 'Claude'}',
            onSend: (t) => _sendText(t, enter: true),
          ),
        if (_terminal)
          Composer(
            key: ValueKey('tcomposer-$_key'),
            enabled: controllable,
            skills: _skills,
            hint: 'Type into the terminal',
            onSend: (t) => _sendText(t, enter: true),
          ),
      ]),
      floatingActionButton: !_terminal && !_stickToBottom
          ? FloatingActionButton.small(onPressed: () => _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut), child: const Icon(Icons.arrow_downward))
          : null,
    );
  }

  String _shortModel(String m) => m.replaceFirst('claude-', '').replaceAll(RegExp(r'-\d{8}$'), '');

  Widget _terminalBody() => TerminalView(screen: _screen, error: _paneError, onRetry: _subscribePane, onKeys: _sendKeys, onText: _typeText);

  Widget _chatBody() {
    if (_loading && _events.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _events.isEmpty) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!), const SizedBox(height: 12), FilledButton(onPressed: _subscribe, child: const Text('Retry'))])));
    }
    if (_events.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Nothing in the transcript yet. Send a message to begin, or switch to the terminal view.', textAlign: TextAlign.center)));
    }
    final s = _session;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      itemCount: _events.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) {
          return _loadingMore ? const Center(child: Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))) : (_hasMore ? TextButton(onPressed: _loadMore, child: const Text('Load earlier')) : const SizedBox(height: 4));
        }
        if (i == _events.length + 1) {
          if (s != null && s.running && s.status == 'busy') {
            return const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 8), child: Row(children: [SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 10), Text('Working…', style: TextStyle(fontSize: 12))]));
          }
          return const SizedBox(height: 4);
        }
        final e = _events[i - 1];
        return EventTile(event: e, result: e.tool != null ? _results[e.tool!.id] : null, showThinking: _showThinking);
      },
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.client, required this.req});
  final DaemonClient client;
  final PermissionRequest req;
  @override
  Widget build(BuildContext context) {
    final input = req.toolInput;
    final detail = input?['command'] ?? input?['file_path'] ?? input?['url'] ?? input?['description'] ?? '';
    final description = input?['description'];
    final note = description is String && description.isNotEmpty && description != detail ? description : '';
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(Icons.security, color: Theme.of(context).colorScheme.primary, size: 18), const SizedBox(width: 8), Text('Permission: ${req.toolName}', style: const TextStyle(fontWeight: FontWeight.w600))]),
          if (detail != '') Padding(padding: const EdgeInsets.only(top: 6), child: SelectableText('$detail', style: const TextStyle(fontFamily: 'monospace', fontSize: 12), minLines: 1, maxLines: 8)),
          if (note != '') Padding(padding: const EdgeInsets.only(top: 4), child: Text(note, style: Theme.of(context).textTheme.bodySmall)),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => client.answerPermission(req.id, 'deny'), child: const Text('Deny')),
            const SizedBox(width: 8),
            FilledButton(onPressed: () => client.answerPermission(req.id, 'allow'), child: const Text('Allow')),
          ]),
        ]),
      ),
    );
  }
}
