#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/env.sh"

TASK_ID="${1:-}"
if [[ -z "$TASK_ID" ]]; then
  echo "[GATE_FAIL stage=ARGS] Usage: bash scripts/verify_task.sh <TASK_ID>"
  exit 2
fi

TASK_FILE="$ROOT_DIR/scripts/tasks/${TASK_ID}.env"
if [[ ! -f "$TASK_FILE" ]]; then
  echo "[GATE_FAIL stage=ARGS] Unknown task '$TASK_ID' (missing $TASK_FILE)"
  exit 2
fi

# Defaults overridden by task env
ALLOWLIST_REGEX=""
LOCKED_REGEX="^scripts/"
CHECK_TARGETS=""
TEST_TARGETS=""
TIMEOUT_SEC=45
BANNED_PATTERNS='abort\("todo"\)|abort\("unimplemented"\)|panic\(\) // todo'
GATE_CMD=""

source "$TASK_FILE"

run_with_timeout() {
  local secs="$1"
  shift
  python3 - "$secs" "$@" <<'PY'
import subprocess, sys, os, signal
timeout = float(sys.argv[1])
cmd = sys.argv[2:]
p = subprocess.Popen(
    cmd,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
    start_new_session=True,
)
try:
    out, _ = p.communicate(timeout=timeout)
    sys.stdout.write(out)
    sys.exit(p.returncode)
except subprocess.TimeoutExpired:
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except Exception:
        p.kill()
    out, _ = p.communicate()
    if out:
        sys.stdout.write(out[-4000:])
    print(f"\n[GATE_FAIL stage=TIMEOUT] Command timed out after {timeout}s: {' '.join(cmd)}")
    print("FIX_HINT: Check for infinite loops, unclosed @http.Server in async test, or deadlock on @async.Mutex.")
    sys.exit(124)
PY
}

echo "=== [VERIFY $TASK_ID] L1: Guardrails & File Scope ==="
if find . -maxdepth 4 -name "moon.pkg.json" | grep -q .; then
  echo "[GATE_FAIL stage=L1_ANTICHEAT] Found forbidden moon.pkg.json!"
  find . -maxdepth 4 -name "moon.pkg.json"
  echo "FIX_HINT: Delete moon.pkg.json immediately. This repo uses 'moon.pkg' DSL format (see s3client/moon.pkg)."
  exit 1
fi

