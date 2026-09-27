#!/usr/bin/env python3
"""Run the actual native proof acceptance consumer with controlled QGA results."""
import os
import base64
import json
import importlib.util
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BOOT = '12345678-1234-1234-1234-123456789abc'
def encode(value):
    return base64.b64encode(json.dumps(value).encode()).decode()


def mount(target, source='/dev/sdb3', major='8:19', fstype='ext4', options='rw'):
    return dict(target=target, source=source, **{'maj:min':major}, fstype=fstype, options=options)


def node(name, major, kind, children=None):
    row=dict(name=name, kname=name, type=kind, **{'maj:min':major})
    if children:
        row['children']=children
    return row


BLOCKS={'blockdevices':[node('/dev/sdb','8:16','disk',[node('/dev/sdb3','8:19','part')])]}
MOUNTS={'filesystems':[mount('/'),mount('/var')]}
LOOPS={'loopdevices':[]}


def native(blocks=BLOCKS, mounts=MOUNTS, loops=LOOPS):
    return (f'SCHEMA=1\nUNAME=Linux\nCMDLINE=root=UUID=native ro\nTARGET=/dev/sdb\nBOOT_ID={BOOT}\n'
            +f'BLOCKS={encode(blocks)}\nMOUNTS={encode(mounts)}\nLOOPS={encode(loops)}\n')


def userdata(source='/dev/sdb3', major='8:19', target='/var', seed='wootc-e2e-userdata current-run\n', proof=None):
    graph=''.join(line+'\n' for line in (proof or native()).splitlines() if line.startswith(('BLOCKS=','MOUNTS=','LOOPS=')))
    return (f'SCHEMA=1\nUNAME=Linux\nBOOT_ID={BOOT}\n'+graph+f'EXPORT_SCHEMA=1\nEXPORT_BOOT_ID={BOOT}\n'
            +f'SRC={source}\nDATA_MAJ_MIN={major}\nDATA_MOUNT={target}\n'+seed)


PROOF=native()


