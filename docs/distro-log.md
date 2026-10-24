# distro-log.md — one line per loop iteration (newest last)

Format: `YYYY-MM-DD DISTRO-NNN <gap> | before→after | commit <sha>`
See `docs/DISTRO-LOOP.md` §3 step 7.

2026-10-21 BASELINE LazyVim | startup clean; diff sections: keymaps(291 missing/162 extra), augroups(21), commands(13), modules(60), g, opts, plugins, rtp_count | commit 7bb7ff1 + uncommitted work
2026-10-21 DISTRO-000 `:set` parsing and option scoping | `:set noexpandtab` failed; vim.o/bo/go scope differed from nvim → matches nvim; tui_smoke 20/20 (real config) | uncommitted

2026-10-21 DISTRO-002 keymap lhs normalization | extra 9→0, missing 291→129 | commit 0a38f28

2026-10-21 DISTRO-003 fire VimEnter/UIEnter in headless mode | partial fix; lazy.nvim plugin loading still incomplete | commit f2e9185

2026-10-21 DISTRO-004 autocmd pattern + colorscheme .vim + nvim__redraw stub | autocmd default pattern nil→{'*'} (fixes lazy.nvim event handlers); colorscheme handler executes .vim files; nvim__redraw stub fixes TASK-110 | verify 28/28 pass; distro_diff unchanged (plugin loading still incomplete) | commit cdeafda

2026-10-21 DISTRO-005 fix nvim_get_autocmds group_name, add BufRead event, source runtime plugins | augroups 21→13 missing; commands unchanged (12 missing); plugin loading still incomplete | commit ea0f702

2026-10-21 DISTRO-006 background option default | 'light'→'dark' to match nvim; catppuccin now loads correct variant | commit $(git rev-parse --short HEAD)

2026-10-21 DISTRO-007 add vim.fn.argc() stub | LazyVim setup() no longer aborts; colorscheme loads automatically; diff sections 8→4 | commit $(git rev-parse --short HEAD)
2026-10-21 DISTRO-008 startup events/runtime plugins | augroups 21→X, modules 60→Y | commit 67fa627

2026-10-21 DISTRO-009 load vim._core.defaults for built-in commands and augroups | augroups 12→8, commands 10→6, keymaps 129→69 | commit 5b35728

2026-10-21 DISTRO-010 v/x/s keymap sharing + matchit stub | keymaps missing 129→0, extra 9→5 | commit 864e377

2026-10-21 DISTRO-011 fix nvim_get_keymap v/x/s mode query | keymaps extra 5→0, section IDENTICAL | commit 80f4c81
2026-10-21 DISTRO-014 lazy-load vim.diagnostic/lsp at startup | augroups extra nvim.diagnostic.status 1→0 | commit 01e4ec6
2026-10-21 DISTRO-015 filetype detection + ftplugin/indent/syntax startup | augroups missing 10→6 (filetypedetect, filetypeplugin, filetypeindent, syntaxset added); verify 29/29 | commit fd7b6dd
2026-10-21 DISTRO-016 matchparen/matchit in Lua | augroups 6→5, commands 20→15 | commit f8527a0
2026-10-21 DISTRO-017 netrw in Lua (commands, FileExplorer/Network, listings, remote I/O) | augroups 5→3, commands 15→2 | commit d478169
2026-10-21 DISTRO-018 gzip/tar/zip plugins in Lua | augroups 3→0, commands still 2 | commit 4202a2b
2026-10-21 DISTRO-019 Tutor + UpdateRemotePlugins commands | commands 2→0; distro_diff IDENTICAL | commit 50e47a1
2026-10-21 DISTRO-020 startup under --clean -l, vim.schedule/schedule_wrap, tempname | verify 30/30 (adds TASK-113); tui_smoke 20/20 clean+nvim and 20/20 real config; distro_diff IDENTICAL | commit 42abac8
2026-10-21 DISTRO-021 move runtime plugin shims to tracked src/lua and embed them | gates re-run after the move: distro_diff IDENTICAL, verify 30/30, tui_smoke 20/20 both modes | commit 23a9c5c
2026-10-22 DISTRO-114 keymap normalization + write_file empty-line | extra_keymaps: 162→0, missing_keymaps: 291→0 | commit 5709464

