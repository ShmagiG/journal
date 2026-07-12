import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../models/blocks.dart';

/// Holds the live editing state for one block: its [data], a Quill [quill]
/// controller (null for block kinds this version can't edit, e.g.
/// [UnknownBlockData]), a [focus] node used to drive the shared toolbar, and a
/// [scroll] controller for subnotes that scroll internally. [key] is a stable
/// identity for [ReorderableListView] item keys across reorders.
class _BlockController {
  _BlockController(this.key, this.data)
    : quill = _quillFor(data),
      focus = FocusNode(),
      scroll = ScrollController();

  final int key;
  final BlockData data;
  final QuillController? quill;
  final FocusNode focus;
  final ScrollController scroll;

  static QuillController? _quillFor(BlockData data) {
    final List<dynamic> delta;
    if (data is TextBlockData) {
      delta = data.delta;
    } else if (data is SubnoteBlockData) {
      delta = data.delta;
    } else {
      return null; // Unknown block: shown as a read-only placeholder.
    }
    Document doc;
    try {
      doc = delta.isEmpty ? Document() : Document.fromJson(delta);
    } catch (_) {
      doc = Document();
    }
    return QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
  }

  /// Writes the live editor content back into [data] so it can be persisted.
  void syncToData() {
    final q = quill;
    if (q == null) return;
    final delta = q.document.toDelta().toJson();
    final d = data;
    if (d is TextBlockData) {
      d.delta = delta;
    } else if (d is SubnoteBlockData) {
      d.delta = delta;
    }
  }

  void dispose() {
    quill?.dispose();
    focus.dispose();
    scroll.dispose();
  }
}

/// Write or edit the journal entry for a given [date] as a page-like canvas of
/// ordered, reorderable blocks (flowing rich text plus collapsible subnotes).
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
  final _titleController = TextEditingController();
  final List<_BlockController> _blocks = [];
  Entry? _entry;
  bool _loading = true;
  int _nextKey = 0;

  /// The controller of the most recently focused block; the shared formatting
  /// toolbar acts on it.
  QuillController? _activeController;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entry = await widget.database.entryForDate(widget.date);
    var datas = <BlockData>[];
    if (entry != null) {
      final rows = await widget.database.blocksForEntry(entry.id);
      datas = rows.map((r) => BlockData.decode(r.type, r.data)).toList();
    }
    if (datas.isEmpty) datas = [TextBlockData.empty()];

    if (!mounted) return;
    setState(() {
      _entry = entry;
      _titleController.text = entry?.title ?? '';
      for (final d in datas) {
        _blocks.add(_makeBlock(d));
      }
      _loading = false;
    });
  }

  _BlockController _makeBlock(BlockData data) {
    final bc = _BlockController(_nextKey++, data);
    bc.focus.addListener(() => _onFocusChange(bc));
    return bc;
  }

  void _onFocusChange(_BlockController bc) {
    // Only follow focus gains so the toolbar keeps targeting the last-edited
    // block while the user reaches for a toolbar button.
    if (bc.focus.hasFocus && _activeController != bc.quill) {
      setState(() => _activeController = bc.quill);
    }
  }

  int? _focusedIndex() {
    for (var i = 0; i < _blocks.length; i++) {
      if (_blocks[i].focus.hasFocus) return i;
    }
    return null;
  }

  void _addBlock(BlockData data) {
    final bc = _makeBlock(data);
    final idx = _focusedIndex();
    setState(() {
      if (idx == null) {
        _blocks.add(bc);
      } else {
        _blocks.insert(idx + 1, bc);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) bc.focus.requestFocus();
    });
  }

  void _deleteBlock(_BlockController bc) {
    setState(() {
      _blocks.remove(bc);
      if (_activeController == bc.quill) _activeController = null;
      // Always keep at least one block to write in.
      if (_blocks.isEmpty) _blocks.add(_makeBlock(TextBlockData.empty()));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => bc.dispose());
  }

  void _onReorder(int oldIndex, int newIndex) {
    // onReorderItem already adjusts newIndex for the removed item.
    setState(() {
      final item = _blocks.removeAt(oldIndex);
      _blocks.insert(newIndex, item);
    });
  }

  Future<void> _save() async {
    if (_loading) return;
    for (final bc in _blocks) {
      bc.syncToData();
    }
    await widget.database.saveEntry(
      widget.date,
      title: _titleController.text,
      blocks: _blocks.map((b) => b.data).toList(),
    );
  }

  Future<void> _delete() async {
    if (_entry != null) {
      await widget.database.deleteEntry(_entry!.id);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _titleController.dispose();
    for (final bc in _blocks) {
      bc.dispose();
    }
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
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: TextField(
                      controller: _titleController,
                      textInputAction: TextInputAction.next,
                      style: Theme.of(context).textTheme.titleLarge,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Title (optional)',
                      ),
                    ),
                  ),
                  if (_activeController != null)
                    QuillSimpleToolbar(
                      controller: _activeController!,
                      config: const QuillSimpleToolbarConfig(
                        multiRowsDisplay: false,
                        showClearFormat: false,
                        showSearchButton: false,
                      ),
                    ),
                  const Divider(height: 1),
                  Expanded(
                    child: ReorderableListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
                      buildDefaultDragHandles: false,
                      itemCount: _blocks.length,
                      onReorderItem: _onReorder,
                      itemBuilder: (context, index) {
                        final bc = _blocks[index];
                        return _BlockCard(
                          key: ValueKey(bc.key),
                          index: index,
                          block: bc,
                          onDelete: () => _deleteBlock(bc),
                          onChanged: () => setState(() {}),
                        );
                      },
                    ),
                  ),
                ],
              ),
        floatingActionButton: _loading
            ? null
            : FloatingActionButton(
                tooltip: 'Add block',
                onPressed: _showAddMenu,
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  void _showAddMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.notes),
              title: const Text('Text'),
              subtitle: const Text('A block of flowing rich text'),
              onTap: () {
                Navigator.of(context).pop();
                _addBlock(TextBlockData.empty());
              },
            ),
            ListTile(
              leading: const Icon(Icons.sticky_note_2_outlined),
              title: const Text('Subnote'),
              subtitle: const Text('A collapsible, resizable side note'),
              onTap: () {
                Navigator.of(context).pop();
                _addBlock(SubnoteBlockData.empty());
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// One block row: a left drag handle, the block's editor, and a delete button.
class _BlockCard extends StatelessWidget {
  const _BlockCard({
    super.key,
    required this.index,
    required this.block,
    required this.onDelete,
    required this.onChanged,
  });

  final int index;
  final _BlockController block;
  final VoidCallback onDelete;

  /// Called when the block mutates its own layout state (collapse/resize) so the
  /// parent can rebuild.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.only(top: 8, right: 4),
              child: Icon(
                Icons.drag_indicator,
                size: 20,
                color: Theme.of(context).disabledColor,
              ),
            ),
          ),
          Expanded(child: _buildContent(context)),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Delete block',
            visualDensity: VisualDensity.compact,
            color: Theme.of(context).disabledColor,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final data = block.data;
    if (data is TextBlockData) {
      return _textEditor(placeholder: 'Write…');
    } else if (data is SubnoteBlockData) {
      return _SubnoteBox(block: block, data: data, onChanged: onChanged);
    } else {
      // Unknown block kind: preserve it but show a non-editable placeholder.
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(data.preview),
      );
    }
  }

  Widget _textEditor({required String placeholder}) {
    return QuillEditor.basic(
      controller: block.quill!,
      focusNode: block.focus,
      scrollController: block.scroll,
      config: QuillEditorConfig(
        scrollable: false,
        expands: false,
        autoFocus: false,
        placeholder: placeholder,
        padding: const EdgeInsets.symmetric(vertical: 6),
      ),
    );
  }
}

