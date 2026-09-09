/// Hand-written JSON helpers.
///
/// There is deliberately no code generation anywhere in this app: `build_runner`
/// output cannot be produced in the environment these files are authored in, and
/// a missing generated file is a build failure rather than a warning. Every model
/// therefore reads and writes its own map, and every reader is total - it returns
/// a sensible value for a missing or wrongly-typed field instead of throwing,
/// because a single unexpected null from the backend should not blank a screen.
///
/// The one thing that is never guessed is a health number: [asDoubleOrNull]
/// returns null rather than zero, and callers surface that as "needs your check".
library;

Map<String, dynamic> asMap(Object? value) {
  if (value is Map) {
    return value.cast<String, dynamic>();
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> asMapList(Object? value) {
  if (value is List) {
    return value
        .whereType<Map<dynamic, dynamic>>()
        .map((Map<dynamic, dynamic> e) => e.cast<String, dynamic>())
        .toList();
  }
  return <Map<String, dynamic>>[];
}

String asString(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

String? asStringOrNull(Object? value) => value is String ? value : null;

bool asBool(Object? value, {bool fallback = false}) =>
    value is bool ? value : fallback;

int asInt(Object? value, {int fallback = 0}) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

int? asIntOrNull(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

double? asDoubleOrNull(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

double asDouble(Object? value, {double fallback = 0}) =>
    asDoubleOrNull(value) ?? fallback;

List<String> asStringList(Object? value) {
  if (value is List) {
    return value.whereType<String>().toList();
  }
  return <String>[];
}

Map<String, String> asStringMap(Object? value) {
  final Map<String, String> out = <String, String>{};
  if (value is Map) {
    value.forEach((Object? k, Object? v) {
      if (k is String && v is String) {
        out[k] = v;
      }
    });
  }
  return out;
}

Map<String, double> asDoubleMap(Object? value) {
  final Map<String, double> out = <String, double>{};
  if (value is Map) {
    value.forEach((Object? k, Object? v) {
      final double? d = asDoubleOrNull(v);
      if (k is String && d != null) {
        out[k] = d;
      }
    });
  }
  return out;
}

/// Full timestamp, round-trip safe.
DateTime? asTimestamp(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

String? timestampToJson(DateTime? value) => value?.toIso8601String();

/// A calendar date with no time part, as Postgres `date` columns carry.
DateTime? asDate(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  final DateTime? parsed = DateTime.tryParse(value);
  if (parsed == null) {
    return null;
  }
  return DateTime(parsed.year, parsed.month, parsed.day);
}

String? dateToJson(DateTime? value) {
  if (value == null) {
    return null;
  }
  final String y = value.year.toString().padLeft(4, '0');
  final String m = value.month.toString().padLeft(2, '0');
  final String d = value.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Drops null entries so a payload never asserts a value we do not have.
Map<String, dynamic> prune(Map<String, dynamic> input) {
  final Map<String, dynamic> out = <String, dynamic>{};
  input.forEach((String key, dynamic value) {
    if (value != null) {
      out[key] = value;
    }
  });
  return out;
}
