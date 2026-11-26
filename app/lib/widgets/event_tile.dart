import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../models.dart';

/// How a shell block from the chat is run: typed into the session as
/// `!command`, or in a tmux window of its own next to the session.
enum RunMode { bang, window }

/// One chat row. Tool uses and their results are paired by the caller.
class EventTile extends StatelessWidget {
  const EventTile({super.key, required this.event, this.result, this.showThinking = false, this.onRun, this.canBang = false});
  final Event event;
  final Event? result;
  final bool showThinking;

  /// Runs a shell block from an assistant message; null hides the run
  /// actions (read-only views such as a subagent's transcript).
  final void Function(String command, RunMode mode)? onRun;

  /// The session is at its prompt, so a `!` command can be typed now.
  final bool canBang;

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
            GptMarkdown(
              event.text,
              style: Theme.of(context).textTheme.bodyMedium,
              codeBuilder: (context, name, code, closed) => CodeBlockView(lang: name, code: code, onRun: closed ? onRun : null, canBang: canBang),
            ),
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
      case 'command':
        return CommandBlock(event: event);
      case 'tool.use':
        if (event.tool?.isQuestion ?? false) return _QuestionTile(use: event, result: result);
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

/// A question the session asked, with the picked answer once it is in.
class _QuestionTile extends StatelessWidget {
  const _QuestionTile({required this.use, this.result});
  final Event use;
  final Event? result;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final q = PendingQuestion.fromToolUse(use.tool!);
    final r = result;
    final answers = r == null ? const <(String, String)>[] : parseQuestionAnswers(r.text);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.help_outline, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          const Expanded(child: Text('Question', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
          if (r == null)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(r.isError ? Icons.error_outline : Icons.check, size: 16, color: r.isError ? cs.error : Colors.green),
        ]),
        for (final spec in q.questions)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (spec.header.isNotEmpty) _chip(context, spec.header, cs.primary),
              Text(spec.question, style: const TextStyle(fontSize: 13)),
            ]),
          ),
        if (r != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              answers.isEmpty ? 'Answered' : 'Answered: ${answers.map((a) => a.$2).join(', ')}',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant, fontStyle: FontStyle.italic),
            ),
          ),
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

/// The output of a `!` or slash command the session ran, as a terminal
/// block: the command, stdout, then stderr in the error colour.
class CommandBlock extends StatefulWidget {
  const CommandBlock({super.key, required this.event});
  final Event event;

  /// Lines shown before the block collapses.
  static const maxLines = 20;

  @override
  State<CommandBlock> createState() => _CommandBlockState();
}

class _CommandBlockState extends State<CommandBlock> {
  bool _all = false;

  static List<String> _lines(Object? v) {
    final s = (v is String ? v : '').replaceAll('\r', '').replaceFirst(RegExp(r'\n+$'), '');
    return s.isEmpty ? const [] : s.split('\n');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = widget.event.meta ?? const {};
    final command = widget.event.text.trim();
    final out = _lines(meta['stdout']);
    final err = _lines(meta['stderr']);
    final total = out.length + err.length;
    final collapse = total > CommandBlock.maxLines && !_all;
    final shownOut = collapse ? out.take(CommandBlock.maxLines).toList() : out;
    final shownErr = collapse ? err.take(CommandBlock.maxLines - shownOut.length).toList() : err;
    final source = switch (meta['source']) {
      'bang' => 'ran with !',
      'slash' => 'slash command',
      _ => '',
    };
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: command.isEmpty
                    ? Text('Command output', style: Theme.of(context).textTheme.labelMedium)
                    : SelectableText('\$ $command', style: mono.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (source.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 8), child: _chip(context, source, cs.outline)),
            ],
          ),
          if (shownOut.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(shownOut.join('\n'), style: mono),
            ),
          if (shownErr.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(shownErr.join('\n'), style: mono.copyWith(color: cs.error)),
            ),
          if (total == 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('(no output)', style: Theme.of(context).textTheme.labelSmall),
            ),
          if (total > CommandBlock.maxLines)
            TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32), visualDensity: VisualDensity.compact),
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? 'Show less' : 'Show all $total lines'),
            ),
        ],
      ),
    );
  }
}

/// Fence languages that are always shell.
const _shellLangs = {'sh', 'bash', 'zsh', 'shell', 'console'};

