import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/theme/hp_severity.dart';
import 'package:healthpulse/core/widgets/widgets.dart';

import '../_harness.dart';

void main() {
  group('HpButton', () {
    testWidgets('clears the 48dp minimum touch target', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          HpButton(label: 'Save profile', onPressed: () {}),
        ),
      );

      final Size size = tester.getSize(find.byType(HpButton));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(find.text('Save profile'), findsOneWidget);
    });

    testWidgets('calls back when tapped', (WidgetTester tester) async {
      int taps = 0;
      await pumpOnce(
        tester,
        wrapForTest(
          HpButton(label: 'Add a glass', onPressed: () => taps += 1),
        ),
      );

      await tester.tap(find.byType(HpButton));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('does not fire while busy', (WidgetTester tester) async {
      int taps = 0;
      await pumpOnce(
        tester,
        wrapForTest(
          HpButton(label: 'Sign in', busy: true, onPressed: () => taps += 1),
        ),
      );

      await tester.tap(find.byType(HpButton));
      await tester.pump();
      expect(taps, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('a null callback disables it', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(const HpButton(label: 'Continue')),
      );
      expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
    });
  });

  group('HpTextAction', () {
    testWidgets('is still a 48dp target', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          Align(
            alignment: Alignment.centerLeft,
            child: HpTextAction(label: 'See the value', onPressed: () {}),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(HpTextAction)).height,
        greaterThanOrEqualTo(48),
      );
    });
  });

  group('HpStatusChip', () {
    testWidgets('never carries meaning in colour alone', (WidgetTester tester) async {
      for (final HpSeverity severity in HpSeverity.values) {
        await pumpOnce(tester, wrapForTest(HpStatusChip(severity: severity)));

        // An icon and a word, every time.
        expect(find.byType(Icon), findsOneWidget);
        expect(find.byType(Text), findsOneWidget);
      }
    });

    testWidgets('each severity has its own icon shape', (WidgetTester tester) async {
      final Set<IconData> icons = <IconData>{};
      for (final HpSeverity severity in HpSeverity.values) {
        await pumpOnce(tester, wrapForTest(HpStatusChip(severity: severity)));
        icons.add(tester.widget<Icon>(find.byType(Icon)).icon!);
      }
      expect(icons.length, HpSeverity.values.length);
    });

    testWidgets('uses the supplied label', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          const HpStatusChip(
            severity: HpSeverity.attention,
            label: 'Below the usual range',
          ),
        ),
      );
      expect(find.text('Below the usual range'), findsOneWidget);
    });
  });

  group('HpDisclaimer', () {
    testWidgets('states plainly that this is not a doctor', (WidgetTester tester) async {
      await pumpOnce(tester, wrapForTest(const HpDisclaimer()));
      expect(find.textContaining('not a doctor'), findsOneWidget);
      expect(find.textContaining('never recommends a medicine'), findsOneWidget);
    });

    testWidgets('offers no way to dismiss it', (WidgetTester tester) async {
      await pumpOnce(tester, wrapForTest(const HpDisclaimer()));
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(Dismissible), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('the compact form is still non-dismissible', (WidgetTester tester) async {
      await pumpOnce(tester, wrapForTest(const HpDisclaimer.compact()));
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(Dismissible), findsNothing);
    });
  });

  group('HpEscalationCard', () {
    const HpEscalationCard card = HpEscalationCard(
      title: 'Your potassium is well below the usual range',
      body: 'The reading is 2.9 mmol/L, where 3.5 to 5.1 is usual. Please '
          'contact a doctor today.',
      steps: <String>[
        'Call your doctor today and read them this value.',
        'Ask whether they want to repeat the test.',
      ],
      footnote: 'Threshold from our reference range table.',
    );

    testWidgets('cannot be swiped or closed away', (WidgetTester tester) async {
      await pumpOnce(tester, wrapForTest(card));

      expect(find.byType(Dismissible), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(CloseButton), findsNothing);
    });

    testWidgets('shows the finding, the steps and the source', (WidgetTester tester) async {
      await pumpOnce(tester, wrapForTest(card));

      expect(find.text('Needs attention'), findsOneWidget);
      expect(
        find.text('Your potassium is well below the usual range'),
        findsOneWidget,
      );
      expect(
        find.text('Call your doctor today and read them this value.'),
        findsOneWidget,
      );
      expect(
        find.text('Threshold from our reference range table.'),
        findsOneWidget,
      );
    });

    testWidgets('announces itself to a screen reader', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await pumpOnce(tester, wrapForTest(card));

      expect(
        find.bySemanticsLabel(
          RegExp('Needs attention\\. Your potassium is well below'),
        ),
        findsAtLeastNWidgets(1),
      );
      handle.dispose();
    });

    testWidgets('the care action is optional and opt-in', (WidgetTester tester) async {
      int taps = 0;
      await pumpOnce(
        tester,
        wrapForTest(
          HpEscalationCard(
            title: 'A value needs attention',
            body: 'Please speak to a doctor today.',
            onFindCare: () => taps += 1,
          ),
        ),
      );
      await tester.tap(find.text('How to get care today'));
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('HpEmptyState', () {
    testWidgets('invites an action rather than apologising', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          HpEmptyState(
            icon: Icons.science_outlined,
            title: 'No reports yet',
            body: 'Upload a lab report and HealthPulse will read the values.',
            actionLabel: 'Upload a report',
            onAction: () {},
          ),
        ),
      );
      expect(find.text('No reports yet'), findsOneWidget);
      expect(find.text('Upload a report'), findsOneWidget);
    });
  });

  group('HpMeter', () {
    testWidgets('spells the number out beside the bar', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          const HpMeter(
            label: 'Water so far',
            value: 900,
            target: 2600,
            unit: 'ml',
          ),
        ),
      );
      expect(find.text('900 of 2600 ml'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('a zero target does not divide by zero', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          const HpMeter(label: 'Iron', value: 5, target: 0, unit: 'mg'),
        ),
      );
      final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0);
    });
  });

  group('HpSectionHeader', () {
    testWidgets('carries its note on the rule', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          const HpSectionHeader(title: 'Values', note: '4 measured'),
        ),
      );
      expect(find.text('Values'), findsOneWidget);
      expect(find.text('4 measured'), findsOneWidget);
    });
  });

  group('HpChoiceGroup', () {
    testWidgets('marks the selection with a tick, not only a colour', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          HpChoiceGroup<String>(
            choices: const <HpChoice<String>>[
              HpChoice<String>(value: 'veg', label: 'Vegetarian'),
              HpChoice<String>(value: 'vegan', label: 'Vegan'),
            ],
            selected: 'veg',
            onChanged: (String _) {},
          ),
        ),
      );
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('reports the value that was tapped', (WidgetTester tester) async {
      String? picked;
      await pumpOnce(
        tester,
        wrapForTest(
          HpChoiceGroup<String>(
            choices: const <HpChoice<String>>[
              HpChoice<String>(value: 'veg', label: 'Vegetarian'),
              HpChoice<String>(value: 'vegan', label: 'Vegan'),
            ],
            selected: 'veg',
            onChanged: (String value) => picked = value,
          ),
        ),
      );
      await tester.tap(find.text('Vegan'));
      await tester.pump();
      expect(picked, 'vegan');
    });
  });

  group('HpDayTimeline', () {
    testWidgets('labels the current moment in words', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          const HpDayTimeline(
            entries: <HpTimelineEntry>[
              HpTimelineEntry(
                time: '6:15 am',
                title: 'Wake up',
                icon: Icons.wb_sunny_outlined,
                state: HpTimelineState.done,
              ),
              HpTimelineEntry(
                time: '8:30 am',
                title: 'Ragi dosa',
                icon: Icons.restaurant_outlined,
                state: HpTimelineState.now,
              ),
              HpTimelineEntry(
                time: '1:30 pm',
                title: 'Rajma and rice',
                icon: Icons.restaurant_outlined,
              ),
            ],
          ),
        ),
      );

      expect(find.text('Now'), findsOneWidget);
      expect(find.text('Ragi dosa'), findsOneWidget);
      expect(find.text('6:15 am'), findsOneWidget);
    });
  });

  group('text scaling', () {
    testWidgets('the escalation card survives 2x text', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          const HpEscalationCard(
            title: 'Your potassium is well below the usual range',
            body: 'Please contact a doctor today rather than waiting.',
            steps: <String>['Call your doctor today.'],
          ),
          textScaler: const TextScaler.linear(2),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a button survives 2x text', (WidgetTester tester) async {
      await pumpOnce(
        tester,
        wrapForTest(
          HpButton(label: 'Type what your report says', onPressed: () {}),
          textScaler: const TextScaler.linear(2),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
