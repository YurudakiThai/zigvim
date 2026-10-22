#!/usr/bin/env python3
"""
TUI smoke test: drive the interactive zigvim UI through a pseudo-terminal,
send real keystrokes, and check the resulting file contents. Stdlib only.

Each case is (initial file, keystrokes, expected file after zigvim exits).
Cases that must be compared against Neovim can be checked with --nvim, which
runs the same keystrokes in real nvim (the oracle) and requires both to agree.

Usage:
  python3 scripts/tui_smoke.py                 # uses your real config
  python3 scripts/tui_smoke.py --clean         # skip init.lua (pure editor behaviour)
  python3 scripts/tui_smoke.py --nvim          # also check the cases against real nvim
  python3 scripts/tui_smoke.py -k yyp          # only cases whose name contains "yyp"

Exit code: 0 when every case passes, 1 otherwise.
"""
import argparse
import fcntl
import os
import pty
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ESC = b"\x1b"

# name: (initial text, keystrokes, expected text after exit[, extra command-line args])
CASES = {
    "dd": ("a\nb\nc\n", [b"dd", b":w\r", b":q\r"], "b\nc\n"),
    "dd then undo": ("a\nb\nc\n", [b"dd", b"u", b":w\r", b":q\r"], "a\nb\nc\n"),
    "yyp": ("a\nb\n", [b"yyp", b":w\r", b":q\r"], "a\na\nb\n"),
    "G then o": ("a\nb\n", [b"G", b"onew", ESC, b":wq\r"], "a\nb\nnew\n"),
    "search then x": ("foo\nbar\nbaz\n", [b"/baz\r", b"x", b":wq\r"], "foo\nbar\naz\n"),
    "visual d": ("hello world\n", [b"v", b"e", b"d", b":wq\r"], " world\n"),
    "cw": ("hello world\n", [b"cw", b"HI", ESC, b":wq\r"], "HI world\n"),
    "3x": ("abcdef\n", [b"3x", b":wq\r"], "def\n"),
    "q! discards": ("a\n", [b"ix", ESC, b":q!\r"], "a\n"),
    "ZZ saves": ("a\n", [b"Ax", ESC, b"ZZ"], "ax\n"),
    "dw": ("one two three\n", [b"dw", b":wq\r"], "two three\n"),
    "ciw": ("one two three\n", [b"w", b"ciw", b"2", ESC, b":wq\r"], "one 2 three\n"),
    "J joins": ("a\nb\n", [b"J", b":wq\r"], "a b\n"),
    "dot repeat": ("a b c d\n", [b"dw", b".", b":wq\r"], "c d\n"),
    "dgg": ("a\nb\nc\n", [b"j", b"dgg", b":wq\r"], "c\n"),
    "r replace": ("abc\n", [b"rx", b":wq\r"], "xbc\n"),
    "~ toggles case": ("abc\n", [b"~", b":wq\r"], "Abc\n"),
    # Sets its own indent options so the result does not depend on the user's config.
    ">> indent": ("a\n", [b":set noexpandtab shiftwidth=8 tabstop=8\r", b">>", b":wq\r"], "\ta\n"),
    "p after dd": ("a\nb\n", [b"dd", b"p", b":wq\r"], "b\na\n"),
    "visual line d": ("a\nb\nc\n", [b"V", b"j", b"d", b":wq\r"], "c\n"),
    # User mappings (-c runs after init.lua, so these also work with a distro loaded).
    "map nnoremap": ("a\nb\n", [b"Q", b":wq\r"], "b\n", ["-c", "nnoremap Q dd"]),
    "map remap chain": ("a\nb\n", [b"Q", b":wq\r"], "b\n", ["-c", "nmap Q W", "-c", "nnoremap W dd"]),
    "map insert jk": ("a\n", [b"ix", b"jk", b":wq\r"], "xa\n", ["-c", "inoremap jk <Esc>"]),
    "map prefix falls back": ("a\n", [b"ijx", ESC, b":wq\r"], "jxa\n", ["-c", "inoremap jk <Esc>"]),
    "map lua callback": (
        "a\nb\n",
        [b"Q", b":wq\r"],
        "b\n",
        ["-c", "lua vim.keymap.set('n','Q',function() vim.api.nvim_buf_set_lines(0,0,1,false,{}) end)"],
    ),
    "map leader": (
        "a\nb\n",
        [b" x", b":wq\r"],
        "b\n",
        ["-c", "lua vim.g.mapleader=' '", "-c", "nnoremap <leader>x dd"],
    ),
    "map <C-s> to :w": ("a\n", [b"x", b"\x13", b":q!\r"], "\n", ["-c", "nnoremap <C-s> :w<CR>"]),
    "map <Cmd>": ("a\n", [b"x", b"\x13", b":q!\r"], "\n", ["-c", "nnoremap <C-s> <Cmd>w<CR>"]),
    "map visual": ("abc\n", [b"v", b"l", b"Q", b":wq\r"], "c\n", ["-c", "xnoremap Q d"]),
}


def run_session(argv, text, keys, step=0.3, startup=1.5):
    """Run `argv + [file]` in a pty, feed keys, return (file text, still_running)."""
    tmp = Path(tempfile.mkdtemp(prefix="zigvim-tui-"))
    path = tmp / "t.txt"
    path.write_text(text)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.chdir(ROOT)
        try:
            os.execv(argv[0], argv + [str(path)])
        finally:
            os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))

    def drain(seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    if not os.read(fd, 65536):
                        return False
                except OSError:
                    return False
        return True

    drain(startup)
    for key in keys:
        os.write(fd, key)
        if not drain(step):
            break
    drain(0.6)
    # Give the process a moment to exit and be reaped before judging it "running".
    running = True
    deadline = time.time() + 2.0
    while time.time() < deadline:
        if os.waitpid(pid, os.WNOHANG)[0] != 0:
            running = False
            break
        time.sleep(0.05)
    if running:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    result = path.read_text()
    shutil.rmtree(tmp, ignore_errors=True)
    return result, running


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zigvim", default=os.environ.get("ZIGVIM", str(ROOT / "zig-out" / "bin" / "zigvim")))
    ap.add_argument("--nvim", action="store_true", help="also run each case in real nvim as the oracle")
    ap.add_argument("--clean", action="store_true", help="pass --clean (skip init.lua)")
    ap.add_argument("-k", default="", help="only run cases whose name contains this text")
    args = ap.parse_args()

    zig_argv = [args.zigvim] + (["--clean"] if args.clean else [])
    nvim_bin = shutil.which("nvim") or "/opt/homebrew/bin/nvim"
    nvim_argv = [nvim_bin, "--clean"]

    failed = 0
    selected = {k: v for k, v in CASES.items() if args.k in k}
    for name, case in selected.items():
        text, keys, want = case[:3]
        extra = case[3] if len(case) > 3 else []
        got, running = run_session(zig_argv + extra, text, keys)
        notes = []
        if args.nvim:
            oracle, _ = run_session(nvim_argv + extra, text, keys)
            if oracle != want:
                notes.append(f"nvim itself gives {oracle!r} (case expectation may be wrong)")
            if oracle != got:
                notes.append(f"differs from nvim: nvim={oracle!r}")
        ok = got == want and not running and not notes
        failed += 0 if ok else 1
        line = f"{'PASS' if ok else 'FAIL'}  {name}"
        if not ok:
            line += f"\n      got={got!r} want={want!r} still_running={running}"
            for note in notes:
                line += f"\n      {note}"
        print(line)
    print(f"\n{len(selected) - failed}/{len(selected)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
