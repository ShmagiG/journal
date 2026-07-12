import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';

/// Write or edit the single journal entry for a given [date].
class EntryEditorScreen extends StatefulWidget {
  const EntryEditorScreen({
    super.key,
    required this.database,
    required this.date,
  });

  final AppDatabase database;
  final DateTime date;

  @override
  State<EntryEditorScreen> createState() => _EntryEditorScreenState();
}

class _EntryEditorScreenState extends State<EntryEditorScreen> {
  final _controller = TextEditingController();
  final _titleController = TextEditingController();
  Entry? _entry;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entry = await widget.database.entryForDate(widget.date);
    if (!mounted) return;
    setState(() {
      _entry = entry;
      _controller.text = entry?.body ?? '';
      _titleController.text = entry?.title ?? '';
      _loading = false;
    });
  }

  /// Persists the current text. Avoids creating an empty row for a brand-new
  /// day, and removes an existing entry that has been emptied out. An entry is
  /// kept when it has a title or a body; only when both are empty is it deleted.
  Future<void> _save() async {
    if (_loading) return;
    final body = _controller.text;
    final title = _titleController.text;
    final normalizedTitle = title.trim().isEmpty ? null : title.trim();
    if (body.trim().isEmpty && normalizedTitle == null) {
      if (_entry != null) {
        await widget.database.deleteEntry(_entry!.id);
      }
      return;
    }
    await widget.database.upsertEntry(widget.date, body, title: normalizedTitle);
  }

  Future<void> _delete() async {
    if (_entry != null) {
      await widget.database.deleteEntry(_entry!.id);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _controller.dispose();
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _save();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(DateFormat.yMMMMEEEEd().format(widget.date)),
          actions: [
            if (_entry != null)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete entry',
                onPressed: _delete,
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _titleController,
                      autofocus: true,
                      textInputAction: TextInputAction.next,
                      style: Theme.of(context).textTheme.titleLarge,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Title (optional)',
                      ),
                    ),
                    const Divider(),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Write your note…',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
