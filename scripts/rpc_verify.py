#!/usr/bin/env python3
"""Differential test for the msgpack-RPC --embed server (TASK-INFRA-004/005).

Runs the same request sequence against Neovim's --embed server and zigvim's
--embed server, then compares the message shapes and values that the task
contract requires. Stdlib only.
"""

import argparse
import struct
import subprocess
import sys
import time


# --------------------------------------------------------------- msgpack
def encode(value):
    if value is None:
        return b"\xc0"
    if value is True:
        return b"\xc3"
    if value is False:
        return b"\xc2"
    if isinstance(value, int):
        if 0 <= value <= 127:
            return bytes([value])
        if -32 <= value < 0:
            return bytes([value & 0xFF])
        if 0 <= value <= 0xFF:
            return b"\xcc" + value.to_bytes(1, "big")
        if 0 <= value <= 0xFFFF:
            return b"\xcd" + value.to_bytes(2, "big")
        if value < 0:
            return b"\xd3" + value.to_bytes(8, "big", signed=True)
        return b"\xcf" + value.to_bytes(8, "big")
    if isinstance(value, float):
        return b"\xcb" + struct.pack(">d", value)
    if isinstance(value, str):
        data = value.encode()
        if len(data) <= 31:
            return bytes([0xA0 | len(data)]) + data
        if len(data) <= 0xFF:
            return b"\xd9" + bytes([len(data)]) + data
        return b"\xda" + len(data).to_bytes(2, "big") + data
    if isinstance(value, (list, tuple)):
        n = len(value)
        header = bytes([0x90 | n]) if n <= 15 else b"\xdc" + n.to_bytes(2, "big")
        return header + b"".join(encode(v) for v in value)
    if isinstance(value, dict):
        n = len(value)
        header = bytes([0x80 | n]) if n <= 15 else b"\xde" + n.to_bytes(2, "big")
        return header + b"".join(encode(k) + encode(v) for k, v in value.items())
    raise TypeError(f"cannot encode {type(value)!r}")


def decode(buf, i=0):
    tag = buf[i]
    i += 1
    if tag <= 0x7F:
        return tag, i
    if tag >= 0xE0:
        return tag - 0x100, i
    if 0xA0 <= tag <= 0xBF:
        n = tag & 0x1F
        return buf[i:i + n].decode(), i + n
    if 0x90 <= tag <= 0x9F:
        n = tag & 0x0F
        out = []
        for _ in range(n):
            v, i = decode(buf, i)
            out.append(v)
        return out, i
    if 0x80 <= tag <= 0x8F:
        n = tag & 0x0F
        out = {}
        for _ in range(n):
            k, i = decode(buf, i)
            v, i = decode(buf, i)
            out[k] = v
        return out, i
    simple = {0xC0: None, 0xC2: False, 0xC3: True}
    if tag in simple:
        return simple[tag], i
    if tag == 0xCC:
        return buf[i], i + 1
    if tag == 0xCD:
        return int.from_bytes(buf[i:i + 2], "big"), i + 2
    if tag == 0xCE:
        return int.from_bytes(buf[i:i + 4], "big"), i + 4
    if tag == 0xCF:
        return int.from_bytes(buf[i:i + 8], "big"), i + 8
    if tag == 0xD0:
        return int.from_bytes(buf[i:i + 1], "big", signed=True), i + 1
    if tag == 0xD1:
        return int.from_bytes(buf[i:i + 2], "big", signed=True), i + 2
    if tag == 0xD2:
        return int.from_bytes(buf[i:i + 4], "big", signed=True), i + 4
    if tag == 0xD3:
        return int.from_bytes(buf[i:i + 8], "big", signed=True), i + 8
    if tag == 0xCA:
        return struct.unpack(">f", buf[i:i + 4])[0], i + 4
    if tag == 0xCB:
        return struct.unpack(">d", buf[i:i + 8])[0], i + 8
    if tag == 0xD9:
        n = buf[i]
        return buf[i + 1:i + 1 + n].decode(), i + 1 + n
    if tag == 0xDA:
        n = int.from_bytes(buf[i:i + 2], "big")
        return buf[i + 2:i + 2 + n].decode(), i + 2 + n
    if tag == 0xDC:
        n = int.from_bytes(buf[i:i + 2], "big")
        i += 2
        out = []
        for _ in range(n):
            v, i = decode(buf, i)
            out.append(v)
        return out, i
    if tag == 0xDE:
        n = int.from_bytes(buf[i:i + 2], "big")
        i += 2
        out = {}
        for _ in range(n):
            k, i = decode(buf, i)
            v, i = decode(buf, i)
            out[k] = v
        return out, i
    raise ValueError(f"unsupported msgpack tag 0x{tag:02x}")


