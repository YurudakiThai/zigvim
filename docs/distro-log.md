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
