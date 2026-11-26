import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../main.dart';
import '../models.dart';
import '../store.dart';
import '../widgets/session_tile.dart';
import 'pairing.dart';
import 'sessions.dart';

/// Manage paired machines: rename, mute, auto-connect, connect now, forget.
/// Opening it checks every address of every machine, and again every 30 s
/// while it stays open.
class MachinesScreen extends StatefulWidget {
  const MachinesScreen({super.key});

  @override
  State<MachinesScreen> createState() => _MachinesScreenState();
}

class _MachinesScreenState extends State<MachinesScreen> {
  Timer? _ticker;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    context.read<AppStore>().probeAll();
    // Every 10 s the "checked … ago" ages refresh; every third tick probes.
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      _ticks++;
      if (_ticks % 3 == 0) context.read<AppStore>().probeAll();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Machines')),
      body: ListView(children: [
        for (final d in store.daemons) _MachineCard(d: d),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('Each machine runs its own porthole daemon with its own pairing. Laptop, workstation, a box in the rack: pair them all and they share one session list.', style: TextStyle(fontSize: 12)),
        ),
        const SizedBox(height: 80),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final info = await Navigator.of(context).push<DaemonInfo>(MaterialPageRoute(builder: (_) => const PairingScreen()));
          if (info != null && context.mounted) {
      await store.add(info);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Paired with ${info.name}')));
    }
        },
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Pair machine'),
      ),
    );
  }
}

class _MachineCard extends StatelessWidget {
  const _MachineCard({required this.d});
  final DaemonInfo d;

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppStore>();
    final client = store.clientFor(d);
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        final running = client.sessions.values.where((s) => s.running && !s.stale).length;
        return Card(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ListTile(
              leading: Icon(Icons.computer, color: client.online ? cs.onSurface : cs.outline),
              title: Text(d.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                MachineStateChip(client: client),
                const SizedBox(height: 2),
                Text('${d.alias != null ? 'reported as ${d.name} · ' : ''}${client.daemonVersion.isNotEmpty ? 'v${client.daemonVersion} · ' : ''}$running running', style: Theme.of(context).textTheme.bodySmall),
              ]),
              onTap: client.online ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SessionsScreen(daemon: d))) : () => store.connectNow(d),
            ),
            if (!client.online && client.lastError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(client.lastError!, style: TextStyle(color: client.needsRepair ? crimsonBright : cs.onSurfaceVariant, fontSize: 12)),
              ),
            SwitchListTile(dense: true, title: const Text('Auto-connect'), subtitle: const Text('Connect when the app opens'), value: d.autoConnect, onChanged: (v) => store.setAutoConnect(d, v)),
            SwitchListTile(dense: true, title: const Text('Mute notifications'), subtitle: const Text('No attention alerts or push from this machine'), value: d.muted, onChanged: (v) => store.setMuted(d, v)),
            if (client.isDemo)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Built-in demo machine · no network', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontFamily: 'monospace')),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                child: Text('Addresses · tap to prefer, hold for more', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
              ),
              for (final h in d.hosts)
                _HostRow(
                  host: h,
                  status: client.hostStatus[h],
                  checking: client.probingHosts.contains(h),
                  via: client.online && d.lastHost == h,
                  ignored: d.ignoredHosts.contains(h),
                  onTap: () => store.preferHost(d, h),
                  onLongPress: () => _hostMenu(context, store, h),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text('port ${d.port} · ${d.fingerprint}', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontFamily: 'monospace')),
              ),
            ],
            OverflowBar(alignment: MainAxisAlignment.end, children: [
              TextButton.icon(onPressed: () => _rename(context, store), icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Rename')),
              if (!client.online) TextButton.icon(onPressed: () => store.connectNow(d), icon: const Icon(Icons.refresh, size: 18), label: const Text('Connect now')),
              TextButton.icon(
                onPressed: () => _forget(context, store),
                icon: Icon(Icons.delete_outline, size: 18, color: cs.error),
                label: Text('Forget', style: TextStyle(color: cs.error)),
              ),
            ]),
          ]),
        );
      },
    );
  }

  Future<void> _hostMenu(BuildContext context, AppStore store, String host) async {
    final ignored = d.ignoredHosts.contains(host);
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(host, style: const TextStyle(fontFamily: 'monospace')), subtitle: Text(ignored ? 'Ignored: never dialled or checked' : 'One of ${d.displayName}\'s addresses')),
          if (!ignored) ListTile(leading: const Icon(Icons.star_outline), title: const Text('Prefer this address'), subtitle: const Text('Try it first when connecting'), onTap: () => Navigator.pop(context, 'prefer')),
          ListTile(
            leading: Icon(ignored ? Icons.visibility_outlined : Icons.visibility_off_outlined),
            title: Text(ignored ? 'Stop ignoring' : 'Ignore this address'),
            subtitle: Text(ignored ? 'Dial and check it again' : 'Never dial or check it; it stays listed here'),
            onTap: () => Navigator.pop(context, ignored ? 'unignore' : 'ignore'),
          ),
        ]),
      ),
    );
    switch (choice) {
      case 'prefer':
        await store.preferHost(d, host);
      case 'ignore':
        await store.ignoreHost(d, host, true);
      case 'unignore':
        await store.ignoreHost(d, host, false);
    }
  }

  Future<void> _rename(BuildContext context, AppStore store) async {
    final ctl = TextEditingController(text: d.alias ?? '');
    final v = await showDialog<String?>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Rename machine'),
        content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(labelText: 'Name', hintText: d.name, helperText: 'Leave empty to use the name the daemon reports')),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Save'))],
      ),
    );
    if (v != null) await store.setAlias(d, v);
  }

  Future<void> _forget(BuildContext context, AppStore store) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Forget ${d.displayName}?'),
        content: Text(store.clientFor(d).isDemo ? 'Removes the demo machine and its sample sessions.' : 'The device token is deleted from this phone. Revoke it on the machine with `porthole devices revoke`.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Forget'))],
      ),
    );
    if (ok == true) await store.remove(d);
  }
}

