import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/audio_service.dart';
import '../theme.dart';

// Organic animated blob orb — matches the Claude Design prototype.
//
// State map:
//   disconnected / ready  →  idle    (amp 0.03, slow)
//   connecting            →  thinking (amp 0.06, 3 dots)
//   listening             →  listening (amp 0.10)
//   thinking              →  thinking  (amp 0.06 + dots)
//   speaking              →  speaking  (amp 0.14, fast)

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
    this.size = 190,
  });

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 60))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _orbState {
    switch (widget.state) {
      case SessionState.listening:   return 'listening';
      case SessionState.speaking:    return 'speaking';
      case SessionState.thinking:    return 'thinking';
      case SessionState.connecting:  return 'thinking';
      default:                       return 'idle';
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          final t = _ctrl.value * 60.0; // seconds
          return CustomPaint(
            size: Size(widget.size, widget.size),
            painter: _OrbPainter(
              t: t,
              orbState: _orbState,
              activity: _orbState == 'listening'
                  ? widget.inputVolume
                  : _orbState == 'speaking'
                      ? widget.outputVolume
                      : 0,
            ),
          );
        },
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  final double t;
  final String orbState;
  final double activity;

  _OrbPainter({required this.t, required this.orbState, required this.activity});

  static const _pts = 64;

  double get _amp {
    switch (orbState) {
      case 'listening': return 0.10 + activity * 0.08;
      case 'speaking':  return 0.14 + activity * 0.06;
      case 'thinking':  return 0.06;
      default:          return 0.03;
    }
  }

  double get _speed {
    switch (orbState) {
      case 'thinking': return 0.6;
      case 'speaking': return 1.8;
      default:         return 1.0;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final R  = size.width * 0.38;
    final amp   = _amp;
    final speed = _speed;

    // ── Build blob path ──────────────────────────────────────────
    final pts = List<Offset>.generate(_pts, (i) {
      final a = (i / _pts) * math.pi * 2;
      final n =
          math.sin(a * 3 + t * speed)          * amp +
          math.sin(a * 5 - t * speed * 1.3)    * amp * 0.5 +
          math.sin(a * 2 + t * speed * 0.7)    * amp * 0.8;
      final r = R * (1 + n);
      return Offset(cx + math.cos(a) * r, cy + math.sin(a) * r);
    });

    // Smooth quadratic bezier path via midpoints
    final path = Path();
    path.moveTo((pts[0].dx + pts[1].dx) / 2, (pts[0].dy + pts[1].dy) / 2);
    for (int i = 0; i < _pts; i++) {
      final p0 = pts[i];
      final p1 = pts[(i + 1) % _pts];
      final mx = (p0.dx + p1.dx) / 2;
      final my = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, mx, my);
    }
    path.close();

    final rect = Rect.fromCenter(center: Offset(cx, cy), width: size.width, height: size.height);

    // ── Outer halo rings ─────────────────────────────────────────
    final haloPaint = Paint()
      ..color = AymaColors.accent.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    canvas.drawCircle(Offset(cx, cy), R * 1.5, haloPaint);
    haloPaint.color = AymaColors.accent.withValues(alpha: 0.12);
    canvas.drawCircle(Offset(cx, cy), R * 1.25, haloPaint);

    // Soft outer glow
    final pulse = 1 + math.sin(t * 1.5) * 0.015;
    final glowPaint = Paint()
      ..color = AymaColors.accent.withValues(
          alpha: orbState == 'idle' ? 0.04 : 0.09)
      ..style = PaintingStyle.fill;
    canvas.save();
    canvas.scale(pulse, pulse);
    canvas.translate(cx * (1 - pulse), cy * (1 - pulse));
    canvas.drawCircle(Offset(cx, cy), R * 1.15, glowPaint);
    canvas.restore();

    // ── Main blob fill — radial gradient ─────────────────────────
    // Approximate the design's RadialGradient from cx=50% cy=42%
    final fillPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment(-0.0, -0.16), // ~cy=42%
        radius: 0.55,
        colors: const [
          Color(0xFFEBD5A8), // warm white highlight
          AymaColors.accent,
          Color(0xFF5A3A08), // oklch(0.35 0.06 40)
          Color(0xFF2A1A04), // oklch(0.20 0.03 40)
        ],
        stops: const [0.0, 0.40, 0.85, 1.0],
      ).createShader(rect)
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, fillPaint);

    // Highlight overlay
    final highlightPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.1, -0.3), // cx=45% cy=35%
        radius: 0.30,
        colors: [
          Colors.white.withValues(alpha: 0.5),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(rect)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, highlightPaint);

    // Inner depth ring
    final innerRing = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    canvas.drawCircle(Offset(cx, cy), R * 0.85, innerRing);

    // ── Thinking dots ─────────────────────────────────────────────
    if (orbState == 'thinking') {
      final dotPaint = Paint()..style = PaintingStyle.fill;
      const dotR = 3.5;
      const spacing = 12.0;
      for (int i = 0; i < 3; i++) {
        final opacity = 0.3 + 0.7 * math.max(0, math.sin(t * 3 - i * 0.8));
        dotPaint.color = Colors.white.withValues(alpha: opacity);
        canvas.drawCircle(
          Offset(cx + (i - 1) * spacing, cy),
          dotR,
          dotPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_OrbPainter o) =>
      o.t != t || o.orbState != orbState || o.activity != activity;
}
