#!/usr/bin/env python3
"""llf_send_test — synthetic Epic Live Link Face sender, for testing the face-tracking chain without
an iPhone.

It emits the same UDP datagrams the Live Link Face app sends in ARKit mode (big-endian header + 52
ARKit blendshape floats + head/eye floats) with an animated test pattern: a blinking eye, a jaw that
opens and closes, and a smile. Point facetrack.py at it and watch VRChat's avatar react.

    llf_send_test.py [--host 127.0.0.1] [--port 11111] [--fps 60] [--seconds 0]
"""
import argparse
import math
import socket
import struct
import time

ARKIT_SHAPES = [
    "eyeBlinkLeft", "eyeLookDownLeft", "eyeLookInLeft", "eyeLookOutLeft", "eyeLookUpLeft",
    "eyeSquintLeft", "eyeWideLeft",
    "eyeBlinkRight", "eyeLookDownRight", "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight",
    "eyeSquintRight", "eyeWideRight",
    "jawForward", "jawLeft", "jawRight", "jawOpen",
    "mouthClose", "mouthFunnel", "mouthPucker", "mouthLeft", "mouthRight",
    "mouthSmileLeft", "mouthSmileRight", "mouthFrownLeft", "mouthFrownRight",
    "mouthDimpleLeft", "mouthDimpleRight", "mouthStretchLeft", "mouthStretchRight",
    "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
    "mouthPressLeft", "mouthPressRight", "mouthLowerDownLeft", "mouthLowerDownRight",
    "mouthUpperUpLeft", "mouthUpperUpRight",
    "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight", "noseSneerLeft", "noseSneerRight",
    "tongueOut",
]
IDX = {n: i for i, n in enumerate(ARKIT_SHAPES)}


def packet(values, device="LiveLinkFace Test", uuid="00000000-0000-0000-0000-000000000000",
           frame=0, fps=60):
    head = struct.pack(">b", 6)
    head += struct.pack(">i", len(uuid)) + uuid.encode()
    head += struct.pack(">i", len(device)) + device.encode()
    head += struct.pack(">IIII", frame, 0, fps, 1)          # frame time block (16 bytes)
    body = struct.pack(">%df" % len(values), *values)
    return head + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=11111)
    ap.add_argument("--fps", type=float, default=60)
    ap.add_argument("--seconds", type=float, default=0)
    args = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    t0 = time.monotonic()
    n = 0
    print(f"llf_send_test: sending synthetic Live Link Face ARKit packets to {args.host}:{args.port}")
    while True:
        t = time.monotonic() - t0
        vals = [0.0] * 61
        # blink both eyes for 0.15 s every 2 s
        blink = 1.0 if (t % 2.0) < 0.15 else 0.0
        vals[IDX["eyeBlinkLeft"]] = blink
        vals[IDX["eyeBlinkRight"]] = blink
        # jaw opens on a 3 s sine
        vals[IDX["jawOpen"]] = 0.5 + 0.5 * math.sin(t * 2 * math.pi / 3.0)
        # smile pulses on a 5 s sine
        smile = 0.5 + 0.5 * math.sin(t * 2 * math.pi / 5.0)
        vals[IDX["mouthSmileLeft"]] = smile
        vals[IDX["mouthSmileRight"]] = smile
        # brows alternate every second
        vals[IDX["browInnerUp"]] = 0.5 + 0.5 * math.sin(t * 2 * math.pi)
        s.sendto(packet(vals, frame=n, fps=int(args.fps)), (args.host, args.port))
        n += 1
        if n % int(args.fps) == 0:
            print(f"  t={t:5.1f}s sent {n} packets jaw={vals[IDX['jawOpen']]:.2f} smile={smile:.2f}")
        if args.seconds and t >= args.seconds:
            break
        time.sleep(1.0 / args.fps)


if __name__ == "__main__":
    main()
