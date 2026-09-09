import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';

/// Wraps a widget in the app's real theme so tests exercise the same tokens the
/// app ships with, rather than Material's defaults.
Widget wrapForTest(
  Widget child, {
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return ProviderScope(
    overrides: <Override>[
      // Zero latency: nothing in a test should have to wait for a fake.
      healthRepositoryProvider.overrideWithValue(
        FakeHealthRepository(latency: Duration.zero, signedIn: true),
      ),
    ],
    child: MaterialApp(
      theme: brightness == Brightness.dark ? HpTheme.dark() : HpTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      ),
    ),
  );
}

/// Contrast ratio as WCAG 2.1 defines it.
double contrastRatio(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double lighter = la > lb ? la : lb;
  final double darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

/// Convenience for the many tests that only need one pump.
Future<void> pumpOnce(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pump();
}
