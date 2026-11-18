import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Plays the daily launch decoration over an already-mounted destination.
class DailyLaunchAnimation extends StatefulWidget {
  final Widget child;
  final bool force;
  final String? lastPlayedDate;
  final Future<void> Function(String) savePlayedDate;
  const DailyLaunchAnimation({
    super.key,
    required this.child,
    required this.lastPlayedDate,
    required this.savePlayedDate,
    this.force = false,
  });
  @override
  State<DailyLaunchAnimation> createState() => _DailyLaunchAnimationState();
}

class _DailyLaunchAnimationState extends State<DailyLaunchAnimation>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  late bool _visible;
  late final String _today;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final now = DateTime.now();
    _today = '${now.year}-${now.month}-${now.day}';
    _visible = widget.force || widget.lastPlayedDate != _today;
    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 2700),
          animationBehavior: AnimationBehavior.preserve,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _dismiss();
        });
    if (_visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_visible) return;
        if (MediaQuery.disableAnimationsOf(context)) {
          _controller.duration = const Duration(milliseconds: 240);
        }
        _controller.forward();
      });
    }
  }

  void _dismiss() {
    if (!mounted || !_visible) return;
    _controller.stop();
    setState(() => _visible = false);
    unawaited(_saveDate());
  }

  Future<void> _saveDate() async {
    try {
      await widget.savePlayedDate(_today);
    } catch (_) {
      // A failed date write should only cause the animation to play again.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _dismiss();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = TideTheme.of(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: _controller,
      child: Image.asset(
        'assets/images/launch_jellyfish.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
      ),
      builder: (context, jellyfish) {
        final t = _controller.value;
        final reveal = _phase(t, .82, 1);
        final flight = _phase(t, 0, .82);
        final entrance = _phase(t, 0, .16);
        final dark = theme.isDark;
        final background = dark
            ? const Color(0xFF101C25)
            : const Color(0xFFF5FAF8);
        return Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _visible ? (_) => _dismiss() : null,
              child: widget.child,
            ),
            if (_visible)
              IgnorePointer(
                child: Opacity(
                  opacity: .28 * (1 - reveal),
                  child: Material(
                    color: background,
                    child: ExcludeSemantics(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final size = constraints.biggest;
                          final center = _flightPoint(flight, size, reduced);
                          final side = math.min(size.width * .38, 180.0);
                          final beat = reduced
                              ? 0.0
                              : math.sin(flight * math.pi * 7);
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              RepaintBoundary(
                                child: CustomPaint(
                                  painter: _MoonSeaPainter(
                                    progress: reduced ? .5 : flight,
                                    entrance: entrance,
                                    dark: dark,
                                    reduced: reduced,
                                  ),
                                ),
                              ),
                              Positioned(
                                left: center.dx - side / 2,
                                top: center.dy - side * .52,
                                width: side,
                                height: side,
                                child: Opacity(
                                  opacity: entrance,
                                  child: Transform.rotate(
                                    angle: reduced
                                        ? 0
                                        : -.13 * math.cos(flight * math.pi * 2),
                                    child: Transform.scale(
                                      scaleX:
                                          (.8 + .2 * entrance) *
                                          (1 - .025 * beat),
                                      scaleY:
                                          (.8 + .2 * entrance) *
                                          (1 + .045 * beat),
                                      child: RepaintBoundary(child: jellyfish),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

double _phase(double t, double start, double end) => Curves.easeInOutCubic
    .transform(((t - start) / (end - start)).clamp(0.0, 1.0));

// A gentle figure-eight flight that returns to the centre before the dissolve.
Offset _flightPoint(double t, Size size, bool reduced) {
  if (reduced) return Offset(size.width * .5, size.height * .43);
  final envelope = math.sin(math.pi * t);
  return Offset(
    size.width * (.5 + .27 * math.sin(t * math.pi * 2) * envelope),
    size.height *
        (.43 -
            .11 * math.sin(t * math.pi) +
            .035 * math.sin(t * math.pi * 4) * envelope),
  );
}

class _MoonSeaPainter extends CustomPainter {
  const _MoonSeaPainter({
    required this.progress,
    required this.entrance,
    required this.dark,
    required this.reduced,
  });
  final double progress;
  final double entrance;
  final bool dark;
  final bool reduced;

  @override
  void paint(Canvas canvas, Size size) {
    final center = _flightPoint(progress, size, reduced);
    final radius = size.shortestSide * .7;
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          (dark ? const Color(0xFF80CDBA) : const Color(0xFFA6E9CE)).withValues(
            alpha: .19 * entrance,
          ),
          (dark ? const Color(0xFF7A83C1) : const Color(0xFFD4CEF4)).withValues(
            alpha: .08 * entrance,
          ),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, glow);

    // Deterministic dust avoids random jumps and expensive blur layers.
    for (var i = 0; i < 22; i++) {
      final seed = i * 2.399963;
      final x = size.width * (.08 + .84 * ((i * .618034) % 1));
      final y =
          size.height * (.19 + .5 * ((i * .381966) % 1)) -
          (reduced ? 0 : 16 * math.sin(progress * math.pi * 2 + seed));
      final alpha =
          (.12 + .12 * math.sin(seed + progress * math.pi).abs()) * entrance;
      final paint = Paint()
        ..color = (dark ? const Color(0xFFACDACF) : const Color(0xFF77AAA1))
            .withValues(alpha: alpha);
      canvas.drawCircle(Offset(x, y), i % 4 == 0 ? 1.8 : 1, paint);
    }
    if (reduced) return;

    // A tapered wake follows the same trajectory as the jellyfish.
    for (var i = 0; i < 24; i++) {
      final age = i / 24;
      final past = progress - age * .15;
      if (past < 0) continue;
      final point = _flightPoint(past, size, false) + Offset(0, 24 + age * 18);
      final paint = Paint()
        ..color = (dark ? const Color(0xFFB6EBD6) : const Color(0xFF9BCFBD))
            .withValues(
              alpha: (1 - age) * .16 * entrance * math.sin(progress * math.pi),
            );
      canvas.drawCircle(point, 2.5 * (1 - age) + .4, paint);
    }
    // Thin elliptical wavefronts open underneath as the mascot comes to rest.
    final settle = _phase(progress, .62, 1);
    for (var i = 0; i < 3; i++) {
      final wave = ((settle - i * .17) / (1 - i * .17)).clamp(0.0, 1.0);
      if (wave <= 0) continue;
      final width = size.width * (.13 + .55 * wave);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8
        ..color = (dark ? const Color(0xFFADDDCD) : const Color(0xFF85B9AB))
            .withValues(alpha: (1 - wave) * .24 * entrance);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width * .5, size.height * .54),
          width: width,
          height: width * .22,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MoonSeaPainter old) =>
      old.progress != progress ||
      old.entrance != entrance ||
      old.dark != dark ||
      old.reduced != reduced;
}
