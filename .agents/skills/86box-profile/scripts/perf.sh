#!/usr/bin/env bash
# Profile 86Box with perf: perf stat + perf record against a running PID.
# Usage: perf.sh [seconds] [pid]
# Output: .scratch/VM/profile/YYYY-MM-DD_HHMMSS.{stat,txt,callgraph.txt,annotate.txt}
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

PERF="perf"
DURATION="${1:-20}"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
DIR="$REPO_ROOT/.scratch/VM/profile"
mkdir -p "$DIR"

BINARY="$REPO_ROOT/build/src/86Box"

if [[ -n "${2:-}" ]]; then
  PID="$2"
else
  # Auto-detect: prefer the scratch live instance, then any 86Box.
  LIVE_PID="$REPO_ROOT/.scratch/VM/live/pid"
  if [[ -f "$LIVE_PID" ]] && kill -0 "$(cat "$LIVE_PID")" 2>/dev/null; then
    PID="$(cat "$LIVE_PID")"
  else
    PID=$(pgrep -f '[8]6Box' | head -1 || true)
  fi
  if [[ -z "$PID" ]]; then
    echo "ERROR: no running 86Box found (start one with the 86box-automation skill)." >&2
    exit 1
  fi
fi
if ! kill -0 "$PID" 2>/dev/null; then
  echo "ERROR: PID $PID is not running." >&2
  exit 1
fi

echo "=== Profiling PID $PID for ${DURATION}s ==="
echo "=== Output: $DIR/$STAMP.* ==="
echo ""

# Phase 1: perf stat for high-level counters
echo "[1/2] perf stat: hardware counters (${DURATION}s, wait for it)..."
$PERF stat -p $PID -d -d --timeout $((DURATION * 1000)) 2>&1 | tee "$DIR/$STAMP.stat"
echo ""

# Phase 2: perf record for function-level call-graph sampling
echo "[2/2] perf record: function sampling (another ${DURATION}s, don't ctrl+c!)..."
$PERF record --call-graph fp -F 499 -p $PID -o "$DIR/$STAMP.data" -- sleep $DURATION

# Generate flat text report
echo "--- generating reports ---"

# Flat function-level report
$PERF report -i "$DIR/$STAMP.data" --stdio --no-children --no-call-graph --percent-limit 0.3 -s sym,dso > "$DIR/$STAMP.txt" || true

# Call graph report (who calls what, with percentages)
$PERF report -i "$DIR/$STAMP.data" --stdio --children --percent-limit 0.5 --call-graph callee,1,caller > "$DIR/$STAMP.callgraph.txt" || true

# Instruction-level annotation for the top hot functions, derived from the
# report just generated (adaptive: works across dynarec/interpreter builds
# and branches, unlike a hardcoded symbol list).
TOP_FUNCS=$(grep -E '^\s+[0-9]+\.[0-9]+%' "$DIR/$STAMP.txt" | head -8 | awk '{print $3}')
: > "$DIR/$STAMP.annotate.txt"
for func in $TOP_FUNCS; do
  echo "========== $func ==========" >> "$DIR/$STAMP.annotate.txt"
  $PERF annotate -i "$DIR/$STAMP.data" -s "$func" --stdio --no-source --percent-limit 0.3 >> "$DIR/$STAMP.annotate.txt" 2>/dev/null || true
done

# Summary header
{
  echo "# Perf snapshot: $STAMP"
  echo "# Duration: ${DURATION}s | PID: $PID"
  echo "# Binary: $(ls -lh $BINARY 2>/dev/null | awk '{print $5, $9}' || echo 'external PID')"
  echo "# Branch: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
  echo "# Build flags: $(grep -m1 'FLAGS =' "$REPO_ROOT/build/build.ninja" 2>/dev/null | sed 's/.*= //' || echo unknown)"
  echo ""
} | cat - "$DIR/$STAMP.txt" > "$DIR/$STAMP.txt.tmp" && mv "$DIR/$STAMP.txt.tmp" "$DIR/$STAMP.txt"

# Clean up raw data (large, not needed after reports generated)
rm -f "$DIR/$STAMP.data"

echo ""
echo "=== Done ==="
echo "  Counters:    $DIR/$STAMP.stat"
echo "  Profile:     $DIR/$STAMP.txt"
echo "  Call graph:  $DIR/$STAMP.callgraph.txt"
echo "  Annotations: $DIR/$STAMP.annotate.txt"
echo ""
echo "Top 10 functions:"
grep -E '^[[:space:]]+[0-9]+\.[0-9]+%' "$DIR/$STAMP.txt" | head -10 || true
