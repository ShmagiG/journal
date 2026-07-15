import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../models/elements.dart';

/// The active canvas tool. Selecting one changes what a pointer does on the
/// canvas: move/select existing elements, drop new text, or draw freehand.
enum Tool { select, text, draw }

/// How far the canvas surface reaches from the origin in *each* direction, so
/// canvas coordinates run from -[canvasExtent] to +[canvasExtent] on both axes
/// and there is room to pan left/up as well as right/down. Big enough to feel
/// edgeless when panned/zoomed; true infinite virtualization is future work.
const double canvasExtent = 5000;

/// Logical size of the (large, fixed) canvas surface.
const double canvasSize = canvasExtent * 2;

/// Where canvas coordinate (0, 0) sits within the surface. Element placements
/// and stroke points are stored in canvas coordinates (which may be negative);
/// adding this offset converts them to surface coordinates for layout/painting,
/// and subtracting it converts a pointer's local position back.
const Offset canvasOrigin = Offset(canvasExtent, canvasExtent);

/// The view that shows canvas (0, 0) in the top-left of the viewport — where the
/// canvas starts out, and what "Reset view" returns to. Content written before
/// the canvas grew leftwards/upwards lives at positive coordinates, so this
/// keeps it exactly where it has always been.
Matrix4 homeTransform() =>
    Matrix4.identity()
      ..translateByDouble(-canvasOrigin.dx, -canvasOrigin.dy, 0, 1);

/// Colors offered for text and pen. First entry doubles as the default.
const List<Color> palette = [
  Colors.black,
  Color(0xFFD32F2F), // red
  Color(0xFF1976D2), // blue
  Color(0xFF388E3C), // green
  Color(0xFFF57C00), // orange
  Color(0xFF7B1FA2), // purple
];

/// Pen opacity floor, so a stroke can never be drawn completely invisible.
const double minOpacity = 0.1;

/// Live editing state for one canvas element: its spatial placement, its
/// [data], and (for text/subnote kinds) a [textController]/[focus] pair. [key]
/// is a stable identity for widget keys across rebuilds.
class CanvasElement {
  CanvasElement({
    required this.key,
    required this.data,
    this.dbId,
    this.x = 0,
    this.y = 0,
    this.width,
    this.height,
    this.z = 0,
  }) : textController = _makeController(data),
       focus = data is StrokeElementData ? null : FocusNode();

  final int key;

  /// The `Elements` row id this element is persisted as, or null if it has not
  /// been saved yet. Kept in sync by [CanvasController.save] so each save
  /// updates the same row instead of re-inserting.
  int? dbId;
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

  PlacedElement toPlaced() => PlacedElement(
    id: dbId,
    x: x,
    y: y,
    width: width,
    height: height,
    z: z,
    data: data,
  );

  void dispose() {
    textController?.dispose();
    focus?.dispose();
  }
}

/// Owns the editable document for one entry's canvas — the elements and their
/// selection/editing/tool/pen state — plus loading, autosaving, drawing capture
/// and focus bookkeeping. A [ChangeNotifier] so the view rebuilds from it; it
/// never touches [BuildContext], the [TransformationController] or the view's
/// focus node directly, reaching them through the injected hooks instead.
class CanvasController extends ChangeNotifier {
  CanvasController({
    required this.database,
    required this.date,
    required this.scale,
    required this.readTitle,
    required this.requestCanvasFocus,
    required this.showMessage,
  }) : readOnly =
           AppDatabase.dateOnly(date) != AppDatabase.dateOnly(DateTime.now()) {
    // Closing the window (or killing the app) doesn't reliably give us time to
    // finish a write, so the entry is saved as we go rather than only on exit.
    _autosave = Timer.periodic(_autosaveInterval, (_) {
      if (_dirty) save();
    });
  }

  final AppDatabase database;
  final DateTime date;

  /// Current InteractiveViewer scale, so screen drag deltas map to canvas px.
  final double Function() scale;

  /// Reads the view's title field at save time.
  final String Function() readTitle;

  /// Moves keyboard focus to the canvas (blurring any active editor).
  final VoidCallback requestCanvasFocus;

  /// Surfaces a transient message to the user (a SnackBar in the view).
  final void Function(String message) showMessage;

  /// Only today's entry can be changed — past days are a read-only record.
  /// Captured once at construction rather than recomputed from `DateTime.now()`:
  /// if the editor is left open across midnight the session keeps the
  /// editability it started with, so an in-progress entry keeps autosaving to
  /// its (fixed) [date] instead of silently going read-only and dropping edits.
  final bool readOnly;

