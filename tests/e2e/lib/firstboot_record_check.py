"""Compare the persisted Phase-2 first-boot record with this running boot.

run-e2e.sh runs this file in the guest through QGA (`python3 -c`). The
product collector is re-run now, and every identity field must agree with
what the first boot recorded. writtenAt is the measurement time; failedUnits
is reported, not identity, but no wootc unit may have failed at either
reading.

One field may change legitimately between the two readings: converting a
bridged folder to native storage (wootc-convert-dir, stage 4) retires its
bind mount and leaves ~/.config/wootc/converted-<folder>. The migration
suite converts ~/Music before this check (probe 44889931801), so the bridge
is compared with the converted folders taken out of the first-boot record,
never ignored.
"""
import importlib.util
import json
import pathlib
import pwd
import sys

HOST = pathlib.Path("/run/initramfs/wootc-host")
HELPER = pathlib.Path("/var/usrlocal/lib/wootc/wootc_firstboot_evidence.py")


def converted_marker(binding):
    home = pathlib.Path(pwd.getpwnam(binding["user"]).pw_dir)
    folder = pathlib.PurePosixPath(binding["target"]).name
    return (home / ".config/wootc" / ("converted-" + folder)).is_file()


def bridge_after_conversions(bridge, converted=converted_marker):
    """The first-boot bridge minus bindings converted since that boot."""
    kept = [binding for binding in bridge.get("bindings", []) if not converted(binding)]
    expected = dict(bridge)
    expected["bindings"] = kept
    expected["boundFolders"] = len(kept)
    expected["matchedUsers"] = len({binding["user"] for binding in kept})
    return expected


def compare(persisted, current, converted=converted_marker):
    for key in current:
        if key in ("writtenAt", "failedUnits"):
            continue
        wanted = persisted.get(key)
        if key == "bridge" and isinstance(wanted, dict):
            wanted = bridge_after_conversions(wanted, converted)
        if wanted != current[key]:
            raise ValueError("persisted firstboot record differs from current boot: " + key)
    for record in (persisted, current):
        failed = [unit for unit in record.get("failedUnits", []) if unit.startswith("wootc-")]
        if failed:
            raise ValueError("wootc units failed: " + ", ".join(failed))


def main():
    sys.path.insert(0, str(HELPER.parent))
    spec = importlib.util.spec_from_file_location("firstboot_observer", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    current = module.collect(HOST)
    path = HOST / "wootc/install/installed-linux-boot.json"
    with path.open(encoding="utf-8-sig") as stream:
        raw = stream.read(65537)
    if len(raw) > 65536:
        raise ValueError("oversized firstboot record")
    persisted = json.loads(raw)
    compare(persisted, current)
    state = json.loads((HOST / "wootc/state.json").read_text(encoding="utf-8-sig"))
    if state.get("state") != "healthy":
        raise ValueError("firstboot state is not healthy")
    if not (HOST / "wootc/install/installed-linux-boot.complete").is_file():
        raise ValueError("firstboot publication did not complete")
    print(json.dumps({"persisted": persisted, "current": current}, indent=2))


if __name__ == "__main__":
    main()
