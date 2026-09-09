import 'package:flutter/widgets.dart';

/// Two families, each with a job.
///
/// **Literata** carries numbers and the one headline on each screen. It is a
/// low-contrast, bookish serif with sturdy lining figures, so a haemoglobin value
/// reads like a line in a well-set book rather than a printout from a machine.
/// Using a serif for the figures is the single decision that stops this looking
/// like every other Material health app.
///
/// **Hanken Grotesk** carries every label, button and paragraph of interface
/// copy. Open apertures and a tall x-height keep 13px labels readable for the
/// person in their sixties reading their own report, which is a real part of this
/// audience.
///
/// Sizes are a ~1.22 modular scale off a 15px body, rounded to whole pixels.
/// Nothing here is set in capitals: tracked-out capital labels are the default
/// dressing of a template, and they read as shouting on a health screen.
class HpType {
  const HpType._();

  static const String serif = 'Literata';
  static const String sans = 'HankenGrotesk';

  static const List<FontFeature> _tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// The greeting on Today. One per screen, at most.
  static const TextStyle display = TextStyle(
    fontFamily: serif,
    fontSize: 33,
    height: 1.18,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.7,
  );

  /// Screen titles.
  static const TextStyle title = TextStyle(
    fontFamily: serif,
    fontSize: 26,
    height: 1.22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
  );

  /// Section headings and card titles.
  static const TextStyle headline = TextStyle(
    fontFamily: serif,
    fontSize: 20,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  /// A measured lab value, a hydration total, a weight. Tabular so a column of
  /// numbers lines up.
  static const TextStyle figure = TextStyle(
    fontFamily: serif,
    fontSize: 36,
    height: 1.05,
    fontWeight: FontWeight.w500,
    letterSpacing: -1.2,
    fontFeatures: _tabular,
  );

  /// A smaller figure, for inline values inside a row.
  static const TextStyle figureSmall = TextStyle(
    fontFamily: serif,
    fontSize: 19,
    height: 1.15,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.4,
    fontFeatures: _tabular,
  );

  /// Long-form explanation - "what this value means". Serif, generous leading.
  static const TextStyle reading = TextStyle(
    fontFamily: serif,
    fontSize: 16,
    height: 1.62,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle body = TextStyle(
    fontFamily: sans,
    fontSize: 15,
    height: 1.47,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.05,
  );

  static const TextStyle bodyStrong = TextStyle(
    fontFamily: sans,
    fontSize: 15,
    height: 1.47,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.05,
  );

  static const TextStyle label = TextStyle(
    fontFamily: sans,
    fontSize: 13,
    height: 1.38,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
  );

  static const TextStyle micro = TextStyle(
    fontFamily: sans,
    fontSize: 12,
    height: 1.33,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.15,
  );

  static const TextStyle button = TextStyle(
    fontFamily: sans,
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.15,
  );
}
