import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'cache_freshness.dart';

/// The small amount of the app that has to work on a train with no signal.
///
/// Three things are kept, and only three: today's plan, the latest report's
/// summary line, and the alert definitions. That is what makes the app useful
/// with the radio off — you can see what you meant to eat, remember what the
/// last report said in one line, and the reminders keep firing because they were
/// scheduled on the device in the first place.
///
/// Two things are deliberately **not** kept:
///
/// * **Escalations.** A red flag is a statement about the person's health right
///   now. Serving a stored one after a failed refresh would show a finding that
///   may already have been resolved, and hiding a new one that has not been
///   fetched. The repository strips them before writing, and the offline screen
///   says plainly that it could not check.
/// * **Report values.** The same reasoning, one level down.
abstract class OfflineCache {
  Future<Cached<Map<String, dynamic>>?> read(String key);
  Future<void> write(String key, Map<String, dynamic> value, {DateTime? at});
  Future<void> remove(String key);

  /// Everything, gone. Called on sign-out and after "delete all my health data",
  /// because a cache that survives either of those is a leak.
  Future<void> clear();

  Future<void> close();

  // Keys are constants rather than strings at call sites so that a typo is a
  // compile error rather than a cache that silently never hits.
  /// Today's briefing, exactly as [TodayBriefing.toJson] writes it — minus the
  /// escalations, which are stripped before it is stored.
  static const String plan = 'plan.today';

  /// The full day plan behind the Plan tab.
  static const String mealPlan = 'plan.day';
  static const String latestReport = 'report.latest';
  static const String alerts = 'alerts';
  static const String account = 'account';
  static const String scheduledAlertsFingerprint = 'alerts.scheduled';

  /// Hydration is the one number the app owns.
  ///
  /// There is no endpoint for "how much water have I had today" — the API has a
  /// hydration *target* on the plan and nothing to log against it. Rather than
  /// invent a server number, the running total is kept here, on the phone,
  /// per calendar day, and shown as the user's own tally.
  static String hydrationFor(DateTime date) {
    final String y = date.year.toString().padLeft(4, '0');
    final String m = date.month.toString().padLeft(2, '0');
    final String d = date.day.toString().padLeft(2, '0');
    return 'hydration.$y-$m-$d';
  }
}

/// The real one: one table, one row per key.
class SqfliteOfflineCache implements OfflineCache {
  SqfliteOfflineCache({this.databaseName = 'healthpulse_cache.db'});

  final String databaseName;

  Database? _db;
  Future<Database>? _opening;

  static const String _table = 'cached_documents';

  Future<Database> _open() {
    final Database? existing = _db;
    if (existing != null) {
      return Future<Database>.value(existing);
    }
    return _opening ??= _openOnce();
  }

  Future<Database> _openOnce() async {
    final String directory = await getDatabasesPath();
    final Database db = await openDatabase(
      p.join(directory, databaseName),
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute(
          'CREATE TABLE $_table ('
          'cache_key TEXT PRIMARY KEY, '
          'body TEXT NOT NULL, '
          'stored_at INTEGER NOT NULL)',
        );
      },
    );
    _db = db;
    return db;
  }

  @override
  Future<Cached<Map<String, dynamic>>?> read(String key) async {
    try {
      final Database db = await _open();
      final List<Map<String, Object?>> rows = await db.query(
        _table,
        columns: <String>['body', 'stored_at'],
        where: 'cache_key = ?',
        whereArgs: <Object?>[key],
        limit: 1,
      );
      if (rows.isEmpty) {
        return null;
      }
      final Object? body = rows.first['body'];
      final Object? at = rows.first['stored_at'];
      if (body is! String || at is! int) {
        return null;
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) {
        return null;
      }
      return Cached<Map<String, dynamic>>(
        value: decoded.cast<String, dynamic>(),
        storedAt: DateTime.fromMillisecondsSinceEpoch(at),
      );
    } catch (_) {
      // A cache that cannot be read is a cache miss. It is never a reason to
      // fail a screen, and it is certainly never a reason to crash on launch.
      return null;
    }
  }

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> value, {
    DateTime? at,
  }) async {
    try {
      final Database db = await _open();
      await db.insert(
        _table,
        <String, Object?>{
          'cache_key': key,
          'body': jsonEncode(value),
          'stored_at': (at ?? DateTime.now()).millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // Failing to cache is not failing the request that produced the value.
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      final Database db = await _open();
      await db.delete(_table, where: 'cache_key = ?', whereArgs: <Object?>[key]);
    } catch (_) {
      // Nothing to do about it, and nothing worth telling the user.
    }
  }

  @override
  Future<void> clear() async {
    try {
      final Database db = await _open();
      await db.delete(_table);
    } catch (_) {
      // See above.
    }
  }

  @override
  Future<void> close() async {
    final Database? db = _db;
    _db = null;
    _opening = null;
    await db?.close();
  }
}

/// The one the tests use, and the one the app falls back to if sqflite will not
/// open. No platform channel, so it works in a plain `flutter test` too.
class MemoryOfflineCache implements OfflineCache {
  final Map<String, Cached<Map<String, dynamic>>> _entries =
      <String, Cached<Map<String, dynamic>>>{};

  @override
  Future<Cached<Map<String, dynamic>>?> read(String key) async => _entries[key];

  @override
  Future<void> write(
    String key,
    Map<String, dynamic> value, {
    DateTime? at,
  }) async {
    _entries[key] = Cached<Map<String, dynamic>>(
      // Copied through JSON so a later mutation of the caller's map cannot
      // change what is "cached", exactly as the sqflite one behaves.
      value: jsonDecode(jsonEncode(value)) as Map<String, dynamic>,
      storedAt: at ?? DateTime.now(),
    );
  }

  @override
  Future<void> remove(String key) async {
    _entries.remove(key);
  }

  @override
  Future<void> clear() async {
    _entries.clear();
  }

  @override
  Future<void> close() async {}
}
