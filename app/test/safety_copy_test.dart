import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/widgets/hp_disclaimer.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';

/// The copy rule from `docs/01-product-and-safety.md`, enforced over every
/// string the interface is designed against.
///
/// This is a blunt instrument and it is not the real safety layer - that is the
/// server-side validator, which a modified app cannot bypass. It exists here so
/// that a placeholder string nobody thought hard about does not quietly teach
/// the interface to diagnose or to prescribe.
void main() {
  final List<RegExp> forbidden = <RegExp>[
    RegExp(r'\byou have (diabetes|anaemia|anemia|a deficiency)\b',
        caseSensitive: false),
    RegExp(r'\byou are diagnosed\b', caseSensitive: false),
    RegExp(r'\byou should take\b', caseSensitive: false),
    RegExp(r'\b(start|begin) taking\b', caseSensitive: false),
    RegExp(r'\bstop taking\b', caseSensitive: false),
    RegExp(r'\btake \d', caseSensitive: false),
    RegExp(
      r'\b\d+(\.\d+)?\s?(iu|mg|mcg|ug)\s+(daily|weekly|twice|once|per day)\b',
      caseSensitive: false,
    ),
  ];

  Future<List<String>> sampleCopy() async {
    final FakeHealthRepository repo =
        FakeHealthRepository(latency: Duration.zero);
    final List<String> strings = <String>[
      HpDisclaimer.fullText,
      HpDisclaimer.compactText,
    ];

    final TodayBriefing today = await repo.loadToday(DateTime(2026, 9, 9));
    strings.add(today.planRationale ?? '');
    for (final FocusNote note in today.focus) {
      strings.add(note.title);
      strings.add(note.body);
    }
    for (final EscalationNotice notice in today.escalations) {
      strings.add(notice.title);
      strings.add(notice.body);
      strings.addAll(notice.steps);
    }
    for (final HealthReport report in await repo.loadReports()) {
      strings.add(report.headline ?? '');
      for (final LabResult result in report.results) {
        strings.add(result.plainLanguage ?? '');
      }
    }
    for (final ChatMessage message in await repo.loadMessages()) {
      strings.add(message.content);
    }
    final MealPlan plan = await repo.loadPlan(DateTime(2026, 9, 9));
    for (final MealPlanItem item in plan.items) {
      strings.add(item.whyText ?? '');
    }
    return strings;
  }

  test('no sample copy diagnoses or prescribes', () async {
    final List<String> strings = await sampleCopy();
    expect(strings.length, greaterThan(20));
    for (final String text in strings) {
      for (final RegExp pattern in forbidden) {
        expect(
          pattern.hasMatch(text),
          isFalse,
          reason: 'Copy matched ${pattern.pattern}: "$text"',
        );
      }
    }
  });

  test('every status word describes a range, not a condition', () {
    for (final LabStatus status in LabStatus.values) {
      expect(status.label.toLowerCase(), isNot(contains('deficien')));
      expect(status.label.toLowerCase(), isNot(contains('abnormal')));
      expect(status.label.toLowerCase(), isNot(contains('disease')));
    }
  });

  test('the disclaimer says what the app is not', () {
    expect(HpDisclaimer.fullText, contains('not a doctor'));
    expect(HpDisclaimer.fullText, contains('does not diagnose'));
    expect(HpDisclaimer.fullText, contains('never recommends a medicine'));
    expect(HpDisclaimer.compactText, contains('not a doctor'));
  });
}
