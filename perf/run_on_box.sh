#!/usr/bin/env bash
# Convenience launcher: copy perf/ into the Simular box, bootstrap the pinned
# checkout there, and run perf/run_compare.py inside the box.
#
#   bash perf/run_on_box.sh --smoke
#   bash perf/run_on_box.sh --docs 50000 --reps 3
#
# The box CLI and paths can be overridden with BOX_BIN / BOX_JS / BOX_NAME /
# REMOTE_ROOT. Only perf/ is uploaded; the box builds the pinned commit itself
# (so local uncommitted source changes never enter the measurement).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BOX_BIN="${BOX_BIN:-/opt/homebrew/bin/node}"
BOX_JS="${BOX_JS:-$HOME/.npm/_npx/b571e6a158670c36/node_modules/@simular-ai/box/bin/simular-box.js}"
BOX_NAME="${BOX_NAME:-main}"
REMOTE_ROOT="${REMOTE_ROOT:-/home/user/turbofish-perf}"

box() { "$BOX_BIN" "$BOX_JS" exec --box "$BOX_NAME" -c "$1"; }

# 1. ensure the pinned checkout + release binary exist
box "test -x '$REMOTE_ROOT/_build/native/release/build/cmd/serve/serve.exe' && test -x '$REMOTE_ROOT/_build/native/release/build/cmd/metad/metad.exe'" >/dev/null 2>&1 || {
  echo "== bootstrapping box (clone + release build)"
  TARBALL="$(mktemp)"
  tar czf "$TARBALL" -C "$HERE" perf
  B64="$(base64 < "$TARBALL" | tr -d '\n')"
  rm -f "$TARBALL"
  box "mkdir -p '$REMOTE_ROOT' && printf '%s' '$B64' | base64 -d | tar xzf - -C '$REMOTE_ROOT'"
  # The previous commit did not track perf/, so git checkout refuses to overwrite
  # the just-uploaded files. They are re-uploaded after bootstrap.
  box "cp '$REMOTE_ROOT/perf/box_bootstrap.sh' /tmp/tf-box-bootstrap.sh && rm -rf '$REMOTE_ROOT/perf' && bash /tmp/tf-box-bootstrap.sh"
}

# 2. upload only perf/ (the source tree in the box stays at the pinned commit)
TARBALL="$(mktemp)"
tar czf "$TARBALL" -C "$HERE" perf
B64="$(base64 < "$TARBALL" | tr -d '\n')"
rm -f "$TARBALL"
box "mkdir -p '$REMOTE_ROOT' && printf '%s' '$B64' | base64 -d | tar xzf - -C '$REMOTE_ROOT'"

# 3. run the comparison (args are shell-quoted for the remote shell)
ARGS=""
for a in "$@"; do ARGS+="$(printf '%q' "$a") "; done
[ -n "$ARGS" ] || ARGS="--smoke"
box "cd '$REMOTE_ROOT' && export PATH=\"\$HOME/.moon/bin:\$PATH\" && python3 perf/run_compare.py $ARGS"
