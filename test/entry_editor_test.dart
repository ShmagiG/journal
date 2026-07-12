import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:journal/data/database.dart';
import 'package:journal/models/elements.dart';
import 'package:journal/screens/entry_editor_screen.dart';

Widget _host(AppDatabase db, DateTime day) =>
    MaterialApp(home: EntryEditorScreen(database: db, date: day));

/// Pumps the editor and lets its async `_load()` settle past the spinner.
Future<void> _openEditor(WidgetTester tester, AppDatabase db, DateTime day) async {
  await tester.pumpWidget(_host(db, day));
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  testWidgets('renders a seeded text box and a collapsed subnote', (tester) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(
        day,
        elements: [
          PlacedElement(
            x: 20,
            y: 20,
            width: 200,
            data: TextElementData(text: 'main hello'),
          ),
          PlacedElement(
            x: 240,
            y: 20,
            width: 180,
            height: 120,
            data: SubnoteElementData(text: 'aside note', collapsed: true),
          ),
        ],
      );

      await _openEditor(tester, db, day);

      // The text element shows its content, and the collapsed subnote shows its
      // preview in the header.
      expect(find.text('main hello'), findsOneWidget);
      expect(find.text('aside note'), findsOneWidget);
      // Collapsed: header shows a right chevron.
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await db.close();
    });
  });

  testWidgets('expanding a collapsed subnote flips its header chevron', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(
        day,
        elements: [
          PlacedElement(
            x: 40,
            y: 40,
            width: 180,
            height: 120,
            data: SubnoteElementData(text: 'aside', collapsed: true),
          ),
        ],
      );
      await _openEditor(tester, db, day);

      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();

      // Expanded now: chevron points down.
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);

      await db.close();
    });
  });

  testWidgets('the draw tool exposes pen options', (tester) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      await _openEditor(tester, db, DateTime(2026, 7, 10));

      // Switch to the draw tool; a pen width slider should appear.
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pump();
      expect(find.byType(Slider), findsOneWidget);

      await db.close();
    });
  });
}
