import 'package:flutter/material.dart';

/// Mirrors the Lichess-style light color scheme from the screenshots.
class AppColors {
  // Primary navy accent
  static const Color primary = Color(0xFF1B3A6B);
  static const Color primaryLight = Color(0xFFDEE8F8);

  // Backgrounds
  static const Color scaffoldBg = Color(0xFFF2F2F7);
  static const Color surface = Colors.white;
  static const Color cardBg = Colors.white;

  // Board colors (wood texture)
  static const Color boardLight = Color(0xFFF0D9B5);
  static const Color boardDark = Color(0xFFB58863);
  static const Color lastMoveHighlight = Color(0x8097BE5A); // green tint
  static const Color engineHighlight = Color(0x6040B0FF); // blue tint

  // Text
  static const Color textPrimary = Color(0xFF1A1A1A);
  static const Color textSecondary = Color(0xFF6B6B6B);
  static const Color textHint = Color(0xFFAAAAAA);

  // Move notation
  static const Color moveNumberColor = Color(0xFF999999);
  static const Color moveActiveBackground = Color(0xFFDEDEDE); // subtle gray, not distracting
  static const Color moveActiveText = Color(0xFF1A1A1A);       // same as textPrimary
  static const Color moveText = Color(0xFF333333);
  static const Color variationText = Color(0xFF777777);
  static const Color variationBg = Color(0xFFF0F0F0);

  // Nav
  static const Color navBarBg = Color(0xFFF2F2F7);
  static const Color navBarActive = Color(0xFF1B3A6B);
  static const Color navBarInactive = Color(0xFFBBBBBB);

  // Evaluation bar
  static const Color evalWhite = Colors.white;
  static const Color evalBlack = Color(0xFF333333);

  // Dividers / borders
  static const Color divider = Color(0xFFE0E0E0);
  static const Color border = Color(0xFFDDDDDD);

  // Comments
  static const Color commentBg = Color(0xFFF8F5EE);
  static const Color commentText = Color(0xFF555555);

  // Chapter tabs
  static const Color chapterTabBg = Color(0xFFEEEEEE);
  static const Color chapterTabActive = Color(0xFF1B3A6B);
}

ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.scaffoldBg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
      surface: AppColors.surface,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.scaffoldBg,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.navBarBg,
      selectedItemColor: AppColors.navBarActive,
      unselectedItemColor: AppColors.navBarInactive,
      type: BottomNavigationBarType.fixed,
      elevation: 8,
    ),
    dividerColor: AppColors.divider,
    cardTheme: const CardThemeData(
      color: AppColors.cardBg,
      elevation: 0,
      margin: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: AppColors.border, width: 0.5),
      ),
    ),
    fontFamily: 'Roboto',
  );
}
