# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

This is a local-first journal app built around a **free-form canvas** (think Excalidraw
/ iPad Notes), not a document editor. Each entry is a spatial surface you pan and zoom,
onto which you place text, collapsible subnotes, and freehand pen strokes *anywhere*,
overlapping and layered as you like. The core canvas, storage, and the three element
kinds (text / subnote / stroke) are implemented in `lib/`.

Deliberate near-term simplifications, so plan around them:
- **Text is plain-text-first.** Text/subnote elements have a single font size + color for
  the whole box; inline rich formatting (bold/italic/lists) is future work.
- The canvas is a **large fixed-size surface** spanning `-canvasExtent` to
  `+canvasExtent` on both axes (see the `canvasExtent` / `canvasSize` / `canvasOrigin`
  constants in `canvas_controller.dart`), not a truly virtualized infinite canvas.
  Element placements and stroke points are stored in *canvas coordinates* (which may be
  negative); adding `canvasOrigin` converts them to surface coordinates for
  layout/painting, and subtracting it maps a pointer's local position back.

## Architecture

- **No third-party rich-text or drawing libraries.** `flutter_quill` and `scribble` have
  been removed by design — the text layer is built on Flutter's own `TextField`/
  `EditableText` primitive and drawing is a self-implemented stroke engine. Do not
  reintroduce an editor/drawing package; extend the hand-rolled implementation instead.
- **Entries are a canvas of positioned, layered elements.** A single entry is a spatial
  surface holding an unordered set of absolutely-positioned elements (`x`, `y`, optional
  `width`/`height`, layer `z`), each of a discriminated kind. Elements can overlap freely.
- **Element kinds** live in `lib/models/elements.dart` as a sealed `ElementData`
  hierarchy (`TextElementData`, `SubnoteElementData`, `StrokeElementData`, plus
  `UnknownElementData` which preserves unrecognized JSON for forward-compat). Adding a
  kind = new subclass + `type` string + a `case` in `ElementData.decode` — **no schema
  change**. `PlacedElement` pairs an `ElementData` with its spatial placement for
  transport between the editor and the database.
- **Drawing** is a custom stroke engine: strokes are captured as raw point lists
  (`StrokeElementData.points`, stored relative to the element origin) and rendered with a
  `CustomPainter`. The raw points are intentionally preserved (not rasterized) so a future
  AI pass can recognize shapes/objects from them.
- **The editor is a controller + thin view.** `CanvasController`
  (`lib/screens/canvas_controller.dart`) is a `ChangeNotifier` that owns the editable
  document — the live `CanvasElement` list, a multi-element selection `Set`,
  editing/tool/pen state, drawing capture, focus bookkeeping, loading and autosave. It
  has five tools (`select` / `text` / `draw` / `marquee` / `lasso`); the latter three
  capture raw surface drags (see `capturesPointer`) and disable pan. Selection can hold
  many elements — Ctrl+click toggles, a `marquee` box selects by bounds-intersection, a
  `lasso` selects by centre-in-polygon; `isSelected` drives frames, `selected` is the
  single-selection getter the format toolbar keys off. It never touches `BuildContext`, the
  `TransformationController` or focus nodes directly, reaching them through injected
  callbacks (`scale`, `readTitle`, `requestCanvasFocus`, `showMessage`) so it stays
  view-agnostic and unit-testable. `EntryEditorScreen`
  (`lib/screens/entry_editor_screen.dart`) is a thin view over it: an `InteractiveViewer`
  (pan/zoom) over a `Stack` of positioned elements, rendering from the controller via a
  `ListenableBuilder` and holding only widget-tier resources (title field, pan/zoom
  transform, focus nodes). Per-element widgets (`TextBox`, `SubnoteCard`, painters, the
  `EagerDrag` drag-vs-pan recognizer) live in `lib/screens/canvas_widgets.dart`. The
  background pointer surface lives *inside* the zoomed child so its local coordinates are
  already surface coordinates; screen drag deltas for move/resize are divided by the
  current scale.
- **Persistence is autosaved and diff-based.** The controller autosaves on a timer
  (and on pop / app-background) whenever a `_dirty` flag is set; `AppDatabase.saveEntry`
  writes a **diff**, not a wholesale rewrite — unchanged elements (notably strokes with
  large point lists) are never re-serialized, and a no-op save performs zero writes.
  Saves are **serialized** (each chains onto the in-flight one) so a freshly-inserted
  element's row id is read back before the next save runs, preventing duplicate inserts;
  `CanvasElement.dbId` / `PlacedElement.id` track that row identity.
- **Past days are read-only.** Only *today's* entry is editable; the `readOnly` flag is
  captured once at controller construction (not recomputed from `DateTime.now()`), so an
  editor left open across midnight keeps autosaving to its original `date` instead of
  silently going read-only mid-session.
- **Storage is local-first via `drift`** (SQLite, `drift_flutter` for platform setup).
  Two live tables: `Entries` (one per calendar day, keyed by `date`) and `Elements`
  (placement in columns `x`/`y`/`width`/`height`/`z` + a JSON `data` payload keyed by
  `type`). The legacy `Blocks` table remains defined **only** so the v3→v4 migration can
  fold old ordered blocks into positioned elements; no live code writes to it, and
  `lib/models/blocks.dart` is kept solely for that migration path.
- Editing a `@DriftDatabase`/table/DAO definition requires regenerating code:
  ```bash
  dart run build_runner build --delete-conflicting-outputs
  ```

## Platforms

Target platforms are **Linux desktop** and **Android/iOS**. Scaffolding also exists for
web, macOS, and Windows (default `flutter create` output) but those are not primary
targets — don't assume web/desktop-only APIs work, and be mindful of touch vs.
mouse/keyboard input differences for the sketch canvas across platforms.

## Commands

```bash
flutter pub get              # install dependencies
flutter run                  # run on a connected device/emulator/desktop
flutter run -d linux         # run on Linux desktop
flutter test                 # run all tests
flutter test test/canvas_controller_test.dart   # run a single test file
flutter test --plain-name "a past day is read-only and never persists edits"  # single test by name
flutter analyze              # static analysis / lints
dart format .                # format code
```

## Linting

`analysis_options.yaml` includes `package:flutter_lints/flutter.yaml` with no
project-specific overrides yet.
