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
2026-10-22 DISTRO-116 winsaveview/winrestview + feedkeys | verify 32/32 (adds TASK-115) | commit pending
