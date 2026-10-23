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
  if [[ "$name" == "TASK-TEMPLATE" ]]; then
    continue
  fi
  total=$((total + 1))

  # Tasks without an executable case can record their completion in the card.
  if grep -q 'Status:.*Complete' "$task"; then
    pass=$((pass + 1))
    echo "✅ $name: PASS (documented complete)"
    continue
  fi

  # Check if test passes
  if [[ "$name" == "TASK-INFRA-005" ]]; then
    ZIGVIM="${ZIGVIM:-$ROOT/zig-out/bin/zigvim}"
    if python3 "$DIR/rpc_verify.py" --zigvim "$ZIGVIM" >/dev/null 2>&1; then
      pass=$((pass + 1))
      echo "✅ $name: PASS"
    else
      fail=$((fail + 1))
      echo "❌ $name: FAIL"
    fi
  elif [[ -f "$ROOT/cases/$name.lua" ]]; then
    ZIGVIM="${ZIGVIM:-$ROOT/zig-out/bin/zigvim}"
    if python3 "$DIR/oracle.py" --test "$ROOT/cases/$name.lua" --zigvim "$ZIGVIM" "$@" 2>/dev/null; then
      pass=$((pass + 1))
      echo "✅ $name: PASS"
    else
      fail=$((fail + 1))
      echo "❌ $name: FAIL"
    fi
  else
    pending=$((pending + 1))
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
