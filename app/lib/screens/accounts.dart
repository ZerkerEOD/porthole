import 'package:flutter/material.dart';

import '../client.dart';
import '../main.dart';

/// Opens the Accounts & usage page for one machine.
Future<void> showAccountsSheet(BuildContext context, DaemonClient client) {
  return Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountsScreen(client: client)));
}

/// Account usage for one machine: a page with a back button, refreshed by
/// pulling down.
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key, required this.client});
  final DaemonClient client;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Accounts & usage · ${client.info.displayName}')),
      body: RefreshIndicator(
        onRefresh: () => client.refreshAccounts().catchError((_) {}),
        child: ListenableBuilder(listenable: client, builder: (context, _) => _AccountsBody(client: client)),
      ),
    );
  }
}

class _AccountsBody extends StatelessWidget {
  const _AccountsBody({required this.client});
  final DaemonClient client;

  @override
  Widget build(BuildContext context) {
    final a = client.accounts ?? {};
    final claude = a['claude'] as Map<String, dynamic>?;
    final codex = a['codex'] as Map<String, dynamic>?;
    final fetched = DateTime.tryParse(a['fetched_at'] as String? ?? '');
    final rows = <Widget>[];
    if (claude != null) {
      final raw = claude['raw'];
      final fetchedAt = DateTime.tryParse(claude['fetched_at'] as String? ?? '');
      rows.add(ListTile(title: const Text('Claude accounts (via cswap)'), subtitle: Text(fetchedAt != null ? 'usage as of ${relAgo(fetchedAt)}' : '')));
      if (raw is Map<String, dynamic>) {
        for (final acc in (raw['accounts'] as List? ?? [])) {
          final m = acc as Map<String, dynamic>;
          final usage = m['usage'] as Map<String, dynamic>?;
          rows.add(_AccountCard(
            title: m['email'] as String? ?? '?',
            subtitle: [if (m['organizationName'] != null) m['organizationName'] as String, if (m['alias'] != null) '(${m['alias']})'].join(' '),
            active: m['active'] == true,
            status: m['usageStatus'] as String? ?? '',
            windows: [
              if (usage?['fiveHour'] is Map) ('5h', usage!['fiveHour'] as Map<String, dynamic>),
              if (usage?['sevenDay'] is Map) ('7d', usage!['sevenDay'] as Map<String, dynamic>),
              for (final w in (usage?['scoped'] as List? ?? [])) ((w as Map<String, dynamic>)['name'] as String? ?? 'model', w),
            ],
          ));
        }
      }
    } else {
      rows.add(const ListTile(title: Text('Claude accounts'), subtitle: Text('cswap not detected on this machine. Install claude-swap to see account usage here.')));
    }
    if (codex != null) {
      final rl = codex['rate_limits'] as Map<String, dynamic>?;
      rows.add(const Divider());
      rows.add(_AccountCard(
        title: codex['email'] as String? ?? 'Codex',
        subtitle: 'Codex${rl?['plan'] != null ? ' · ${rl!['plan']}' : ''}${codex['seen_at'] != null ? ' · seen in a session ${relAgo(DateTime.tryParse(codex['seen_at'] as String))}' : ''}',
        active: true,
        status: '',
        windows: [
          if (rl?['primary'] is Map) ('${((rl!['primary'] as Map)['window_minutes'] as num? ?? 300) ~/ 60}h', _codexWin(rl['primary'] as Map<String, dynamic>)),
          if (rl?['secondary'] is Map) ('${((rl!['secondary'] as Map)['window_minutes'] as num? ?? 10080) ~/ 1440}d', _codexWin(rl['secondary'] as Map<String, dynamic>)),
        ],
      ));
    }
    return SafeArea(
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ...rows,
          if (fetched != null) Padding(padding: const EdgeInsets.all(16), child: Text('Refreshed ${relAgo(fetched)}. Usage numbers come from each tool\'s own cache; Porthole never calls provider APIs.', style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }

  Map<String, dynamic> _codexWin(Map<String, dynamic> w) => {
        'pct': w['used_percent'],
        'resetsAt': w['resets_at'],
      };
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.title, required this.subtitle, required this.active, required this.status, required this.windows});
  final String title, subtitle, status;
  final bool active;
  final List<(String, Map<String, dynamic>)> windows;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (active) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.check_circle, size: 16, color: Colors.green)),
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
            if (status.isNotEmpty && status != 'ok') Text(status, style: TextStyle(color: cs.error, fontSize: 12)),
          ]),
          if (subtitle.isNotEmpty) Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final (label, w) in windows) _bar(context, label, w),
        ]),
      ),
    );
  }

  Widget _bar(BuildContext context, String label, Map<String, dynamic> w) {
    final theme = Theme.of(context);
    final pct = ((w['pct'] as num?) ?? 0).toDouble().clamp(0, 100);
    final color = pct >= 90 ? crimsonBright : (pct >= 70 ? const Color(0xFFFFB020) : const Color(0xFF3DDC84));
    final reset = resetText(w);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(width: 56, child: Text(label, style: theme.textTheme.labelMedium)),
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: pct / 100, minHeight: 8, color: color))),
          const SizedBox(width: 8),
          SizedBox(width: 40, child: Text('${pct.toStringAsFixed(0)}%', textAlign: TextAlign.right, style: theme.textTheme.labelSmall)),
        ]),
        if (reset.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 56, top: 2),
            child: Text(reset, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
      ]),
    );
  }
}

/// Text under a usage bar describing when the window resets.
///
/// Prefers `resetsAt`, which the app can count down live, over the
/// `countdown` string cswap froze when it wrote its cache. The clock time is
/// appended when the provider gives one so "in 4h 49m" reads as "at 22:10".
String resetText(Map<String, dynamic> w) {
  final at = DateTime.tryParse('${w['resetsAt'] ?? ''}');
  final clock = w['clock'] as String?;
  String when;
  if (at != null) {
    final rel = relIn(at);
    when = rel == 'now' ? 'reset due now' : 'resets $rel';
  } else if (w['countdown'] != null) {
    when = 'resets in ${w['countdown']}';
  } else {
    return '';
  }
  return clock != null && clock.isNotEmpty ? '$when · $clock' : when;
}
