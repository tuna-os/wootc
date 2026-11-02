#!/usr/bin/env python3
"""Execute inside the installed Linux guest through QGA, not on the host."""
import datetime as dt
import importlib.util
import json
import pathlib
import platform
import sys

run_id, attempt, sha = sys.argv[1:]
if platform.system() != 'Linux':
    raise ValueError('Current guest is not Linux')
host = pathlib.Path('/run/initramfs/wootc-host')
sys.path.insert(0, '/var/usrlocal/lib/wootc')
spec = importlib.util.spec_from_file_location('native_proof_boot', '/var/usrlocal/lib/wootc/wootc_firstboot_evidence.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
# Reassess current mounts/image/bridge, never copy the Windows UI model.
current = module.collect(host)
live_id = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
if current['bootId'] != live_id or current['kernel'] != platform.release():
    raise ValueError('Installed observation is not the current kernel boot')
with (host / 'wootc/install/installed-linux-boot.json').open(encoding='utf-8-sig') as stream:
    persisted = json.load(stream)
for key in current:
    if key not in ('writtenAt', 'failedUnits') and persisted.get(key) != current[key]:
        raise ValueError('Persisted first boot differs from current measurement: ' + key)
bridge = current['bridge']
summary = 'boundFolders={};matchedUsers={};bitlockerUnlocked={}'.format(
    bridge['boundFolders'], bridge['matchedUsers'], str(bridge['bitlockerUnlocked']).lower())
print(json.dumps(dict(runId=int(run_id), runAttempt=int(attempt), sourceSha=sha,
    observer='linux-qga', uname=platform.system(), capturedAt=dt.datetime.now(dt.timezone.utc).isoformat(),
    bootId=current['bootId'], liveBootId=live_id, kernel=platform.release(),
    sourceImage=current['image'].get('sourceRef') or current['image']['ref'], bridge=summary,
    current=current), separators=(',', ':')))
