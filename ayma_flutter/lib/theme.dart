import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Palette ──────────────────────────────────────────────────────────────────
// Approximated from the design's OKLCH tokens

class AymaColors {
  AymaColors._();

  // Background layers
  static const bg      = Color(0xFF131210); // oklch(0.13 0.006 60)
  static const bgElev  = Color(0xFF1B1916); // oklch(0.17 0.007 60)
  static const bgCard  = Color(0xFF222019); // oklch(0.20 0.008 60)

  // Borders / lines
  static const line     = Color(0xFF3A352A); // oklch(0.30 0.008 60)
  static const lineSoft = Color(0xFF2A261F); // oklch(0.22 0.006 60)

  // Text
  static const fg     = Color(0xFFEDE9DE); // oklch(0.94 0.012 80)
  static const fgDim  = Color(0xFFBAB3A3); // oklch(0.74 0.010 70)
  static const fgMute = Color(0xFF7E7669); // oklch(0.52 0.008 70)

  // Accent — Ember oklch(0.72 0.11 45) — warm terracotta-leaning orange
  static const accent      = Color(0xFFDE8E69);
  static const accentSoft  = Color(0x2EDE8E69); // ~18% alpha
  static const accentFaint = Color(0x14DE8E69); // ~8% alpha

  // Legacy aliases (keep existing code compiling)
  static const surface   = bgElev;
  static const card      = bgCard;
  static const border    = lineSoft;
  static const borderSub = Color(0xFF1F1D16);

  static const textPrimary   = fg;
  static const textSecondary = fgDim;
  static const textTertiary  = fgMute;

  static const gold        = accent;
  static const goldBright  = Color(0xFFCA7048); // ember bright
  static const goldSun     = Color(0xFFDE8E69); // ember base
  static const goldDim     = Color(0xFF7A3D20); // ember dark
  static const goldGlow    = Color(0x22DE8E69);
  static const goldGlowMid = Color(0x44DE8E69);
  static const accentDark  = goldDim;
  static const accentGlow  = goldGlow;

  static const success = Color(0xFF4CAF7D);
  static const error   = Color(0xFFCF4B4B);
  static const warning = Color(0xFFCA7048);

