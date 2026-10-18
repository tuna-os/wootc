"""Create an exclusive qcow2 overlay of a pinned, already installed QA baseline."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def provision(root, baseline, expected, run=subprocess.run):
    # This owns only a new overlay. It does not install an OS into retained fixtures.
    root, baseline = Path(root), Path(baseline)
    if root.is_symlink() or baseline.is_symlink():
        raise ValueError('scratch root or baseline symlink')
    root = root.resolve(strict=True)
    baseline = baseline.resolve(strict=True)
    stat = root.stat()
    if stat.st_uid != os.getuid() or stat.st_mode & 0o077:
        raise ValueError('scratch parent must be caller-owned and private')
    if digest(baseline) != expected:
        raise ValueError('baseline hash differs')
    identity = uuid.uuid4()
    folder = root/identity.hex
    folder.mkdir(mode=0o700)  # Never reuse or delete any previous scratch identity.
    record = {'schemaVersion': 1, 'scratchId': identity.hex, 'vmUuid': str(identity),
              'baseline': str(baseline), 'baselineSha256': expected,
              'overlay': str(folder/'disk.qcow2'), 'state': 'preparing',
              'firmwareAcceptance': False, 'classicOsBootAcceptance': False}
    manifest = folder/'scratch.json'
    manifest.write_text(json.dumps(record, indent=2)+'\n')
    manifest.chmod(0o600)
    run(['qemu-img', 'check', '-f', 'qcow2', str(baseline)], check=True, timeout=120)
    run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(baseline), record['overlay']],
        check=True, timeout=30)
    if digest(baseline) != expected:
        raise ValueError('baseline changed while provisioning')
    record['state'] = 'ready-for-baseline-boot'
    manifest.write_text(json.dumps(record, indent=2)+'\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('scratch_parent', type=Path)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('baseline_sha256')
    args = parser.parse_args()
    try:
        print(json.dumps(provision(args.scratch_parent, args.baseline, args.baseline_sha256), sort_keys=True))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, 'scratch provision refused: '+str(error)+'\n')
