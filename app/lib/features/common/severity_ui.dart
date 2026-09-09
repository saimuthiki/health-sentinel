import '../../core/theme/hp_severity.dart';
import '../../data/models/models.dart';

/// The one place where a data-layer status becomes a visual severity.
///
/// Keeping this mapping in the feature layer means `core/` stays free of any
/// knowledge of the data model, and `data/` stays free of any knowledge of how
/// things look. It also means there is exactly one answer to "how loud is a
/// borderline value?" instead of one per screen.
extension LabStatusUi on LabStatus {
  HpSeverity get severity {
    switch (this) {
      case LabStatus.normal:
        return HpSeverity.calm;
      case LabStatus.borderlineLow:
      case LabStatus.borderlineHigh:
        return HpSeverity.watch;
      case LabStatus.low:
      case LabStatus.high:
        return HpSeverity.attention;
      case LabStatus.criticalLow:
      case LabStatus.criticalHigh:
        return HpSeverity.urgent;
      case LabStatus.needsReview:
        return HpSeverity.unknown;
    }
  }
}

extension NoteToneUi on NoteTone {
  HpSeverity get severity {
    switch (this) {
      case NoteTone.calm:
        return HpSeverity.calm;
      case NoteTone.watch:
        return HpSeverity.watch;
      case NoteTone.attention:
        return HpSeverity.attention;
      case NoteTone.urgent:
        return HpSeverity.urgent;
      case NoteTone.unknown:
        return HpSeverity.unknown;
    }
  }
}

extension HealthReportUi on HealthReport {
  /// The loudest thing in the report decides how the report itself reads.
  HpSeverity get severity {
    bool has(LabStatus status) =>
        results.any((LabResult r) => r.status == status);
    if (has(LabStatus.criticalLow) || has(LabStatus.criticalHigh)) {
      return HpSeverity.urgent;
    }
    if (has(LabStatus.low) || has(LabStatus.high)) {
      return HpSeverity.attention;
    }
    if (has(LabStatus.borderlineLow) || has(LabStatus.borderlineHigh)) {
      return HpSeverity.watch;
    }
    if (results.any((LabResult r) => r.needsReview)) {
      return HpSeverity.unknown;
    }
    return HpSeverity.calm;
  }
}