  final List<CanvasElement> _elements = [];
  List<CanvasElement> get elements => _elements;

  bool _loading = true;
  bool get loading => _loading;

  /// The entry's title as loaded from storage, for the view to seed its field.
  String loadedTitle = '';

  int _nextKey = 0;

  Tool _tool = Tool.select;
  Tool get tool => _tool;

  CanvasElement? _selected;
  CanvasElement? get selected => _selected;

  /// The element explicitly opened for editing — by tapping into its text, or by
  /// creating a subnote — independent of the current tool. Cleared on blur.
  CanvasElement? _editing;
  CanvasElement? get editing => _editing;

  // Pen settings for the draw tool.
  Color _penColor = palette[0];
  Color get penColor => _penColor;
  double _penWidth = StrokeElementData.defaultWidth;
  double get penWidth => _penWidth;

  /// Pen opacity, baked into a stroke's colour when it is committed. Kept above
  /// [minOpacity] so a stroke can never be drawn completely invisible.
  double _penOpacity = 1;
  double get penOpacity => _penOpacity;

  /// The stroke currently being drawn, in canvas coordinates (null when idle).
  /// A [ValueNotifier] (not notify-the-whole-tree) so that adding a point
  /// repaints only the isolated live-stroke layer, never the whole element list.
  final ValueNotifier<List<Offset>?> liveStroke = ValueNotifier(null);

  /// Set by every edit and cleared by [save], so the autosave below only writes
  /// when there is something to write.
  bool _dirty = false;
  Timer? _autosave;

  /// The save currently in flight (null when idle). Every [save] chains onto
  /// this so writes never overlap — which is what lets a freshly-inserted
  /// element's id be read back before the next save runs (no duplicate inserts).
  Future<void>? _savePending;

  bool _disposed = false;

  static const _autosaveInterval = Duration(seconds: 3);

  // --- Loading -------------------------------------------------------------

  Future<void> load() async {
    final loaded = <CanvasElement>[];
    try {
      final entry = await database.entryForDate(date);
      loadedTitle = entry?.title ?? '';
      if (entry != null) {
        final rows = await database.elementsForEntry(entry.id);
        for (final r in rows) {
          final el = CanvasElement(
            key: _nextKey++,
            data: ElementData.decode(r.type, r.data),
            dbId: r.id,
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
    } catch (_) {
      // Don't leave the user stuck on the spinner: drop out of the loading
      // state and surface the failure.
      if (_disposed) return;
      _loading = false;
      notifyListeners();
      showMessage("Couldn't open this entry.");
      return;
    }
    if (_disposed) return;
    _elements.addAll(loaded);
    _loading = false;
    notifyListeners();
  }

  // --- Queries -------------------------------------------------------------

  int get _topZ => _elements.isEmpty
      ? 0
      : _elements.map((e) => e.z).reduce((a, b) => a > b ? a : b);

  /// Whether elements can currently be moved/resized/selected.
  bool get moveEnabled => !readOnly && _tool == Tool.select;

  /// Whether [el]'s editor is live: the text tool makes every box editable, and
  /// a single box can also be opened on its own via [beginEditing].
  bool isEditing(CanvasElement el) =>
      !readOnly && (_tool == Tool.text || identical(_editing, el));

  /// Strokes always sit beneath text and subnotes. A stroke's hit area is its
  /// whole bounding box, so a stroke drawn *around* a text box (circling it, say)
  /// would otherwise cover it and swallow every click meant for the text.
  static int _layer(CanvasElement el) => el.data is StrokeElementData ? 0 : 1;

  /// The elements in paint order (stroke layer first, then by [CanvasElement.z]).
  List<CanvasElement> sortedByZ() {
    final list = [..._elements]
      ..sort((a, b) {
        final byLayer = _layer(a).compareTo(_layer(b));
        return byLayer != 0 ? byLayer : a.z.compareTo(b.z);
      });
    return list;
  }

  /// The text/subnote element whose editor currently has focus, if any.
  CanvasElement? get _focusedTextElement {
    for (final el in _elements) {
      if ((el.focus?.hasFocus ?? false) && el.textController != null) return el;
    }
    return null;
  }

  // --- Editing hooks -------------------------------------------------------

  void markDirty() => _dirty = true;

  void setPenColor(Color c) {
    _penColor = c;
    notifyListeners();
  }

  void setPenWidth(double w) {
    _penWidth = w;
    notifyListeners();
  }

  void setPenOpacity(double o) {
    _penOpacity = o;
    notifyListeners();
  }

  /// Applies an [mutate] (typing, recolouring, collapsing) and rebuilds. Anything
  /// routed through here is an edit, so it also arms the autosave.
  void edit([VoidCallback? mutate]) {
    _dirty = true;
    mutate?.call();
    notifyListeners();
  }

  void select(CanvasElement? el) {
    if (readOnly) return;
    _selected = el;
    notifyListeners();
  }

  /// Opens [el]'s editor and puts the caret in it, whatever the current tool.
  void beginEditing(CanvasElement el) {
    if (readOnly || el.focus == null) return;
    _editing = el;
    _selected = el;
    notifyListeners();
    // The field only stops being read-only once this rebuild lands.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) el.focus?.requestFocus();
    });
  }

  /// Selecting a text/subnote follows keyboard focus: when a box's editor gains
  /// focus (e.g. the user taps into it) it becomes the selected element, so the
  /// selection frame and format toolbar target what's being edited. On losing
  /// focus, a text box left empty (created but never written in) is discarded.
  void _attachFocus(CanvasElement el) {
    final f = el.focus;
    if (f == null) return;
    f.addListener(() {
      // A read-only (past) entry never selects or mutates anything, even if a
      // field somehow takes focus.
      if (readOnly) return;
      if (f.hasFocus) {
        if (_selected != el) {
          _selected = el;
          notifyListeners();
        }
      } else {
        if (identical(_editing, el)) {
          _editing = null;
          notifyListeners();
        }
        el.syncToData();
        if (el.data is TextElementData && el.data.isEmpty) {
          removeElement(el);
        }
      }
    });
  }

  void removeElement(CanvasElement el) {
    if (!_elements.contains(el)) return;
    _dirty = true;
    _elements.remove(el);
    if (_selected == el) _selected = null;
    if (identical(_editing, el)) _editing = null;
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => el.dispose());
  }

