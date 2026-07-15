import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../models/blocks.dart';
import '../models/elements.dart';

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

/// Legacy ordered-block table, superseded by [Elements]. Kept defined only so
/// the v3→v4 migration can read pre-canvas rows and fold them into the new
/// canvas model; no live code writes to it.
class Blocks extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get entryId =>
      integer().references(Entries, #id, onDelete: KeyAction.cascade)();

  /// 0-based order of this block within its entry.
  IntColumn get position => integer()();

  /// Block-kind discriminator, e.g. 'text' or 'subnote'.
  TextColumn get type => text()();

  /// JSON-encoded block payload.
  TextColumn get data => text()();
}

/// One element placed on an [Entries] canvas. Elements are absolutely
/// positioned at ([x], [y]), optionally sized ([width]/[height] — null for
/// strokes, which derive their bounds from their points), and layered by [z].
/// [type] discriminates the kind ('text', 'subnote', 'stroke', …) and [data]
/// holds its JSON content payload (see [ElementData]).
class Elements extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get entryId =>
      integer().references(Entries, #id, onDelete: KeyAction.cascade)();

  /// Canvas coordinates of the element's top-left corner, in logical pixels.
  RealColumn get x => real()();
  RealColumn get y => real()();

  /// Box size for text/subnote elements; null for strokes.
  RealColumn get width => real().nullable()();
  RealColumn get height => real().nullable()();

  /// Layer order; higher paints on top.
  IntColumn get z => integer().withDefault(const Constant(0))();

  /// Element-kind discriminator, e.g. 'text', 'subnote' or 'stroke'.
  TextColumn get type => text()();

  /// JSON-encoded [ElementData.toJson] payload for this element.
  TextColumn get data => text()();
}

