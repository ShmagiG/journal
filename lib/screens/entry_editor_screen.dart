import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../models/elements.dart';

/// The active canvas tool. Selecting one changes what a pointer does on the
/// canvas: move/select existing elements, drop new text, or draw freehand.
enum _Tool { select, text, draw }

/// Logical size of the (large, fixed) canvas. Big enough to feel edgeless when
/// panned/zoomed; true infinite virtualization is future work.
const double _canvasSize = 5000;

/// Colors offered for text and pen. First entry doubles as the default.
const List<Color> _palette = [
  Colors.black,
  Color(0xFFD32F2F), // red
  Color(0xFF1976D2), // blue
  Color(0xFF388E3C), // green
  Color(0xFFF57C00), // orange
  Color(0xFF7B1FA2), // purple
];

/// Live editing state for one canvas element: its spatial placement, its
/// [data], and (for text/subnote kinds) a [textController]/[focus] pair. [key]
/// is a stable identity for widget keys across rebuilds.
class _CanvasElement {
  _CanvasElement({
    required this.key,
    required this.data,
    this.x = 0,
    this.y = 0,
    this.width,
    this.height,
    this.z = 0,
  }) : textController = _makeController(data),
       focus = data is StrokeElementData ? null : FocusNode();

  final int key;
  double x;
  double y;
  double? width;
  double? height;
  int z;
  final ElementData data;
  final TextEditingController? textController;
  final FocusNode? focus;

  static TextEditingController? _makeController(ElementData d) {
    if (d is TextElementData) return TextEditingController(text: d.text);
    if (d is SubnoteElementData) return TextEditingController(text: d.text);
    return null;
  }

  /// Writes the live text back into [data] so it can be persisted.
  void syncToData() {
    final d = data;
    if (d is TextElementData) {
      d.text = textController!.text;
    } else if (d is SubnoteElementData) {
      d.text = textController!.text;
    }
  }

  PlacedElement toPlaced() =>
      PlacedElement(x: x, y: y, width: width, height: height, z: z, data: data);

  void dispose() {
    textController?.dispose();
    focus?.dispose();
  }
}

