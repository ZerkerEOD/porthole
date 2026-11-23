import 'package:flutter/material.dart';

import '../models.dart';

/// Multi-line input with slash-command autocomplete. The text is editable
/// while the machine is unreachable; only Send waits for the connection.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.onSend, required this.skills, this.enabled = true, this.online = true, this.hint = 'Message', this.initialText = '', this.onChanged});
  final Future<void> Function(String text) onSend;
  final List<Skill> skills;
  final bool enabled;
  /// False while the connection is down: Send is disabled and the field
  /// says so.
  final bool online;
  final String hint;
  /// The draft restored into the field when the composer is built.
  final String initialText;
  /// Every edit, and an empty string once a send went through.
  final void Function(String text)? onChanged;
  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  late final _ctl = TextEditingController(text: widget.initialText);
  final _focus = FocusNode();
  bool _sending = false;

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<Skill> get _matches {
    final t = _ctl.text;
    if (!t.startsWith('/') || t.contains('\n')) return const [];
    final q = t.substring(1).toLowerCase();
    final head = q.split(' ').first;
    if (q.contains(' ')) return const [];
    return widget.skills.where((s) => s.name.toLowerCase().contains(head)).take(8).toList();
  }

  Future<void> _send() async {
    final text = _ctl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      _ctl.clear();
      widget.onChanged?.call('');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final matches = _matches;
    return Material(
      color: cs.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (matches.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in matches)
                    ListTile(
                      dense: true,
                      leading: Icon(s.source == 'builtin' ? Icons.bolt : Icons.auto_awesome, size: 18),
                      title: Text('/${s.name}', style: const TextStyle(fontFamily: 'monospace')),
                      subtitle: s.description.isNotEmpty ? Text(s.description, maxLines: 2, overflow: TextOverflow.ellipsis) : null,
                      trailing: Text(s.source, style: Theme.of(context).textTheme.labelSmall),
                      onTap: () {
                        _ctl.text = '/${s.name} ';
                        _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
                        widget.onChanged?.call(_ctl.text);
                        setState(() {});
                        _focus.requestFocus();
                      },
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: TextField(
                  controller: _ctl,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  onChanged: (t) {
                    widget.onChanged?.call(t);
                    setState(() {});
                  },
                  decoration: InputDecoration(
                    hintText: widget.enabled ? widget.hint : 'Read-only: not running in tmux',
                    helperText: widget.enabled && !widget.online ? 'Sends when reconnected' : null,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                    filled: true,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
              ),
              IconButton.filled(onPressed: widget.enabled && widget.online && !_sending ? _send : null, icon: _sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send)),
            ]),
          ),
        ]),
      ),
    );
  }
}
