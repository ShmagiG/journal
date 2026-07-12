import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:journal/data/database.dart';
import 'package:journal/models/elements.dart';
import 'package:journal/screens/entry_editor_screen.dart';

Widget _host(AppDatabase db, DateTime day) =>
    MaterialApp(home: EntryEditorScreen(database: db, date: day));

/// Presses Ctrl(+Shift)+[key].
Future<void> _pressCtrl(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

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
      final day = DateTime.now();
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
      final day = DateTime.now();
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

  testWidgets('tapping a text box lets you edit its text', (tester) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final day = DateTime.now();
      await db.saveEntry(
        day,
        elements: [
          PlacedElement(
            x: 30,
            y: 30,
            width: 220,
            data: TextElementData(text: 'hello'),
          ),
        ],
      );
      await _openEditor(tester, db, day);

      final field = find.widgetWithText(TextField, 'hello');
      expect(field, findsOneWidget);

      // Editing happens under the text tool; select mode is for moving.
      await tester.tap(find.byIcon(Icons.text_fields));
      await tester.pump();

      await tester.tap(field);
      await tester.pump();
      // enterText only succeeds on an editable (non-readOnly, focusable) field.
      await tester.enterText(field, 'hello world');
      await tester.pump();

      expect(find.text('hello world'), findsOneWidget);

      await db.close();
    });
  });

  testWidgets('in select mode a text box is moved by dragging its body', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final day = DateTime.now();
      await db.saveEntry(
        day,
        elements: [
          PlacedElement(
            x: 30,
            y: 30,
            width: 200,
            data: TextElementData(text: 'move me'),
          ),
          PlacedElement(
            x: 30,
            y: 260,
            width: 200,
            data: TextElementData(text: 'stay put'),
          ),
        ],
      );
      await _openEditor(tester, db, day);

      // Default tool is select; tapping selects (frame + resize handle appear).
      await tester.tap(find.text('move me'));
      await tester.pump();
      expect(find.byIcon(Icons.open_in_full), findsOneWidget);

      final before = tester.getTopLeft(find.text('move me'));
      final otherBefore = tester.getTopLeft(find.text('stay put'));

      await tester.drag(find.text('move me'), const Offset(50, 40));
      await tester.pump();

      final after = tester.getTopLeft(find.text('move me'));
      final otherAfter = tester.getTopLeft(find.text('stay put'));

      // The dragged box moved...
      expect(after.dx, greaterThan(before.dx));
      expect(after.dy, greaterThan(before.dy));
      // ...and the canvas did NOT pan (the other box stayed put).
      expect(otherAfter, otherBefore);

      await db.close();
    });
  });

  testWidgets('an empty text box is discarded when it loses focus', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      await _openEditor(tester, db, DateTime.now());

      // Text tool, then tap empty canvas to create a new (empty) box.
      await tester.tap(find.byIcon(Icons.text_fields));
      await tester.pump();
      await tester.tapAt(const Offset(400, 450));
      await tester.pump();
      expect(find.text('Write…'), findsOneWidget);

      // Switch tools (which drops focus). The untouched empty box is discarded.
      await tester.tap(find.byIcon(Icons.pan_tool_alt_outlined));
      await tester.pump();
      expect(find.text('Write…'), findsNothing);

      await db.close();
    });
  });

  testWidgets('a subnote can be dragged by its header to move it', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final day = DateTime.now();
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

      // Select tool is the default; the drag handle lives in the header.
      final before = tester.getTopLeft(find.text('aside'));
      await tester.drag(find.byIcon(Icons.drag_indicator), const Offset(60, 30));
      await tester.pump();
      final after = tester.getTopLeft(find.text('aside'));

      expect(after.dx, greaterThan(before.dx));
      expect(after.dy, greaterThan(before.dy));

      await db.close();
    });
  });

  testWidgets('the timestamp button inserts HH:mm:ss on a new line', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final day = DateTime.now();
      await db.saveEntry(
        day,
        elements: [
          PlacedElement(
            x: 30,
            y: 30,
            width: 220,
            data: TextElementData(text: 'note'),
          ),
        ],
      );
      await _openEditor(tester, db, day);

      // Focus the box under the text tool, then insert the timestamp.
      await tester.tap(find.byIcon(Icons.text_fields));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextField, 'note'));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.schedule));
      await tester.pump();

      expect(
        find.textContaining(RegExp(r'note\n\d{2}:\d{2}:\d{2}\n')),
        findsOneWidget,
      );

      await db.close();
    });
  });

  testWidgets('Ctrl+D / Ctrl+T / Ctrl+M switch tools and Ctrl+N adds a subnote',
      (tester) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      await _openEditor(tester, db, DateTime.now());

      // Ctrl+D → draw tool (pen options appear).
      await _pressCtrl(tester, LogicalKeyboardKey.keyD);
      expect(find.byType(Slider), findsOneWidget);

      // Ctrl+M → select tool (pen options gone).
      await _pressCtrl(tester, LogicalKeyboardKey.keyM);
      expect(find.byType(Slider), findsNothing);

      // Ctrl+T → text tool: tapping empty canvas now creates a text box.
      await _pressCtrl(tester, LogicalKeyboardKey.keyT);
      await tester.tapAt(const Offset(400, 450));
      await tester.pump();
      expect(find.text('Write…'), findsOneWidget);

      // Ctrl+N → adds a subnote (its header appears).
      await _pressCtrl(tester, LogicalKeyboardKey.keyN);
      expect(find.text('Subnote'), findsOneWidget);

      await db.close();
    });
  });

  testWidgets('Ctrl+Shift+T inserts a timestamp without switching tools', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final day = DateTime.now();
      await db.saveEntry(
        day,
        elements: [
          PlacedElement(
            x: 30,
            y: 30,
            width: 220,
            data: TextElementData(text: 'note'),
          ),
        ],
      );
      await _openEditor(tester, db, day);

      // Focus the box under the text tool (Ctrl+T), then stamp with Ctrl+Shift+T.
      await _pressCtrl(tester, LogicalKeyboardKey.keyT);
      await tester.tap(find.widgetWithText(TextField, 'note'));
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyT, shift: true);

      expect(
        find.textContaining(RegExp(r'note\n\d{2}:\d{2}:\d{2}\n')),
        findsOneWidget,
      );

      await db.close();
    });
  });

  testWidgets('a past day is read-only: no tools, text not editable', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final past = DateTime.now().subtract(const Duration(days: 2));
      await db.saveEntry(
        past,
        elements: [
          PlacedElement(
            x: 30,
            y: 30,
            width: 220,
            data: TextElementData(text: 'old entry'),
          ),
        ],
      );
      await _openEditor(tester, db, past);

      // Content still renders, but the authoring tools are gone.
      expect(find.text('old entry'), findsOneWidget);
      expect(find.textContaining('Read-only'), findsOneWidget);
      expect(find.byIcon(Icons.text_fields), findsNothing);
      expect(find.byIcon(Icons.edit), findsNothing);
      expect(find.byIcon(Icons.sticky_note_2_outlined), findsNothing);

      // The text cannot be changed.
      final field = find.widgetWithText(TextField, 'old entry');
      await tester.enterText(field, 'tampered');
      await tester.pump();
      expect(find.text('old entry'), findsOneWidget);
      expect(find.text('tampered'), findsNothing);

      // Tapping it does not select it (no move/resize handles appear).
      await tester.tap(field, warnIfMissed: false);
      await tester.pump();
      expect(find.byIcon(Icons.open_in_full), findsNothing);

      await db.close();
    });
  });

  testWidgets('the draw tool exposes pen options', (tester) async {
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      await _openEditor(tester, db, DateTime.now());

      // Switch to the draw tool; a pen width slider should appear.
      await tester.tap(find.byIcon(Icons.edit));
      await tester.pump();
      expect(find.byType(Slider), findsOneWidget);

      await db.close();
    });
  });
}
