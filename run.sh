#!/bin/zsh
# Build + launch a stroke .app bundle locally. Defaults to release
# (Stroke.app, com.stroke.stroke) — the bundle you'd actually use
# day to day. ``--dev`` builds the parallel Stroke-dev.app
# (com.stroke.stroke.dev) for verification alongside a Homebrew
# install without TCC grant collisions.
#
#   ./run.sh             release → Stroke.app
#   ./run.sh --dev       dev     → Stroke-dev.app
#
# Always kills any currently-running stroke first (via stop.sh) so
# the new bundle takes over cleanly. Quit later: ``./stop.sh`` or
# ``stroke --quit``.
set -e
cd "$(dirname "$0")"

MODE=""
APP="Stroke.app"
if [[ "${1:-}" == "--dev" ]]; then
    MODE="--dev"
    APP="Stroke-dev.app"
fi

./package.sh $MODE
./stop.sh
sleep 0.5
open "./$APP"
echo "$APP launched. Grant Accessibility on first run."
