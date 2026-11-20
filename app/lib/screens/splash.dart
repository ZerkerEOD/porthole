import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';

/// Short branded splash: the animated avatar on true black with a crimson
/// glow, shown once per launch. Tap anywhere to skip.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.next});
  final Widget next;

  static const skip = bool.fromEnvironment('PH_NO_SPLASH');

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..forward();
  Timer? _timer;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 3000), _go);
  }

  void _go() {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      pageBuilder: (_, a, _) => FadeTransition(opacity: a, child: widget.next),
      transitionDuration: const Duration(milliseconds: 450),
    ));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: ink,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _go,
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 3),
              Container(
                width: 190,
                height: 190,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: crimson.withValues(alpha: 0.55), blurRadius: 48, spreadRadius: 4),
                    BoxShadow(color: crimsonBright.withValues(alpha: 0.25), blurRadius: 110, spreadRadius: 20),
                  ],
                  border: Border.all(color: crimsonDeep, width: 2),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset('assets/splash/avatar.gif', fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium),
              ),
              const SizedBox(height: 36),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOut,
                builder: (_, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, (1 - v) * 10), child: child)),
                child: Column(children: [
                  Text('Welcome to', style: text.titleMedium?.copyWith(color: chalkDim, letterSpacing: 3, fontWeight: FontWeight.w400)),
                  const SizedBox(height: 4),
                  Text('PORTHOLE', style: text.displaySmall?.copyWith(color: chalk, fontWeight: FontWeight.w800, letterSpacing: 6)),
                  const SizedBox(height: 18),
                  Container(width: 56, height: 2, decoration: BoxDecoration(color: crimsonBright, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 18),
                  Text('Brought to you by', style: text.bodySmall?.copyWith(color: chalkDim, letterSpacing: 1.5)),
                  const SizedBox(height: 4),
                  Text('Aaron Sullivan', style: text.titleMedium?.copyWith(color: chalk, fontWeight: FontWeight.w600)),
                  Text('ZerkerEOD', style: text.bodyMedium?.copyWith(color: crimsonBright, fontFamily: 'monospace', letterSpacing: 2)),
                ]),
              ),
              const Spacer(flex: 4),
              Padding(
                padding: const EdgeInsets.fromLTRB(48, 0, 48, 28),
                child: Column(children: [
                  AnimatedBuilder(
                    animation: _ctl,
                    builder: (_, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(value: _ctl.value, minHeight: 2, color: crimson, backgroundColor: ink3),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('tap to continue', style: text.labelSmall?.copyWith(color: const Color(0xFF555555), letterSpacing: 1)),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
