"""Install only producer-staged SHA-bound public packages in the owned QA guest."""
import hashlib
import json
from pathlib import Path
import subprocess


def upgrade(folder=Path('/var/lib/wootc/qa-upgrade'), run=subprocess.run):
    folder = Path(folder)
    record = json.loads((folder/'packages.json').read_text())
    packages = record['newPackages']
    if not packages:
        raise ValueError('no staged classic upgrade packages')
    paths = []
    for name, expected in packages.items():
        if Path(name).name != name or name in ('.', '..'):
            raise ValueError('unsafe package filename')
        path = folder/name
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('staged package hash differs')
        paths.append(str(path))
    if record['manager'] == 'dpkg':
        command = ['/usr/bin/dpkg', '--install']+paths
    elif record['manager'] == 'rpm':
        command = ['/usr/bin/dnf', '--assumeyes', '--disablerepo=*', 'install']+paths
    else:
        raise ValueError('unsupported package manager')
    # Prevent the path unit from observing a half-updated package set.
    run(['/usr/bin/systemctl', 'stop', 'wootc-esp-sync.path'], check=True, timeout=30)
    run(command, check=True, timeout=600)
    run(['/usr/bin/python3', '/var/usrlocal/lib/wootc-qa/stage-classic-source.py'], check=True, timeout=120)
    run(['/usr/bin/systemctl', 'reset-failed', 'wootc-esp-sync.service'], check=True, timeout=30)
    run(['/usr/bin/systemctl', 'start', 'wootc-esp-sync.path'], check=True, timeout=30)


if __name__ == '__main__':
    upgrade()
