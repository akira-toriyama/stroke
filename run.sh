#!/bin/zsh
# Build + launch a wand .app bundle locally. Defaults to release
# (Wand.app, com.wand.wand) — the bundle you'd actually use
# day to day. ``--dev`` builds the parallel Wand-dev.app
# (com.wand.wand.dev) for verification alongside a Homebrew
# install without TCC grant collisions.
#
#   ./run.sh             release → Wand.app
#   ./run.sh --dev       dev     → Wand-dev.app
#
# Always kills any currently-running wand first (via stop.sh) so
# the new bundle takes over cleanly. Quit later: ``./stop.sh`` or
# ``wand --quit``.
set -e
cd "$(dirname "$0")"

MODE=""
APP="Wand.app"
if [[ "${1:-}" == "--dev" ]]; then
    MODE="--dev"
    APP="Wand-dev.app"
fi

./package.sh $MODE
./stop.sh
sleep 0.5
# run.sh always sets WAND_DEBUG so the dev loop's /tmp/wand.log is verbose
# (and mirrored to stderr). A normal/brew/raw launch sets nothing and stays
# quiet — there is no --debug flag. `open` does not inherit the shell env,
# so the var must be passed explicitly via --env.
open "./$APP" --env WAND_DEBUG=1
echo "$APP launched (WAND_DEBUG=1). Grant Accessibility on first run."
