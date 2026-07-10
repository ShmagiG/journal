import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:journal/data/database.dart';
import 'package:journal/main.dart';

void main() {
  group('AppDatabase', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('upsertEntry stores and entryForDate reads it back', () async {
      final day = DateTime(2026, 7, 10);
      await db.upsertEntry(day, 'Hello journal');

      final entry = await db.entryForDate(day);
      expect(entry, isNotNull);
      expect(entry!.body, 'Hello journal');
    });

    test('re-saving the same day updates rather than duplicates', () async {
      final day = DateTime(2026, 7, 10);
      await db.upsertEntry(day, 'first');
      await db.upsertEntry(day, 'second');

      final entries = await db.watchEntries().first;
      expect(entries, hasLength(1));
      expect(entries.single.body, 'second');
    });

    test('entryForDate ignores the time component', () async {
      await db.upsertEntry(DateTime(2026, 7, 10, 9, 30), 'morning');
      final entry = await db.entryForDate(DateTime(2026, 7, 10, 21, 0));
      expect(entry?.body, 'morning');
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
