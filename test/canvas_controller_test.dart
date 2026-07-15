import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:journal/data/database.dart';
import 'package:journal/models/elements.dart';
import 'package:journal/screens/canvas_controller.dart';

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
}
