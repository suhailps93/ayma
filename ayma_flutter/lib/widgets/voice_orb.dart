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

class _VoiceOrbState extends State<VoiceOrb>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double get _activity {
    switch (widget.state) {
      case SessionState.listening: return widget.inputVolume;
      case SessionState.speaking:  return widget.outputVolume;
      default:                     return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final active = widget.state == SessionState.listening ||
                   widget.state == SessionState.speaking;

    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: s * 1.6,
        height: s * 1.6,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Outer glow ring
            if (active)
              _Ring(
                size: s * 1.5 + (_activity * s * 0.2),
                color: AymaColors.accent.withValues(alpha: 0.06),
              ).animate(controller: _ctrl).scale(
                begin: const Offset(0.95, 0.95),
                end: const Offset(1.05, 1.05),
                curve: Curves.easeInOut,
              ),

            // Mid ring
            _Ring(
              size: s * 1.15,
              color: AymaColors.accent.withValues(alpha: active ? 0.10 : 0.03),
            ).animate(controller: _ctrl).scale(
              begin: const Offset(0.98, 0.98),
              end: const Offset(1.02, 1.02),
              curve: Curves.easeInOut,
              delay: 200.ms,
            ),

            // Inner ring
            _Ring(
              size: s * 0.88,
              color: AymaColors.accent.withValues(alpha: active ? 0.15 : 0.05),
            ),

            // Core orb
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: s * (0.65 + _activity * 0.12),
              height: s * (0.65 + _activity * 0.12),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: active
                    ? AymaColors.orbGradient
                    : const LinearGradient(
                        colors: [Color(0xFF1E1E1E), Color(0xFF141414)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: AymaColors.accent.withValues(alpha: 0.25),
                          blurRadius: 32,
                          spreadRadius: 2,
                        )
                      ]
                    : [],
              ),
              child: widget.state == SessionState.thinking
                  ? _ThinkingSpinner(size: s * 0.28)
                  : widget.state == SessionState.connecting
                      ? _ConnectingDots(size: s * 0.2)
                      : widget.state == SessionState.disconnected
                          ? Icon(Icons.mic_none_rounded,
                              color: AymaColors.textTertiary, size: s * 0.28)
                          : _WaveIcon(state: widget.state, size: s * 0.3),
            ),
          ],
        ),
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  final double size;
  final Color color;
  const _Ring({required this.size, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 1),
    ),
  );
}

class _WaveIcon extends StatelessWidget {
  final SessionState state;
  final double size;
  const _WaveIcon({required this.state, required this.size});

  @override
  Widget build(BuildContext context) {
    final isListening = state == SessionState.listening;
    return Icon(
      isListening ? Icons.mic_rounded : Icons.volume_up_rounded,
      color: Colors.white,
      size: size,
    ).animate(onPlay: (c) => c.repeat(reverse: true))
     .scaleXY(begin: 0.92, end: 1.08, duration: 800.ms, curve: Curves.easeInOut);
  }
}

class _ThinkingSpinner extends StatefulWidget {
  final double size;
  const _ThinkingSpinner({required this.size});
  @override State<_ThinkingSpinner> createState() => _ThinkingSpinnerState();
}

class _ThinkingSpinnerState extends State<_ThinkingSpinner>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override void initState() { super.initState(); _c = AnimationController(vsync: this, duration: 1200.ms)..repeat(); }
  @override void dispose()   { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, __) => CustomPaint(
      size: Size(widget.size, widget.size),
      painter: _ArcPainter(_c.value),
    ),
  );
}

class _ArcPainter extends CustomPainter {
  final double t;
  _ArcPainter(this.t);
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = AymaColors.accent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    c.drawArc(
      Rect.fromLTWH(0, 0, s.width, s.height),
      t * 2 * math.pi,
      math.pi * 1.2,
      false,
      p,
    );
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
        width: size * 0.22,
        height: size * 0.22,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AymaColors.textTertiary,
        ),
      ).animate(onPlay: (c) => c.repeat(reverse: true))
       .fadeIn(delay: (i * 150).ms, duration: 400.ms)
       .scaleXY(begin: 0.6, end: 1.0),
    ),
  );
}
