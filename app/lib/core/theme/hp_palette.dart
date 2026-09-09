import 'package:flutter/material.dart';

import 'hp_colors.dart';

/// The resolved palette for the current brightness, hung off [ThemeData] so that
/// widgets never have to ask which mode they are in.
@immutable
class HpPalette extends ThemeExtension<HpPalette> {
  const HpPalette({
    required this.brightness,
    required this.ground,
    required this.surface,
    required this.surfaceSunk,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.hairline,
    required this.outline,
    required this.pine,
    required this.pineDeep,
    required this.pineSoft,
    required this.onPine,
    required this.marigold,
    required this.marigoldInk,
    required this.marigoldSoft,
    required this.calmInk,
    required this.calmSoft,
    required this.watchInk,
    required this.watchSoft,
    required this.attentionInk,
    required this.attentionSoft,
    required this.urgentInk,
    required this.urgentSoft,
    required this.urgentSolid,
    required this.onUrgent,
    required this.unknownInk,
    required this.unknownSoft,
  });

  final Brightness brightness;
  final Color ground;
  final Color surface;
  final Color surfaceSunk;
  final Color ink;
  final Color inkMuted;
  final Color inkFaint;
  final Color hairline;
  final Color outline;
  final Color pine;
  final Color pineDeep;
  final Color pineSoft;
  final Color onPine;
  final Color marigold;
  final Color marigoldInk;
  final Color marigoldSoft;
  final Color calmInk;
  final Color calmSoft;
  final Color watchInk;
  final Color watchSoft;
  final Color attentionInk;
  final Color attentionSoft;
  final Color urgentInk;
  final Color urgentSoft;
  final Color urgentSolid;
  final Color onUrgent;
  final Color unknownInk;
  final Color unknownSoft;

  bool get isDark => brightness == Brightness.dark;

  static const HpPalette light = HpPalette(
    brightness: Brightness.light,
    ground: HpColors.ground,
    surface: HpColors.surface,
    surfaceSunk: HpColors.surfaceSunk,
    ink: HpColors.ink,
    inkMuted: HpColors.inkMuted,
    inkFaint: HpColors.inkFaint,
    hairline: HpColors.hairline,
    outline: HpColors.outline,
    pine: HpColors.pine,
    pineDeep: HpColors.pineDeep,
    pineSoft: HpColors.pineSoft,
    onPine: HpColors.onPine,
    marigold: HpColors.marigold,
    marigoldInk: HpColors.marigoldInk,
    marigoldSoft: HpColors.marigoldSoft,
    calmInk: HpColors.calmInk,
    calmSoft: HpColors.calmSoft,
    watchInk: HpColors.watchInk,
    watchSoft: HpColors.watchSoft,
    attentionInk: HpColors.attentionInk,
    attentionSoft: HpColors.attentionSoft,
    urgentInk: HpColors.urgentInk,
    urgentSoft: HpColors.urgentSoft,
    urgentSolid: HpColors.urgentInk,
    onUrgent: HpColors.onUrgent,
    unknownInk: HpColors.unknownInk,
    unknownSoft: HpColors.unknownSoft,
  );

  static const HpPalette dark = HpPalette(
    brightness: Brightness.dark,
    ground: HpColors.groundDark,
    surface: HpColors.surfaceDark,
    surfaceSunk: HpColors.surfaceSunkDark,
    ink: HpColors.inkDark,
    inkMuted: HpColors.inkMutedDark,
    inkFaint: HpColors.inkFaintDark,
    hairline: HpColors.hairlineDark,
    outline: HpColors.outlineDark,
    pine: HpColors.pineDark,
    pineDeep: HpColors.pineDeepDark,
    pineSoft: HpColors.pineSoftDark,
    onPine: HpColors.onPineDark,
    marigold: HpColors.marigoldDark,
    marigoldInk: HpColors.marigoldInkDark,
    marigoldSoft: HpColors.marigoldSoftDark,
    calmInk: HpColors.calmInkDark,
    calmSoft: HpColors.calmSoftDark,
    watchInk: HpColors.watchInkDark,
    watchSoft: HpColors.watchSoftDark,
    attentionInk: HpColors.attentionInkDark,
    attentionSoft: HpColors.attentionSoftDark,
    urgentInk: HpColors.urgentInkDark,
    urgentSoft: HpColors.urgentSoftDark,
    urgentSolid: HpColors.urgentSolidDark,
    onUrgent: HpColors.onUrgent,
    unknownInk: HpColors.unknownInkDark,
    unknownSoft: HpColors.unknownSoftDark,
  );

  @override
  HpPalette copyWith() => this;

  /// The palette is a pair of fixed sets rather than a continuum; cross-fading
  /// twenty-eight tokens would only muddy the mid-point of a theme switch.
  @override
  HpPalette lerp(ThemeExtension<HpPalette>? other, double t) {
    if (other is! HpPalette) {
      return this;
    }
    return t < 0.5 ? this : other;
  }
}

extension HpPaletteContext on BuildContext {
  /// The HealthPulse palette for this subtree. Falls back to the light palette so
  /// that a widget dropped into a bare `MaterialApp` in a test still renders.
  HpPalette get hp => Theme.of(this).extension<HpPalette>() ?? HpPalette.light;
}
