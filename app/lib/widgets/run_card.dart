import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';

/// One command running in a tmux window next to the session: its state,
/// how long it has run, the last lines of output and what happens to them.
class RunCard extends StatefulWidget {
  const RunCard({super.key, required this.run, this.onStop, this.onOpen, this.onDismiss});
  final Run run;
  final VoidCallback? onStop;
  final VoidCallback? onOpen;
  final VoidCallback? onDismiss;

  @override
  State<RunCard> createState() => _RunCardState();
}

class _RunCardState extends State<RunCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(RunCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// A one-second tick for the elapsed time while the command runs.
  void _sync() {
    if (widget.run.isDone) {
      _tick?.cancel();
      _tick = null;
    } else {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static String _elapsed(Duration d) {
    final s = d.inSeconds;
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s';
    return '${s ~/ 3600}h ${((s % 3600) ~/ 60).toString().padLeft(2, '0')}m';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = widget.run;
    final Widget glyph = !r.isDone
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(key: ValueKey('state-ring'), strokeWidth: 2, color: workingBlue),
          )
        : Icon(r.failed ? Icons.error : Icons.check_circle, key: const ValueKey('run-state'), size: 16, color: r.failed ? crimsonBright : readyGreen);
    final status = !r.isDone ? 'running' : (r.stopped ? 'stopped' : (r.exit == null ? 'done' : 'exit ${r.exit}'));
    final footer = r.fed ? 'Output sent to the session' : (r.queued ? 'Output queued for the next turn' : '');
    final lines = r.tailLines;
    return Card(
      key: ValueKey('run-${r.id}'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      color: cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                glyph,
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '\$ ${r.command.replaceAll('\n', ' ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Text('$status · ${_elapsed(r.elapsed())}', style: TextStyle(fontSize: 11, color: r.failed ? crimsonBright : cs.onSurfaceVariant)),
              ],
            ),
            if (lines.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 8, right: 4),
                constraints: const BoxConstraints(maxHeight: 10 * 12 * 1.3 + 16),
                decoration: BoxDecoration(color: cs.surfaceContainerLowest, borderRadius: BorderRadius.circular(6)),
                child: SingleChildScrollView(
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(lines.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3)),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: footer.isEmpty
                      ? const SizedBox.shrink()
                      : Text(
                          footer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: r.queued && !r.fed ? attentionAmber : cs.onSurfaceVariant),
                        ),
                ),
                if (!r.isDone && widget.onStop != null) TextButton(onPressed: widget.onStop, child: const Text('Stop')),
                if (widget.onOpen != null && r.paneId.isNotEmpty) TextButton(onPressed: widget.onOpen, child: const Text('Open window')),
                if (r.isDone && widget.onDismiss != null) TextButton(onPressed: widget.onDismiss, child: const Text('Dismiss')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
