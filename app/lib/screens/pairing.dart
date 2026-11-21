import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../client.dart';
import '../models.dart';
import '../store.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  bool _busy = false;
  bool _done = false;
  String? _error;
  final _scanCtl = MobileScannerController();
  bool _manual = !(Platform.isAndroid || Platform.isIOS);
  final _host = TextEditingController();
  final _port = TextEditingController(text: '7433');
  final _fp = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController(text: Platform.isIOS ? 'iPhone' : (Platform.isAndroid ? 'Android' : Platform.localHostname));

  @override
  void dispose() {
    _scanCtl.dispose();
    super.dispose();
  }

  Future<void> _finish(PairPayload p) async {
    if (_busy || _done) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final store = context.read<AppStore>();
    // The code is single use: stop decoding so a second frame of the same QR
    // does not hit the daemon after the first attempt.
    if (!_manual) await _scanCtl.stop();
    try {
      final info = await pair(p, _name.text.trim(), store.newLocalId());
      _done = true;
      if (mounted) Navigator.of(context).pop(info);
    } catch (e) {
      setState(() => _error = '$e');
      if (!_manual && mounted) await _scanCtl.start();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  PairPayload? _parseQr(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'porthole' || uri.host != 'pair') return null;
      var d = uri.queryParameters['d']!;
      d = d.padRight(d.length + (4 - d.length % 4) % 4, '=');
      return PairPayload.fromJson(jsonDecode(utf8.decode(base64Url.decode(d))) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair a machine'), actions: [
        if (Platform.isAndroid || Platform.isIOS) TextButton(onPressed: () => setState(() => _manual = !_manual), child: Text(_manual ? 'Scan QR' : 'Enter manually')),
      ]),
      body: Column(
        children: [
          if (_error != null)
            MaterialBanner(content: Text(_error!), backgroundColor: Theme.of(context).colorScheme.errorContainer, actions: [TextButton(onPressed: () => setState(() => _error = null), child: const Text('Dismiss'))]),
          if (_busy) const LinearProgressIndicator(),
          Expanded(child: _manual ? _manualForm() : _scanner()),
        ],
      ),
    );
  }

  Widget _scanner() {
    return Column(
      children: [
        Expanded(
          child: MobileScanner(
            controller: _scanCtl,
            onDetect: (capture) {
              if (_busy || _done) return;
              for (final b in capture.barcodes) {
                final p = b.rawValue == null ? null : _parseQr(b.rawValue!);
                if (p != null) {
                  _finish(p);
                  return;
                }
              }
            },
          ),
        ),
        const Padding(padding: EdgeInsets.all(16), child: Text('On your machine run:  porthole pair', style: TextStyle(fontFamily: 'monospace'))),
      ],
    );
  }

  Widget _manualForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Run `porthole pair` on the machine and copy the values it prints.'),
        const SizedBox(height: 12),
        TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host (VPN address)', hintText: '100.64.0.5')),
        TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
        TextField(controller: _fp, decoration: const InputDecoration(labelText: 'Certificate fingerprint')),
        TextField(controller: _code, decoration: const InputDecoration(labelText: 'Pairing code'), textCapitalization: TextCapitalization.characters),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'This device\'s name')),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _finish(PairPayload(
                    name: _host.text.trim(),
                    hosts: [_host.text.trim()],
                    port: int.tryParse(_port.text.trim()) ?? 7433,
                    fingerprint: _fp.text.trim(),
                    code: _code.text.trim().toUpperCase(),
                  )),
          child: const Text('Pair'),
        ),
      ],
    );
  }
}
