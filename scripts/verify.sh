#!/usr/bin/env bash
# Single-command gate for vibe coding. Run this after each task.
# Usage: ./verify.sh TASK-006
#        ./verify.sh TASK-006 --nvim-only     # just validate the oracle
#        ./verify.sh all                       # run every TASK-*.lua in cases/
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"

TASK="$1"; shift || { echo "usage: $0 <task|all>"; exit 1; }

if [[ "$TASK" == "all" ]]; then
  pass=0; fail=0; err=0
  ZIGVIM="${ZIGVIM:-$ROOT/zig-out/bin/zigvim}"
  for f in "$ROOT/cases"/TASK-*.lua; do
    name=$(basename "$f" .lua)
    if python3 "$DIR/oracle.py" --test "$f" --zigvim "$ZIGVIM" "$@" 2>/dev/null; then
      ((pass++)); echo "  PASS $name"
    else
      ((fail++)); echo "  FAIL $name"
    fi
  done
  # TASK-INFRA-005 drives the RPC server over stdin/stdout, so it uses the
  # dedicated integration harness instead of a Lua oracle case.
  if python3 "$DIR/rpc_verify.py" --zigvim "$ZIGVIM" >/dev/null 2>&1; then
    ((pass++)); echo "  PASS TASK-INFRA-005"
  else
    ((fail++)); echo "  FAIL TASK-INFRA-005"
  fi
  echo ""; echo "=== $pass pass / $fail fail ==="
  [[ "$fail" -eq 0 ]]
  exit
fi

# TASK-INFRA-005 has no Lua case; it is verified end-to-end over the
# msgpack-RPC transport.
if [[ "$TASK" == "TASK-INFRA-005" ]]; then
  ZIGVIM="${ZIGVIM:-$ROOT/zig-out/bin/zigvim}"
  exec python3 "$DIR/rpc_verify.py" --zigvim "$ZIGVIM"
fi

# Single task
LUA="$ROOT/cases/$TASK.lua"
[[ -f "$LUA" ]] || { echo "missing: $LUA"; exit 2; }
ZIGVIM="${ZIGVIM:-$ROOT/zig-out/bin/zigvim}"
python3 "$DIR/oracle.py" --test "$LUA" --zigvim "$ZIGVIM" "$@"
