import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/elements.dart';
import 'canvas_controller.dart';

/// A pan recognizer that claims the gesture arena as soon as the pointer goes
/// down. The canvas's [InteractiveViewer] installs a `ScaleGestureRecognizer`
/// over the whole surface which otherwise steals element drags (it wins the
/// arena even with `panEnabled`/`scaleEnabled` false). Accepting eagerly means a
/// drag that *starts on an element* moves that element instead of panning.
class _EagerPanRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// Drags [child] using an [_EagerPanRecognizer], reporting screen-space deltas.
/// Because the gesture is claimed on pointer-down, nothing inside [child] can
/// receive taps — keep buttons outside it. [onTap] stands in for the tap the
/// recognizer swallows: it fires when the pointer is released having travelled
/// less than the touch slop.
class EagerDrag extends StatefulWidget {
  const EagerDrag({
    super.key,
    required this.onDelta,
    required this.child,
    this.onDown,
    this.onTap,
  });

  final ValueChanged<Offset> onDelta;
  final VoidCallback? onDown;
  final VoidCallback? onTap;
  final Widget child;

  @override
  State<EagerDrag> createState() => _EagerDragState();
}

class _EagerDragState extends State<EagerDrag> {
  /// Distance travelled since pointer-down, to tell a tap from a drag.
  double _travel = 0;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _EagerPanRecognizer:
            GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
              _EagerPanRecognizer.new,
              (r) {
                r.onDown = (_) {
                  _travel = 0;
                  widget.onDown?.call();
                };
                r.onUpdate = (d) {
                  _travel += d.delta.distance;
                  widget.onDelta(d.delta);
                };
                r.onEnd = (_) {
                  if (_travel < kTouchSlop) widget.onTap?.call();
                };
              },
            ),
      },
      child: widget.child,
    );
  }
}

/// A surface that selects its element on pointer-down and moves it on drag.
/// When [enabled] is false (text/draw tool) it only handles taps, leaving drags
/// to the canvas. [onTap] (if given) fires on a click that didn't drag.
class DragSurface extends StatelessWidget {
  const DragSurface({
    super.key,
    required this.enabled,
    required this.onSelect,
    required this.onDelta,
    required this.child,
    this.onTap,
  });

  final bool enabled;
  final VoidCallback onSelect;
  final VoidCallback? onTap;

  /// Screen-space drag delta.
  final ValueChanged<Offset> onDelta;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap ?? onSelect,
        child: child,
      );
    }
    // Pointer-down selects: a click without movement still selects, since the
    // eager pan swallows the tap gesture.
    return EagerDrag(
      onDown: onSelect,
      onDelta: onDelta,
      onTap: onTap,
      child: child,
    );
  }
}

/// A faint dotted background so the (otherwise blank) canvas reads as a surface.
class CanvasBackground extends StatelessWidget {
  const CanvasBackground({
    super.key,
    required this.transform,
    required this.viewport,
  });

