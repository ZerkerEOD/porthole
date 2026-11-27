// Store-asset flow: drives the built-in demo and takes the listing
// screenshots. Build and run with
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/demo_flow_test.dart -d <device> \
//     --dart-define=PH_DEMO=true --dart-define=PH_NO_SPLASH=true
// PNGs land in build/screenshots/ (see test_driver/integration_test.dart).
// With --dart-define=PH_DEMO_SLOW=true every step dwells so the same flow
// takes about a minute, for the demo recording (fastlane `assets`).
//
// Screens, in order: 01-home, 02-session-chat (thinking shown),
// 03-terminal-view, 04-permission-card, 05-new-session, 06-machines,
// 07-accounts-usage, 08-settings.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:porthole/demo/demo_client.dart';
import 'package:porthole/demo/fixture.dart' as fx;
import 'package:porthole/main.dart' as app;
import 'package:porthole/notifications.dart';
import 'package:porthole/screens/splash.dart';
import 'package:porthole/store.dart';
import 'package:porthole/widgets/event_tile.dart';
import 'package:provider/provider.dart';

const slow = bool.fromEnvironment('PH_DEMO_SLOW');

/// Real-time wait: [ticks] frames 250 ms apart (timers keep running).
Future<void> pump(WidgetTester t, int ticks) async {
  for (var i = 0; i < ticks; i++) {
    await t.pump(const Duration(milliseconds: 250));
  }
}

/// Pause on a screen: half a second for screenshots, four seconds for the recording.
Future<void> dwell(WidgetTester t) => pump(t, slow ? 16 : 2);

/// Polls until [finder] matches, up to [ticks] × 250 ms.
Future<void> waitFor(WidgetTester t, Finder finder, {int ticks = 60, String? reason}) async {
  for (var i = 0; i < ticks; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await t.pump(const Duration(milliseconds: 250));
  }
  throw TestFailure('timed out waiting for ${reason ?? finder}');
}

