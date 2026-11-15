#!/usr/bin/env python3
"""vrcft_bridge.py — carry VRCFaceTracking's OSC from a Windows PC into VRChat running in the VM.

Pairs with `windows-vrcft-bridge.ps1`, which runs on the Windows PC and forwards VRCFT's OSC (VRCFT
keeps its default target 127.0.0.1:9000) to this Mac. Here the packets are relayed into the guest
through a gvproxy UDP forward, and VRChat's OSCQuery is proxied back so VRCFT can see the avatar.

    iPhone Live Link Face --UDP 11111--> VRCFT (Windows) --OSC/UDP--> this bridge
        --UDP--> 127.0.0.1:19000 --gvproxy--> guest 192.168.127.2:9000 (VRChat)

Why a relay at all: the VM sits behind user-mode NAT, so a LAN host cannot address the guest directly.
gvproxy (started by FX Steam Launcher) exposes an HTTP API that can add loopback UDP forwards; this
bridge owns that forward and the LAN-side listener.

Also proxies VRChat's OSCQuery (inside the guest, random port) to `http://<lan-ip>:19090/` over an SSH
tunnel, so VRCFT can resolve `/avatar/change` and the avatar's parameter list.

Usage:
    vrcft_bridge.py [--listen 0.0.0.0:9000] [--relay 127.0.0.1:19000] [--http 0.0.0.0:19090]
                    [--allow 192.168.68.0/24] [--ssh-port 2222] [--quiet]

Endpoints:  GET /status   JSON counters   GET /windows-vrcft-bridge.ps1   the PC helper
            GET /           proxied VRChat OSCQuery (also /?HOST_INFO, /avatar/...)
"""
import argparse
import glob
import http.server
import ipaddress
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent

lock = threading.Lock()
state = {
    "osc_packets": 0,
    "osc_last_peer": None,
    "osc_last_address": None,
    "osc_packets_per_sec": 0.0,
    "query_upstream_port": None,
    "avatar": None,
    "relay": None,
    "listen": None,
    "started": time.time(),
}
forward_api = None


# --------------------------------------------------------------------------- helpers
def guest_ssh(port, args, timeout=8):
    return subprocess.check_output(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no",
         "-p", str(port), "steamos@127.0.0.1"] + args, timeout=timeout, text=True,
        stderr=subprocess.DEVNULL)


def gvproxy_expose(local, remote):
    """Add (or confirm) a gvproxy UDP forward host:local -> guest:remote. Returns the api.sock path."""
    global forward_api
    socks = sorted(glob.glob("/tmp/steamac-*/api.sock"), key=lambda p: Path(p).stat().st_mtime, reverse=True)
    if not socks:
        raise RuntimeError("gvproxy is not running (start FX Steam Launcher first)")
    api = socks[0]
    body = json.dumps({"protocol": "udp", "local": local, "remote": remote})
    r = subprocess.run(["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--unix-socket", api,
                        "-H", "Content-Type: application/json", "-d", body,
                        "http://localhost/services/forwarder/expose"], capture_output=True, text=True)
    if r.stdout.strip() not in ("200", "201"):
        listing = json.loads(subprocess.check_output(
            ["curl", "-fsS", "--unix-socket", api, "http://localhost/services/forwarder/all"], timeout=5))
        if not any(e.get("local") == local and e.get("remote") == remote and e.get("protocol") == "udp"
                   for e in listing):
            raise RuntimeError(f"could not expose {local} -> {remote}: {r.stdout.strip()} {r.stderr.strip()}")
    forward_api = api
    return api


def gvproxy_unexpose(local, remote):
    if not forward_api:
        return
    subprocess.run(["curl", "-sS", "-o", "/dev/null", "--unix-socket", forward_api,
                    "-H", "Content-Type: application/json",
                    "-d", json.dumps({"protocol": "udp", "local": local, "remote": remote}),
                    "http://localhost/services/forwarder/unexpose"], capture_output=True)


def guest_oscquery_port(ssh_port):
    """VRChat advertises OSCQuery on a random loopback port; find it in the guest."""
    out = guest_ssh(ssh_port, ["ss -lntpH"], timeout=8)
    ports = re.findall(r'127\.0\.0\.1:(\d+).*users:\(\("(?:exe|VRChat.exe)"', out)
    for port in ports:
        try:
            data = guest_ssh(ssh_port, [f'curl -fsS --max-time 2 "http://127.0.0.1:{port}/?HOST_INFO"'], timeout=6)
            info = json.loads(data)
            if str(info.get("NAME", "")).startswith("VRChat-Client"):
                return port
        except Exception:
            continue
    return None


def osc_address(payload):
    """First OSC address of a datagram, for logging."""
    try:
        end = payload.index(b"\0")
        return payload[:end].decode("utf-8", "replace")
    except ValueError:
        return repr(payload[:24])


def maintain_forward(local, remote, bw):
    """The VM (and therefore gvproxy) can be restarted at any time: keep the forward alive."""
    global forward_api
    while True:
        try:
            socks = sorted(glob.glob("/tmp/steamac-*/api.sock"),
                           key=lambda p: Path(p).stat().st_mtime, reverse=True)
            if not socks:
                raise RuntimeError("waiting for gvproxy (is FX Steam Launcher running?)")
            if socks[0] != forward_api:
                gvproxy_expose(local, remote)
                if bw:
                    print(f"gvproxy: forward re-established on {forward_api}", flush=True)
        except Exception as exc:
            if bw:
                print(f"gvproxy: {exc}", flush=True)
        time.sleep(5)


