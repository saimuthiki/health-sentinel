import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../common/failure_copy.dart';
import 'weekly_summary_service.dart';

/// The week just gone.
///
/// The owner asked for this as something that "will boost the user", and the
/// design question underneath that is what an encouraging health app is allowed
/// to say. Four decisions, each of them a choice rather than an accident.
///
/// **The counts and the encouragement are drawn as different things.** The tiles
/// are arithmetic — the backend counted rows, in Python, with no model involved.
/// The sentence at the top is the one thing a model wrote, and it carries no
/// digits at all because the backend refuses one that does. So the two can never
/// disagree about the same week, and nothing on this screen is a number somebody
/// generated.
///
/// **A quiet week is drawn as a quiet week.** When too little was logged there is
/// no encouragement, no tiles full of zeros dressed up as progress, and no
/// apology either: the screen names the things that were not logged and says
/// what to tap next week. That is the honest answer, and it is what makes a full
/// week's sentence believable when it does arrive.
///
/// **What the summary cannot see is written on it.** Water is tallied on this
/// phone and never sent anywhere, so the week cannot count it — and rather than
/// leave a gap somebody reads as a zero, the backend sends the sentence that
/// explains it and this screen shows it.
///
/// **A downgrade is visible.** If the model's sentence broke one of the summary
/// rails, or could not be made safe, the counts still stand and a line says the
/// week is being shown without one. A missing sentence with no explanation reads
/// as a bug; an explained one reads as care.
class WeeklySummaryScreen extends ConsumerStatefulWidget {
  const WeeklySummaryScreen({super.key});

  @override
  ConsumerState<WeeklySummaryScreen> createState() =>
      _WeeklySummaryScreenState();
}

class _WeeklySummaryScreenState extends ConsumerState<WeeklySummaryScreen> {
  /// What the backend last told us. Null until the first fetch answers.
  WeeklySummary? _summary;

  bool _loading = true;

  /// True while a deliberate rewrite is in flight. Separate from [_loading] so
  /// the week already on screen stays on screen while it happens.
  bool _refreshing = false;

  /// Why the week could not be fetched at all. Shown instead of the week.
  String? _loadFailure;