/// Polls until [finder] matches nothing, up to [ticks] × 250 ms.
Future<void> waitGone(WidgetTester t, Finder finder, {int ticks = 60, String? reason}) async {
  for (var i = 0; i < ticks; i++) {
    if (finder.evaluate().isEmpty) return;
    await t.pump(const Duration(milliseconds: 250));
  }
  throw TestFailure('timed out waiting for ${reason ?? finder} to go away');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var surfaceConverted = false;

  Future<void> shot(WidgetTester t, String name) async {
    await t.pump(const Duration(milliseconds: 100));
    if (!(Platform.isAndroid || Platform.isIOS)) {
      // Desktop has no capture in integration_test; the flow itself still
      // runs, which is what a Linux dry run checks.
      debugPrint('screenshot $name skipped on ${Platform.operatingSystem}');
      return;
    }
    if (Platform.isAndroid && !surfaceConverted) {
      await binding.convertFlutterSurfaceToImage();
      surfaceConverted = true;
    }
    await binding.takeScreenshot(name);
  }

  testWidgets('demo flow screenshots', (tester) async {
    // The flow decides when the permission prompt appears; no OS dialogs.
    DemoDaemonClient.permissionDelay = const Duration(days: 1);
    Notifier.suppressPrompts = true;

    await app.main();
    await pump(tester, 4);
    // The recording keeps the splash; let it finish rather than tapping through it.
    await waitGone(tester, find.byType(SplashScreen), ticks: 40, reason: 'splash');

    // A previous run leaves the demo machine in the keystore: forget it so
    // the flow starts from the empty home screen every time.
    await waitFor(tester, find.byType(Scaffold), reason: 'home');
    // Let the keystore read finish so an empty home is not mistaken for a populated one.
    // (Busy session rows spin too, so test the store rather than looking for a spinner.)
    final appStore = Provider.of<AppStore>(app.navigatorKey.currentContext!, listen: false);
    for (var i = 0; i < 20 && !appStore.loaded; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pump();
    if (find.text('Try the demo').evaluate().isEmpty) {
      await tester.tap(find.byTooltip('Machines'));
      await pump(tester, 3);
      while (find.text('Forget').evaluate().isNotEmpty) {
        await tester.tap(find.text('Forget').first);
        await pump(tester, 3);
        await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
        await pump(tester, 3);
      }
      await tester.pageBack();
      await pump(tester, 3);
    }
    await waitFor(tester, find.text('Try the demo'), reason: 'empty home');
    if (slow) await pump(tester, 4);

    await tester.tap(find.text('Try the demo'));
    await waitFor(tester, find.text('Add rate limiting to the pairing endpoint'), reason: 'demo sessions');
    await pump(tester, 2);
    await shot(tester, '01-home');
    await dwell(tester);

    // Session transcript with thinking blocks shown.
    await tester.tap(find.text('Add rate limiting to the pairing endpoint'));
    await waitFor(tester, find.byTooltip('Terminal view'), reason: 'session screen');
    await waitFor(tester, find.byType(EventTile), reason: 'transcript');
    await pump(tester, 3); // let the route transition finish
    await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byType(PopupMenuButton<String>)).last);
    await pump(tester, 2);
    // The item's ink well takes the tap even though the label itself is not
    // in the hit path, hence warnIfMissed: false; the block below proves it.
    await tester.tap(find.text('Show thinking'), warnIfMissed: false);
    await pump(tester, 3);
    await waitFor(tester, find.text('Thinking'), reason: 'thinking block shown');
    await shot(tester, '02-session-chat');
    await dwell(tester);

    // Terminal view of the same session.
    await tester.tap(find.byTooltip('Terminal view'));
    await waitFor(tester, find.textContaining('Claude Code'), reason: 'pane snapshot');
    await pump(tester, 2);
    await shot(tester, '03-terminal-view');
    await dwell(tester);
    await tester.tap(find.byTooltip('Chat view'));
    await pump(tester, 2);

    // Permission prompt: raise it now, capture, then allow it.
    final store = Provider.of<AppStore>(app.navigatorKey.currentContext!, listen: false);
    (store.clients[fx.demoDaemonId] as DemoDaemonClient).askPermission();
    await waitFor(tester, find.text('Permission: Bash'), reason: 'permission card');
    await pump(tester, 2);
    await shot(tester, '04-permission-card');
    await dwell(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    await waitGone(tester, find.text('Permission: Bash'), reason: 'permission card');
    // The demo answers with the test run about two seconds later.
    await pump(tester, slow ? 16 : 10);
    await tester.pageBack();
    await pump(tester, 3);

    // New session form.
    await tester.tap(find.text('New session'));
    await waitFor(tester, find.text('Start in tmux'), reason: 'new session screen');
    await waitFor(tester, find.textContaining('porthole/daemon'), reason: 'repositories loaded');
    await pump(tester, 2);
    await shot(tester, '05-new-session');
    await dwell(tester);
    await tester.pageBack();
    await pump(tester, 3);

    // Machines list.
    await tester.tap(find.byTooltip('Machines'));
    await waitFor(tester, find.text('Pair machine'), reason: 'machines screen');
    await pump(tester, 2);
    await shot(tester, '06-machines');
    await dwell(tester);
    await tester.pageBack();
    await pump(tester, 3);

    // Accounts and usage sheet from the machine's overflow menu.
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await pump(tester, 2);
    await tester.tap(find.text('Accounts & usage'));
    await waitFor(tester, find.textContaining('Claude accounts'), reason: 'accounts sheet');
    await pump(tester, 3);
    await shot(tester, '07-accounts-usage');
    await dwell(tester);
    app.navigatorKey.currentState!.pop();
    await pump(tester, 3);

    // Settings.
    await tester.tap(find.byTooltip('Settings'));
    await waitFor(tester, find.text('Notify while connected'), reason: 'settings screen');
    await pump(tester, 2);
    await shot(tester, '08-settings');
    await dwell(tester);
    if (slow) {
      await tester.pageBack();
      await pump(tester, 4);
    }
  });
}
