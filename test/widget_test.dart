import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:journal/data/database.dart';
import 'package:journal/main.dart';
import 'package:journal/models/elements.dart';

/// A placed text element containing [text].
PlacedElement textEl(String text, {double x = 0, double y = 0, int z = 0}) =>
    PlacedElement(
      x: x,
      y: y,
      width: 200,
      z: z,
      data: TextElementData(text: text),
    );

void main() {
  group('AppDatabase', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('saveEntry stores elements; elementsForEntry reads them in z order',
        () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(
        day,
        elements: [
          textEl('second', y: 100, z: 1),
          textEl('first', y: 0, z: 0),
        ],
      );

      final entry = await db.entryForDate(day);
      expect(entry, isNotNull);

      final rows = await db.elementsForEntry(entry!.id);
      final datas = rows.map((r) => ElementData.decode(r.type, r.data)).toList();
      expect(datas.map((d) => d.preview), ['first', 'second']);
    });

    test('re-saving replaces elements rather than duplicating', () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(day, elements: [textEl('a'), textEl('b')]);
      await db.saveEntry(day, elements: [textEl('only')]);

      final entries = await db.watchEntries().first;
      expect(entries, hasLength(1));

      final rows = await db.elementsForEntry(entries.single.id);
      expect(rows, hasLength(1));
      expect(ElementData.decode(rows.single.type, rows.single.data).preview,
          'only');
    });

    test('saveEntry sets the denormalized preview from the first element',
        () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(day, elements: [textEl('Dear diary')]);
      final entry = await db.entryForDate(day);
      expect(entry!.preview, 'Dear diary');
    });

    test('an empty entry (no title, only empty elements) is not persisted',
        () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(day, elements: [textEl('')]);
      expect(await db.entryForDate(day), isNull);
    });

    test('emptying an existing entry deletes it', () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(day, elements: [textEl('something')]);
      expect(await db.entryForDate(day), isNotNull);

      await db.saveEntry(day, elements: [textEl('')]);
      expect(await db.entryForDate(day), isNull);
    });

    test('a subnote element round-trips its collapsed state and position',
        () async {
      final day = DateTime(2026, 7, 10);
      final subnote = PlacedElement(
        x: 40,
        y: 60,
        width: 180,
        height: 220,
        z: 2,
        data: SubnoteElementData(text: 'aside', collapsed: true),
      );
      await db.saveEntry(day, elements: [textEl('main'), subnote]);

      final entry = await db.entryForDate(day);
      final rows = await db.elementsForEntry(entry!.id);
      final restoredRow = rows.firstWhere((r) => r.type == SubnoteElementData.kType);
      expect(restoredRow.x, 40);
      expect(restoredRow.y, 60);
      final restored = ElementData.decode(restoredRow.type, restoredRow.data);
      expect(restored, isA<SubnoteElementData>());
      restored as SubnoteElementData;
      expect(restored.collapsed, isTrue);
      expect(restored.preview, 'aside');
    });

    test('a stroke element round-trips its points, color and width', () async {
      final day = DateTime(2026, 7, 10);
      final stroke = PlacedElement(
        x: 10,
        y: 10,
        width: 20,
        height: 20,
        data: StrokeElementData(
          points: const [Offset(0, 0), Offset(10, 10), Offset(20, 5)],
          color: 0xFFD32F2F,
          width: 4,
        ),
      );
      // Pair it with text so the entry is persisted (strokes have no preview).
      await db.saveEntry(day, elements: [textEl('note'), stroke]);

      final entry = await db.entryForDate(day);
      final rows = await db.elementsForEntry(entry!.id);
      final row = rows.firstWhere((r) => r.type == StrokeElementData.kType);
      final restored =
          ElementData.decode(row.type, row.data) as StrokeElementData;
      expect(restored.points, hasLength(3));
      expect(restored.points.last, const Offset(20, 5));
      expect(restored.color, 0xFFD32F2F);
      expect(restored.width, 4);
    });

    test('deleting an entry cascades to its elements', () async {
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(day, elements: [textEl('x'), textEl('y')]);
      final entry = await db.entryForDate(day);

      await db.deleteEntry(entry!.id);
      expect(await db.elementsForEntry(entry.id), isEmpty);
    });

    test('entryForDate ignores the time component', () async {
      await db.saveEntry(DateTime(2026, 7, 10, 9, 30),
          elements: [textEl('morning')]);
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
