#!/usr/bin/env python3
"""Add (or refresh) a Syphon source for the Spout bridge in an OBS scene collection.

OBS must not be running while this edits its scene collection, otherwise OBS overwrites the file when
it saves on exit. The script backs the collection up next to itself first.

The source is matched to the Syphon server **by name** (OBS's mac-syphon falls back to the first server
with that name when the stored UUID is gone), so it reconnects after a VM restart even though the
server's UUID is new. `bounds` is set to scale-inner so the camera fills the canvas at 720p or 1080p.
"""
import json
import os
import shutil
import sys
import time
import uuid
import glob

SERVER_NAME = os.environ.get("SPOUTSYPHON_NAME", "VRChat Spout Camera")
# OBS's mac-syphon only accepts an announce when BOTH the app name and the server name match its stored
# settings (or when the stored UUID matches), and Syphon takes the app name from the server process's
# bundle: here that is the launcher's name. scripts/pin-obs-source.sh fills both in from the live directory.
SERVER_APP = os.environ.get("SPOUTSYPHON_APP", "")
SERVER_UUID = os.environ.get("SPOUTSYPHON_UUID", "")
SOURCE_NAME = os.environ.get("OBS_SOURCE_NAME", "VRChat Spout Camera")
SCENE_DIR = os.path.expanduser("~/Library/Application Support/obs-studio/basic/scenes")


def main() -> int:
    files = sorted(glob.glob(os.path.join(SCENE_DIR, "*.json")))
    if not files:
        print(f"no scene collection in {SCENE_DIR}", file=sys.stderr)
        return 1
    target = files[0]
    with open(target) as f:
        coll = json.load(f)

    backup = f"{target}.bak-spoutbridge-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(target, backup)
    print(f"backup: {backup}")

    scene = next((s for s in coll["sources"] if s.get("id") == "scene"), None)
    if scene is None:
        print("no scene in the collection", file=sys.stderr)
        return 1

    src_uuid = None
    for s in coll["sources"]:
        if s.get("id") == "syphon-input" and s.get("name") == SOURCE_NAME:
            src_uuid = s["uuid"]
            s["settings"].update({"name": SERVER_NAME, "uuid": SERVER_UUID, "app_name": SERVER_APP})
            print(f"updated existing source {SOURCE_NAME} ({src_uuid})")
            break
    if src_uuid is None:
        src_uuid = str(uuid.uuid4())
        coll["sources"].append(
            {
                "prev_ver": 537001986,
                "name": SOURCE_NAME,
                "uuid": src_uuid,
                "id": "syphon-input",
                "versioned_id": "syphon-input",
                "settings": {"name": SERVER_NAME, "uuid": SERVER_UUID, "app_name": SERVER_APP},
                "mixers": 0,
                "sync": 0,
                "flags": 0,
                "volume": 1.0,
                "balance": 0.5,
                "enabled": True,
                "muted": False,
                "push-to-mute": False,
                "push-to-mute-delay": 0,
                "push-to-talk": False,
                "push-to-talk-delay": 0,
                "hotkeys": {},
                "deinterlace_mode": 0,
                "deinterlace_field_order": 0,
                "monitoring_type": 0,
                "private_settings": {},
            }
        )
        print(f"added source {SOURCE_NAME} -> syphon server '{SERVER_NAME}' ({src_uuid})")

    items = scene.setdefault("settings", {}).setdefault("items", [])
    if any(it.get("source_uuid") == src_uuid for it in items):
        print("scene already contains the source")
    else:
        next_id = max([it.get("id", 0) for it in items] + [scene["settings"].get("id_counter", 0)]) + 1
        items.append(
            {
                "name": SOURCE_NAME,
                "source_uuid": src_uuid,
                "visible": True,
                "locked": False,
                "rot": 0.0,
                "align": 5,
                "blend_type": "normal",
                "blend_method": "default",
                "show": True,
                "scale": {"x": 1.0, "y": 1.0},
                "pos": {"x": 0.0, "y": 0.0},
                "bounds_type": 2,          # OBS_BOUNDS_SCALE_INNER
                "bounds_align": 0,
                "bounds": {"x": 1920.0, "y": 1080.0},
                "bounds_crop": {"left": 0, "right": 0, "top": 0, "bottom": 0},
                "crop_left": 0,
                "crop_right": 0,
                "crop_top": 0,
                "crop_bottom": 0,
                "id": next_id,
                "group_item_backup": False,
                "private_settings": {},
            }
        )
        scene["settings"]["id_counter"] = next_id
        print(f"added scene item (id {next_id}, scale-inner to 1920x1080)")

    with open(target, "w") as f:
        json.dump(coll, f, indent=4)
    print(f"wrote {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
