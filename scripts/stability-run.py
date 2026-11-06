#!/usr/bin/env python3
"""stability-run.py — long-run measurement for the Spout->Syphon bridge.

While VRChat sends its Spout camera, this records once per second:
  * frames per second actually delivered to a Syphon client, and the longest gap (drops/stalls)
  * the bridge's own publish rate and source update rate (from /tmp/spoutsyphon.log)
and once per 5 s:
  * CPU% and RSS of the VM process (steamac-vm), OBS, and the guest's load average via SSH

At the end it prints a summary (min/mean/max fps, worst gap, CPU, RSS drift) and writes two CSVs.

  scripts/stability-run.py --minutes 10 [--tag NAME]
"""
import argparse
import csv
import os
import re
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG = os.environ.get("SPOUTSYPHON_LOG", "/tmp/spoutsyphon.log")


def ps_usage(pattern):
    """CPU% and RSS(KB) of the largest process matching a pgrep -f pattern."""
    try:
        pids = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split()
    except Exception:
        return None, None
    best = (0.0, 0)
    for pid in pids:
        try:
            out = subprocess.run(["ps", "-o", "%cpu=,rss=", "-p", pid], capture_output=True, text=True).stdout
            parts = out.split()
            if len(parts) >= 2:
                best = max(best, (float(parts[0]), int(parts[1])))
        except Exception:
            pass
    return best


def guest_load():
    try:
        out = subprocess.run([os.path.join(ROOT, "scripts", "guest-ssh.sh"), "cat /proc/loadavg"],
                             capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL).stdout.strip()
        return out.split()[0] if out else ""
    except Exception:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=10)
    ap.add_argument("--tag", default=time.strftime("%Y%m%d-%H%M%S"))
    ap.add_argument("--name", default=os.environ.get("SPOUTSYPHON_NAME", "VRChat Spout Camera"))
    args = ap.parse_args()

    secs = int(args.minutes * 60)
    fdir = os.path.join(ROOT, "evidence", "stability")
    os.makedirs(fdir, exist_ok=True)
    fps_csv = os.path.join(fdir, f"fps-{args.tag}.csv")
    host_csv = os.path.join(fdir, f"host-{args.tag}.csv")

    print(f"recording {secs}s -> {fps_csv} / {host_csv}")
    stats = subprocess.Popen([os.path.join(ROOT, "build", "syphon_stats"), "--name", args.name,
                              "--seconds", str(secs), "--csv", fps_csv, "--require-frames", "10"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    rows = []
    t0 = time.time()
    log_pos = 0
    try:
        with open(host_csv, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["t", "vm_cpu", "vm_rss_mb", "obs_cpu", "obs_rss_mb", "guest_load",
                        "bridge_publish_fps", "bridge_source_fps", "syphon_clients"])
            while time.time() - t0 < secs + 2:
                time.sleep(5)
                vm_cpu, vm_rss = ps_usage("FX Steam Launcher.app/Contents/MacOS/steamac-vm")
                ob_cpu, ob_rss = ps_usage("/Applications/OBS.app/Contents/MacOS/OBS")
                pub = src = cli = ""
                try:
                    with open(LOG) as f:
                        f.seek(log_pos)
                        chunk = f.read()
                        log_pos = f.tell()
                    m = re.findall(
                        r"publish ([\d.]+) fps.*source \d+x\d+ (\w*) ?update ([\d.]+)/s, flip=\d, "
                        r"syphon clients=(\d+)", chunk)
                    if m:
                        pub, srcf, cli = m[-1][0], m[-1][2], m[-1][3]
                        src = srcf
                except Exception:
                    pass
                row = [round(time.time() - t0, 1), vm_cpu, round((vm_rss or 0) / 1024, 1),
                       ob_cpu, round((ob_rss or 0) / 1024, 1), guest_load(), pub, src, cli]
                w.writerow(row)
                fh.flush()
                rows.append(row)
    finally:
        try:
            out, _ = stats.communicate(timeout=max(10, secs))
        except Exception:
            stats.kill()
            out = ""

    # ---- summary
    print("\n=== bridge summary ===")
    lines = [l for l in out.splitlines() if l.startswith("t=")]
    fps = []
    gaps = []
    for l in lines:
        m = re.search(r"fps=\s*([\d.]+)", l)
        g = re.search(r"max_gap=\s*([\d.]+)", l)
        if m:
            fps.append(float(m.group(1)))
        if g:
            gaps.append(float(g.group(1)))
    if fps:
        print(f"syphon fps: min {min(fps):.1f} mean {sum(fps)/len(fps):.1f} max {max(fps):.1f} over {len(fps)}s")
        print(f"worst inter-frame gap: {max(gaps):.1f} ms")
    else:
        print("no syphon frames recorded")
    if rows:
        vm = [r[1] for r in rows if r[1] is not None]
        ob = [r[3] for r in rows if r[3] is not None]
        rss = [r[2] for r in rows]
        print(f"steamac-vm CPU%: mean {sum(vm)/len(vm):.1f} max {max(vm):.1f}")
        print(f"OBS CPU%:        mean {sum(ob)/len(ob):.1f} max {max(ob):.1f}")
        print(f"steamac-vm RSS:  start {rss[0]:.0f} MB end {rss[-1]:.0f} MB (drift {rss[-1]-rss[0]:+.0f} MB)")
    print(f"csv: {fps_csv}")
    print(f"csv: {host_csv}")


if __name__ == "__main__":
    main()
