#!/usr/bin/env python3
"""osc_debug.py — print the OSC traffic VRChat sends (run inside the SteamOS guest).

VRChat's OSC *output* goes to 127.0.0.1:9001 inside the guest, so a host-side process cannot see it.
This tiny listener binds that port and prints addresses (decoding the 102-byte face-tracking blob's
non-zero keys), which is how the bridge validates that VRChat accepted the face data:

    /avatar/avatarfullfacetracking ,T|F     avatar has Face Tracking + "Use All Tracking Keys"
    /avatar/parameters/UserFaceTracking     a face tracking source is active
    /avatar/parameters/UserEyeTracking      eye tracking data is available

Usage (in the guest):  python3 osc_debug.py [--port 9001] [--quiet]
"""
import argparse
import socket
import struct
import sys

VRCHAT_KEYS = [
    "EyeLookOutRight", "EyeLookInRight", "EyeLookUpRight", "EyeLookDownRight",
    "EyeLookOutLeft", "EyeLookInLeft", "EyeLookUpLeft", "EyeLookDownLeft",
    "EyeClosedRight", "EyeClosedLeft", "EyeDilationRight", "EyeDilationLeft",
    "EyeConstrictRight", "EyeConstrictLeft", "EyeSquintRight", "EyeSquintLeft",
    "EyeWideRight", "EyeWideLeft", "BrowPinchRight", "BrowPinchLeft",
    "BrowLowererRight", "BrowLowererLeft", "BrowInnerUpRight", "BrowInnerUpLeft",
    "BrowOuterUpRight", "BrowOuterUpLeft", "NasalDilationRight", "NasalDilationLeft",
    "NasalConstrictRight", "NasalConstrictLeft", "CheekSquintRight", "CheekSquintLeft",
    "CheekPuffRight", "CheekPuffLeft", "CheekSuckRight", "CheekSuckLeft",
    "JawOpen", "JawRight", "JawLeft", "JawForward", "JawBackward", "JawClench", "JawMandibleRaise",
    "MouthClosed", "LipSuckUpperRight", "LipSuckUpperLeft", "LipSuckLowerRight", "LipSuckLowerLeft",
    "LipSuckCornerRight", "LipSuckCornerLeft", "LipFunnelUpperRight", "LipFunnelUpperLeft",
    "LipFunnelLowerRight", "LipFunnelLowerLeft", "LipPuckerUpperRight", "LipPuckerUpperLeft",
    "LipPuckerLowerRight", "LipPuckerLowerLeft", "MouthUpperUpRight", "MouthUpperUpLeft",
    "MouthUpperDeepenRight", "MouthUpperDeepenLeft", "NoseSneerRight", "NoseSneerLeft",
    "MouthLowerDownRight", "MouthLowerDownLeft", "MouthUpperRight", "MouthUpperLeft",
    "MouthLowerRight", "MouthLowerLeft", "MouthCornerPullRight", "MouthCornerPullLeft",
    "MouthCornerSlantRight", "MouthCornerSlantLeft", "MouthFrownRight", "MouthFrownLeft",
    "MouthStretchRight", "MouthStretchLeft", "MouthDimpleRight", "MouthDimpleLeft",
    "MouthRaiserUpper", "MouthRaiserLower", "MouthPressRight", "MouthPressLeft",
    "MouthTightenerRight", "MouthTightenerLeft", "TongueOut", "TongueUp", "TongueDown",
    "TongueRight", "TongueLeft", "TongueRoll", "TongueBendDown", "TongueCurlUp", "TongueSquish",
    "TongueFlat", "TongueTwistRight", "TongueTwistLeft", "SoftPalateClose", "ThroatSwallow",
    "NeckFlexRight", "NeckFlexLeft",
]


def read_string(buf, off):
    end = buf.index(b"\x00", off)
    s = buf[off:end].decode("utf-8", "replace")
    off = end + 1
    off += (-off) % 4
    return s, off


def decode(buf):
    """Minimal OSC message decoder: address + a few int/float/string/T/F/blob arguments."""
    addr, off = read_string(buf, 0)
    tags, off = read_string(buf, off) if off < len(buf) else ("", off)
    args = []
    for t in tags[1:] if tags.startswith(",") else "":
        if t == "i":
            args.append(struct.unpack_from(">i", buf, off)[0]); off += 4
        elif t == "f":
            args.append(round(struct.unpack_from(">f", buf, off)[0], 3)); off += 4
        elif t == "T":
            args.append(True)
        elif t == "F":
            args.append(False)
        elif t == "s":
            s, off = read_string(buf, off); args.append(s)
        elif t == "b":
            n = struct.unpack_from(">i", buf, off)[0]; off += 4
            blob = buf[off:off + n]; off += n; off += (-n) % 4
            if n == 102:
                hot = [(VRCHAT_KEYS[i], blob[i]) for i in range(102) if blob[i] > 8]
                args.append(f"<102B face blob, {len(hot)} active: " +
                            " ".join(f"{k}={v}" for k, v in sorted(hot, key=lambda x: -x[1])[:6]) + ">")
            else:
                args.append(f"<blob {n}B>")
        else:
            args.append(f"<{t}?>")
    return addr, args


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9001)
    ap.add_argument("--bind", default="127.0.0.1", help="bind address (0.0.0.0 to test forwarded packets)")
    ap.add_argument("--quiet", action="store_true", help="only print changed addresses")
    args = ap.parse_args()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((args.bind, args.port))
    print(f"osc_debug: listening on {args.bind}:{args.port}", flush=True)
    last = {}
    while True:
        data, _ = s.recvfrom(65536)
        try:
            addr, vals = decode(data)
        except Exception as e:
            print("decode error:", e, data[:40], flush=True)
            continue
        if args.quiet:
            key = (addr, tuple(map(str, vals)))
            if last.get(addr) == key:
                continue
            last[addr] = key
        print(f"{addr} {vals}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
