import 'enums.dart';
import 'json.dart';
import 'plan.dart';

/// A short coaching note on the Today screen.
///
/// Copy rules, enforced by review and by the server-side validator: describe
/// what was seen and what helps; never name a condition, a medicine or a dose.
/// "Your vitamin D is below the usual range - sunlight and these foods help, and
/// it is worth asking your doctor about" is a note. "You have a vitamin D
/// deficiency, take 60,000 IU weekly" is two separate violations.
class FocusNote {
  const FocusNote({
    required this.id,
    required this.title,
    required this.body,
    this.tone = NoteTone.calm,
    this.linkedBiomarker,
    this.actionLabel,
  });

  final String id;
  final String title;
  final String body;
  final NoteTone tone;
  final String? linkedBiomarker;
  final String? actionLabel;

  factory FocusNote.fromJson(Map<String, dynamic> json) => FocusNote(
        id: asString(json['id']),
        title: asString(json['title']),
        body: asString(json['body']),
        tone: NoteTone.fromWire(json['tone']),
        linkedBiomarker: asStringOrNull(json['linked_biomarker']),
        actionLabel: asStringOrNull(json['action_label']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'id': id,
        'title': title,
        'body': body,
        'tone': tone.wire,
        'linked_biomarker': linkedBiomarker,
        'action_label': actionLabel,
      });
}

/// A red-flag finding. Rendered by `HpEscalationCard`, which cannot be dismissed.
///
/// Raised by deterministic threshold rules in `backend/app/rules`, never by the
/// model. [steps] are things to do or ask; they never name a medicine or a dose,
/// and they never tell anyone to stop a treatment.
class EscalationNotice {
  const EscalationNotice({
    required this.id,
    required this.title,
    required this.body,
    this.steps = const <String>[],
    this.raisedAt,
    this.sourceCitation,
    this.acknowledgedAt,
  });

  final String id;
  final String title;
  final String body;
  final List<String> steps;
  final DateTime? raisedAt;
  final String? sourceCitation;

  /// Records that the user read it. It does not remove the card - only the
  /// finding being resolved does that.
  final DateTime? acknowledgedAt;

  factory EscalationNotice.fromJson(Map<String, dynamic> json) =>
      EscalationNotice(
        id: asString(json['id']),
        title: asString(json['title']),
        body: asString(json['body']),
        steps: asStringList(json['steps']),
        raisedAt: asTimestamp(json['raised_at']),
        sourceCitation: asStringOrNull(json['source_citation']),
        acknowledgedAt: asTimestamp(json['acknowledged_at']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'id': id,
        'title': title,
        'body': body,
        'steps': steps,
        'raised_at': timestampToJson(raisedAt),
        'source_citation': sourceCitation,
        'acknowledged_at': timestampToJson(acknowledgedAt),
      });
}

/// Everything the Today screen needs, in one round trip.
///
/// It is one object rather than six calls because Today is the screen people
/// open on a train with one bar of signal, and it is the screen cached locally
/// for offline use.
class TodayBriefing {
  const TodayBriefing({
    required this.date,
    required this.displayName,
    this.wakeTime = '06:30',
    this.sleepTime = '22:30',
    this.hydrationMl = 0,
    this.hydrationTargetMl,
    this.hydrationTargetSourcedMl,
    this.hydrationTargetChosenByUser = false,
    this.hydrationTargetSource = '',
    this.hydrationTargetCaution = '',
    this.movementMinutes = 0,
    this.movementTargetMinutes = 30,
    this.meals = const <MealPlanItem>[],
    this.focus = const <FocusNote>[],
    this.escalations = const <EscalationNotice>[],
    this.planRationale,
    this.lastReportHeadline,
  });

  final DateTime date;
  final String displayName;
  final String wakeTime;
  final String sleepTime;

  /// Millilitres of water logged for this day. The server's figure, plus
  /// anything logged on this phone that has not reached it yet.
  final double hydrationMl;