/// "12 s ago", "3 min ago", "2 h ago".
String checkedAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return '${d.inSeconds} s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  return '${d.inHours} h ago';
}

/// One address of a machine: status dot, the address, a "via" chip while it
/// carries the connection, and the latency or the short error with how long
/// ago it was checked. Tapping it makes it the preferred address.
class _HostRow extends StatelessWidget {
  const _HostRow({required this.host, required this.status, required this.via, required this.onTap, required this.onLongPress, this.checking = false, this.ignored = false});
  final String host;
  final HostStatus? status;
  final bool via;
  final bool checking;
  final bool ignored;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = status;
    final failed = s?.reachable == false;
    final color = s == null || s.reachable == null ? cs.outline : (s.reachable == true ? const Color(0xFF3DDC84) : crimsonBright);
    final label = ignored
        ? 'ignored'
        : checking
            ? 'checking…'
            : s == null
                ? 'untested'
                : '${s.label} · checked ${checkedAgo(s.checkedAt)}';
    return Tooltip(
      message: ignored ? 'Ignored · hold for options' : 'Tap to connect through this address · hold for options',
      child: InkWell(
        onTap: ignored ? onLongPress : onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: ignored ? cs.outlineVariant : color)),
            const SizedBox(width: 8),
            Expanded(child: Text(host, style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: ignored ? cs.outline : cs.onSurface, decoration: ignored ? TextDecoration.lineThrough : null))),
            if (via)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(8)),
                child: Text('via', style: TextStyle(fontSize: 10, color: cs.onPrimaryContainer)),
              ),
            Text(label, style: TextStyle(fontSize: 11, color: failed && !checking && !ignored ? crimsonBright : cs.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}
