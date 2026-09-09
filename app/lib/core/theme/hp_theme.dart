import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'hp_colors.dart';
import 'hp_palette.dart';
import 'hp_spacing.dart';
import 'hp_typography.dart';

/// Material 3 wired to the HealthPulse tokens.
///
/// Material is the substrate, not the look: the seeded purple, the default
/// Roboto stack, the pill-shaped filled buttons and the tonal app bar are all
/// replaced here, because a health coach that looks like a framework demo is a
/// health coach nobody trusts with their reports.
class HpTheme {
  const HpTheme._();

  static ThemeData light() => _build(HpPalette.light);

  static ThemeData dark() => _build(HpPalette.dark);

  static ThemeData _build(HpPalette p) {
    final ColorScheme scheme = ColorScheme(
      brightness: p.brightness,
      primary: p.pine,
      onPrimary: p.onPine,
      primaryContainer: p.pineSoft,
      onPrimaryContainer: p.isDark ? p.ink : HpColors.pineDeep,
      secondary: p.marigoldInk,
      onSecondary: p.isDark ? HpColors.groundDark : HpColors.surface,
      secondaryContainer: p.marigoldSoft,
      onSecondaryContainer: p.marigoldInk,
      tertiary: p.pineDeep,
      onTertiary: p.isDark ? HpColors.groundDark : HpColors.surface,
      tertiaryContainer: p.pineSoft,
      onTertiaryContainer: p.isDark ? p.ink : HpColors.pineDeep,
      error: p.urgentInk,
      onError: p.onUrgent,
      errorContainer: p.urgentSoft,
      onErrorContainer: p.urgentInk,
      surface: p.surface,
      onSurface: p.ink,
      surfaceContainerLowest: p.surface,
      surfaceContainerLow: p.ground,
      surfaceContainer: p.ground,
      surfaceContainerHigh: p.surfaceSunk,
      surfaceContainerHighest: p.surfaceSunk,
      onSurfaceVariant: p.inkMuted,
      outline: p.outline,
      outlineVariant: p.hairline,
      shadow: const Color(0xFF000000),
      scrim: const Color(0xFF000000),
      inverseSurface: p.ink,
      onInverseSurface: p.ground,
      inversePrimary: p.pineSoft,
    );

    final TextTheme text = TextTheme(
      displayLarge: HpType.display.copyWith(color: p.ink),
      displayMedium: HpType.title.copyWith(color: p.ink),
      displaySmall: HpType.headline.copyWith(color: p.ink),
      headlineLarge: HpType.title.copyWith(color: p.ink),
      headlineMedium: HpType.headline.copyWith(color: p.ink),
      headlineSmall: HpType.headline.copyWith(color: p.ink, fontSize: 18),
      titleLarge: HpType.headline.copyWith(color: p.ink),
      titleMedium: HpType.bodyStrong.copyWith(color: p.ink),
      titleSmall: HpType.label.copyWith(color: p.inkMuted),
      bodyLarge: HpType.reading.copyWith(color: p.ink),
      bodyMedium: HpType.body.copyWith(color: p.ink),
      bodySmall: HpType.label.copyWith(color: p.inkMuted),
      labelLarge: HpType.button.copyWith(color: p.ink),
      labelMedium: HpType.label.copyWith(color: p.inkMuted),
      labelSmall: HpType.micro.copyWith(color: p.inkFaint),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.ground,
      canvasColor: p.ground,
      splashFactory: InkSparkle.splashFactory,
      textTheme: text,
      // ThemeData's `fontFamily` argument would be applied over the whole text
      // theme and would flatten the serif back to the sans, so every style
      // names its own family instead.
      extensions: <ThemeExtension<dynamic>>[p],
      appBarTheme: AppBarTheme(
        backgroundColor: p.ground,
        foregroundColor: p.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: HpType.headline.copyWith(color: p.ink),
        systemOverlayStyle: p.isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      dividerTheme: DividerThemeData(
        color: p.hairline,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: p.inkMuted, size: 22),
      // Material's Card is deliberately not themed here: HpCard owns every raised
      // surface in this app, so there is one place where a card's weight is decided.
      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceSunk,
        selectedColor: p.pineSoft,
        side: BorderSide(color: p.hairline),
        labelStyle: HpType.label.copyWith(color: p.ink),
        shape: const RoundedRectangleBorder(borderRadius: HpRadii.pillRadius),
        padding: const EdgeInsets.symmetric(
          horizontal: HpSpacing.md,
          vertical: HpSpacing.sm,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.isDark ? p.surfaceSunk : p.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: HpSpacing.lg,
          vertical: HpSpacing.lg,
        ),
        hintStyle: HpType.body.copyWith(color: p.inkFaint),
        labelStyle: HpType.label.copyWith(color: p.inkMuted),
        helperStyle: HpType.micro.copyWith(color: p.inkFaint),
        errorStyle: HpType.micro.copyWith(color: p.urgentInk),
        border: OutlineInputBorder(
          borderRadius: HpRadii.fieldRadius,
          borderSide: BorderSide(color: p.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: HpRadii.fieldRadius,
          borderSide: BorderSide(color: p.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: HpRadii.fieldRadius,
          borderSide: BorderSide(color: p.pine, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: HpRadii.fieldRadius,
          borderSide: BorderSide(color: p.urgentInk),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: HpRadii.fieldRadius,
          borderSide: BorderSide(color: p.urgentInk, width: 2),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.ink,
        contentTextStyle: HpType.body.copyWith(color: p.ground),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: HpRadii.fieldRadius),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: HpRadii.sheetRadius),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: p.pineSoft,
        elevation: 0,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? HpType.micro.copyWith(color: p.ink, fontWeight: FontWeight.w600)
              : HpType.micro.copyWith(color: p.inkFaint),
        ),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
          (Set<WidgetState> states) => IconThemeData(
            size: 23,
            color: states.contains(WidgetState.selected) ? p.pine : p.inkFaint,
          ),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.pine,
        linearTrackColor: p.surfaceSunk,
        circularTrackColor: p.surfaceSunk,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.pine,
        inactiveTrackColor: p.surfaceSunk,
        thumbColor: p.pine,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? p.onPine
              : p.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? p.pine
              : p.surfaceSunk,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.inkMuted,
        textColor: p.ink,
        titleTextStyle: HpType.bodyStrong.copyWith(color: p.ink),
        subtitleTextStyle: HpType.label.copyWith(color: p.inkFaint),
        minVerticalPadding: HpSpacing.md,
        shape: const RoundedRectangleBorder(borderRadius: HpRadii.fieldRadius),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: p.ink,
          borderRadius: HpRadii.fieldRadius,
        ),
        textStyle: HpType.micro.copyWith(color: p.ground),
      ),
    );
  }
}
