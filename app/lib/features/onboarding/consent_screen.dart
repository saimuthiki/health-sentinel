import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';
import '../common/api_waking_notice.dart';
import '../common/failure_copy.dart';

/// What we collect, where it goes, and what this app is not.
///
/// Two things are stated plainly rather than buried, because burying them would
/// be the dishonest choice and because the Play Store asks about both: this is
/// not a doctor, and uploads are analysed by Google's Gemini API. Accepting is a
/// deliberate act - a switch each, not one pre-ticked box - and the version of
/// this text is written to the `consents` table alongside the timestamp.
///
/// This is also the first backend call any account ever makes, which is why two
/// things that look like polish are not. The wait is named while it happens
/// ([ApiWakingNotice]), because the free host can take the better part of a
/// minute to start and a silent spinner on a first-run screen reads as a broken
/// app. And a refusal is shown and retried here rather than swallowed: consent
/// that fails to record and says nothing is how somebody ends up with an
/// account they cannot sign into.
class ConsentScreen extends ConsumerStatefulWidget {
  const ConsentScreen({super.key, this.recovered = false});

  /// True when the person was sent here by a refusal rather than by signing up.
  ///
  /// Set from the `blocked` query parameter in `core/router/app_router.dart`.
  /// It changes nothing about what is being agreed to; it only explains, on
  /// arrival, why a screen they may have seen before is in front of them again.
  final bool recovered;

  @override
  ConsumerState<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends ConsumerState<ConsentScreen> {
  bool _understandsNotADoctor = false;
  bool _acceptsAiProcessing = false;
  bool _saving = false;

  /// The last refusal, in our own words, or null. Held in the widget rather
  /// than read off the session, because a failed consent must not disturb who
  /// the app thinks is signed in.
  String? _error;

  bool get _canContinue => _understandsNotADoctor && _acceptsAiProcessing;

  /// Record the consent, and go on **only** if it was actually recorded.
  ///
  /// The busy flag is cleared in a `finally`, so no path out of here - a thrown
  /// failure, a timeout while the free host wakes, a bug in the repository -
  /// can leave the button spinning for ever. Nothing navigates unless the write
  /// succeeded: sending somebody to the profile wizard on a consent that was
  /// never stored is what produced an account the backend then refused.
  Future<void> _accept() async {
    if (_saving) {
      // A second tap while the first is in flight would post the consent twice
      // and, worse, could navigate twice.
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    String? failure;
    try {
      await ref.read(sessionControllerProvider.notifier).acceptConsent();
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'Your agreement could not be saved just now. Nothing was '
            'lost - try again in a moment.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = failure;
        });
      }
    }

