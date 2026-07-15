import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:journal/data/database.dart';
import 'package:journal/models/elements.dart';
import 'package:journal/screens/canvas_controller.dart';

// Pointer events in surface coordinates for a given canvas coordinate.
PointerDownEvent _down(Offset c) => PointerDownEvent(position: canvasOrigin + c);
PointerMoveEvent _move(Offset c) => PointerMoveEvent(position: canvasOrigin + c);
PointerUpEvent _up(Offset c) => PointerUpEvent(position: canvasOrigin + c);

Future<List<String>> _texts(AppDatabase db, DateTime day) async {
  final entry = await db.entryForDate(day);
  if (entry == null) return const [];
  return [
    for (final r in await db.elementsForEntry(entry.id))
      if (ElementData.decode(r.type, r.data) is TextElementData)
        (ElementData.decode(r.type, r.data) as TextElementData).text,
  ];
}

void main() {
  // The controller schedules post-frame callbacks (focus) and creates
  // FocusNodes, so it needs a binding — but no widget tree is pumped.
  TestWidgetsFlutterBinding.ensureInitialized();

  CanvasController makeController(AppDatabase db, DateTime day) =>
      CanvasController(
        database: db,
        date: day,
        scale: () => 1.0,
        readTitle: () => '',
        requestCanvasFocus: () {},
        showMessage: (_) {},
      );

  test(
    'add → edit → save → delete, driven purely through the controller',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final day = DateTime.now();
      final controller = makeController(db, day);

      await controller.load();
      expect(controller.loading, isFalse);
      expect(controller.readOnly, isFalse, reason: 'today is editable');

      // Add a text box and type into it.
      controller.addTextAt(const Offset(40, 40));
      final el = controller.elements.single;
      el.textController!.text = 'hello from the controller';
      controller.edit();
      await controller.save();

      expect(await _texts(db, day), ['hello from the controller']);

      // Deleting the only element leaves the entry empty, so it is removed.
      controller.select(el);
      controller.deleteSelected();
      await controller.save();
      expect(await _texts(db, day), isEmpty);

      controller.dispose();
      await db.close();
    },
  );

  test('a past day is read-only and never persists edits', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final past = DateTime.now().subtract(const Duration(days: 3));
    final controller = makeController(db, past);
    await controller.load();

    expect(controller.readOnly, isTrue);
    // Mutations are refused on a read-only entry.
    controller.addSubnote(at: const Offset(0, 0));
    expect(controller.elements, isEmpty);

    controller.dispose();
    await db.close();
  });

  test('toggleSelected builds a multi-selection; select replaces it', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final controller = makeController(db, DateTime.now());
    await controller.load();

    controller.addTextAt(const Offset(40, 40));
    final a = controller.elements.last;
    controller.addTextAt(const Offset(40, 400));
    final b = controller.elements.last;

    controller.select(a);
    controller.toggleSelected(b);
    expect(controller.selection, {a, b});
    // With two selected there is no single "selected" element for the toolbar.
    expect(controller.selected, isNull);

    controller.toggleSelected(b);
    expect(controller.selection, {a});
    expect(controller.selected, a);

    // A plain select collapses back to a single element.
    controller.select(b);
    expect(controller.selection, {b});

    controller.dispose();
    await db.close();
  });

  test('dragging one of several selected moves the whole group', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final controller = makeController(db, DateTime.now());
    await controller.load();

    controller.addTextAt(const Offset(40, 40));
    final a = controller.elements.last;
    controller.addTextAt(const Offset(40, 400));
    final b = controller.elements.last;

    controller.select(a);
    controller.toggleSelected(b);
    controller.drag(a, const Offset(10, 20)); // scale is 1 in tests

    expect(a.x, 50);
    expect(a.y, 60);
    expect(b.x, 50);
    expect(b.y, 420);

    controller.dispose();
    await db.close();
  });

  test('marquee selects elements whose bounds intersect the box', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final controller = makeController(db, DateTime.now());
    await controller.load();

    controller.addTextAt(const Offset(40, 40));
    final a = controller.elements.last; // bounds ~ (40,40,220,~38)
    controller.addTextAt(const Offset(40, 400));
    final b = controller.elements.last; // far below the box

    controller.setTool(Tool.marquee);
    controller.onPointerDown(_down(const Offset(0, 0)));
    controller.onPointerMove(_move(const Offset(300, 100)));
    controller.onPointerUp(_up(const Offset(300, 100)));

    expect(controller.selection, {a});
    expect(controller.isSelected(b), isFalse);
    // The sweep drops back into select mode so the selection can be moved.
    expect(controller.tool, Tool.select);

    controller.dispose();
    await db.close();
  });

  test('lasso selects elements whose centre is inside the path', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final controller = makeController(db, DateTime.now());
    await controller.load();

    controller.addTextAt(const Offset(40, 40));
    final a = controller.elements.last;
    controller.addTextAt(const Offset(40, 400));
    final b = controller.elements.last;

    // A closed loop drawn around box A (well above B).
    controller.setTool(Tool.lasso);
    controller.onPointerDown(_down(const Offset(0, 0)));
    controller.onPointerMove(_move(const Offset(300, 0)));
    controller.onPointerMove(_move(const Offset(300, 120)));
    controller.onPointerMove(_move(const Offset(0, 120)));
    controller.onPointerUp(_up(const Offset(0, 120)));

    expect(controller.selection, {a});
    expect(controller.isSelected(b), isFalse);
    expect(controller.tool, Tool.select);

    controller.dispose();
    await db.close();
  });

  test('deleteSelected removes every selected element', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final day = DateTime.now();
    final controller = makeController(db, day);
    await controller.load();

    controller.addTextAt(const Offset(40, 40));
    final a = controller.elements.last;
    a.textController!.text = 'a';
    controller.addTextAt(const Offset(40, 400));
    final b = controller.elements.last;
    b.textController!.text = 'b';

    controller.select(a);
    controller.toggleSelected(b);
    controller.deleteSelected();

    expect(controller.elements, isEmpty);
    expect(controller.selection, isEmpty);

    controller.dispose();
    await db.close();
  });
}
