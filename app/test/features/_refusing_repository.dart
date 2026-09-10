import 'dart:async';

import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';

/// The fake repository, with one or two calls made to refuse.
///
/// It throws the same [ApiRepositoryException] the real HTTP repository throws,
/// so the screens under test see exactly what a refused backend call looks like
/// in production - our own sentence, and an [ApiFailure] the caller can branch
/// on - rather than a bare `Exception`.
class RefusingRepository extends FakeHealthRepository {
  RefusingRepository({
    this.failure = const ApiFailure(ApiFailureKind.wakingUpTimedOut),
    this.refuseConsent = false,
    this.hangConsent = false,
    this.refuseProfile = false,
    this.refuseSend = false,
    this.refuseSignIn = false,
    bool signedIn = true,
  }) : super(latency: Duration.zero, signedIn: signedIn);

  /// What the refused call throws.
  final ApiFailure failure;

  final bool refuseConsent;

  /// Hold `recordConsent` open until [releaseConsent] is called.
  ///
  /// Without this a test cannot tap twice "while the first call is in flight":
  /// the fake settles in a microtask, and microtasks flush between two awaited
  /// taps, so the second tap would land on a call that had already finished and
  /// navigated. Holding the call open is the only way to put a second tap
  /// inside the window the busy guard exists for.
  final bool hangConsent;
  final bool refuseProfile;
  final bool refuseSend;
  final bool refuseSignIn;

  /// How many times consent was actually posted, so a test can prove a single
  /// tap produced a single write.
  int consentCalls = 0;

  /// How many times the profile was actually saved.
  int profileSaves = 0;

  final Completer<void> _consentGate = Completer<void>();

  /// Let a held `recordConsent` finish. Only meaningful with [hangConsent].
  void releaseConsent() {
    if (!_consentGate.isCompleted) {
      _consentGate.complete();
    }
  }

  Never _refuse() => throw ApiRepositoryException(failure);

  @override
  Future<AuthSession> signIn({
    required String email,
    required String password,
  }) {
    if (refuseSignIn) {
      _refuse();
    }
    return super.signIn(email: email, password: password);
  }

  @override
  Future<ConsentRecord> recordConsent(
    ConsentType type, {
    required String version,
  }) async {
    consentCalls += 1;
    if (refuseConsent) {
      _refuse();
    }
    if (hangConsent) {
      await _consentGate.future;
    }
    return super.recordConsent(type, version: version);
  }

  @override
  Future<HealthProfile> saveHealthProfile(HealthProfile profile) {
    profileSaves += 1;
    if (refuseProfile) {
      _refuse();
    }
    return super.saveHealthProfile(profile);
  }

  @override
  Future<ChatMessage> sendMessage(
    String text, {
    List<String> attachments = const <String>[],
  }) {
    if (refuseSend) {
      _refuse();
    }
    return super.sendMessage(text, attachments: attachments);
  }
}
