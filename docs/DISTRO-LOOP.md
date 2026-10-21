# DISTRO-LOOP.md — The coding loop for "behaves like Neovim, runs LazyVim / AstroNvim"

> Read `AGENTS.md` first for the general protocol. This file is the **loop** an
> agent runs, over and over, until a real Neovim distribution behaves in zigvim
> exactly as it does in Neovim 0.12.6. It replaces guessing with measurement.

---

## 0. Goal and definition of done

zigvim is "done" for a distribution when **all** of these hold:

1. `python3 scripts/distro_diff.py --config <distro>` prints `IDENTICAL`.
2. `./scripts/verify.sh all` — every case passes (currently 28/28).
3. `python3 scripts/tui_smoke.py --clean --nvim` — 100% and agrees with real nvim.
4. `python3 scripts/tui_smoke.py` (your real config loaded) — 100%.
5. Starting the distribution prints **no** error or warning that real nvim does not print.

Distributions in scope: **LazyVim** (measured, see §9) and **AstroNvim** (not yet
run, see §7). Anything that loads through lazy.nvim should follow.

---

## 1. Ground rules (never break these)

1. **Oracle is law.** Real `nvim` (v0.12.6, `/opt/homebrew/bin/nvim`) decides what is correct.
   If you are unsure what an API returns, run it in nvim first:
   `nvim --headless --clean -c 'lua print(vim.inspect(<expr>))' -c 'qa!'`
2. **Never touch the user's real `~/.config/nvim` or `~/.local/share/nvim`.**
   `distro_diff.py` works in a sandbox copy. For any other experiment set
   `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` to a temp dir.
   Never run real nvim against the real config headlessly: lazy.nvim will install
   missing plugins into the real data dir.
3. **Fix zigvim, never the config, never the test.** Do not edit the distro, delete a
   failing probe field, or loosen an expected value to get green. A test may only
   change if real nvim proves the test is wrong (show the nvim output).
4. **One gap per iteration, one commit per iteration.** ≤ 500 lines changed.
   Commit format: `feat(DISTRO-NNN): short description` or `fix(DISTRO-NNN): ...`.
5. **No silent stubs.** A stub is allowed only if it is listed in §6 with the reason and
   the condition for removing it. A stub that hides an error nvim would not hide is a bug.
6. **The probe grows with the goal.** If you discover a behavior that matters but
   `distro_probe.lua` cannot see it (LSP, treesitter, diagnostics, highlights, ...), extend
   the probe *first*, show the diff, then fix. Otherwise the loop cannot prove progress.
7. **Never claim success without running the gates in §3 step 6.** Paste the real output.

---

## 2. Tools (all stdlib Python / shell; nothing to install)

| Command | What it proves |
|---|---|
| `zig build` | Compiles. `src/prelude.lua` and `src/tui.lua` are **embedded at build time** — after editing them you must rebuild or you are testing the old code. |
| `./scripts/verify.sh all` | API behavior matches nvim, case by case (`cases/TASK-*.lua` → oracle). |
| `./scripts/verify.sh TASK-NNN --nvim-only --show-output` | What real nvim returns for a case. |
| `python3 scripts/distro_diff.py [--config DIR] [--data DIR] [--json F] [--limit N]` | Loads the same distro in nvim and zigvim (sandboxed), diffs: globals, 40 options, keymaps, user commands, augroups, lazy.nvim plugin load state, loaded modules, runtimepath size, plus any message only zigvim prints. |
| `python3 scripts/tui_smoke.py [--clean] [--nvim] [-k NAME]` | Real keystrokes through a pseudo-terminal; checks the saved file. `--nvim` also runs each case in real nvim. |
| `zigvim --headless -c 'lua ...' -c 'qa!'` | Quick probe of any API. Always pipe stdin from `/dev/null`. |

Environment notes learned the hard way:
- The TUI only starts when stdin **and** stdout are a tty. Anything run from a plain
  pipe (CI, tool runners) exercises only the headless path — use `tui_smoke.py` for the TUI.
- macOS has no `timeout`; use `perl -e 'alarm 60; exec @ARGV' cmd ...`.
- `zigvim` finds `runtime/` next to its binary (`<project>/zig-out/bin/..`); override with
  `ZIGVIM_RUNTIME=/path/to/runtime`.
- Run long suites in separate calls; `tui_smoke.py` takes about 80 s per mode.

---

## 3. The loop

Repeat until §0 holds. Each pass is one gap.