/// Write or edit the journal entry for a given [date] as a free-form canvas of
/// absolutely-positioned, layered elements — plain-text boxes, collapsible
/// subnotes, and freehand pen strokes.
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
  final _transform = TransformationController();
  final List<_CanvasElement> _elements = [];
  Entry? _entry;
  bool _loading = true;
  int _nextKey = 0;

  _Tool _tool = _Tool.select;
  _CanvasElement? _selected;

  // Pen settings for the draw tool.
  Color _penColor = _palette[0];
  double _penWidth = StrokeElementData.defaultWidth;

  // The stroke currently being drawn, in canvas coordinates (null when idle).
  List<Offset>? _drawing;

  Size _viewport = Size.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entry = await widget.database.entryForDate(widget.date);
    final loaded = <_CanvasElement>[];
    if (entry != null) {
      final rows = await widget.database.elementsForEntry(entry.id);
      for (final r in rows) {
        final el = _CanvasElement(
          key: _nextKey++,
          data: ElementData.decode(r.type, r.data),
          x: r.x,
          y: r.y,
          width: r.width,
          height: r.height,
          z: r.z,
        );
        _attachFocus(el);
        loaded.add(el);
      }
    }
    if (!mounted) return;
    setState(() {
      _entry = entry;
      _titleController.text = entry?.title ?? '';
      _elements.addAll(loaded);
      _loading = false;
    });
  }

  int get _topZ =>
      _elements.isEmpty ? 0 : _elements.map((e) => e.z).reduce((a, b) => a > b ? a : b);

  /// Canvas coordinate at the centre of the current viewport, for placing new
  /// elements somewhere visible.
  Offset _visibleCenter() {
    final screenCenter = Offset(_viewport.width / 2, _viewport.height / 2);
    return _transform.toScene(screenCenter);
  }

  void _select(_CanvasElement? el) {
    setState(() => _selected = el);
  }

  /// Selecting a text/subnote follows keyboard focus: when a box's editor gains
  /// focus (e.g. the user taps into it) it becomes the selected element, so the
  /// selection frame and format toolbar target what's being edited.
  void _attachFocus(_CanvasElement el) {
    final f = el.focus;
    if (f == null) return;
    f.addListener(() {
      if (f.hasFocus && _selected != el) {
        setState(() => _selected = el);
      }
    });
  }

  /// Public rebuild hook for child element widgets (they can't call the
  /// protected [setState] directly).
  void rebuild([VoidCallback? mutate]) {
    setState(() => mutate?.call());
  }

  _CanvasElement _add(
    ElementData data, {
    required double x,
    required double y,
    double? width,
    double? height,
  }) {
    final el = _CanvasElement(
      key: _nextKey++,
      data: data,
      x: x,
      y: y,
      width: width,
      height: height,
      z: _topZ + 1,
    );
    _attachFocus(el);
    setState(() {
      _elements.add(el);
      _selected = el;
    });
    return el;
  }

  void _addTextAt(Offset canvasPoint) {
    final el = _add(
      TextElementData.empty(),
      x: canvasPoint.dx,
      y: canvasPoint.dy,
      width: 220,
    );
    // Stay in text mode so tapping empty canvas keeps adding boxes; the new box
    // is focused so the user can type immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) el.focus?.requestFocus();
    });
  }

  void _addSubnote() {
    final c = _visibleCenter();
    _add(
      SubnoteElementData.empty(),
      x: c.dx - SubnoteElementData.defaultWidth / 2,
      y: c.dy - SubnoteElementData.defaultHeight / 2,
      width: SubnoteElementData.defaultWidth,
      height: SubnoteElementData.defaultHeight,
    );
    setState(() => _tool = _Tool.select);
  }

  void _deleteSelected() {
    final el = _selected;
    if (el == null) return;
    setState(() {
      _elements.remove(el);
      _selected = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => el.dispose());
  }

  void _bringToFront() {
    final el = _selected;
    if (el == null) return;
    setState(() => el.z = _topZ + 1);
  }

  // --- Drawing (draw tool) -------------------------------------------------

  void _onPointerDown(PointerDownEvent e) {
    if (_tool != _Tool.draw) return;
    setState(() => _drawing = [e.localPosition]);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_tool != _Tool.draw || _drawing == null) return;
    setState(() => _drawing!.add(e.localPosition));
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_tool != _Tool.draw || _drawing == null) return;
    final pts = _drawing!;
    _drawing = null;
    if (pts.isEmpty) {
      setState(() {});
      return;
    }
    final pad = _penWidth / 2 + 1;
    var minX = pts.first.dx, minY = pts.first.dy;
    var maxX = pts.first.dx, maxY = pts.first.dy;
    for (final p in pts) {
      minX = p.dx < minX ? p.dx : minX;
      minY = p.dy < minY ? p.dy : minY;
      maxX = p.dx > maxX ? p.dx : maxX;
      maxY = p.dy > maxY ? p.dy : maxY;
    }
    final origin = Offset(minX - pad, minY - pad);
    final rel = [for (final p in pts) p - origin];
    _add(
      StrokeElementData(points: rel, color: _penColor.toARGB32(), width: _penWidth),
      x: origin.dx,
      y: origin.dy,
      width: maxX - minX + pad * 2,
      height: maxY - minY + pad * 2,
    );
    // A stroke shouldn't leave the element "selected"; keep drawing fluidly.
    setState(() => _selected = null);
  }

  // --- Canvas taps ---------------------------------------------------------

  void _onCanvasTap(Offset canvasPoint) {
    switch (_tool) {
      case _Tool.text:
        // Tapping empty canvas creates a new text box; tapping an existing box
        // hits the box (not this background), so it edits instead of creating.
        _addTextAt(canvasPoint);
      case _Tool.select:
        FocusScope.of(context).unfocus();
        _select(null);
      case _Tool.draw:
        break;
    }
  }

  // --- Save ----------------------------------------------------------------

  Future<void> _save() async {
    if (_loading) return;
    for (final el in _elements) {
      el.syncToData();
    }
    await widget.database.saveEntry(
      widget.date,
      title: _titleController.text,
      elements: _elements.map((e) => e.toPlaced()).toList(),
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
    _transform.dispose();
    for (final el in _elements) {
      el.dispose();
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
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: TextField(
                      controller: _titleController,
                      style: Theme.of(context).textTheme.titleLarge,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Title (optional)',
                      ),
                    ),
                  ),
                  _toolbar(context),
                  const Divider(height: 1),
                  Expanded(child: _canvas(context)),
                ],
              ),
      ),
    );
  }

  // --- Toolbar -------------------------------------------------------------

  Widget _toolbar(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              _toolButton(Icons.pan_tool_alt_outlined, 'Select / move', _Tool.select),
              _toolButton(Icons.text_fields, 'Add text (tap canvas)', _Tool.text),
              _toolButton(Icons.edit, 'Draw', _Tool.draw),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.sticky_note_2_outlined),
                tooltip: 'Add subnote',
                onPressed: _addSubnote,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.center_focus_strong),
                tooltip: 'Reset view',
                onPressed: () => _transform.value = Matrix4.identity(),
              ),
            ],
          ),
        ),
        _contextRow(context),
      ],
    );
  }

  Widget _toolButton(IconData icon, String tip, _Tool tool) {
    final active = _tool == tool;
    return IconButton(
      icon: Icon(icon),
      tooltip: tip,
      isSelected: active,
      color: active ? Theme.of(context).colorScheme.primary : null,
      onPressed: () => setState(() => _tool = tool),
    );
  }

  /// Second toolbar row: pen options when drawing, or format/actions when an
  /// element is selected. Empty otherwise.
  Widget _contextRow(BuildContext context) {
    if (_tool == _Tool.draw) {
      return _penOptions(context);
    }
    final el = _selected;
    if (el != null && el.data is! StrokeElementData) {
      return _formatOptions(context, el);
    }
    if (el != null && el.data is StrokeElementData) {
      return _strokeOptions(context);
    }
    return const SizedBox(height: 4);
  }

  Widget _penOptions(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 8),
          for (final c in _palette)
            _swatch(c, _penColor == c, () => setState(() => _penColor = c)),
          const SizedBox(width: 12),
          const Icon(Icons.line_weight, size: 18),
          Expanded(
            child: Slider(
              min: 1,
              max: 16,
              value: _penWidth,
              onChanged: (v) => setState(() => _penWidth = v),
            ),
          ),
        ],
      ),
    );
  }

  Widget _strokeOptions(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.flip_to_front),
            tooltip: 'Bring to front',
            onPressed: _bringToFront,
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: _deleteSelected,
          ),
        ],
      ),
    );
  }

  Widget _formatOptions(BuildContext context, _CanvasElement el) {
    double fontSize;
    int? colorValue;
    final d = el.data;
    if (d is TextElementData) {
      fontSize = d.fontSize;
      colorValue = d.color;
    } else if (d is SubnoteElementData) {
      fontSize = d.fontSize;
      colorValue = d.color;
    } else {
      return const SizedBox(height: 4);
    }

    void setFont(double v) {
      setState(() {
        if (d is TextElementData) {
          d.fontSize = v;
        } else if (d is SubnoteElementData) {
          d.fontSize = v;
        }
      });
    }

    void setColor(int? v) {
      setState(() {
        if (d is TextElementData) {
          d.color = v;
        } else if (d is SubnoteElementData) {
          d.color = v;
        }
      });
    }

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.remove),
            tooltip: 'Smaller',
            onPressed: () => setFont((fontSize - 2).clamp(8, 96)),
          ),
          Center(child: Text('${fontSize.round()}')),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Larger',
            onPressed: () => setFont((fontSize + 2).clamp(8, 96)),
          ),
          const VerticalDivider(width: 8),
          for (final c in _palette)
            _swatch(c, colorValue == c.toARGB32(), () => setColor(c.toARGB32())),
          const VerticalDivider(width: 8),
          IconButton(
            icon: const Icon(Icons.flip_to_front),
            tooltip: 'Bring to front',
            onPressed: _bringToFront,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: _deleteSelected,
          ),
        ],
      ),
    );
  }

  Widget _swatch(Color color, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).dividerColor,
              width: selected ? 3 : 1,
            ),
          ),
        ),
      ),
    );
  }

  // --- Canvas --------------------------------------------------------------

  Widget _canvas(BuildContext context) {
    // Pan/zoom via InteractiveViewer, except in draw mode where a single-finger
    // drag must paint instead of pan.
    final interactive = _tool != _Tool.draw;
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        return ClipRect(
          child: InteractiveViewer(
            transformationController: _transform,
            constrained: false,
            minScale: 0.3,
            maxScale: 5,
            panEnabled: interactive,
            scaleEnabled: interactive,
            child: SizedBox(
              width: _canvasSize,
              height: _canvasSize,
              child: Listener(
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                child: Stack(
                  children: [
                    // Background: catches taps for placing text / deselecting.
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) => _onCanvasTap(d.localPosition),
                        child: const _CanvasBackground(),
                      ),
                    ),
                    for (final el in _sortedByZ()) _buildElement(context, el),
                    if (_drawing != null && _drawing!.isNotEmpty)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _StrokePainter(
                              _drawing!,
                              _penColor,
                              _penWidth,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<_CanvasElement> _sortedByZ() {
    final list = [..._elements]..sort((a, b) => a.z.compareTo(b.z));
    return list;
  }

  Widget _buildElement(BuildContext context, _CanvasElement el) {
    final data = el.data;
    if (data is StrokeElementData) {
      return _positioned(
        el,
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _select(el),
          onPanUpdate: _tool == _Tool.select ? (d) => _drag(el, d) : null,
          child: CustomPaint(
            size: Size(el.width ?? 0, el.height ?? 0),
            painter: _StrokePainter(
              data.points,
              Color(data.color),
              data.width,
              selected: _selected == el,
            ),
          ),
        ),
      );
    }
    if (data is SubnoteElementData) {
      return _positioned(el, _SubnoteCard(state: this, el: el, data: data));
    }
    if (data is TextElementData) {
      return _positioned(el, _TextBox(state: this, el: el, data: data));
    }
    return _positioned(
      el,
      Container(
        padding: const EdgeInsets.all(8),
        color: Theme.of(context).colorScheme.errorContainer,
        child: const Text('[unsupported]'),
      ),
    );
  }

  Widget _positioned(_CanvasElement el, Widget child) {
    // Text boxes always auto-size vertically (never impose a fixed height, which
    // could clip growing text); a collapsed subnote shrinks to just its header.
    final data = el.data;
    double? height = el.height;
    if (data is TextElementData) {
      height = null;
    } else if (data is SubnoteElementData && data.collapsed) {
      height = null;
    }
    return Positioned(
      key: ValueKey(el.key),
      left: el.x,
      top: el.y,
      width: el.width,
      height: height,
      // While drawing, elements don't intercept pointers so strokes can be laid
      // over them freely.
      child: IgnorePointer(ignoring: _tool == _Tool.draw, child: child),
    );
  }

  /// Current InteractiveViewer scale, so screen drag deltas map to canvas px.
  double get _scale => _transform.value.getMaxScaleOnAxis();

  void _drag(_CanvasElement el, DragUpdateDetails d) {
    setState(() {
      el.x += d.delta.dx / _scale;
      el.y += d.delta.dy / _scale;
    });
  }

  void _resize(_CanvasElement el, DragUpdateDetails d) {
    setState(() {
      el.width = ((el.width ?? 120) + d.delta.dx / _scale).clamp(60.0, 2000.0);
      // Text boxes grow only horizontally; their height follows their content.
      if (el.data is! TextElementData) {
        el.height = ((el.height ?? 80) + d.delta.dy / _scale).clamp(40.0, 2000.0);
      }
    });
  }
}

/// A faint dotted background so the (otherwise blank) canvas reads as a surface.
class _CanvasBackground extends StatelessWidget {
  const _CanvasBackground();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GridPainter(Theme.of(context).dividerColor.withValues(alpha: 0.4)),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      for (double y = 0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 0.8, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.color != color;
}

/// Paints a freehand stroke from a list of points (in the painter's local
/// coordinate space). Adds a subtle highlight box when [selected].
class _StrokePainter extends CustomPainter {
  _StrokePainter(this.points, this.color, this.width, {this.selected = false});

  final List<Offset> points;
  final Color color;
  final double width;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (points.length == 1) {
      canvas.drawPoints(PointMode.points, points, paint..strokeCap = StrokeCap.round);
    } else {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (var i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(path, paint);
    }
    if (selected && size.width > 0) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..color = color.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) =>
      old.points != points ||
      old.color != color ||
      old.width != width ||
      old.selected != selected;
}

/// A movable, resizable plain-text box. Tapping selects it; when selected a
/// frame with a move bar and a resize handle appears and the text is editable.
class _TextBox extends StatelessWidget {
  const _TextBox({required this.state, required this.el, required this.data});

  final _EntryEditorScreenState state;
  final _CanvasElement el;
  final TextElementData data;

  @override
  Widget build(BuildContext context) {
    final selected = state._selected == el;
    final style = TextStyle(
      fontSize: data.fontSize,
      color: data.color != null ? Color(data.color!) : null,
    );
    // The TextField is always editable: tapping it focuses it (which selects the
    // box via the focus listener) and places the caret so the user can type.
    // Moving/resizing happen on the surrounding frame, not on the text itself.
    return _Frame(
      selected: selected,
      onMove: (d) => state._drag(el, d),
      onResize: (d) => state._resize(el, d),
      child: TextField(
        controller: el.textController,
        focusNode: el.focus,
        maxLines: null,
        style: style,
        cursorColor: Theme.of(context).colorScheme.primary,
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: 'Write…',
          contentPadding: EdgeInsets.all(6),
        ),
        onChanged: (_) => state.rebuild(),
      ),
    );
  }
}

/// A floating, collapsible subnote card. The header (tap to collapse/expand) is
/// always shown; the body is an editable text area when expanded.
class _SubnoteCard extends StatelessWidget {
  const _SubnoteCard({required this.state, required this.el, required this.data});

  final _EntryEditorScreenState state;
  final _CanvasElement el;
  final SubnoteElementData data;

  String get _headerText {
    final t = (el.textController?.text ?? data.text).trim();
    if (t.isEmpty) return 'Subnote';
    final first = t.split('\n').first;
    return first.length > 40 ? '${first.substring(0, 40)}…' : first;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = state._selected == el;
    // Selection/move is driven by the header handle below; the body TextField is
    // always editable and tapping it focuses (and thereby selects) the note.
    return _Frame(
      selected: selected,
      onMove: (d) => state._drag(el, d),
      onResize: data.collapsed ? null : (d) => state._resize(el, d),
      child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
            border: Border(left: BorderSide(color: scheme.primary, width: 3)),
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The header doubles as the move handle: tap selects the note,
              // dragging it moves the note, and the chevron toggles collapse.
              MouseRegion(
                cursor: SystemMouseCursors.move,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => state._select(el),
                  onPanUpdate: state._tool == _Tool.select
                      ? (d) => state._drag(el, d)
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 6, 0),
                    child: Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                          iconSize: 18,
                          icon: Icon(
                            data.collapsed
                                ? Icons.chevron_right
                                : Icons.keyboard_arrow_down,
                          ),
                          tooltip: data.collapsed ? 'Expand' : 'Collapse',
                          onPressed: () =>
                              state.rebuild(() => data.collapsed = !data.collapsed),
                        ),
                        Expanded(
                          child: Text(
                            _headerText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        Icon(
                          Icons.drag_indicator,
                          size: 16,
                          color: Theme.of(context).disabledColor,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (!data.collapsed)
                Expanded(
                  child: TextField(
                    controller: el.textController,
                    focusNode: el.focus,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: TextStyle(
                      fontSize: data.fontSize,
                      color: data.color != null ? Color(data.color!) : null,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'Subnote…',
                      contentPadding: EdgeInsets.fromLTRB(8, 0, 8, 8),
                    ),
                    onChanged: (_) => state.rebuild(),
                  ),
                ),
            ],
          ),
        ),
      );
  }
}

/// Wraps a selected element with a highlight frame, a top move bar, and a
/// bottom-right resize handle. When not selected it just shows [child].
class _Frame extends StatelessWidget {
  const _Frame({
    required this.selected,
    required this.child,
    required this.onMove,
    this.onResize,
  });

  final bool selected;
  final Widget child;
  final ValueChanged<DragUpdateDetails> onMove;
  final ValueChanged<DragUpdateDetails>? onResize;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    if (!selected) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.transparent),
        ),
        child: child,
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: primary, width: 1.5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: child,
        ),
        // Move bar along the top edge.
        Positioned(
          left: 0,
          right: 0,
          top: -14,
          height: 14,
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: onMove,
              child: Container(
                color: primary,
                alignment: Alignment.center,
                child: const Icon(Icons.drag_indicator, size: 12, color: Colors.white),
              ),
            ),
          ),
        ),
        if (onResize != null)
          Positioned(
            right: -6,
            bottom: -6,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeDownRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: onResize,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.open_in_full, size: 10, color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
