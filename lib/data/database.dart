import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../models/blocks.dart';

part 'database.g.dart';

/// A single journal entry. There is at most one entry per calendar day, keyed
/// by [date] (normalized to local midnight). An entry's content is an ordered
/// list of rows in the [Blocks] table; [preview] is a denormalized plain-text
/// snippet kept in sync on save so the entry list can render without loading
/// every block.
class Entries extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The day this entry belongs to, normalized to local midnight. Unique so
  /// that each day has exactly one entry.
  DateTimeColumn get date => dateTime().unique()();

  /// An optional user-provided name for the entry, shown next to the date.
  /// Null when the user hasn't named the entry.
  TextColumn get title => text().nullable()();

  /// Legacy single-body content. Superseded by the [Blocks] table; retained so
  /// existing rows migrate cleanly (SQLite can't drop a column in place).
  TextColumn get body => text().withDefault(const Constant(''))();

  /// Denormalized plain-text preview of the first non-empty block, for the list.
  TextColumn get preview => text().withDefault(const Constant(''))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// One content block belonging to an [Entries] row. Blocks are ordered by
/// [position]; [type] discriminates the block kind ('text', 'subnote', …) and
/// [data] holds its JSON payload (see [BlockData]).
class Blocks extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get entryId =>
      integer().references(Entries, #id, onDelete: KeyAction.cascade)();

  /// 0-based order of this block within its entry.
  IntColumn get position => integer()();

  /// Block-kind discriminator, e.g. 'text' or 'subnote'.
  TextColumn get type => text()();

  /// JSON-encoded [BlockData.toJson] payload for this block.
  TextColumn get data => text()();
}

@DriftDatabase(tables: [Entries, Blocks])
class AppDatabase extends _$AppDatabase {
  /// Pass a custom [executor] (e.g. an in-memory database) in tests; the app
  /// uses [driftDatabase] for platform-appropriate on-disk storage.
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'journal'));

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.addColumn(entries, entries.title);
      if (from < 3) {
        await m.createTable(blocks);
        await m.addColumn(entries, entries.preview);
        // Fold each legacy plain-text body into a single position-0 text block.
        final rows = await select(entries).get();
        for (final e in rows) {
          if (e.body.trim().isEmpty) continue;
          final text = e.body.endsWith('\n') ? e.body : '${e.body}\n';
          final delta = <dynamic>[
            {'insert': text},
          ];
          await into(blocks).insert(
            BlocksCompanion.insert(
              entryId: e.id,
              position: 0,
              type: TextBlockData.kType,
              data: jsonEncode({'delta': delta}),
            ),
          );
          await (update(entries)..where((t) => t.id.equals(e.id))).write(
            EntriesCompanion(preview: Value(plainTextFromDelta(delta))),
          );
        }
      }
    },
    // Required for the Blocks -> Entries cascade delete to take effect.
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

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

  /// The blocks of [entryId], in [Blocks.position] order.
  Future<List<Block>> blocksForEntry(int entryId) {
    return (select(blocks)
          ..where((t) => t.entryId.equals(entryId))
          ..orderBy([(t) => OrderingTerm.asc(t.position)]))
        .get();
  }

  /// Persists the entry for [day]: its [title] and the ordered [blocks].
  ///
  /// Empty blocks are dropped. If nothing meaningful remains (no title and no
  /// non-empty block) the entry is deleted (or never created), mirroring the
  /// old empty-entry cleanup. Blocks are rewritten wholesale in one
  /// transaction, so insert/delete/reorder all persist uniformly.
  Future<void> saveEntry(
    DateTime day, {
    String? title,
    required List<BlockData> blocks,
  }) {
    final key = dateOnly(day);
    final normalizedTitle = (title == null || title.trim().isEmpty)
        ? null
        : title.trim();
    final kept = blocks.where((b) => !b.isEmpty).toList();

    return transaction(() async {
      final existing = await entryForDate(key);

      if (kept.isEmpty && normalizedTitle == null) {
        if (existing != null) await deleteEntry(existing.id);
        return;
      }

      final preview = _previewFor(kept);
      final int entryId;
      if (existing == null) {
        entryId = await into(entries).insert(
          EntriesCompanion.insert(
            date: key,
            title: Value(normalizedTitle),
            preview: Value(preview),
          ),
        );
      } else {
        entryId = existing.id;
        await (update(entries)..where((t) => t.id.equals(entryId))).write(
          EntriesCompanion(
            title: Value(normalizedTitle),
            preview: Value(preview),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }

      await (delete(this.blocks)..where((t) => t.entryId.equals(entryId))).go();
      for (var i = 0; i < kept.length; i++) {
        final block = kept[i];
        await into(this.blocks).insert(
          BlocksCompanion.insert(
            entryId: entryId,
            position: i,
            type: block.type,
            data: jsonEncode(block.toJson()),
          ),
        );
      }
    });
  }

  Future<void> deleteEntry(int id) {
    return (delete(entries)..where((t) => t.id.equals(id))).go();
  }

  /// First non-empty block preview, capped to a reasonable length.
  static String _previewFor(List<BlockData> blocks) {
    for (final block in blocks) {
      final p = block.preview.trim();
      if (p.isNotEmpty) return p.length > 140 ? p.substring(0, 140) : p;
    }
    return '';
  }
}
