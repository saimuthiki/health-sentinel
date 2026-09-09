import 'enums.dart';
import 'json.dart';
import 'today.dart';

/// `lab_results`, joined with the `biomarkers` reference table for the display
/// name and with the report summary for the plain-language line.
///
/// [status] and the reference bounds come from deterministic backend rules over
/// the curated `reference_ranges` table - never from the model. [plainLanguage]
/// is the one field the model writes, and it is checked by the safety validator
/// before it reaches here.
class LabResult {
  const LabResult({
    required this.id,
    required this.biomarkerCode,
    required this.displayName,
    required this.unit,
    required this.status,
    this.value,
    this.valueText,
    this.reportId,
    this.printedRange,
    this.refLow,
    this.refHigh,
    this.needsReview = false,
    this.confirmedByUser = false,
    this.measuredOn,
    this.plainLanguage,
    this.sourceCitation,
  });

  final String id;
  final String biomarkerCode;
  final String displayName;

  /// Null when the lab printed something we could not read. Never guessed.
  final double? value;

  /// The value **exactly as the backend sent it**, digit for digit.
  ///
  /// The API returns lab values as strings on purpose, and this field keeps them
  /// that way. Parsing "0.45" into a double and printing it back through a
  /// formatter is how a value silently becomes "0.5" on the way to the screen,
  /// and a lab number the app rounded is a lab number the app made up. [value]
  /// stays for charts and comparisons; [valueLabel] shows this.
  final String? valueText;

  final String unit;
  final LabStatus status;
  final String? reportId;

  /// Exactly what the lab printed, kept verbatim so the user can check us.
  final String? printedRange;

  final double? refLow;
  final double? refHigh;

  /// We could not map the value or the unit with confidence. The UI must ask.
  final bool needsReview;

  final bool confirmedByUser;
  final DateTime? measuredOn;

  /// One sentence a person can understand. Never a diagnosis.
  final String? plainLanguage;

  /// Where the reference range came from. Mandatory on every range in the
  /// database, so it is always available to show.
  final String? sourceCitation;

  bool get isOutsideRange =>
      status != LabStatus.normal && status != LabStatus.needsReview;

  String get valueLabel {
    final String? exact = valueText;
    if (exact != null && exact.trim().isNotEmpty) {
      final String shown = exact.trim();
      return unit.isEmpty ? shown : '$shown $unit';
    }
    // Reached only when neither a textual value nor a raw `value` was stored --
    // a chart-only row. A lab figure that exists is shown as the lab printed it,
    // never re-rounded by us.
    final double? v = value;
    if (v == null) {
      return '--';
    }
    final String number =
        v == v.roundToDouble() && v.abs() < 1000 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return unit.isEmpty ? number : '$number $unit';
  }

  factory LabResult.fromJson(Map<String, dynamic> json) => LabResult(
        id: asString(json['id']),
        biomarkerCode: asString(json['biomarker_code']),
        displayName: asString(json['display_name']),
        value: asDoubleOrNull(json['value']),
        // This is the cache path: toJson writes value_text, so it is normally
        // present. The fallback to `value` covers a row written by an older build
        // that stored no value_text -- taking the string verbatim rather than the
        // double parsed from it, because a lab figure is shown as the lab printed
        // it. (The live API path is Wire.labResultFrom, which already does this;
        // ResultOut.value is a str on the backend for exactly this reason.)
        valueText: asStringOrNull(json['value_text']) ?? asStringOrNull(json['value']),
        unit: asString(json['unit']),
        status: LabStatus.fromWire(json['status']),
        reportId: asStringOrNull(json['report_id']),
        printedRange: asStringOrNull(json['printed_range']),
        refLow: asDoubleOrNull(json['ref_low']),
        refHigh: asDoubleOrNull(json['ref_high']),
        needsReview: asBool(json['needs_review']),
        confirmedByUser: asBool(json['confirmed_by_user']),
        measuredOn: asDate(json['measured_on']),
        plainLanguage: asStringOrNull(json['plain_language']),
        sourceCitation: asStringOrNull(json['source_citation']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'id': id,
        'biomarker_code': biomarkerCode,
        'display_name': displayName,
        'value': value,
        'value_text': valueText,
        'unit': unit,
        'status': status.wire,
        'report_id': reportId,
        'printed_range': printedRange,
        'ref_low': refLow,
        'ref_high': refHigh,
        'needs_review': needsReview,
        'confirmed_by_user': confirmedByUser,
        'measured_on': dateToJson(measuredOn),
        'plain_language': plainLanguage,
        'source_citation': sourceCitation,
      });
}

