import 'package:flutter/material.dart';

import 'hp_palette.dart';

/// How serious a finding is, in the app's own vocabulary.
///
/// These are presentation levels, not clinical categories, and none of them is a
/// diagnosis. They exist so that the interface can be consistent about weight and
/// tone: a borderline vitamin D and an out-of-range HbA1c should not look the
/// same, and neither should look like an emergency.
enum HpSeverity {
  /// Inside the reference range for this person's age and sex.
  calm,

  /// Close to the edge of the range. Worth watching, not worth worrying about.
  watch,

  /// Outside the reference range. Worth raising with a doctor.
  attention,

  /// A red-flag value or symptom. The interface must dominate and must not be
  /// dismissible.
  urgent,

  /// We could not map the value or the unit with confidence, so we are asking
  /// rather than guessing. Never guess a health number.
  unknown,
}

/// The visual and verbal treatment for a severity level.
///
/// Every level carries a distinct icon *shape* and a word, so meaning survives
/// greyscale, colour blindness and a screen in bright sunlight.
@immutable
class HpSeverityStyle {
  const HpSeverityStyle({
    required this.severity,
    required this.foreground,
    required this.background,
    required this.icon,
    required this.label,
  });

  final HpSeverity severity;
  final Color foreground;
  final Color background;
  final IconData icon;

  /// The default word for this level. Screens may pass a more specific one.
  final String label;

  static HpSeverityStyle of(BuildContext context, HpSeverity severity) {
    final HpPalette p = context.hp;
    switch (severity) {
      case HpSeverity.calm:
        return HpSeverityStyle(
          severity: severity,
          foreground: p.calmInk,
          background: p.calmSoft,
          icon: Icons.check_circle_outline_rounded,
          label: 'In range',
        );
      case HpSeverity.watch:
        return HpSeverityStyle(
          severity: severity,
          foreground: p.watchInk,
          background: p.watchSoft,
          icon: Icons.info_outline_rounded,
          label: 'Near the edge',
        );
      case HpSeverity.attention:
        return HpSeverityStyle(
          severity: severity,
          foreground: p.attentionInk,
          background: p.attentionSoft,
          icon: Icons.warning_amber_rounded,
          label: 'Outside the usual range',
        );
      case HpSeverity.urgent:
        return HpSeverityStyle(
          severity: severity,
          foreground: p.urgentInk,
          background: p.urgentSoft,
          icon: Icons.priority_high_rounded,
          label: 'See a doctor soon',
        );
      case HpSeverity.unknown:
        return HpSeverityStyle(
          severity: severity,
          foreground: p.unknownInk,
          background: p.unknownSoft,
          icon: Icons.help_outline_rounded,
          label: 'Needs your check',
        );
    }
  }
}
