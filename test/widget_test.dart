import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:journal/data/database.dart';
import 'package:journal/main.dart';
import 'package:journal/models/blocks.dart';

/// A text block containing a single plain paragraph.
TextBlockData textBlock(String text) => TextBlockData([
  {'insert': '$text\n'},
]);

void main() {
  group('AppDatabase', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('saveEntry stores blocks and blocksForEntry reads them in order', () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(
        day,
        blocks: [textBlock('first'), textBlock('second')],
      );

      final entry = await db.entryForDate(day);
      expect(entry, isNotNull);

      final rows = await db.blocksForEntry(entry!.id);
      expect(rows.map((r) => r.position), [0, 1]);
      final datas = rows.map((r) => BlockData.decode(r.type, r.data)).toList();
      expect(datas.map((d) => d.preview), ['first', 'second']);
    });

    test('re-saving replaces blocks rather than duplicating', () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(day, blocks: [textBlock('a'), textBlock('b')]);
      await db.saveEntry(day, blocks: [textBlock('only')]);

      final entries = await db.watchEntries().first;
      expect(entries, hasLength(1));

      final rows = await db.blocksForEntry(entries.single.id);
      expect(rows, hasLength(1));
      expect(BlockData.decode(rows.single.type, rows.single.data).preview, 'only');
    });

    test('saveEntry sets the denormalized preview from the first block', () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(day, blocks: [textBlock('Dear diary')]);
      final entry = await db.entryForDate(day);
      expect(entry!.preview, 'Dear diary');
    });

    test('an empty entry (no title, only empty blocks) is not persisted', () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(day, blocks: [TextBlockData.empty()]);
      expect(await db.entryForDate(day), isNull);
    });

    test('emptying an existing entry deletes it', () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(day, blocks: [textBlock('something')]);
      expect(await db.entryForDate(day), isNotNull);

      await db.saveEntry(day, blocks: [TextBlockData.empty()]);
      expect(await db.entryForDate(day), isNull);
    });

    test('a subnote block round-trips its collapsed state and height', () async {
      final day = DateTime(2026, 7, 10);
      final subnote = SubnoteBlockData(
        delta: [
          {'insert': 'aside\n'},
        ],
        collapsed: true,
        height: 220,
      );
      await db.saveEntry(day, blocks: [textBlock('main'), subnote]);

      final entry = await db.entryForDate(day);
      final rows = await db.blocksForEntry(entry!.id);
      final restored = BlockData.decode(rows[1].type, rows[1].data);
      expect(restored, isA<SubnoteBlockData>());
      restored as SubnoteBlockData;
      expect(restored.collapsed, isTrue);
      expect(restored.height, 220);
      expect(restored.preview, 'aside');
    });

    test('deleting an entry cascades to its blocks', () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(day, blocks: [textBlock('x'), textBlock('y')]);
      final entry = await db.entryForDate(day);

      await db.deleteEntry(entry!.id);
      expect(await db.blocksForEntry(entry.id), isEmpty);
    });

    test('entryForDate ignores the time component', () async {
      await db.saveEntry(DateTime(2026, 7, 10, 9, 30), blocks: [textBlock('morning')]);
      final entry = await db.entryForDate(DateTime(2026, 7, 10, 21, 0));
      expect(entry?.preview, 'morning');
    });
  });

  testWidgets('list screen renders empty state', (tester) async {
    // Drift's NativeDatabase does real (non-fake) async I/O, so the stream
    // query and close() must run on the real event loop via runAsync.
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());

      await tester.pumpWidget(MyApp(database: db));
      // Let the drift stream emit its first (empty) event, then rebuild past
      // the initial CircularProgressIndicator to the empty-state text.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.text('Journal'), findsOneWidget);
      expect(find.textContaining('No entries yet'), findsOneWidget);

      await db.close();
    });
  });
}
