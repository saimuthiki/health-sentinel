import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/config/app_config.dart';
import 'package:healthpulse/core/theme/hp_theme.dart';
import 'package:healthpulse/data/providers.dart';
import 'package:healthpulse/features/setup/not_configured_screen.dart';

/// The screen a build with no backend opens on.
///
/// It has one job that matters more than looking right: it must not put a key,
/// a fragment of a key, or an exception on screen. What it may show is what is
/// missing, by name, and the command that supplies it.
void main() {
  String anonKey() {
    String segment(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${segment(<String, dynamic>{'alg': 'HS256'})}'
        '.${segment(<String, dynamic>{'role': 'anon'})}'
        '.signature';
  }

  Widget wrap(AppConfig config) {
    return ProviderScope(
      overrides: <Override>[
        appConfigProvider.overrideWithValue(config),
      ],
      child: MaterialApp(
        theme: HpTheme.light(),
        home: const NotConfiguredScreen(),
      ),
    );
  }

  testWidgets('says what it is, calmly, with no spinner', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(const AppConfig()));
    await tester.pump();

    expect(find.text('Not connected yet'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Nothing is broken'), findsOneWidget);
  });

  testWidgets('names every missing define', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(const AppConfig()));
    await tester.pump();

    for (final String name in AppConfig.defineNames) {
      expect(find.text(name), findsOneWidget, reason: '$name is not named');
    }
  });

  testWidgets('names only the define that is actually missing',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        AppConfig(
          supabaseUrl: 'https://project.supabase.co',
          supabaseAnonKey: anonKey(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('API_BASE_URL'), findsOneWidget);
    expect(find.text('SUPABASE_URL'), findsNothing);
    expect(find.text('SUPABASE_ANON_KEY'), findsNothing);
  });

  testWidgets('never prints the key it was given', (WidgetTester tester) async {
    final String key = anonKey();
    await tester.pumpWidget(
      wrap(
        AppConfig(
          supabaseUrl: 'https://project.supabase.co',
          supabaseAnonKey: key,
        ),
      ),
    );
    await tester.pump();

    final Iterable<String> onScreen = tester
        .widgetList<Text>(find.byType(Text))
        .map((Text t) => t.data ?? '')
        .followedBy(
          tester
              .widgetList<SelectableText>(find.byType(SelectableText))
              .map((SelectableText t) => t.data ?? ''),
        );
    for (final String text in onScreen) {
      expect(text, isNot(contains(key)));
      // Not even the first few characters of it.
      expect(text, isNot(contains(key.substring(0, 12))));
      expect(text, isNot(contains('project.supabase.co')));
    }
  });

  testWidgets('offers the way out to sample data, and says it stays on the phone',
      (WidgetTester tester) async {
    // A phone-shaped surface, because that is what this screen is for.
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrap(const AppConfig()));
    await tester.pump();

    // The screen is a ListView, so it builds lazily and this button is not built
    // until it is scrolled near. Enlarging the surface is not a reliable fix --
    // a narrower surface wraps more text and pushes the button further down, so
    // any height picked here is a guess. Scrolling to it is height-independent.
    final Finder button = find.text('Look around with sample data');
    await tester.scrollUntilVisible(button, 300);
    await tester.pump();

    expect(button, findsOneWidget);
    expect(find.textContaining('leaves this phone'), findsOneWidget);
  });

  testWidgets('shows the build command that fixes it',
      (WidgetTester tester) async {
    await tester.pumpWidget(wrap(const AppConfig()));
    await tester.pump();

    // SelectableText renders through EditableText, so allow more than one
    // matching node rather than asserting on the widget tree's internals.
    expect(find.textContaining('--dart-define=SUPABASE_URL='), findsWidgets);
    expect(find.textContaining('flutter build apk'), findsWidgets);
  });
}
