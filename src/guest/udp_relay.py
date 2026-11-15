#!/usr/bin/env python3
"""udp_relay.py — forward UDP from the guest's NIC address to a loopback port (run inside the guest).

VRChat may bind its OSC input to 127.0.0.1:9000 only. A gvproxy forward delivers packets to the
guest's NIC address (192.168.127.2), which a loopback-bound socket never sees. This relay accepts
them on the NIC and re-sends them to 127.0.0.1:9000.

    udp_relay.py [--listen 0.0.0.0:9100] [--forward 127.0.0.1:9000]
"""
import argparse
import socket
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", default="0.0.0.0:9100")
    ap.add_argument("--forward", default="127.0.0.1:9000")
    args = ap.parse_args()
    lhost, lport = args.listen.rsplit(":", 1)
    fhost, fport = args.forward.rsplit(":", 1)

    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    rx.bind((lhost, int(lport)))
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    print(f"udp_relay: {lhost}:{lport} -> {fhost}:{fport}", flush=True)
    n = 0
    while True:
        data, peer = rx.recvfrom(65536)
        tx.sendto(data, (fhost, int(fport)))
        n += 1
        if n % 300 == 0:
            print(f"udp_relay: {n} packets relayed", flush=True)


if __name__ == "__main__":
    sys.exit(main())