@DriftDatabase(tables: [Entries, Blocks, Elements])
class AppDatabase extends _$AppDatabase {
  /// Pass a custom [executor] (e.g. an in-memory database) in tests; the app
  /// uses [driftDatabase] for platform-appropriate on-disk storage.
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'journal'));

  @override
  int get schemaVersion => 4;

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
      if (from < 4) await _migrateBlocksToElements(m);
    },
    // Required for the cascade deletes to take effect.
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// v3→v4: fold the ordered [Blocks] of every entry into positioned canvas
  /// [Elements], stacked vertically down the left of the canvas so migrated
  /// content lands somewhere sensible. Quill deltas are flattened to plain text
  /// (rich formatting is not carried into the plain-text-first canvas model).
  Future<void> _migrateBlocksToElements(Migrator m) async {
    await m.createTable(elements);
    const leftMargin = 24.0;
    const topMargin = 24.0;
    const gap = 16.0;
    const textWidth = 320.0;
    // Rough height estimate per element so stacked items don't overlap.
    double estimateHeight(String text, double fontSize) {
      final lines = (text.isEmpty ? 1 : '\n'.allMatches(text).length + 1);
      return (lines * fontSize * 1.4 + 24).clamp(48.0, 400.0);
    }

    final legacyBlocks =
        await (select(blocks)..orderBy([
              (t) => OrderingTerm.asc(t.entryId),
              (t) => OrderingTerm.asc(t.position),
            ]))
            .get();

    int? currentEntry;
    double y = topMargin;
    for (final b in legacyBlocks) {
      if (b.entryId != currentEntry) {
        currentEntry = b.entryId;
        y = topMargin;
      }
      final json = jsonDecode(b.data) as Map<String, dynamic>;
      final delta = (json['delta'] as List?) ?? const [];
      final text = plainTextFromDelta(delta);
      if (text.trim().isEmpty) continue;

      final ElementData data;
      final double fontSize;
      if (b.type == SubnoteBlockData.kType) {
        fontSize = SubnoteElementData.defaultFontSize;
        data = SubnoteElementData(
          text: text,
          collapsed: (json['collapsed'] as bool?) ?? false,
        );
      } else {
        fontSize = TextElementData.defaultFontSize;
        data = TextElementData(text: text);
      }
      final h = estimateHeight(text, fontSize);
      await into(elements).insert(
        ElementsCompanion.insert(
          entryId: b.entryId,
          x: leftMargin,
          y: y,
          width: Value(b.type == SubnoteBlockData.kType ? SubnoteElementData.defaultWidth : textWidth),
          height: Value(h),
          type: data.type,
          data: jsonEncode(data.toJson()),
        ),
      );
      y += h + gap;
    }
  }

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

  /// The canvas elements of [entryId], in [Elements.z] (layer) order.
  Future<List<Element>> elementsForEntry(int entryId) {
    return (select(elements)
          ..where((t) => t.entryId.equals(entryId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.z),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .get();
  }

  /// Persists the entry for [day]: its [title] and its canvas [elements].
  ///
  /// Empty elements are dropped. If nothing meaningful remains (no title and no
  /// non-empty element) the entry is deleted (or never created), mirroring the
  /// old empty-entry cleanup.
  ///
  /// Persistence is a **diff**, not a wholesale rewrite: an element with a known
  /// [PlacedElement.id] updates that row (and only if its columns actually
  /// changed), a new element is inserted and has its id written back, and rows
  /// no longer present are deleted. Unchanged elements — notably strokes with
  /// large point lists — are never re-serialized to disk, and a save with no
  /// real change performs zero writes.
  Future<void> saveEntry(
    DateTime day, {
    String? title,
    required List<PlacedElement> elements,
  }) {
    final key = dateOnly(day);
    final normalizedTitle = (title == null || title.trim().isEmpty)
        ? null
        : title.trim();
    final kept = elements.where((e) => !e.data.isEmpty).toList();

    return transaction(() async {
      final existing = await entryForDate(key);

      if (kept.isEmpty && normalizedTitle == null) {
        if (existing != null) await deleteEntry(existing.id);
        for (final e in elements) {
          e.id = null;
        }
        return;
      }

      final preview = _previewFor(kept);
      final int entryId;
      // Tracks whether anything changed, so the entry row (and its updatedAt)
      // is only touched when there's a real edit.
      var changed = false;
      if (existing == null) {
        entryId = await into(entries).insert(
          EntriesCompanion.insert(
            date: key,
            title: Value(normalizedTitle),
            preview: Value(preview),
          ),
        );
        changed = true;
      } else {
        entryId = existing.id;
      }

      // Current rows for this entry, keyed by id, to diff against.
      final currentRows =
          await (select(this.elements)
                ..where((t) => t.entryId.equals(entryId)))
              .get();
      final byId = {for (final r in currentRows) r.id: r};
      final keptIds = <int>{};

      for (final el in elements) {
        if (el.data.isEmpty) {
          // Not persisted; its old row (if any) is removed in the sweep below.
          el.id = null;
          continue;
        }
        final dataJson = jsonEncode(el.data.toJson());
        final row = el.id == null ? null : byId[el.id];
        if (row != null) {
          keptIds.add(el.id!);
          if (_rowDiffers(row, el, dataJson)) {
            await (update(this.elements)
                  ..where((t) => t.id.equals(el.id!)))
                .write(
                  ElementsCompanion(
                    x: Value(el.x),
                    y: Value(el.y),
                    width: Value(el.width),
                    height: Value(el.height),
                    z: Value(el.z),
                    type: Value(el.data.type),
                    data: Value(dataJson),
                  ),
                );
            changed = true;
          }
        } else {
          final newId = await into(this.elements).insert(
            ElementsCompanion.insert(
              entryId: entryId,
              x: el.x,
              y: el.y,
              width: Value(el.width),
              height: Value(el.height),
              z: Value(el.z),
              type: el.data.type,
              data: dataJson,
            ),
          );
          el.id = newId;
          keptIds.add(newId);
          changed = true;
        }
      }

      final toDelete = byId.keys.toSet().difference(keptIds);
      if (toDelete.isNotEmpty) {
        await (delete(this.elements)..where((t) => t.id.isIn(toDelete))).go();
        changed = true;
      }

      // Only rewrite the entry row (bumping updatedAt) when something actually
      // changed — a no-op save leaves the whole table untouched.
      if (existing != null &&
          (changed ||
              existing.title != normalizedTitle ||
              existing.preview != preview)) {
        await (update(entries)..where((t) => t.id.equals(entryId))).write(
          EntriesCompanion(
            title: Value(normalizedTitle),
            preview: Value(preview),
            updatedAt: Value(DateTime.now()),
          ),
        );
      }
    });
  }

  /// Whether [row] on disk differs from the in-memory [el]/[dataJson] in any
  /// persisted column, i.e. whether an UPDATE is actually needed.
  static bool _rowDiffers(Element row, PlacedElement el, String dataJson) =>
      row.x != el.x ||
      row.y != el.y ||
      row.width != el.width ||
      row.height != el.height ||
      row.z != el.z ||
      row.type != el.data.type ||
      row.data != dataJson;

  Future<void> deleteEntry(int id) {
    return (delete(entries)..where((t) => t.id.equals(id))).go();
  }

  /// First non-empty element preview, capped to a reasonable length.
  static String _previewFor(List<PlacedElement> elements) {
    for (final el in elements) {
      final p = el.data.preview.trim();
      if (p.isNotEmpty) return p.length > 140 ? p.substring(0, 140) : p;
    }
    return '';
  }
}
