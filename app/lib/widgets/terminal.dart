import 'package:flutter/material.dart';

import '../models.dart';
import 'ansi.dart';

/// Renders a captured tmux screen with quick keys. Pinch-free: the font is
/// sized so the pane's width fits, and the user can scroll horizontally.
class TerminalView extends StatelessWidget {
  const TerminalView({super.key, required this.screen, required this.onKeys, required this.onText});
  final ScreenSnapshot? screen;
  final void Function(List<String>) onKeys;
  final void Function(String text, bool enter) onText;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.25, color: const Color(0xFFE6E6E6));
    final s = screen;
    return Column(children: [
      Expanded(
        child: Container(
          color: const Color(0xFF000000),
          width: double.infinity,
          child: s == null
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  reverse: true,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (var i = 0; i < s.lines.length; i++)
                          Text.rich(ansiToSpan(s.lines[i].isEmpty ? ' ' : s.lines[i], base), softWrap: false),
                      ]),
                    ),
                  ),
                ),
        ),
      ),
      _KeyBar(onKeys: onKeys),
    ]);
  }
}

class _KeyBar extends StatelessWidget {
  const _KeyBar({required this.onKeys});
  final void Function(List<String>) onKeys;
  @override
  Widget build(BuildContext context) {
    final keys = <(String, List<String>)>[
      ('Esc', ['Escape']),
      ('Tab', ['Tab']),
      ('↑', ['Up']),
      ('↓', ['Down']),
      ('←', ['Left']),
      ('→', ['Right']),
      ('Enter', ['Enter']),
      ('y', ['y']),
      ('n', ['n']),
      ('1', ['1']),
      ('2', ['2']),
      ('3', ['3']),
      ('^C', ['C-c']),
      ('^D', ['C-d']),
      ('^U', ['C-u']),
      ('S-Tab', ['BTab']),
      ('PgUp', ['PageUp']),
      ('PgDn', ['PageDown']),
    ];
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(children: [
          for (final (label, ks) in keys)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(40, 34), padding: const EdgeInsets.symmetric(horizontal: 10), visualDensity: VisualDensity.compact),
                onPressed: () => onKeys(ks),
                child: Text(label, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            ),
        ]),
      ),
    );
  }
}
