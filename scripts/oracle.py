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
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

NVIM = shutil.which("nvim") or "/opt/homebrew/bin/nvim"
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
        # Neovim outputs to stderr when using -l flag
        output = result.stderr.strip() if result.stderr.strip() else result.stdout.strip()
        if not output:
            return {"_error": "no output", "stderr": result.stderr, "stdout": result.stdout}
        try:
            return json.loads(output)
        except json.JSONDecodeError as e:
            return {"_error": f"invalid json: {e}", "stdout": result.stdout, "stderr": result.stderr}
    except subprocess.TimeoutExpired:
        return {"_error": "timeout"}
    except Exception as e:
        return {"_error": str(e)}
    finally:
        os.unlink(lua_path)


def normalize_json_strings(obj):
    """Recursively parse and normalize JSON strings within objects.
    
    This handles the case where a field contains a JSON string (like vim.json.encode output).
    We parse it, then re-serialize with sorted keys so comparison is order-independent.
    """
    if isinstance(obj, dict):
        for key, value in obj.items():
            if isinstance(value, str):
                try:
                    # Try to parse as JSON
                    parsed = json.loads(value)
                    # Re-serialize with sorted keys for deterministic comparison
                    obj[key] = json.dumps(parsed, sort_keys=True, separators=(',', ':'))
                except (json.JSONDecodeError, ValueError):
                    pass  # Not a JSON string, keep as-is
            else:
                normalize_json_strings(value)
    elif isinstance(obj, list):
        for item in obj:
            normalize_json_strings(item)


def deep_equal(a, b) -> bool:
    """Deep equality check for JSON-serializable objects.
    
    Normalizes JSON strings to handle non-deterministic key ordering in Lua tables.
    """
    normalize_json_strings(a)
    normalize_json_strings(b)
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
