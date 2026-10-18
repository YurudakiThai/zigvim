# Differential Test Harness สำหรับ zigvim

> คู่มือการพัฒนา + สถาปัตยกรรม สำหรับเปรียบเทียบ **zigvim** (Neovim ที่เขียนใหม่ด้วย Zig) กับ **Neovim 0.12.6 ต้นฉบับ** อย่างเป็นระบบอัตโนมัติ
> อ้างอิงข้อมูลจริงจาก environment ปัจจุบัน: nvim 0.12.6, LuaJIT 2.1.1788856981, plugin corpus 55 ตัว

---

## สารบัญ

1. [หลักการออกแบบ](#1-หลักการออกแบบ)
2. [สถาปัตยกรรมโดยรวม](#2-สถาปัตยกรรมโดยรวม)
3. [ชั้นที่ 1 — Test Case Language](#3-ชั้นที่-1--test-case-language)
4. [ชั้นที่ 2 — Executor (side-by-side spawning)](#4-ชั้นที่-2--executor-side-by-side-spawning)
5. [ชั้นที่ 3 — Executor (msgpack-rpc level)](#5-ชั้นที่-3--executor-msgpack-rpc-level)
6. [ชั้นที่ 4 — Diff Engine & Reporter](#6-ชั้นที่-4--diff-engine--reporter)
7. [การ Enumerate API ใน Neovim 0.12](#7-การ-enumerate-api-ใน-neovim-012)
8. [Structure ของ Test Suite](#8-structure-ของ-test-suite)
9. [Workflow การพัฒนาแบบ CI-Driven](#9-workflow-การพัฒนาแบบ-ci-driven)
10. [ตัวอย่างการใช้จริง](#10-ตัวอย่างการใช้จริง)
11. [ขอบเขตที่ Harness ตรวจไม่พบ](#11-ขอบเขตที่-harness-ตรวจไม่พบ)
12. [Appendix — Reference Tables](#appendix--reference-tables)

---

## 1. หลักการออกแบบ

### 1.1 Problem Statement

เมื่อ port Neovim เป็น Zig เรามีความไม่แน่นอน 3 ระดับ:

| ระดับ | ตัวอย่าง | วิธี validate |
|------|---------|--------------|
| **A. Semantics** | `vim.api.nvim_buf_set_lines(buf, 0, -1, false, {...})` ให้ผลเหมือนกันหรือไม่? | เปรียบเทียบ output |
| **B. State** | หลังรัน script เดียวกัน buffer/window/options state ตรงกันหรือไม่? | dump state -> deep diff |
| **C. Behavior** | Plugin ทำงานเหมือนเดิมหรือไม่? (regression testing) | scenario comparison |

### 1.2 Design Principles

1. **Black-box first** - ทดสอบ behavior ที่ user/plugin มองเห็น ไม่ต้องรู้ internal ของ zigvim
2. **Two executors, one protocol** - ทดสอบผ่าน Lua scripting (user-level) และ msgpack-rpc (api-level) พร้อมกัน
3. **Deterministic snapshots** - ทุก test case กำหนด initial state ชัดเจน -> output reproducible
4. **Zero false positives** - ถ้า diff เจอ ต้องเป็น bug จริง (normalize noise ออกก่อน)
5. **Incremental coverage** - track progress เป็น `% implemented / % passing` ต่อวัน
6. **Plugin corpus as north star** - test suite ครอบคลุม 55 plugins ของคุณ

### 1.3 Ground Truth (environment ปัจจุบัน)

```
zig              : 0.17.0
nvim             : 0.12.6 (brew)
luajit            : 2.1.1788856981
vim.api functions : 181
VIMRUNTIME/lua    : 128 files / 92,619 LOC
plugin corpus     : 55 plugins (LazyVim + ecosystem)
brew deps         : libuv, lpeg, tree-sitter, luajit
```

**ข้อสังเกตสำคัญ:** `nvim_get_api_info()` ถูก **ลบออก** ใน Neovim 0.12 ดังนั้นเราไม่สามารถใช้วิธี legacy ของการ introspect api metadata ได้ - ต้อง parse source code ตรงๆ หรือเก็บ metadata จาก Lua table `vim.api` ตอน runtime

---

## 2. สถาปัตยกรรมโดยรวม

```
                        +-------------------------+
                        |   Test Cases (.lua/.json)|
                        |   (declarative specs)    |
                        +------------+------------+
                                     |
                        +------------v------------+
                        |   Test Runner (Python)   |
                        |   - orchestrator          |
                        |   - scheduler             |
                        |   - parallel runner       |
                        +------------+------------+
                                     |
                +--------------------+--------------------+
                |                    |                    |
                v                    v                    v
        +--------------+     +--------------+    +--------------+
        | Executor:    |     | Executor:    |    | Executor:    |
        | Script-level |     | RPC-level    |    | Scenario     |
        | (--headless) |     | (--embed)    |    | (plugins)    |
        +------+-------+     +------+-------+    +------+-------+
               |                    |                   |
     +---------+---------+   +------+-------+            |
     | nvim 0.12.6       |   | zigvim      |   +--------+--------+
     | + zigvim (side-   |   | (side-by-   |   | Full plugin     |
     |   by-side)        |   |  side)      |   | stack run       |
     +---------+---------+   +------+------+   +--------+--------+
               |                    |                   |
               +--------------------+-------------------+
                                    |
                        +-----------v----------+
                        |   Diff Engine        |
                        |   - deep-equal       |
                        |   - normalization    |
                        |   - tolerance rules  |
                        +-----------+----------+
                                    |
                        +-----------v----------+
                        |   Reporter           |
                        |   - coverage %       |
                        |   - failure triage   |
                        |   - historical trend |
                        |   - plugin matrix    |
                        +----------------------+
```

### 2.1 Directory Layout

```
zigvim/
+-- build.zig                 # Zig build
+-- src/                      # Zig source
+-- conformance/              # <- Differential harness ทั้งหมดอยู่ที่นี่
|   +-- README.md
|   +-- pyproject.toml        # Python 3.11+, uv/pipx
|   +-- harness/
|   |   +-- __init__.py
|   |   +-- runner.py         # orchestrator
|   |   +-- executors/
|   |   |   +-- script.py     # --headless executor
|   |   |   +-- rpc.py        # --embed executor
|   |   |   +-- scenario.py   # plugin scenario
|   |   +-- diff.py           # deep-equal + normalize
|   |   +-- normalize.py      # rules ลบ noise
|   |   +-- reporter.py       # HTML/JSON/markdown report
|   |   +-- metadata.py       # parse nvim 0.12 api metadata
|   +-- cases/
|   |   +-- api/              # per-function api tests
|   |   +-- options/          # per-option tests
|   |   +-- runtime/          # vim.* module tests
|   |   +-- plugins/          # per-plugin scenarios
|   |   +-- stress/           # perf & load tests
|   +-- corpus/               # plugin sources for scenario tests
|   +-- reports/              # output directory
|   +-- fixtures/             # shared files for tests
+-- conftest.py
```

---

## 3. ชั้นที่ 1 — Test Case Language

### 3.1 Why declarative?

Test case ควรเป็น **data, not code** เพื่อให้:
- executor ทุกชนิด (script / rpc / scenario) ใช้ test case เดียวกันได้
- diff engine เปรียบเทียบได้ตรงไปตรงมา
- generate test cases แบบ automated ได้ (property-based)

### 3.2 Schema (YAML + embedded Lua)

```yaml
# conformance/cases/api/buf_set_lines/basic.yaml
id: api.buf_set_lines.basic_001
tags: [api, buffer, lines]
priority: P0
description: |
  nvim_buf_set_lines: replace all lines in current buffer.
  -1 means "to end of buffer".
setup:
  lua: |
    -- Initial state: create a buffer with 3 lines
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"alpha", "beta", "gamma"})
    return { buf = buf }
action:
  lua: |
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"one", "two", "three"})
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assertions:
  - kind: equal
    path: action_result
    expected:
      - "one"
      - "two"
      - "three"
  - kind: state_equal
    path: buffer_line_count
    expected: 3
```

```yaml
# conformance/cases/plugins/oil/edit_rename.yaml
id: plugin.oil.edit_rename
tags: [plugin, oil, scenario]
priority: P1
description: Open oil.nvim, rename a file, verify filesystem reflects change.
kind: scenario
plugin: oil.nvim
plugin_config:
  lua: |
    require('oil').setup({ default_file_explorer = false })
steps:
  - action: write_file
    path: tmp/orig.txt
    content: "hello"
  - action: run_lua
    lua: |
      vim.cmd('edit tmp/')
      vim.wait(100)
      -- simplified: trigger rename via oil api
      require('oil').save()
  - action: assert_file_exists
    path: tmp/2.txt
  - action: assert_file_not_exists
    path: tmp/orig.txt
```

### 3.3 Test Case Generator (from source headers)

Script ที่จะ generate test case skeletons จาก Neovim source:

```python
# conformance/harness/generator.py
"""
Parse Neovim src/nvim/api/*.h signatures and generate skeleton test cases.
For nvim 0.12, api_info is removed so we parse headers directly.
"""
import re
from pathlib import Path

API_DIR = Path.home() / "src" / "neovim" / "src" / "nvim" / "api"

SIG_RE = re.compile(
    r"""
    (?:ArrayOf\(.*?\)|Boolean|Integer|Float|String|Dictionary|Object)
    \s+(nvim_\w+)\s*\(
    ([^)]*)\s*\)
    """,
    re.VERBOSE,
)

def parse_api_header(path: Path) -> list[dict]:
    """Extract function signatures from an api .h file."""
    text = path.read_text()
    out = []
    for m in SIG_RE.finditer(text):
        name, args = m.group(1), m.group(2)
        out.append({"name": name, "raw_args": args, "source": str(path)})
    return out

def all_api_functions() -> list[dict]:
    functions = []
    for h in API_DIR.glob("*.h"):
        if h.name.startswith("_"):
            continue
        functions.extend(parse_api_header(h))
    return functions

def generate_skeleton(fn: dict) -> dict:
    """Return a minimal test case skeleton for a function."""
    return {
        "id": f"api.{fn['name']}.auto_001",
        "tags": ["api", "generated"],
        "priority": "P2",
        "description": f"Auto-generated skeleton for {fn['name']}",
        "action": {"lua": f"local ok, r = pcall(vim.api.{fn['name']})\nreturn {{ok = ok, r = r}}"},
        "assertions": [{"kind": "equal", "path": "action_result.ok", "expected": True}],
    }
```

---

## 4. ชั้นที่ 2 — Executor (side-by-side spawning)

### 4.1 Architecture

- Spawn 2 processes: `nvim --headless --clean` และ `zigvim --headless --clean`
- ส่ง Lua script เดียวกันผ่าน `-c "lua ..."` หรือ RPC
- Capture stdout + state dump
- Return `(reference_output, candidate_output)` pair

### 4.2 Implementation

```python
# conformance/harness/executors/script.py
import subprocess, json, tempfile, os, re
from dataclasses import dataclass
from typing import Optional

@dataclass
class ExecResult:
    stdout: str
    stderr: str
    exit_code: int
    state: Optional[dict]  # buffer, window, option snapshot
    duration_ms: float

class ScriptExecutor:
    """Run a Lua script on nvim and zigvim side-by-side."""

    def __init__(self, nvim_bin: str, zigvim_bin: str, timeout_s: float = 10.0):
        self.nvim = nvim_bin
        self.zigvim = zigvim_bin
        self.timeout = timeout_s

    STATE_DUMP = """
    local dump = {}
    dump.buffers = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_is_valid(b) then
        dump.buffers[#dump.buffers+1] = {
          name = vim.api.nvim_buf_get_name(b),
          lines = vim.api.nvim_buf_get_lines(b, 0, -1, false),
          ft = vim.bo[b].filetype,
          modifiable = vim.bo[b].modifiable,
          modified = vim.bo[b].modified,
        }
      end
    end
    dump.windows = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) then
        dump.windows[#dump.windows+1] = {
          buf = vim.api.nvim_win_get_buf(w),
          cursor = vim.api.nvim_win_get_cursor(w),
          height = vim.api.nvim_win_get_height(w),
          width = vim.api.nvim_win_get_width(w),
        }
      end
    end
    dump.options = {}
    for _, k in ipairs({"number", "relativenumber", "tabstop", "shiftwidth",
                         "expandtab", "wrap", "conceallevel"}) do
      dump.options[k] = vim.o[k]
    end
    dump.globals = {}
    for k, v in pairs(vim.g) do
      if type(v) ~= "function" then dump.globals[k] = v end
    end
    print("\\n__STATE__" .. vim.json.encode(dump) .. "__ENDSTATE__")
    """

    def _run_one(self, binary: str, script: str,
                 setup: Optional[str] = None) -> ExecResult:
        full_script = ""
        if setup:
            full_script += setup + "\n"
        full_script += "local __action = function()\n" + script + "\nend\n"
        full_script += "local __ok, __r = pcall(__action)\n"
        full_script += "print('\\n__RESULT__' .. vim.json.encode({ok=__ok, r=__r}) .. '__ENDRESULT__')\n"
        full_script += self.STATE_DUMP

        tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".lua", delete=False)
        tmp.write(full_script); tmp.close()

        cmd = [
            binary, "--headless", "--clean",
            "--noplugin",
            "-c", f"luafile {tmp.name}",
            "-c", "qa!"
        ]
        t0 = os.times()[4]  # wall-clock approximation
        try:
            r = subprocess.run(
                cmd,
                capture_output=True, text=True,
                timeout=self.timeout,
                env={**os.environ, "VIMRUNTIME": os.environ.get("VIMRUNTIME", "")},
            )
            duration = (os.times()[4] - t0) * 1000
        except subprocess.TimeoutExpired:
            return ExecResult("", f"timeout after {self.timeout}s", -1, None, self.timeout*1000)
        finally:
            os.unlink(tmp.name)

        stdout, stderr = r.stdout, r.stderr
        state = self._extract_state(stdout)
        result = self._extract_result(stdout)

        if result:
            # Replace stdout with just the JSON result for comparison
            stdout = json.dumps(result, sort_keys=True)

        return ExecResult(stdout, stderr, r.returncode, state, duration)

    def _extract_state(self, stdout: str) -> Optional[dict]:
        m = re.search(r"__STATE__(.*)__ENDSTATE__", stdout, re.DOTALL)
        if m:
            try:
                return json.loads(m.group(1))
            except json.JSONDecodeError:
                return None
        return None

    def _extract_result(self, stdout: str) -> Optional[dict]:
        m = re.search(r"__RESULT__(.*)__ENDRESULT__", stdout, re.DOTALL)
        if m:
            try:
                return json.loads(m.group(1))
            except json.JSONDecodeError:
                return None
        return None

    def run_pair(self, case: dict) -> tuple[ExecResult, ExecResult]:
        """Run the same case on both binaries."""
        ref = self._run_one(self.nvim, case["action"]["lua"],
                            case.get("setup", {}).get("lua"))
        cand = self._run_one(self.zigvim, case["action"]["lua"],
                             case.get("setup", {}).get("lua"))
        return ref, cand
```

### 4.3 Key Design Decisions

1. **`--clean` แทน `--noplugin`:** `--clean` ใน Neovim 0.12 เป็น flag ที่ reset ทุกอย่างให้ clean state - ใกล้เคียงกับ state ที่ test ต้องการมากที่สุด
2. **`pcall` wrap:** ตรวจจับ runtime error แทนปล่อยให้ process crash - ได้ structured error ที่ diff ได้
3. **Separate state dump:** แยก state snapshot ออกจาก action result เพื่อ diff ได้ตรงไปตรงมา
4. **`__RESULT__` / `__STATE__` delimiters:** ใช้ marker ที่ไม่ clash กับ normal output

---

## 5. ชั้นที่ 3 — Executor (msgpack-rpc level)

### 5.1 Why msgpack-rpc level?

- ทดสอบ protocol ที่ GUI clients พึ่ง (เช่น VSCode Neovim, Neovide)
- ทดสอบ async behavior (notification vs request)
- จับ timing และ ordering ได้ละเอียดกว่า

### 5.2 Implementation (Python + msgpack)

```python
# conformance/harness/executors/rpc.py
import subprocess, time
import msgpack
from dataclasses import dataclass
from typing import Optional, Any

@dataclass
class RpcResult:
    request_id: int
    error: Optional[list]   # [type, msg, details] or None
    value: Any
    notifications: list     # notifications received during call
    duration_ms: float

class MsgpackRpcClient:
    """Talk to a nvim/zigvim instance over --embed stdio."""

    def __init__(self, binary: str):
        self.binary = binary
        self.proc = None
        self.unpacker = None
        self.next_id = 1

    def start(self):
        self.proc = subprocess.Popen(
            [self.binary, "--embed", "--headless", "--clean", "--noplugin"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.unpacker = msgpack.Unpacker(self.proc.stdout, raw=False, use_list=True)

    def request(self, method: str, args: list, timeout_s: float = 5.0) -> RpcResult:
        req_id = self.next_id; self.next_id += 1
        msg = [0, req_id, method, args]  # msgpack-rpc request
        t0 = time.monotonic()
        self.proc.stdin.write(msgpack.packb(msg))
        self.proc.stdin.flush()
        # Read until we see a response with this id
        notifications = []
        while True:
            try:
                frame = self.unpacker.unpack()
            except Exception as e:
                return RpcResult(req_id, [None, str(e), None], None, [],
                                 (time.monotonic()-t0)*1000)
            if not isinstance(frame, list) or len(frame) < 3:
                continue
            if frame[0] == 2:  # notification
                notifications.append(frame)
            elif frame[0] == 1 and frame[1] == req_id:  # response
                err, val = frame[2], frame[3]
                return RpcResult(req_id, err, val, notifications,
                                 (time.monotonic()-t0)*1000)

    def notify(self, method: str, args: list):
        msg = [2, method, args]  # msgpack-rpc notification
        self.proc.stdin.write(msgpack.packb(msg))
        self.proc.stdin.flush()

    def stop(self):
        if self.proc:
            try: self.notify("nvim_command", ["qa!"])
            except: pass
            self.proc.terminate()
            self.proc.wait(timeout=3)

class RpcExecutor:
    """Pair of RPC clients: reference nvim and candidate zigvim."""

    def __init__(self, nvim_bin: str, zigvim_bin: str):
        self.ref = MsgpackRpcClient(nvim_bin)
        self.cand = MsgpackRpcClient(zigvim_bin)

    def run_pair(self, method: str, args: list) -> tuple[RpcResult, RpcResult]:
        self.ref.start(); self.cand.start()
        try:
            ref = self.ref.request(method, args)
            cand = self.cand.request(method, args)
            return ref, cand
        finally:
            self.ref.stop(); self.cand.stop()

    def run_sequence(self, sequence: list[dict]) -> tuple[list[RpcResult], list[RpcResult]]:
        """Run an ordered sequence of requests, capturing ordering."""
        self.ref.start(); self.cand.start()
        ref_results, cand_results = [], []
        try:
            for step in sequence:
                ref_results.append(self.ref.request(step["method"], step["args"]))
                cand_results.append(self.cand.request(step["method"], step["args"]))
            return ref_results, cand_results
        finally:
            self.ref.stop(); self.cand.stop()
```

### 5.3 Use Cases

- **API-level parity:** `nvim_buf_set_lines` ผ่าน RPC ให้ผลเท่ากับ `vim.api.nvim_buf_set_lines` ใน Lua หรือไม่
- **Async ordering:** ส่งหลาย request พร้อมกัน ดูว่า response กลับมาตาม order เดียวกัน
- **Notification capture:** ดูว่า `nvim_ui_attach` ส่ง event เหมือนกัน

---

## 6. ชั้นที่ 4 — Diff Engine & Reporter

### 6.1 Deep-Equal with Normalization

```python
# conformance/harness/diff.py
import json, re
from typing import Any, Optional
from dataclasses import dataclass, field

@dataclass
class DiffNode:
    path: str
    kind: str          # "mismatch", "missing_in_ref", "missing_in_cand", "noise"
    ref_value: Any
    cand_value: Any
    reason: Optional[str] = None

@dataclass
class DiffResult:
    equal: bool
    nodes: list[DiffNode]
    summary: dict

class Normalizer:
    """Remove known-noise differences between ref and cand."""

    NOISE_PATHS = {
        # Buffer handles may differ; compare by name+lines instead
        r"\.buffers\[\d+\]\.name": "buffer_name",
        # Internal addresses, pointers - never compare
        r"\.(handle|ptr|ptrval|addr)$": "pointer",
        # Timestamps
        r"\.(created_at|modified_at|uptime)$": "timestamp",
        # Filesystem path differences (brew vs zigvim binary location)
        r"\.options\.runtimepath": "runtimepath",
        r"\.options\.packpath": "packpath",
        r"\.options\.rtp": "rtp",
    }

    def normalize(self, path: str, value: Any) -> Any:
        for pattern, tag in self.NOISE_PATHS.items():
            if re.search(pattern, path):
                return f"<normalized:{tag}>"
        # Normalize floating-point to 6 decimals
        if isinstance(value, float):
            return round(value, 6)
        return value

    def should_skip(self, path: str) -> bool:
        return re.search(r"\.(handle|ptr|ptrval|addr)$", path) is not None


class DiffEngine:
    def __init__(self, normalizer: Normalizer):
        self.normalizer = normalizer

    def deep_diff(self, ref: Any, cand: Any, path: str = "$",
                  results: Optional[list[DiffNode]] = None) -> list[DiffNode]:
        if results is None:
            results = []

        ref = self.normalizer.normalize(path, ref)
        cand = self.normalizer.normalize(path, cand)

        if self.normalizer.should_skip(path):
            return results

        if type(ref) is not type(cand):
            results.append(DiffNode(path, "type_mismatch",
                                     type(ref).__name__,
                                     type(cand).__name__))
            return results

        if isinstance(ref, dict):
            all_keys = set(ref.keys()) | set(cand.keys())
            for k in sorted(all_keys):
                if k not in ref:
                    results.append(DiffNode(f"{path}.{k}", "missing_in_ref",
                                            None, cand[k]))
                elif k not in cand:
                    results.append(DiffNode(f"{path}.{k}", "missing_in_cand",
                                            ref[k], None))
                else:
                    self.deep_diff(ref[k], cand[k], f"{path}.{k}", results)
        elif isinstance(ref, list):
            if len(ref) != len(cand):
                results.append(DiffNode(path, "length_mismatch",
                                         len(ref), len(cand)))
            for i in range(min(len(ref), len(cand))):
                self.deep_diff(ref[i], cand[i], f"{path}[{i}]", results)
        else:
            if ref != cand:
                results.append(DiffNode(path, "mismatch", ref, cand))

        return results

    def diff(self, ref: Any, cand: Any) -> DiffResult:
        nodes = self.deep_diff(ref, cand)
        equal = len([n for n in nodes if n.kind != "noise"]) == 0
        return DiffResult(
            equal=equal,
            nodes=nodes,
            summary={
                "total_diffs": len(nodes),
                "mismatches": len([n for n in nodes if n.kind == "mismatch"]),
                "missing_in_ref": len([n for n in nodes if n.kind == "missing_in_ref"]),
                "missing_in_cand": len([n for n in nodes if n.kind == "missing_in_cand"]),
            },
        )
```

### 6.2 Reporter (Markdown + JSON + HTML)

```python
# conformance/harness/reporter.py
import json, datetime
from pathlib import Path
from typing import Iterable

class Reporter:
    def __init__(self, out_dir: Path):
        self.out_dir = out_dir
        self.out_dir.mkdir(parents=True, exist_ok=True)

    def markdown_report(self, results: Iterable[dict], run_id: str) -> Path:
        out = self.out_dir / f"report-{run_id}.md"
        total = len(results)
        passed = sum(1 for r in results if r["passed"])
        failed = sum(1 for r in results if not r["passed"])
        skipped = sum(1 for r in results if r.get("skipped"))

        lines = [
            f"# zigvim Conformance Report - {run_id}",
            f"",
            f"**Run at:** {datetime.datetime.now().isoformat()}",
            f"",
            f"## Summary",
            f"",
            f"| Status | Count | % |",
            f"|--------|------:|--:|",
            f"| PASS | {passed} | {100*passed/total:.1f}% |",
            f"| FAIL | {failed} | {100*failed/total:.1f}% |",
            f"| SKIP | {skipped} | {100*skipped/total:.1f}% |",
            f"| **Total** | **{total}** | 100% |",
            f"",
        ]

        # Coverage by api category
        by_category = {}
        for r in results:
            cat = r["case"]["tags"][0] if r["case"]["tags"] else "other"
            by_category.setdefault(cat, {"total": 0, "passed": 0})
            by_category[cat]["total"] += 1
            if r["passed"]:
                by_category[cat]["passed"] += 1

        lines.append("## Coverage by Category")
        lines.append("")
        lines.append("| Category | Passed | Total | % |")
        lines.append("|----------|-------:|------:|--:|")
        for cat, s in sorted(by_category.items()):
            lines.append(f"| {cat} | {s['passed']} | {s['total']} | "
                        f"{100*s['passed']/s['total']:.1f}% |")
        lines.append("")

        # Failed cases
        failures = [r for r in results if not r["passed"] and not r.get("skipped")]
        if failures:
            lines.append("## Failures")
            lines.append("")
            for r in failures[:50]:  # cap to avoid huge report
                case_id = r["case"]["id"]
                lines.append(f"### FAIL `{case_id}`")
                lines.append("")
                lines.append(f"**Description:** {r['case'].get('description', '-')}")
                lines.append("")
                for n in r["diff"].nodes[:10]:
                    lines.append(f"- `{n.path}`: ref=`{n.ref_value}` vs cand=`{n.cand_value}` ({n.kind})")
                lines.append("")

        out.write_text("\n".join(lines))
        return out

    def json_report(self, results: Iterable[dict], run_id: str) -> Path:
        out = self.out_dir / f"report-{run_id}.json"
        out.write_text(json.dumps(results, indent=2, default=str))
        return out
```

---

## 7. การ Enumerate API ใน Neovim 0.12

### 7.1 ปัญหา

ใน Neovim 0.12 `vim.api.nvim_get_api_info()` ถูกเอาออก - วิธีดั้งเดิมที่ใช้ introspect api metadata ไม่ทำงานอีกต่อไป ต้องหาทางใหม่

### 7.2 วิธีแก้: สองแหล่งข้อมูล

**A. Runtime enumeration (สำหรับ function names)**

```python
# conformance/harness/metadata.py
import subprocess, json, re

def enumerate_api_functions(binary: str) -> list[str]:
    """Use Lua runtime to enumerate all vim.api functions."""
    script = """
    local names = {}
    for k,v in pairs(vim.api) do if type(v)=="function" then names[#names+1]=k end end
    table.sort(names)
    print(vim.json.encode(names))
    """
    r = subprocess.run([binary, "--headless", "--clean", "-c", f"lua {script}", "-c", "qa!"],
                       capture_output=True, text=True, timeout=10)
    # find json array in stdout
    m = re.search(r"\[.*\]", r.stdout, re.DOTALL)
    if m:
        return json.loads(m.group(0))
    return []
```

**B. Header parsing (สำหรับ signatures - parameter names/types)**

```python
# conformance/harness/metadata.py
from pathlib import Path
import re

API_H_DIR = Path.home() / "neovim-source" / "src" / "nvim" / "api"

TYPE_RE = re.compile(
    r"""
    (?:ArrayOf\(.*?\)|Boolean|Integer|Float|String|Dictionary|Object)
    \s+(nvim_\w+)\s*\(\s*
    ([^)]*)\s*\)
    """,
    re.VERBOSE,
)

PARAM_RE = re.compile(r"(\w+(?:Of\([^)]*\))?)\s+(\w+)")

def parse_api_header(path: Path) -> list[dict]:
    text = path.read_text()
    out = []
    for m in TYPE_RE.finditer(text):
        name, args = m.group(1), m.group(2)
        params = []
        for pm in PARAM_RE.finditer(args):
            params.append({"type": pm.group(1), "name": pm.group(2)})
        out.append({"name": name, "params": params, "source": path.name})
    return out

def all_api_signatures() -> list[dict]:
    if not API_H_DIR.exists():
        raise FileNotFoundError(f"Clone neovim source to {API_H_DIR.parent}")
    fns = []
    for h in API_H_DIR.glob("*.h"):
        if h.name.startswith("_"):
            continue
        fns.extend(parse_api_header(h))
    return fns
```

### 7.3 การ Setup Source Tree

```bash
# One-time setup:
mkdir -p ~/neovim-source
cd ~/neovim-source
git clone --depth 1 --branch v0.12.6 https://github.com/neovim/neovim.git .
# Now API_H_DIR = ~/neovim-source/src/nvim/api/
```

---

## 8. Structure ของ Test Suite

### 8.1 Layered Coverage

| Layer | Test Count Target | Example Cases |
|------|------------------|---------------|
| **L1: Primitive** | 500+ | each api function x 3 cases (happy path, edge, error) |
| **L2: Composition** | 200+ | api combinations (e.g., create buf -> set lines -> get text) |
| **L3: Option Semantics** | 374 | one test per `vim.o.*` option |
| **L4: VimL Bridge** | 400+ | `vim.fn.*` functions |
| **L5: Plugin Scenarios** | 55 x 3-10 | one scenario per plugin x several use cases |
| **L6: Stress / Concurrency** | 50+ | large buffers, deep recursion, parallel jobs |

### 8.2 Case Directory Layout

```
cases/
+-- api/
|   +-- buf_set_lines/
|   |   +-- basic.yaml
|   |   +-- empty_array.yaml
|   |   +-- negative_end.yaml
|   |   +-- unicode.yaml
|   |   +-- invalid_buffer.yaml
|   +-- buf_get_lines/
|   +-- set_option_value/
|   +-- create_autocmd/
|   +-- set_extmark/
|   +-- ... (181 function dirs)
+-- options/
|   +-- number.yaml
|   +-- tabstop.yaml
|   +-- ...
+-- runtime/
|   +-- vim_schedule/
|   +-- vim_defer/
|   +-- vim_wait/
+-- plugins/
|   +-- oil/
|   +-- telescope/
|   +-- lualine/
|   +-- ...
+-- stress/
    +-- large_buffer.yaml
    +-- 10k_autocmds.yaml
    +-- parallel_jobs.yaml
```

### 8.3 Property-Based Test Generator (advanced)

```python
# conformance/harness/property_tests.py
from hypothesis import given, strategies as st
import json

@given(
    lines=st.lists(st.text(max_size=200, alphabet=st.characters(codec="utf-8")),
                   min_size=0, max_size=1000),
    start=st.integers(min_value=0, max_value=100),
)
def prop_buf_set_lines_idempotent(lines, start):
    """
    If we set lines [start..] to L, then get lines [start..], we should get L back.
    This is tested on BOTH nvim and zigvim.
    """
    script = f"""
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, {start}, -1, false, {json.dumps(lines)})
    return vim.api.nvim_buf_get_lines(buf, {start}, -1, false)
    """
    ref = run_on_nvim(script)
    cand = run_on_zigvim(script)
    assert ref == cand == lines
```

---

## 9. Workflow การพัฒนาแบบ CI-Driven

### 9.1 Daily Development Loop

```
1. Implement a function (e.g., nvim_buf_set_lines)
2. Write test case(s) in cases/api/buf_set_lines/
3. Run: ./run.sh cases/api/buf_set_lines/*.yaml
4. Look at diff output
5. Fix -> repeat until all P0/P1 pass
6. Commit
```

### 9.2 `run.sh` — Primary entry point

```bash
#!/usr/bin/env bash
# conformance/run.sh
set -euo pipefail

NVIM_BIN="${NVIM_BIN:-/opt/homebrew/bin/nvim}"
ZIGVIM_BIN="${ZIGVIM_BIN:-$(realpath ../zig-out/bin/zigvim)}"
CASES="${1:-cases/}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"

# 1. Build zigvim if needed
if [[ ! -x "$ZIGVIM_BIN" ]]; then
    echo "Building zigvim..."
    (cd .. && zig build -Doptimize=Debug)
fi

# 2. Run the harness
uv run python -m harness.runner \
    --nvim "$NVIM_BIN" \
    --zigvim "$ZIGVIM_BIN" \
    --cases "$CASES" \
    --run-id "$RUN_ID" \
    --jobs 4

# 3. Show the report
REPORT="reports/report-${RUN_ID}.md"
echo ""
echo "Report: $REPORT"
echo ""
head -30 "$REPORT"
echo "..."
echo ""
echo "Full report: $REPORT"
echo "JSON: reports/report-${RUN_ID}.json"

# 4. Fail CI if any P0/P1 fails
FAILS=$(jq '[.[] | select(.passed == false and (.case.priority == "P0" or .case.priority == "P1"))] | length' \
    "reports/report-${RUN_ID}.json")
if [[ "$FAILS" -gt 0 ]]; then
    echo ""
    echo "FAIL $FAILS P0/P1 failures - CI would fail here."
    exit 1
fi
```

### 9.3 Runner Orchestrator

```python
# conformance/harness/runner.py
"""Orchestrates parallel test execution."""
import argparse, json, sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from .executors.script import ScriptExecutor
from .executors.rpc import RpcExecutor
from .diff import DiffEngine, Normalizer
from .reporter import Reporter
from .metadata import enumerate_api_functions

def load_cases(case_dir: Path) -> list[dict]:
    """Load all YAML/JSON test cases from a directory."""
    import yaml
    cases = []
    for f in case_dir.rglob("*"):
        if f.suffix in (".yaml", ".yml", ".json"):
            with f.open() as fh:
                cases.append(yaml.safe_load(fh))
    return cases

def run_one_case(case: dict, executor, diff_engine) -> dict:
    """Run a single case, return result dict."""
    try:
        if case.get("kind") == "rpc":
            ref, cand = executor.run_pair(case["method"], case["args"])
            ref_data = {"value": ref.value, "error": ref.error}
            cand_data = {"value": cand.value, "error": cand.error}
        else:
            ref, cand = executor.run_pair(case)
            ref_data = {"stdout": ref.stdout, "state": ref.state}
            cand_data = {"stdout": cand.stdout, "state": cand.state}

        diff = diff_engine.diff(ref_data, cand_data)
        return {
            "case": case,
            "passed": diff.equal,
            "diff": diff,
            "ref_duration_ms": ref.duration_ms if hasattr(ref, "duration_ms") else 0,
            "cand_duration_ms": cand.duration_ms if hasattr(cand, "duration_ms") else 0,
        }
    except Exception as e:
        return {
            "case": case,
            "passed": False,
            "error": f"{type(e).__name__}: {e}",
            "skipped": False,
        }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nvim", required=True)
    ap.add_argument("--zigvim", required=True)
    ap.add_argument("--cases", default="cases/")
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--tags", nargs="*", default=[])
    args = ap.parse_args()

    cases = load_cases(Path(args.cases))
    if args.tags:
        cases = [c for c in cases if any(t in c.get("tags", []) for t in args.tags)]

    executor = ScriptExecutor(args.nvim, args.zigvim)
    diff_engine = DiffEngine(Normalizer())
    reporter = Reporter(Path("reports"))

    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_one_case, c, executor, diff_engine): c for c in cases}
        for fut in as_completed(futures):
            r = fut.result()
            results.append(r)
            status = "PASS" if r["passed"] else "FAIL"
            print(f"{status} {r['case']['id']}")

    md_path = reporter.markdown_report(results, args.run_id)
    json_path = reporter.json_report(results, args.run_id)

    total = len(results)
    passed = sum(1 for r in results if r["passed"])
    print(f"\n{passed}/{total} passed ({100*passed/total:.1f}%)")
    print(f"Reports: {md_path}, {json_path}")

if __name__ == "__main__":
    main()
```

### 9.4 Tracking Progress Over Time

```bash
# conformance/scripts/track.sh
# Run daily and append to history.jsonl
./run.sh cases/ > /dev/null 2>&1
REPORT="reports/report-$(date +%Y%m%d-%H%M%S).json"
jq -r '[
  {
    date: (now | strftime("%Y-%m-%d %H:%M")),
    total: (. | length),
    passed: ([.[] | select(.passed == true)] | length),
    p0_pass: ([.[] | select(.case.priority == "P0" and .passed)] | length),
    p0_total: ([.[] | select(.case.priority == "P0")] | length),
    p1_pass: ([.[] | select(.case.priority == "P1" and .passed)] | length),
    p1_total: ([.[] | select(.case.priority == "P1")] | length),
    api_pass: ([.[] | select((.case.tags // [] | any(. == "api")) and .passed)] | length),
    api_total: ([.[] | select((.case.tags // [] | any(. == "api")))] | length),
    plugin_pass: ([.[] | select((.case.tags // [] | any(. == "plugin")) and .passed)] | length),
    plugin_total: ([.[] | select((.case.tags // [] | any(. == "plugin")))] | length)
  }
] | .[]' "$REPORT" >> history.jsonl
```

Plot with Python (optional):

```python
import json, matplotlib.pyplot as plt
data = [json.loads(l) for l in open("history.jsonl")]
plt.plot([d["date"] for d in data], [100*d["passed"]/d["total"] for d in data])
plt.title("zigvim Conformance %")
plt.savefig("progress.png")
```

---

## 10. ตัวอย่างการใช้จริง

### 10.1 End-to-End: Implementing `nvim_buf_set_lines`

**Step 1:** สร้าง test case

```yaml
# cases/api/buf_set_lines/basic.yaml
id: api.buf_set_lines.basic_001
tags: [api, buffer, lines]
priority: P0
description: Replace all lines in a scratch buffer.
setup:
  lua: |
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"alpha", "beta", "gamma"})
    return { buf = buf }
action:
  lua: |
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"one", "two", "three"})
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assertions:
  - kind: equal
    path: action_result
    expected: ["one", "two", "three"]
```

**Step 2:** Implement in Zig (sketch)

```zig
// src/api/buffer.zig
pub fn buf_set_lines(lua: *LuaJit) !void {
    const buf = try lua.check_buffer(1);
    const start = try lua.check_int(2);
    const end = try lua.check_int(3);
    const strict_indexing = try lua.check_bool(4);
    const lines = try lua.check_string_array(5);
    _ = strict_indexing;
    const buf_obj = try editor.get_buffer(buf);
    const actual_end = if (end < 0) @as(i32, @intCast(buf_obj.line_count)) + end + 1 else end;
    try buf_obj.replace_lines(@intCast(start), @intCast(actual_end), lines);
}
```

**Step 3:** Run

```bash
$ ./run.sh cases/api/buf_set_lines/basic.yaml
FAIL api.buf_set_lines.basic_001
...
0/1 passed (0.0%)
```

**Step 4:** ดู diff

```markdown
### FAIL `api.buf_set_lines.basic_001`

- `$.action_result`: ref=`["one","two","three"]` vs cand=`["alpha","beta","gamma"]` (mismatch)
```

**Step 5:** Fix - พบว่า `buf_set_lines` ใน zigvim ไม่ได้เรียก `replace_lines` จริง แต่เป็น stub

**Step 6:** Re-run -> PASS

### 10.2 Regression Test: oil.nvim rename flow

```bash
$ ./run.sh cases/plugins/oil/ --tags plugin
PASS plugin.oil.open_directory
PASS plugin.oil.edit_file
FAIL plugin.oil.rename_file
FAIL plugin.oil.delete_file
...
2/12 passed
```

Diff จะชี้ว่า rename ไม่เกิดจริงบน filesystem - bug ใน `vim.fn.rename` implementation -> fix

---

## 11. ขอบเขตที่ Harness ตรวจไม่พบ

สำคัญมาก - harness นี้ **ไม่** ครอบคลุม:

| Gap | เหตุผล | วิธีแก้ |
|-----|-------|---------|
| **TUI rendering correctness** | stdout diff ไม่ได้ capture terminal escapes | Golden screenshot comparison (use `vterm` dump -> image compare) |
| **Keyboard input / keymap edge cases** | ไม่มี human-in-the-loop | Use `xdotool` / `tmux send-keys` + snapshot comparison |
| **Performance parity** | harness วัดเวลาแต่ไม่ได้เทียบ perf | Separate benchmark suite (`zig bench`) |
| **Memory safety / leaks** | Lua-level tests ไม่เห็น Zig bugs | Zig's test runner + sanitizers (ASan) |
| **Plugin lifecycle (setup/init ordering)** | Lazy loading semantics ซับซ้อน | Dedicated `lazy.nvim` compatibility tests |
| **RPC streaming events (UI protocol)** | Notification ordering hard to assert | Record event traces -> trace diffing |
| **Concurrent editor state** | หลาย client พร้อมกัน | Dedicated concurrent test harness |

---

## 12. Appendix — Reference Tables

### A. Environment Summary (ground truth)

```
nvim version          : 0.12.6 (brew)
luajit                 : 2.1.1788856981
zig                    : 0.17.0
vim.api functions      : 181
VIMRUNTIME/lua files   : 128 (92,619 LOC)
plugin corpus          : 55 plugins
brew deps available    : libuv, lpeg, tree-sitter, luajit
```

### B. Complete Plugin Corpus

```
blink.cmp              bufferline.nvim        catppuccin
clangd_extensions.nvim cmake-tools.nvim       conform.nvim
flash.nvim             friendly-snippets      gitsigns.nvim
grug-far.nvim          lazy.nvim              lazydev.nvim
LazyVim                lualine.nvim           markdown-preview.nvim
mason-lspconfig.nvim   mason-nvim-dap.nvim    mason.nvim
mini.ai                mini.icons             mini.pairs
neotest                neotest-playwright     noice.nvim
nui.nvim               nvim-dap               nvim-dap-ui
nvim-dap-virtual-text  nvim-lint              nvim-lspconfig
nvim-nio               nvim-treesitter        nvim-treesitter-textobjects
nvim-ts-autotag        nvim-web-devicons      oil.nvim
persistence.nvim       plenary.nvim           render-markdown.nvim
snacks.nvim            telekasten.nvim        telescope.nvim
todo-comments.nvim     tokyonight.nvim        trouble.nvim
ts-comments.nvim       typescript.nvim
```

### C. Priority Matrix for Test Cases

| Priority | Meaning | Criteria | Example |
|---------|---------|----------|---------|
| **P0** | Must pass before dogfood | Core api used by 5+ plugins | `nvim_buf_set_lines`, `nvim_create_autocmd`, `vim.o` |
| **P1** | Must pass for plugin compatibility | Used by 1-4 plugins | `nvim_set_extmark`, `nvim_win_set_config` |
| **P2** | Nice-to-have | Rare api, low impact | `nvim__id_array`, `nvim_parse_cmd` |
| **P3** | Known gaps / WONTFIX for now | Legacy VimL quirks | `vim.fn.eval` with weird VimL |

### D. Normalization Rules

| Pattern | Why | Normalized to |
|---------|-----|---------------|
| `*.handle`, `*.ptr`, `*.ptrval` | Memory addresses differ | `<normalized:pointer>` |
| `*.runtimepath`, `*.packpath` | Brew path vs Zig out path | `<normalized:path>` |
| `*.created_at`, `*.modified_at` | Timestamps differ | `<normalized:timestamp>` |
| `float` values | Precision differ | `round(x, 6)` |
| `*.name` for anonymous buffers | Handle differs | compare by `lines` only |

### E. Commands Cheatsheet

```bash
# Full suite
./run.sh cases/

# One category
./run.sh cases/api/buf_set_lines/

# By tag
./run.sh cases/ --tags api buffer

# Only P0
./run.sh cases/ --tags priority:P0

# Single case
./run.sh cases/api/buf_set_lines/basic.yaml

# Plugin tests
./run.sh cases/plugins/oil/ --tags plugin

# After every commit
./run.sh cases/ && git commit -m "feat(api): add nvim_buf_set_lines (X/Y P0 passing)"

# Track progress
./scripts/track.sh  # appends to history.jsonl
```

---

## ขั้นตอนถัดไปที่แนะนำ (Action Plan)

1. **สัปดาห์ 1:** สร้าง `conformance/` directory, `pyproject.toml`, `runner.py`, `script.py`, `diff.py` - MVP ที่รัน test case เดียวได้
2. **สัปดาห์ 2:** เขียน test cases P0 จำนวน 30-50 cases ครอบคลุม api หลัก
3. **สัปดาห์ 3:** Integrate กับ `build.zig` ให้ zig build -> test -> fail = ไม่ build
4. **เดือน 2:** ขยายเป็น 200+ test cases + เพิ่ม `rpc.py` executor
5. **เดือน 3:** เพิ่ม `scenario.py` สำหรับ plugin corpus

---

## สรุป: ทำไม harness นี้จำเป็น

**Without harness:** คุณต้อง test ด้วยมือทีละ plugin -> ไม่ scalable, human error, ไม่มี regression tracking
**With harness:** ทุก commit ได้ score ที่ชัดเจน (X/181 api passing), เจอ regression ทันที, plugin corpus ของคุณทำงานเป็น test suite ให้อัตโนมัติ

เป้าหมายสุดท้าย: **เมื่อ harness ผ่าน 100% P0+P1 + ทุก plugin ใน corpus - zigvim พร้อมสำหรับ dogfood ทุกวัน**
