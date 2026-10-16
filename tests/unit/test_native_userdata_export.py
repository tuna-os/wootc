"""Execute the actual go-native probe with owned paths and command fixtures."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BOOT = '00000000-0000-0000-0000-000000000001'


class NativeExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bin = self.root/'bin'; self.bin.mkdir()
        home = self.root/'home/alice/Documents'; home.mkdir(parents=True)
        self.seed = home/'wootc-e2e-userdata.txt'
        self.seed.write_bytes(b'exact seed\r\nlast line without newline')
        self.boot = self.root/'boot'; self.boot.write_text(BOOT+'\n')
        self.out = self.root/'export'
        source = (ROOT/'payload/migration/wootc-go-native').read_text()
        match = re.search(r'<<\'PROBE\'\n(.*?)\nPROBE', source, re.S)
        self.assertIsNotNone(match)
        script = match[1].replace('/run/wootc-e2e-native-userdata', str(self.out))
        script = script.replace('/proc/sys/kernel/random/boot_id', str(self.boot))
        script = script.replace('/var/home/*/Documents/', str(self.root/'home')+'/*/Documents/')
        self.script = self.root/'probe'; self.script.write_text(script)
        self.environment = dict(os.environ, PATH=str(self.bin)+':/usr/bin:/bin',
                                EXPORT_TEST_BOOT=str(self.boot), EXPORT_TEST_COUNT=str(self.root/'reads'),
                                EXPORT_TEST_ROW='/dev/vdb3[/home] 252:19 /var/home',
                                EXPORT_TEST_FINDMNT_EXIT='0', EXPORT_TEST_MODE='normal')
        self.command('findmnt', 'printf "%s\\n" "$EXPORT_TEST_ROW"\nexit "$EXPORT_TEST_FINDMNT_EXIT"\n')
        self.command('cat', '''last=${!#}
if [[ "$last" == "$EXPORT_TEST_BOOT" ]]; then
    count=0
    [[ ! -f "$EXPORT_TEST_COUNT" ]] || read -r count < "$EXPORT_TEST_COUNT"
    printf '%s\\n' "$((count+1))" > "$EXPORT_TEST_COUNT"
    if [[ "$EXPORT_TEST_MODE" == boot-failure ]]; then /bin/cat "$last"; exit 1; fi
    if [[ "$EXPORT_TEST_MODE" == boot-change && "$count" != 0 ]]; then
        printf '00000000-0000-0000-0000-000000000002\\n'; exit 0
    fi
elif [[ "$EXPORT_TEST_MODE" == partial ]]; then
    /usr/bin/head -c 8 -- "$last"; exit 1
elif [[ "$EXPORT_TEST_MODE" == file-change ]]; then
    /bin/cat -- "$last"; printf 'changed' >> "$last"; exit 0
fi
exec /bin/cat "$@"
''')
        # A noexec fixture directory must fail the positive setup, not make refusals pass.
        self.command('execution-control', 'printf executable\n')
        check = subprocess.run([str(self.bin/'execution-control')], capture_output=True)
        self.assertEqual((check.returncode, check.stdout), (0, b'executable'))

    def command(self, name, body):
        path = self.bin/name; path.write_text('#!/bin/bash\n'+body); path.chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def run_probe(self):
        return subprocess.run(['/bin/bash', str(self.script)], env=self.environment,
                              capture_output=True, timeout=5)

    def refused(self):
        self.out.write_bytes(b'stale prior success')
        result = self.run_probe()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.out.exists())
        self.assertEqual(list(self.root.glob('export.*')), [])

    def test_exact_successful_export_and_bytes(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ('EXPORT_SCHEMA=1\nEXPORT_BOOT_ID='+BOOT+'\nSRC=/dev/vdb3[/home]\n'
                    'DATA_MAJ_MIN=252:19\nDATA_MOUNT=/var/home\n').encode()+self.seed.read_bytes()
        self.assertEqual(self.out.read_bytes(), expected)
        self.assertEqual(self.out.stat().st_mode & 0o777, 0o644)

    def test_findmnt_failure_with_plausible_stdout_removes_stale_export(self):
        self.environment['EXPORT_TEST_FINDMNT_EXIT'] = '1'
        self.refused()

    def test_boot_change_refuses_after_seed_read(self):
        self.environment['EXPORT_TEST_MODE'] = 'boot-change'
        self.refused()

    def test_failed_boot_read_with_valid_stdout_refuses(self):
        self.environment['EXPORT_TEST_MODE'] = 'boot-failure'
        self.refused()

    def test_partial_seed_read_never_publishes(self):
        self.environment['EXPORT_TEST_MODE'] = 'partial'
        self.refused()

    def test_seed_change_during_read_refuses(self):
        self.environment['EXPORT_TEST_MODE'] = 'file-change'
        self.refused()

    def test_missing_seed_removes_stale_export(self):
        self.seed.unlink()
        self.refused()

    def test_failed_stat_with_plausible_metadata_refuses(self):
        self.command('stat', 'printf "1:2:33:fixed:fixed\\n"\nexit 1\n')
        self.refused()

    def test_failed_chmod_removes_private_partial_file(self):
        self.command('chmod', 'exit 1\n')
        self.refused()

    def test_failed_rename_never_publishes_success(self):
        self.command('mv', 'exit 1\n')
        self.refused()

    def test_ambiguous_seed_is_not_first_file_success(self):
        other = self.root/'home/bob/Documents'; other.mkdir(parents=True)
        (other/self.seed.name).write_bytes(b'other seed')
        self.refused()

    def test_malformed_mount_or_boot_observations_refuse(self):
        for row in ('/dev/vdb3 252:19 /var/home\n/dev/vdc3 252:35 /var/home',
                    '/dev/vdb3 252:19 relative', '/dev/vdb3 unknown /var/home',
                    '/dev/vdb3 252:19 /var/home extra', '/dev/vdb3 252:19 /var/home\\x20space'):
            with self.subTest(row=row):
                self.environment['EXPORT_TEST_ROW'] = row
                self.refused()
        self.boot.write_text('plausible-but-not-uuid\n')
        self.refused()


if __name__ == '__main__':
    unittest.main()
