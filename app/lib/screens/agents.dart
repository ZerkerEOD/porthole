import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../client.dart';
import '../main.dart';
import '../models.dart';
import '../widgets/event_tile.dart';

/// One line under the session header summarising its subagents; tap for the
/// list.
class AgentsStrip extends StatelessWidget {
  const AgentsStrip({super.key, required this.client, required this.session, this.onMessage});
  final DaemonClient client;
  final Session session;

  /// Called with text to put in the session's composer.
  final ValueChanged<String>? onMessage;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final agents = session.agents;
    final running = agents.where((a) => a.running).length;
    final tokens = agents.fold<int>(0, (n, a) => n + a.totalTokens);
    final total = session.agentCount;
    final label = [
      '$total ${total == 1 ? 'agent' : 'agents'}',
      if (running > 0) '$running working',
      if (tokens > 0) '${compactTokens(tokens)} tokens',
    ].join(' · ');
    return Material(
      color: cs.surfaceContainerHigh,
      child: InkWell(
        key: const ValueKey('agents-strip'),
        onTap: () => showAgentsSheet(context, client, session, onMessage: onMessage),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              running > 0
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(key: ValueKey('state-ring'), strokeWidth: 2, color: workingBlue),
                    )
                  : Icon(Icons.account_tree_outlined, size: 16, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cs.onSurface),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lists the session's subagents with their state, time and token use.
Future<void> showAgentsSheet(BuildContext context, DaemonClient client, Session session, {ValueChanged<String>? onMessage}) {
  var showAll = false;
  const firstPage = 20;
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (context, setSheetState) => ListenableBuilder(
        listenable: client,
        builder: (context, _) {
          final s = client.sessions[session.key] ?? session;
          final all = [...s.agents]
            ..sort((a, b) {
              if (a.running != b.running) return a.running ? -1 : 1;
              return (b.startedAt ?? DateTime(0)).compareTo(a.startedAt ?? DateTime(0));
            });
          final agents = showAll || all.length <= firstPage ? all : all.take(firstPage).toList();
          final hidden = all.length - agents.length;
          final earlier = s.agentCount - all.length;
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.6,
            maxChildSize: 0.95,
            builder: (context, ctl) => ListView(
              controller: ctl,
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text('Agents of ${s.displayTitle}', style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Subagents run inside the session and have no input of their own. Open one to read along; to steer it, message the session.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                for (final a in agents)
                  _AgentCard(
                    agent: a,
                    onOpen: () async {
                      final msg = await Navigator.of(context).push<String>(
                        MaterialPageRoute(
                          builder: (_) => AgentScreen(client: client, sessionKey: s.key, agent: a),
                        ),
                      );
                      if (msg != null && sheetCtx.mounted) {
                        Navigator.of(sheetCtx).pop();
                        onMessage?.call(msg);
                      }
                    },
                  ),
                if (hidden > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                    child: TextButton(onPressed: () => setSheetState(() => showAll = true), child: Text('Show $hidden more')),
                  ),
                if (earlier > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      '$earlier earlier ${earlier == 1 ? 'agent is' : 'agents are'} not listed; the daemon keeps the running ones and the most recent finished.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({required this.agent, required this.onOpen});
  final AgentInfo agent;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final a = agent;
    final (icon, color, state) = a.running
        ? (null, workingBlue, 'working')
        : a.finished
        ? (Icons.check_circle, readyGreen, 'finished')
        : (Icons.stop_circle_outlined, cs.outline, 'stopped');
    final elapsed = a.elapsed;
    final facts = [
      if (elapsed != null) compactDuration(elapsed),
      if (a.totalTokens > 0) '${compactTokens(a.inputTokens)} in · ${compactTokens(a.outputTokens)} out',
      if (a.toolUses > 0) '${a.toolUses} tool ${a.toolUses == 1 ? 'use' : 'uses'}',
      if (a.turns > 0) '${a.turns} ${a.turns == 1 ? 'turn' : 'turns'}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: icon == null
                        ? const CircularProgressIndicator(key: ValueKey('state-ring'), strokeWidth: 2, color: workingBlue)
                        : Icon(icon, size: 16, color: color),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      a.description.isEmpty ? a.type : a.description,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(8)),
                    child: Text(a.type, style: TextStyle(fontSize: 10, color: cs.onSecondaryContainer)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '$state${facts.isNotEmpty ? ' · $facts' : ''}${a.background ? ' · background' : ''}',
                style: TextStyle(fontSize: 12, color: color == cs.outline ? cs.onSurfaceVariant : color),
              ),
              if (a.lastText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(a.lastText, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A subagent's transcript, read-only, following it while it runs.
class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key, required this.client, required this.sessionKey, required this.agent});
  final DaemonClient client;
  final String sessionKey;
  final AgentInfo agent;

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  final _events = <Event>[];
  final _results = <String, Event>{};
  // Items: 0 the Load earlier row, 1..N the events, then an empty end
  // marker the list is anchored on (alignment 1.0) while it follows the end.
  final _itemScroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  bool _stickToBottom = true, _anchoredAtEnd = true, _pinScheduled = false;
  bool _userScrolling = false, _userMoved = false;
  int _anchorCount = -1, _itemCount = 0;
  final _tileKeys = Expando<GlobalKey>();
  StreamSubscription<(String, String, List<Event>)>? _sub;
  bool _loading = true, _hasMore = false, _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = widget.client.agentEvents.listen((e) {
      final (key, id, evs) = e;
      if (key == widget.sessionKey && id == widget.agent.id) _append(evs);
    });
    _positions.itemPositions.addListener(_onPositions);
    _subscribe();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _positions.itemPositions.removeListener(_onPositions);
    unawaited(widget.client.unsubscribeAgent(widget.sessionKey, widget.agent.id));
    super.dispose();
  }

  Future<void> _subscribe() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (evs, more) = await widget.client.subscribeAgent(widget.sessionKey, widget.agent.id, limit: 150);
      _events.clear();
      _results.clear();
      _append(evs);
      _hasMore = more;
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_events.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final (evs, more) = await widget.client.agentHistory(widget.sessionKey, widget.agent.id, before: _events.first.seq, limit: 150);
      if (!mounted) return;
      // Keep the top visible event in place as the indices shift.
      final top = _positions.itemPositions.value.where((p) => p.index >= 1).fold<ItemPosition?>(null, (a, p) => a == null || p.index < a.index ? p : a);
      if (!_stickToBottom && top != null && evs.isNotEmpty) {
        final target = top.index + evs.length;
        if (target <= _itemCount - 1) {
          _jumpTo(target, top.itemLeadingEdge);
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _jumpTo(target, top.itemLeadingEdge);
          });
        }
      }
      setState(() {
        _events.insertAll(0, evs);
        for (final e in evs) {
          if (e.type == 'tool.result' && e.resultFor != null) _results[e.resultFor!] = e;
        }
        _hasMore = more;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _append(List<Event> evs) {
    if (!mounted) return;
    setState(() {
      for (final e in evs) {
        if (e.type == 'tool.result' && e.resultFor != null) _results[e.resultFor!] = e;
        final i = _events.indexWhere((x) => x.seq == e.seq);
        if (i >= 0) {
          _events[i] = e;
        } else {
          _events.add(e);
        }
      }
    });
    // A list at the end follows: the build re-anchors it on the new count.
  }

  void _jumpTo(int index, double alignment) {
    if (!_itemScroll.isAttached) return;
    _anchoredAtEnd = false;
    _itemScroll.jumpTo(index: index, alignment: alignment);
  }

  /// Anchors the list on the end marker, now or after the next frame.
  void _pinToEnd({bool now = false}) {
    if (now) {
      if (!mounted || !_itemScroll.isAttached || _itemCount == 0) return;
      if (_anchoredAtEnd && _anchorCount == _itemCount) return;
      _anchoredAtEnd = true;
      _anchorCount = _itemCount;
      _itemScroll.jumpTo(index: _itemCount - 1, alignment: 1.0);
      return;
    }
    if (_pinScheduled) return;
    _pinScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pinScheduled = false;
      if (_stickToBottom) _pinToEnd(now: true);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _onPositions() {
    final ps = _positions.itemPositions.value;
    if (ps.isEmpty || _itemCount == 0) return;
    final user = _userScrolling || _userMoved;
    _userMoved = false;
    final last = ps.where((p) => p.index == _itemCount - 2).firstOrNull;
    final atBottom = last != null && last.itemTrailingEdge <= 1.02;
    if (!user && _stickToBottom && !atBottom) _pinToEnd(now: true);
    if (atBottom != _stickToBottom && (atBottom || user)) setState(() => _stickToBottom = atBottom);
    if (ps.any((p) => p.index == 0) && _hasMore && !_loadingMore && !_loading) _loadMore();
  }

  bool _onScroll(Notification n) {
    if (n is ScrollNotification && (n.depth != 0 || n.metrics.axis != Axis.vertical)) return false;
    if (n is ScrollMetricsNotification && (n.depth != 0 || n.metrics.axis != Axis.vertical)) return false;
    if (n is UserScrollNotification && n.direction != ScrollDirection.idle) {
      _userScrolling = true;
      _userMoved = true;
      _anchoredAtEnd = false;
    } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
      _userMoved = true;
      _anchoredAtEnd = false;
    } else if (n is ScrollEndNotification) {
      _userScrolling = false;
      if (_stickToBottom) _pinToEnd();
    } else if (n is ScrollMetricsNotification) {
      if (_stickToBottom && !_userScrolling) _pinToEnd();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final live = widget.client.sessions[widget.sessionKey]?.agents.where((a) => a.id == widget.agent.id).firstOrNull ?? widget.agent;
    final elapsed = live.elapsed;
    final facts = [
      live.running ? 'working' : (live.finished ? 'finished' : 'stopped'),
      if (elapsed != null) compactDuration(elapsed),
      if (live.totalTokens > 0) '${compactTokens(live.totalTokens)} tokens',
      if (live.toolUses > 0) '${live.toolUses} tool uses',
    ].join(' · ');
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(live.description.isEmpty ? live.type : live.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
            Text(
              '${live.type} · $facts',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _body()),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Read-only: the agent runs inside the session.', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop('About the agent working on "${live.description.isEmpty ? live.type : live.description}": '),
                    icon: const Icon(Icons.reply, size: 16),
                    label: const Text('Message the session'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _events.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _events.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!),
              const SizedBox(height: 12),
              FilledButton(onPressed: _subscribe, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (_events.isEmpty) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text('Nothing written yet.')),
      );
    }
    final count = _events.length + 2;
    _itemCount = count;
    if (_anchoredAtEnd && _anchorCount < 0) _anchorCount = count;
    if (_stickToBottom && !(_anchoredAtEnd && _anchorCount == count)) _pinToEnd();
    return NotificationListener<Notification>(
      onNotification: _onScroll,
      child: ScrollablePositionedList.builder(
        itemScrollController: _itemScroll,
        itemPositionsListener: _positions,
        initialScrollIndex: count - 1,
        initialAlignment: 1.0,
        itemCount: count,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _loadingMore
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    )
                  : (_hasMore ? TextButton(onPressed: _loadMore, child: const Text('Load earlier')) : const SizedBox(height: 4)),
            );
          }
          if (i == count - 1) return const SizedBox.shrink();
          final e = _events[i - 1];
          final tile = EventTile(key: _tileKeys[e] ??= GlobalKey(), event: e, result: e.tool != null ? _results[e.tool!.id] : null, showThinking: false, client: widget.client, sessionKey: widget.sessionKey);
          return i == count - 2 ? Padding(padding: const EdgeInsets.only(bottom: 12), child: tile) : tile;
        },
      ),
    );
  }
}
