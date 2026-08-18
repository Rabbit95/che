import 'package:flutter/material.dart';

/// Design tokens for the Nikon Z Control UI — kept in one place so the
/// same values feed both the [ThemeData] and hand-authored widgets.
///
/// Values traced from `ui-mockups/index.html` (design v0.1).
abstract final class AppColors {
  AppColors._();

  static const Color background = Color(0xFF09090B);
  static const Color pageBackground = Color(0xFF050506);
  static const Color panel = Color(0xFF131317);
  static const Color surface = Color(0xFF1A1A20);
  static const Color surface2 = Color(0xFF24242C);
  static const Color surface3 = Color(0xFF2D2D37);

  static const Color border = Color(0x0FFFFFFF);
  static const Color borderStrong = Color(0x1FFFFFFF);

  static const Color text = Color(0xFFF5F5F7);
  static const Color text2 = Color(0xFFA1A1AA);
  static const Color text3 = Color(0xFF71717A);
  static const Color text4 = Color(0xFF52525B);

  static const Color accent = Color(0xFFE8B455);
  static const Color accentSubtle = Color(0x24E8B455); // 14% alpha
  static const Color record = Color(0xFFFF2D2D);
  static const Color success = Color(0xFF22C55E);
  static const Color info = Color(0xFF3B82F6);
  static const Color warn = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFEF4444);
}

abstract final class AppRadius {
  AppRadius._();

  static const BorderRadius chip = BorderRadius.all(Radius.circular(100));
  static const BorderRadius card = BorderRadius.all(Radius.circular(14));
  static const BorderRadius sheet = BorderRadius.vertical(top: Radius.circular(28));
  static const BorderRadius button = BorderRadius.all(Radius.circular(100));
  static const BorderRadius tile = BorderRadius.all(Radius.circular(12));
}

abstract final class AppSpacing {
  AppSpacing._();

  static const double xxs = 4;
  static const double xs = 8;
  static const double s = 12;
  static const double m = 16;
  static const double l = 20;
  static const double xl = 24;
}

abstract final class AppTypography {
  AppTypography._();

  /// System UI stack — matches the mockup's `--font-ui`.
  static const List<String> uiFontFallback = [
    'SF Pro Text',
    'PingFang SC',
    'Inter',
    'Segoe UI',
    'Roboto',
  ];

  /// Monospace stack for numbers, filenames, hex — `--font-mono`.
  static const List<String> monoFontFallback = [
    'SF Mono',
    'Menlo',
    'Cascadia Code',
    'Roboto Mono',
    'monospace',
  ];

  static const TextStyle title = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.18,
    color: AppColors.text,
    fontFamilyFallback: uiFontFallback,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.5,
    color: AppColors.text,
    fontFamilyFallback: uiFontFallback,
  );

  static const TextStyle bodySecondary = TextStyle(
    fontSize: 13,
    height: 1.5,
    color: AppColors.text2,
    fontFamilyFallback: uiFontFallback,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.5,
    color: AppColors.text3,
    fontFamilyFallback: uiFontFallback,
  );

  static const TextStyle sectionLabel = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.88,
    color: AppColors.text4,
    fontFamilyFallback: monoFontFallback,
  );

  static const TextStyle mono = TextStyle(
    fontSize: 12,
    color: AppColors.text2,
    fontFamilyFallback: monoFontFallback,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle monoStat = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: AppColors.text,
    letterSpacing: -0.3,
    fontFamilyFallback: monoFontFallback,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle monoStatLarge = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.56,
    color: AppColors.text,
    fontFamilyFallback: monoFontFallback,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle badge = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    fontFamilyFallback: monoFontFallback,
  );
}

/// Builds the app-wide [ThemeData]. Kept a plain function so we can drop
/// in a light variant later without touching call sites.
ThemeData buildAppTheme() {
  const seed = AppColors.accent;
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    canvasColor: AppColors.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: AppColors.surface,
      onSurface: AppColors.text,
      primary: AppColors.accent,
      onPrimary: Colors.black,
      error: AppColors.danger,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    dividerColor: AppColors.border,
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
      fontFamilyFallback: AppTypography.uiFontFallback,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: AppColors.text2),
      titleTextStyle: AppTypography.title,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.panel,
      selectedItemColor: AppColors.accent,
      unselectedItemColor: AppColors.text3,
      showUnselectedLabels: true,
      type: BottomNavigationBarType.fixed,
      selectedLabelStyle: TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
      unselectedLabelStyle: TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
    ),
    iconTheme: const IconThemeData(color: AppColors.text2, size: 20),
  );
}
