"""Apply the complete offline QA policy, then stage the freshly installed source."""
from pathlib import Path
import runpy

consumer = runpy.run_path(str(Path(__file__).with_name('package-consumer.py')))


def upgrade(folder=Path('/var/lib/wootc/qa-upgrade'), run=None):
    execute = consumer['execute'] if run is None else run
    # Preflight verifies ownership, inventory and every frozen archive before this stop.
    consumer['consume'](folder, 'new', execute,
                        before_install=lambda: execute(['/usr/bin/systemctl', 'stop', 'wootc-esp-sync.path'],
                                                       check=True, timeout=30))
    execute(['/usr/bin/python3', '/var/usrlocal/lib/wootc-qa/stage-classic-source.py'], check=True, timeout=120)
    execute(['/usr/bin/systemctl', 'reset-failed', 'wootc-esp-sync.service'], check=True, timeout=30)
    execute(['/usr/bin/systemctl', 'start', 'wootc-esp-sync.path'], check=True, timeout=30)


if __name__ == '__main__':
    upgrade()
