import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'machines.dart';

import '../attention.dart';
import '../config.dart';
import '../foreground.dart';
import '../push.dart';
import '../main.dart';
import '../store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _keepAlive = false;

  @override
  void initState() {
    super.initState();
    BackgroundLink.isRunning().then((v) => mounted ? setState(() => _keepAlive = v) : null);
  }

  @override
  Widget build(BuildContext context) {
    final push = context.watch<PushService>();
    final watcher = context.read<AttentionWatcher>();
    final store = context.watch<AppStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('What the icons mean'),
          subtitle: const Text('Session and machine states, one line each'),
          onTap: () => showLegendSheet(context),
        ),
        const Divider(),
        const _Header('Notifications'),
        SwitchListTile(
          title: const Text('Notify while connected'),
          subtitle: const Text('Live alerts while the app is open or kept alive. Push alerts are set per machine under Machines.'),
          value: watcher.enabled,
          onChanged: (v) async {
            await watcher.setEnabled(v);
            setState(() {});
          },
        ),
        if (BackgroundLink.supported)
          SwitchListTile(
            title: const Text('Stay connected in the background'),
            subtitle: const Text('Android foreground service: keeps the VPN socket open with a persistent notification. No cloud involved.'),
            value: _keepAlive,
            onChanged: (v) async {
              var ok = true;
              if (v) {
                ok = await BackgroundLink.start();
              } else {
                await BackgroundLink.stop();
              }
              setState(() => _keepAlive = v && ok);
            },
          ),
        const Divider(),
        const _Header('Push'),
        if (!push.capable)
          const ListTile(
            title: Text('Background push is not available in this build'),
            subtitle: Text('This build was made without push support. Notifications still work while the app is open, and on Android with the background service above.'),
          )
        else if (!push.hasRelay) ...[
          ListTile(
            title: const Text('Push relay'),
            subtitle: const Text('Notifications when the app is closed need a relay. Paste a relay URL here, or run your own.'),
            trailing: IconButton(
              icon: const Icon(Icons.help_outline),
              tooltip: 'How to run a relay',
              onPressed: () => launchUrl(Uri.parse(BuildConfig.relayDocsUrl), mode: LaunchMode.externalApplication),
            ),
          ),
          const _RelayUrlForm(),
        ] else ...[
          ListTile(
            leading: Icon(
              switch (push.relayState) { RelayState.active => Icons.verified, RelayState.inactive => Icons.pause_circle_outline, _ => Icons.error_outline },
              color: switch (push.relayState) { RelayState.active => const Color(0xFF3DDC84), RelayState.inactive => Theme.of(context).colorScheme.outline, _ => Theme.of(context).colorScheme.error },
            ),
            title: Text(switch (push.relayState) { RelayState.active => 'Relay: connected', RelayState.inactive => 'Relay: not active', _ => 'Relay: could not verify' }),
            subtitle: Text(switch (push.relayState) {
              RelayState.active => 'Push notifications on. Valid until ${push.grantExpires?.toLocal().toString().split(' ').first ?? '…'}, renews automatically.',
              RelayState.inactive => push.lastError ?? 'The relay refused this URL.',
              _ => push.lastError ?? 'Will retry automatically.',
            }),
            trailing: Text(push.relayHost, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
          SwitchListTile(
            title: const Text('Push notifications'),
            subtitle: const Text('Delivered through the relay as an encrypted wake-up; your sessions never leave the VPN.'),
            value: push.enabled,
            onChanged: (v) => push.setEnabled(v),
          ),
          OverflowBar(alignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => push.refreshGrant(force: true), child: const Text('Re-check')),
            TextButton(onPressed: push.clearRelay, child: const Text('Remove relay')),
          ]),
        ],
        const Divider(),
        const _Header('Machines'),
        ListTile(
          leading: const Icon(Icons.devices_other),
          title: Text('${store.daemons.length} paired machine${store.daemons.length == 1 ? '' : 's'}'),
          subtitle: const Text('Rename, mute, auto-connect, forget, pair another'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MachinesScreen())),
        ),
        const Divider(),
        const _Header('About'),
        ListTile(
          leading: ClipOval(child: Image.asset('assets/splash/avatar.gif', width: 44, height: 44, fit: BoxFit.cover)),
          title: const Text('Porthole'),
          subtitle: const Text('Brought to you by Aaron Sullivan (ZerkerEOD)'),
        ),
        ListTile(
          leading: const Icon(Icons.alternate_email),
          title: const Text('@ZerkerEOD on X'),
          subtitle: const Text('x.com/ZerkerEOD'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => launchUrl(Uri.parse('https://x.com/ZerkerEOD'), mode: LaunchMode.externalApplication),
        ),
        ListTile(
          leading: const Icon(Icons.work_outline),
          title: const Text('Aaron Sullivan on LinkedIn'),
          subtitle: const Text('linkedin.com/in/zerkereod'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => launchUrl(Uri.parse('https://www.linkedin.com/in/zerkereod/'), mode: LaunchMode.externalApplication),
        ),
        ListTile(title: const Text('Privacy policy'), trailing: const Icon(Icons.open_in_new), onTap: () => launchUrl(Uri.parse('https://zerkersec.io/privacy'), mode: LaunchMode.externalApplication)),
        ListTile(title: const Text('Terms of service'), trailing: const Icon(Icons.open_in_new), onTap: () => launchUrl(Uri.parse('https://zerkersec.io/terms'), mode: LaunchMode.externalApplication)),
        ListTile(title: const Text('Source code (AGPL-3.0)'), trailing: const Icon(Icons.open_in_new), onTap: () => launchUrl(Uri.parse('https://github.com/ZerkerEOD/porthole'), mode: LaunchMode.externalApplication)),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.t);
  final String t;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text(t, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)));
}


class _RelayUrlForm extends StatefulWidget {
  const _RelayUrlForm();
  @override
  State<_RelayUrlForm> createState() => _RelayUrlFormState();
}

class _RelayUrlFormState extends State<_RelayUrlForm> {
  final _ctl = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final push = context.watch<PushService>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _ctl,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: 'Relay URL',
            hintText: 'https://…@relay.example',
            errorText: push.lastError,
            suffixIcon: IconButton(
              icon: const Icon(Icons.content_paste),
              onPressed: () async {
                final data = await Clipboard.getData('text/plain');
                if (data?.text != null) setState(() => _ctl.text = data!.text!.trim());
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  await push.setRelay(_ctl.text);
                  if (mounted) setState(() => _busy = false);
                },
          child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Connect'),
        ),
      ]),
    );
  }
}