  static const LinearGradient accentGradient = LinearGradient(
    colors: [goldBright, accent, goldDim],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient orbGradient = LinearGradient(
    colors: [Color(0xFFEDC9B0), accent, goldDim],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

// ── Typography helpers ────────────────────────────────────────────────────────

class AymaFonts {
  AymaFonts._();

  static TextStyle serif({
    double size = 16,
    bool italic = false,
    FontWeight weight = FontWeight.w400,
    Color color = AymaColors.fg,
  }) =>
      GoogleFonts.instrumentSerif(
        fontSize: size,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        fontWeight: weight,
        color: color,
        height: 1.1,
        letterSpacing: -0.01 * size,
      );

  static TextStyle mono({
    double size = 10,
    Color color = AymaColors.fgMute,
    double letterSpacing = 0.2,
  }) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size,
        color: color,
        letterSpacing: size * letterSpacing,
        fontWeight: FontWeight.w400,
      );

  static TextStyle sans({
    double size = 14,
    Color color = AymaColors.fg,
    FontWeight weight = FontWeight.w400,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: 'Geist',
        fontSize: size,
        color: color,
        fontWeight: weight,
        letterSpacing: letterSpacing,
      );

  static TextStyle elegantSans({
    double size = 14,
    Color color = AymaColors.fg,
    FontWeight weight = FontWeight.w300,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: 'Geist',
        fontSize: size,
        color: color,
        fontWeight: weight,
        letterSpacing: letterSpacing,
      );
}

// ── Theme ─────────────────────────────────────────────────────────────────────

class AymaTheme {
  AymaTheme._();

  static TextTheme _buildTextTheme(TextTheme base) {
    return base.copyWith(
      displayLarge:  GoogleFonts.instrumentSerif(color: AymaColors.fg, fontSize: 52, height: 1.05),
      displayMedium: GoogleFonts.instrumentSerif(color: AymaColors.fg, fontSize: 40, height: 1.05),
      headlineLarge: GoogleFonts.instrumentSerif(color: AymaColors.fg, fontSize: 32, height: 1.1),
      headlineMedium:GoogleFonts.instrumentSerif(color: AymaColors.fg, fontSize: 26, height: 1.15),
      headlineSmall: GoogleFonts.instrumentSerif(color: AymaColors.fg, fontSize: 22, height: 1.2),
      titleLarge:  base.titleLarge?.copyWith(color: AymaColors.fg, fontWeight: FontWeight.w500),
      titleMedium: base.titleMedium?.copyWith(color: AymaColors.fg, fontWeight: FontWeight.w500, letterSpacing: 0),
      titleSmall:  base.titleSmall?.copyWith(color: AymaColors.fgDim, fontWeight: FontWeight.w400),
      bodyLarge:   base.bodyLarge?.copyWith(color: AymaColors.fg, fontSize: 15, height: 1.55),
      bodyMedium:  base.bodyMedium?.copyWith(color: AymaColors.fgDim, fontSize: 13, height: 1.5),
      bodySmall:   base.bodySmall?.copyWith(color: AymaColors.fgMute, fontSize: 12),
      labelLarge:  GoogleFonts.jetBrainsMono(
        color: AymaColors.fgMute, fontSize: 10,
        letterSpacing: 2.0, fontWeight: FontWeight.w400,
      ),
      labelMedium: GoogleFonts.jetBrainsMono(
        color: AymaColors.fgMute, fontSize: 9,
        letterSpacing: 1.8, fontWeight: FontWeight.w400,
      ),
      labelSmall: GoogleFonts.jetBrainsMono(
        color: AymaColors.fgMute, fontSize: 8,
        letterSpacing: 1.5, fontWeight: FontWeight.w400,
      ),
    );
  }

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final text = _buildTextTheme(base.textTheme);

    return base.copyWith(
      scaffoldBackgroundColor: AymaColors.bg,
      colorScheme: const ColorScheme.dark(
        surface:          AymaColors.bgElev,
        primary:          AymaColors.accent,
        onPrimary:        Colors.black,
        secondary:        AymaColors.goldDim,
        onSecondary:      Colors.white,
        error:            AymaColors.error,
        surfaceContainer: AymaColors.bgCard,
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
        iconTheme: IconThemeData(color: AymaColors.fgDim),
      ),
      cardTheme: CardThemeData(
        color: AymaColors.bgCard,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AymaColors.lineSoft, width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AymaColors.bgElev,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AymaColors.lineSoft, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AymaColors.lineSoft, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AymaColors.accent, width: 1),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AymaColors.error, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: const TextStyle(color: AymaColors.fgMute, fontSize: 14),
        labelStyle: const TextStyle(color: AymaColors.fgDim),
      ),
      dividerTheme: const DividerThemeData(
        color: AymaColors.lineSoft,
        thickness: 0.5,
        space: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AymaColors.bgCard,
        contentTextStyle: const TextStyle(color: AymaColors.fg),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: AymaColors.fg,
        unselectedItemColor: AymaColors.fgMute,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showSelectedLabels: false,
        showUnselectedLabels: false,
      ),
      extensions: [AymaColorExt.dark],
    );
  }

  static ThemeData get light {
    final base = ThemeData.light(useMaterial3: true);
    final ext = AymaColorExt.light;
    return base.copyWith(
      scaffoldBackgroundColor: ext.bg,
      colorScheme: ColorScheme.light(
        surface:          ext.bgElev,
        primary:          ext.accent,
        onPrimary:        Colors.white,
        secondary:        ext.bgCard,
        onSecondary:      ext.fg,
        error:            AymaColors.error,
        surfaceContainer: ext.bgCard,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: ext.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
        ),
        iconTheme: IconThemeData(color: ext.fgDim),
      ),
      cardTheme: CardThemeData(
        color: ext.bgCard,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: ext.lineSoft, width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ext.bgElev,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: ext.lineSoft, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: ext.lineSoft, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: ext.accent, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: TextStyle(color: ext.fgMute, fontSize: 14),
        labelStyle: TextStyle(color: ext.fgDim),
      ),
      dividerTheme: DividerThemeData(
        color: ext.lineSoft,
        thickness: 0.5,
        space: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ext.bgCard,
        contentTextStyle: TextStyle(color: ext.fg),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: ext.fg,
        unselectedItemColor: ext.fgMute,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showSelectedLabels: false,
        showUnselectedLabels: false,
      ),
      extensions: [ext],
    );
  }
}

// ── Color extension (theme-aware tokens) ─────────────────────────────────────

class AymaColorExt extends ThemeExtension<AymaColorExt> {
  const AymaColorExt({
    required this.bg,
    required this.bgElev,
    required this.bgCard,
    required this.line,
    required this.lineSoft,
    required this.fg,
    required this.fgDim,
    required this.fgMute,
    required this.accent,
    required this.accentSoft,
    required this.accentFaint,
  });

  final Color bg;
  final Color bgElev;
  final Color bgCard;
  final Color line;
  final Color lineSoft;
  final Color fg;
  final Color fgDim;
  final Color fgMute;
  final Color accent;
  final Color accentSoft;
  final Color accentFaint;

