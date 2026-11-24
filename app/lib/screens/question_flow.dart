import 'package:flutter/material.dart';

import '../client.dart';
import '../models.dart';

/// Why the flow closed: answered from here, or the question went away
/// while it was open (answered in the terminal, or replaced). Null when
/// the user closed it; the draft is kept then.
enum QuestionFlowResult { answered, gone }

/// Shown when the question clears underneath an open flow.
const questionGoneNotice = 'This question was answered in the terminal';

/// One page per question, then a review page, for a question set the
/// session is waiting on. Answers are kept as a draft on the client until
/// they are submitted or the question goes away.
class QuestionFlowScreen extends StatefulWidget {
  const QuestionFlowScreen({super.key, required this.client, required this.sessionKey, required this.question});
  final DaemonClient client;
  final String sessionKey;
  final PendingQuestion question;

  @override
  State<QuestionFlowScreen> createState() => _QuestionFlowScreenState();
}

class _QuestionFlowScreenState extends State<QuestionFlowScreen> {
  late final String _draftKey = DaemonClient.questionDraftKey(widget.sessionKey, widget.question);
  late final QuestionDraft _draft;
  late final List<TextEditingController> _other;
  late final List<TextEditingController> _notes;
  /// Pages whose notes field has been opened.
  final Set<int> _notesOpen = {};
  late final PageController _pages;
  late int _page;
  bool _submitting = false;
  bool _left = false;
  String? _error;
  /// Previews expanded past their 12-line cap, as `(question, option)`.
  final Set<(int, int)> _expanded = {};

  List<QuestionSpec> get _qs => widget.question.questions;
  int get _count => _qs.length;
  bool get _onReview => _page >= _count;

