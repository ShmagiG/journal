#!/usr/bin/env bash
# Installs the release bundle plus desktop-environment integration (icons and
# a .desktop entry) into the current user's XDG directories.
#
#   ./linux/packaging/install.sh            # install for the current user
#   ./linux/packaging/install.sh --uninstall
set -euo pipefail

APP_ID="io.github.shgh.Journal"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGING="$REPO_ROOT/linux/packaging"
BUNDLE="$REPO_ROOT/build/linux/x64/release/bundle"

PREFIX="${PREFIX:-$HOME/.local}"
LIBDIR="$PREFIX/lib/journal"
BINDIR="$PREFIX/bin"
ICONDIR="$PREFIX/share/icons/hicolor"
DESKTOPDIR="$PREFIX/share/applications"

refresh_caches() {
  # Both are best-effort: the install is still correct without them, the
  # desktop just may take longer to notice.
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -qtf "$ICONDIR" 2>/dev/null || true
  command -v update-desktop-database >/dev/null && update-desktop-database -q "$DESKTOPDIR" 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -rf "$LIBDIR"
  rm -f "$BINDIR/journal" "$DESKTOPDIR/$APP_ID.desktop"
  find "$ICONDIR" -name "$APP_ID.png" -delete 2>/dev/null || true
  refresh_caches
  echo "Uninstalled $APP_ID."
  exit 0
fi

if [[ ! -x "$BUNDLE/journal" ]]; then
  echo "No release bundle at $BUNDLE" >&2
  echo "Build one first:  flutter build linux --release" >&2
  exit 1
fi

# Replace rather than overlay, so files dropped from a newer build don't linger.
rm -rf "$LIBDIR"
mkdir -p "$LIBDIR" "$BINDIR" "$DESKTOPDIR"
cp -r "$BUNDLE/." "$LIBDIR/"
ln -sfn "$LIBDIR/journal" "$BINDIR/journal"

for src in "$PACKAGING/icons/hicolor"/*/apps/"$APP_ID.png"; do
  size_dir="$(basename "$(dirname "$(dirname "$src")")")"
  mkdir -p "$ICONDIR/$size_dir/apps"
  cp "$src" "$ICONDIR/$size_dir/apps/$APP_ID.png"
done

sed "s|@EXEC@|$LIBDIR/journal|g" \
  "$PACKAGING/$APP_ID.desktop.in" > "$DESKTOPDIR/$APP_ID.desktop"
chmod 644 "$DESKTOPDIR/$APP_ID.desktop"

refresh_caches

echo "Installed $APP_ID to $LIBDIR"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "Note: $BINDIR is not on your PATH, so the 'journal' command won't resolve." ;;
esac