```
1 MEASURE  →  2 SELECT  →  3 ORACLE  →  4 CASE  →  5 IMPLEMENT  →  6 GATES  →  7 COMMIT+LOG
     ↑                                                                              │
     └──────────────────────────────────────────────────────────────────────────────┘
```

**1. MEASURE** — get fresh numbers; never trust memory of the last run.
```bash
zig build
python3 scripts/distro_diff.py --json /tmp/before.json --limit 10
```
Read `docs/distro-log.md` to see what was already tried.

**2. SELECT** — pick exactly one gap using the priority order in §4.

**3. ORACLE** — reproduce the gap in isolation, in both editors, with the smallest input:
```bash
nvim --headless --clean -c 'lua <minimal repro>' -c 'qa!'
zigvim --headless --clean -c 'lua <minimal repro>' -c 'qa!' < /dev/null
```
Write down the exact nvim output. If the distro's source is involved, read it
(`~/.local/share/nvim/lazy/<plugin>/lua/...`) to see which API call actually fails.

**4. CASE** — encode the repro as `cases/TASK-1NN.lua` (+ `tasks/TASK-1NN.md` from
`tasks/TASK-TEMPLATE.md`), confirm it **fails** in zigvim and records nvim's answer:
`./scripts/verify.sh TASK-1NN --nvim-only --show-output`. For TUI behavior add a case
to `scripts/tui_smoke.py` instead.

**5. IMPLEMENT** — smallest change in the right layer (§5). Prefer reading Neovim's own
runtime Lua (`runtime/lua/vim/*.lua`) over re-inventing; implement the missing primitive
underneath it.

**6. GATES** — all must pass, paste the tail of each:
```bash
zig build 2>&1 | tail
./scripts/verify.sh all | tail -3                      # no FAIL
python3 scripts/distro_diff.py --json /tmp/after.json   # targeted section shrank,
                                                        # no section grew vs /tmp/before.json
python3 scripts/tui_smoke.py --clean --nvim -k <area>  # when TUI/editing code changed
```
Non-regression is by **count per section** (`missing_in_zigvim`, `extra_in_zigvim`,
`changed`): none may increase; the section you targeted must decrease or disappear.

**7. COMMIT + LOG** — one commit, then append one line to `docs/distro-log.md`:
`YYYY-MM-DD DISTRO-NNN <gap> | before→after counts | commit <sha>`.

---

## 4. Priority order for choosing a gap

1. **Anything zigvim prints that nvim doesn't** (`zigvim-only startup messages` in the
   diff) — these are crashes/missing APIs, they block everything downstream.
2. **Wrong data in what already exists** (e.g. keymap normalization, option values).
3. **Missing startup behavior** the distro depends on (events, runtime plugins, colorscheme).
4. **Missing subsystems** the distro uses lazily (job control, LSP, treesitter, diagnostics).
5. **Polish** (rarely-used commands, cosmetic differences).

Inside a tier prefer the gap with the largest count in the diff, since one root cause
usually explains many rows (e.g. 291 "missing keymaps" is mostly one normalization bug).

---

## 5. Where a change belongs

| Layer | File | Put here |
|---|---|---|
| Zig core | `src/main.zig`, `src/platform/` | Buffers/windows/tabs, libuv handles (timers, spawn, fs), terminal I/O, RPC. Anything needing the OS or speed. |
| Lua API layer | `src/prelude.lua` | `vim.api.*`, `vim.fn.*`, options, autocmds, keymaps, Ex commands, `vim.cmd`, rtp/`require` resolution. |
| TUI | `src/tui.lua` | Rendering, normal/insert/visual/command-line modes. Must call the same `vim.api`/`vim.cmd` a plugin would, not private state. |
| Neovim runtime | `runtime/` (fetched by `scripts/fetch-runtime.sh`) | Never edit. It is Neovim's own Lua; make zigvim run it. |

Rule of thumb: if a plugin can observe it, it must go through `vim.api` — not hide in the TUI.

---

## 6. Stub register (every stub must be listed here)

| Stub | Why | Remove when |
|---|---|---|
| `vim.loader` (no-op `enable`, simple `find`) | Neovim's loader needs most of libuv's fs API. | `fs_*` API is complete (see `runtime/lua/vim/loader.lua`). |
| `vim.uv.new_check` (inert handle) | No per-iteration loop hook yet. | Event loop drives check/idle handles. |
| `source` skips `.vim` files | No Vimscript engine. | Vimscript runtime sourcing is needed by a distro. |
| `augroup`, `packadd`, `filetype`, `syntax`, `highlight` Ex commands accepted and ignored | No highlighter / Vimscript behind them. | Highlight groups and `:syntax` exist. |
| `vim.fn.getcompletion` handles only `color` | Only completion kind lazy.nvim needs. | A plugin needs other kinds. |
| `vim.fn.getchar` returns 27 | Only used on lazy.nvim's failure path. | Real input queue is exposed to Lua. |