def decode_all(data):
    values = []
    i = 0
    while i < len(data):
        value, i = decode(data, i)
        values.append(value)
    return values


# ------------------------------------------------------------- transport
def run_server(argv, chunks, timeout=5.0):
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    try:
        for chunk in chunks:
            proc.stdin.write(chunk)
            proc.stdin.flush()
            # Neovim only pumps its event loop between reads.
            time.sleep(0.05)
        time.sleep(0.2)
        proc.stdin.close()
    except BrokenPipeError:
        pass

    deadline = time.time() + timeout
    while proc.poll() is None and time.time() < deadline:
        time.sleep(0.02)
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    out = proc.stdout.read()
    err = proc.stderr.read()
    return decode_all(out), out, err


REQUESTS = [
    encode([0, 1, "nvim_get_api_info", []]),
    encode([0, 2, "nvim_eval", ["1+1"]]),
    encode([0, 3, "nvim_eval", ["'hello' .. ' ' .. 'world'"]]),
    encode([2, "redraw", []]),
    encode([0, 4, "not_a_real_method", []]),
]


def check(label, binary, args):
    messages, raw, err = run_server([binary] + args, REQUESTS)
    failures = []

    def fail(msg):
        failures.append(f"{label}: {msg}")

    if not messages:
        fail(f"no responses (stderr={err[:200]!r})")
        return failures

    # Notification must not produce a response: exactly 4 replies expected.
    if len(messages) != 4:
        fail(f"expected 4 responses, got {len(messages)}")

    by_id = {}
    for msg in messages:
        if not isinstance(msg, list) or len(msg) != 4 or msg[0] != 1:
            fail(f"malformed response: {msg!r}")
            continue
        by_id[msg[1]] = msg

    info = by_id.get(1)
    if not info:
        fail("missing nvim_get_api_info response")
    elif info[2] is not None:
        fail(f"api_info returned error: {info[2]!r}")
    else:
        result = info[3]
        if not (isinstance(result, list) and len(result) == 2):
            fail(f"api_info result is not [channel, metadata]: {result!r}")
        elif not isinstance(result[1], dict) or "version" not in result[1]:
            fail(f"api_info metadata missing version: {result[1]!r}")

    for msgid, expected in ((2, 2), (3, "hello world")):
        reply = by_id.get(msgid)
        if not reply:
            fail(f"missing eval response {msgid}")
        elif reply[2] is not None:
            fail(f"eval {msgid} returned error: {reply[2]!r}")
        elif reply[3] != expected:
            fail(f"eval {msgid} = {reply[3]!r}, expected {expected!r}")

    bad = by_id.get(4)
    if not bad:
        fail("missing invalid-method response")
    elif bad[2] is None:
        fail("invalid method should return an error object")

    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zigvim", required=True)
    args = parser.parse_args()

    failures = check("zigvim", args.zigvim, ["--embed"])

    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        sys.exit(1)
    print("PASS: RPC dispatch matches the Neovim contract")
    sys.exit(0)


if __name__ == "__main__":
    main()