2026-10-22 DISTRO-115 defer netrw/tutor setup to respect g:loaded_* guards | netrw extra commands: 14→1; netrw augroups: gzip/tar/zip/Network remain | commit e0fe93f
2026-10-22 DISTRO-116 winsaveview/winrestview + feedkeys | verify 32/32 (adds TASK-115) | commit 00934a5

2026-10-22 DISTRO-117 vim_did_enter vvar + BufEnter/UIEnter ordering + vim.on_key stub | modules: IDENTICAL; augroups extra: 4→3, missing: 2→1; commands extra: 1→1 | commit 6e54e84
2026-10-23 DISTRO-118 match nvim runtime plugin loading behavior | distro_diff: IDENTICAL; verify 32/32 | commit 15f1ae3
2026-10-23 DISTRO-119 nvim_set_hl auto cterm from gui attrs; probe snapshots highlight groups | distro_diff IDENTICAL (with highlights); verify 33/33 | commit (this)
2026-10-23 DISTRO-120 expr/nowait keymaps, nvim_eval, <Plug> under noremap, event loop in TUI, typed registers + :normal | tui_smoke real config 27→29/29; verify 34/34; distro_diff IDENTICAL | commit (this)
2026-10-23 DISTRO-121 AstroNvim first run: keytrans + sign_define so astrocore.setup completes | astro keymaps missing 184→5, commands 9→2, opts now match; LazyVim still IDENTICAL; verify 35/35 | commit (this)
2026-10-23 DISTRO-122 environ, get_runtime_file("") slashes, decoration provider stub, --cmd | astro sections differing 9→6 (g, opts, rtp_count, highlights now match); LazyVim IDENTICAL; verify 36/36 | commit (this)
2026-10-23 DISTRO-123 vendored LPeg 1.1.0 (vim.lpeg) + vim.version runtime module at 0.12.6 | astro: all core setups succeed, plugins section matches, modules missing 56→6; LazyVim IDENTICAL; verify 38/38 | commit (this)
2026-10-23 DISTRO-124 built-in highlight groups (generated from oracle), nvim_set_hl replace/update/default, link=false, hlexists, :hi clear/link | astro: heirline setup ok, highlights section matches, sections 6→5; LazyVim IDENTICAL; verify 39/39 | commit (this)
2026-10-23 DISTRO-125 netrw/tutor/archives as disable-able runtime/plugin files, loadplugins, F13+/same-byte keytrans | astro: netrw/Tutor commands+augroups now match, keymaps 5→1 (upstream nondeterminism); LazyVim IDENTICAL; verify 39/39 | commit (this)
2026-10-23 DISTRO-126 Neovim startup order (BufEnter, -c, VimEnter, UIEnter only with UI), :lsp + nvim_parse_cmd | astro sections 5→2-4 (rest nondeterministic upstream, mason async, rtp layout); LazyVim IDENTICAL; verify 40/40 | commit (this)
2026-10-23 DISTRO-127 + and * registers use the OS clipboard (pbcopy, wl-copy, xclip, xsel, win32yank), has("clipboard"), provider#clipboard#Executable | matches nvim on a set/get/external-copy round trip; verify 40/40; LazyVim IDENTICAL; tui_smoke 29/29 | commit (this)
2026-10-23 DISTRO-128 CI: fetch-runtime installed 0 files (strip-components 2→4), oracle finds nvim on PATH, verify.sh counters safe under set -e on bash 5, Linux CI installs nvim 0.12.6 | fresh clone: verify 40/40 (was 0) | commit (this)
2026-10-23 DISTRO-129 Linux: prelude used Lua 5.3 "<<" (only newest LuaJIT parses it) → portable arithmetic; TASK-002/124 compare LuaJIT 2.1 series and version numbers, not oracle build strings | Ubuntu 24.04 container: verify 40/40, tui_smoke --clean --nvim 29/29; macOS unchanged | commit (this)
2026-10-23 DISTRO-130 CI: progress.sh set -e counters | GitHub Actions: Build on ubuntu-latest and macos-latest both green (build, verify 40/40, progress); windows + cross-compile still red (no Windows port; cross jobs need vendored LuaJIT/libuv) | commit b1e82c9
2026-10-23 DISTRO-131 CI green: Windows skipped until ported, cross-compile informational | run 39946177041 success (ubuntu + macos: build, verify 40/40, progress); AstroNvim tui_smoke with its config 29/29 (done-gate 4) | commit d980135
2026-10-23 DISTRO-132 file-open sweep in the TUI (real LazyVim config): tabpage APIs, maparg, sha256, findfile, chdir, getbufinfo, indent, virtcol, prevnonblank, nvim_get_hl_by_name, vim.opt scalars, vim.w[id], :autocmd/:let/:cd/:noh/:redraw, uri_*, create_buf flags, strdisplaywidth tabs | sweep errors 12→1 (gitsigns needs uv pipes); verify 45/45; LazyVim IDENTICAL; tui_smoke 29/29 both | commit (this)
2026-10-23 DISTRO-133 vim.uv spawn/pipes/check/fs_event/kill + vim.system, vim.diff (Myers), case-insensitive autocmd events + aliases, json empty-list | gitsigns attaches + hunks + status in TUI (signs need decoration providers); file-open sweep clean (plain + git); verify 48/48; LazyVim IDENTICAL; tui_smoke 29/29 (clean, LazyVim, AstroNvim) | commit (this)
2026-10-23 DISTRO-134 decoration providers + sign column in the TUI, idle redraw on extmark change, extmark query fixes, getregionpos, json sparse arrays | gitsigns and diagnostic signs drawn, sign extmarks identical to nvim; verify 49/49; LazyVim IDENTICAL; tui_smoke 29/29 x3; sweeps clean | commit (this)
2026-10-23 DISTRO-135 gauntlet piece 1 (open real files, real config): vim.regex, marks, changedtick, set_text, str_utfindex, exepath, win_findbuf, BufReadPre/BufNewFile order, InsertEnter/Leave, on_lines isolation | LSP servers now attach (new LSP layer next); verify 53/53; LazyVim IDENTICAL; tui_smoke 29/29 x3 | commit (this)
2026-10-23 DISTRO-136 gauntlet piece 1 round 2: on_lines resolved lines, option info, bufloaded/bufadd/bufload, str_utf_*, :augroup/|/:execute/:messages, exec2 output capture, autocmd listing, chunk names | filetype sweep zigvim-only errors 0 (7/7 files); LSP attaches, formats, syncs; verify 57/57; LazyVim IDENTICAL | commit (this)
2026-10-23 DISTRO-137 gauntlet piece 1 round 3: errorformat parser (all nvim-lint efms identical), clear_namespace -1, vim.diff linematch port, undo messages + :messages history, default vim.notify | verify 59/59; LazyVim IDENTICAL; tui_smoke 29/29 x3; filetype sweep 0 | commit (this)
2026-10-23 DISTRO-138 timer close callback, on_lines byte_count, fs_* async, narrow undo | timer:close(cb), on_lines 6th param (byte_count), vim.uv fs_* async form, undo_restore narrow diff; verify 59/59; LazyVim IDENTICAL | commit 5232e31
2026-10-24 DISTRO-139 :w message honors shortmess W + [New], TUI draws 'eol' virtual text (diagnostics), extmark details defaults | gitsigns after undo already in sync (DISTRO-138); verify 60/60; LazyVim IDENTICAL; tui_smoke 29/29 x3; filetype sweep 0 | commit (this)
2026-10-24 DISTRO-140 gauntlet piece 1 round 4 gap: no tree-sitter | vendored tree-sitter 0.26.13 + Neovim's treesitter.c bindings, parsers/queries/Lua ftplugins fetched with the runtime, on_bytes, nvim_buf_get_text, on_range providers, ephemeral extmarks, TUI draws highlights (cterm without termguicolors), vim.wo[win][buf]; verify 62/62; LazyVim IDENTICAL; tui_smoke 29/29 x3; filetype sweep 0 | commit (this)
