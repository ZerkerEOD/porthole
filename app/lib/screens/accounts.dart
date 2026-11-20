import 'package:flutter/material.dart';

import '../client.dart';
import '../main.dart';

Future<void> showAccountsSheet(BuildContext context, DaemonClient client) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => ListenableBuilder(listenable: client, builder: (context, _) => _AccountsBody(client: client)),
  );
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
        shrinkWrap: true,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Accounts & usage', style: Theme.of(context).textTheme.titleLarge)),
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
    final pct = ((w['pct'] as num?) ?? 0).toDouble().clamp(0, 100);
    final reset = w['countdown'] != null ? 'resets in ${w['countdown']}' : (w['resetsAt'] != null ? 'resets ${relIn(DateTime.tryParse('${w['resetsAt']}'))}' : '');
    final color = pct >= 90 ? crimsonBright : (pct >= 70 ? const Color(0xFFFFB020) : const Color(0xFF3DDC84));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        SizedBox(width: 56, child: Text(label, style: Theme.of(context).textTheme.labelMedium)),
        Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: pct / 100, minHeight: 8, color: color))),
        const SizedBox(width: 8),
        SizedBox(width: 92, child: Text('${pct.toStringAsFixed(0)}% · $reset', style: Theme.of(context).textTheme.labelSmall, overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}