  final TransformationController transform;
  final Size viewport;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GridPainter(
        color: Theme.of(context).dividerColor.withValues(alpha: 0.4),
        transform: transform,
        viewport: viewport,
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.color,
    required this.transform,
    required this.viewport,
  }) : super(repaint: transform);

  final Color color;
  final TransformationController transform;
  final Size viewport;

  static const double _step = 40.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (viewport.isEmpty) return;
    // Only the slice of the (huge) surface currently on screen is worth
    // painting. Map the viewport back into surface coordinates and clamp it to
    // the surface bounds, then walk only that window's grid.
    final visible = MatrixUtils.inverseTransformRect(
      transform.value,
      Offset.zero & viewport,
    ).intersect(Offset.zero & size);
    if (visible.isEmpty) return;

    // Snap the window's edges down to the grid so dots stay aligned.
    final startX = (visible.left / _step).floor() * _step;
    final startY = (visible.top / _step).floor() * _step;

    final paint = Paint()..color = color;
    for (double x = startX; x <= visible.right; x += _step) {
      for (double y = startY; y <= visible.bottom; y += _step) {
        canvas.drawCircle(Offset(x, y), 0.8, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.color != color || old.viewport != viewport;
}

/// Paints the in-progress freehand stroke as its points arrive. Listens to
/// [points] via its `repaint` argument so only this layer repaints per point;
/// [color]/[width] are fixed for the duration of a stroke.
class LiveStrokePainter extends CustomPainter {
  LiveStrokePainter({
    required this.points,
    required this.color,
    required this.width,
  }) : super(repaint: points);

  final ValueListenable<List<Offset>?> points;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = points.value;
    if (pts == null || pts.isEmpty) return;
    _paintStrokePath(
      canvas,
      pts,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant LiveStrokePainter old) =>
      old.color != color || old.width != width;
}

/// Paints the in-progress marquee (box) selection rectangle. Listens to [rect]
/// so only this layer repaints as the box is dragged.
class MarqueePainter extends CustomPainter {
  MarqueePainter({required this.rect, required this.color})
    : super(repaint: rect);

  final ValueListenable<Rect?> rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect.value;
    if (r == null) return;
    canvas.drawRect(
      r,
      Paint()
        ..color = color.withValues(alpha: 0.12)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      r,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant MarqueePainter old) => old.color != color;
}

/// Paints the in-progress lasso selection path, closed back to its start so it
/// reads as the region being enclosed. Listens to [points] so only this layer
/// repaints per point.
class LassoPainter extends CustomPainter {
  LassoPainter({required this.points, required this.color})
    : super(repaint: points);

  final ValueListenable<List<Offset>?> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = points.value;
    if (pts == null || pts.length < 2) return;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.1)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant LassoPainter old) => old.color != color;
}

/// Draws a freehand stroke (a dot for a single point, a joined path otherwise)
/// from [points] in the canvas's local space. Shared by the committed-stroke
/// [StrokePainter] and the live [LiveStrokePainter].
void _paintStrokePath(Canvas canvas, List<Offset> points, Paint paint) {
  if (points.isEmpty) return;
  if (points.length == 1) {
    canvas.drawPoints(PointMode.points, points, paint);
  } else {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, paint);
  }
}

/// Paints a freehand stroke from a list of points (in the painter's local
/// coordinate space). Adds a subtle highlight box when [selected].
class StrokePainter extends CustomPainter {
  StrokePainter(this.points, this.color, this.width, {this.selected = false});

  final List<Offset> points;
  final Color color;
  final double width;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    _paintStrokePath(
      canvas,
      points,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
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
  bool shouldRepaint(covariant StrokePainter old) =>
      old.points != points ||
      old.color != color ||
      old.width != width ||
      old.selected != selected;
}

/// A movable, resizable plain-text box. Tapping selects it; when selected a
/// frame with a move bar and a resize handle appears and the text is editable.
class TextBox extends StatelessWidget {
  const TextBox({
    super.key,
    required this.controller,
    required this.el,
    required this.data,
  });

  final CanvasController controller;
  final CanvasElement el;
  final TextElementData data;

  @override
  Widget build(BuildContext context) {
    final selected = controller.isSelected(el);
    final editing = controller.isEditing(el);
    final style = TextStyle(
      fontSize: data.fontSize,
      color: data.color != null ? Color(data.color!) : null,
    );

    final field = TextField(
      controller: el.textController,
      focusNode: el.focus,
      readOnly: !editing,
      maxLines: null,
      style: style,
      cursorColor: Theme.of(context).colorScheme.primary,
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: 'Write…',
        contentPadding: EdgeInsets.all(6),
      ),
      onChanged: (_) => controller.edit(),
    );

