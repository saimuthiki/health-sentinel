import 'json.dart';

/// The signed-in user, as far as the app is concerned.
///
/// The access token itself is never held here: it lives in the platform keystore
/// through `flutter_secure_storage`, and the repository attaches it to requests.
class AuthSession {
  const AuthSession({
    required this.userId,
    required this.email,
    this.displayName = '',
    this.hasCompletedProfile = false,
    this.hasAcceptedConsent = false,
  });

  final String userId;
  final String email;
  final String displayName;
  final bool hasCompletedProfile;
  final bool hasAcceptedConsent;

  AuthSession copyWith({
    String? displayName,
    bool? hasCompletedProfile,
    bool? hasAcceptedConsent,
  }) {
    return AuthSession(
      userId: userId,
      email: email,
      displayName: displayName ?? this.displayName,
      hasCompletedProfile: hasCompletedProfile ?? this.hasCompletedProfile,
      hasAcceptedConsent: hasAcceptedConsent ?? this.hasAcceptedConsent,
    );
  }

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
        userId: asString(json['user_id']),
        email: asString(json['email']),
        displayName: asString(json['display_name']),
        hasCompletedProfile: asBool(json['has_completed_profile']),
        hasAcceptedConsent: asBool(json['has_accepted_consent']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'user_id': userId,
        'email': email,
        'display_name': displayName,
        'has_completed_profile': hasCompletedProfile,
        'has_accepted_consent': hasAcceptedConsent,
      };
}