  /// Why the last rewrite did not happen. Shown beside the button that asked
  /// for it — the week itself is untouched, so it must not take over the screen.
  String? _refreshFailure;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Fetch the week. Called on arrival and by "Try again".
  Future<void> _load() async {
    final WeeklySummaryService? service =
        ref.read(weeklySummaryServiceProvider);
    setState(() {
      _loading = true;
      _loadFailure = null;
    });

    WeeklySummary? fetched;
    String? failure;
    try {
      if (service == null) {
        throw const _NoBackend();
      }
      fetched = await service.load();
    } catch (error) {
      failure = error is _NoBackend
          ? _noBackendMessage
          : explainFailure(
              error,
              fallback: 'Your week could not be fetched just now. Nothing has '
                  'changed — try again in a moment.',
            );
    } finally {
      // In a `finally`, so a thrown failure cannot leave this screen spinning
      // for ever with no way back into it.
      final WeeklySummary? week = fetched;
      final String? message = failure;
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailure = message;
          if (week != null) {
            _summary = week;
            _refreshFailure = null;
          }
        });
      }
    }
  }

  /// Ask for the sentence to be written again.
  ///
  /// The guard against a second tap is here rather than on a disabled button:
  /// the button says what it is doing while it does it, and a second tap is
  /// turned away rather than sending the same request twice.
  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    final WeeklySummaryService? service =
        ref.read(weeklySummaryServiceProvider);
    setState(() {
      _refreshing = true;
      _refreshFailure = null;
    });

    WeeklySummary? fetched;
    String? failure;
    try {
      if (service == null) {
        throw const _NoBackend();
      }
      fetched = await service.refresh();
    } catch (error) {
      failure = error is _NoBackend
          ? _noBackendMessage
          : explainFailure(
              error,
              fallback: 'That could not be written again just now. The week '
                  'below is still the one we have — try again in a moment.',
            );
    } finally {
      final WeeklySummary? week = fetched;
      final String? message = failure;
      if (mounted) {
        setState(() {
          _refreshing = false;
          _refreshFailure = message;
          if (week != null) {
            _summary = week;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to More',
          onPressed: () => context.go('/more'),
        ),
        title: const Text('Your week'),
      ),
      body: SafeArea(bottom: false, child: _body(p)),
    );
  }

  Widget _body(HpPalette p) {
    final WeeklySummary? week = _summary;
    if (week == null && _loading) {
      return const HpLoadingState(
        message: 'Adding up your week',
        detail: 'The health engine sleeps between visits, so the first look of '
            'the day can take a moment.',
      );
    }
    final String? loadFailure = _loadFailure;
    if (week == null) {
      return HpErrorState(
        title: 'We could not fetch your week',
        body: loadFailure ??
            'Nothing has changed. Everything you logged is still logged.',
        onRetry: _load,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HpSpacing.gutter,
        HpSpacing.lg,
        HpSpacing.gutter,
        HpSpacing.section,
      ),
      children: <Widget>[
        Text(
          weekLabel(week.weekStart, week.weekEnd),
          style: HpType.label.copyWith(color: p.inkFaint),
        ),
        const SizedBox(height: HpSpacing.md),
        if (week.hasEnoughData) ..._full(p, week) else ..._quiet(p, week),
        const SizedBox(height: HpSpacing.section),
        const HpDisclaimer(),
      ],
    );
  }

  /// A week with enough in it: the sentence, the counts, then the caveats.
  List<Widget> _full(HpPalette p, WeeklySummary week) {
    final String? summary = week.summary;
    final int? movementTarget = week.facts.movementTargetMinutesPerWeek;
    return <Widget>[
      if (summary != null)
        HpCard(
          tone: HpCardTone.tinted,
          child: Text(
            summary,
            style: HpType.reading.copyWith(color: p.ink),
          ),
        )
      else
        const _NoSentenceNotice(),
      const SizedBox(height: HpSpacing.section),
      const HpSectionHeader(
        title: 'What you did',
        note: 'counted, not estimated',
      ),
      ..._lines(p, week.lines),
      if (movementTarget != null && movementTarget > 0) ...<Widget>[
        const SizedBox(height: HpSpacing.sm),
        // The only bar on this screen, and both of its numbers are the
        // backend's: the minutes are folded from logged entries and the target
        // is resolved by curated code from a cited guideline. Nothing here was
        // estimated, so nothing here needs a hedge.
        HpMeter(
          label: 'Movement',
          value: week.facts.movementMinutes.toDouble(),
          target: movementTarget.toDouble(),
          unit: 'minutes this week',
          footnote: week.facts.movementTargetSource,
        ),
      ],
      const SizedBox(height: HpSpacing.lg),
      _refreshRow(p),
      const SizedBox(height: HpSpacing.section),
      _NotMeasured(sentences: week.notMeasured),
    ];
  }

  /// A week with almost nothing in it. No tiles, no encouragement, no apology.
  List<Widget> _quiet(HpPalette p, WeeklySummary week) {
    return <Widget>[
      HpCard(
        tone: HpCardTone.flat,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'A quiet week',
              style: HpType.bodyStrong.copyWith(color: p.ink),
            ),
            const SizedBox(height: HpSpacing.sm),
            ..._lines(p, week.lines, dense: true),
          ],
        ),
      ),
      const SizedBox(height: HpSpacing.lg),
      HpButton(
        label: 'Open today’s plan',
        icon: Icons.today_outlined,
        onPressed: () => context.go('/today'),
      ),
      const SizedBox(height: HpSpacing.section),
      _NotMeasured(sentences: week.notMeasured),
    ];
  }

  List<Widget> _lines(HpPalette p, List<String> lines, {bool dense = false}) {
    return <Widget>[
      for (final String line in lines)
        Padding(
          padding: EdgeInsets.only(
            bottom: dense ? HpSpacing.sm : HpSpacing.md,
          ),
          child: Text(
            line,
            style: HpType.reading.copyWith(color: p.ink),
          ),
        ),
    ];
  }

  Widget _refreshRow(HpPalette p) {
    final String? message = _refreshFailure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        HpButton(
          label: 'Write it again',
          icon: Icons.refresh_rounded,
          tone: HpButtonTone.quiet,
          busy: _refreshing,
          onPressed: _refresh,
        ),
        if (message != null) ...<Widget>[
          const SizedBox(height: HpSpacing.md),
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
                    message,
                    style: HpType.label.copyWith(color: p.urgentInk),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// "Monday 7 Sep to Sunday 13 Sep".
String weekLabel(DateTime start, DateTime end) {
  return 'The week of ${HpFormat.dayShort(start)} to ${HpFormat.dayShort(end)}';
}

/// Why there is no sentence at the top of an otherwise full week.
///
/// Shown rather than left blank. There is only one way to get here -- the
/// backend had counts but no words it was sure of -- and it is worth saying out
/// loud, because it is us refusing to show something we could not stand behind
/// rather than anything being broken. A quiet week takes the other branch and
/// says its own thing.
class _NoSentenceNotice extends StatelessWidget {
  const _NoSentenceNotice();

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return HpCard(
      tone: HpCardTone.flat,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.notes_rounded, size: 18, color: p.inkFaint),
          const SizedBox(width: HpSpacing.sm),
          Expanded(
            child: Text(
              noSentenceMessage,
              style: HpType.label.copyWith(color: p.inkMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Said when the counts are shown without a written summary.
const String noSentenceMessage =
    'Your week is below, in numbers. We had nothing to add to it in words that '
    'we were sure of, so we have not written anything — the counts are the part '
    'we can stand behind.';

/// The caveats. Deliberately at the bottom and deliberately not hidden.
class _NotMeasured extends StatelessWidget {
  const _NotMeasured({required this.sentences});

  final List<String> sentences;

  @override
  Widget build(BuildContext context) {
    if (sentences.isEmpty) {
      return const SizedBox.shrink();
    }
    final HpPalette p = context.hp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const HpSectionHeader(title: 'What this does not count'),
        for (final String sentence in sentences)
          Padding(
            padding: const EdgeInsets.only(bottom: HpSpacing.sm),
            child: Text(
              sentence,
              style: HpType.label.copyWith(color: p.inkMuted),
            ),
          ),
      ],
    );
  }
}

/// Shown in a build with no backend address, where there is nothing to fetch.
const String _noBackendMessage =
    'This build has no backend to ask, so there is no week to show. Sign in on '
    'a configured build to see your summary.';

/// Thrown when there is no service at all. Never shown as an exception: it is
/// caught immediately and turned into [_noBackendMessage].
class _NoBackend implements Exception {
  const _NoBackend();
}
