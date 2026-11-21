import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../client.dart';
import '../main.dart';
import '../models.dart';
import '../store.dart';
import '../widgets/session_tile.dart';
import 'accounts.dart';
import 'machines.dart';
import 'new_session.dart';
import 'pairing.dart';
import 'session.dart';
import 'sessions.dart';
import 'settings.dart';

/// Unified home: every machine's sessions in one list, grouped by machine.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _filter = 'all'; // all | claude | codex | machine:<id>
  final Set<String> _historyOpen = {};

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final f = p.getString('home.filter');
      if (f != null && mounted) setState(() => _filter = f);
    });
  }

  void _setFilter(String f) {
    setState(() => _filter = f);
    SharedPreferences.getInstance().then((p) => p.setString('home.filter', f));
  }

  Future<void> _pair(BuildContext context) async {
    final store = context.read<AppStore>();
    final info = await Navigator.of(context).push<DaemonInfo>(MaterialPageRoute(builder: (_) => const PairingScreen()));
    if (info != null && context.mounted) {
      await store.add(info);
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Paired with ${info.name}')));
    }
  }

  void _open(DaemonClient client, Session s) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SessionScreen(client: client, sessionKey: s.key)));
  }

  Future<void> _newSession(AppStore store) async {
    final online = store.daemons.where((d) => store.clients[d.id]?.online == true).toList();
    final d = online.length == 1 ? online.first : store.defaultDaemon;
    if (d == null) return;
    final client = store.clientFor(d);
    final s = await Navigator.of(context).push<Session>(MaterialPageRoute(builder: (_) => NewSessionScreen(client: client, allowMachinePick: store.daemons.length > 1)));
    if (s != null && mounted) {
      // The spawn may have happened on another machine chosen in the picker.
      final target = store.clients.values.firstWhere((c) => c.sessions.containsKey(s.key), orElse: () => client);
      _open(target, s);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (!store.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final clients = store.daemons.map(store.clientFor).toList()..sort(machineOrder);
    final visible = clients.where((c) => !_filter.startsWith('machine:') || _filter == 'machine:${c.info.id}').toList();
    final prov = _filter == 'claude' || _filter == 'codex' ? _filter : null;
    final attention = store.attentionCount;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Porthole'),
        actions: [
          IconButton(tooltip: 'Machines', icon: Badge(isLabelVisible: store.daemons.length > 1, label: Text('${store.daemons.length}'), child: const Icon(Icons.devices_other)), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MachinesScreen()))),
          IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()))),
        ],
      ),
      body: store.daemons.isEmpty
          ? _Empty(onPair: () => _pair(context), onDemo: () => store.addDemo())
          : Column(children: [
              _chipBar(clients),
              for (final c in visible)
                for (final p in c.permissions.values) PermissionBanner(client: c, req: p),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    for (final c in visible) {
                      if (c.online) {
                        await c.request('session.list').catchError((_) => <String, dynamic>{});
                      } else {
                        store.connectNow(c.info);
                      }
                    }
                  },
                  child: ListView(
                    children: [
                      for (final c in visible) ..._machineGroup(c, prov, store),
                      if (attention == 0 && visible.every((c) => c.sessions.values.where((s) => s.running).isEmpty))
                        const Padding(padding: EdgeInsets.all(24), child: Text('No running sessions. Start one below, or run `porthole wrap claude` in a repo.', textAlign: TextAlign.center)),
                      const SizedBox(height: 88),
                    ],
                  ),
                ),
              ),
            ]),
      floatingActionButton: store.onlineCount > 0 ? FloatingActionButton.extended(onPressed: () => _newSession(store), icon: const Icon(Icons.add), label: const Text('New session')) : null,
    );
  }

  Widget _chipBar(List<DaemonClient> clients) {
    Widget chip(String value, Widget label) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(label: label, selected: _filter == value, onSelected: (_) => _setFilter(value), showCheckmark: false, visualDensity: VisualDensity.compact),
        );
    return SizedBox(
      height: 46,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 6, 12, 4), children: [
        chip('all', const Text('All')),
        for (final c in clients)
          chip('machine:${c.info.id}', Row(mainAxisSize: MainAxisSize.min, children: [
            MachineStateChip(client: c, compact: true),
            const SizedBox(width: 6),
            Text(c.info.displayName),
            if (c.permissions.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 6), child: Badge(label: Text('${c.permissions.length}'))),
          ])),
        chip('claude', const Text('Claude')),
        chip('codex', const Text('Codex')),
      ]),
    );
  }

  List<Widget> _machineGroup(DaemonClient c, String? prov, AppStore store) {
    final all = c.sessions.values.where((s) => prov == null || s.provider == prov).toList();
    final running = all.where((s) => s.running).toList()
      ..sort((a, b) {
        if (a.needsAttention != b.needsAttention) return a.needsAttention ? -1 : 1;
        return (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0));
      });
    final history = all.where((s) => !s.running).toList()..sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
    final open = _historyOpen.contains(c.info.id);
    final cs = Theme.of(context).colorScheme;
    return [
      ListTile(
        dense: true,
        leading: Icon(Icons.computer, color: c.online ? cs.onSurface : cs.outline),
        title: Text(c.info.displayName, style: TextStyle(fontWeight: FontWeight.w600, color: c.online ? cs.onSurface : cs.onSurfaceVariant)),
        subtitle: MachineStateChip(client: c),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (c.info.muted) Icon(Icons.notifications_off_outlined, size: 16, color: cs.outline),
          Text(running.isNotEmpty && running.every((s) => s.stale) ? '${running.length} last seen' : '${running.length} running', style: Theme.of(context).textTheme.labelSmall),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'connect':
                  store.connectNow(c.info);
                case 'accounts':
                  showAccountsSheet(context, c);
                case 'mute':
                  store.setMuted(c.info, !c.info.muted);
                case 'open':
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => SessionsScreen(daemon: c.info)));
                case 'manage':
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MachinesScreen()));
              }
            },
            itemBuilder: (_) => [
              if (!c.online) const PopupMenuItem(value: 'connect', child: Text('Connect now')),
              if (c.online) const PopupMenuItem(value: 'accounts', child: Text('Accounts & usage')),
              PopupMenuItem(value: 'mute', child: Text(c.info.muted ? 'Unmute notifications' : 'Mute notifications')),
              const PopupMenuItem(value: 'open', child: Text('Open machine view')),
              const PopupMenuItem(value: 'manage', child: Text('Manage machines')),
            ],
          ),
        ]),
        onTap: c.online ? null : () => store.connectNow(c.info),
      ),
      if (c.state == ConnState.offline && c.needsRepair)
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(c.lastError ?? 'Pair again', style: const TextStyle(color: crimsonBright, fontSize: 12))),
      for (final s in running) SessionTile(s: s, onTap: () => _open(c, s)),
      if (history.isNotEmpty)
        ListTile(
          dense: true,
          title: Text('History (${history.length})', style: Theme.of(context).textTheme.labelMedium),
          trailing: Icon(open ? Icons.expand_less : Icons.expand_more, size: 18),
          onTap: () => setState(() => open ? _historyOpen.remove(c.info.id) : _historyOpen.add(c.info.id)),
        ),
      if (open) for (final s in history.take(60)) SessionTile(s: s, onTap: () => _open(c, s)),
      const Divider(height: 8),
    ];
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onPair, required this.onDemo});
  final VoidCallback onPair;
  final VoidCallback onDemo;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.terminal, size: 64),
          const SizedBox(height: 16),
          Text('No machines paired', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('Run `porthole pair` on your machine and scan the code. Make sure your VPN is connected.', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: onPair, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan pairing code')),
          const SizedBox(height: 8),
          TextButton(onPressed: onDemo, child: const Text('Try the demo')),
        ]),
      ),
    );
  }
}
