import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';

/// What the app shows when it was built without a backend to talk to.
///
/// The three values it needs arrive through `--dart-define` at build time, and
/// the owner has not supplied them yet. The two wrong ways to handle that are a
/// crash on launch and a spinner that never resolves; both make a working app
/// look broken and neither tells anybody what to do about it.
///
/// So this screen is calm, specific and short: what is missing, by name, the
/// exact command that supplies it, and a way through to the sample data so the
/// app can still be looked at. No key, no fragment of a key, and no stack trace
/// appears anywhere on it.
class NotConfiguredScreen extends ConsumerWidget {
  const NotConfiguredScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HpPalette p = context.hp;
    final AppConfig config = ref.watch(appConfigProvider);
    // A startup failure is the more specific of the two explanations, so it
    // wins when there is one.
    final String explanation =
        ref.watch(startupErrorProvider) ?? config.explanation;
    final List<String> missing = config.missing;

    return Scaffold(
      backgroundColor: p.ground,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            HpSpacing.gutter,
            HpSpacing.section,
            HpSpacing.gutter,
            HpSpacing.section,
          ),
          children: <Widget>[
            const HpMark(size: 44),
            const SizedBox(height: HpSpacing.xl),
            Text(
              'Not connected yet',
              style: HpType.display.copyWith(color: p.ink),
            ),
            const SizedBox(height: HpSpacing.md),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(
                explanation,
                style: HpType.reading.copyWith(color: p.inkMuted),
              ),
            ),
            if (missing.isNotEmpty) ...<Widget>[
              const SizedBox(height: HpSpacing.section),
              const HpSectionHeader(
                title: 'What is missing',
                note: 'build settings',
              ),
              for (final String name in missing)
                Padding(
                  padding: const EdgeInsets.only(bottom: HpSpacing.xs),
                  child: Text(
                    name,
                    style: HpType.bodyStrong.copyWith(color: p.ink),
                  ),
                ),
            ],
            const SizedBox(height: HpSpacing.section),
            const HpSectionHeader(
              title: 'How it is supplied',
              note: 'at build time, never in the repository',
            ),
            HpCard(
              tone: HpCardTone.flat,
              child: SelectableText(
                AppConfig.buildCommand,
                style: HpType.micro.copyWith(
                  color: p.inkMuted,
                  fontFamily: 'monospace',
                  fontFamilyFallback: const <String>['Roboto Mono', 'monospace'],
                ),
              ),
            ),
            const SizedBox(height: HpSpacing.md),
            Text(
              'These are addresses and a publishable key. No private key belongs '
              'in this app, and none is ever built into it.',
              style: HpType.micro.copyWith(color: p.inkFaint),
            ),
            const SizedBox(height: HpSpacing.section),
            HpButton(
              label: 'Look around with sample data',
              tone: HpButtonTone.secondary,
              onPressed: () => context.go('/welcome'),
            ),
            const SizedBox(height: HpSpacing.md),
            Text(
              'Nothing you see or type in sample mode leaves this phone, and '
              'none of it is your health data.',
              style: HpType.micro.copyWith(color: p.inkFaint),
            ),
          ],
        ),
      ),
    );
  }
}