  /// The daily water goal in force, and **null when the server will not give
  /// one** - pregnancy, or a condition where fluid is a doctor's decision.
  ///
  /// It used to default to 2500, which was a number nobody computed shown as
  /// though somebody had. There is no default any more: no goal means no bar,
  /// and [hydrationTargetSource] carries the reason instead of a citation.
  final double? hydrationTargetMl;

  /// What the published guideline says for this profile, sent whatever the
  /// person chose, so the evidence stays visible beside the choice.
  final double? hydrationTargetSourcedMl;

  /// True when the goal is one this person set for themselves.
  final bool hydrationTargetChosenByUser;

  /// The citation behind the goal, or the reason there is not one.
  final String hydrationTargetSource;

  /// The warning attached to a chosen goal above the published range, empty
  /// when there is nothing to say. Server text, shown verbatim.
  final String hydrationTargetCaution;

  final int movementMinutes;
  final int movementTargetMinutes;
  final List<MealPlanItem> meals;
  final List<FocusNote> focus;
  final List<EscalationNotice> escalations;
  final String? planRationale;
  final String? lastReportHeadline;

  bool get hasEscalation => escalations.isNotEmpty;

  /// The five `hydrationTarget*` fields as the one object screens render.
  ///
  /// They are flat on this class because the Today screen has always passed
  /// `briefing.hydrationTargetMl` down to the water card, and they arrive flat
  /// on the wire; this getter is what saves the card from unpacking them again.
  HydrationGoal get hydrationGoal => HydrationGoal(
        millilitres: hydrationTargetMl,
        sourcedMillilitres: hydrationTargetSourcedMl,
        chosenByUser: hydrationTargetChosenByUser,
        source: hydrationTargetSource,
        caution: hydrationTargetCaution,
      );

  factory TodayBriefing.fromJson(Map<String, dynamic> json) => TodayBriefing(
        date: asDate(json['date']) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        displayName: asString(json['display_name']),
        wakeTime: asString(json['wake_time'], fallback: '06:30'),
        sleepTime: asString(json['sleep_time'], fallback: '22:30'),
        hydrationMl: asDouble(json['hydration_ml']),
        hydrationTargetMl: asDoubleOrNull(json['hydration_target_ml']),
        hydrationTargetSourcedMl:
            asDoubleOrNull(json['hydration_target_sourced_ml']),
        hydrationTargetChosenByUser:
            asBool(json['hydration_target_chosen_by_user']),
        hydrationTargetSource: asString(json['hydration_target_source']),
        hydrationTargetCaution: asString(json['hydration_target_caution']),
        movementMinutes: asInt(json['movement_minutes']),
        movementTargetMinutes:
            asInt(json['movement_target_minutes'], fallback: 30),
        meals: asMapList(json['meals']).map(MealPlanItem.fromJson).toList(),
        focus: asMapList(json['focus']).map(FocusNote.fromJson).toList(),
        escalations: asMapList(json['escalations'])
            .map(EscalationNotice.fromJson)
            .toList(),
        planRationale: asStringOrNull(json['plan_rationale']),
        lastReportHeadline: asStringOrNull(json['last_report_headline']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'date': dateToJson(date),
        'display_name': displayName,
        'wake_time': wakeTime,
        'sleep_time': sleepTime,
        'hydration_ml': hydrationMl,
        'hydration_target_ml': hydrationTargetMl,
        'hydration_target_sourced_ml': hydrationTargetSourcedMl,
        'hydration_target_chosen_by_user': hydrationTargetChosenByUser,
        'hydration_target_source': hydrationTargetSource,
        'hydration_target_caution': hydrationTargetCaution,
        'movement_minutes': movementMinutes,
        'movement_target_minutes': movementTargetMinutes,
        'meals': meals.map((MealPlanItem m) => m.toJson()).toList(),
        'focus': focus.map((FocusNote f) => f.toJson()).toList(),
        'escalations':
            escalations.map((EscalationNotice e) => e.toJson()).toList(),
        'plan_rationale': planRationale,
        'last_report_headline': lastReportHeadline,
      });
}
