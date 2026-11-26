import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../client.dart';
import '../main.dart';
import '../models.dart';
import '../prefs.dart';
import '../widgets/composer.dart';
import '../widgets/event_tile.dart';
import '../widgets/run_card.dart';
import '../widgets/terminal.dart';
import 'agents.dart';
import 'new_session.dart';
import 'question_flow.dart';

/// A key or text send that failed; the message is fit for a SnackBar.
class _SendError implements Exception {
  _SendError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Where a message sent from this phone stands until the transcript has it.
enum _OutState { sending, queued, sent, failed }

/// A message this phone sent that the transcript does not show yet.
class _Outgoing {
  _Outgoing(this.id, this.text) : sentAt = DateTime.now();
  final int id;
  final String text;
  final DateTime sentAt;
  _OutState state = _OutState.sending;
  String? error;
  late final String norm = normalizeMessage(text);
}

/// [t] trimmed with each run of whitespace collapsed to one space, the
/// form sent messages, queued messages and transcript text are matched in.
String normalizeMessage(String t) => t.trim().replaceAll(RegExp(r'\s+'), ' ');

/// After this long an unmatched message offers Dismiss.
const _outboxStale = Duration(minutes: 10);

/// Shown when a chat set to open at the last read position cannot find it.
const lostReadMarkNotice = "Couldn't find where you left off";

/// Pages of history searched for a read mark before giving up.
const _markSearchPages = 5;

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.client, required this.sessionKey, this.positionsListener});
  final DaemonClient client;
  final String sessionKey;
  /// Reports which chat items are on screen; for tests.
  final ItemPositionsListener? positionsListener;
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> with WidgetsBindingObserver {
  final List<Event> _events = [];
  final Map<String, Event> _results = {}; // tool_use_id -> result
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _composerGen = 0;
  bool _terminal = false;
  /// True while a fresh session has no transcript yet; the chat view shows
  /// a starting notice until the first events land.
  bool _starting = false;
  Timer? _retry;
  bool _showThinking = false;
  ScreenSnapshot? _screen;
  String? _paneError;
  List<Skill> _skills = const [];
  StreamSubscription? _evSub, _paneSub, _replacedSub, _noticeSub;
  // The chat list. Items: 0 the Load earlier row, 1..N the events, then
  // the pending bubbles, the Working row, and an empty end marker that the
  // list is anchored on (alignment 1.0) to keep the newest message at the
  // bottom whatever grows above it.
  final _itemScroll = ItemScrollController();
  late final ItemPositionsListener _positions = widget.positionsListener ?? ItemPositionsListener.create();
  bool _stickToBottom = true;
  /// True once the list sits on the end marker with [_anchorCount] items;
  /// cleared when the person scrolls or the list moves elsewhere.
  bool _anchoredAtEnd = false;
  int _anchorCount = -1;
  bool _pinScheduled = false;
  /// The item count of the last chat build.
  int _itemCount = 0;
  /// The person is dragging or flinging the list, or has since the last
  /// position report.
  bool _userScrolling = false, _userMoved = false;
  /// The Go to bottom animation is running.
  bool _animatingToEnd = false;
  /// Where the list is built: consumed by the first build of each list
  /// generation ([_listGen]).
  int _initialIndex = 0;
  double _initialAlignment = 0;
  int _listGen = 0;
  /// True between subscribing and knowing where to open.
  bool _opening = true;
  /// The first event newer than the read mark this chat opened at; the
  /// "New since you were here" divider goes above it. For this open only.
  int? _dividerSeq;
  /// The read position the screen shows now, written on idle, pause,
  /// leaving and every 10 s.
  ReadMark? _markCandidate;
  Timer? _markTimer;
  /// Keeps each event tile's state when the list re-anchors.
  final _tileKeys = Expando<GlobalKey>();
  String _key = '';
  /// The spawn placeholder's pane and tmux session, kept so the real
  /// session can be matched even after the placeholder is removed.
  String? _pendingPane, _pendingTmux;
  /// The question set answered from here, so its strip stays hidden until
  /// the daemon catches up.
  String? _answeredId;

  /// The run whose tmux window the terminal view shows instead of the
  /// session's own pane; null for the session pane.
  Run? _runPane;

  /// Messages sent from here that have not shown up in the transcript yet.
  final List<_Outgoing> _outbox = [];
  int _outboxSeq = 0;
  /// Rebuilds now and then while the outbox has entries, so an old one
  /// grows its Dismiss.
  Timer? _outboxTick;

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
    _noticeSub = widget.client.notices.listen((n) {
      if (n.$1 != _key || !mounted) return;
      // The client has already gone back to the session's own pane.
      if (n.$2 == DaemonClient.runWindowClosedNotice && _runPane != null) setState(() => _runPane = null);
      _toast(n.$2);
    });
    _positions.itemPositions.addListener(_onPositions);
    WidgetsBinding.instance.addObserver(this);
    _markTimer = Timer.periodic(const Duration(seconds: 10), (_) => _recordMark());
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
    _recordMark();
    _markCandidate = null;
    widget.client.moveComposerDraft(old, key);
    setState(() {
      _key = key;
      _pendingPane = null;
      _pendingTmux = null;
      _events.clear();
      _results.clear();
      _screen = null;
      _paneError = null;
      _runPane = null;
      _outbox.clear();
    });
    _syncOutboxTick();
    widget.client.unsubscribe(old);
    if (_terminal) widget.client.unsubscribePane(old);
    _subscribe();
    if (_terminal) _subscribePane();
  }

  Future<void> _subscribe() async {
    setState(() {
      _loading = true;
      _opening = true;
      _error = null;
    });
    try {
      final key = _key;
      var (evs, more) = await widget.client.subscribe(key, limit: 150);
      final mode = _openAt();
      final mark = mode == OpenAt.lastRead ? widget.client.readMarks[key] : null;
      var lost = false;
      if (mark != null) {
        // The mark may be older than the latest page: page back a little.
        var pages = 0;
        while (_markIndex(evs, mark) < 0 && more && evs.isNotEmpty && pages < _markSearchPages) {
          try {
            final (older, m) = await widget.client.history(key, before: evs.first.seq, limit: 150);
            if (older.isEmpty) break;
            evs = [...older, ...evs];
            more = m;
          } catch (_) {
            break;
          }
          pages++;
        }
        lost = _markIndex(evs, mark) < 0;
      }
      if (!mounted || key != _key) return;
      _events.clear();
      _results.clear();
      _placeOpening(evs, mode, lost ? null : mark);
      _append(evs, initial: true);
      _hasMore = more;
      _starting = false;
      _opening = false;
      if (lost && evs.isNotEmpty) _toast(lostReadMarkNotice);
    } catch (e) {
      final s = _session;
      if (s != null && (s.pending || (s.running && '$e'.contains('no transcript')))) {
        // Fresh session: nothing written yet. Stay in the chat view with a
        // starting notice and ask again until the transcript appears.
        _error = null;
        _starting = true;
        _retry?.cancel();
        _retry = Timer(const Duration(seconds: 3), () {
          if (mounted && _events.isEmpty) _subscribe();
        });
      } else {
        _error = '$e';
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  OpenAt _openAt() {
    try {
      return Provider.of<ChatPrefs?>(context, listen: false)?.openAt ?? OpenAt.bottom;
    } catch (_) {
      return OpenAt.bottom;
    }
  }

  /// The index in [evs] of the event [mark] points at: by transcript id,
  /// else by seq; -1 when it is not there.
  static int _markIndex(List<Event> evs, ReadMark mark) {
    if (mark.id.isNotEmpty) {
      final i = evs.lastIndexWhere((e) => e.id == mark.id);
      if (i >= 0) return i;
    }
    if (mark.seq > 0) return evs.lastIndexWhere((e) => e.seq == mark.seq);
    return -1;
  }

  /// Decides where the new list is built, from the opening setting: the
  /// end, the first block of the last assistant reply, or [mark].
  void _placeOpening(List<Event> evs, OpenAt mode, ReadMark? mark) {
    _listGen++;
    _dividerSeq = null;
    var index = -1;
    var align = 0.0;
    if (mode == OpenAt.lastMessage) {
      final last = evs.lastIndexWhere(_isReply);
      if (last >= 0) {
        var first = last;
        final mid = evs[last].messageId;
        if (mid.isNotEmpty) first = evs.indexWhere((e) => e.messageId == mid && _isReply(e));
        // Without message ids, the run of reply blocks it ends.
        if (mid.isEmpty) {
          while (first > 0 && _isReply(evs[first - 1])) {
            first--;
          }
        }
        index = first + 1;
      }
    } else if (mark != null) {
      final i = _markIndex(evs, mark);
      if (i >= 0) {
        index = i + 1;
        align = mark.align.clamp(-1.0, 1.0);
        _dividerSeq = evs.where((e) => e.seq > mark.newestSeq).firstOrNull?.seq;
      }
    }
    if (index < 0) {
      // The end marker, at the bottom edge.
      _initialIndex = 1 << 30; // clamped to the last item by the list
      _initialAlignment = 1.0;
      _stickToBottom = true;
      _anchoredAtEnd = true;
      _anchorCount = -1;
    } else {
      _initialIndex = index;
      _initialAlignment = align;
      _stickToBottom = false;
      _anchoredAtEnd = false;
    }
  }

  static bool _isReply(Event e) => e.type == 'assistant.text' || e.type == 'assistant.thinking';

  // ---- list position ----

  int get _endIndex => _itemCount - 1;
  int get _workIndex => _itemCount - 2;

  /// Anchors the list on the end marker, now (from a post-frame callback,
  /// where the list has its current item count) or after the next frame.
  void _pinToEnd({bool now = false}) {
    if (now) {
      if (!mounted || !_itemScroll.isAttached || _itemCount == 0) return;
      if (_anchoredAtEnd && _anchorCount == _itemCount) return;
      _anchoredAtEnd = true;
      _anchorCount = _itemCount;
      _itemScroll.jumpTo(index: _endIndex, alignment: 1.0);
      return;
    }
    if (_pinScheduled) return;
    _pinScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pinScheduled = false;
      if (_stickToBottom && !_animatingToEnd) _pinToEnd(now: true);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _jumpTo(int index, double alignment) {
    if (!_itemScroll.isAttached) return;
    _anchoredAtEnd = false;
    _itemScroll.jumpTo(index: index, alignment: alignment);
  }

  void _onPositions() {
    final ps = _positions.itemPositions.value;
    if (ps.isEmpty || _opening || _itemCount == 0) return;
    final user = _userScrolling || _userMoved;
    _userMoved = false;
    ItemPosition? work, first;
    for (final p in ps) {
      if (p.index == _workIndex) work = p;
      if (p.index == 0) first = p;
    }
    final atBottom = work != null && work.itemTrailingEdge <= 1.02;
    if (!user && !_animatingToEnd && _itemScroll.isAttached) {
      if (work != null && work.itemTrailingEdge < 0.995) {
        // Space under the end: the target sat too close to it.
        _pinToEnd(now: true);
      } else if (!_hasMore && first != null && first.itemLeadingEdge > 0.005 && !(work != null && work.itemTrailingEdge - first.itemLeadingEdge <= 1.0)) {
        // Space over the start of a chat taller than the view. With more
        // history, the next page fills it instead.
        _jumpTo(0, 0);
      } else if (_stickToBottom && !atBottom) {
        // A position report that is not at the end means the last pin did
        // not land (or the list moved on); pin again, unconditionally.
        _anchoredAtEnd = false;
        _pinToEnd(now: true);
      }
    }
    if (atBottom != _stickToBottom && (atBottom || user)) setState(() => _stickToBottom = atBottom);
    final m = _markFrom(ps);
    if (m != null) _markCandidate = m;
    if (first != null && _hasMore && !_loadingMore && !_loading) _loadMore();
  }

  bool _onScrollNotification(Notification n) {
    // Only the chat list's own scrolling, not a code block's.
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
      if (_stickToBottom && !_animatingToEnd) _pinToEnd();
      _recordMark();
    } else if (n is ScrollMetricsNotification) {
      // Something grew or the view changed size without a scroll.
      if (_stickToBottom && !_animatingToEnd && !_userScrolling) _pinToEnd();
    }
    return false;
  }

  /// The read position [ps] shows: the top visible event and its offset,
  /// or the last event when the end is in view.
  ReadMark? _markFrom(Iterable<ItemPosition> ps) {
    final n = _events.length;
    if (n == 0) return null;
    final newest = _events.last.seq;
    ReadMark at(Event e, double align) => ReadMark(seq: e.seq, id: e.id, align: align, newestSeq: newest);
    ItemPosition? top;
    var below = false;
    for (final p in ps) {
      if (p.itemTrailingEdge <= 0) continue;
      if (p.index == n && p.itemTrailingEdge <= 1.02) return at(_events.last, 0);
      if (p.index > n) below = true;
      if (p.index < 1 || p.index > n) continue;
      if (top == null || p.index < top.index) top = p;
    }
    if (top == null) return below ? at(_events.last, 0) : null;
    return at(_events[top.index - 1], top.itemLeadingEdge.clamp(-1.0, 1.0));
  }

  void _recordMark() {
    final m = _markCandidate;
    if (m == null || _opening) return;
    widget.client.setReadMark(_key, m);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) _recordMark();
  }

  Future<void> _loadMore() async {
    if (_events.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final key = _key;
      final before = _events.first.seq;
      final (evs, more) = await widget.client.history(key, before: before, limit: 150);
      if (!mounted || key != _key) return;
      // The new events go in at the front, which shifts every index: keep
      // the top visible event where it is by moving the list's anchor with
      // it. A list at the end re-anchors on the end marker instead.
      final top = _positions.itemPositions.value.where((p) => p.index >= 1 && p.index <= _events.length).fold<ItemPosition?>(null, (a, p) => a == null || p.index < a.index ? p : a);
      final shift = evs.length;
      if (!_stickToBottom && top != null && shift > 0) {
        final target = top.index + shift;
        if (target <= _itemCount - 1) {
          // Fits the current list: move before the rebuild, so no frame
          // shows the wrong items.
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

  void _append(List<Event> evs, {bool initial = false}) {
    setState(() {
      final added = <Event>[];
      for (final e in evs) {
        // A reconnect replays recent history; keep only what is new.
        if (!initial && e.seq > 0 && _events.isNotEmpty && e.seq <= _events.last.seq) continue;
        if (e.type == 'tool.result' && e.resultFor != null) _results[e.resultFor!] = e;
        _events.add(e);
        added.add(e);
      }
      _matchOutbox(added, initial: initial);
    });
    _syncOutboxTick();
    // A list at the end follows: the chat build re-anchors it when the
    // item count changes.
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
    final run = _runPane;
    try {
      final scr = run != null ? await widget.client.subscribeRunPane(key, run.paneId) : await widget.client.subscribePane(key);
      if (mounted && key == _key && _runPane == run) setState(() => _screen = scr);
    } catch (e) {
      if (run != null) {
        // The window could not be opened: say why and go back to the
        // session's own pane.
        _toast('Could not open the window: ${_describe(e)}');
        if (!mounted || key != _key || _runPane != run) return;
        setState(() {
          _runPane = null;
          _screen = null;
        });
        if (_terminal) _subscribePane();
        return;
      }
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
    if (on) _keepPlace();
    setState(() {
      _terminal = on;
      _screen = null;
      _paneError = null;
      _runPane = null;
    });
    if (on) {
      _subscribePane();
      if (_draftFor(_pendingQuestion()) != null) _toast('Draft answers are kept until you submit. The terminal shows the live dialog.');
    } else {
      widget.client.unsubscribePane(_key);
    }
  }

  /// Notes where the chat list is, so the list built when the chat comes
  /// back opens there.
  void _keepPlace() {
    _listGen++;
    if (_stickToBottom) {
      _initialIndex = 1 << 30;
      _initialAlignment = 1.0;
      _anchoredAtEnd = true;
      _anchorCount = -1;
      return;
    }
    final top = _positions.itemPositions.value.fold<ItemPosition?>(null, (a, p) => a == null || p.index < a.index ? p : a);
    _initialIndex = top?.index ?? _initialIndex;
    _initialAlignment = top?.itemLeadingEdge ?? _initialAlignment;
    _anchoredAtEnd = false;
  }

  /// Switches the terminal view to [run]'s tmux window.
  void _openRunWindow(Run run) {
    if (!_terminal) _keepPlace();
    setState(() {
      _terminal = true;
      _runPane = run;
      _screen = null;
      _paneError = null;
    });
    _subscribePane();
  }

  /// Back from a run's window to the session's own pane.
  void _closeRunWindow() {
    setState(() {
      _runPane = null;
      _screen = null;
      _paneError = null;
    });
    _subscribePane();
  }

  /// Fetches a finished run's saved output and shows it in a sheet.
  Future<void> _showRunLog(Run run) async {
    final ({String text, bool truncated}) log;
    try {
      log = await widget.client.runLog(_key, run.id);
    } catch (e) {
      _toast('Could not load the output: ${_describe(e)}');
      return;
    }
    if (!mounted) return;
    await showRunLogSheet(context, run, log.text, truncated: log.truncated);
  }

  /// True when a `!` command can be typed now: the session takes input and
  /// sits at its prompt with nothing open.
  bool get _canBang {
    final s = _session;
    if (s == null || !s.controllable) return false;
    return s.status == 'idle' || (s.status == 'waiting_input' && s.question == null);
  }

  /// Why Run with ! has to wait: the CLI holds messages that would go
  /// ahead of the command. Null when nothing is queued.
  String? get _bangBlocked {
    final n = _session?.queued.length ?? 0;
    if (n == 0) return null;
    return n == 1
        ? '1 message is queued ahead of this; wait for it to send, or use Run in a window.'
        : '$n messages are queued ahead of this; wait for them to send, or use Run in a window.';
  }

  /// Runs a shell block from the chat after the person confirms it.
  Future<void> _runFromChat(String command, RunMode mode) async {
    final feed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _RunSheet(command: command, mode: mode),
    );
    if (feed == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (mode == RunMode.bang) {
      final blocked = _bangBlocked;
      if (blocked != null) {
        _toast(blocked);
        return;
      }
      if (!_canBang) {
        _toast('The session is busy; use Run in a window');
        return;
      }
      // The outbox bubble shows the command until it lands, and a failure
      // with Retry.
      await _sendFromChat('!$command');
      return;
    }
    try {
      await widget.client.runCommand(_key, command, feed: feed);
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('Could not start the command: ${_describe(e)}')));
    }
  }

  Future<void> _runAction(Future<void> Function() f, String what) async {
    try {
      await f();
    } catch (e) {
      _toast('Could not $what: ${_describe(e)}');
    }
  }

  String _describe(Object e) => switch (e) {
        TimeoutException() => 'No reply from ${widget.client.info.displayName} after ${e.duration?.inSeconds ?? 5} s',
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

  /// Sends an attached image to the machine; a refusal carries the
  /// daemon's message. Large images get a longer wait than keystrokes.
  Future<String> _upload(PendingImage img) async {
    try {
      return await widget.client.putFile(_key, img.name, img.mediaType, img.bytes).timeout(const Duration(seconds: 60));
    } catch (e) {
      throw _SendError('Image not sent: ${_describe(e)}');
    }
  }

    Future<void> _sendText(String text, {required bool enter}) => _guard(widget.client.sendText(_key, text, enter: enter));

  /// Sends [text] with Enter and shows it at the bottom of the chat until
  /// the transcript has it. A failure stays on the bubble with Retry, so
  /// the caller (the chat composer) can clear its field. With [rethrowError]
  /// a failure instead drops the bubble and throws, for the terminal
  /// composer, which keeps its draft and shows the error itself.
  Future<void> _sendFromChat(String text, {bool rethrowError = false}) async {
    final o = _Outgoing(++_outboxSeq, text);
    setState(() {
      _outbox.add(o);
      _stickToBottom = true;
    });
    _syncOutboxTick();
    _scrollToEnd();
    final err = await _deliver(o);
    if (err != null && rethrowError) {
      if (mounted) setState(() => _outbox.remove(o));
      _syncOutboxTick();
      throw err;
    }
  }

  /// Sends an outbox entry and records how it went; returns the error.
  Future<_SendError?> _deliver(_Outgoing o) async {
    final key = _key;
    _SendError? err;
    try {
      await _sendText(o.text, enter: true);
    } on _SendError catch (e) {
      err = e;
    }
    // Gone already: the transcript caught up first, or the screen moved on.
    if (!mounted || key != _key || !_outbox.contains(o)) return err;
    setState(() {
      if (err != null) {
        o.state = _OutState.failed;
        o.error = err.message;
      } else {
        o.state = _session?.status == 'busy' ? _OutState.queued : _OutState.sent;
      }
    });
    return err;
  }

  void _retryOutgoing(_Outgoing o) {
    setState(() {
      o.state = _OutState.sending;
      o.error = null;
    });
    _deliver(o);
  }

  void _dismissOutgoing(_Outgoing o) {
    setState(() => _outbox.remove(o));
    _syncOutboxTick();
  }

  /// Drops the outbox entries the transcript now shows: a user message
  /// with the same text (or starting with it, as the CLI may append to a
  /// paste), or for `!cmd` the command it ran. Each event settles at most
  /// one entry, the oldest. On the initial load the transcript holds older
  /// history too, so only events from around the send or later count.
  void _matchOutbox(List<Event> evs, {bool initial = false}) {
    if (_outbox.isEmpty) return;
    for (final e in evs) {
      final o = _outbox.where((o) => _outboxMatches(o, e) && (!initial || e.ts == null || !e.ts!.isBefore(o.sentAt.subtract(const Duration(minutes: 2))))).firstOrNull;
      if (o != null) _outbox.remove(o);
      if (_outbox.isEmpty) return;
    }
  }

  static bool _outboxMatches(_Outgoing o, Event e) {
    final n = o.norm;
    if (n.isEmpty) return false;
    if (e.type == 'user') {
      final t = normalizeMessage(e.text);
      return t == n || t.startsWith(n);
    }
    if (e.type == 'command' && n.startsWith('!')) return normalizeMessage(e.text) == normalizeMessage(n.substring(1));
    return false;
  }

  void _syncOutboxTick() {
    if (_outbox.isEmpty || !mounted) {
      _outboxTick?.cancel();
      _outboxTick = null;
      return;
    }
    _outboxTick ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  /// Follows the end again; the next chat build anchors the list there.
  void _scrollToEnd() {
    _anchoredAtEnd = false;
    _pinToEnd();
  }

  /// The Go to bottom button. A jump, not an animation: a long animated
  /// scroll cross-fades two copies of the list, and the tiles' GlobalKeys
  /// must never be built twice at once.
  void _animateToEnd() {
    setState(() => _stickToBottom = true);
    if (!_itemScroll.isAttached || _itemCount == 0) return;
    _animatingToEnd = false;
    _anchoredAtEnd = false;
    _pinToEnd();
  }

  /// Puts text in the composer (from the agent view) and rebuilds it so the
  /// field shows it.
  void _prefill(String text) {
    widget.client.setComposerDraft(_key, text);
    setState(() => _composerGen++);
  }

  /// Opens the mode sheet. A session with a prompt or question open cannot
  /// change mode (Shift+Tab means something else inside a dialog), and the
  /// sheet says so instead of trying.
  Future<void> _pickMode() async {
    final s = _session;
    if (s == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!s.controllable) {
      messenger.showSnackBar(const SnackBar(content: Text('This session is read-only: it is not running inside tmux.')));
      return;
    }
    final busy = s.question != null || widget.client.permissions.values.any((p) => p.sessionKey == _key);
    if (busy) {
      messenger.showSnackBar(const SnackBar(content: Text('Answer the open prompt first, then change the mode.')));
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ModeSheet(current: s.permissionMode),
    );
    if (picked == null || picked == s.permissionMode || !mounted) return;
    try {
      final got = await widget.client.setMode(_key, picked);
      if (got != picked && mounted) {
        messenger.showSnackBar(SnackBar(content: Text('${PermissionMode.byValue(picked)?.label ?? picked} is not available in this session; it stays in ${PermissionMode.byValue(got)?.label ?? got}.')));
      }
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(_describe(e))));
    }
  }

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

  /// The question the session is waiting on, as the daemon records it.
  /// Only the daemon's id is accepted by `question.answer`, so the transcript
  /// is not consulted here (its tile still shows the answer once it lands).
  PendingQuestion? _pendingQuestion() {
    final q = _session?.question;
    return q != null && q.id != _answeredId && q.questions.isNotEmpty ? q : null;
  }

  QuestionDraft? _draftFor(PendingQuestion? q) => q == null ? null : widget.client.questionDraft(_key, q);

  Future<void> _openQuestion(PendingQuestion q) async {
    final r = await Navigator.of(context).push<QuestionFlowResult>(MaterialPageRoute(builder: (_) => QuestionFlowScreen(client: widget.client, sessionKey: _key, question: q)));
    if (!mounted) return;
    setState(() {
      if (r == QuestionFlowResult.answered) _answeredId = q.id;
    });
  }

  @override
  void dispose() {
    _recordMark();
    _markTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _positions.itemPositions.removeListener(_onPositions);
    widget.client.removeListener(_onClient);
    _retry?.cancel();
    _outboxTick?.cancel();
    _evSub?.cancel();
    _paneSub?.cancel();
    _replacedSub?.cancel();
    _noticeSub?.cancel();
    widget.client.unsubscribe(_key);
    if (_terminal) widget.client.unsubscribePane(_key);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final cs = Theme.of(context).colorScheme;
    final controllable = s?.controllable ?? false;
    final perms = widget.client.permissions.values.where((p) => p.sessionKey == _key).toList();
    final client = widget.client;
    final question = _pendingQuestion();
    final machine = client.info.displayName;
    final runs = client.runs.values.where((r) => r.key == _key).toList()..sort((a, b) => (b.startedAt ?? DateTime(0)).compareTo(a.startedAt ?? DateTime(0)));
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s?.displayTitle ?? _key, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
          Row(children: [
            if (s != null) providerBadge(context, s.provider),
            const SizedBox(width: 6),
            StatusGlyph(s, size: 12),
            const SizedBox(width: 4),
            Flexible(child: Text('${s == null ? 'unknown' : sessionStateLabel(context, s)} · ${widget.client.info.displayName} · ${s?.repo ?? ''}${(s?.model ?? '').isNotEmpty ? ' · ${_shortModel(s!.model)}' : ''}${(s?.account ?? '').isNotEmpty ? ' · ${s!.account}' : ''}${(s?.totalTokens ?? 0) > 0 ? ' · ${compactTokens(s!.totalTokens)} tokens' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant))),
          ]),
        ]),
        actions: [
          if (s != null && s.provider == 'claude' && s.running)
            _ModeButton(mode: s.permissionMode, enabled: controllable, onTap: _pickMode),
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
      body: GestureDetector(
        // A tap outside a field puts the keyboard away, in both views.
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: Column(children: [
          if (client.state != ConnState.connected)
            MaterialBanner(
              leading: const Icon(Icons.vpn_lock),
              content: Text(client.state == ConnState.connecting ? 'Reconnecting to $machine…' : (client.lastError ?? 'Connection to $machine lost. Reconnecting…')),
              actions: [TextButton(onPressed: () => client.connect(manual: true), child: const Text('Retry'))],
            ),
          if (s?.lastDenied case final d? when d.at != null && DateTime.now().difference(d.at!) < const Duration(minutes: 15))
            Material(
              color: cs.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(children: [
                  Icon(Icons.block, size: 16, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Auto mode blocked ${d.tool} ${relAgo(d.at)}. Blocked actions are listed under /permissions in the terminal.', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant))),
                ]),
              ),
            ),
          if (s != null && s.agents.isNotEmpty) AgentsStrip(client: widget.client, session: s, onMessage: _prefill),
          for (final p in perms) _PermissionCard(client: widget.client, req: p),
          if (question != null)
            _QuestionStrip(
              key: ValueKey('question-$_key-${question.id}'),
              count: question.questions.length + question.remaining,
              provider: s?.provider ?? 'claude',
              hasDraft: _draftFor(question) != null,
              recovered: question.recovered,
              onAnswer: () => _openQuestion(question),
            ),
          if (question == null && s != null && s.running && s.status == 'waiting_input')
            Material(
              color: cs.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
                child: Row(children: [
                  Icon(Icons.keyboard_outlined, size: 18, color: cs.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_terminal ? 'Waiting for your answer in the terminal' : 'Waiting for your answer', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onTertiaryContainer, fontWeight: FontWeight.w500))),
                  if (!_terminal && controllable) TextButton(onPressed: _toggleTerminal, child: const Text('Open terminal')),
                ]),
              ),
            ),
          if (s != null && s.running && !controllable)
            MaterialBanner(
              leading: const Icon(Icons.visibility_outlined),
              content: const Text('This session is not running inside tmux, so it is read-only here. Start sessions with `porthole wrap` or from the app to control them.'),
              actions: const [SizedBox.shrink()],
            ),
          for (final r in runs)
            RunCard(
              key: ValueKey('runcard-${r.id}'),
              run: r,
              onStop: () => _runAction(() => client.stopRun(_key, r.id), 'stop the command'),
              onOpen: controllable && !r.isDone ? () => _openRunWindow(r) : null,
              onFullOutput: () => _showRunLog(r),
              onDismiss: () => _runAction(() => client.dismissRun(_key, r.id), 'dismiss the command'),
            ),
          if (_terminal && _runPane != null) _runWindowStrip(_runPane!),
          Expanded(child: _terminal ? _terminalBody() : _chatBody()),
          if (!_terminal)
            Composer(
              key: ValueKey('composer-$_key-$_composerGen'),
              enabled: controllable,
              online: client.online,
              skills: _skills,
              hint: s?.status == 'waiting_input' ? 'The session is waiting for you' : 'Message ${s?.provider == 'codex' ? 'Codex' : 'Claude'}',
              initialText: client.composerDrafts[_key] ?? '',
              onChanged: (t) => client.setComposerDraft(_key, t),
              onSend: _sendFromChat,
              onUpload: _upload,
            ),
          if (_terminal && _runPane == null)
            Composer(
              key: ValueKey('tcomposer-$_key'),
              enabled: controllable,
              online: client.online,
              skills: _skills,
              hint: 'Type into the terminal',
              initialText: client.composerDrafts[_key] ?? '',
              onChanged: (t) => client.setComposerDraft(_key, t),
              onSend: (t) => _sendFromChat(t, rethrowError: true),
            ),
        ]),
      ),
      floatingActionButton: !_terminal && !_stickToBottom
          ? FloatingActionButton.small(onPressed: _animateToEnd, child: const Icon(Icons.arrow_downward))
          : null,
    );
  }

  String _shortModel(String m) => m.replaceFirst('claude-', '').replaceAll(RegExp(r'-\d{8}$'), '');

  Widget _terminalBody() => _runPane != null
      ? TerminalView(screen: _screen, error: _paneError, onRetry: _subscribePane, onKeys: (_) => _viewOnly(), onText: (_, _) => _viewOnly())
      : TerminalView(screen: _screen, error: _paneError, onRetry: _subscribePane, onKeys: _sendKeys, onText: _typeText);

  void _viewOnly() => _toast('This window is view-only here. Stop the command from its card.');

  /// Above the terminal while it shows a run's window.
  Widget _runWindowStrip(Run r) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
        child: Row(children: [
          Icon(Icons.open_in_new, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text('Window: \$ ${r.command.replaceAll('\n', ' ')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
          TextButton(onPressed: _closeRunWindow, child: const Text('Back to session')),
        ]),
      ),
    );
  }

  /// The messages on their way in, below the transcript: what the daemon
  /// says the CLI is holding, in its order, then what this phone sent that
  /// the daemon does not list. A message in both shows once.
  List<Widget> _pendingBubbles() {
    final s = _session;
    final queuedLabel = 'Queued · sends when ${s?.provider == 'codex' ? 'Codex' : 'Claude'} finishes the current turn';
    final left = List.of(_outbox);
    final out = <Widget>[];
    final daemon = s?.queued ?? const <String>[];
    for (var i = 0; i < daemon.length; i++) {
      final n = normalizeMessage(daemon[i]);
      final mine = left.where((o) => o.norm == n && o.state != _OutState.failed).firstOrNull;
      if (mine != null) left.remove(mine);
      out.add(PendingBubble(key: ValueKey('queued-$i'), text: mine?.text ?? daemon[i], label: queuedLabel));
    }
    final now = DateTime.now();
    for (final o in left) {
      final stale = now.difference(o.sentAt) >= _outboxStale;
      out.add(switch (o.state) {
        _OutState.sending => PendingBubble(key: ValueKey('outbox-${o.id}'), text: o.text, label: 'Sending…'),
        _OutState.failed => PendingBubble(
            key: ValueKey('outbox-${o.id}'),
            text: o.text,
            label: 'Could not send: ${o.error ?? 'unknown error'}',
            error: true,
            actions: [
              TextButton(onPressed: () => _retryOutgoing(o), child: const Text('Retry')),
              TextButton(onPressed: () => _dismissOutgoing(o), child: const Text('Dismiss')),
            ],
          ),
        _ => PendingBubble(
            key: ValueKey('outbox-${o.id}'),
            text: o.text,
            label: '${o.state == _OutState.queued ? queuedLabel : 'Sent'}${stale ? ' · tap to dismiss' : ''}',
            onLabelTap: stale ? () => _dismissOutgoing(o) : null,
          ),
      });
    }
    return out;
  }

  Widget _chatBody() {
    final s = _session;
    final pending = _pendingBubbles();
    if (_events.isEmpty && pending.isEmpty && (_starting || (s?.pending ?? false))) return _startingBody(s);
    if (_loading && (_opening || _events.isEmpty) && pending.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _events.isEmpty) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!), const SizedBox(height: 12), FilledButton(onPressed: _subscribe, child: const Text('Retry'))])));
    }
    if (_events.isEmpty && pending.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Nothing in the transcript yet. Send a message to begin, or switch to the terminal view.', textAlign: TextAlign.center)));
    }
    final bangBlocked = _bangBlocked;
    final count = _events.length + pending.length + 3;
    _itemCount = count;
    if (_anchoredAtEnd && _anchorCount < 0) _anchorCount = count;
    if (_stickToBottom && !_animatingToEnd && !(_anchoredAtEnd && _anchorCount == count)) _pinToEnd();
    final list = ScrollablePositionedList.builder(
      key: ValueKey('chat-$_listGen'),
      itemScrollController: _itemScroll,
      itemPositionsListener: _positions,
      initialScrollIndex: _initialIndex.clamp(0, count - 1),
      initialAlignment: _initialAlignment,
      itemCount: count,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _loadingMore ? const Center(child: Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))) : (_hasMore ? TextButton(onPressed: _loadMore, child: const Text('Load earlier')) : const SizedBox(height: 4)),
          );
        }
        if (i > _events.length && i <= _events.length + pending.length) return pending[i - _events.length - 1];
        if (i == count - 1) return const SizedBox.shrink();
        if (i == count - 2) {
          if (s != null && s.running && s.status == 'busy') {
            return const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 20), child: Row(children: [SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 10), Text('Working…', style: TextStyle(fontSize: 12))]));
          }
          return const SizedBox(height: 16);
        }
        final e = _events[i - 1];
        final tile = EventTile(
          key: _tileKeys[e] ??= GlobalKey(),
          event: e,
          result: e.tool != null ? _results[e.tool!.id] : null,
          showThinking: _showThinking,
          onRun: (s?.controllable ?? false) ? _runFromChat : null,
          canBang: _canBang,
          bangBlockedReason: bangBlocked,
          client: widget.client,
          sessionKey: _key,
        );
        if (e.seq != _dividerSeq) return tile;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const NewSinceDivider(), tile]);
      },
    );
    return NotificationListener<Notification>(onNotification: _onScrollNotification, child: list);
  }

  /// A fresh session before its transcript exists: where it runs, and that
  /// it is on its way.
  Widget _startingBody(Session? s) {
    final cs = Theme.of(context).colorScheme;
    final place = s == null ? '' : (s.repo.isNotEmpty ? s.repo : s.cwd);
    final mode = PermissionMode.byValue(s?.permissionMode ?? '');
    final where = [if (place.isNotEmpty) place, widget.client.info.displayName, if (mode != null) '${mode.label} mode'].join(' · ');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(height: 20),
          Text('Starting the session…', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(where, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// One line for a question the session is waiting on, in both views; the
/// answers are collected in [QuestionFlowScreen].
class _QuestionStrip extends StatelessWidget {
  const _QuestionStrip({super.key, required this.count, required this.provider, required this.hasDraft, required this.onAnswer, this.recovered = false});
  final int count;
  final String provider;
  final bool hasDraft;
  final bool recovered;
  final VoidCallback onAnswer;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final who = provider == 'codex' ? 'Codex' : 'Claude';
    return Material(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        child: Row(children: [
          Icon(Icons.help_outline, size: 18, color: cs.onPrimaryContainer),
          const SizedBox(width: 8),
          Expanded(child: Text('${count == 1 ? '$who is asking a question' : '$who is asking $count questions'}${recovered ? ' (one at a time)' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onPrimaryContainer, fontWeight: FontWeight.w500))),
          FilledButton(onPressed: onAnswer, child: Text(hasDraft ? 'Answer (draft saved)' : 'Answer')),
        ]),
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.client, required this.req});
  final DaemonClient client;
  final PermissionRequest req;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final input = req.toolInput;
    final detail = req.recovered ? req.detail : '${input?['command'] ?? input?['file_path'] ?? input?['url'] ?? input?['description'] ?? ''}';
    final description = req.recovered ? req.description : input?['description'];
    final note = description is String && description.isNotEmpty && description != detail ? description : '';
    final plan = req.recovered && req.toolName == 'Plan approval';
    final title = plan ? 'Plan ready to approve' : (req.recovered ? req.toolName : 'Permission: ${req.toolName}');
    return Card(
      color: cs.primaryContainer,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(req.recovered && req.toolName == 'Plan approval' ? Icons.checklist : Icons.security, color: cs.primary, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(title.isEmpty ? 'Permission' : title, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
          if (note != '') Padding(padding: const EdgeInsets.only(top: 4), child: Text(note, style: Theme.of(context).textTheme.bodySmall)),
          if (detail != '' && plan)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: Material(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(8),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: GptMarkdown(detail, style: Theme.of(context).textTheme.bodySmall),
                  ),
                ),
              ),
            )
          else if (detail != '')
            Padding(padding: const EdgeInsets.only(top: 6), child: SelectableText(detail, style: const TextStyle(fontFamily: 'monospace', fontSize: 12), minLines: 1, maxLines: 8)),
          if (req.recovered && req.prompt.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(req.prompt, style: const TextStyle(fontWeight: FontWeight.w500))),
          const SizedBox(height: 8),
          if (req.recovered)
            // The CLI's own options, as numbered on screen; the first Yes is
            // the primary action and a plain No stays quiet.
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (var i = 0; i < req.options.length; i++)
                if (i == 0)
                  FilledButton(onPressed: () => client.answerPermissionOption(req.id, i), child: Text(req.options[i]))
                else if (req.options[i] == 'No')
                  TextButton(onPressed: () => client.answerPermissionOption(req.id, i), child: const Text('No'))
                else
                  OutlinedButton(
                    onPressed: () async {
                      await client.answerPermissionOption(req.id, i);
                      if (req.options[i].startsWith('Tell Claude') && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Now type what to change in the message box.')));
                      }
                    },
                    child: Text(req.options[i], maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
            ])
          else
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

/// The permission-mode chip in the session header: tap to change it.
class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.mode, required this.enabled, required this.onTap});
  final String mode;
  final bool enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final m = PermissionMode.byValue(mode);
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: m == null ? 'Permission mode' : '${m.label} mode${enabled ? ' · tap to change' : ''}',
      child: TextButton(
        key: const ValueKey('mode-button'),
        onPressed: onTap,
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 36), foregroundColor: enabled ? cs.onSurface : cs.outline),
        child: Text(m == null ? 'Mode' : '${m.glyph} ${m.short}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// Lists the modes Shift+Tab can reach, the current one checked.
class _ModeSheet extends StatelessWidget {
  const _ModeSheet({required this.current});
  final String current;
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Permission mode', style: Theme.of(context).textTheme.titleLarge)),
          for (final m in PermissionMode.switchable(current))
            ListTile(
              leading: Icon(m.value == current ? Icons.radio_button_checked : Icons.radio_button_off, color: m.value == current ? Theme.of(context).colorScheme.primary : null),
              title: Text('${m.glyph} ${m.label}'),
              subtitle: Text(m.description),
              onTap: () => Navigator.of(context).pop(m.value),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text('Changing the mode presses Shift+Tab in the terminal on your behalf. Auto mode is only offered when this account has it.', style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// Confirms a run from the chat: the exact command, what will happen, and
/// for a window whether the output goes back to the session. Pops the feed
/// choice (true for `!`), or null on Cancel.
class _RunSheet extends StatefulWidget {
  const _RunSheet({required this.command, required this.mode});
  final String command;
  final RunMode mode;
  @override
  State<_RunSheet> createState() => _RunSheetState();
}

class _RunSheetState extends State<_RunSheet> {
  bool _feed = true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bang = widget.mode == RunMode.bang;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(bang ? 'Run with !' : 'Run in a window', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(color: cs.surfaceContainerLowest, borderRadius: BorderRadius.circular(8)),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    bang ? '!${widget.command}' : widget.command,
                    key: const ValueKey('run-sheet-command'),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              bang
                  ? 'Typed into the session as `!…`; the output lands in the conversation.'
                  : 'Runs in a tmux window next to the session; the output is sent to the session when it finishes.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (!bang)
              SwitchListTile(
                key: const ValueKey('run-sheet-feed'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Send output to the session'),
                value: _feed,
                onChanged: (v) => setState(() => _feed = v),
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(key: const ValueKey('run-sheet-run'), onPressed: () => Navigator.of(context).pop(bang ? true : _feed), child: const Text('Run')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The line above the first message that arrived since the chat was last
/// read.
class NewSinceDivider extends StatelessWidget {
  const NewSinceDivider({super.key});
  static const caption = 'New since you were here';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final line = Expanded(child: Divider(height: 1, thickness: 1, color: cs.primary.withValues(alpha: 0.5)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(children: [
        line,
        Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text(caption, style: TextStyle(fontSize: 11, color: cs.primary))),
        line,
      ]),
    );
  }
}
