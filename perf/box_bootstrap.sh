#!/usr/bin/env bash
# Run this INSIDE the Linux benchmark VM (not on the laptop).
#
# It prepares a clean checkout of the pinned Turbofish commit and builds the
# release server binary used by perf/run_compare.py. The perf/ directory is
# added separately (see perf/run_on_box.sh) and is never overwritten by git.
#
#   bash ~/turbofish-perf/perf/box_bootstrap.sh
#
# Env overrides: REPO_URL, COMMIT, ROOT, MOON_TARGET
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/hu00yan/turbofish.git}"
COMMIT="${COMMIT:-291b260a43829b296f67ed48ff20d715b7a7e5ee}"
ROOT="${ROOT:-$HOME/turbofish-perf}"
TARGET="${MOON_TARGET:-native}"

export PATH="$HOME/.moon/bin:$PATH"

echo "== bootstrap ROOT=$ROOT COMMIT=$COMMIT"
if [ ! -d "$ROOT/.git" ]; then
  echo "== cloning $REPO_URL"
  TMP="$(mktemp -d)"
  git clone --no-checkout "$REPO_URL" "$TMP/repo"
  mkdir -p "$ROOT"
  # Move the clone (including .git) into ROOT without clobbering perf/.
  cp -a "$TMP/repo/." "$ROOT/"
  rm -rf "$TMP"
fi

cd "$ROOT"
echo "== checking out pinned commit"
git fetch --depth 1 origin "$COMMIT" 2>/dev/null || git fetch --depth 50 origin
git checkout --detach "$COMMIT"
test "$(git rev-parse HEAD)" = "$COMMIT"

echo "== building cmd/serve + cmd/metad --release"
moon build cmd/serve --target "$TARGET" --release
moon build cmd/metad --target "$TARGET" --release

BIN="$ROOT/_build/$TARGET/release/build/cmd/serve/serve.exe"
METAD_BIN="$ROOT/_build/$TARGET/release/build/cmd/metad/metad.exe"
test -x "$BIN"
test -x "$METAD_BIN"
echo "== serve binary: $BIN"
ls -l "$BIN" "$METAD_BIN"
sha256sum "$BIN" "$METAD_BIN"

echo "== dependency check"
python3 - <<'PY'
import sys
missing = []
try:
    import numpy
    print("numpy", numpy.__version__)
except Exception as exc:
    missing.append(f"numpy: {exc}")
try:
    import qdrant_client
    import importlib.metadata as md
    print("qdrant-client", md.version("qdrant-client"))
except Exception as exc:
    missing.append(f"qdrant_client: {exc}")
if missing:
    print("MISSING:", "; ".join(missing))
    sys.exit(1)
PY
for tool in /opt/minio/mc python3 git; do
  command -v "$tool" >/dev/null || { echo "MISSING $tool"; exit 1; }
done
curl -fsS -o /dev/null http://127.0.0.1:9000/minio/health/live || { echo "MinIO not healthy"; exit 1; }
curl -fsS -o /dev/null http://127.0.0.1:6333/readyz || { echo "Qdrant not healthy"; exit 1; }
curl -fsS -o /dev/null http://127.0.0.1:8474/proxies || { echo "toxiproxy not healthy"; exit 1; }
echo "== bootstrap OK"
