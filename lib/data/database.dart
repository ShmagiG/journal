import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// A single journal entry. There is at most one entry per calendar day, keyed
/// by [date] (normalized to local midnight). For now an entry holds a single
/// plain-text [body]; richer mixed-content blocks are a future addition.
class Entries extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The day this entry belongs to, normalized to local midnight. Unique so
  /// that each day has exactly one entry.
  DateTimeColumn get date => dateTime().unique()();

  TextColumn get body => text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

@DriftDatabase(tables: [Entries])
class AppDatabase extends _$AppDatabase {
  /// Pass a custom [executor] (e.g. an in-memory database) in tests; the app
  /// uses [driftDatabase] for platform-appropriate on-disk storage.
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'journal'));

  @override
  int get schemaVersion => 1;

  /// Strips the time component, giving the local-midnight key for a day.
  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// All entries, newest day first.
  Stream<List<Entry>> watchEntries() {
    return (select(entries)
      ..orderBy([(t) => OrderingTerm.desc(t.date)])).watch();
  }

  /// The entry for [day], or null if none exists yet.
  Future<Entry?> entryForDate(DateTime day) {
    final key = dateOnly(day);
    return (select(entries)..where((t) => t.date.equals(key))).getSingleOrNull();
  }

  /// Creates or updates the entry for [day] with [body].
  Future<void> upsertEntry(DateTime day, String body) {
    final key = dateOnly(day);
    return transaction(() async {
      final existing = await entryForDate(key);
      if (existing == null) {
        await into(entries).insert(
          EntriesCompanion.insert(date: key, body: Value(body)),
        );
      } else {
        await (update(entries)..where((t) => t.id.equals(existing.id))).write(
          EntriesCompanion(body: Value(body), updatedAt: Value(DateTime.now())),
        );
      }
    });
  }

  Future<void> deleteEntry(int id) {
    return (delete(entries)..where((t) => t.id.equals(id))).go();
  }
}
