import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Palette ──────────────────────────────────────────────────────────────────

class AymaColors {
  AymaColors._();

  static const bg        = Color(0xFF080808);
  static const surface   = Color(0xFF101010);
  static const card      = Color(0xFF141414);
  static const border    = Color(0xFF1C1C1C);
  static const borderSub = Color(0xFF141414);

  static const textPrimary   = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF666666);
  static const textTertiary  = Color(0xFF333333);

  static const accent      = Color(0xFF9B8AFB); // soft violet
  static const accentDark  = Color(0xFF6D28D9);
  static const accentGlow  = Color(0x1A9B8AFB);

  static const success = Color(0xFF34D399);
  static const error   = Color(0xFFF87171);
  static const warning = Color(0xFFFBBF24);

  // Gradient used on orb, buttons, badges
  static const LinearGradient accentGradient = LinearGradient(
    colors: [Color(0xFF9B8AFB), Color(0xFF6D28D9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient orbGradient = LinearGradient(
    colors: [Color(0xFF9B8AFB), Color(0xFF4F46E5), Color(0xFF7C3AED)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

// ── Theme ─────────────────────────────────────────────────────────────────────

class AymaTheme {
  AymaTheme._();

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final text = GoogleFonts.spaceGroteskTextTheme(base.textTheme);

    return base.copyWith(
      scaffoldBackgroundColor: AymaColors.bg,
      colorScheme: const ColorScheme.dark(
        surface:          AymaColors.surface,
        primary:          AymaColors.accent,
        onPrimary:        Colors.black,
        secondary:        AymaColors.accentDark,
        onSecondary:      Colors.white,
        error:            AymaColors.error,
        surfaceContainer: AymaColors.card,
      ),
      textTheme: text.copyWith(
        displayLarge:  text.displayLarge?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w700, letterSpacing: -1.0),
        displayMedium: text.displayMedium?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w700, letterSpacing: -0.5),
        headlineLarge: text.headlineLarge?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w700, letterSpacing: -0.5),
        headlineMedium:text.headlineMedium?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w600),
        headlineSmall: text.headlineSmall?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w600),
        titleLarge:    text.titleLarge?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w600),
        titleMedium:   text.titleMedium?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w500),
        titleSmall:    text.titleSmall?.copyWith(color: AymaColors.textSecondary, fontWeight: FontWeight.w500),
        bodyLarge:     text.bodyLarge?.copyWith(color: AymaColors.textPrimary),
        bodyMedium:    text.bodyMedium?.copyWith(color: AymaColors.textSecondary),
        bodySmall:     text.bodySmall?.copyWith(color: AymaColors.textTertiary),
        labelLarge:    text.labelLarge?.copyWith(color: AymaColors.textPrimary, fontWeight: FontWeight.w600, letterSpacing: 0.5),
        labelMedium:   text.labelMedium?.copyWith(color: AymaColors.textSecondary, letterSpacing: 0.5),
        labelSmall:    text.labelSmall?.copyWith(color: AymaColors.textTertiary, letterSpacing: 0.8),
      ),
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
          color: AymaColors.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: AymaColors.textSecondary),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AymaColors.surface,
        selectedItemColor: AymaColors.accent,
        unselectedItemColor: AymaColors.textTertiary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showSelectedLabels: false,
        showUnselectedLabels: false,
      ),
      cardTheme: const CardThemeData(
        color: AymaColors.card,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: AymaColors.border, width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AymaColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AymaColors.border, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AymaColors.border, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AymaColors.accent, width: 1),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AymaColors.error, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: const TextStyle(color: AymaColors.textTertiary, fontSize: 15),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
