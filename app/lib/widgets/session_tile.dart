import 'package:flutter/material.dart';

import '../client.dart';
import '../main.dart';
import '../models.dart';

/// One session row, shared by the unified home and the per-machine list.
class SessionTile extends StatelessWidget {
  const SessionTile({super.key, required this.s, required this.onTap, this.machine});
  final Session s;
  final VoidCallback onTap;
  /// Shown as a trailing hint when the list mixes machines.
  final String? machine;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final st = sessionState(context, s);
    final tile = ListTile(
      leading: Padding(padding: const EdgeInsets.only(top: 4), child: StatusGlyph(s, size: 18)),
      title: Text(s.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(children: [
        providerBadge(context, s.provider),
        const SizedBox(width: 6),
        Flexible(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: sessionStateLabel(context, s), style: TextStyle(color: s.stale ? cs.onSurfaceVariant : st.color, fontWeight: st.attention ? FontWeight.w600 : FontWeight.w500)),
              TextSpan(text: ' · ${s.repo}${s.branch.isNotEmpty ? ' · ${s.branch}' : ''}${_modeTag(s)}${machine != null ? ' · $machine' : ''}'),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      ]),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(relTime(s.updatedAt), style: Theme.of(context).textTheme.labelSmall),
        if (s.running && !s.controllable && !s.stale) Tooltip(message: 'Not in tmux: read-only', child: Icon(Icons.visibility_outlined, size: 16, color: cs.outline)),
      ]),
      onTap: onTap,
    );
    // Rows that wait for the person carry an amber edge so they stand out
    // before the label is read.
    final edged = st.attention && !s.stale
        ? DecoratedBox(decoration: const BoxDecoration(border: Border(left: BorderSide(color: attentionAmber, width: 3))), child: tile)
        : tile;
    return s.stale ? Opacity(opacity: 0.55, child: edged) : edged;
  }

  /// " · ⏸ Plan" for a running Claude session whose mode is known.
  static String _modeTag(Session s) {
    if (s.stale || !s.running || s.provider != 'claude') return '';
    final m = PermissionMode.byValue(s.permissionMode);
    return m == null ? '' : ' · ${m.glyph} ${m.short}';
  }
}

/// Banner for a pending Claude permission prompt.
class PermissionBanner extends StatelessWidget {
  const PermissionBanner({super.key, required this.client, required this.req});
  final DaemonClient client;
  final PermissionRequest req;
  @override
  Widget build(BuildContext context) {
    final s = client.sessions[req.sessionKey];
    final input = req.toolInput;
    final detail = input?['command'] ?? input?['file_path'] ?? input?['url'] ?? '';
    return MaterialBanner(
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      leading: Icon(Icons.security, color: Theme.of(context).colorScheme.primary),
      content: Text('${s?.displayTitle ?? req.sessionKey} on ${client.info.displayName} wants to run ${req.toolName}${detail != '' ? ': $detail' : ''}', maxLines: 3, overflow: TextOverflow.ellipsis),
      actions: [
        TextButton(onPressed: () => client.answerPermission(req.id, 'deny'), child: const Text('Deny')),
        FilledButton(onPressed: () => client.answerPermission(req.id, 'allow'), child: const Text('Allow')),
      ],
    );
  }
}

/// Small state chip for a machine. When online, the label also says which
/// address carries the connection if it is not the first one, and which
/// other addresses failed their last check.
class MachineStateChip extends StatelessWidget {
  const MachineStateChip({super.key, required this.client, this.compact = false});
  final DaemonClient client;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Only the state: which address carries it, and which failed, belong to
    // Manage machines.
    final (label, icon, color, spin) = switch (client.state) {
      _ when client.isDemo => ('demo', Icons.science_outlined, cs.outline, false),
      ConnState.connected => ('online', Icons.link, readyGreen, false),
      ConnState.connecting => ('connecting', Icons.sync, attentionAmber, true),
      ConnState.disconnected => ('reconnecting', Icons.sync, attentionAmber, true),
      ConnState.offline when client.needsRepair => ('pair again', Icons.error_outline, crimsonBright, false),
      ConnState.offline when client.allUnreachable => ('unreachable', Icons.link_off, crimsonBright, false),
      ConnState.offline => ('offline${client.lastSeen != null ? ' · seen ${relAgo(client.lastSeen)}' : ''}', Icons.link_off, cs.outline, false),
    };
    final glyph = spin
        ? SizedBox(width: 12, height: 12, child: CircularProgressIndicator(key: const ValueKey('state-ring'), strokeWidth: 1.6, color: color))
        : Icon(icon, size: 14, color: color);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: 14, height: 14, child: Center(child: glyph)),
      if (!compact) ...[const SizedBox(width: 6), Text(label, style: TextStyle(fontSize: 11, color: color == crimsonBright ? crimsonBright : cs.onSurfaceVariant))],
      if (client.info.muted) ...[const SizedBox(width: 6), Icon(Icons.notifications_off_outlined, size: 13, color: cs.outline)],
    ]);
  }
}

/// Sort order for machine groups: needs attention, online, transient, offline, then name.
int machineOrder(DaemonClient a, DaemonClient b) {
  int rank(DaemonClient c) {
    final attention = c.permissions.isNotEmpty || c.sessions.values.any((s) => s.running && !s.stale && s.needsAttention);
    if (attention) return 0;
    return switch (c.state) { ConnState.connected => 1, ConnState.connecting || ConnState.disconnected => 2, ConnState.offline => 3 };
  }
  final r = rank(a).compareTo(rank(b));
  return r != 0 ? r : a.info.displayName.toLowerCase().compareTo(b.info.displayName.toLowerCase());
}
