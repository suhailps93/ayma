import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../services/audio_service.dart';
import '../theme.dart';

class VoiceOrb extends StatefulWidget {
  final SessionState state;
  final double inputVolume;
  final double outputVolume;
  final VoidCallback? onTap;
  final double size;

  const VoiceOrb({
    super.key,
    required this.state,
    this.inputVolume  = 0,
    this.outputVolume = 0,
    this.onTap,
    this.size = 160,
  });

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  double get _activity {
    switch (widget.state) {
      case SessionState.listening: return widget.inputVolume;
      case SessionState.speaking:  return widget.outputVolume;
      default: return 0;
    }
  }

  bool get _active =>
      widget.state == SessionState.listening || widget.state == SessionState.speaking;

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: s * 1.7,
        height: s * 1.7,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Rotating scan sweep
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Transform.rotate(
                angle: _ctrl.value * 2 * math.pi,
                child: CustomPaint(
                  size: Size(s * 1.55, s * 1.55),
                  painter: _ScanRingPainter(active: _active, activity: _activity),
                ),
              ),
            ),

            // Outer dashed ring (breathing)
            _GoldRing(size: s * 1.25, opacity: _active ? 0.18 : 0.06, dashed: true)
                .animate(controller: _ctrl)
                .scale(begin: const Offset(0.97, 0.97), end: const Offset(1.03, 1.03),
                       curve: Curves.easeInOut),

            // Mid ring
            _GoldRing(size: s * 0.95, opacity: _active ? 0.28 : 0.08)
                .animate(controller: _ctrl)
                .scale(begin: const Offset(0.99, 0.99), end: const Offset(1.01, 1.01),
                       curve: Curves.easeInOut, delay: 400.ms),

            // Core orb
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width:  s * (0.62 + _activity * 0.14),
              height: s * (0.62 + _activity * 0.14),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: _active
                    ? AymaColors.orbGradient
                    : const RadialGradient(
                        colors: [Color(0xFF1C1508), Color(0xFF080808)],
                        center: Alignment(-0.3, -0.3),
                      ),
                boxShadow: _active
                    ? [
                        BoxShadow(
                          color: AymaColors.gold.withValues(alpha: 0.35 + _activity * 0.25),
                          blurRadius: 40 + _activity * 20,
                          spreadRadius: 4,
                        ),
                        BoxShadow(
                          color: AymaColors.goldBright.withValues(alpha: 0.12),
                          blurRadius: 80,
                          spreadRadius: 8,
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: AymaColors.gold.withValues(alpha: 0.07),
                          blurRadius: 20,
                        ),
                      ],
                border: Border.all(
                  color: _active
                      ? AymaColors.gold.withValues(alpha: 0.55)
                      : AymaColors.goldDim.withValues(alpha: 0.2),
                  width: 0.5,
                ),
              ),
              child: _OrbIcon(state: widget.state, size: s * 0.28),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoldRing extends StatelessWidget {
  final double size;
  final double opacity;
  final bool dashed;
  const _GoldRing({required this.size, required this.opacity, this.dashed = false});

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(size, size),
    painter: _RingPainter(opacity: opacity, dashed: dashed),
  );
}

class _RingPainter extends CustomPainter {
  final double opacity;
  final bool dashed;
  _RingPainter({required this.opacity, required this.dashed});

  @override
  void paint(Canvas c, Size s) {
    final center = Offset(s.width / 2, s.height / 2);
    final r = s.width / 2;
    final paint = Paint()
      ..color = AymaColors.gold.withValues(alpha: opacity)
      ..strokeWidth = dashed ? 0.8 : 0.5
      ..style = PaintingStyle.stroke;
    if (!dashed) { c.drawCircle(center, r, paint); return; }
    const dashCount = 48;
    final dashAngle = (2 * math.pi) / dashCount;
    for (int i = 0; i < dashCount; i++) {
      if (i % 3 == 2) continue;
      c.drawArc(Rect.fromCircle(center: center, radius: r), i * dashAngle, dashAngle * 0.6, false, paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.opacity != opacity;
}

class _ScanRingPainter extends CustomPainter {
  final bool active;
  final double activity;
  _ScanRingPainter({required this.active, required this.activity});

  @override
  void paint(Canvas c, Size s) {
    if (!active && activity < 0.01) return;
    final center = Offset(s.width / 2, s.height / 2);
    final r = s.width / 2 - 1;
    final paint = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 0.7,
        colors: [Colors.transparent, AymaColors.gold.withValues(alpha: active ? 0.3 : 0.08)],
      ).createShader(Rect.fromCircle(center: center, radius: r))
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    c.drawArc(Rect.fromCircle(center: center, radius: r), -math.pi / 2, math.pi * 0.7, false, paint);
  }

  @override
  bool shouldRepaint(_ScanRingPainter o) => o.active != active;
}

class _OrbIcon extends StatelessWidget {
  final SessionState state;
  final double size;
  const _OrbIcon({required this.state, required this.size});

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case SessionState.thinking:    return _GoldSpinner(size: size);
      case SessionState.connecting:  return _ConnectingDots(size: size);
      case SessionState.disconnected:
        return Icon(Icons.mic_none_rounded, color: AymaColors.goldDim, size: size);
      case SessionState.ready:
        return Icon(Icons.mic_rounded, color: AymaColors.gold.withValues(alpha: 0.45), size: size);
      case SessionState.listening:
        return Icon(Icons.mic_rounded, color: Colors.white, size: size)
            .animate(onPlay: (c) => c.repeat(reverse: true))
            .scaleXY(begin: 0.88, end: 1.12, duration: 600.ms, curve: Curves.easeInOut);
      case SessionState.speaking:
        return Icon(Icons.volume_up_rounded, color: Colors.white, size: size)
            .animate(onPlay: (c) => c.repeat(reverse: true))
            .scaleXY(begin: 0.9, end: 1.1, duration: 700.ms, curve: Curves.easeInOut);
    }
  }
}

class _GoldSpinner extends StatefulWidget {
  final double size;
  const _GoldSpinner({required this.size});
  @override State<_GoldSpinner> createState() => _GoldSpinnerState();
}

class _GoldSpinnerState extends State<_GoldSpinner> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override void initState() { super.initState(); _c = AnimationController(vsync: this, duration: 1000.ms)..repeat(); }
  @override void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, __) => CustomPaint(size: Size(widget.size, widget.size), painter: _ArcPainter(_c.value)),
  );
}

class _ArcPainter extends CustomPainter {
  final double t;
  _ArcPainter(this.t);
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..shader = SweepGradient(colors: [Colors.transparent, AymaColors.goldBright])
          .createShader(Rect.fromLTWH(0, 0, s.width, s.height))
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    c.drawArc(Rect.fromLTWH(0, 0, s.width, s.height), t * 2 * math.pi, math.pi * 1.4, false, p);
  }
  @override bool shouldRepaint(_ArcPainter o) => o.t != t;
}

class _ConnectingDots extends StatelessWidget {
  final double size;
  const _ConnectingDots({required this.size});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: List.generate(3, (i) =>
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        width: size * 0.20, height: size * 0.20,
        decoration: BoxDecoration(shape: BoxShape.circle, color: AymaColors.gold.withValues(alpha: 0.6)),
      ).animate(onPlay: (c) => c.repeat(reverse: true))
       .fadeIn(delay: (i * 180).ms, duration: 400.ms)
       .scaleXY(begin: 0.5, end: 1.0),
    ),
  );
}
