#!/usr/bin/env python3
"""facetrack — Epic Live Link Face (iPhone) → VRChat native OSC face tracking.

Receives the ARKit blendshape stream that Epic's **Live Link Face** iOS app sends over UDP (default
port 11111), maps the 52 ARKit shapes onto VRChat's 102 **Unified Expressions** tracking keys, and
sends them to VRChat as a single OSC blob on `/tracking/face/v1`
(https://creators.vrchat.com/avatars/face-tracking/osc/).

Only VRChat's own OSC input is used: no VRCFaceTracking, no Windows software, nothing running inside
the VM. In a FX Steam Launcher setup the OSC datagrams reach the guest's VRChat through a gvproxy UDP
forward (see scripts/osc-forward.sh).

Usage:
    facetrack.py [--listen 0.0.0.0:11111] [--osc 127.0.0.1:9000] [--smooth 0.5] [--gain 1.0]
                 [--hold 0.4] [--verbose] [--quiet]

  --listen   address for Live Link Face packets (bind the LAN IP to avoid listening on everything)
  --osc      UDP destination of VRChat's OSC input
  --smooth   exponential smoothing 0..0.95 (higher = smoother/slower); default 0.5
  --gain     multiplier applied to every mapped shape before clamping to 0..1
  --hold     seconds without a packet before sending an all-zero frame (default 0.4)
  --verbose  print every mapped frame (about 60/s)
"""
import argparse
import select
import socket
import struct
import sys
import time

# --- Epic Live Link Face payload order: the first 52 floats of the ARKit/MetaHuman packet ------------
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

# --- VRChat tracking key order (indices are the payload byte positions) ------------------------------
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
    "MouthClosed",
    "LipSuckUpperRight", "LipSuckUpperLeft", "LipSuckLowerRight", "LipSuckLowerLeft",
    "LipSuckCornerRight", "LipSuckCornerLeft",
    "LipFunnelUpperRight", "LipFunnelUpperLeft", "LipFunnelLowerRight", "LipFunnelLowerLeft",
    "LipPuckerUpperRight", "LipPuckerUpperLeft", "LipPuckerLowerRight", "LipPuckerLowerLeft",
    "MouthUpperUpRight", "MouthUpperUpLeft", "MouthUpperDeepenRight", "MouthUpperDeepenLeft",
    "NoseSneerRight", "NoseSneerLeft",
    "MouthLowerDownRight", "MouthLowerDownLeft", "MouthUpperRight", "MouthUpperLeft",
    "MouthLowerRight", "MouthLowerLeft",
    "MouthCornerPullRight", "MouthCornerPullLeft", "MouthCornerSlantRight", "MouthCornerSlantLeft",
    "MouthFrownRight", "MouthFrownLeft", "MouthStretchRight", "MouthStretchLeft",
    "MouthDimpleRight", "MouthDimpleLeft", "MouthRaiserUpper", "MouthRaiserLower",
    "MouthPressRight", "MouthPressLeft", "MouthTightenerRight", "MouthTightenerLeft",
    "TongueOut", "TongueUp", "TongueDown", "TongueRight", "TongueLeft",
    "TongueRoll", "TongueBendDown", "TongueCurlUp", "TongueSquish", "TongueFlat",
    "TongueTwistRight", "TongueTwistLeft", "SoftPalateClose", "ThroatSwallow",
    "NeckFlexRight", "NeckFlexLeft",
]
KEY_INDEX = {k: i for i, k in enumerate(VRCHAT_KEYS)}
assert len(VRCHAT_KEYS) == 102

