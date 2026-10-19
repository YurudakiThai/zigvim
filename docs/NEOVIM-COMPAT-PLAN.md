# Neovim-Compatible Architecture Plan

**Version:** 2.0  
**Date:** 2026-10-19  
**Status:** Planning Phase  
**Goal:** Build a Neovim-compatible editor in Zig that works on Windows, macOS, and Linux

---

## 🎯 North Star

zigvim must be able to:
- ✅ Run `:lua vim.cmd('Lazy! sync')` (lazy.nvim plugin manager)
- ✅ Load LazyVim core plugins (which-key, telescope, neo-tree)
- ✅ Edit files with syntax highlighting + LSP diagnostics
- ✅ Connect to external UI clients (neovide, nvim-qt) via msgpack-RPC

---

## 🏗️ Architecture (3 Layers)

```
┌─────────────────────────────────────────────────────┐
│  Layer 2: UI Clients (external, via msgpack-RPC)    │
│  ├── zigvim-tui (Zig) — default TUI                │
│  ├── neovide, nvim-qt, goneovim (optional)         │
│  └── Neovim's built-in TUI (works out of box)      │
└─────────────────────────────────────────────────────┘
                          ↕ msgpack-RPC
┌─────────────────────────────────────────────────────┐
│  Layer 1: Lua Runtime (runtime/lua/)                 │
│  ├── vim.api.* (nvim_buf_*, nvim_win_*, etc.)       │
│  ├── vim.o, vim.opt, vim.bo, vim.wo                 │
│  ├── vim.fn (vimscript functions)                   │
│  ├── vim.keymap, vim.schedule, vim.wait             │
│  ├── vim.lsp (LSP client)                           │
│  ├── vim.treesitter                                 │
│  └── vim.pack (nvim 0.11+ plugin manager)           │
└─────────────────────────────────────────────────────┘
                          ↕ FFI / LuaJIT bindings
┌─────────────────────────────────────────────────────┐
│  Layer 0: Zig Core (src/)                            │
│  ├── libuv event loop (uv_run)                      │
│  ├── msgpack-RPC server (stdin/stdout/socket)       │
│  ├── Buffer store (gap buffer / piece table)        │
│  ├── Window/Tabpage manager                         │
│  ├── Option registry                                │
│  └── Autocmd scheduler                              │
└─────────────────────────────────────────────────────┘
```

**Key Principle:** Layer 0 is a "Neovim kernel" — it doesn't know about TUI or UI at all. It only sends events via RPC.

---

## 🌍 Cross-Platform Support

### Supported Platforms
- **Linux:** x86_64, arm64 (Ubuntu 22.04+, Arch, Fedora)
- **macOS:** Intel (x86_64), Apple Silicon (arm64), macOS 11.0+
- **Windows:** Windows 10+, x86_64 (native + WSL2)

### Platform Abstractions
All platform-specific code lives in `src/platform/`:
- `terminal.zig` — Terminal I/O (Unix termios / Windows Console API)
- `paths.zig` — Config/data/cache directories (XDG / macOS / Windows)
- `ipc.zig` — IPC transport (Unix socket / Named pipe)
- `process.zig` — Process spawning (libuv uv_spawn)

### Build System
Cross-compilation via Zig's target system:
```zig
const targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },  // Apple Silicon
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },   // ARM Linux
};
```

---

## 📅 Implementation Phases

### Phase 0: Reset & Infrastructure (1-2 weeks, 12 tasks)

| Task | Goal | Platform |
|------|------|----------|
| **RESET-001** | Git hygiene + setup CI | All |
| **RESET-002** | Remove TUI in-process from main.zig | All |
| **INFRA-001** | Link libuv in build.zig | All |
| **INFRA-002** | Implement libuv event loop wrapper | All |
| **INFRA-003** | Implement msgpack encoder/decoder | All |
| **INFRA-004** | Implement RPC server (stdin/stdout) | All |
| **INFRA-005** | Implement RPC request/response dispatch | All |
| **INFRA-006** | Implement buffer store (gap buffer) | All |
| **INFRA-007** | Rebuild verify.sh to be stable | All |
| **INFRA-008** | Implement platform/terminal.zig (Unix) | Linux/macOS |
| **INFRA-009** | Implement platform/terminal.zig (Windows) | Windows |
| **INFRA-010** | Implement platform/paths.zig (config dirs) | All |

### Phase 1: Core API Surface (2-4 weeks, 15-20 tasks)

**Goal:** Pass top-50 nvim API functions that plugins use frequently

- `nvim_buf_*` (get_lines, set_lines, line_count, get_name, set_name)
- `nvim_win_*` (get_cursor, set_cursor, get_buf, set_buf)
- `nvim_tabpage_*` (basic)
- `nvim_get_var/set_var/del_var` (g:, b:, w:, t:, v:)
- `nvim_get_option/set_option` (o:, bo:, wo:)
- `nvim_create_autocmd`, `nvim_exec_autocmds`
- `nvim_set_keymap`, `nvim_del_keymap`
- `nvim_get_api_info` (return API metadata)
- `nvim_command`, `nvim_eval`, `nvim_exec2`