/// Commands that mark an unlabelled block as shell when its first line
/// starts with one.
const _shellWords = [
  'cd',
  'git',
  'go',
  'npm',
  'npx',
  'pnpm',
  'yarn',
  'flutter',
  'dart',
  'porthole',
  'sudo',
  'make',
  'systemctl',
  'journalctl',
  'curl',
  'wget',
  'docker',
  'kubectl',
  'python',
  'python3',
  'pip',
];
const _shellPaths = ['./', '~/', '/'];

/// The command text of a fenced block when it is shell, or null when it is
/// not. A `console` block keeps only its `$ ` lines, without the prompt
/// (all lines when none has one).
String? shellCommand(String lang, String code) {
  final l = lang.trim().toLowerCase();
  final text = _dedent(code.replaceAll('\r', ''));
  if (l == 'console') {
    final lines = text.split('\n');
    final prompted = [
      for (final line in lines)
        if (line.trimLeft().startsWith(r'$ ')) line.trimLeft().substring(2),
    ];
    final cmd = (prompted.isNotEmpty ? prompted : lines).join('\n');
    return cmd.trim().isEmpty ? null : cmd;
  }
  if (_shellLangs.contains(l)) return text.trim().isEmpty ? null : text;
  if (l.isNotEmpty) return null;
  final first = text.split('\n').map((x) => x.trim()).firstWhere((x) => x.isNotEmpty, orElse: () => '');
  if (first.isEmpty) return null;
  final word = first.split(RegExp(r'\s+')).first;
  if (_shellWords.contains(word) || _shellPaths.any(first.startsWith)) return text;
  return null;
}

/// [code] without surrounding blank lines and without the indent every
/// line shares.
String _dedent(String code) {
  final lines = code.split('\n');
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  final indents = [
    for (final l in lines)
      if (l.trim().isNotEmpty) l.length - l.trimLeft().length,
  ];
  final cut = indents.isEmpty ? 0 : indents.reduce((a, b) => a < b ? a : b);
  return [for (final l in lines) l.length >= cut ? l.substring(cut) : l.trimLeft()].join('\n');
}

/// [command] as one line for `!`, its lines joined with ` && `, or null
/// when a line is not a simple command (a continuation, a heredoc or a
/// comment).
String? bangCommand(String command) {
  final lines = [
    for (final l in command.split('\n'))
      if (l.trim().isNotEmpty) l.trim(),
  ];
  if (lines.isEmpty) return null;
  for (final l in lines) {
    if (l.endsWith('\\') || l.contains('<<') || l.startsWith('#')) return null;
    // A line that already ends in an operator or opens a compound command
    // would not survive being joined with "&&".
    if (RegExp(r'(;|&&|\|\||\||&|\{|\bthen|\bdo|\belse)$').hasMatch(l)) return null;
  }
  return lines.join(' && ');
}

/// A fenced code block in an assistant message: monospace, scrolls
/// sideways, with Copy and, for shell, the two ways to run it.
class CodeBlockView extends StatelessWidget {
  const CodeBlockView({super.key, required this.lang, required this.code, this.onRun, this.canBang = false});
  final String lang;
  final String code;
  final void Function(String command, RunMode mode)? onRun;
  final bool canBang;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = code.replaceFirst(RegExp(r'\n+$'), '');
    final run = onRun;
    final command = run == null ? null : shellCommand(lang, text);
    final bang = command == null ? null : bangCommand(command);
    Widget tool(Key key, IconData icon, String tip, VoidCallback? onTap) => Tooltip(
      message: tip,
      child: IconButton(
        key: key,
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        icon: Icon(icon),
        onPressed: onTap,
      ),
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(color: cs.surfaceContainerLowest, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(lang.trim(), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.outline)),
                ),
              ),
              if (command != null && bang != null)
                tool(
                  const ValueKey('run-bang'),
                  Icons.play_arrow,
                  canBang ? 'Run with !' : 'The session is busy; use Run in a window',
                  canBang ? () => run!(bang, RunMode.bang) : null,
                ),
              if (command != null)
                tool(
                  const ValueKey('run-window'),
                  Icons.open_in_new,
                  bang != null ? 'Run in a window' : 'multi-line: run in a window',
                  () => run!(command, RunMode.window),
                ),
              tool(const ValueKey('copy-code'), Icons.copy, 'Copy', () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Copied')));
              }),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
