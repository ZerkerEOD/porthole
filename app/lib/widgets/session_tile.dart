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
    final tile = ListTile(
      leading: Container(width: 10, height: 10, margin: const EdgeInsets.only(top: 6), decoration: BoxDecoration(shape: BoxShape.circle, color: s.stale ? cs.outlineVariant : statusColor(context, s.status))),
      title: Text(s.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(children: [
        providerBadge(context, s.provider),
        const SizedBox(width: 6),
        Flexible(child: Text('${s.repo}${s.branch.isNotEmpty ? ' · ${s.branch}' : ''} · ${s.stale ? 'last seen' : statusLabel(s.status)}${machine != null ? ' · $machine' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant))),
      ]),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(relTime(s.updatedAt), style: Theme.of(context).textTheme.labelSmall),
        if (s.running && !s.controllable && !s.stale) Tooltip(message: 'Not in tmux: read-only', child: Icon(Icons.visibility_outlined, size: 16, color: cs.outline)),
      ]),
      onTap: onTap,
    );
    return s.stale ? Opacity(opacity: 0.55, child: tile) : tile;
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
    final route = client.routeNote;
    final (label, color) = switch (client.state) {
      ConnState.connected => (route.isEmpty ? 'online' : (route.startsWith('via') ? 'online $route' : 'online · $route'), const Color(0xFF3DDC84)),
      ConnState.connecting => ('connecting', const Color(0xFFFFD54F)),
      ConnState.disconnected => ('reconnecting', const Color(0xFFFFD54F)),
      ConnState.offline => client.needsRepair ? ('pair again', crimsonBright) : ('offline${client.lastSeen != null ? ' · seen ${relAgo(client.lastSeen)}' : ''}', cs.outline),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
      if (!compact) ...[const SizedBox(width: 6), Text(label, style: TextStyle(fontSize: 11, color: client.needsRepair ? crimsonBright : cs.onSurfaceVariant))],
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