When you add or remove a stub, edit this table in the same commit.

---

## 7. Adding a distribution

The harness takes any config dir; the distro runs against a **sandbox copy**.

**LazyVim (your current setup)** — `python3 scripts/distro_diff.py`

**AstroNvim** — *not yet run; treat the first run as exploratory:*
```bash
git clone --depth 1 https://github.com/AstroNvim/template /tmp/astro-template
rm -rf /tmp/astro-template/.git
python3 scripts/distro_diff.py --config /tmp/astro-template --data /nonexistent \
    --timeout 900 --json /tmp/astro-diff.json
```
With an empty `--data`, real nvim clones all plugins into the sandbox first (minutes,
needs network); zigvim then runs against the plugins nvim installed. Expect the first
runs to be dominated by "zigvim-only startup messages" (missing APIs). Work through
them with the loop in §3 exactly as for LazyVim, and add AstroNvim's numbers to
`docs/distro-log.md`. Plugins that need compiled parsers or language servers are out of
scope until §4 tier 4 is reached.

Other distros (NvChad, LunarVim, kickstart) follow the same recipe.

---

## 8. When to stop and ask the human

- The fix needs a design decision (new Zig dependency, changing the RPC protocol, a new
  subsystem such as treesitter or LSP).
- A gate cannot be made to pass without weakening a test (rule 3).
- Two consecutive passes make no progress on the same gap.
- The next gap needs credentials, network access you don't have, or touches the real config.

State the blocker, what you tried, and the exact output; don't guess.

---

## 9. Baseline — LazyVim, 2026-10-21 (measured, nvim 0.12.6)

`python3 scripts/distro_diff.py` on the author's config: both editors start without
errors (0.1 s), but 8 sections still differ (`augroups`, `commands`, `g`, `keymaps`, `modules`, `opts`, `plugins`, `rtp_count`). Likely root causes, in suggested order:

| Section | Diff | Likely cause |
|---|---|---|
| `keymaps` | 291 missing / 162 extra | `nvim_get_keymap` returns `lhs` as written; nvim normalizes it (`<c-s>`→`<C-S>`, `<leader>`→the actual key, `<Plug>` kept whole). One bug explains most rows; `n:<P` shows `<Plug>…` is being truncated. |
| `g` / `plugins` / `modules` / `rtp_count` / `opts.background` | colorscheme `catppuccin-mocha` not applied; 60 catppuccin modules not loaded | Colorscheme plugin is never loaded: lazy.nvim's `install.colorscheme` / `:colorscheme` path doesn't trigger plugin loading, so `vim.g.colors_name` stays unset. `laststatus` likely follows once startup events run. |
| `augroups` | 21 missing | Neovim's own runtime plugins (`filetypedetect`, `nvim.*`, `matchparen`) aren't sourced (`runtime/plugin/*`); `LazyVim`, `lazy_handler_event` need the `VeryLazy`/`UIEnter` events to fire. |
| `commands` | 13 missing | Same two causes: runtime plugin commands (`Inspect`, `Man`, `DoMatchParen`, ...) and plugin commands that never loaded (`Catppuccin*`). |

Not measured yet (extend the probe first, rule 6): job control (`jobstart`, `uv.spawn`),
`vim.diagnostic`, `vim.lsp`, `vim.treesitter`, highlight groups, window/split layout,
statusline/tabline, `:terminal`, cmdline completion. These are what make a distro
*feel* like Neovim and each is a larger sub-project: open one task card per subsystem.

---

## 10. Pitfalls already hit

- Tests that assume option defaults break under a distro (LazyVim sets `expandtab`,
  `shiftwidth=2`): set options explicitly inside the test.
- Plugins add flag options (`shortmess`) through unordered tables, so character order
  differs run to run: compare as sets (the harness does).
- `:set noexpandtab` silently failed because the `no` prefix check compared 3 characters
  with a 2-character string — when a feature "works in clean mode" suspect defaults
  masking a bug, and test with a non-default value.
- `vim.o.x = v` sets the global value **and** the current buffer's value for
  buffer-local options; `vim.bo.x = v` sets only the buffer; `vim.go.x` is global only;
  buffers without their own value inherit the global one. Match this exactly.
- Test results printed as "got X want X" with `still_running=True` are a harness timing
  problem, not an editor bug — wait for the process to exit before judging.
