import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../main.dart';
import '../models.dart';
import '../store.dart';

class NewSessionScreen extends StatefulWidget {
  const NewSessionScreen({super.key, required this.client, this.resume, this.allowMachinePick = false});
  final DaemonClient client;
  final Session? resume;
  /// Show a machine selector (unified home with several machines).
  final bool allowMachinePick;
  @override
  State<NewSessionScreen> createState() => _NewSessionScreenState();
}

class _NewSessionScreenState extends State<NewSessionScreen> {
  Widget _machinePicker(BuildContext context) {
    final store = context.watch<AppStore>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DropdownButtonFormField<String>(
        initialValue: _client.info.id,
        decoration: const InputDecoration(labelText: 'Machine'),
        items: [
          for (final d in store.daemons)
            DropdownMenuItem(
              value: d.id,
              enabled: store.clients[d.id]?.online == true,
              child: Text('${d.displayName}${store.clients[d.id]?.online == true ? '' : '  (offline)'}', style: TextStyle(color: store.clients[d.id]?.online == true ? null : Theme.of(context).colorScheme.outline)),
            ),
        ],
        onChanged: (id) {
          final d = store.daemons.where((x) => x.id == id).firstOrNull;
          if (d == null) return;
          setState(() => _client = store.clientFor(d));
          _load();
        },
      ),
    );
  }

  late DaemonClient _client = widget.client;
  List<Repo>? _repos;
  Repo? _repo;
  String _provider = 'claude';
  String _mode = 'default';
  final _prompt = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _repos = null;
      _repo = null;
      _error = null;
    });
    try {
      final r = await _client.repos();
      if (!mounted) return;
      setState(() {
        _repos = r;
        if (widget.resume != null) {
          _provider = widget.resume!.provider;
          _repo = r.where((x) => x.path == widget.resume!.cwd).firstOrNull;
        } else if (r.isNotEmpty) {
          _repo = r.first;
          if (r.first.lastProvider.isNotEmpty) _provider = r.first.lastProvider;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _start() async {
    if (_repo == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await _client.spawn(
        provider: _provider,
        dir: _repo!.path,
        resume: widget.resume?.id,
        prompt: _prompt.text.trim(),
        permissionMode: _provider == 'claude' && _mode != 'default' ? _mode : null,
      );
      if (mounted) {
        context.read<AppStore>().markUsed(_client.info);
        Navigator.of(context).pop(s);
      }
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _client.features;
    return Scaffold(
      appBar: AppBar(title: Text(widget.resume != null ? 'Resume session' : 'New session')),
      body: _repos == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (widget.allowMachinePick && widget.resume == null) _machinePicker(context),
                if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                if (widget.resume == null)
                  SegmentedButton<String>(
                    segments: [
                      if (f['claude'] != false) const ButtonSegment(value: 'claude', label: Text('Claude Code')),
                      if (f['codex'] != false) const ButtonSegment(value: 'codex', label: Text('Codex')),
                    ],
                    selected: {_provider},
                    onSelectionChanged: (s) => setState(() => _provider = s.first),
                  ),
                const SizedBox(height: 16),
                if (_repos != null && _repos!.isEmpty) const Text('No repositories found. Set `workspaces` in the daemon config.'),
                DropdownButtonFormField<Repo>(
                  key: ValueKey('repo-${_client.info.id}'),
                  initialValue: _repo,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Repository'),
                  items: [for (final r in _repos ?? const <Repo>[]) DropdownMenuItem(value: r, child: Text('${r.name}${r.branch.isNotEmpty ? '  ·  ${r.branch}' : ''}', overflow: TextOverflow.ellipsis))],
                  onChanged: widget.resume != null ? null : (r) => setState(() => _repo = r),
                ),
                if (_repo != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_repo!.path, style: Theme.of(context).textTheme.bodySmall)),
                const SizedBox(height: 16),
                if (_provider == 'claude' && widget.resume == null)
                  DropdownButtonFormField<String>(
                    initialValue: _mode,
                    decoration: const InputDecoration(labelText: 'Permission mode'),
                    items: const [
                      DropdownMenuItem(value: 'default', child: Text('Default (ask)')),
                      DropdownMenuItem(value: 'plan', child: Text('Plan mode')),
                      DropdownMenuItem(value: 'acceptEdits', child: Text('Accept edits')),
                    ],
                    onChanged: (v) => setState(() => _mode = v ?? 'default'),
                  ),
                const SizedBox(height: 16),
                TextField(controller: _prompt, minLines: 2, maxLines: 6, decoration: const InputDecoration(labelText: 'First prompt (optional)', border: OutlineInputBorder())),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy || _repo == null ? null : _start,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(widget.resume != null ? 'Resume in tmux' : 'Start in tmux'),
                ),
                const SizedBox(height: 8),
                Text('Runs on ${_client.info.displayName} inside a tmux session you can also attach to from a terminal.', style: Theme.of(context).textTheme.bodySmall),
                if (widget.resume != null) Padding(padding: const EdgeInsets.only(top: 8), child: Row(children: [providerBadge(context, widget.resume!.provider), const SizedBox(width: 8), Expanded(child: Text(widget.resume!.displayTitle, overflow: TextOverflow.ellipsis))])),
              ],
            ),
    );
  }
}