# --- ARKit -> Unified Expressions ---------------------------------------------------------------------
# ARKit has one shape where VRChat has a left/right pair, so several entries fan out. Values land in a
# 0..1 space; "pair" entries are split evenly because ARKit gives no side information.
MAPPING = {
    # eyes
    "eyeBlinkLeft": [("EyeClosedLeft", 1.0)],
    "eyeBlinkRight": [("EyeClosedRight", 1.0)],
    "eyeLookInLeft": [("EyeLookInLeft", 1.0)],
    "eyeLookInRight": [("EyeLookInRight", 1.0)],
    "eyeLookOutLeft": [("EyeLookOutLeft", 1.0)],
    "eyeLookOutRight": [("EyeLookOutRight", 1.0)],
    "eyeLookUpLeft": [("EyeLookUpLeft", 1.0)],
    "eyeLookUpRight": [("EyeLookUpRight", 1.0)],
    "eyeLookDownLeft": [("EyeLookDownLeft", 1.0)],
    "eyeLookDownRight": [("EyeLookDownRight", 1.0)],
    "eyeSquintLeft": [("EyeSquintLeft", 1.0)],
    "eyeSquintRight": [("EyeSquintRight", 1.0)],
    "eyeWideLeft": [("EyeWideLeft", 1.0)],
    "eyeWideRight": [("EyeWideRight", 1.0)],
    # brows
    "browDownLeft": [("BrowLowererLeft", 1.0)],
    "browDownRight": [("BrowLowererRight", 1.0)],
    "browInnerUp": [("BrowInnerUpLeft", 0.6), ("BrowInnerUpRight", 0.6)],
    "browOuterUpLeft": [("BrowOuterUpLeft", 1.0)],
    "browOuterUpRight": [("BrowOuterUpRight", 1.0)],
    # cheeks / nose
    "cheekPuff": [("CheekPuffLeft", 0.8), ("CheekPuffRight", 0.8)],
    "cheekSquintLeft": [("CheekSquintLeft", 1.0)],
    "cheekSquintRight": [("CheekSquintRight", 1.0)],
    "noseSneerLeft": [("NoseSneerLeft", 1.0)],
    "noseSneerRight": [("NoseSneerRight", 1.0)],
    # jaw
    "jawOpen": [("JawOpen", 1.0)],
    "jawForward": [("JawForward", 1.0)],
    "jawLeft": [("JawLeft", 1.0)],
    "jawRight": [("JawRight", 1.0)],
    # mouth
    "mouthClose": [("MouthClosed", 1.0)],
    "mouthFunnel": [("LipFunnelUpperLeft", 0.7), ("LipFunnelUpperRight", 0.7),
                    ("LipFunnelLowerLeft", 0.7), ("LipFunnelLowerRight", 0.7)],
    "mouthPucker": [("LipPuckerUpperLeft", 0.7), ("LipPuckerUpperRight", 0.7),
                    ("LipPuckerLowerLeft", 0.7), ("LipPuckerLowerRight", 0.7)],
    "mouthLeft": [("MouthUpperLeft", 0.6), ("MouthLowerLeft", 0.6)],
    "mouthRight": [("MouthUpperRight", 0.6), ("MouthLowerRight", 0.6)],
    "mouthSmileLeft": [("MouthCornerPullLeft", 1.0)],
    "mouthSmileRight": [("MouthCornerPullRight", 1.0)],
    "mouthFrownLeft": [("MouthFrownLeft", 1.0)],
    "mouthFrownRight": [("MouthFrownRight", 1.0)],
    "mouthDimpleLeft": [("MouthDimpleLeft", 1.0)],
    "mouthDimpleRight": [("MouthDimpleRight", 1.0)],
    "mouthStretchLeft": [("MouthStretchLeft", 1.0)],
    "mouthStretchRight": [("MouthStretchRight", 1.0)],
    "mouthRollLower": [("LipSuckLowerLeft", 0.7), ("LipSuckLowerRight", 0.7)],
    "mouthRollUpper": [("LipSuckUpperLeft", 0.7), ("LipSuckUpperRight", 0.7)],
    "mouthShrugLower": [("MouthRaiserLower", 1.0)],
    "mouthShrugUpper": [("MouthRaiserUpper", 1.0)],
    "mouthPressLeft": [("MouthPressLeft", 1.0)],
    "mouthPressRight": [("MouthPressRight", 1.0)],
    "mouthLowerDownLeft": [("MouthLowerDownLeft", 1.0)],
    "mouthLowerDownRight": [("MouthLowerDownRight", 1.0)],
    "mouthUpperUpLeft": [("MouthUpperUpLeft", 1.0)],
    "mouthUpperUpRight": [("MouthUpperUpRight", 1.0)],
    # tongue
    "tongueOut": [("TongueOut", 1.0)],
}


def parse_packet(data):
    """Decode one Live Link Face UDP datagram -> (device_name, [floats]) or None.

    Layout (big-endian), as sent by the Live Link Face iOS app in ARKit mode:
        u8   message type (6)
        i32  uuid length, uuid bytes
        i32  device name length, device name bytes
        ...  frame time block, then float32 values
    The frame-time block length varies between app versions, so the payload start is located by
    looking for the offset that leaves a plausible whole number of float32 values in range.
    """
    if len(data) < 9:
        return None
    try:
        off = 1  # message type
        ulen = struct.unpack_from(">i", data, off)[0]
        off += 4
        if not 0 <= ulen <= 256 or off + ulen + 4 > len(data):
            return None
        off += ulen
        nlen = struct.unpack_from(">i", data, off)[0]
        off += 4
        if not 0 <= nlen <= 256 or off + nlen > len(data):
            return None
        device = data[off:off + nlen].decode("utf-8", "replace")
        off += nlen
        # The 16 bytes before the float payload are the frame-time block: (frame, subframe, fps,
        # denominator) as big-endian uint32. Checking the fps field pins the payload start far more
        # reliably than the values alone (a 4-float shift leaves plausible-looking zeros behind).
        fallback = None
        for cand in range(off, min(off + 26, len(data))):
            rem = len(data) - cand
            if rem % 4:
                continue
            count = rem // 4
            if count not in (52, 61, 64, 65):
                continue
            vals = struct.unpack_from(">%df" % count, data, cand)
            if not all(-0.02 <= v <= 1.02 for v in vals[:len(ARKIT_SHAPES)]):
                continue
            if cand - off >= 16:
                fps = struct.unpack_from(">I", data, cand - 8)[0]
                frame = struct.unpack_from(">I", data, cand - 16)[0]
                if 1 <= fps <= 240 and frame < 100_000_000:
                    return device, list(vals), cand
            if fallback is None:
                fallback = (device, list(vals), cand)
        return fallback
        return None
    except (struct.error, IndexError, UnicodeDecodeError):
        return None


