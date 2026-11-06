# Install, use, roll back

Everything here is reversible and leaves the launcher bundle, the SteamOS disk image, the Proton prefix
and OBS's own installation untouched. The only persistent changes are (a) files in this project directory
and (b) one Syphon source added to an OBS scene collection (backed up automatically).

## 1. Prerequisites

| Piece | Version used here | Notes |
| --- | --- | --- |
| macOS | 27.2 (26B123), Apple M5, 24 GB | Apple silicon required (the bridge links OBS's arm64 Syphon) |
| Xcode command line tools | `clang` from CLT | `xcode-select --install` |
| OBS | 33.0.1 (bundle 40954849292) | supplies `Syphon.framework` (Syphon 5) that we link against |
| FX Steam Launcher | 1.9.8 | the VM/launcher; must be ad-hoc signed without hardened runtime (1.9.8 is) |
| Guest | SteamOS, Proton Experimental, DXMT | already the state of this machine; nothing to install in the guest |

Optional, only for the independent guest-side test sender: `brew install mingw-w64` (14.0.0 used here).

## 2. Build

```bash
cd ~/Projects/VRC-SpoutBridge
scripts/build.sh
```

Outputs `build/libSpoutSyphon.dylib` plus the test/measurement tools. The dylib's only link-time
dependency outside the system frameworks is `Syphon.framework` from `/Applications/OBS.app/Contents/
Frameworks` (`OBS_APP=/path/to/OBS.app scripts/build.sh` to override). `otool -L` should show
`@rpath/Syphon.framework/...` and `/usr/lib/libSystem` only.

## 3. Run

```bash
scripts/launch-with-bridge.sh            # asks before quitting a running launcher
scripts/launch-with-bridge.sh --yes      # no prompt
```

This quits FX Steam Launcher (AppleScript `quit`, graceful), then relaunches it through
`open --env DYLD_INSERT_LIBRARIES=…` with:

| variable | default | meaning |
| --- | --- | --- |
| `SPOUTSYPHON_ENABLE` | 1 | the dylib is inert without it |
| `SPOUTSYPHON_NAME` | `VRChat Spout Camera` | Syphon server name |
| `SPOUTSYPHON_FPS` | 30 | publish rate cap |
| `SPOUTSYPHON_FLIP` | 1 | flip vertically for OBS's Syphon drawing convention |

Source selection is automatic: a newly created shared texture only becomes the published source once it
is observed to change, and a source that stops changing for 2 s is replaced by a newer live candidate.
That is what makes VRChat's resolution change (it destroys and recreates the sender) and unrelated small
shared textures (a 640×360 face-mirror helper) behave.
| `SPOUTSYPHON_LOG` | `/tmp/spoutsyphon.log` | log file |

Every child process of the launcher inherits the variable, so the hook is present in whichever process
runs the Metal executor. The injection applies to this launch only.

### Live settings (no restart)

`/tmp/spoutsyphon.conf` is re-read once a second:

```
flip=1        # 0/1, vertical flip for Syphon consumers (OBS wants 1)
fps=30        # publish cap
probe=1       # measure the source's real update rate (one small GPU readback per frame)
name=VRChat Spout Camera
```

## 4. OBS

Manual (the normal way): **Sources → + → Syphon Client →** pick **VRChat Spout Camera**. OBS stores the
server's name, app name and UUID and reconnects by name after a VM restart.

Scripted (what was used for the validation screenshots):

```bash
scripts/obs-add-syphon-source.py     # edits the scene collection; OBS must be closed
scripts/pin-obs-source.sh            # same, but reads name/app/uuid from the live server and restarts OBS
```

The source is added with `bounds_type = scale-inner` to 1920×1080, so 720p and 1080p camera output both
fill the canvas without distortion. The scene collection is backed up as
`Untitled.json.bak-spoutbridge-<timestamp>` next to itself before every edit.

> OBS's `mac-syphon` only accepts a server announce when **both** the app name and the server name match
> its stored settings (or the UUID matches). Syphon takes the app name from the server process's bundle,
> which here is **FX Steam Launcher**. If you add the source by hand OBS fills this in for you; if the
> source is created programmatically without it, the frame stays black — run `scripts/pin-obs-source.sh`.

## 5. Verify

```bash
scripts/status.sh                  # launcher, dylib presence, log tail, Syphon servers
build/syphon_stats --seconds 10    # frames/s, worst gap, geometry, mean RGBA delivered to a client
build/syphon_list                  # name / app / uuid of every Syphon server
```

In VRChat: **Camera → Mode = Stream**, then turn on **Spout Stream**. The camera's
**Stream Resolution** setting chooses 720p/1080p/1440p/2160p. Camera **Mask** toggles (World, Remote
Player, UI…) decide what becomes transparent — with World masked off the background is transparent and
the alpha arrives in OBS intact.

The bridge log then shows one `newSharedTexture … ACCEPTED` line per sender:

```
15:18:56.702 [33646] newSharedTexture 1920x1080 fmt=RGBA8Unorm usage=0x5 storage=2 why=hook -> ACCEPTED
15:18:56.707 [33646] syphon server 'VRChat Spout Camera' started on device Apple M5 (source 1920x1080)
```

## 6. Roll back

| Level | Action |
| --- | --- |
| Stop the bridge | Quit FX Steam Launcher and start it normally (Finder/Dock). Nothing else is needed: the injection is per-launch. |
| Remove the OBS source | OBS → Sources → right-click *VRChat Spout Camera* → Remove. Or restore a `Untitled.json.bak-spoutbridge-*` backup. |
| Remove everything | Delete `~/Projects/VRC-SpoutBridge`. No system, launcher, guest or Proton file was modified. |

To confirm the launcher is clean: `pgrep -lf steamac-vm` should show no `libSpoutSyphon` in
`vmmap <pid> | grep SpoutSyphon`.

## 7. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| OBS source black, `syphon_list` shows the server | app/server name mismatch in the source settings → `scripts/pin-obs-source.sh` |
| OBS shows the image upside down | `flip=0` in `/tmp/spoutsyphon.conf`; default 1 is what OBS needs |
| No `newSharedTexture` line at all | Spout Stream is off in VRChat, or the camera is not in Stream mode |
| `newSharedTexture … -> NIL` | Metal refused the shared descriptor (should not happen; it is logged with size and format) |
| Everything stops after a launcher update | re-run `scripts/launch-with-bridge.sh`; if the launcher becomes hardened/signed, `DYLD_INSERT_LIBRARIES` is refused and the fallback in `docs/ARCHITECTURE.md` (rebuild `libwmtr_host.dylib` with an export call) is needed |
| Source frozen | VRChat closed the sender; the bridge keeps the last frame by design |