    if (failure != null) {
      return;
    }
    if (!mounted) {
      return;
    }
    context.go('/profile');
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final String? error = _error;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  HpSpacing.gutter,
                  HpSpacing.xxl,
                  HpSpacing.gutter,
                  HpSpacing.xxl,
                ),
                children: <Widget>[
                  const HpMark(size: 44),
                  const SizedBox(height: HpSpacing.xl),
                  Text(
                    'Before we start',
                    style: HpType.display.copyWith(color: p.ink),
                  ),
                  const SizedBox(height: HpSpacing.md),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Text(
                      'Two things you should know, in plain words, before you '
                      'give HealthPulse anything about your health.',
                      style: HpType.reading.copyWith(color: p.inkMuted),
                    ),
                  ),
                  if (widget.recovered) ...<Widget>[
                    const SizedBox(height: HpSpacing.lg),
                    const _RecoveryNote(),
                  ],
                  const SizedBox(height: HpSpacing.section),
                  _ConsentBlock(
                    icon: Icons.health_and_safety_outlined,
                    title: 'HealthPulse is not a doctor',
                    body:
                        'It explains your results in plain language and suggests '
                        'food, water, movement and sleep. It does not diagnose '
                        'anything, and it will never name a medicine or tell you '
                        'a dose — not even for a supplement. When something looks '
                        'off, it says so and tells you what to ask a doctor. In an '
                        'emergency, call your local emergency number.',
                    accepted: _understandsNotADoctor,
                    switchLabel: 'I understand this is not medical advice',
                    onChanged: (bool value) =>
                        setState(() => _understandsNotADoctor = value),
                  ),
                  const SizedBox(height: HpSpacing.lg),
                  _ConsentBlock(
                    icon: Icons.cloud_upload_outlined,
                    title: 'Your uploads are analysed by Google’s Gemini API',
                    body:
                        'Reports, scans, prescriptions and food photos you upload '
                        'are sent to our server, which passes them to Google’s '
                        'Gemini API to be read and explained. Your files are stored '
                        'privately and only you can see them. You can delete '
                        'everything at any time from More, and deletion removes the '
                        'files as well as the data.',
                    accepted: _acceptsAiProcessing,
                    switchLabel: 'I agree to my uploads being analysed this way',
                    onChanged: (bool value) =>
                        setState(() => _acceptsAiProcessing = value),
                  ),
                  const SizedBox(height: HpSpacing.xl),
                  Text(
                    'We record which version of this text you agreed to, and when. '
                    'You can read it again any time in More.',
                    style: HpType.label.copyWith(color: p.inkFaint),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(
                HpSpacing.gutter,
                HpSpacing.lg,
                HpSpacing.gutter,
                HpSpacing.lg,
              ),
              decoration: BoxDecoration(
                color: p.ground,
                border: Border(top: BorderSide(color: p.hairline)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // Says the free host is starting, and roughly how long, for
                  // as long as that is actually what is happening.
                  const ApiWakingNotice(),
                  if (error != null) ...<Widget>[
                    Semantics(
                      liveRegion: true,
                      container: true,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(
                            Icons.error_outline_rounded,
                            size: 18,
                            color: p.urgentInk,
                          ),
                          const SizedBox(width: HpSpacing.sm),
                          Expanded(
                            child: Text(
                              error,
                              style: HpType.label.copyWith(color: p.urgentInk),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: HpSpacing.md),
                  ],
                  HpButton(
                    label: 'Agree and continue',
                    busy: _saving,
                    onPressed: _canContinue ? _accept : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Why this screen is in front of you again.
///
/// Shown only when the app arrived here from a refusal. It is deliberately not
/// an accusation and not an apology: it says what the server would not let
/// through and what finishing this screen fixes, so somebody who force-quit
/// mid-consent can see that they are back on the same step rather than lost.
class _RecoveryNote extends StatelessWidget {
  const _RecoveryNote();

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Container(
      padding: const EdgeInsets.all(HpSpacing.lg),
      decoration: BoxDecoration(
        color: p.marigoldSoft,
        borderRadius: HpRadii.fieldRadius,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline_rounded, size: 18, color: p.marigoldInk),
          const SizedBox(width: HpSpacing.md),
          Expanded(
            child: Text(
              'We could not confirm that this account has agreed to the notice '
              'below, so the server would not open anything health-related. '
              'Nothing is wrong with your account, and nothing you have saved '
              'is lost. Agreeing here finishes the step and lets you straight '
              'in.',
              style: HpType.label.copyWith(color: p.marigoldInk),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsentBlock extends StatelessWidget {
  const _ConsentBlock({
    required this.icon,
    required this.title,
    required this.body,
    required this.accepted,
    required this.switchLabel,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool accepted;
  final String switchLabel;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return HpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 22, color: p.pine),
              const SizedBox(width: HpSpacing.md),
              Expanded(
                child: Text(
                  title,
                  style: HpType.headline.copyWith(color: p.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: HpSpacing.md),
          Text(body, style: HpType.reading.copyWith(color: p.inkMuted)),
          const SizedBox(height: HpSpacing.lg),
          Container(height: 1, color: p.hairline),
          const SizedBox(height: HpSpacing.sm),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  switchLabel,
                  style: HpType.bodyStrong.copyWith(color: p.ink),
                ),
              ),
              const SizedBox(width: HpSpacing.md),
              Switch(value: accepted, onChanged: onChanged),
            ],
          ),
        ],
      ),
    );
  }
}
