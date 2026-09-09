import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';

/// What we collect, where it goes, and what this app is not.
///
/// Two things are stated plainly rather than buried, because burying them would
/// be the dishonest choice and because the Play Store asks about both: this is
/// not a doctor, and uploads are analysed by Google's Gemini API. Accepting is a
/// deliberate act - a switch each, not one pre-ticked box - and the version of
/// this text is written to the `consents` table alongside the timestamp.
class ConsentScreen extends ConsumerStatefulWidget {
  const ConsentScreen({super.key});

  @override
  ConsumerState<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends ConsumerState<ConsentScreen> {
  bool _understandsNotADoctor = false;
  bool _acceptsAiProcessing = false;
  bool _saving = false;

  bool get _canContinue => _understandsNotADoctor && _acceptsAiProcessing;

  Future<void> _accept() async {
    setState(() => _saving = true);
    await ref.read(sessionControllerProvider.notifier).acceptConsent();
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    context.go('/profile');
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

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
              child: HpButton(
                label: 'Agree and continue',
                busy: _saving,
                onPressed: _canContinue ? _accept : null,
              ),
            ),
          ],
        ),
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
