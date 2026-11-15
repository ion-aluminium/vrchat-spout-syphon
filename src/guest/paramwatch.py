#!/usr/bin/env python3
"""paramwatch.py — print selected VRChat avatar parameters from OSCQuery (run inside the guest).

Used to verify that a face-tracking source actually reaches VRChat: watches the parameters the avatar
exposes (VRCFT v2 set) plus the built-in face-tracking status booleans.

    paramwatch.py [--seconds 10] [--names JawOpen,FT,v2,...]
"""
import argparse
import json
import time
import urllib.request

DEFAULT = ["JawOpen", "FT", "v2", "EyeLidLeft", "EyeLidRight", "SmileFrownLeft", "MouthSmileLeft",
           "UserFaceTracking", "UserEyeTracking"]


def fetch():
    return json.load(urllib.request.urlopen("http://127.0.0.1:40331/", timeout=4))


def collect(node, want, path="", out=None):
    if out is None:
        out = {}
    for k, v in node.get("CONTENTS", {}).items():
        p = path + "/" + k
        if k in want:
            out[k] = v.get("VALUE")
        collect(v, want, p, out)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--names", default=",".join(DEFAULT))
    ap.add_argument("--interval", type=float, default=1.0)
    args = ap.parse_args()
    want = set(args.names.split(","))
    end = time.time() + args.seconds
    while time.time() < end:
        try:
            vals = collect(fetch(), want)
        except Exception as e:
            print("OSCQuery error:", e, flush=True)
            time.sleep(args.interval)
            continue
        line = "  ".join(f"{k}={vals.get(k)}" for k in args.names.split(",") if k in vals)
        print(f"{time.strftime('%H:%M:%S')}  {line}", flush=True)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
