import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/health_repository.dart';

/// The fake is what every screen is designed against, so its shape matters.
void main() {
  late FakeHealthRepository repo;

  setUp(() {
    repo = FakeHealthRepository(latency: Duration.zero);
  });

  test('starts signed out', () async {
    expect(await repo.restoreSession(), isNull);
  });

  test('refuses a password that is too short', () async {
    await expectLater(
      repo.signIn(email: 'sai@example.com', password: 'short'),
      throwsA(isA<HealthRepositoryException>()),
    );
  });

  test('refuses something that is not an email address', () async {
    await expectLater(
      repo.signIn(email: 'not-an-email', password: 'a-good-password'),
      throwsA(isA<HealthRepositoryException>()),
    );
  });

  test('signs in and remembers the session', () async {
    final AuthSession session = await repo.signIn(
      email: 'sai@example.com',
      password: 'a-good-password',
    );
    expect(session.email, 'sai@example.com');
    expect(await repo.restoreSession(), isNotNull);

    await repo.signOut();
    expect(await repo.restoreSession(), isNull);
  });

  test('has no profile until one is saved', () async {
    expect(await repo.loadHealthProfile(), isNull);
    const HealthProfile profile = HealthProfile(userId: 'demo-user');
    await repo.saveHealthProfile(profile);
    expect((await repo.loadHealthProfile())?.userId, 'demo-user');
  });

  test('today has meals, focus notes and an escalation', () async {
    final TodayBriefing today = await repo.loadToday(DateTime(2026, 9, 9));
    expect(today.meals, isNotEmpty);
    expect(today.focus, isNotEmpty);
    expect(today.hasEscalation, isTrue);
    expect(today.date, DateTime(2026, 9, 9));
  });

  test('hydration accumulates', () async {
    final double first = await repo.logHydration(250);
    final double second = await repo.logHydration(250);
    expect(second - first, 250);
  });

  test('every plan item explains itself', () async {
    final MealPlan plan = await repo.loadPlan(DateTime(2026, 9, 9));
    expect(plan.items, isNotEmpty);
    for (final MealPlanItem item in plan.items) {
      expect(item.whyText, isNotNull, reason: '${item.title} has no reason');
    }
  });

  test('a report keeps its unreadable value unreadable', () async {
    final HealthReport report = await repo.loadReport('r1');
    final LabResult ferritin = report.results
        .firstWhere((LabResult r) => r.biomarkerCode == 'ferritin');
    expect(ferritin.value, isNull);
    expect(ferritin.needsReview, isTrue);
  });

  test('sending a message gets a reply back', () async {
    final int before = (await repo.loadMessages()).length;
    await repo.sendMessage('I felt dizzy after lunch');
    final List<ChatMessage> after = await repo.loadMessages();
    expect(after.length, before + 2);
    expect(after.last.role, ChatRole.assistant);
  });
}

