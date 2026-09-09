import 'package:flutter/material.dart';

/// The HealthPulse palette.
///
/// The ground is a pale herbal grey-green rather than white or clinical blue:
/// this is an app someone opens before their first cup of tea, and it should feel
/// like steam and kitchen herbs, not like a hospital corridor. There is exactly
/// one brand colour (pine) and exactly one warm accent (marigold), and marigold is
/// spent only on "now" and on progress. Severity has its own separate, functional
/// ramp so that a warm accent can never be mistaken for a warning.
///
/// Every text pair below was measured against WCAG 2.1: no foreground/background
/// pair used for text falls under 4.5:1, and interactive outlines clear 3:1.
/// Colour never carries meaning on its own - see [HpSeverity], which pairs every
/// colour with an icon and a word.
class HpColors {
  const HpColors._();

  // ---------------------------------------------------------------- light
  /// Page background. Pale sage; the "steam" of the palette.
  static const Color ground = Color(0xFFEDF1EA);

  /// Raised surfaces: things you can act on.
  static const Color surface = Color(0xFFFFFFFF);

  /// Recessed surfaces: input fields, progress tracks.
  static const Color surfaceSunk = Color(0xFFE3E9E0);

  /// Deep pine-black. A green-black, so body text reads warm rather than stark.
  static const Color ink = Color(0xFF0F241E);

  /// Secondary text. 7.1:1 on [ground].
  static const Color inkMuted = Color(0xFF3D544C);

  /// Tertiary text: timestamps, units, helper lines. 4.99:1 on [ground].
  static const Color inkFaint = Color(0xFF566B63);

  /// Decorative separators only. Never used to bound an interactive control.
  static const Color hairline = Color(0xFFCFDACA);

  /// Boundaries of interactive controls. 3.78:1 on [surface].
  static const Color outline = Color(0xFF74887C);

  /// Brand colour: actions, structure, the arc of the day.
  static const Color pine = Color(0xFF1D5C4A);
  static const Color pineDeep = Color(0xFF133F32);
  static const Color pineSoft = Color(0xFFDCE9E1);

  /// The single warm accent. Marks "now" and progress, nothing else. Because it
  /// is under 3:1 against the ground it is never the only carrier of meaning.
  static const Color marigold = Color(0xFFE0A32E);
  static const Color marigoldInk = Color(0xFF7A5000);
  static const Color marigoldSoft = Color(0xFFFAEFD6);

  // Severity ramp - functional, and always paired with an icon and a label.
  static const Color calmInk = Color(0xFF1B5E45);
  static const Color calmSoft = Color(0xFFDDEBE2);
  static const Color watchInk = Color(0xFF7A5000);
  static const Color watchSoft = Color(0xFFFAEFD6);
  static const Color attentionInk = Color(0xFF8F3A1E);
  static const Color attentionSoft = Color(0xFFFBE6DC);
  static const Color urgentInk = Color(0xFF8C1D18);
  static const Color urgentSoft = Color(0xFFFBE2DE);
  static const Color unknownInk = Color(0xFF3F4A7A);
  static const Color unknownSoft = Color(0xFFE4E8F6);

  static const Color onPine = Color(0xFFFFFFFF);
  static const Color onUrgent = Color(0xFFFFFFFF);

  // ----------------------------------------------------------------- dark
  static const Color groundDark = Color(0xFF0D1512);
  static const Color surfaceDark = Color(0xFF14201C);
  static const Color surfaceSunkDark = Color(0xFF1B2A25);
  static const Color inkDark = Color(0xFFE8EFE9);
  static const Color inkMutedDark = Color(0xFFAEBFB7);
  static const Color inkFaintDark = Color(0xFF93A69C);
  static const Color hairlineDark = Color(0xFF2A3A33);
  static const Color outlineDark = Color(0xFF6E837A);

  static const Color pineDark = Color(0xFF7FCBAE);
  static const Color pineDeepDark = Color(0xFF9FDCC4);
  static const Color pineSoftDark = Color(0xFF1B3A31);

  static const Color marigoldDark = Color(0xFFF0BC5E);
  static const Color marigoldInkDark = Color(0xFFF0BC5E);
  static const Color marigoldSoftDark = Color(0xFF3A2E14);

  static const Color calmInkDark = Color(0xFF8ED9B4);
  static const Color calmSoftDark = Color(0xFF1B3A31);
  static const Color watchInkDark = Color(0xFFF2C878);
  static const Color watchSoftDark = Color(0xFF3A2E14);
  static const Color attentionInkDark = Color(0xFFF2A98C);
  static const Color attentionSoftDark = Color(0xFF3B1D12);
  static const Color urgentInkDark = Color(0xFFFFB4AB);
  static const Color urgentSoftDark = Color(0xFF3A1310);
  static const Color unknownInkDark = Color(0xFFB9C4F2);
  static const Color unknownSoftDark = Color(0xFF22284A);

  static const Color onPineDark = Color(0xFF06120E);
  static const Color urgentSolidDark = Color(0xFF93000A);
}