def osc_blob_message(address, blob):
    """Encode an OSC message with a single blob argument."""
    def padded(b):
        out = b + b"\x00" * (4 - len(b) % 4) if len(b) % 4 else b
        return out
    return padded(address.encode() + b"\x00") + padded(b",b\x00") + struct.pack(">i", len(blob)) + padded(blob)


def map_frame(vals, gain, smooth, state):
    """ARKit floats -> 102 bytes of VRChat tracking keys, with smoothing."""
    raw = [0.0] * 102
    for i, name in enumerate(ARKIT_SHAPES):
        v = vals[i] if i < len(vals) else 0.0
        if v <= 0:
            continue
        for key, weight in MAPPING.get(name, ()):
            idx = KEY_INDEX[key]
            raw[idx] = min(1.0, raw[idx] + v * weight * gain)
    out = bytearray(102)
    for i in range(102):
        s = state[i] + (raw[i] - state[i]) * (1.0 - smooth)
        state[i] = s
        out[i] = 0 if s <= 0.002 else (255 if s >= 1.0 else int(s * 255.0 + 0.5))
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description="Live Link Face -> VRChat OSC face tracking bridge")
    ap.add_argument("--listen", default="0.0.0.0:11111", help="Live Link Face UDP address (default 0.0.0.0:11111)")
    ap.add_argument("--osc", default="127.0.0.1:9000", help="VRChat OSC input (default 127.0.0.1:9000)")
    ap.add_argument("--smooth", type=float, default=0.5, help="0..0.95 smoothing (default 0.5)")
    ap.add_argument("--gain", type=float, default=1.0, help="value multiplier (default 1.0)")
    ap.add_argument("--hold", type=float, default=0.4, help="seconds before an all-zero frame (default 0.4)")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    lhost, lport = args.listen.rsplit(":", 1)
    osc_addr = (args.osc.rsplit(":", 1)[0], int(args.osc.rsplit(":", 1)[1]))

    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    rx.bind((lhost, int(lport)))
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    state = [0.0] * 102
    msg = osc_blob_message("/tracking/face/v1", bytes(102))
    frames = 0
    packets = 0
    last_packet = 0.0
    last_stat = time.monotonic()
    device = "?"
    print(f"facetrack: listening for Live Link Face on {lhost}:{lport}, "
          f"sending /tracking/face/v1 to {osc_addr[0]}:{osc_addr[1]}", flush=True)

    try:
        while True:
            r, _, _ = select.select([rx], [], [], 0.005)
            now = time.monotonic()
            if r:
                data, _ = rx.recvfrom(65536)
                parsed = parse_packet(data)
                if parsed:
                    device, vals, poff = parsed
                    packets += 1
                    last_packet = now
                    blob = map_frame(vals, args.gain, max(0.0, min(0.95, args.smooth)), state)
                    msg = osc_blob_message("/tracking/face/v1", blob)
                    tx.sendto(msg, osc_addr)
                    frames += 1
                    if args.verbose:
                        top = sorted(((blob[i], VRCHAT_KEYS[i]) for i in range(102) if blob[i]), reverse=True)[:5]
                        print("  " + " ".join(f"{k}={v}" for v, k in top), flush=True)
                elif not args.quiet:
                    print(f"facetrack: unparsable packet ({len(data)} bytes) from Live Link Face", flush=True)
            elif now - last_packet > args.hold and any(state):
                # sender stopped: release the face instead of freezing the last expression
                for i in range(102):
                    state[i] = 0.0
                tx.sendto(osc_blob_message("/tracking/face/v1", bytes(102)), osc_addr)
                frames += 1

            if now - last_stat >= 1.0:
                if not args.quiet:
                    sent = frames
                    print(f"facetrack: {packets} pkt/s, {sent} OSC/s, device={device}", flush=True)
                packets = frames = 0
                last_stat = now
    except KeyboardInterrupt:
        print("\nfacetrack: stopped")
    finally:
        for i in range(102):
            state[i] = 0.0
        tx.sendto(osc_blob_message("/tracking/face/v1", bytes(102)), osc_addr)
        rx.close()
        tx.close()


if __name__ == "__main__":
    sys.exit(main())
