#!/usr/bin/env python3
"""Mac-side probe for the Android TV Remote v2 protocol, used to validate AirPoint's client.

  pair <host>          start pairing; type the 6-character code shown on the TV
  key <host> <code>    send one key (e.g. 23 = DPAD_CENTER)
  text <host> <text>   replace the focused text field's contents

Uses ios/Identity/cert.pem + key.pem (the same identity the iPhone app bundles).
Pure standard library: protobuf is encoded by hand.
"""
import hashlib
import os
import socket
import ssl
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CERT = ROOT / "ios/Identity/cert.pem"
KEY = ROOT / "ios/Identity/key.pem"


# ---------------------------------------------------------------- protobuf

def varint(n):
    out = bytearray()
    n &= (1 << 64) - 1
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def f_varint(field, value):
    return varint(field << 3 | 0) + varint(value)


def f_bytes(field, data):
    if isinstance(data, str):
        data = data.encode()
    return varint(field << 3 | 2) + varint(len(data)) + data


def read_varint(buf, pos):
    shift = result = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, pos
        shift += 7


def parse(buf):
    """Returns {field: [values]} where values are ints or bytes."""
    fields, pos = {}, 0
    while pos < len(buf):
        key, pos = read_varint(buf, pos)
        field, wire = key >> 3, key & 7
        if wire == 0:
            val, pos = read_varint(buf, pos)
        elif wire == 2:
            ln, pos = read_varint(buf, pos)
            val = buf[pos:pos + ln]
            pos += ln
        elif wire == 5:
            val = buf[pos:pos + 4]; pos += 4
        elif wire == 1:
            val = buf[pos:pos + 8]; pos += 8
        else:
            raise ValueError(f"wire type {wire}")
        fields.setdefault(field, []).append(val)
    return fields


class Framed:
    def __init__(self, host, port):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.load_cert_chain(CERT, KEY)
        raw = socket.create_connection((host, port), timeout=10)
        self.sock = ctx.wrap_socket(raw, server_hostname=host)
        self.buf = b""

    def send(self, msg):
        self.sock.sendall(varint(len(msg)) + msg)

    def recv(self):
        while True:
            if self.buf:
                try:
                    ln, pos = read_varint(self.buf, 0)
                    if len(self.buf) >= pos + ln:
                        msg = self.buf[pos:pos + ln]
                        self.buf = self.buf[pos + ln:]
                        return msg
                except IndexError:
                    pass
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk


# ---------------------------------------------------------------- pairing

def rsa_numbers_pem(pem_or_der, der=False):
    args = ["openssl", "x509", "-noout", "-modulus"] + (["-inform", "DER"] if der else [])
    mod = subprocess.run(args, input=pem_or_der, capture_output=True, check=True).stdout.decode().strip()
    modulus = int(mod.split("=", 1)[1], 16)
    text = subprocess.run(["openssl", "x509", "-noout", "-text"] + (["-inform", "DER"] if der else []),
                          input=pem_or_der, capture_output=True, check=True).stdout.decode()
    exp = int(text.split("Exponent:")[1].split()[0])
    return modulus, exp


