import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'attention.dart';
import 'foreground.dart';
import 'notifications.dart';
import 'push.dart';
import 'screens/home.dart';
import 'screens/session.dart';
import 'screens/splash.dart';
import 'store.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore();
  final push = PushService(store);
  final watcher = AttentionWatcher(store);
  store.onMuteChanged = push.onMuteChanged;
  await Notifier.instance.init();
  await BackgroundLink.init();
  store.load();
  push.init();
  watcher.start();
  Notifier.instance.onTap = (key) => openSession(store, key);
  final launch = Notifier.instance.launchPayload;
  if (launch != null && launch.isNotEmpty) _openWhenReady(store, launch);
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: store),
      ChangeNotifierProvider.value(value: push),
      Provider.value(value: watcher),
    ],
    child: const PortholeApp(),
  ));
}

/// Opens the session a notification points at, on whichever machine has it.
void openSession(AppStore store, String key) {
  final c = store.clients.values.where((c) => c.sessions.containsKey(key)).firstOrNull;
  final nav = navigatorKey.currentState;
  if (nav == null || c == null) return;
  nav.popUntil((r) => r.isFirst);
  nav.push(MaterialPageRoute(builder: (_) => SessionScreen(client: c, sessionKey: key)));
}

/// Cold start from a notification tap: wait until the machine has said hello
/// and the splash is gone, then open the session. Gives up after 20 s.
void _openWhenReady(AppStore store, String key) {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  final splash = SplashScreen.skip ? Duration.zero : const Duration(milliseconds: 3600);
  late void Function() listener;
  listener = () {
    if (DateTime.now().isAfter(deadline)) {
      store.removeListener(listener);
      return;
    }
    if (!store.clients.values.any((c) => c.sessions.containsKey(key))) return;
    store.removeListener(listener);
    Future.delayed(splash, () => openSession(store, key));
  };
  store.addListener(listener);
}

class PortholeApp extends StatelessWidget {
  const PortholeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Porthole',
      debugShowCheckedModeBanner: false,
      theme: lightTheme(),
      darkTheme: oledTheme(),
      themeMode: ThemeMode.dark,
      home: SplashScreen.skip ? const HomeScreen() : const SplashScreen(next: HomeScreen()),
    );
  }
}

/// Brand: deep red on true black. Pure #000000 surfaces so OLED pixels are
/// off; a short grey ramp for elevation; crimson for anything interactive.
const crimson = Color(0xFFB3001B);
const crimsonBright = Color(0xFFE5243B);
const crimsonDeep = Color(0xFF7A0012);
const ink = Color(0xFF000000);
const ink1 = Color(0xFF0A0A0A);
const ink2 = Color(0xFF111111);
const ink3 = Color(0xFF181818);
const ink4 = Color(0xFF222222);
const chalk = Color(0xFFEDEDED);
const chalkDim = Color(0xFFA3A3A3);

