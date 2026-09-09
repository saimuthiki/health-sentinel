import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

/// Settings, data and the things that only get touched once.
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HpPalette p = context.hp;
    final AuthSession? session = ref.watch(sessionControllerProvider).value;
    final String name = (session?.displayName ?? '').isEmpty
        ? 'Your account'
        : session!.displayName;

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            HpSpacing.gutter,
            HpSpacing.lg,
            HpSpacing.gutter,
            HpSpacing.section,
          ),
          children: <Widget>[
            HpCard(
              child: Row(
                children: <Widget>[
                  Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: p.pineSoft,
                      borderRadius: HpRadii.pillRadius,
                    ),
                    child: Icon(
                      Icons.person_outline_rounded,
                      color: p.pineDeep,
                    ),
                  ),
                  const SizedBox(width: HpSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          name,
                          style: HpType.bodyStrong.copyWith(color: p.ink),
                        ),
                        const SizedBox(height: HpSpacing.xxs),
                        Text(
                          session?.email ?? 'Not signed in',
                          style: HpType.label.copyWith(color: p.inkFaint),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: HpSpacing.section),
            const HpSectionHeader(title: 'Your setup'),
            _MoreTile(
              icon: Icons.tune_rounded,
              title: 'Health profile',
              subtitle: 'Diet, allergies, meal times, sleep, goals',
              onTap: () => context.go('/profile'),
            ),
            _MoreTile(
              icon: Icons.notifications_none_rounded,
              title: 'Reminders',
              subtitle: 'Water, meals, movement, sleep and quiet hours',
              onTap: () {},
            ),
            const SizedBox(height: HpSpacing.section),
            const HpSectionHeader(title: 'Your data'),
            _MoreTile(
              icon: Icons.file_download_outlined,
              title: 'Export everything',
              subtitle: 'A copy of your reports, values, plans and chat',
              onTap: () {},
            ),
            _MoreTile(
              icon: Icons.delete_outline_rounded,
              title: 'Delete all my health data',
              subtitle: 'Removes the files as well as the data. Permanent.',
              destructive: true,
              onTap: () => _confirmDelete(context),
            ),
            const SizedBox(height: HpSpacing.section),
            const HpSectionHeader(title: 'About'),
            HpCard(
              tone: HpCardTone.flat,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'What HealthPulse is',
                    style: HpType.bodyStrong.copyWith(color: p.ink),
                  ),
                  const SizedBox(height: HpSpacing.sm),
                  Text(
                    HpDisclaimer.fullText,
                    style: HpType.reading.copyWith(color: p.inkMuted),
                  ),
                  const SizedBox(height: HpSpacing.md),
                  Text(
                    'Consent text version $consentVersion',
                    style: HpType.micro.copyWith(color: p.inkFaint),
                  ),
                ],
              ),
            ),
            const SizedBox(height: HpSpacing.xxl),
            HpButton(
              label: 'Sign out',
              tone: HpButtonTone.secondary,
              icon: Icons.logout_rounded,
              onPressed: () async {
                await ref.read(sessionControllerProvider.notifier).signOut();
                if (context.mounted) {
                  context.go('/welcome');
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _confirmDelete(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Delete all your health data?'),
          content: const Text(
            'This removes every report, every value, every plan and every '
            'message, and it deletes the uploaded files themselves. It cannot '
            'be undone, and you will get a receipt confirming what was removed.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Keep my data'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Delete everything'),
            ),
          ],
        );
      },
    );
  }
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final Color tint = destructive ? p.urgentInk : p.ink;

    return Padding(
      padding: const EdgeInsets.only(bottom: HpSpacing.sm),
      child: Material(
        color: p.surface,
        borderRadius: HpRadii.fieldRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.all(HpSpacing.lg),
            decoration: BoxDecoration(
              borderRadius: HpRadii.fieldRadius,
              border: Border.all(color: p.hairline),
            ),
            child: Row(
              children: <Widget>[
                Icon(icon, size: 21, color: destructive ? p.urgentInk : p.pine),
                const SizedBox(width: HpSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: HpType.bodyStrong.copyWith(color: tint),
                      ),
                      const SizedBox(height: HpSpacing.xxs),
                      Text(
                        subtitle,
                        style: HpType.label.copyWith(color: p.inkFaint),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: p.inkFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
