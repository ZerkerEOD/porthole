import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../models.dart';

/// One chat row. Tool uses and their results are paired by the caller.
class EventTile extends StatelessWidget {
  const EventTile({super.key, required this.event, this.result, this.showThinking = false});
  final Event event;
  final Event? result;
  final bool showThinking;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (event.type) {
      case 'user':
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.86),
            margin: const EdgeInsets.fromLTRB(48, 6, 12, 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(16)),
            child: SelectableText(event.text, style: TextStyle(color: cs.onPrimaryContainer)),
          ),
        );
      case 'assistant.text':
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (event.sidechain) _chip(context, 'subagent', cs.tertiary),
            GptMarkdown(event.text, style: Theme.of(context).textTheme.bodyMedium),
            if (event.truncated) _truncNote(context),
          ]),
        );
      case 'assistant.thinking':
        if (!showThinking || event.text.trim().isEmpty) return const SizedBox.shrink();
        return _Collapsible(
          icon: Icons.psychology_outlined,
          title: 'Thinking',
          color: cs.outline,
          child: Text(event.text, style: TextStyle(color: cs.onSurfaceVariant, fontStyle: FontStyle.italic, fontSize: 13)),
        );
      case 'tool.use':
        return _ToolCard(use: event, result: result);
      case 'tool.result':
        return const SizedBox.shrink(); // rendered inside its tool card
      case 'status':
        return const SizedBox.shrink();
      case 'compact':
        return _divider(context, 'Context compacted');
      case 'model_switch':
        return _divider(context, 'Model: ${event.model}');
      case 'system':
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Row(children: [
            Icon(event.level == 'error' ? Icons.error_outline : Icons.info_outline, size: 16, color: event.level == 'error' ? cs.error : cs.outline),
            const SizedBox(width: 6),
            Expanded(child: Text(event.text, style: TextStyle(color: event.level == 'error' ? cs.error : cs.onSurfaceVariant, fontSize: 12))),
          ]),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _divider(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [const Expanded(child: Divider()), Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(t, style: Theme.of(context).textTheme.labelSmall)), const Expanded(child: Divider())]),
      );
}

Widget _chip(BuildContext context, String t, Color c) => Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: c), borderRadius: BorderRadius.circular(8)),
      child: Text(t, style: TextStyle(fontSize: 10, color: c)),
    );

Widget _truncNote(BuildContext context) => Text('(truncated; full text on the machine)', style: Theme.of(context).textTheme.labelSmall);

class _Collapsible extends StatefulWidget {
  const _Collapsible({required this.icon, required this.title, required this.child, this.color, this.trailing});
  final IconData icon;
  final String title;
  final Widget child;
  final Color? color;
  final Widget? trailing;
  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(widget.icon, size: 16, color: widget.color ?? cs.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontFamily: 'monospace'))),
              if (widget.trailing != null) widget.trailing!,
              Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
            ]),
          ),
        ),
        if (_open) Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), child: widget.child),
      ]),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.use, this.result});
  final Event use;
  final Event? result;

  String _summary() {
    final t = use.tool;
    if (t == null) return '';
    final i = t.input;
    if (i is Map) {
      for (final k in ['command', 'file_path', 'path', 'pattern', 'query', 'url', 'description', 'prompt']) {
        if (i[k] is String && (i[k] as String).isNotEmpty) return i[k] as String;
      }
      if (i['command'] is List) return (i['command'] as List).join(' ');
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = use.tool?.name ?? 'tool';
    final sum = _summary().split('\n').first;
    final done = result != null;
    final err = result?.isError ?? false;
    Widget trailing = done
        ? Icon(err ? Icons.error_outline : Icons.check, size: 16, color: err ? cs.error : Colors.green)
        : const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2));
    String input;
    try {
      input = const JsonEncoder.withIndent('  ').convert(use.tool?.input);
    } catch (_) {
      input = '${use.tool?.input}';
    }
    return _Collapsible(
      icon: _iconFor(name),
      title: sum.isNotEmpty ? '$name  $sum' : name,
      color: err ? cs.error : null,
      trailing: Padding(padding: const EdgeInsets.only(right: 6), child: trailing),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _mono(context, input, maxLines: 20),
        if (done) ...[
          const SizedBox(height: 6),
          Row(children: [
            Text('Result', style: Theme.of(context).textTheme.labelSmall),
            const Spacer(),
            IconButton(visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.copy), onPressed: () => Clipboard.setData(ClipboardData(text: result!.text))),
          ]),
          _mono(context, result!.text, maxLines: 40),
          if (result!.truncated) _truncNote(context),
        ],
      ]),
    );
  }

  static IconData _iconFor(String n) {
    switch (n) {
      case 'Bash':
      case 'shell':
        return Icons.terminal;
      case 'Read':
        return Icons.description_outlined;
      case 'Edit':
      case 'Write':
      case 'apply_patch':
        return Icons.edit_outlined;
      case 'Grep':
      case 'Glob':
        return Icons.search;
      case 'WebSearch':
      case 'WebFetch':
      case 'web_search':
        return Icons.public;
      case 'Agent':
        return Icons.smart_toy_outlined;
      default:
        return Icons.build_outlined;
    }
  }

  Widget _mono(BuildContext context, String s, {int maxLines = 30}) {
    final lines = s.split('\n');
    final clipped = lines.length > maxLines ? '${lines.take(maxLines).join('\n')}\n… (${lines.length - maxLines} more lines)' : s;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLowest, borderRadius: BorderRadius.circular(6)),
      child: SelectableText(clipped, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
    );
  }
}
