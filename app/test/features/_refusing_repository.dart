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
    this.refuseProfile = false,
    this.refuseSend = false,
    this.refuseSignIn = false,
    bool signedIn = true,
  }) : super(latency: Duration.zero, signedIn: signedIn);

  /// What the refused call throws.
  final ApiFailure failure;

  final bool refuseConsent;
  final bool refuseProfile;
  final bool refuseSend;
  final bool refuseSignIn;

  /// How many times consent was actually posted, so a test can prove a single
  /// tap produced a single write.
  int consentCalls = 0;

  /// How many times the profile was actually saved.
  int profileSaves = 0;

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
  }) {
    consentCalls += 1;
    if (refuseConsent) {
      _refuse();
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