  static const AymaColorExt dark = AymaColorExt(
    bg:          AymaColors.bg,
    bgElev:      AymaColors.bgElev,
    bgCard:      AymaColors.bgCard,
    line:        AymaColors.line,
    lineSoft:    AymaColors.lineSoft,
    fg:          AymaColors.fg,
    fgDim:       AymaColors.fgDim,
    fgMute:      AymaColors.fgMute,
    accent:      AymaColors.accent,
    accentSoft:  AymaColors.accentSoft,
    accentFaint: AymaColors.accentFaint,
  );

  static const AymaColorExt light = AymaColorExt(
    bg:          Color(0xFFFAF8F4),
    bgElev:      Color(0xFFF3F0EB),
    bgCard:      Color(0xFFEBE7E0),
    line:        Color(0xFFCDC8BE),
    lineSoft:    Color(0xFFDDD9D2),
    fg:          Color(0xFF1A1714),
    fgDim:       Color(0xFF4A443B),
    fgMute:      Color(0xFF7A7468),
    accent:      AymaColors.accent,
    accentSoft:  AymaColors.accentSoft,
    accentFaint: AymaColors.accentFaint,
  );

  @override
  AymaColorExt copyWith({
    Color? bg, Color? bgElev, Color? bgCard, Color? line, Color? lineSoft,
    Color? fg, Color? fgDim, Color? fgMute, Color? accent,
    Color? accentSoft, Color? accentFaint,
  }) => AymaColorExt(
    bg:          bg          ?? this.bg,
    bgElev:      bgElev      ?? this.bgElev,
    bgCard:      bgCard      ?? this.bgCard,
    line:        line        ?? this.line,
    lineSoft:    lineSoft    ?? this.lineSoft,
    fg:          fg          ?? this.fg,
    fgDim:       fgDim       ?? this.fgDim,
    fgMute:      fgMute      ?? this.fgMute,
    accent:      accent      ?? this.accent,
    accentSoft:  accentSoft  ?? this.accentSoft,
    accentFaint: accentFaint ?? this.accentFaint,
  );

  @override
  AymaColorExt lerp(AymaColorExt? other, double t) {
    if (other == null) return this;
    return AymaColorExt(
      bg:          Color.lerp(bg,          other.bg,          t)!,
      bgElev:      Color.lerp(bgElev,      other.bgElev,      t)!,
      bgCard:      Color.lerp(bgCard,      other.bgCard,      t)!,
      line:        Color.lerp(line,        other.line,        t)!,
      lineSoft:    Color.lerp(lineSoft,    other.lineSoft,    t)!,
      fg:          Color.lerp(fg,          other.fg,          t)!,
      fgDim:       Color.lerp(fgDim,       other.fgDim,       t)!,
      fgMute:      Color.lerp(fgMute,      other.fgMute,      t)!,
      accent:      Color.lerp(accent,      other.accent,      t)!,
      accentSoft:  Color.lerp(accentSoft,  other.accentSoft,  t)!,
      accentFaint: Color.lerp(accentFaint, other.accentFaint, t)!,
    );
  }
}

extension AymaContextColors on BuildContext {
  AymaColorExt get ac =>
      Theme.of(this).extension<AymaColorExt>() ?? AymaColorExt.dark;
}

// ── HUD Panel ─────────────────────────────────────────────────────────────────

/// Kept for backward compat — used by insights_screen.dart
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
            color: context.ac.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: glowing ? AymaColors.goldDim : context.ac.lineSoft,
              width: 0.5,
            ),
            boxShadow: glowing
                ? [const BoxShadow(color: AymaColors.goldGlow, blurRadius: 16)]
                : null,
          ),
          child: child,
        ),
        Positioned(top: 0, left: 0,    child: _CornerMark(q: 0, size: cornerSize)),
        Positioned(top: 0, right: 0,   child: _CornerMark(q: 1, size: cornerSize)),
        Positioned(bottom: 0, left: 0, child: _CornerMark(q: 2, size: cornerSize)),
        Positioned(bottom: 0, right: 0,child: _CornerMark(q: 3, size: cornerSize)),
      ],
    );
  }
}

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
    ..color = AymaColors.accent
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.square;

  @override
  void paint(Canvas c, Size s) {
    final w = s.width;
    final h = s.height;
    switch (q) {
      case 0:
        c.drawLine(Offset(0, h), Offset(0, 0), _paint);
        c.drawLine(Offset(0, 0), Offset(w, 0), _paint);
      case 1:
        c.drawLine(Offset(0, 0), Offset(w, 0), _paint);
        c.drawLine(Offset(w, 0), Offset(w, h), _paint);
      case 2:
        c.drawLine(Offset(0, 0), Offset(0, h), _paint);
        c.drawLine(Offset(0, h), Offset(w, h), _paint);
      case 3:
        c.drawLine(Offset(w, 0), Offset(w, h), _paint);
        c.drawLine(Offset(0, h), Offset(w, h), _paint);
    }
  }

  @override
  bool shouldRepaint(_CornerPainter o) => o.q != q;
}