    // Text tool: the field is live — tapping it focuses/edits (and selects via
    // the focus listener).
    if (editing) {
      return Frame(
        selected: selected,
        onMove: (d) => controller.drag(el, d),
        onResize: (d) => controller.resize(el, d),
        child: field,
      );
    }
    // Otherwise the field is inert and a transparent overlay on top of it is the
    // drag surface: pointer-down selects, a drag moves, a click opens the editor.
    return Frame(
      selected: selected,
      onMove: (d) => controller.drag(el, d),
      onResize: (d) => controller.resize(el, d),
      child: Stack(
        children: [
          IgnorePointer(child: field),
          Positioned.fill(
            child: DragSurface(
              enabled: controller.moveEnabled,
              onSelect: () => controller.selectAt(el),
              onDelta: (d) => controller.drag(el, d),
              onTap: () => controller.onElementTap(el),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }
}

/// A floating, collapsible subnote card. The header (tap to collapse/expand) is
/// always shown; the body is an editable text area when expanded.
class SubnoteCard extends StatelessWidget {
  const SubnoteCard({
    super.key,
    required this.controller,
    required this.el,
    required this.data,
  });

  final CanvasController controller;
  final CanvasElement el;
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
    final selected = controller.isSelected(el);
    final editing = controller.isEditing(el);

    // The chevron stays OUTSIDE the drag surface: the eager pan recognizer
    // claims the gesture on pointer-down, so anything inside the surface can no
    // longer receive taps. The rest of the header is the move handle.
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 6, 0),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            iconSize: 18,
            icon: Icon(
              data.collapsed ? Icons.chevron_right : Icons.keyboard_arrow_down,
            ),
            tooltip: data.collapsed ? 'Expand' : 'Collapse',
            onPressed: () =>
                controller.edit(() => data.collapsed = !data.collapsed),
          ),
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: DragSurface(
                enabled: controller.moveEnabled,
                onSelect: () => controller.selectAt(el),
                onDelta: (d) => controller.drag(el, d),
                child: Row(
                  children: [
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
        ],
      ),
    );

    final body = TextField(
      controller: el.textController,
      focusNode: el.focus,
      readOnly: !editing,
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
      onChanged: (_) => controller.edit(),
    );

    final card = Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          if (!data.collapsed)
            Expanded(
              // While editing, the body is live and takes text. Otherwise it's
              // inert and doubles as a drag surface, so the card moves from
              // anywhere — and a click (not a drag) opens the editor.
              child: editing
                  ? body
                  : DragSurface(
                      enabled: controller.moveEnabled,
                      onSelect: () => controller.selectAt(el),
                      onDelta: (d) => controller.drag(el, d),
                      onTap: () => controller.onElementTap(el),
                      child: IgnorePointer(child: body),
                    ),
            ),
        ],
      ),
    );

    return Frame(
      selected: selected,
      onMove: (d) => controller.drag(el, d),
      onResize: data.collapsed ? null : (d) => controller.resize(el, d),
      child: card,
    );
  }
}

/// Wraps a selected element with a highlight frame, a top move bar, and a
/// bottom-right resize handle. When not selected it just shows [child].
///
/// The move bar occupies [barHeight] at the top of the frame; the caller grows
/// the element upwards by the same amount when it is selected, so the content
/// stays where it was and the bar stays inside the frame's bounds — a render box
/// never hit-tests outside them.
class Frame extends StatelessWidget {
  const Frame({
    super.key,
    required this.selected,
    required this.child,
    required this.onMove,
    this.onResize,
  });

  static const double barHeight = 14;

  final bool selected;
  final Widget child;

  /// Screen-space drag deltas.
  final ValueChanged<Offset> onMove;
  final ValueChanged<Offset>? onResize;

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
        Padding(
          padding: const EdgeInsets.only(top: barHeight),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: primary, width: 1.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: child,
          ),
        ),
        // Move bar along the top edge, in the space reserved for it.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: barHeight,
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: EagerDrag(
              onDelta: onMove,
              child: Container(
                color: primary,
                alignment: Alignment.center,
                child: const Icon(
                  Icons.drag_indicator,
                  size: 12,
                  color: Colors.white,
                ),
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
              child: EagerDrag(
                onDelta: onResize!,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.open_in_full,
                    size: 10,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
