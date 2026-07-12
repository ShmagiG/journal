import 'dart:convert';

/// The content payload of a single block within a journal entry.
///
/// An entry is an ordered list of blocks (see the `Blocks` table in
/// `data/database.dart`). A block's concrete kind is identified by [type] and
/// its content is serialized to JSON via [toJson]; [decode] reconstructs the
/// right subclass from a stored row. Adding a new kind of block (e.g. a figure
/// or a sketch) means adding a subclass, a `type` string, and a `case` in
/// [decode] — no database schema change is required.
sealed class BlockData {
  /// Stable discriminator persisted in the `blocks.type` column.
  String get type;

  /// The content persisted (JSON-encoded) in the `blocks.data` column.
  Map<String, dynamic> toJson();

  /// A short plain-text summary, used for the collapsed subnote header and the
  /// entry-list subtitle.
  String get preview;

  /// Whether this block carries no user content and can be dropped on save.
  /// Blocks whose content we can't interpret ([UnknownBlockData]) are never
  /// considered empty, so foreign data is preserved.
  bool get isEmpty => preview.trim().isEmpty;

  /// Reconstructs a [BlockData] from a stored [type] discriminator and its
  /// JSON-encoded [data]. Unknown types degrade to an [UnknownBlockData]
  /// placeholder rather than throwing, so data authored by a newer version (or
  /// a renamed type) survives a round-trip instead of being lost.
  static BlockData decode(String type, String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    switch (type) {
      case TextBlockData.kType:
        return TextBlockData.fromJson(json);
      case SubnoteBlockData.kType:
        return SubnoteBlockData.fromJson(json);
      default:
        return UnknownBlockData(type, json);
    }
  }
}

/// A flowing rich-text block — the main writing surface. Content is a Quill
/// Delta (list of ops), the same format `flutter_quill` reads and writes.
class TextBlockData extends BlockData {
  static const String kType = 'text';

  /// Quill Delta ops. An empty document is `[{"insert": "\n"}]`.
  List<dynamic> delta;

  TextBlockData(this.delta);

  TextBlockData.empty() : delta = _emptyDelta();

  factory TextBlockData.fromJson(Map<String, dynamic> json) =>
      TextBlockData((json['delta'] as List).cast<dynamic>());

  @override
  String get type => kType;

  @override
  Map<String, dynamic> toJson() => {'delta': delta};

  @override
  String get preview => plainTextFromDelta(delta);
}

/// A collapsible, resizable "subnote" — rich text tucked inside a box. When
/// [collapsed] only [preview] is shown; when expanded the full text is shown in
/// a box [height] pixels tall (user-draggable) that scrolls internally.
class SubnoteBlockData extends BlockData {
  static const String kType = 'subnote';

  /// Minimum/maximum resizable box height, in logical pixels.
  static const double minHeight = 64;
  static const double maxHeight = 600;
  static const double defaultHeight = 160;

  List<dynamic> delta;
  bool collapsed;
  double height;

  SubnoteBlockData({
    required this.delta,
    this.collapsed = true,
    this.height = defaultHeight,
  });

  /// A brand-new subnote starts expanded so the user can type immediately.
  SubnoteBlockData.empty()
    : delta = _emptyDelta(),
      collapsed = false,
      height = defaultHeight;

  factory SubnoteBlockData.fromJson(Map<String, dynamic> json) => SubnoteBlockData(
    delta: (json['delta'] as List).cast<dynamic>(),
    collapsed: json['collapsed'] as bool? ?? true,
    height: (json['height'] as num?)?.toDouble() ?? defaultHeight,
  );

  @override
  String get type => kType;

  @override
  Map<String, dynamic> toJson() => {
    'delta': delta,
    'collapsed': collapsed,
    'height': height,
  };

  @override
  String get preview => plainTextFromDelta(delta);
}

/// A block whose [type] this version doesn't recognize. Its raw JSON is kept
/// verbatim so saving never discards content written by another version.
class UnknownBlockData extends BlockData {
  final String _type;
  final Map<String, dynamic> raw;

  UnknownBlockData(this._type, this.raw);

  @override
  String get type => _type;

  @override
  Map<String, dynamic> toJson() => raw;

  @override
  String get preview => '[unsupported block]';

  @override
  bool get isEmpty => false;
}

/// The Quill Delta representing an empty document.
List<dynamic> _emptyDelta() => <dynamic>[
  {'insert': '\n'},
];

/// Concatenates the plain-text `insert` ops of a Quill [delta], skipping embed
/// ops (whose `insert` is a map). Used for previews.
String plainTextFromDelta(List<dynamic> delta) {
  final buffer = StringBuffer();
  for (final op in delta) {
    if (op is Map && op['insert'] is String) {
      buffer.write(op['insert'] as String);
    }
  }
  return buffer.toString().trim();
}