  @override
  void initState() {
    super.initState();
    _draft = widget.client.questionDraft(widget.sessionKey, widget.question) ?? QuestionDraft();
    _other = [for (var i = 0; i < _count; i++) TextEditingController(text: _draft.other[i] ?? '')];
    _notes = [for (var i = 0; i < _count; i++) TextEditingController(text: _draft.notes[i] ?? '')];
    _notesOpen.addAll([for (var i = 0; i < _count; i++) if (_draft.notes[i]?.trim().isNotEmpty ?? false) i]);
    _page = _draft.page.clamp(0, _count);
    _pages = PageController(initialPage: _page);
    widget.client.addListener(_onClient);
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClient);
    for (final c in _other) {
      c.dispose();
    }
    for (final c in _notes) {
      c.dispose();
    }
    _pages.dispose();
    super.dispose();
  }

  /// The question as the daemon sees it now; null once it is gone.
  PendingQuestion? get _live {
    final q = widget.client.sessions[widget.sessionKey]?.question;
    return q != null && q.hash == widget.question.hash ? q : null;
  }

  void _onClient() {
    if (!mounted) return;
    if (_live == null && !_submitting) {
      _leaveGone();
      return;
    }
    setState(() {});
  }

  void _leaveGone() {
    if (!mounted || _left) return;
    _left = true;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(questionGoneNotice)));
    Navigator.of(context).pop(QuestionFlowResult.gone);
  }

  void _save() {
    _draft.page = _page;
    widget.client.setQuestionDraft(_draftKey, _draft);
  }

  void _go(int page) {
    FocusScope.of(context).unfocus();
    setState(() {
      _page = page.clamp(0, _count);
      _error = null;
    });
    _pages.jumpToPage(_page);
    _save();
  }

  String? _text(int i) {
    final t = _draft.other[i]?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  String? _note(int i) {
    final t = _draft.notes[i]?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  /// Whether page [i] holds an answer the daemon accepts: a multi-select
  /// needs choices or text (or both); a single-select needs exactly one of
  /// a choice and text.
  bool _valid(int i) {
    final typed = _text(i) != null;
    if (_qs[i].multiSelect) return (_draft.multi[i]?.isNotEmpty ?? false) || typed;
    return (_draft.single[i] != null) != typed;
  }

  bool get _complete => _count > 0 && List.generate(_count, _valid).every((a) => a);

  List<QuestionAnswer> _answers() => [
        for (var i = 0; i < _count; i++)
          if (_qs[i].multiSelect)
            QuestionAnswer(
              indices: (_draft.multi[i]?.isNotEmpty ?? false) ? (_draft.multi[i]!.toList()..sort()) : null,
              text: _text(i),
            )
          else
            QuestionAnswer(
              index: _draft.single[i],
              text: _draft.single[i] == null ? _text(i) : null,
              notes: _note(i),
            ),
      ];

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.client.answerQuestion(widget.sessionKey, widget.question.id, _answers()).timeout(const Duration(seconds: 10));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = switch (e) {
          StateError() => e.message,
          _ => 'No reply from ${widget.client.info.displayName}. Try again.',
        };
      });
      // The question may have gone away while the request was out.
      if (_live == null) _leaveGone();
      return;
    }
    widget.client.dropQuestionDraft(_draftKey);
    if (!mounted || _left) return;
    _left = true;
    Navigator.of(context).pop(QuestionFlowResult.answered);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final online = widget.client.online;
    final canSubmit = online && !_submitting && _complete && _live != null;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        title: Text(_onReview ? 'Review' : widget.question.recovered ? 'Question ${_page + 1} of ${_count + widget.question.remaining}' : 'Question ${_page + 1} of $_count'),
      ),
      body: GestureDetector(
        // A tap outside a field puts the keyboard away.
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: Column(children: [
          if (!online)
            MaterialBanner(
              leading: const Icon(Icons.vpn_lock),
              content: Text('Connection to ${widget.client.info.displayName} lost. Reconnecting… Your answers are kept.'),
              actions: [TextButton(onPressed: () => widget.client.connect(manual: true), child: const Text('Retry'))],
            ),
          Expanded(
            child: PageView(
              controller: _pages,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var i = 0; i < _count; i++) _questionPage(context, i),
                _reviewPage(context),
              ],
            ),
          ),
          // In the body, not the Scaffold's bottom bar, so it rises with
          // the keyboard.
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(children: [
                if (_page > 0) TextButton(onPressed: _submitting ? null : () => _go(_page - 1), child: const Text('Back')),
                const Spacer(),
                if (_submitting)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                if (_onReview)
                  FilledButton(onPressed: canSubmit ? _submit : null, child: const Text('Submit'))
                else
                  FilledButton(onPressed: _valid(_page) ? () => _go(_page + 1) : null, child: const Text('Next')),
              ]),
            ),
          ),
        ]),
      ),
      backgroundColor: cs.surface,
    );
  }

  Widget _header(BuildContext context, QuestionSpec q) {
    final cs = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (q.header.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(border: Border.all(color: cs.primary), borderRadius: BorderRadius.circular(10)),
          child: Text(q.header, style: TextStyle(fontSize: 11, color: cs.primary)),
        ),
      Text(q.question, style: const TextStyle(fontSize: 16)),
    ]);
  }

  Widget _questionPage(BuildContext context, int i) {
    final q = _qs[i];
    final cs = Theme.of(context).colorScheme;
    final enabled = !_submitting;
    Widget tile(int j, QuestionOption o) {
      final subtitle = o.description.isNotEmpty ? Text(o.description, style: const TextStyle(fontSize: 12)) : null;
      if (q.multiSelect) {
        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _draft.multi[i]?.contains(j) ?? false,
          enabled: enabled,
          title: Text(o.label),
          subtitle: subtitle,
          onChanged: (v) {
            setState(() {
              final set = _draft.multi.putIfAbsent(i, () => <int>{});
              v == true ? set.add(j) : set.remove(j);
            });
            _save();
          },
        );
      }
      return RadioListTile<int>(contentPadding: EdgeInsets.zero, value: j, enabled: enabled, title: Text(o.label), subtitle: subtitle);
    }

    final options = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var j = 0; j < q.options.length; j++) ...[
        tile(j, q.options[j]),
        if (q.options[j].preview.isNotEmpty) _preview(context, i, j, q.options[j].preview),
      ],
    ]);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        _header(context, q),
        const SizedBox(height: 4),
        Text(q.multiSelect ? 'Select all that apply' : 'Select one', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        const SizedBox(height: 8),
        if (q.multiSelect)
          options
        else
          RadioGroup<int>(
            groupValue: _draft.single[i],
            onChanged: enabled
                ? (v) {
                    // A choice and a typed answer are exclusive here.
                    setState(() {
                      v == null ? _draft.single.remove(i) : _draft.single[i] = v;
                      _draft.other.remove(i);
                      _other[i].clear();
                    });
                    _save();
                  }
                : (_) {},
            child: options,
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _other[i],
          enabled: enabled,
          minLines: 1,
          maxLines: 4,
          onChanged: (t) {
            setState(() {
              t.isEmpty ? _draft.other.remove(i) : _draft.other[i] = t;
              if (!q.multiSelect && t.trim().isNotEmpty) _draft.single.remove(i);
            });
            _save();
          },
          decoration: InputDecoration(labelText: q.multiSelect ? 'Other' : 'Other (instead of the options above)', hintText: 'Type your own answer', border: const OutlineInputBorder()),
        ),
        if (!q.multiSelect) ...[
          const SizedBox(height: 8),
          if (_notesOpen.contains(i))
            TextField(
              controller: _notes[i],
              enabled: enabled,
              minLines: 1,
              maxLines: 4,
              onChanged: (t) {
                setState(() => t.isEmpty ? _draft.notes.remove(i) : _draft.notes[i] = t);
                _save();
              },
              decoration: const InputDecoration(labelText: 'Notes', hintText: 'Anything to add to your choice', border: OutlineInputBorder()),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: enabled ? () => setState(() => _notesOpen.add(i)) : null,
                icon: const Icon(Icons.notes, size: 18),
                label: const Text('Add notes (optional)'),
              ),
            ),
        ],
      ],
    );
  }

  static const _previewLines = 12;

  Widget _preview(BuildContext context, int i, int j, String text) {
    final cs = Theme.of(context).colorScheme;
    final lines = text.split('\n');
    final open = _expanded.contains((i, j));
    final long = lines.length > _previewLines;
    final shown = long && !open ? lines.take(_previewLines).join('\n') : text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.all(10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(shown, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3)),
          ),
        ),
        if (long)
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => setState(() => open ? _expanded.remove((i, j)) : _expanded.add((i, j))),
            child: Text(open ? 'Show less' : 'Show more'),
          ),
      ]),
    );
  }

  Widget _reviewPage(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        for (var i = 0; i < _count; i++) ...[
          if (i > 0) const Divider(height: 24),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _header(context, _qs[i])),
            TextButton(onPressed: _submitting ? null : () => _go(i), child: const Text('Edit')),
          ]),
          const SizedBox(height: 4),
          if (_valid(i)) ...[
            Text(_summary(i), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            if (_note(i) case final n?) Padding(padding: const EdgeInsets.only(top: 2), child: Text('Notes: $n', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant))),
          ] else
            Text('Question ${i + 1} needs an answer', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: cs.error)),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
          ),
      ],
    );
  }

  String _summary(int i) {
    final q = _qs[i];
    final labels = <String>[];
    if (q.multiSelect) {
      final picked = _draft.multi[i]?.toList() ?? <int>[];
      picked.sort();
      labels.addAll([for (final j in picked) if (j < q.options.length) q.options[j].label]);
    } else {
      final s = _draft.single[i];
      if (s != null && s < q.options.length) labels.add(q.options[s].label);
    }
    final other = _text(i);
    if (other != null) labels.add(other);
    return labels.join(', ');
  }
}