ThemeData oledTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: crimsonBright,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFF3A0009),
    onPrimaryContainer: Color(0xFFFFD9DC),
    secondary: chalkDim,
    onSecondary: ink,
    secondaryContainer: ink3,
    onSecondaryContainer: chalk,
    tertiary: Color(0xFFFF8A80),
    onTertiary: ink,
    tertiaryContainer: Color(0xFF4A1010),
    onTertiaryContainer: Color(0xFFFFDAD6),
    error: Color(0xFFFF6B6B),
    onError: ink,
    errorContainer: Color(0xFF5A0A0A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: ink,
    onSurface: chalk,
    surfaceDim: ink,
    surfaceBright: ink4,
    surfaceContainerLowest: ink,
    surfaceContainerLow: ink1,
    surfaceContainer: ink2,
    surfaceContainerHigh: ink3,
    surfaceContainerHighest: ink4,
    onSurfaceVariant: chalkDim,
    outline: Color(0xFF4A4A4A),
    outlineVariant: Color(0xFF2A2A2A),
    shadow: ink,
    scrim: ink,
    inverseSurface: chalk,
    onInverseSurface: ink,
    inversePrimary: crimsonDeep,
    surfaceTint: Colors.transparent,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: ink,
    canvasColor: ink,
    appBarTheme: const AppBarTheme(backgroundColor: ink, foregroundColor: chalk, elevation: 0, scrolledUnderElevation: 0, surfaceTintColor: Colors.transparent),
    cardTheme: const CardThemeData(color: ink2, surfaceTintColor: Colors.transparent, elevation: 0),
    dividerTheme: const DividerThemeData(color: ink3, thickness: 1),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: ink1, surfaceTintColor: Colors.transparent),
    dialogTheme: const DialogThemeData(backgroundColor: ink2, surfaceTintColor: Colors.transparent),
    popupMenuTheme: const PopupMenuThemeData(color: ink2, surfaceTintColor: Colors.transparent),
    bannerTheme: const MaterialBannerThemeData(backgroundColor: ink2, surfaceTintColor: Colors.transparent),
    snackBarTheme: const SnackBarThemeData(backgroundColor: ink3, contentTextStyle: TextStyle(color: chalk)),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: crimson, foregroundColor: Colors.white),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(backgroundColor: crimson, foregroundColor: Colors.white)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(foregroundColor: chalk, side: const BorderSide(color: ink4))),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : chalkDim),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? crimson : ink4),
    ),
    inputDecorationTheme: const InputDecorationTheme(fillColor: ink2, filled: true),
    listTileTheme: const ListTileThemeData(iconColor: chalkDim),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: crimsonBright, linearTrackColor: ink3),
    badgeTheme: const BadgeThemeData(backgroundColor: crimsonBright, textColor: Colors.white),
  );
}

ThemeData lightTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: crimson, brightness: Brightness.light).copyWith(primary: crimson, surfaceTint: Colors.transparent);
  return ThemeData(colorScheme: scheme, useMaterial3: true, filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(backgroundColor: crimson, foregroundColor: Colors.white)));
}

/// Sentence-form relative time: "just now", "3m ago", "2h ago", "5d ago".
String relAgo(DateTime? t) {
  if (t == null) return 'unknown';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return 'on ${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

/// Future-facing: "in 2h 10m", "in 3d", or "now" when already past.
String relIn(DateTime? t) {
  if (t == null) return '';
  final d = t.difference(DateTime.now());
  if (d.isNegative || d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return 'in ${d.inMinutes}m';
  if (d.inHours < 24) return 'in ${d.inHours}h ${d.inMinutes % 60}m';
  return 'in ${d.inDays}d ${d.inHours % 24}h';
}

/// Compact relative time for list trailers: "now", "3m", "2h", "5d", or a date.
String relTime(DateTime? t) {
  if (t == null) return '';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

Color statusColor(BuildContext context, String status) {
  final cs = Theme.of(context).colorScheme;
  switch (status) {
    case 'busy':
      return crimsonBright;
    case 'idle':
      return const Color(0xFF3DDC84);
    case 'waiting_permission':
      return const Color(0xFFFFB020);
    case 'waiting_input':
      return const Color(0xFFFFD54F);
    case 'exited':
      return cs.outline;
    default:
      return cs.outlineVariant;
  }
}

String statusLabel(String status) {
  switch (status) {
    case 'busy':
      return 'working';
    case 'idle':
      return 'idle';
    case 'waiting_permission':
      return 'needs approval';
    case 'waiting_input':
      return 'needs input';
    case 'exited':
      return 'ended';
    default:
      return status;
  }
}

Widget providerBadge(BuildContext context, String provider) {
  final isClaude = provider == 'claude';
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: isClaude ? const Color(0xFFD97757).withValues(alpha: 0.18) : const Color(0xFF10A37F).withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(isClaude ? 'Claude' : 'Codex', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: isClaude ? const Color(0xFFD97757) : const Color(0xFF10A37F))),
  );
}