CHANGED_FILES="$(git status --porcelain --untracked-files=all | awk '$1 != "D" {print $NF}' || true)"
if [[ -n "$CHANGED_FILES" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # Ignore scripts/ harness metadata and docs/
    if [[ "$f" =~ ^(scripts|docs)/ ]]; then
      continue
    fi
    if [[ -n "$LOCKED_REGEX" ]] && [[ "$f" =~ $LOCKED_REGEX ]]; then
      echo "[GATE_FAIL stage=L1_ANTICHEAT] Modified LOCKED file: $f"
      echo "FIX_HINT: Revert it immediately with: git checkout -- $f"
      exit 1
    fi
    if [[ -n "$ALLOWLIST_REGEX" ]] && ! [[ "$f" =~ $ALLOWLIST_REGEX ]]; then
      echo "[GATE_FAIL stage=L1_ANTICHEAT] Modified out-of-scope file: $f"
      echo "ALLOWED_REGEX: $ALLOWLIST_REGEX"
      echo "FIX_HINT: Revert out-of-scope edits with: git checkout -- $f"
      exit 1
    fi
    if [[ -f "$f" ]] && [[ "$f" == *.mbt ]]; then
      if grep -En "$BANNED_PATTERNS" "$f" >/dev/null 2>&1; then
        echo "[GATE_FAIL stage=L1_ANTICHEAT] Banned placeholder found in $f:"
        grep -En "$BANNED_PATTERNS" "$f" | head -n 5
        exit 1
      fi
    fi
  done <<< "$CHANGED_FILES"
fi

translate_moon_errors() {
  local log="$1"
  if grep -Fq "async" <<< "$log" && grep -Fq "SpndError" <<< "$log"; then
    echo "FIX_HINT [ASYNC+ERROR]: In MoonBit, 'async fn' ALREADY implicitly raises 'Error'. Remove 'raise @core.SpndError' from 'async fn' signatures, and ensure 'catch { ... }' blocks include a wildcard fallback '_ => ...' or 'e => raise e'."
  fi
  if grep -Eq "cannot call async|not in async|async function" <<< "$log"; then
    echo "FIX_HINT [ASYNC_CALLER]: Any function calling an async function (like store.get/put/list) must be declared 'async fn' (or 'pub async fn'), and tests calling async functions must be 'async test \"...\"' with 'import { \"moonbitlang/async\" } for \"wbtest\"' in moon.pkg."
  fi
  if grep -Eq "impl .* with async fn" <<< "$log"; then
    echo "FIX_HINT [TRAIT_IMPL]: In MoonBit, trait declares 'async fn foo(...)', while implementation writes 'pub impl Trait for Type with fn foo(self, ...)' (NO 'async' keyword after 'with', or 'with get(self, key)'!). See .mooncakes/moonbitlang/async/src/io/writer.mbt."
  fi
  if grep -Eq "async.*not found|Unbound package.*async" <<< "$log"; then
    echo "FIX_HINT [WBTEST_IMPORT]: Add 'import { \"moonbitlang/async\" } for \"wbtest\"' (or in main import block if package code uses @async) in that package's moon.pkg."
  fi
  if grep -Eq "The type .* does not implement trait" <<< "$log"; then
    echo "FIX_HINT [TRAIT_METHODS]: Check exact parameter types and method list of @store.ObjectStore in store/store.mbt (especially put_if_match(Self, String, String?, Bytes) -> Bool)."
  fi
}

if [[ -n "$CHECK_TARGETS" ]]; then
  echo "=== [VERIFY $TASK_ID] L2: moon check --target native $CHECK_TARGETS ==="
  set +e
  CHECK_OUT="$(run_with_timeout "$TIMEOUT_SEC" moon check --target native --diagnostic-limit 8 $CHECK_TARGETS 2>&1)"
  RC=$?
  set -e
  if [[ $RC -ne 0 ]]; then
    echo "$CHECK_OUT" | tail -n 60
    echo "[GATE_FAIL stage=L2_COMPILE] moon check failed (exit=$RC)"
    translate_moon_errors "$CHECK_OUT"
    exit 1
  fi
fi

if [[ -n "$TEST_TARGETS" ]]; then
  echo "=== [VERIFY $TASK_ID] L3: moon test --target native $TEST_TARGETS ==="
  set +e
  TEST_OUT="$(run_with_timeout "$TIMEOUT_SEC" moon test --target native --diagnostic-limit 8 $TEST_TARGETS 2>&1)"
  RC=$?
  set -e
  if [[ $RC -ne 0 ]]; then
    echo "$TEST_OUT" | tail -n 75
    echo "[GATE_FAIL stage=L3_TEST] moon test failed (exit=$RC)"
    translate_moon_errors "$TEST_OUT"
    exit 1
  fi
  echo "$TEST_OUT" | tail -n 5
fi

if [[ -n "$GATE_CMD" ]]; then
  echo "=== [VERIFY $TASK_ID] L4: Behavioral Gate ==="
  set +e
  GATE_OUT="$(run_with_timeout "$TIMEOUT_SEC" bash -c "$GATE_CMD" 2>&1)"
  RC=$?
  set -e
  if [[ $RC -ne 0 ]]; then
    echo "$GATE_OUT" | tail -n 60
    echo "[GATE_FAIL stage=L4_BEHAVIOR] Behavioral gate failed (exit=$RC)"
    exit 1
  fi
  echo "$GATE_OUT" | tail -n 15
fi

echo "[GATE_VERDICT: PASS] Task $TASK_ID passed all verification layers."
