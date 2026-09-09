import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_palette.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';

import '../_harness.dart';

/// Accessibility is a build-time property here, not a hope.
///
/// If somebody adjusts a token and drops a text pair under 4.5:1, this fails
/// before it ships rather than after somebody cannot read their own results.
void main() {
  const double aa = 4.5;
  const double aaLarge = 3.0;

  for (final HpPalette p in <HpPalette>[HpPalette.light, HpPalette.dark]) {
    final String mode = p.isDark ? 'dark' : 'light';

    group('$mode palette contrast', () {
      test('body text on every surface clears 4.5:1', () {
        expect(contrastRatio(p.ink, p.ground), greaterThanOrEqualTo(aa));
        expect(contrastRatio(p.ink, p.surface), greaterThanOrEqualTo(aa));
        expect(contrastRatio(p.ink, p.surfaceSunk), greaterThanOrEqualTo(aa));
      });

      test('secondary and tertiary text clear 4.5:1', () {
        expect(contrastRatio(p.inkMuted, p.ground), greaterThanOrEqualTo(aa));
        expect(contrastRatio(p.inkMuted, p.surface), greaterThanOrEqualTo(aa));
        expect(contrastRatio(p.inkFaint, p.ground), greaterThanOrEqualTo(aa));
        expect(contrastRatio(p.inkFaint, p.surface), greaterThanOrEqualTo(aa));
      });

      test('button and link text clears 4.5:1', () {
        expect(contrastRatio(p.pine, p.ground), greaterThanOrEqualTo(aa));
        expect(contrastRatio(p.pine, p.surface), greaterThanOrEqualTo(aa));
        expect(contrastRatio(p.onPine, p.pine), greaterThanOrEqualTo(aa));
      });

      test('every severity word is readable on its own chip', () {
        expect(contrastRatio(p.calmInk, p.calmSoft), greaterThanOrEqualTo(aa));
        expect(contrastRatio(p.watchInk, p.watchSoft), greaterThanOrEqualTo(aa));
        expect(
          contrastRatio(p.attentionInk, p.attentionSoft),
          greaterThanOrEqualTo(aa),
        );
        expect(
          contrastRatio(p.urgentInk, p.urgentSoft),
          greaterThanOrEqualTo(aa),
        );
        expect(
          contrastRatio(p.unknownInk, p.unknownSoft),
          greaterThanOrEqualTo(aa),
        );
        expect(
          contrastRatio(p.onUrgent, p.urgentSolid),
          greaterThanOrEqualTo(aa),
        );
      });

      test('interactive outlines clear the 3:1 non-text minimum', () {
        expect(
          contrastRatio(p.outline, p.surface),
          greaterThanOrEqualTo(aaLarge),
        );
        expect(
          contrastRatio(p.outline, p.ground),
          greaterThanOrEqualTo(aaLarge),
        );
      });

      test('marigold accent is never asked to carry text', () {
        // It sits under 3:1 against the ground by design, which is exactly why
        // "now" is also spelled out in words next to it.
        expect(contrastRatio(p.marigoldInk, p.marigoldSoft),
            greaterThanOrEqualTo(aa));
      });
    });
  }

  group('ThemeData', () {
    test('carries the palette as an extension in both modes', () {
      expect(HpTheme.light().extension<HpPalette>(), isNotNull);
      expect(HpTheme.dark().extension<HpPalette>(), isNotNull);
      expect(HpTheme.dark().extension<HpPalette>()!.isDark, isTrue);
    });

    test('does not fall back to the Material default font', () {
      expect(HpTheme.light().textTheme.bodyMedium?.fontFamily, 'HankenGrotesk');
      expect(HpTheme.light().textTheme.headlineMedium?.fontFamily, 'Literata');
    });

    test('uses the app ground rather than Material white', () {
      expect(HpTheme.light().scaffoldBackgroundColor, HpPalette.light.ground);
      expect(HpTheme.dark().scaffoldBackgroundColor, HpPalette.dark.ground);
    });
  });

  group('HpPalette', () {
    test('resolves from a context, and falls back to light', () {
      expect(HpPalette.light.brightness, Brightness.light);
      expect(HpPalette.dark.brightness, Brightness.dark);
    });
  });
}
