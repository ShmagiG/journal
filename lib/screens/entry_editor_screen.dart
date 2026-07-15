import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../models/elements.dart';
import 'canvas_controller.dart';
import 'canvas_widgets.dart';

/// Write or edit the journal entry for a given [date] as a free-form canvas of
/// absolutely-positioned, layered elements — plain-text boxes, collapsible
/// subnotes, and freehand pen strokes.
///
/// This is a thin view over a [CanvasController], which owns the document state,
/// persistence, drawing capture and focus bookkeeping. The view keeps only the
/// widget-tier resources (title field, pan/zoom transform, the shortcut/timestamp
/// focus nodes) and renders from the controller via a [ListenableBuilder].
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

class _EntryEditorScreenState extends State<EntryEditorScreen>
    with WidgetsBindingObserver {
  final _titleController = TextEditingController();
  final _transform = TransformationController(homeTransform());

  /// Keeps the timestamp button from taking focus away from the editor it is
  /// meant to insert into.
  final _timestampFocus = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// Anchors keyboard focus inside the shortcut subtree. Focusing this (rather
  /// than calling `unfocus()`) blurs whatever editor was active — discarding an
  /// empty text box — while keeping the Ctrl+key bindings reachable.
  final _canvasFocus = FocusNode(debugLabel: 'canvas');

  Size _viewport = Size.zero;

  late final CanvasController _controller;

  @override
  void initState() {
    super.initState();
    _controller = CanvasController(
      database: widget.database,
      date: widget.date,
      scale: () => _transform.value.getMaxScaleOnAxis(),
      readTitle: () => _titleController.text,
      requestCanvasFocus: _canvasFocus.requestFocus,
      showMessage: (message) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      },
    );
    WidgetsBinding.instance.addObserver(this);
    _controller.load().then((_) {
      if (mounted) _titleController.text = _controller.loadedTitle;
    });
  }

  /// Leaving the app (backgrounded on mobile, window closing on desktop) flushes
  /// whatever hasn't been autosaved yet.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller.save();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _titleController.dispose();
    _transform.dispose();
    _timestampFocus.dispose();
    _canvasFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool get _readOnly => _controller.readOnly;

  /// Canvas coordinate at the centre of the current viewport, for placing new
  /// elements somewhere visible.
  Offset _visibleCenter() {
    final screenCenter = Offset(_viewport.width / 2, _viewport.height / 2);
    return _transform.toScene(screenCenter) - canvasOrigin;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _controller.save();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyM, control: true): () =>
              _controller.setTool(Tool.select),
          const SingleActivator(LogicalKeyboardKey.keyT, control: true): () =>
              _controller.setTool(Tool.text),
          const SingleActivator(LogicalKeyboardKey.keyD, control: true): () =>
              _controller.setTool(Tool.draw),
          const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
              _controller.setTool(Tool.marquee),
          const SingleActivator(LogicalKeyboardKey.keyL, control: true): () =>
              _controller.setTool(Tool.lasso),
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
              _controller.addSubnote(at: _visibleCenter()),
          // Ctrl+Shift+T, since Ctrl+T selects the text tool. SingleActivator
          // matches modifiers exactly, so the two don't collide.
          const SingleActivator(
            LogicalKeyboardKey.keyT,
            control: true,
            shift: true,
          ): _controller.insertTimestamp,
        },
        // Anchors focus inside the shortcut subtree so the bindings fire even
        // when no editor is focused. Key events from a focused text box bubble
        // up through here too.
        child: Focus(
          focusNode: _canvasFocus,
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: Text(DateFormat.yMMMMEEEEd().format(widget.date)),
            ),
            body: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                if (_controller.loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: TextField(
                        controller: _titleController,
                        readOnly: _readOnly,
                        onChanged: (_) => _controller.markDirty(),
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
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // --- Toolbar -------------------------------------------------------------

  Widget _toolbar(BuildContext context) {
    // Past days are a read-only record: no tools, just a notice and the view
    // reset. Only today's entry can be authored.
    if (_readOnly) {
      final scheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.lock_outline, size: 16, color: scheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Read-only — you can only edit today\'s entry.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.center_focus_strong),
              tooltip: 'Reset view',
              onPressed: () => _transform.value = homeTransform(),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              _toolButton(
                Icons.pan_tool_alt_outlined,
                'Select / move (Ctrl+M)',
                Tool.select,
              ),
              _toolButton(
                Icons.text_fields,
                'Add text — tap canvas (Ctrl+T)',
                Tool.text,
              ),
              _toolButton(Icons.edit, 'Draw (Ctrl+D)', Tool.draw),
              _toolButton(
                Icons.highlight_alt,
                'Box select (Ctrl+B)',
                Tool.marquee,
              ),
              _toolButton(Icons.gesture, 'Lasso select (Ctrl+L)', Tool.lasso),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.sticky_note_2_outlined),
                tooltip: 'Add subnote (Ctrl+N)',
                onPressed: () => _controller.addSubnote(at: _visibleCenter()),
              ),
              IconButton(
                // Must not steal focus from the editor being typed in, or the
                // timestamp would have nowhere to go (and an empty box would be
                // discarded on blur).
                focusNode: _timestampFocus,
                icon: const Icon(Icons.schedule),
                tooltip: 'Insert timestamp (Ctrl+Shift+T)',
                onPressed: _controller.insertTimestamp,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.center_focus_strong),
                tooltip: 'Reset view',
                onPressed: () => _transform.value = homeTransform(),
              ),
            ],
          ),
        ),
        _contextRow(context),
      ],
    );
  }

  Widget _toolButton(IconData icon, String tip, Tool tool) {
    final active = _controller.tool == tool;
    return IconButton(
      icon: Icon(icon),
      tooltip: tip,
      isSelected: active,
      color: active ? Theme.of(context).colorScheme.primary : null,
      onPressed: () => _controller.setTool(tool),
    );
  }

  /// Second toolbar row: pen options when drawing, group actions when several
  /// elements are selected, or format/actions for a single selected element.
  /// Empty otherwise.
  Widget _contextRow(BuildContext context) {
    if (_controller.tool == Tool.draw) {
      return _penOptions(context);
    }
    if (_controller.selection.length > 1) {
      return _multiOptions(context);
    }
    final el = _controller.selected;
    if (el != null && el.data is! StrokeElementData) {
      return _formatOptions(context, el);
    }
    if (el != null && el.data is StrokeElementData) {
      return _strokeOptions(context, el);
    }
    return const SizedBox(height: 4);
  }

  /// Actions available when a multi-selection is active: the two operations that
  /// apply uniformly to any mix of elements.
  Widget _multiOptions(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 12),
          Text(
            '${_controller.selection.length} selected',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.flip_to_front),
            tooltip: 'Bring to front',
            onPressed: _controller.bringToFront,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: _controller.deleteSelected,
          ),
        ],
      ),
    );
  }

  Widget _penOptions(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 8),
          for (final c in palette)
            _swatch(
              c,
              _controller.penColor == c,
              () => _controller.setPenColor(c),
            ),
          const SizedBox(width: 12),
          const Icon(Icons.line_weight, size: 18),
          Expanded(
            child: Slider(
              min: 1,
              max: 16,
              value: _controller.penWidth,
              onChanged: _controller.setPenWidth,
            ),
          ),
          const Icon(Icons.opacity, size: 18),
          Expanded(
            child: Slider(
              min: minOpacity,
              max: 1,
              value: _controller.penOpacity,
              label: '${(_controller.penOpacity * 100).round()}%',
              divisions: 9,
              onChanged: _controller.setPenOpacity,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _strokeOptions(BuildContext context, CanvasElement el) {
    final data = el.data as StrokeElementData;
    final color = Color(data.color);
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 8),
          const Icon(Icons.opacity, size: 18),
          Expanded(
            child: Slider(
              min: minOpacity,
              max: 1,
              value: color.a.clamp(minOpacity, 1.0),
              label: '${(color.a * 100).round()}%',
              divisions: 9,
              // Transparency lives in the stroke's colour, so re-tinting it in
              // place is all it takes to make an existing line see-through.
              onChanged: (v) => _controller.edit(
                () => data.color = color.withValues(alpha: v).toARGB32(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: _controller.deleteSelected,
          ),
        ],
      ),
    );
  }

  Widget _formatOptions(BuildContext context, CanvasElement el) {
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
      _controller.edit(() {
        if (d is TextElementData) {
          d.fontSize = v;
        } else if (d is SubnoteElementData) {
          d.fontSize = v;
        }
      });
    }

    void setColor(int? v) {
      _controller.edit(() {
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
          for (final c in palette)
            _swatch(
              c,
              colorValue == c.toARGB32(),
              () => setColor(c.toARGB32()),
            ),
          const VerticalDivider(width: 8),
          IconButton(
            icon: const Icon(Icons.flip_to_front),
            tooltip: 'Bring to front',
            onPressed: _controller.bringToFront,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: _controller.deleteSelected,
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
    // The draw / marquee / lasso tools disable one-finger *pan* so a drag paints
    // or sweeps out a selection instead of moving the canvas, but zoom (pinch /
    // mouse-wheel / ctrl+scroll) stays enabled — those go through
    // InteractiveViewer's scale path, while the drag is captured by the child
    // Listener independent of the gesture arena.
    final allowPan = !_controller.capturesPointer;
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        return ClipRect(
          child: InteractiveViewer(
            transformationController: _transform,
            constrained: false,
            minScale: 0.3,
            maxScale: 5,
            panEnabled: allowPan,
            scaleEnabled: true,
            child: SizedBox(
              width: canvasSize,
              height: canvasSize,
              child: Listener(
                onPointerDown: _controller.onPointerDown,
                onPointerMove: _controller.onPointerMove,
                onPointerUp: _controller.onPointerUp,
                child: Stack(
                  children: [
                    // Background: catches taps for placing text / deselecting.
                    // The grid repaints on pan/zoom, so a RepaintBoundary keeps
                    // those repaints off the element layers.
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) => _controller.onCanvasTap(
                          d.localPosition - canvasOrigin,
                        ),
                        child: RepaintBoundary(
                          child: CanvasBackground(
                            transform: _transform,
                            viewport: _viewport,
                          ),
                        ),
                      ),
                    ),
                    for (final el in _controller.sortedByZ())
                      _buildElement(context, el),
                    // Live drawing preview: mounted whenever the draw tool is
                    // active and isolated in its own RepaintBoundary, so adding a
                    // point repaints only this layer (not the element Stack).
                    if (_controller.tool == Tool.draw)
                      Positioned.fill(
                        child: IgnorePointer(
                          // The in-progress points are canvas coordinates, so the
                          // preview paints from the origin, not the surface's
                          // top-left corner.
                          child: Transform.translate(
                            offset: canvasOrigin,
                            child: RepaintBoundary(
                              child: CustomPaint(
                                painter: LiveStrokePainter(
                                  points: _controller.liveStroke,
                                  color: _controller.penColor.withValues(
                                    alpha: _controller.penOpacity,
                                  ),
                                  width: _controller.penWidth,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    // Live marquee box, isolated like the draw preview above.
                    if (_controller.tool == Tool.marquee)
                      _overlay(
                        MarqueePainter(
                          rect: _controller.marquee,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    // Live lasso path, isolated like the draw preview above.
                    if (_controller.tool == Tool.lasso)
                      _overlay(
                        LassoPainter(
                          points: _controller.lasso,
                          color: Theme.of(context).colorScheme.primary,
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

  /// A full-surface, non-interactive [CustomPaint] layer whose painter works in
  /// canvas coordinates (translated off the surface origin) and repaints in
  /// isolation. Shared by the marquee and lasso previews.
  Widget _overlay(CustomPainter painter) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Transform.translate(
          offset: canvasOrigin,
          child: RepaintBoundary(child: CustomPaint(painter: painter)),
        ),
      ),
    );
  }

  Widget _buildElement(BuildContext context, CanvasElement el) {
    final data = el.data;
    if (data is StrokeElementData) {
      return _positioned(
        el,
        DragSurface(
          enabled: _controller.moveEnabled,
          onSelect: () => _controller.selectAt(el),
          onDelta: (d) => _controller.drag(el, d),
          child: CustomPaint(
            size: Size(el.width ?? 0, el.height ?? 0),
            painter: StrokePainter(
              data.points,
              Color(data.color),
              data.width,
              selected: _controller.isSelected(el),
            ),
          ),
        ),
      );
    }
    if (data is SubnoteElementData) {
      return _positioned(
        el,
        SubnoteCard(controller: _controller, el: el, data: data),
      );
    }
    if (data is TextElementData) {
      return _positioned(
        el,
        TextBox(controller: _controller, el: el, data: data),
      );
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

  Widget _positioned(CanvasElement el, Widget child) {
    // Text boxes always auto-size vertically (never impose a fixed height, which
    // could clip growing text); a collapsed subnote shrinks to just its header.
    final data = el.data;
    double? height = el.height;
    if (data is TextElementData) {
      height = null;
    } else if (data is SubnoteElementData && data.collapsed) {
      height = null;
    }
    // A selected element grows upwards to make room for the frame's move bar.
    // Reserving the space here (rather than letting the bar overflow the box) is
    // what makes the bar hit-testable: a render box never hit-tests outside its
    // own bounds, however it paints. Strokes have no frame/move bar, so they get
    // no offset — a selected stroke stays exactly where it was drawn.
    final hasFrame = data is! StrokeElementData;
    final bar = (hasFrame && _controller.isSelected(el)) ? Frame.barHeight : 0.0;
    return Positioned(
      key: ValueKey(el.key),
      left: el.x + canvasOrigin.dx,
      top: el.y + canvasOrigin.dy - bar,
      width: el.width,
      height: height == null ? null : height + bar,
      // While drawing or sweeping a selection, elements don't intercept pointers
      // so the drag reaches the surface Listener (strokes can be laid over them
      // freely, and a marquee/lasso can start on top of an element).
      child: IgnorePointer(
        ignoring: _controller.capturesPointer,
        child: child,
      ),
    );
  }
}
