import 'package:flutter/material.dart';

import '../models.dart';

/// The pinned card for a question the session is waiting on: one section
/// per question with its options, a free-text "Other" field, and Submit.
class QuestionCard extends StatefulWidget {
  const QuestionCard({super.key, required this.question, required this.onSubmit, required this.onOpenTerminal});
  final PendingQuestion question;

  /// Sends the answers; resolves to null when accepted, else the reason.
  final Future<String?> Function(List<QuestionAnswer> answers) onSubmit;
  final VoidCallback onOpenTerminal;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  late final List<int?> _single;
  late final List<Set<int>> _multi;
  late final List<TextEditingController> _other;
  bool _busy = false;
  String? _reason;

  @override
  void initState() {
    super.initState();
    final n = widget.question.questions.length;
    _single = List.filled(n, null);
    _multi = List.generate(n, (_) => <int>{});
    _other = List.generate(n, (_) => TextEditingController());
  }

  @override
  void dispose() {
    for (final c in _other) {
      c.dispose();
    }
    super.dispose();
  }

  bool _answered(int i) => _single[i] != null || _multi[i].isNotEmpty || _other[i].text.trim().isNotEmpty;
  bool get _complete => widget.question.questions.isNotEmpty && List.generate(widget.question.questions.length, _answered).every((a) => a);

  List<QuestionAnswer> _answers() => [
    for (var i = 0; i < widget.question.questions.length; i++)
      QuestionAnswer(
        index: widget.question.questions[i].multiSelect ? null : _single[i],
        indices: widget.question.questions[i].multiSelect && _multi[i].isNotEmpty ? (_multi[i].toList()..sort()) : null,
        text: _other[i].text.trim().isEmpty ? null : _other[i].text.trim(),
      ),
  ];

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _reason = null;
    });
    final reason = await widget.onSubmit(_answers());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _reason = reason;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final qs = widget.question.questions;
    // Bounded so a long question set scrolls instead of pushing the
    // transcript off the screen.
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
      child: Card(
        color: cs.primaryContainer,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.help_outline, color: cs.primary, size: 18),
                  const SizedBox(width: 8),
                  const Text('Question', style: TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var i = 0; i < qs.length; i++) _section(context, i, qs[i])]),
                ),
              ),
              if (_reason != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_reason!, style: TextStyle(color: cs.error, fontSize: 13)),
                ),
              const SizedBox(height: 4),
              Row(
                children: [
                  TextButton(onPressed: _busy ? null : widget.onOpenTerminal, child: const Text('Open terminal')),
                  const Spacer(),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  FilledButton(onPressed: _complete && !_busy ? _submit : null, child: const Text('Submit')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, int i, QuestionSpec q) {
    final cs = Theme.of(context).colorScheme;
    final enabled = !_busy;
    Widget tile(int j, QuestionOption o) {
      final subtitle = o.description.isNotEmpty ? Text(o.description, style: const TextStyle(fontSize: 12)) : null;
      if (q.multiSelect) {
        return CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _multi[i].contains(j),
          enabled: enabled,
          title: Text(o.label),
          subtitle: subtitle,
          onChanged: (v) => setState(() => v == true ? _multi[i].add(j) : _multi[i].remove(j)),
        );
      }
      return RadioListTile<int>(dense: true, contentPadding: EdgeInsets.zero, value: j, enabled: enabled, title: Text(o.label), subtitle: subtitle);
    }

    final options = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var j = 0; j < q.options.length; j++) tile(j, q.options[j])]);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (q.header.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: cs.primary),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(q.header, style: TextStyle(fontSize: 10, color: cs.primary)),
            ),
          Text(q.question, style: const TextStyle(fontSize: 14)),
          if (q.multiSelect) options else RadioGroup<int>(groupValue: _single[i], onChanged: enabled ? (v) => setState(() => _single[i] = v) : (_) {}, child: options),
          TextField(
            controller: _other[i],
            enabled: enabled,
            minLines: 1,
            maxLines: 3,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Other', hintText: 'Type your own answer', isDense: true, border: OutlineInputBorder()),
          ),
        ],
      ),
    );
  }
}
