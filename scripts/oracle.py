#!/usr/bin/env python3
"""
Vibe-coding oracle: run a Lua test case against real nvim (ground truth)
and compare to zigvim output. Stdlib-only (no pip install).

Usage:
  python3 oracle.py --test cases/TASK-006.lua --zigvim ../zig-out/bin/zigvim
  python3 oracle.py --test cases/TASK-006.lua --nvim-only

Exit codes:
  0 = PASS (zigvim matches nvim)
  1 = FAIL (output differs)
  2 = ERROR (crash, timeout, or nvim unavailable)
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

NVIM = "/opt/homebrew/bin/nvim"
TIMEOUT = 10  # seconds


def run_nvim_lua(lua_code: str, nvim_bin: str = NVIM) -> dict:
    """Run Lua code in headless nvim, return JSON output as dict."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False) as f:
        f.write(lua_code)
        lua_path = f.name
    try:
        result = subprocess.run(
            [nvim_bin, "--headless", "--clean", "-l", lua_path, "-c", "qa!"],
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
        stdout = result.stdout.strip()
        if not stdout:
            return {"_error": "no output", "stderr": result.stderr}
        try:
            return json.loads(stdout)
        except json.JSONDecodeError as e:
            return {"_error": f"invalid json: {e}", "stdout": stdout, "stderr": result.stderr}
    except subprocess.TimeoutExpired:
        return {"_error": "timeout"}
    except Exception as e:
        return {"_error": str(e)}
    finally:
        os.unlink(lua_path)


def deep_equal(a, b) -> bool:
    """Deep equality check for JSON-serializable objects."""
    return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)


def show_diff(a, b):
    """Pretty-print the difference between two dicts."""
    print("\n" + "=" * 60)
    print("NVIM (oracle):")
    print(json.dumps(a, indent=2, sort_keys=True))
    print("\nZIGVIM:")
    print(json.dumps(b, indent=2, sort_keys=True))
    print("=" * 60 + "\n")


def main():
    parser = argparse.ArgumentParser(description="Vibe-coding oracle")
    parser.add_argument("--test", required=True, help="Path to Lua test file")
    parser.add_argument("--zigvim", help="Path to zigvim binary")
    parser.add_argument("--nvim-only", action="store_true", help="Only run nvim, skip zigvim")
    parser.add_argument("--show-output", action="store_true", help="Show nvim output even on success")
    args = parser.parse_args()

    test_path = Path(args.test)
    if not test_path.exists():
        print(f"ERROR: test file not found: {test_path}", file=sys.stderr)
        sys.exit(2)

    lua_code = test_path.read_text()
    print(f"Running test: {test_path.name}")
    print(f"  nvim: {NVIM}")
    if not args.nvim_only:
        print(f"  zigvim: {args.zigvim or '(not specified)'}")

    # Run nvim (oracle)
    nvim_out = run_nvim_lua(lua_code, NVIM)
    if "_error" in nvim_out:
        print(f"FAIL: nvim error: {nvim_out}", file=sys.stderr)
        sys.exit(2)

    if args.nvim_only:
        if args.show_output:
            print("\nNVIM OUTPUT:")
            print(json.dumps(nvim_out, indent=2, sort_keys=True))
        print("PASS (nvim-only mode)")
        sys.exit(0)

    if not args.zigvim:
        print("ERROR: --zigvim required (or use --nvim-only)", file=sys.stderr)
        sys.exit(2)

    if not Path(args.zigvim).exists():
        print(f"ERROR: zigvim not found: {args.zigvim}", file=sys.stderr)
        sys.exit(2)

    # Run zigvim
    zigvim_out = run_nvim_lua(lua_code, args.zigvim)
    if "_error" in zigvim_out:
        print(f"FAIL: zigvim error: {zigvim_out}", file=sys.stderr)
        sys.exit(1)

    # Compare
    if deep_equal(nvim_out, zigvim_out):
        print("PASS: zigvim matches nvim")
        if args.show_output:
            print("\nOUTPUT:")
            print(json.dumps(nvim_out, indent=2, sort_keys=True))
        sys.exit(0)
    else:
        print("FAIL: output differs")
        show_diff(nvim_out, zigvim_out)
        sys.exit(1)


if __name__ == "__main__":
    main()
