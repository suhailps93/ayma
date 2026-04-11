import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Palette ──────────────────────────────────────────────────────────────────

class AymaColors {
  AymaColors._();

  static const bg        = Color(0xFF070707);
  static const surface   = Color(0xFF0D0D0D);
  static const card      = Color(0xFF111111);
  static const border    = Color(0xFF2A200A);
  static const borderSub = Color(0xFF1A1408);

  static const textPrimary   = Color(0xFFEEE8D5);
  static const textSecondary = Color(0xFF8A7A50);
  static const textTertiary  = Color(0xFF3D3420);

  // Gold palette
  static const gold        = Color(0xFFC8860A);
  static const goldBright  = Color(0xFFFFB800);
  static const goldDim     = Color(0xFF7A5206);
  static const goldGlow    = Color(0x22C8860A);
  static const goldGlowMid = Color(0x44C8860A);

  // Aliases so existing code compiles unchanged
  static const accent      = gold;
  static const accentDark  = goldDim;
  static const accentGlow  = goldGlow;

  static const success = Color(0xFF4CAF7D);
  static const error   = Color(0xFFCF4B4B);
  static const warning = Color(0xFFFFB800);

  static const LinearGradient accentGradient = LinearGradient(
    colors: [goldBright, gold, Color(0xFF7A5206)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient orbGradient = LinearGradient(
    colors: [Color(0xFFFFD060), Color(0xFFC8860A), Color(0xFF7A5206)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

// ── Theme ─────────────────────────────────────────────────────────────────────

class AymaTheme {
  AymaTheme._();

  static TextTheme _buildTextTheme(TextTheme base) {
    final orb = GoogleFonts.orbitronTextTheme(base);
    final sp  = GoogleFonts.spaceGroteskTextTheme(base);
    return base.copyWith(
      displayLarge:  orb.displayLarge?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w700, letterSpacing: 2.0),
      displayMedium: orb.displayMedium?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w700, letterSpacing: 1.5),
      headlineLarge: orb.headlineLarge?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w700, letterSpacing: 1.0),
      headlineMedium:orb.headlineMedium?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w600, letterSpacing: 0.8),
      headlineSmall: orb.headlineSmall?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w600, letterSpacing: 0.5),
      titleLarge:    orb.titleLarge?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w600, letterSpacing: 0.5),
      titleMedium:   sp.titleMedium?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w500, letterSpacing: 0.3),
      titleSmall:    sp.titleSmall?.copyWith(color: AymaColors.textSecondary, fontWeight: FontWeight.w500, letterSpacing: 0.5),
      bodyLarge:     sp.bodyLarge?.copyWith(color: AymaColors.textPrimary),
      bodyMedium:    sp.bodyMedium?.copyWith(color: AymaColors.textSecondary),
      bodySmall:     sp.bodySmall?.copyWith(color: AymaColors.textTertiary),
      labelLarge:    orb.labelLarge?.copyWith(color: AymaColors.gold, fontWeight: FontWeight.w600, letterSpacing: 1.5),
      labelMedium:   sp.labelMedium?.copyWith(color: AymaColors.textSecondary, letterSpacing: 1.0),
      labelSmall:    sp.labelSmall?.copyWith(color: AymaColors.textTertiary, letterSpacing: 1.2),
    );
  }

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final text = _buildTextTheme(base.textTheme);

    return base.copyWith(
      scaffoldBackgroundColor: AymaColors.bg,
      colorScheme: const ColorScheme.dark(
        surface:          AymaColors.surface,
        primary:          AymaColors.gold,
        onPrimary:        Colors.black,
        secondary:        AymaColors.goldDim,
        onSecondary:      Colors.white,
        error:            AymaColors.error,
        surfaceContainer: AymaColors.card,
      ),
      textTheme: text,
      appBarTheme: const AppBarTheme(
        backgroundColor: AymaColors.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
        ),
        titleTextStyle: TextStyle(
          color: AymaColors.goldBright,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 2.5,
        ),
        iconTheme: IconThemeData(color: AymaColors.textSecondary),
      ),
      cardTheme: CardThemeData(
        color: AymaColors.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(2),
          side: const BorderSide(color: AymaColors.border, width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AymaColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: AymaColors.border, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: AymaColors.border, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: AymaColors.gold, width: 1),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(2),
          borderSide: const BorderSide(color: AymaColors.error, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: const TextStyle(color: AymaColors.textTertiary, fontSize: 14, letterSpacing: 0.5),
        labelStyle: const TextStyle(color: AymaColors.textSecondary),
      ),
      dividerTheme: const DividerThemeData(
        color: AymaColors.border,
        thickness: 0.5,
        space: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AymaColors.card,
        contentTextStyle: const TextStyle(color: AymaColors.textPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
        behavior: SnackBarBehavior.floating,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AymaColors.surface,
        selectedItemColor: AymaColors.gold,
        unselectedItemColor: AymaColors.textTertiary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showSelectedLabels: false,
        showUnselectedLabels: false,
      ),
    );
  }
}

// ── HUD Panel ─────────────────────────────────────────────────────────────────

/// Dark panel with gold corner tick marks — sci-fi HUD aesthetic
class HudPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double cornerSize;
  final bool glowing;

  const HudPanel({
    super.key,
    required this.child,
    this.padding,
    this.cornerSize = 10,
    this.glowing = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          padding: padding,
          decoration: BoxDecoration(
            color: AymaColors.card,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(
              color: glowing ? AymaColors.goldDim : AymaColors.border,
              width: 0.5,
            ),
            boxShadow: glowing
                ? [const BoxShadow(color: AymaColors.goldGlow, blurRadius: 16, spreadRadius: 0)]
                : null,
          ),
          child: child,
        ),
        Positioned(top: 0, left: 0,   child: _CornerMark(q: 0, size: cornerSize)),
        Positioned(top: 0, right: 0,  child: _CornerMark(q: 1, size: cornerSize)),
        Positioned(bottom: 0, left: 0, child: _CornerMark(q: 2, size: cornerSize)),
        Positioned(bottom: 0, right: 0, child: _CornerMark(q: 3, size: cornerSize)),
      ],
    );
  }
}

/// q=0 top-left, 1=top-right, 2=bottom-left, 3=bottom-right
class _CornerMark extends StatelessWidget {
  final int q;
  final double size;
  const _CornerMark({required this.q, required this.size});

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(size, size),
    painter: _CornerPainter(q: q),
  );
}

class _CornerPainter extends CustomPainter {
  final int q;
  _CornerPainter({required this.q});

  static final _paint = Paint()
    ..color = AymaColors.gold
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.square;

  @override
  void paint(Canvas c, Size s) {
    final w = s.width;
    final h = s.height;
    switch (q) {
      case 0: // top-left
        c.drawLine(Offset(0, h), Offset(0, 0), _paint);
        c.drawLine(Offset(0, 0), Offset(w, 0), _paint);
      case 1: // top-right
        c.drawLine(Offset(0, 0), Offset(w, 0), _paint);
        c.drawLine(Offset(w, 0), Offset(w, h), _paint);
      case 2: // bottom-left
        c.drawLine(Offset(0, 0), Offset(0, h), _paint);
        c.drawLine(Offset(0, h), Offset(w, h), _paint);
      case 3: // bottom-right
        c.drawLine(Offset(w, 0), Offset(w, h), _paint);
        c.drawLine(Offset(0, h), Offset(w, h), _paint);
    }
  }

  @override
  bool shouldRepaint(_CornerPainter o) => o.q != q;
}
