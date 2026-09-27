"""Execute fixed outer-helper observation/refusal boundaries without mounting."""
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'payload/vm-observer/outer_install.sh'

class OuterViewControls(unittest.TestCase):
    def run_shell(self, body):
        return subprocess.run(['sh', '-c', '. ' + shlex.quote(str(HELPER)) + '\n' + body],
                              capture_output=True, text=True, timeout=8)

    def test_real_current_proc_view(self):
        result = self.run_shell('observer_proc_current /proc')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_real_current_sysfs_device_view(self):
        result = self.run_shell('observer_sys_current /sys')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_copied_sysfs_shape_cannot_establish_current_device_identity(self):
        with tempfile.TemporaryDirectory(prefix='wootc-foreign-sys-') as tmp:
            root = Path(tmp)
            for relative in ('dev/block', 'devices', 'class/block', 'devices/system/cpu'):
                (root / relative).mkdir(parents=True, exist_ok=True)
            (root / 'devices/system/cpu/online').write_bytes(Path('/sys/devices/system/cpu/online').read_bytes())
            result = self.run_shell('observer_sys_current ' + shlex.quote(tmp))
            self.assertNotEqual(result.returncode, 0)

    def test_foreign_proc_directory_refuses(self):
        with tempfile.TemporaryDirectory(prefix='wootc-foreign-proc-') as tmp:
            result = self.run_shell('observer_proc_current ' + shlex.quote(tmp))
            self.assertNotEqual(result.returncode, 0)

    def test_foreign_sources_refuse_before_mount_or_namespace_creation(self):
        result = self.run_shell('''
OBS_DEPLOYMENT=/foreign
mount() { echo UNEXPECTED-MOUNT; return 0; }
mkdir() { echo UNEXPECTED-MKDIR; return 0; }
observer_bind_view sys /foreign /foreign/sys
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_unknown_inventory_preserves_cleanup_namespace(self):
        result = self.run_shell('''
observer_is_mounted() { return 2; }
umount() { echo UNEXPECTED-UNMOUNT; return 0; }
rmdir() { echo UNEXPECTED-RMDIR; return 0; }
observer_release_view /foreign 1:2 1:3 true
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

if __name__ == '__main__':
    unittest.main()