  CanvasElement _add(
    ElementData data, {
    required double x,
    required double y,
    double? width,
    double? height,
  }) {
    final el = CanvasElement(
      key: _nextKey++,
      data: data,
      x: x,
      y: y,
      width: width,
      height: height,
      z: _topZ + 1,
    );
    _attachFocus(el);
    _dirty = true;
    _elements.add(el);
    _selected = el;
    notifyListeners();
    return el;
  }

  void addTextAt(Offset canvasPoint) {
    final el = _add(
      TextElementData.empty(),
      x: canvasPoint.dx,
      y: canvasPoint.dy,
      width: 220,
    );
    // Stay in text mode so tapping empty canvas keeps adding boxes; the new box
    // is focused so the user can type immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) el.focus?.requestFocus();
    });
  }

  /// Adds a subnote centred on [at] (a canvas coordinate the view supplies from
  /// the current viewport centre).
  void addSubnote({required Offset at}) {
    if (readOnly) return;
    final el = _add(
      SubnoteElementData.empty(),
      x: at.dx - SubnoteElementData.defaultWidth / 2,
      y: at.dy - SubnoteElementData.defaultHeight / 2,
      width: SubnoteElementData.defaultWidth,
      height: SubnoteElementData.defaultHeight,
    );
    // The draw tool puts every element behind an IgnorePointer, so leave it —
    // otherwise keep the current tool and just open the new card for typing.
    if (_tool == Tool.draw) {
      _tool = Tool.select;
      notifyListeners();
    }
    beginEditing(el);
  }

  void deleteSelected() {
    final el = _selected;
    if (el == null) return;
    _dirty = true;
    _elements.remove(el);
    _selected = null;
    if (identical(_editing, el)) _editing = null;
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => el.dispose());
  }

  void bringToFront() {
    final el = _selected;
    if (el == null) return;
    _dirty = true;
    el.z = _topZ + 1;
    notifyListeners();
  }

  // --- Tool + canvas taps --------------------------------------------------

  /// Switches the active tool (from a toolbar button or a Ctrl+key shortcut).
  void setTool(Tool tool) {
    if (readOnly) return;
    // Moving focus to the canvas discards any empty text box being left behind
    // and makes text non-interactive in select/draw mode.
    requestCanvasFocus();
    _tool = tool;
    notifyListeners();
  }

  void onCanvasTap(Offset canvasPoint) {
    switch (_tool) {
      case Tool.text:
        // Tapping empty canvas creates a new text box; tapping an existing box
        // hits the box (not this background), so it edits instead of creating.
        addTextAt(canvasPoint);
      case Tool.select:
        requestCanvasFocus();
        select(null);
      case Tool.draw:
        break;
    }
  }

  // --- Drawing (draw tool) -------------------------------------------------

  void onPointerDown(PointerDownEvent e) {
    if (_tool != Tool.draw) return;
    // No notify: only the live-stroke layer (which listens to liveStroke) needs
    // to repaint, not the element list.
    liveStroke.value = [e.localPosition - canvasOrigin];
  }

  void onPointerMove(PointerMoveEvent e) {
    if (_tool != Tool.draw || liveStroke.value == null) return;
    // Reassign a new list so the notifier fires; the live-stroke CustomPaint
    // repaints in isolation.
    liveStroke.value = [...liveStroke.value!, e.localPosition - canvasOrigin];
  }

  void onPointerUp(PointerUpEvent e) {
    if (_tool != Tool.draw || liveStroke.value == null) return;
    final pts = liveStroke.value!;
    liveStroke.value = null;
    if (pts.isEmpty) return;
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
      StrokeElementData(
        points: rel,
        color: _penColor.withValues(alpha: _penOpacity).toARGB32(),
        width: _penWidth,
      ),
      x: origin.dx,
      y: origin.dy,
      width: maxX - minX + pad * 2,
      height: maxY - minY + pad * 2,
    );
    // A stroke shouldn't leave the element "selected"; keep drawing fluidly.
    _selected = null;
    notifyListeners();
  }

  // --- Timestamp -----------------------------------------------------------

  /// Inserts the current `HH:mm:ss` on its own new line in the focused text box
  /// or subnote, leaving the caret on the line below it. Bound to Ctrl+Shift+T
  /// and the clock toolbar button.
  void insertTimestamp() {
    if (readOnly) return;
    final el = _focusedTextElement;
    if (el == null) {
      showMessage('Place the cursor in a text box or subnote first.');
      return;
    }
    final c = el.textController!;
    final stamp = DateFormat('HH:mm:ss').format(DateTime.now());
    final text = c.text;
    final sel = c.selection;
    final at = (sel.isValid ? sel.end : text.length).clamp(0, text.length);

    final before = text.substring(0, at);
    final after = text.substring(at);
    // Start a new line unless we're already at the start of one.
    final lead = (before.isEmpty || before.endsWith('\n')) ? '' : '\n';
    final insertion = '$lead$stamp\n';

    c.value = TextEditingValue(
      text: '$before$insertion$after',
      selection: TextSelection.collapsed(
        offset: before.length + insertion.length,
      ),
    );
    el.syncToData();
    edit();
  }

  // --- Move / resize -------------------------------------------------------

  /// [delta] is a screen-space drag delta; dividing by the current [scale]
  /// converts it to canvas pixels.
  void drag(CanvasElement el, Offset delta) {
    _dirty = true;
    final s = scale();
    el.x += delta.dx / s;
    el.y += delta.dy / s;
    notifyListeners();
  }

  void resize(CanvasElement el, Offset delta) {
    _dirty = true;
    final s = scale();
    el.width = ((el.width ?? 120) + delta.dx / s).clamp(60.0, 2000.0);
    // Text boxes grow only horizontally; their height follows their content.
    if (el.data is! TextElementData) {
      el.height = ((el.height ?? 80) + delta.dy / s).clamp(40.0, 2000.0);
    }
    notifyListeners();
  }

  // --- Save ----------------------------------------------------------------

  Future<void> save() {
    if (_loading || readOnly || !_dirty) return Future.value();
    // Freeze content synchronously, before any await, so this is safe even when
    // called from the pop path as the text controllers are about to be disposed.
    _dirty = false;
    for (final el in _elements) {
      el.syncToData();
    }
    final els = List.of(_elements);
    final title = readTitle();

    // Serialize behind any in-flight save. The PlacedElements are built *inside*
    // the chained op so each element's dbId is read after a prior op wrote it
    // back — otherwise two overlapping autosaves could both insert the same new
    // element.
    final op = (_savePending ?? Future.value()).then((_) async {
      final placed = [for (final el in els) el.toPlaced()];
      try {
        await database.saveEntry(date, title: title, elements: placed);
        for (var i = 0; i < els.length; i++) {
          els[i].dbId = placed[i].id;
        }
      } catch (_) {
        // Re-arm so the next tick (or pop) retries, and let the user know.
        _dirty = true;
        showMessage("Couldn't save — will retry.");
      }
    });
    _savePending = op.whenComplete(() {
      if (identical(_savePending, op)) _savePending = null;
    });
    return _savePending!;
  }

  @override
  void dispose() {
    _disposed = true;
    _autosave?.cancel();
    liveStroke.dispose();
    for (final el in _elements) {
      el.dispose();
    }
    super.dispose();
  }
}
