import 'package:flutter/widgets.dart';

/// Spacing, radii, motion and hit targets.
///
/// The scale is a 4dp base with a deliberate jump between 24 and 32: inside a
/// card, space is tight and rhythmic; between sections of a screen it opens up,
/// so the eye can find the next thing without a divider doing the work.
class HpSpacing {
  const HpSpacing._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double section = 32;
  static const double screen = 44;

  /// Horizontal page gutter.
  static const double gutter = 20;

  /// Android's minimum comfortable touch target.
  static const double minTapTarget = 48;

  static const EdgeInsets pagePadding =
      EdgeInsets.symmetric(horizontal: gutter);
}

/// Four radii, not one. Chips are fully round, cards are soft, inputs are
/// squarer so they read as somewhere to type, and the escalation card keeps a
/// square leading edge so it does not look like the cards around it.
class HpRadii {
  const HpRadii._();

  static const double field = 10;
  static const double card = 18;
  static const double sheet = 26;
  static const double pill = 999;

  static const BorderRadius fieldRadius = BorderRadius.all(Radius.circular(field));
  static const BorderRadius cardRadius = BorderRadius.all(Radius.circular(card));
  static const BorderRadius sheetRadius =
      BorderRadius.vertical(top: Radius.circular(sheet));
  static const BorderRadius pillRadius = BorderRadius.all(Radius.circular(pill));
}

/// Separation comes from a hairline and from space. Shadow is spent once, on
/// the primary sheet, so that a raised thing genuinely reads as raised.
class HpElevation {
  const HpElevation._();

  static const List<BoxShadow> none = <BoxShadow>[];

  static const List<BoxShadow> resting = <BoxShadow>[
    BoxShadow(
      color: Color(0x0F0F241E),
      blurRadius: 14,
      offset: Offset(0, 6),
    ),
  ];

  static const List<BoxShadow> lifted = <BoxShadow>[
    BoxShadow(
      color: Color(0x1A0F241E),
      blurRadius: 28,
      offset: Offset(0, 12),
    ),
  ];
}

/// One orchestrated moment per screen, not motion everywhere.
class HpMotion {
  const HpMotion._();

  static const Duration quick = Duration(milliseconds: 140);
  static const Duration settle = Duration(milliseconds: 260);
  static const Duration arrive = Duration(milliseconds: 620);
  static const Curve ease = Curves.easeOutCubic;
}