class Phase3Tests(unittest.TestCase):
    def consumer(self, module=None, **overrides):
        source = (module or ROOT/'tests/e2e/run-e2e.sh').read_text()
        start = source.index('    # A failed guest command cannot establish facts even with plausible stdout.')
        body = source[start:source.index('\nelse\n    step "Rebooting Phase 2 Linux', start)]
        prefix = '''set -Eeuo pipefail
P3_TARGET=/dev/sdb; RUN_ID=current-run
step() { :; }; fail() { echo "FAIL $*"; }
infra_fail() { echo "INFRA $*"; }
product_fail() { echo "PRODUCT-FAIL $*"; }
product_pass() { echo "PRODUCT-PASS $*"; }
qga_call() {
 if [[ "$*" == */etc/wootc/native-target* ]]; then printf '%s' "$PROOF"; return "$PROOF_RC"; fi
 printf '%s' "$DATA"; return "$DATA_RC"
}
'''
        env = dict(PROOF=PROOF, PROOF_RC='0', DATA=userdata(),
                   DATA_RC='0', SCRIPT_DIR=str(ROOT/'tests/e2e'))
        with tempfile.TemporaryDirectory() as tmp:
            return subprocess.run(['bash', '-c', prefix+body], text=True, capture_output=True,
                                  timeout=4, env={**os.environ, **env,'ARTIFACT_DIR':tmp, **overrides})

    def test_successful_native_and_current_data_pass(self):
        r = self.consumer()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('PRODUCT-PASS native-boot', r.stdout)
        self.assertIn('PRODUCT-PASS native-user-data', r.stdout)

    def test_failed_native_command_with_plausible_stdout_refuses(self):
        for code in ['7', '42', '124']:
            r = self.consumer(PROOF_RC=code)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('INFRA', r.stdout)
            self.assertNotIn('PRODUCT-PASS', r.stdout)

    def test_failed_data_command_cannot_assert_persistence(self):
        r = self.consumer(DATA_RC='7')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('PRODUCT-PASS native-boot', r.stdout)
        self.assertIn('INFRA', r.stdout)
        self.assertNotIn('PRODUCT-PASS native-user-data', r.stdout)

    def test_invalid_protocol_is_infrastructure_unknown(self):
        for proof in ['', 'noise\n'+PROOF, PROOF+'UNAME=Linux\n', PROOF.replace('BOOT_ID='+BOOT, 'BOOT_ID=no'),
                      PROOF.replace('CMDLINE=root=UUID=native ro', 'CMDLINE='), PROOF.replace('SCHEMA=1', 'SCHEMA=2')]:
            r = self.consumer(PROOF=proof)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('INFRA', r.stdout)
            self.assertNotIn('PRODUCT-PASS', r.stdout)

    def test_removed_userdata_status_guard_counterexample(self):
        source = (ROOT/'tests/e2e/run-e2e.sh').read_text()
        source = source.replace('if ! P3_USERDATA=$(', 'if P3_USERDATA=$(', 1)
        source = source.replace('infra_fail "Phase 3 native user-data observation command failed"\n        exit 1', ':', 1)
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'mutant.sh'; p.write_text(source)
            r = self.consumer(p, DATA_RC='7')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('PRODUCT-PASS native-user-data', r.stdout)

    def test_successful_wrong_native_facts_are_product_failures(self):
        for proof in [PROOF.replace('UNAME=Linux', 'UNAME=Windows_NT'),
                      PROOF.replace('TARGET=/dev/sdb', 'TARGET=/dev/sdc'),
                      PROOF.replace('root=UUID=native ro', 'loop=/wootc/disks/root.disk ro'),
                      PROOF.replace('root=UUID=native ro', 'ro wootc.rootdisk=/wootc/disks/root.disk')]:
            r = self.consumer(PROOF=proof)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('PRODUCT-FAIL', r.stdout)
            self.assertNotIn('PRODUCT-PASS', r.stdout)

    def test_current_run_seed_requires_exact_literal_line(self):
        for data in ['SRC=/dev/sdb3\nwootc-e2e-userdata old-run\n',
                     'SRC=/dev/sdb3\nwootc-e2e-userdata current-run-extra\n',
                     'SRC=/dev/sdb3\nprefix wootc-e2e-userdata current-run\n']:
            r = self.consumer(DATA=userdata(seed=data.split('\n',1)[1]))
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('PRODUCT-PASS native-user-data', r.stdout)

    def test_removed_native_status_guard_counterexample(self):
        source = (ROOT/'tests/e2e/run-e2e.sh').read_text()
        source = source.replace('if ! P3_NATIVE_PROOF=$(', 'if P3_NATIVE_PROOF=$(', 1)
        source = source.replace('infra_fail "Phase 3 native boot observation command failed"\n        exit 1', ':', 1)
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'mutant.sh'; p.write_text(source)
            r = self.consumer(p, PROOF_RC='7')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('PRODUCT-PASS native-boot', r.stdout)

    def test_userdata_requires_same_successful_linux_boot(self):
        for data in [f'SCHEMA=1\nUNAME=Linux\nBOOT_ID=abcdefab-1234-1234-1234-123456789abc\nSRC=/dev/sdb3\nwootc-e2e-userdata current-run\n',
                     f'SCHEMA=1\nUNAME=Windows_NT\nBOOT_ID={BOOT}\nSRC=/dev/sdb3\nwootc-e2e-userdata current-run\n',
                     'SRC=/dev/sdb3\nwootc-e2e-userdata current-run\n']:
            r = self.consumer(DATA=data)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('INFRA', r.stdout)
            self.assertNotIn('PRODUCT-PASS native-user-data', r.stdout)

    def test_original_windows_seed_crlf_is_valid_without_content_trimming(self):
        data=userdata(seed='wootc-e2e-userdata current-run\r\n')
        self.assertEqual(self.consumer(DATA=data).returncode, 0)
        self.assertNotEqual(self.consumer(DATA=data.replace('current-run\r', 'current-run \r')).returncode, 0)

    def test_actual_guest_boot_query_stops_on_each_failed_read(self):
        source=(ROOT/'tests/e2e/run-e2e.sh').read_text().split('if ! P3_NATIVE_PROOF=$(',1)[1]
        query=re.search(r"qga_call exec /bin/sh -c \\\n        '([\s\S]+?)' \\\n",source).group(1)
        prefix='''uname() { printf Linux; [ "$FAIL_READ" != uname ]; }
cat() {
 case "$1" in
 /proc/cmdline) printf 'root=UUID=native ro'; [ "$FAIL_READ" != cmdline ] ;;
 /etc/wootc/native-target) printf /dev/sdb; [ "$FAIL_READ" != target ] ;;
 /proc/sys/kernel/random/boot_id) printf '%s' "$BOOT"; [ "$FAIL_READ" != boot ] ;;
 *) return 1 ;;
 esac
}
'''
        prefix+='''lsblk() { printf '%s' "$BLOCK_JSON"; [ "$FAIL_READ" != blocks ]; }
findmnt() { printf '%s' "$MOUNT_JSON"; [ "$FAIL_READ" != mounts ]; }
losetup() { printf '%s' "$LOOP_JSON"; [ "$FAIL_READ" != loops ]; }
'''
        for failed in ['none','uname','cmdline','target','boot','blocks','mounts','loops']:
            r=subprocess.run(['/bin/sh','-c',prefix+query],capture_output=True,text=True,
                             env={**os.environ,'FAIL_READ':failed,'BOOT':BOOT,'BLOCK_JSON':json.dumps(BLOCKS),
                                  'MOUNT_JSON':json.dumps(MOUNTS),'LOOP_JSON':json.dumps(LOOPS)},timeout=2)
            if failed=='none':
                self.assertEqual(r.returncode,0,r.stderr)
                self.assertEqual(r.stdout,PROOF)
            else:
                self.assertNotEqual(r.returncode,0)
                self.assertEqual(r.stdout,'')

    def test_wrong_physical_root_cannot_publish_native_boot(self):
        graph={'blockdevices':BLOCKS['blockdevices']+[node('/dev/sda','8:0','disk',[node('/dev/sda3','8:3','part')])]}
        mounts={'filesystems':[mount('/', '/dev/sda3','8:3'),mount('/var')]}
        r=self.consumer(PROOF=native(graph,mounts))
        self.assertNotEqual(r.returncode,0)
        self.assertIn('PRODUCT-FAIL',r.stdout)
        self.assertNotIn('PRODUCT-PASS',r.stdout)

    def test_measured_loop_root_and_loop_data_refuse(self):
        graph={'blockdevices':BLOCKS['blockdevices']+[node('/dev/loop0','7:0','loop')]}
        for path in ['/','/var']:
            mounts={'filesystems':[mount('/'),mount('/var')]}
            mounts['filesystems'][0 if path=='/' else 1]=mount(path,'/dev/loop0','7:0','btrfs')
            r=self.consumer(PROOF=native(graph,mounts),DATA=userdata('/dev/loop0','7:0',proof=native(graph,mounts)))
            self.assertNotEqual(r.returncode,0)
            self.assertIn('PRODUCT-FAIL',r.stdout)
            self.assertNotIn('PRODUCT-PASS native-user-data',r.stdout)
            if path=='/':
                self.assertNotIn('PRODUCT-PASS native-boot',r.stdout)

    def test_mount_and_block_source_major_disagreement_is_unknown(self):
        mounts={'filesystems':[mount('/',major='8:3'),mount('/var')]}
        r=self.consumer(PROOF=native(mounts=mounts))
        self.assertNotEqual(r.returncode,0)
        self.assertIn('INFRA',r.stdout)

    def test_exported_mount_and_boot_must_match_current_observations(self):
        for data in [userdata(major='8:3'),userdata(target='/unobserved'),userdata(source='/dev/sda3'),
                     userdata().replace('EXPORT_BOOT_ID='+BOOT,'EXPORT_BOOT_ID=abcdefab-1234-1234-1234-123456789abc')]:
            r=self.consumer(DATA=data)
            self.assertNotEqual(r.returncode,0)
            self.assertIn('INFRA',r.stdout)
            self.assertNotIn('PRODUCT-PASS native-user-data',r.stdout)

    def test_btrfs_subvolume_and_dm_native_ancestry(self):
        mounts={'filesystems':[mount('/',source='/dev/sdb3[/root]',fstype='btrfs'),
                              mount('/var',source='/dev/sdb3[/var]',fstype='btrfs')]}
        r=self.consumer(PROOF=native(mounts=mounts),DATA=userdata(source='/dev/sdb3[/var]',proof=native(mounts=mounts)))
        self.assertEqual(r.returncode,0,r.stderr)
        crypt=node('/dev/mapper/native','253:0','crypt');crypt['kname']='/dev/dm-0'
        graph={'blockdevices':[node('/dev/sdb','8:16','disk',[node('/dev/sdb3','8:19','part',[crypt])])]}
        mounts={'filesystems':[mount('/','/dev/mapper/native','253:0'),mount('/var','/dev/mapper/native','253:0')]}
        r=self.consumer(PROOF=native(graph,mounts),DATA=userdata('/dev/mapper/native','253:0',proof=native(graph,mounts)))
        self.assertEqual(r.returncode,0,r.stderr)

    def test_dm_with_multiple_physical_disks_refuses(self):
        crypt=node('/dev/dm-0','253:0','crypt')
        graph={'blockdevices':[node('/dev/sdb','8:16','disk',[node('/dev/sdb3','8:19','part',[crypt])]),
                               node('/dev/sda','8:0','disk',[node('/dev/sda3','8:3','part',[crypt])])]}
        mounts={'filesystems':[mount('/','/dev/dm-0','253:0'),mount('/var','/dev/dm-0','253:0')]}
        r=self.consumer(PROOF=native(graph,mounts))
        self.assertNotEqual(r.returncode,0)
        self.assertIn('PRODUCT-FAIL',r.stdout)

    def projection(self, backing='/sysroot/native.cfs', options='ro,lowerdir=/run/cfs::/sysroot/objects'):
        graph={'blockdevices':BLOCKS['blockdevices']+[node('/dev/loop0','7:0','loop'),
               node('/dev/sda','8:0','disk',[node('/dev/sda3','8:3','part')])]}
        mounts={'filesystems':[mount('/','composefs','0:51','overlay',options),mount('/var'),mount('/sysroot'),
                               mount('/run/cfs','/dev/loop0','7:0','erofs','ro'),mount('/mnt/windows','/dev/sda3','8:3')]}
        loops={'loopdevices':[{'name':'/dev/loop0','maj:min':'7:0','back-file':backing}]}
        return native(graph,mounts,loops)

    def test_composefs_requires_actual_projection_backing_on_target(self):
        for options in ['ro,lowerdir=/run/cfs::/sysroot/objects',
                        'ro,lowerdir+=/run/cfs,datadir+=/sysroot/objects']:
            r=self.consumer(PROOF=self.projection(options=options))
            self.assertEqual(r.returncode,0,r.stderr)
        r=self.consumer(PROOF=self.projection(backing='/mnt/windows/native.cfs'))
        self.assertNotEqual(r.returncode,0)
        self.assertIn('PRODUCT-FAIL',r.stdout)
        self.assertNotIn('PRODUCT-PASS',r.stdout)

    def test_arbitrary_sysroot_or_missing_projection_cannot_establish_root(self):
        for options in ['ro','ro,lowerdir=/missing/path','ro,lowerdir=/mnt/windows/foreign']:
            r=self.consumer(PROOF=self.projection(options=options))
            self.assertNotEqual(r.returncode,0)
            self.assertNotIn('PRODUCT-PASS',r.stdout)

    def test_deleted_missing_or_unbound_projected_image_is_unknown(self):
        for backing in ['/sysroot/native.cfs (deleted)','relative.cfs','/unobserved/native.cfs']:
            r=self.consumer(PROOF=self.projection(backing=backing))
            self.assertNotEqual(r.returncode,0)
            self.assertIn('INFRA',r.stdout)

    def test_malformed_ambiguous_or_duplicate_json_graph_refuses(self):
        for encoded in ['not-base64',encode({'blockdevices':[]}),
                        base64.b64encode(b'{"blockdevices":[],"blockdevices":[]}').decode()]:
            r=self.consumer(PROOF=PROOF.replace('BLOCKS='+encode(BLOCKS),'BLOCKS='+encoded))
            self.assertNotEqual(r.returncode,0)
            self.assertIn('INFRA',r.stdout)

    def producer(self):
        path=ROOT/'tests/unit/test_native_userdata_export.py'
        spec=importlib.util.spec_from_file_location('native_export_controls',path)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        provider=module.NativeExportTests();provider.setUp()
        self.addCleanup(provider.tearDown)
        provider.boot.write_text(BOOT+'\n')
        provider.environment['EXPORT_TEST_ROW']='/dev/sdb3 8:19 /var'
        provider.seed.write_bytes(b'wootc-e2e-userdata current-run\r\n')
        return provider

    def test_actual_producer_bytes_feed_current_observer(self):
        provider=self.producer()
        for payload in [b'wootc-e2e-userdata current-run\r\n',b'wootc-e2e-userdata current-run']:
            provider.seed.write_bytes(payload)
            produced=provider.run_probe()
            self.assertEqual(produced.returncode,0,produced.stderr)
            prefix=userdata().split('EXPORT_SCHEMA=',1)[0]
            r=self.consumer(DATA=prefix+provider.out.read_bytes().decode())
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('PRODUCT-PASS native-user-data',r.stdout)

    def test_successful_but_stale_actual_export_cannot_combine_with_current_boot(self):
        provider=self.producer();provider.boot.write_text('abcdefab-1234-1234-1234-123456789abc\n')
        self.assertEqual(provider.run_probe().returncode,0)
        prefix=userdata().split('EXPORT_SCHEMA=',1)[0]
        r=self.consumer(DATA=prefix+provider.out.read_bytes().decode())
        self.assertNotEqual(r.returncode,0)
        self.assertIn('INFRA',r.stdout)
        self.assertNotIn('PRODUCT-PASS native-user-data',r.stdout)

    def test_actual_partial_producer_never_supplies_usable_receipt(self):
        provider=self.producer();provider.out.write_bytes(b'stale prior receipt')
        provider.environment['EXPORT_TEST_MODE']='partial'
        self.assertNotEqual(provider.run_probe().returncode,0)
        self.assertFalse(provider.out.exists())
        r=self.consumer(DATA=userdata().split('EXPORT_SCHEMA=',1)[0])
        self.assertNotEqual(r.returncode,0)
        self.assertNotIn('PRODUCT-PASS native-user-data',r.stdout)

    def test_failed_host_evidence_write_prevents_native_boot_assertion(self):
        r=self.consumer(ARTIFACT_DIR='/dev/null')
        self.assertNotEqual(r.returncode,0)
        self.assertIn('INFRA',r.stdout)
        self.assertNotIn('PRODUCT-PASS',r.stdout)

    def test_actual_native_boot_boundary_clears_previous_phase_in_caller(self):
        source=(ROOT/'tests/e2e/run-e2e.sh').read_text()
        anchor='    wootc_phase_boundary\n    step "Rebooting Phase 2 into the one-shot Phase 3 native install..."'
        start=source.index(anchor)
        end=source.index('    # A failed guest command',start)
        prefix=f'''set -Eeuo pipefail
source '{ROOT/'tests/e2e/phase-ledger.sh'}'
WOOTC_CURRENT_PHASE_ID=firstboot-evidence; WOOTC_PHASE_CARRY=torn
step() {{ :; }}
owned_runtime() {{ [ -z "$WOOTC_CURRENT_PHASE_ID" ] && [ -z "$WOOTC_PHASE_CARRY" ]; echo RESET; }}
DOCKER=owned_runtime; CONTAINER_NAME=owned
qga_probe() {{ return 1; }}
qga_wait() {{ echo LIVENESS; }}
'''
        r=subprocess.run(['bash','-c',prefix+source[start:end]+'\necho "PHASE=$WOOTC_CURRENT_PHASE_ID"'],
                         capture_output=True,text=True,timeout=2)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('RESET',r.stdout)
        self.assertTrue(r.stdout.rstrip().endswith('PHASE='))


if __name__ == '__main__':
    unittest.main()
