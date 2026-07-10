# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

This is a local-first journal app. `lib/main.dart` is currently still the default
`flutter create` counter-app boilerplate — no journal features (entries, storage, rich
text, drawing) have been implemented yet. `pubspec.yaml` already declares the intended
dependencies, so treat this document as the target architecture to build toward, not a
description of existing code.

## Architecture

- **Entries are mixed-content documents.** A single journal entry is one page that can
  contain both rich-text blocks and freehand-sketch blocks, interleaved in sequence (e.g.
  paragraph → sketch → paragraph). Model an entry as an ordered list of typed blocks
  rather than a single flutter_quill document or a single scribble canvas — the two
  content types need to coexist and be reorderable/editable independently within one page.
- **Rich text** is authored and rendered with `flutter_quill`. Text blocks store Quill
  Delta JSON.
- **Sketches** are authored and rendered with `scribble`. Sketch blocks store Scribble's
  serializable stroke/sketch data (not rasterized images), so drawings stay editable.
- **Storage is local-first via `drift`** (SQLite, using `drift_flutter` for
  platform-specific database setup). Entries and their blocks should be modeled as Drift
  tables (e.g. an `entries` table plus a `blocks` table with a discriminator column for
  block type and a position/order column), not as a single blob column, so blocks can be
  queried/reordered without deserializing an entire entry.
- Editing a `@DriftDatabase`/table/DAO definition requires regenerating code:
  ```bash
  dart run build_runner build --delete-conflicting-outputs
  ```

## Platforms

Target platforms are **Linux desktop** and **Android/iOS**. Scaffolding also exists for
web, macOS, and Windows (default `flutter create` output) but those are not primary
targets — don't assume web/desktop-only APIs work, and be mindful of touch vs.
mouse/keyboard input differences for the sketch canvas (`scribble`) across platforms.

## Commands

```bash
flutter pub get              # install dependencies
flutter run                  # run on a connected device/emulator/desktop
flutter run -d linux         # run on Linux desktop
flutter test                 # run all tests
flutter test test/widget_test.dart   # run a single test file
flutter test --plain-name "Counter increments smoke test"  # run a single test by name
flutter analyze              # static analysis / lints
dart format .                # format code
```

## Linting

`analysis_options.yaml` includes `package:flutter_lints/flutter.yaml` with no
project-specific overrides yet.