def int_bytes(v):
    return v.to_bytes((v.bit_length() + 7) // 8, "big")


def outer(body):
    return f_varint(1, 2) + f_varint(2, 200) + body


def pair(host):
    c = Framed(host, 6467)
    c.send(outer(f_bytes(10, f_bytes(1, "atvremote") + f_bytes(2, "AirPoint"))))
    print("ack:", parse(c.recv()))
    enc = f_varint(1, 3) + f_varint(2, 6)
    c.send(outer(f_bytes(20, f_bytes(1, enc) + f_varint(3, 1))))
    print("options:", parse(c.recv()))
    c.send(outer(f_bytes(30, f_bytes(1, enc) + f_varint(2, 1))))
    print("config ack:", parse(c.recv()))
    code_file = os.environ.get("CODE_FILE")
    if code_file:
        print("Waiting for code in", code_file, flush=True)
        while not (os.path.exists(code_file) and open(code_file).read().strip()):
            time.sleep(0.5)
        code = open(code_file).read().strip().upper()
    else:
        code = input("Code shown on TV: ").strip().upper()
    cm, ce = rsa_numbers_pem(CERT.read_bytes())
    sm, se = rsa_numbers_pem(c.sock.getpeercert(True), der=True)
    h = hashlib.sha256()
    for v in (cm, ce, sm, se):
        h.update(int_bytes(v))
    h.update(bytes.fromhex(code[2:]))
    digest = h.digest()
    if digest[0] != int(code[:2], 16):
        sys.exit("Code check failed (typo?)")
    c.send(outer(f_bytes(40, f_bytes(1, digest))))
    print("secret ack:", parse(c.recv()))
    print("Paired.")


# ---------------------------------------------------------------- remote

def remote(host, after_ready):
    c = Framed(host, 6466)
    active = 1 | 2 | 4 | 32 | 64 | 512   # PING KEY IME POWER VOLUME APP_LINK
    ready = False
    deadline = time.time() + 8
    while time.time() < deadline:
        m = parse(c.recv())
        if 1 in m:   # remote_configure
            cfg = parse(m[1][0])
            print("TV features:", cfg.get(1))
            info = f_varint(3, 1) + f_bytes(4, "1") + f_bytes(5, "atvremote") + f_bytes(6, "1.0.0") \
                + f_bytes(1, "iPhone") + f_bytes(2, "AirPoint")
            c.send(f_bytes(1, f_varint(1, active & cfg[1][0]) + f_bytes(2, info)))
        elif 2 in m:  # remote_set_active
            c.send(f_bytes(2, f_varint(1, active)))
        elif 8 in m:  # ping
            c.send(f_bytes(9, f_varint(1, parse(m[8][0]).get(1, [0])[0])))
        elif 40 in m:  # remote_start
            print("remote started:", parse(m[40][0]))
            ready = True
            break
        else:
            print("msg:", {k: v for k, v in m.items()})
    if not ready:
        sys.exit("Remote never became ready")
    after_ready(c)
    time.sleep(0.5)


def key(host, code):
    def go(c):
        time.sleep(0.8)
        c.send(f_bytes(10, f_varint(1, int(code)) + f_varint(2, 3)))
        time.sleep(1.0)
    remote(host, go)
    print("sent key", code)


def watch(host, seconds, text=None):
    """Print every message for a while (IME traffic), optionally sending text when a field is active."""
    def go(c):
        c.sock.settimeout(1.0)
        end = time.time() + float(seconds)
        counters = {"ime": 0, "field": 0}
        sent = False
        while time.time() < end:
            try:
                m = parse(c.recv())
            except (socket.timeout, TimeoutError):
                continue
            if 8 in m:
                c.send(f_bytes(9, f_varint(1, parse(m[8][0]).get(1, [0])[0])))
                continue
            print("msg", {k: (v if k not in (20, 21, 22) else [parse(x) for x in v]) for k, v in m.items()}, flush=True)
            if 20 in m:
                inj = parse(m[20][0])
                if 1 in inj: counters["ime"] = parse(inj[1][0]).get(1, [0])[0]
                if 2 in inj: counters["field"] = parse(inj[2][0]).get(1, [0])[0]
                print("  app_info:", parse(inj[1][0]) if 1 in inj else None, " field:", parse(inj[2][0]) if 2 in inj else None, flush=True)
            if 22 in m:
                fs = parse(parse(m[22][0])[2][0])
                counters["field"] = fs.get(1, [0])[0]
            if 21 in m:
                b = parse(m[21][0])
                counters["ime"] = b.get(1, [counters["ime"]])[0] or counters["ime"]
            if text and not sent and (20 in m or 22 in m):
                time.sleep(0.3)
                obj = f_varint(1, len(text)) + f_varint(2, len(text)) + f_bytes(3, text)
                edit = f_varint(1, 1) + f_bytes(2, obj)
                batch = f_varint(1, counters["ime"]) + f_varint(2, counters["field"]) + f_bytes(3, edit)
                c.send(f_bytes(21, batch))
                print("sent text with counters", counters, flush=True)
                if os.environ.get("RAPID"):
                    t2 = text + "Z"
                    obj = f_varint(1, len(t2)) + f_varint(2, len(t2)) + f_bytes(3, t2)
                    edit = f_varint(1, 1) + f_bytes(2, obj)
                    c.send(f_bytes(21, f_varint(1, counters["ime"]) + f_varint(2, counters["field"]) + f_bytes(3, edit)))
                    print("sent", t2, "immediately with the same (stale) counters", flush=True)
                sent = True
    remote(host, go)


if __name__ == "__main__":
    cmd, host = sys.argv[1], sys.argv[2]
    if cmd == "pair":
        pair(host)
    elif cmd == "watch":
        watch(host, sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
    elif cmd == "key":
        key(host, sys.argv[3])
    else:
        sys.exit(__doc__)
