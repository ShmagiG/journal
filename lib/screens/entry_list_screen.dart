import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import 'entry_editor_screen.dart';

/// Home screen: lists every day that has a journal entry, newest first.
class EntryListScreen extends StatelessWidget {
  const EntryListScreen({super.key, required this.database});

  final AppDatabase database;

  Future<void> _openEditor(BuildContext context, DateTime date) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EntryEditorScreen(database: database, date: date),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Journal')),
      body: StreamBuilder<List<Entry>>(
        stream: database.watchEntries(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data!;
          if (entries.isEmpty) {
            return const Center(
              child: Text('No entries yet.\nTap + to write today\'s note.',
                textAlign: TextAlign.center),
            );
          }
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final dateLabel = DateFormat.yMMMMEEEEd().format(entry.date);
              final label = (entry.title?.trim().isNotEmpty ?? false)
                  ? '$dateLabel · ${entry.title!.trim()}'
                  : dateLabel;
              return ListTile(
                title: Text(label),
                subtitle: entry.body.trim().isEmpty
                    ? null
                    : Text(
                        entry.body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => _openEditor(context, entry.date),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(context, DateTime.now()),
        tooltip: 'Today\'s note',
        child: const Icon(Icons.add),
      ),
    );
  }
}
