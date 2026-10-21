# distro-log.md — one line per loop iteration (newest last)

Format: `YYYY-MM-DD DISTRO-NNN <gap> | before→after | commit <sha>`
See `docs/DISTRO-LOOP.md` §3 step 7.

2026-10-21 BASELINE LazyVim | startup clean; diff sections: keymaps(291 missing/162 extra), augroups(21), commands(13), modules(60), g, opts, plugins, rtp_count | commit 7bb7ff1 + uncommitted work
2026-10-21 DISTRO-000 `:set` parsing and option scoping | `:set noexpandtab` failed; vim.o/bo/go scope differed from nvim → matches nvim; tui_smoke 20/20 (real config) | uncommitted

2026-10-21 DISTRO-002 keymap lhs normalization | extra 9→0, missing 291→129 | commit 0a38f28

2026-10-21 DISTRO-003 fire VimEnter/UIEnter in headless mode | partial fix; lazy.nvim plugin loading still incomplete | commit f2e9185