/// `reports` plus the results extracted from it.
class HealthReport {
  const HealthReport({
    required this.id,
    required this.fileName,
    required this.status,
    this.reportType = 'blood_panel',
    this.labName,
    this.collectedOn,
    this.createdAt,
    this.mimeType = 'application/pdf',
    this.storagePath,
    this.keepOriginalUntil,
    this.headline,
    this.results = const <LabResult>[],
    this.escalations = const <EscalationNotice>[],
  });

  final String id;
  final String fileName;
  final ReportStatus status;
  final String reportType;
  final String? labName;
  final DateTime? collectedOn;
  final DateTime? createdAt;
  final String mimeType;
  final String? storagePath;

  /// Original files are deleted after this date unless the user keeps them.
  final DateTime? keepOriginalUntil;

  /// One line summarising the report. Written by the model, checked by the
  /// safety validator, and never a diagnosis.
  final String? headline;

  final List<LabResult> results;

  /// Red flags the backend's deterministic rules raised over these results.
  ///
  /// They are carried on the report rather than fetched separately because the
  /// escalation card has to be on screen *before* any value is, and a second
  /// request would let the values render first. Sorted most urgent first by the
  /// mapper; the screen renders them in order, above everything else, with no
  /// way to dismiss one.
  final List<EscalationNotice> escalations;

  bool get hasEscalation => escalations.isNotEmpty;

  int get outsideRangeCount =>
      results.where((LabResult r) => r.isOutsideRange).length;

  int get needsReviewCount =>
      results.where((LabResult r) => r.needsReview).length;

  factory HealthReport.fromJson(Map<String, dynamic> json) => HealthReport(
        id: asString(json['id']),
        fileName: asString(json['file_name']),
        status: ReportStatus.fromWire(json['status']),
        reportType: asString(json['report_type'], fallback: 'blood_panel'),
        labName: asStringOrNull(json['lab_name']),
        collectedOn: asDate(json['collected_on']),
        createdAt: asTimestamp(json['created_at']),
        mimeType: asString(json['mime_type'], fallback: 'application/pdf'),
        storagePath: asStringOrNull(json['storage_path']),
        keepOriginalUntil: asDate(json['keep_original_until']),
        headline: asStringOrNull(json['headline']),
        results: asMapList(json['results']).map(LabResult.fromJson).toList(),
        escalations: asMapList(json['escalations'])
            .map(EscalationNotice.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'id': id,
        'file_name': fileName,
        'status': status.wire,
        'report_type': reportType,
        'lab_name': labName,
        'collected_on': dateToJson(collectedOn),
        'created_at': timestampToJson(createdAt),
        'mime_type': mimeType,
        'storage_path': storagePath,
        'keep_original_until': dateToJson(keepOriginalUntil),
        'headline': headline,
        'results': results.map((LabResult r) => r.toJson()).toList(),
        'escalations':
            escalations.map((EscalationNotice e) => e.toJson()).toList(),
      });
}

/// A single measurement in a biomarker's history.
class TrendPoint {
  const TrendPoint({required this.measuredOn, required this.value});

  final DateTime measuredOn;
  final double value;

  factory TrendPoint.fromJson(Map<String, dynamic> json) => TrendPoint(
        measuredOn: asDate(json['measured_on']) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        value: asDouble(json['value']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'measured_on': dateToJson(measuredOn),
        'value': value,
      };
}

/// One biomarker over time, with the band that counts as usual for this person.
class BiomarkerTrend {
  const BiomarkerTrend({
    required this.biomarkerCode,
    required this.displayName,
    required this.unit,
    this.refLow,
    this.refHigh,
    this.points = const <TrendPoint>[],
  });

  final String biomarkerCode;
  final String displayName;
  final String unit;
  final double? refLow;
  final double? refHigh;
  final List<TrendPoint> points;

  factory BiomarkerTrend.fromJson(Map<String, dynamic> json) => BiomarkerTrend(
        biomarkerCode: asString(json['biomarker_code']),
        displayName: asString(json['display_name']),
        unit: asString(json['unit']),
        refLow: asDoubleOrNull(json['ref_low']),
        refHigh: asDoubleOrNull(json['ref_high']),
        points: asMapList(json['points']).map(TrendPoint.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'biomarker_code': biomarkerCode,
        'display_name': displayName,
        'unit': unit,
        'ref_low': refLow,
        'ref_high': refHigh,
        'points': points.map((TrendPoint p) => p.toJson()).toList(),
      });
}