/// The collapsible, user-resizable subnote box. Collapsed it shows a one-line
/// preview; expanded it shows the full rich text in a fixed-height box that
/// scrolls internally, with a bottom handle to drag the height.
class _SubnoteBox extends StatelessWidget {
  const _SubnoteBox({
    required this.block,
    required this.data,
    required this.onChanged,
  });

  final _BlockController block;
  final SubnoteBlockData data;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(
          left: BorderSide(color: scheme.primary, width: 3),
        ),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () {
              data.collapsed = !data.collapsed;
              onChanged();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    data.collapsed
                        ? Icons.chevron_right
                        : Icons.keyboard_arrow_down,
                    size: 20,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _headerText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!data.collapsed) ...[
            SizedBox(
              height: data.height,
              child: Scrollbar(
                controller: block.scroll,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: QuillEditor.basic(
                    controller: block.quill!,
                    focusNode: block.focus,
                    scrollController: block.scroll,
                    config: const QuillEditorConfig(
                      scrollable: true,
                      expands: false,
                      autoFocus: false,
                      placeholder: 'Subnote…',
                    ),
                  ),
                ),
              ),
            ),
            _ResizeHandle(
              onDrag: (dy) {
                data.height = (data.height + dy).clamp(
                  SubnoteBlockData.minHeight,
                  SubnoteBlockData.maxHeight,
                );
                onChanged();
              },
            ),
          ],
        ],
      ),
    );
  }

  String _headerText() {
    final text = block.quill?.document.toPlainText().trim() ?? data.preview;
    if (text.isEmpty) return 'Subnote';
    final firstLine = text.split('\n').first;
    return firstLine.length > 60 ? '${firstLine.substring(0, 60)}…' : firstLine;
  }
}

/// A draggable bar at the bottom of a subnote used to resize its box height.
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.onDrag});

  /// Called with the vertical drag delta (pixels) as the user drags.
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
        child: Container(
          height: 18,
          alignment: Alignment.center,
          child: Container(
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).disabledColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}
