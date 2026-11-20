import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../models.dart';
import '../store.dart';
import 'accounts.dart';
import 'new_session.dart';
import 'session.dart';
import 'settings.dart';
import '../widgets/session_tile.dart';

class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, required this.daemon});
  final DaemonInfo daemon;
  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  String _filter = 'all'; // all|claude|codex
  bool _showHistory = true;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final client = store.clientFor(widget.daemon);
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        final all = client.sessions.values.where((s) => _filter == 'all' || s.provider == _filter).toList();
        final running = all.where((s) => s.running).toList()..sort(_byAttentionThenTime);
        final history = all.where((s) => !s.running).toList()..sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
        return Scaffold(
          appBar: AppBar(
            title: Row(children: [
              Icon(Icons.circle, size: 10, color: switch (client.state) { ConnState.connected => Colors.green, ConnState.connecting => Colors.amber, _ => Colors.red }),
              const SizedBox(width: 8),
              Text(widget.daemon.displayName),
            ]),
            actions: [
              IconButton(tooltip: 'Accounts & usage', icon: const Icon(Icons.account_circle_outlined), onPressed: () => showAccountsSheet(context, client)),
              IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()))),
              PopupMenuButton<String>(
                onSelected: (v) => setState(() => _filter = v),
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(value: 'all', checked: _filter == 'all', child: const Text('All')),
                  CheckedPopupMenuItem(value: 'claude', checked: _filter == 'claude', child: const Text('Claude only')),
                  CheckedPopupMenuItem(value: 'codex', checked: _filter == 'codex', child: const Text('Codex only')),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (client.state != ConnState.connected)
                MaterialBanner(
                  leading: const Icon(Icons.vpn_lock),
                  content: Text(client.lastError ?? 'Connecting to ${widget.daemon.displayName}…'),
                  actions: [TextButton(onPressed: () => client.connect(manual: true), child: const Text('Retry'))],
                ),
              for (final p in client.permissions.values) PermissionBanner(client: client, req: p),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async => client.request('session.list').catchError((_) => <String, dynamic>{}),
                  child: ListView(
                    children: [
                      if (running.isEmpty && client.state == ConnState.connected)
                        const Padding(padding: EdgeInsets.all(24), child: Text('No running sessions. Start one below, or run `porthole wrap claude` in a repo.', textAlign: TextAlign.center)),
                      if (running.isNotEmpty) _header(context, 'Running'),
                      for (final s in running) SessionTile(s: s, onTap: () => _open(context, client, s)),
                      if (history.isNotEmpty)
                        ListTile(
                          title: Text('History (${history.length})', style: Theme.of(context).textTheme.labelLarge),
                          trailing: Icon(_showHistory ? Icons.expand_less : Icons.expand_more),
                          onTap: () => setState(() => _showHistory = !_showHistory),
                        ),
                      if (_showHistory) for (final s in history.take(100)) SessionTile(s: s, onTap: () => _open(context, client, s)),
                      const SizedBox(height: 80),
                    ],
                  ),
                ),
              ),
            ],
          ),
          floatingActionButton: client.state == ConnState.connected
              ? FloatingActionButton.extended(
                  onPressed: () async {
                    final s = await Navigator.of(context).push<Session>(MaterialPageRoute(builder: (_) => NewSessionScreen(client: client)));
                    if (s != null && context.mounted) _open(context, client, s);
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('New session'),
                )
              : null,
        );
      },
    );
  }

  int _byAttentionThenTime(Session a, Session b) {
    if (a.needsAttention != b.needsAttention) return a.needsAttention ? -1 : 1;
    return (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0));
  }

  Widget _header(BuildContext context, String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(t, style: Theme.of(context).textTheme.labelLarge));

  void _open(BuildContext context, DaemonClient client, Session s) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SessionScreen(client: client, sessionKey: s.key)));
  }
}

