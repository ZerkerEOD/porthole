// Drives the real app against running daemons. Build once with
//   flutter build linux --debug -t integration_test/pair_test.dart \
//     --dart-define=PH_NO_SPLASH=true --dart-define=PH_PAIR_FILE=/path/a.json \
//     --dart-define=PH_PAIR_FILE2=/path/b.json
// then run the bundle; each run reads fresh single-use codes from the files.
// With PH_EXPECT_OFFLINE=<machine name> the test asserts that machine is shown
// offline (quiet, no banner) instead of pairing it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:porthole/main.dart' as app;

const pairFile = String.fromEnvironment('PH_PAIR_FILE');
const pairFile2 = String.fromEnvironment('PH_PAIR_FILE2');
final expectOffline = Platform.environment['PH_EXPECT_OFFLINE'] ?? '';

Future<void> pump(WidgetTester t, int ticks) async {
  for (var i = 0; i < ticks; i++) {
    await t.pump(const Duration(milliseconds: 250));
  }
}

Future<void> pairVia(WidgetTester tester, String file) async {
  final j = jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
  await tester.enterText(find.widgetWithText(TextField, 'Host (VPN address)'), '127.0.0.1');
  await tester.enterText(find.widgetWithText(TextField, 'Port'), '${j['port']}');
  await tester.enterText(find.widgetWithText(TextField, 'Certificate fingerprint'), j['fp'] as String);
  await tester.enterText(find.widgetWithText(TextField, 'Pairing code'), j['code'] as String);
  await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
  await pump(tester, 40);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pair machines, unified home, open a session', (tester) async {
    await app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Start clean: forget machines left in the keystore by earlier runs
    // (their daemon state is gone, so their tokens are dead) unless this run
    // is the offline check, which relies on them.
    if (expectOffline.isEmpty && find.text('Scan pairing code').evaluate().isEmpty) {
      await tester.tap(find.byTooltip('Machines'));
      await tester.pumpAndSettle();
      while (find.text('Forget').evaluate().isNotEmpty) {
        await tester.tap(find.text('Forget').first);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
        await tester.pumpAndSettle();
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    // First machine: either fresh pairing or already in the keystore.
    if (find.text('Scan pairing code').evaluate().isNotEmpty) {
      await tester.tap(find.text('Scan pairing code'));
      await tester.pumpAndSettle();
      await pairVia(tester, pairFile);
    }
    await pump(tester, 12);
    expect(find.text('New session'), findsOneWidget, reason: 'home shows the FAB once a machine is online');

    // Second machine through the Machines page, when a second pair file is given.
    if (pairFile2.isNotEmpty && expectOffline.isEmpty && File(pairFile2).existsSync()) {
      final j2 = jsonDecode(File(pairFile2).readAsStringSync()) as Map<String, dynamic>;
      if (find.text(j2['name'] as String).evaluate().isEmpty) {
        await tester.tap(find.byTooltip('Machines'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pair machine'));
        await tester.pumpAndSettle();
        await pairVia(tester, pairFile2);
        await tester.pageBack();
        await pump(tester, 8);
      }
      expect(find.text(j2['name'] as String), findsWidgets, reason: 'second machine appears on the unified home');
    }

    if (expectOffline.isNotEmpty) {
      await pump(tester, 20);
      expect(find.textContaining('offline'), findsWidgets, reason: 'offline machine shows a quiet chip');
      expect(find.textContaining('Is your VPN connected?'), findsNothing, reason: 'no banner for an offline machine');
      expect(find.text('New session'), findsOneWidget, reason: 'the online machine still works');
    }

    // Open the first running or cached session.
    final tiles = find.byType(ListTile);
    expect(tiles, findsWidgets);
    // Skip the machine header rows: find a tile whose title is not a machine name.
    await tester.tap(find.byType(ListTile).at(1));
    await pump(tester, 40);
    expect(find.byType(TextField), findsWidgets, reason: 'session screen has a composer');
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Accounts sheet from the machine overflow menu.
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    if (find.text('Accounts & usage').evaluate().isNotEmpty) {
      await tester.tap(find.text('Accounts & usage'));
      await pump(tester, 6);
      expect(find.textContaining('Accounts'), findsWidgets);
    }
  });
}
