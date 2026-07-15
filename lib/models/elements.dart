import 'dart:convert';
import 'dart:ui' show Offset;

/// The content payload of a single element placed on an entry's canvas.
///
/// An entry is a free-form canvas of absolutely-positioned, layered elements
/// (see the `Elements` table in `data/database.dart`). The element's spatial
/// fields — position (`x`,`y`), size (`width`,`height`) and layer (`z`) — live
/// in table columns; this class carries only the type-specific *content*.
///
/// A concrete kind is identified by [type] and serialized to JSON via [toJson];
/// [decode] reconstructs the right subclass from a stored row. Adding a new kind
/// (e.g. a shape or an image) means adding a subclass, a `type` string, and a
/// `case` in [decode] — no database schema change is required.
sealed class ElementData {
  /// Stable discriminator persisted in the `elements.type` column.
  String get type;

  /// The content persisted (JSON-encoded) in the `elements.data` column.
  Map<String, dynamic> toJson();

  /// A short plain-text summary, used for the denormalized entry-list preview.
  String get preview;

  /// Whether this element carries no user content and can be dropped on save.
  /// Elements whose content we can't interpret ([UnknownElementData]) are never
  /// considered empty, so foreign data is preserved.
  bool get isEmpty;

  /// Reconstructs an [ElementData] from a stored [type] discriminator and its
  /// JSON-encoded [data]. Unknown types degrade to an [UnknownElementData]
  /// placeholder rather than throwing, so data authored by a newer version (or
  /// a renamed type) survives a round-trip instead of being lost.
  static ElementData decode(String type, String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    switch (type) {
      case TextElementData.kType:
        return TextElementData.fromJson(json);
      case SubnoteElementData.kType:
        return SubnoteElementData.fromJson(json);
      case StrokeElementData.kType:
        return StrokeElementData.fromJson(json);
      default:
        return UnknownElementData(type, json);
    }
  }
}

/// An [ElementData] together with its spatial placement on the canvas. Used to
/// carry an element between the editor and the database (whose `Elements` table
/// stores the placement in columns and the content as JSON).
class PlacedElement {
  PlacedElement({
    this.id,
    required this.x,
    required this.y,
    this.width,
    this.height,
    this.z = 0,
    required this.data,
  });

  /// The `Elements` row id this element is persisted as, or null if it hasn't
  /// been written yet. [AppDatabase.saveEntry] reads it to pick UPDATE vs
  /// INSERT and writes it back after an insert, so subsequent saves target the
  /// same row instead of deleting and re-inserting.
  int? id;

  double x;
  double y;
  double? width;
  double? height;
  int z;
  ElementData data;
}

/// A free-floating box of plain text — the main writing surface. Rich inline
/// formatting is intentionally deferred; for now a text element has a single
/// [fontSize] and [color] applied to the whole box.
class TextElementData extends ElementData {
  static const String kType = 'text';

  static const double defaultFontSize = 16;

  String text;
  double fontSize;

  /// ARGB value (as from [Color.value]); null means "use the theme default".
  int? color;

  TextElementData({required this.text, this.fontSize = defaultFontSize, this.color});

  TextElementData.empty() : text = '', fontSize = defaultFontSize, color = null;

  factory TextElementData.fromJson(Map<String, dynamic> json) => TextElementData(
    text: json['text'] as String? ?? '',
    fontSize: (json['fontSize'] as num?)?.toDouble() ?? defaultFontSize,
    color: (json['color'] as num?)?.toInt(),
  );

  @override
  String get type => kType;

  @override
  Map<String, dynamic> toJson() => {
    'text': text,
    'fontSize': fontSize,
    if (color != null) 'color': color,
  };

  @override
  String get preview => text.trim();

  @override
  bool get isEmpty => text.trim().isEmpty;
}

/// A floating, collapsible "subnote" card. Same plain-text content as a text
/// element, but rendered as a boxed card that can be collapsed to just its
/// header (first line) and can overlap other elements. Its box size lives in the
/// element's `width`/`height` columns.
class SubnoteElementData extends ElementData {
  static const String kType = 'subnote';

  static const double defaultFontSize = 14;
  static const double defaultWidth = 200;
  static const double defaultHeight = 140;

  String text;
  double fontSize;
  int? color;
  bool collapsed;

  SubnoteElementData({
    required this.text,
    this.fontSize = defaultFontSize,
    this.color,
    this.collapsed = false,
  });

  /// A brand-new subnote starts expanded so the user can type immediately.
  SubnoteElementData.empty()
    : text = '',
      fontSize = defaultFontSize,
      color = null,
      collapsed = false;

  factory SubnoteElementData.fromJson(Map<String, dynamic> json) =>
      SubnoteElementData(
        text: json['text'] as String? ?? '',
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? defaultFontSize,
        color: (json['color'] as num?)?.toInt(),
        collapsed: json['collapsed'] as bool? ?? false,
      );

  @override
  String get type => kType;

  @override
  Map<String, dynamic> toJson() => {
    'text': text,
    'fontSize': fontSize,
    if (color != null) 'color': color,
    'collapsed': collapsed,
  };

  @override
  String get preview => text.trim();

  /// A subnote is kept even when empty as long as it isn't blank *and*
  /// collapsed — an empty expanded note is still a placeholder the user may be
  /// about to fill in on this session, but on save a truly blank note is
  /// dropped like any other empty element.
  @override
  bool get isEmpty => text.trim().isEmpty;
}

/// A freehand pen stroke. [points] are stored **relative to the element's
/// `x`/`y`** (its bounding-box origin) so the whole stroke moves as a unit and
/// the raw path is directly available for future AI shape/object recognition.
class StrokeElementData extends ElementData {
  static const String kType = 'stroke';

  static const double defaultWidth = 3;

  /// Points relative to the element origin, in canvas logical pixels.
  List<Offset> points;

  /// ARGB value (as from [Color.value]).
  int color;

  /// Stroke thickness in logical pixels.
  double width;

  StrokeElementData({
    required this.points,
    required this.color,
    this.width = defaultWidth,
  });

  factory StrokeElementData.fromJson(Map<String, dynamic> json) =>
      StrokeElementData(
        points: (json['points'] as List)
            .map((p) => Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()))
            .toList(),
        color: (json['color'] as num).toInt(),
        width: (json['width'] as num?)?.toDouble() ?? defaultWidth,
      );

  @override
  String get type => kType;

  @override
  Map<String, dynamic> toJson() => {
    'points': [
      for (final p in points) [p.dx, p.dy],
    ],
    'color': color,
    'width': width,
  };

  @override
  String get preview => '';

  @override
  bool get isEmpty => points.isEmpty;
}

/// An element whose [type] this version doesn't recognize. Its raw JSON is kept
/// verbatim so saving never discards content written by another version.
class UnknownElementData extends ElementData {
  final String _type;
  final Map<String, dynamic> raw;

  UnknownElementData(this._type, this.raw);

  @override
  String get type => _type;

  @override
  Map<String, dynamic> toJson() => raw;

  @override
  String get preview => '';

  @override
  bool get isEmpty => false;
}
