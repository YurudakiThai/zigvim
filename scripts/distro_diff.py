#!/usr/bin/env python3
"""
Distro compatibility check: load the same Neovim distribution (LazyVim,
AstroNvim, ...) under real nvim and under zigvim, snapshot the observable
state with scripts/distro_probe.lua, and report every difference.

The run happens in a throw-away sandbox (copy of the config + copy-on-write
copy of the plugin data dir) so neither editor can modify your real
~/.config/nvim or ~/.local/share/nvim. Plugins missing from the data dir are
cloned into the sandbox only.

Usage:
  python3 scripts/distro_diff.py                          # ~/.config/nvim
  python3 scripts/distro_diff.py --config ~/astro-template --data ~/.local/share/astronvim
  python3 scripts/distro_diff.py --json /tmp/diff.json    # machine-readable
  python3 scripts/distro_diff.py --keep                   # keep the sandbox for debugging

Exit codes: 0 = identical, 1 = differences, 2 = a run failed (crash/timeout).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "scripts" / "distro_probe.lua"
NVIM_DEFAULT = shutil.which("nvim") or "/opt/homebrew/bin/nvim"


def clone_tree(src: Path, dst: Path) -> None:
    """Copy a directory tree, using copy-on-write when the filesystem has it."""
    if not src.exists():
        dst.mkdir(parents=True)
        return
    if sys.platform == "darwin":
        cmd = ["cp", "-cR", str(src), str(dst)]
    else:
        cmd = ["cp", "-R", "--reflink=auto", str(src), str(dst)]
    if subprocess.run(cmd, capture_output=True).returncode != 0:
        shutil.copytree(src, dst, symlinks=True)


def make_sandbox(config: Path, data: Path, tmp: Path) -> dict:
    # Both editors share this HOME: nvim installs missing plugins into the
    # sandbox data dir first, then zigvim must see exactly those plugins.
    # Only state/cache are split per editor (see run_editor).
    sandbox_home = tmp / "home"
    sandbox_home.mkdir(parents=True)
    shutil.copytree(config, sandbox_home / ".config" / "nvim", symlinks=True, ignore=shutil.ignore_patterns(".git"))
    clone_tree(data, sandbox_home / ".local" / "share" / "nvim")
    for name in ("state", "cache"):
        (sandbox_home / ".local" / name).mkdir(parents=True)
    
    env = dict(os.environ)
    env.update(
        HOME=str(sandbox_home),
        GIT_TERMINAL_PROMPT="0",
    )
    return env


def run_editor(name: str, binary: str, env: dict, out_path: Path, timeout: int) -> dict:
    # Keep the sandbox HOME (config + plugin data) shared so plugins nvim
    # installs are visible to zigvim, but isolate ephemeral state and cache so
    # the two runs cannot observe each other's shada/lazy state.
    scratch = out_path.parent
    editor_state = scratch / f"state-{name}"
    editor_cache = scratch / f"cache-{name}"
    editor_state.mkdir(exist_ok=True)
    editor_cache.mkdir(exist_ok=True)

    env = dict(
        env,
        XDG_STATE_HOME=str(editor_state),
        XDG_CACHE_HOME=str(editor_cache),
        PROBE_OUT=str(out_path),
    )
    cmd = [binary, "--headless", "-c", f"lua dofile('{PROBE}')", "-c", "qa!"]
    started = time.time()
    try:
        proc = subprocess.run(
            cmd, env=env, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL
        )
    except subprocess.TimeoutExpired:
        return {"name": name, "ok": False, "error": f"timeout after {timeout}s", "elapsed": timeout}
    elapsed = time.time() - started
    snapshot = None
    if out_path.exists():
        try:
            snapshot = json.loads(out_path.read_text())
        except json.JSONDecodeError as exc:
            return {"name": name, "ok": False, "error": f"probe output is not JSON: {exc}", "elapsed": elapsed}
    messages = (proc.stdout + proc.stderr).strip().splitlines()
    return {
        "name": name,
        "ok": snapshot is not None,
        "snapshot": snapshot,
        "messages": messages,
        "exit": proc.returncode,
        "elapsed": elapsed,
        "error": None if snapshot is not None else "probe did not write a snapshot (see messages)",
    }


# Flag-string options: the order of the characters carries no meaning (and
# plugins add them through unordered tables), so compare them as sets.
FLAG_OPTIONS = {"shortmess", "formatoptions", "cpoptions", "guioptions", "mouse"}


def normalize(snapshot: dict) -> dict:
    opts = snapshot.get("opts")
    if isinstance(opts, dict):
        snapshot = dict(snapshot)
        snapshot["opts"] = {
            k: "".join(sorted(v)) if k in FLAG_OPTIONS and isinstance(v, str) else v for k, v in opts.items()
        }
    return snapshot


def diff_snapshots(nvim: dict, zig: dict) -> dict:
    nvim, zig = normalize(nvim), normalize(zig)
    result = {}
    for key in sorted(set(nvim) | set(zig)):
        a, b = nvim.get(key), zig.get(key)
        if a == b:
            continue
        if isinstance(a, dict) and isinstance(b, dict):
            changed = {
                k: {"nvim": a.get(k), "zigvim": b.get(k)}
                for k in sorted(set(a) | set(b))
                if a.get(k) != b.get(k)
            }
            result[key] = {"changed": changed}
        elif isinstance(a, list) and isinstance(b, list):
            result[key] = {
                "missing_in_zigvim": sorted(set(map(str, a)) - set(map(str, b))),
                "extra_in_zigvim": sorted(set(map(str, b)) - set(map(str, a))),
            }
        else:
            result[key] = {"nvim": a, "zigvim": b}
    return result


def show(items, limit):
    for item in items[:limit]:
        print(f"      {item}")
    if len(items) > limit:
        print(f"      ... and {len(items) - limit} more")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(Path.home() / ".config" / "nvim"))
    ap.add_argument("--data", default=str(Path.home() / ".local" / "share" / "nvim"))
    ap.add_argument("--nvim", default=NVIM_DEFAULT)
    ap.add_argument("--zigvim", default=os.environ.get("ZIGVIM", str(ROOT / "zig-out" / "bin" / "zigvim")))
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--limit", type=int, default=25, help="max items listed per section")
    ap.add_argument("--json", help="write the full diff as JSON to this path")
    ap.add_argument("--keep", action="store_true", help="keep the sandbox directory")
    args = ap.parse_args()

    config, data = Path(args.config).expanduser(), Path(args.data).expanduser()
    if not config.is_dir():
        print(f"config dir not found: {config}", file=sys.stderr)
        return 2

    tmp = Path(tempfile.mkdtemp(prefix="zigvim-distro-"))
    try:
        env = make_sandbox(config, data, tmp)
        nv = run_editor("nvim", args.nvim, env, tmp / "nvim.json", args.timeout)
        zg = run_editor("zigvim", args.zigvim, env, tmp / "zigvim.json", args.timeout)

        print(f"config: {config}")
        print(f"nvim   : {'ok' if nv['ok'] else 'FAILED'}  {nv['elapsed']:.1f}s")
        print(f"zigvim : {'ok' if zg['ok'] else 'FAILED'}  {zg['elapsed']:.1f}s")

        # Startup messages from zigvim are the most direct signal of a missing API.
        zmsgs = [m for m in zg.get("messages", []) if m.strip()]
        nmsgs = set(m for m in nv.get("messages", []) if m.strip())
        new_msgs = [m for m in zmsgs if m not in nmsgs]
        if new_msgs:
            print("\nzigvim-only startup messages (fix these first):")
            show(new_msgs, args.limit)

        if not nv["ok"]:
            print(f"\nnvim run failed: {nv['error']}")
            show(nv.get("messages", []), 10)
            return 2
        if not zg["ok"]:
            print(f"\nzigvim run failed: {zg['error']}")
            show(zg.get("messages", []), 10)
            return 2

        diff = diff_snapshots(nv["snapshot"], zg["snapshot"])
        if args.json:
            Path(args.json).write_text(json.dumps({"diff": diff, "zigvim_only_messages": new_msgs}, indent=2))

        if not diff and not new_msgs:
            print("\nIDENTICAL: zigvim matches nvim for this distribution")
            return 0

        print(f"\n{len(diff)} section(s) differ:")
        for key, detail in diff.items():
            print(f"\n  [{key}]")
            if "changed" in detail:
                show([f"{k}: nvim={v['nvim']!r} zigvim={v['zigvim']!r}" for k, v in detail["changed"].items()], args.limit)
            elif "missing_in_zigvim" in detail:
                if detail["missing_in_zigvim"]:
                    print(f"    missing in zigvim ({len(detail['missing_in_zigvim'])}):")
                    show(detail["missing_in_zigvim"], args.limit)
                if detail["extra_in_zigvim"]:
                    print(f"    extra in zigvim ({len(detail['extra_in_zigvim'])}):")
                    show(detail["extra_in_zigvim"], args.limit)
            else:
                print(f"      nvim={detail['nvim']!r}\n      zigvim={detail['zigvim']!r}")
        return 1
    finally:
        if args.keep:
            print(f"\nsandbox kept at {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
