import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:journal/data/database.dart';
import 'package:journal/models/blocks.dart';
import 'package:journal/screens/entry_editor_screen.dart';

Widget _host(AppDatabase db, DateTime day) => MaterialApp(
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    FlutterQuillLocalizations.delegate,
  ],
  supportedLocales: FlutterQuillLocalizations.supportedLocales,
  home: EntryEditorScreen(database: db, date: day),
);

/// Pumps the editor and lets its async `_load()` settle past the spinner.
Future<void> _openEditor(WidgetTester tester, AppDatabase db, DateTime day) async {
  await tester.pumpWidget(_host(db, day));
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  testWidgets('renders seeded text and subnote blocks', (tester) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(
        day,
        blocks: [
          textBlock('main hello'),
          SubnoteBlockData(
            delta: [
              {'insert': 'aside note\n'},
            ],
            collapsed: true,
          ),
        ],
      );

      await _openEditor(tester, db, day);

      // The collapsed subnote shows its preview in the header.
      expect(find.text('aside note'), findsOneWidget);
      // Collapsed subnote has no editor, so only the text block's editor shows.
      expect(find.byType(QuillEditor), findsOneWidget);

      await db.close();
    });
  });

  testWidgets('expanding a subnote reveals its editor and resize handle', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final day = DateTime(2026, 7, 10);
      await db.saveEntry(
        day,
        blocks: [
          textBlock('main'),
          SubnoteBlockData(
            delta: [
              {'insert': 'aside\n'},
            ],
            collapsed: true,
          ),
        ],
      );
      await _openEditor(tester, db, day);

      expect(find.byType(QuillEditor), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();

      // Now the subnote's editor is shown alongside the text block's.
      expect(find.byType(QuillEditor), findsNWidgets(2));
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

      await db.close();
    });
  });

}

/// A text block containing a single plain paragraph.
TextBlockData textBlock(String text) => TextBlockData([
  {'insert': '$text\n'},
]);
