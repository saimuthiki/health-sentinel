import 'package:flutter/material.dart';

import '../theme/hp_palette.dart';
import '../theme/hp_spacing.dart';
import '../theme/hp_typography.dart';

/// Where an entry sits relative to now.
enum HpTimelineState { done, now, upcoming }

@immutable
class HpTimelineEntry {
  const HpTimelineEntry({
    required this.time,
    required this.title,
    required this.icon,
    this.detail,
    this.state = HpTimelineState.upcoming,
    this.onTap,
  });

  /// Already formatted for display: "7:15 am".
  final String time;

  final String title;
  final String? detail;
  final IconData icon;
  final HpTimelineState state;
  final VoidCallback? onTap;
}

/// The day as a single ribbon of time.
///
/// This is the app's one memorable structure and the reason the rest of the
/// interface stays quiet. Everything HealthPulse does is anchored to *when* -
/// meal times, wake and sleep times, hydration through the day, the reminder
/// that fires at four - so the home screen is that spine rather than a grid of
/// cards. The current moment is a filled marigold node, and it is also labelled
/// "Now", because colour on its own is not a signal.
class HpDayTimeline extends StatelessWidget {
  const HpDayTimeline({super.key, required this.entries});

  final List<HpTimelineEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < entries.length; i++)
          _TimelineRow(
            entry: entries[i],
            isLast: i == entries.length - 1,
          ),
      ],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({super.key, required this.entry, required this.isLast});

  final HpTimelineEntry entry;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final bool isNow = entry.state == HpTimelineState.now;
    final bool isDone = entry.state == HpTimelineState.done;

    final Color titleColour = isDone ? p.inkMuted : p.ink;

    final Widget content = Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : HpSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Flexible(
                child: Text(
                  entry.title,
                  style: HpType.bodyStrong.copyWith(color: titleColour),
                ),
              ),
              if (isNow) ...<Widget>[
                const SizedBox(width: HpSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HpSpacing.sm,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: p.marigoldSoft,
                    borderRadius: HpRadii.pillRadius,
                  ),
                  child: Text(
                    'Now',
                    style: HpType.micro.copyWith(
                      color: p.marigoldInk,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (entry.detail != null) ...<Widget>[
            const SizedBox(height: HpSpacing.xxs),
            Text(
              entry.detail!,
              style: HpType.label.copyWith(color: p.inkFaint),
            ),
          ],
        ],
      ),
    );

    // IntrinsicHeight lets the connecting rule fill whatever height the row's
    // text ends up needing, which matters because that height changes with the
    // reader's text-scale setting.
    final Widget row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 62,
            child: Text(
              entry.time,
              style: HpType.figureSmall.copyWith(
                color: isDone ? p.inkFaint : p.inkMuted,
                fontSize: 15,
              ),
            ),
          ),
          SizedBox(
            width: 28,
            child: Column(
              children: <Widget>[
                _Node(
                  icon: entry.icon,
                  isNow: isNow,
                  isDone: isDone,
                ),
                if (!isLast)
                  Expanded(
                    child: Center(
                      child: Container(width: 2, color: p.hairline),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );

    if (entry.onTap == null) {
      return row;
    }
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: entry.onTap,
        borderRadius: HpRadii.fieldRadius,
        child: row,
      ),
    );
  }
}

class _Node extends StatelessWidget {
  const _Node({
    super.key,
    required this.icon,
    required this.isNow,
    required this.isDone,
  });

  final IconData icon;
  final bool isNow;
  final bool isDone;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    if (isNow) {
      return Container(
        width: 26,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: p.marigold,
          borderRadius: HpRadii.pillRadius,
        ),
        child: Icon(icon, size: 15, color: const Color(0xFF3B2A05)),
      );
    }

    return Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDone ? p.surfaceSunk : p.surface,
        borderRadius: HpRadii.pillRadius,
        border: Border.all(color: isDone ? p.hairline : p.outline),
      ),
      child: Icon(
        icon,
        size: 14,
        color: isDone ? p.inkFaint : p.inkMuted,
      ),
    );
  }
}