**Test strategy:** Every task uses differential testing against Neovim 0.12.6

### Phase 2: UI Protocol (2-3 weeks, 10-12 tasks)

**Goal:** UI client can connect + display text

- UI attach/detach protocol
- `grid_resize`, `grid_clear`, `grid_cursor_goto`
- `grid_line` (characters + highlight attributes)
- `hl_attr_define`, `hl_group_set` (highlighting)
- `msg_show` (messages area)
- `popupmenu_show/hide/select`
- `cmdline_show/hide`
- `flush` event
- **zigvim-tui**: standalone Zig program that connects back to core via RPC

### Phase 3: Plugin Ecosystem (2-3 weeks, 8-10 tasks)

**Goal:** Plugin manager works

- `runtimepath` / `packpath` management
- `plugin/*.lua` loading
- `after/` directory
- `vim.pack` (nvim 0.11+ built-in)
- **`lazy.nvim` compatible** (minimal API surface)
- `require()` path resolution
- User `init.lua` loading (`~/.config/zigvim/`)

### Phase 4: Language Features (3-4 weeks, 8-10 tasks)

**Goal:** Syntax + LSP

- Treesitter C bindings (libtree-sitter)
- Parser loader (grammar.so files)
- `vim.treesitter.highlighter`
- LSP protocol (JSON-RPC over stdio)
- `vim.lsp.start`, `vim.lsp.buf.*`
- Mason.nvim compatible (install servers)

### Phase 5: Distribution Compatibility (4-8 weeks, 5-8 tasks)

**Goal:** Run LazyVim / AstroNvim

- Load LazyVim's `init.lua`
- LazyVim plugin specs parse without error
- LazyVim opens file + telescope + which-key
- AstroNvim `init.lua` loads
- AstroNvim basic editing

---

## 🎮 Vibe Coding Workflow (Revised)

### Iron Rules

1. **One task = one commit = one PR**
   - Task > 500 lines → split first
   - No "feat: bunch of changes" commits

2. **Differential test mandatory for every task**
   - Write `cases/TASK-XXX.lua` before code
   - Oracle runs against Neovim 0.12.6
   - zigvim must match output 100%

3. **Failure signatures documented**
   - Every task has "if X fails, it means Y"
   - Makes debugging easy, no guessing

4. **Automatic progress dashboard**
   - `./scripts/progress.sh` shows % completion
   - No "I think it's done" — must be measurable

5. **No runtime copying until core is ready**
   - Remove copied `runtime/lua/` first
   - Add modules one by one as APIs become ready

### Workflow for Each Task

```bash
# 1. Read task
cat tasks/TASK-INFRA-001.md

# 2. See expected output
./scripts/verify.sh TASK-INFRA-001 --nvim-only --show-output

# 3. Implement (≤ 500 lines)
#    - Write code
#    - zig build
#    - Fix until compile passes

# 4. Verify
./scripts/verify.sh TASK-INFRA-001
# If fail → see error → loop back to step 3

# 5. Commit
git add -A
git commit -m "feat(INFRA-001): link libuv in build.zig"
```

---

## 🧪 Testing Strategy

### Cross-Platform Testing
- **Local:** Build native + cross-compile to other platforms
- **CI:** GitHub Actions runs on Linux, macOS, Windows for every push
- **Manual:** Test on real devices before major releases

### Terminal Emulators
Must test with:
- **Unix:** GNOME Terminal, Konsole, Alacritty, Kitty, WezTerm, iTerm2 (macOS)
- **Windows:** Windows Terminal, PowerShell, ConEmu, WSL2 + Ubuntu Terminal

### Plugin Compatibility
- **lazy.nvim:** Must sync plugins without error
- **LazyVim:** Must load core plugins (which-key, telescope, neo-tree)
- **AstroNvim:** Must load basic config
- **Mason:** Must install LSP servers

---

## 📊 Success Metrics

By the end of Phase 5:
- ✅ zigvim passes 100+ differential tests
- ✅ zigvim loads LazyVim config without error
- ✅ zigvim works on 3 platforms (Windows, macOS, Linux)
- ✅ zigvim connects to external UI clients via RPC
- ✅ zigvim has working LSP with Mason.nvim
- ✅ zigvim has Treesitter syntax highlighting

---

## 🚀 Getting Started

### Prerequisites
- Zig 0.17.0+
- LuaJIT 2.1+
- libuv 1.44+
- Neovim 0.12.6 (for oracle testing)

### Quick Start
```bash
git clone https://github.com/yourusername/zigvim
cd zigvim
./scripts/fetch-runtime.sh  # Download Neovim runtime
zig build
./zig-out/bin/zigvim --version
```

### Development
```bash
./scripts/verify.sh all  # Run all tests
./scripts/progress.sh    # See progress
```

---

## 📝 Notes

- This plan supersedes the old TUI-focused plan (archived in `docs/archive/2026-10-18-tui-phase/`)
- The old TUI implementation was a learning exercise but architecturally wrong (in-process TUI instead of RPC)
- The new architecture follows Neovim's actual design (kernel + external UI)
- Cross-platform support is built in from day one, not bolted on later

---

**Last Updated:** 2026-10-19  
**Maintainer:** zigvim team
