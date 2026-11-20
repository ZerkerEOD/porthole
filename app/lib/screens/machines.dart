import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../models.dart';
import '../store.dart';
import '../widgets/session_tile.dart';
import 'pairing.dart';
import 'sessions.dart';

/// Manage paired machines: rename, mute, auto-connect, connect now, forget.
class MachinesScreen extends StatelessWidget {
  const MachinesScreen({super.key});

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
          if (info != null && context.mounted) await store.add(info);
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
              trailing: IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(context, store)),
              onTap: client.online ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => SessionsScreen(daemon: d))) : () => store.connectNow(d),
            ),
            if (client.needsRepair)
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(client.lastError ?? '', style: const TextStyle(color: crimsonBright, fontSize: 12))),
            SwitchListTile(dense: true, title: const Text('Auto-connect'), subtitle: const Text('Connect when the app opens'), value: d.autoConnect, onChanged: (v) => store.setAutoConnect(d, v)),
            SwitchListTile(dense: true, title: const Text('Mute notifications'), subtitle: const Text('No attention alerts or push from this machine'), value: d.muted, onChanged: (v) => store.setMuted(d, v)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(client.isDemo ? 'Built-in demo machine · no network' : '${d.hosts.join(', ')} : ${d.port}\n${d.fingerprint}', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontFamily: 'monospace')),
            ),
            OverflowBar(alignment: MainAxisAlignment.end, children: [
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
