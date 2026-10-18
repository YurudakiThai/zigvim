#!/usr/bin/env bash
# Track progress across all tasks. Run after completing tasks.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

echo "=== zigvim Progress Report ==="
echo "Date: $(date '+%Y-%m-%d %H:%M')"
echo ""

# Count tasks
total=0
pass=0
fail=0
pending=0

for task in "$ROOT/tasks"/TASK-*.md; do
  name=$(basename "$task" .md)
  ((total++))
  
  # Check if test passes
  if [[ -f "$ROOT/cases/$name.lua" ]]; then
    ZIGVIM="${ZIGVIM:-$ROOT/zig-out/bin/zigvim}"
    if python3 "$DIR/oracle.py" --test "$ROOT/cases/$name.lua" --zigvim "$ZIGVIM" "$@" 2>/dev/null; then
      ((pass++))
      echo "✅ $name: PASS"
    else
      ((fail++))
      echo "❌ $name: FAIL"
    fi
  else
    ((pending++))
    echo "⏳ $name: pending (no test yet)"
  fi
done

echo ""
echo "Summary:"
echo "  Total:   $total"
echo "  Pass:    $pass"
echo "  Fail:    $fail"
echo "  Pending: $pending"

# Append to history
echo "$(date '+%Y-%m-%d %H:%M'),$pass,$fail,$pending" >> "$ROOT/session/history.csv"
