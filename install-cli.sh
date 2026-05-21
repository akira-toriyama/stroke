#!/bin/zsh
# Put a `stroke` command on your PATH. With --reload / --quit /
# --validate / --record / --help it acts as a thin client: posts a
# distributed notification to the running daemon (or runs the
# standalone command) and exits. The daemon itself is launched via
# run.sh or `open Stroke.app`.
set -e
cd "$(dirname "$0")"
BIN="$PWD/Stroke.app/Contents/MacOS/stroke"
[[ -x "$BIN" ]] || { echo "build first: ./package.sh"; exit 1; }

# Prefer a dir already on PATH and writable (no dotfile changes):
# Homebrew bin (Apple Silicon, user-owned) → /usr/local/bin → ~/.local/bin.
if [[ -w /opt/homebrew/bin ]]; then
  DIR=/opt/homebrew/bin
elif [[ -w /usr/local/bin ]]; then
  DIR=/usr/local/bin
else
  mkdir -p "$HOME/.local/bin"; DIR="$HOME/.local/bin"
fi
ln -sf "$BIN" "$DIR/stroke"
echo "linked: $DIR/stroke -> $BIN"
case ":$PATH:" in
  *":$DIR:"*) : ;;
  *) echo "note: add $DIR to PATH (e.g. in ~/.zshrc)";;
esac
echo "usage: stroke --reload | --quit | --validate | --record | --help"
echo "       (run \`stroke\` alone for the daemon)"