# --------------------------------------------------------------------------- OSC relay
def osc_relay(listen, relay_addr, allow_nets, bw):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(listen)
    out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    state["listen"] = f"{listen[0]}:{listen[1]}"
    state["relay"] = f"{relay_addr[0]}:{relay_addr[1]}"
    print(f"osc: listening {listen[0]}:{listen[1]} -> {relay_addr[0]}:{relay_addr[1]}", flush=True)

    window_start, window_count = time.time(), 0
    while True:
        payload, peer = sock.recvfrom(65535)
        ip = ipaddress.ip_address(peer[0])
        if not any(ip in net for net in allow_nets):
            continue
        out.sendto(payload, relay_addr)
        with lock:
            state["osc_packets"] += 1
            state["osc_last_peer"] = f"{peer[0]}:{peer[1]}"
            state["osc_last_address"] = osc_address(payload)
        window_count += 1
        now = time.time()
        if now - window_start >= 1.0:
            with lock:
                state["osc_packets_per_sec"] = window_count / (now - window_start)
                n = state["osc_packets"]
            window_start, window_count = now, 0
            if bw:
                print(f"osc: {n} packets ({state['osc_packets_per_sec']:.0f}/s) from "
                      f"{state['osc_last_peer']} last={state['osc_last_address']}", flush=True)


# --------------------------------------------------------------------------- OSCQuery proxy
def maintain_query_tunnel(ssh_port, local_port, bw):
    """Keep an SSH tunnel to VRChat's OSCQuery port, reconnecting when the port or VM changes."""
    tunnel = None
    while True:
        try:
            port = guest_oscquery_port(ssh_port)
            if not port:
                raise RuntimeError("waiting for VRChat OSCQuery (is VRChat running with OSC enabled?)")
            with lock:
                state["query_upstream_port"] = port
            if tunnel is None or tunnel.poll() is not None:
                if tunnel:
                    tunnel.terminate()
                tunnel = subprocess.Popen(
                    ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-o", "ExitOnForwardFailure=yes",
                     "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", "-N",
                     "-L", f"127.0.0.1:{local_port}:127.0.0.1:{port}", "-p", str(ssh_port), "steamos@127.0.0.1"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if bw:
                    print(f"oscquery: tunnel to guest 127.0.0.1:{port} on 127.0.0.1:{local_port}", flush=True)
            # keep the avatar id fresh for the Windows helper
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{local_port}/avatar/change", timeout=4) as r:
                    val = json.load(r).get("VALUE")
                    if val:
                        with lock:
                            state["avatar"] = val[0]
            except Exception:
                pass
        except Exception as exc:
            if bw:
                print(f"oscquery: {exc}", flush=True)
        time.sleep(10)


def make_handler(query_port_local):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _send(self, code, payload, ctype="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            try:
                if self.path == "/status":
                    with lock:
                        payload = json.dumps(state).encode()
                    return self._send(200, payload)
                if self.path == "/windows-vrcft-bridge.ps1":
                    return self._send(200, (HERE / "windows-vrcft-bridge.ps1").read_bytes(),
                                      "text/plain; charset=utf-8")
                with urllib.request.urlopen(f"http://127.0.0.1:{query_port_local}{self.path}", timeout=4) as r:
                    return self._send(200, r.read())
            except Exception as exc:
                self._send(503, json.dumps({"error": str(exc)}).encode())

    return Handler


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="VRCFaceTracking OSC -> VM VRChat bridge")
    ap.add_argument("--listen", default="0.0.0.0:9000", help="LAN address VRCFT traffic arrives on")
    ap.add_argument("--relay", default="127.0.0.1:19000", help="loopback forward into the guest")
    ap.add_argument("--http", default="0.0.0.0:19090", help="OSCQuery proxy address")
    ap.add_argument("--allow", default="", help="allowed source CIDRs (default: the listen address's /24)")
    ap.add_argument("--ssh-port", type=int, default=2222)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    lhost, lport = args.listen.rsplit(":", 1)
    rhost, rport = args.relay.rsplit(":", 1)
    hhost, hport = args.http.rsplit(":", 1)

    if args.allow:
        nets = [ipaddress.ip_network(c.strip(), strict=False) for c in args.allow.split(",") if c.strip()]
    else:
        base = lhost if lhost != "0.0.0.0" else "192.168.0.0"
        nets = [ipaddress.ip_network(f"{base.rsplit('.', 1)[0]}.0/24", strict=False)]
    nets.append(ipaddress.ip_network("127.0.0.1/32"))

    try:
        api = gvproxy_expose(f"{rhost}:{rport}", "192.168.127.2:9000")
        print(f"gvproxy: udp {rhost}:{rport} -> guest 192.168.127.2:9000 ({api})", flush=True)
    except Exception as exc:
        print(f"gvproxy: {exc}", file=sys.stderr, flush=True)
        return 1

    def cleanup(*_):
        gvproxy_unexpose(f"{rhost}:{rport}", "192.168.127.2:9000")
        print("\nvrcft_bridge: forward removed", flush=True)
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    threading.Thread(target=maintain_forward,
                     args=(f"{rhost}:{rport}", "192.168.127.2:9000", not args.quiet),
                     daemon=True).start()
    threading.Thread(target=osc_relay,
                     args=((lhost, int(lport)), (rhost, int(rport)), nets, not args.quiet),
                     daemon=True).start()
    threading.Thread(target=maintain_query_tunnel, args=(args.ssh_port, 19092, not args.quiet),
                     daemon=True).start()

    httpd = http.server.ThreadingHTTPServer((hhost, int(hport)), make_handler(19092))
    print(f"oscquery: http://{hhost if hhost != '0.0.0.0' else '<lan-ip>'}:{hport}/  "
          f"(status at /status, PC helper at /windows-vrcft-bridge.ps1)", flush=True)
    print(f"allowed sources: {', '.join(str(n) for n in nets)}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
