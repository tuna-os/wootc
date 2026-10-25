#!/usr/bin/env python3
"""Run the actual native proof acceptance consumer with controlled QGA results."""
import os
import base64
import json
import importlib.util
import re
from pathlib import Path
import subprocess
import sys
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


def native(blocks=BLOCKS, mounts=MOUNTS, loops=LOOPS, paths=None, btrfs=None, root=''):
    if paths is None:
        paths={}
        for row in mounts['filesystems']:
            if row['target']=='/' and row['fstype']=='overlay':
                for option in row['options'].split(','):
                    key,sep,value=option.partition('=')
                    if sep and key.rstrip('+') in {'lowerdir','datadir','upperdir','workdir'}:
                        paths.update({path:path for path in value.split(':') if path})
        paths.update({row['back-file']:row['back-file'] for row in loops['loopdevices']})
    path_text='\n'.join(path+'\t'+resolved for path,resolved in sorted(paths.items()))
    btrfs_text='\n'.join(fsid+'\t'+valid+'\t'+','.join(members) for fsid,(valid,members) in (btrfs or {}).items())
    extra='PATHS='+base64.b64encode(path_text.encode()).decode()+'\nBTRFS='+base64.b64encode(btrfs_text.encode()).decode()+'\n'
    extra+='ROOT='+base64.b64encode(root.encode()).decode()+'\n'
    return (f'SCHEMA=1\nUNAME=Linux\nCMDLINE=root=UUID=native ro\nTARGET=/dev/sdb\nBOOT_ID={BOOT}\n'
            +f'BLOCKS={encode(blocks)}\nMOUNTS={encode(mounts)}\nLOOPS={encode(loops)}\n'+extra)


def userdata(source='/dev/sdb3', major='8:19', target='/var', seed='wootc-e2e-userdata current-run\n', proof=None):
    graph=''.join(line+'\n' for line in (proof or native()).splitlines() if line.startswith(('BLOCKS=','MOUNTS=','LOOPS=','PATHS=','BTRFS=')))
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
 if [[ "${!#}" == native ]]; then printf '%s' "$PROOF"; return "$PROOF_RC"; fi
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
        query=(ROOT/'tests/e2e/phase3-snapshot.sh').read_text()
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
findmnt() { if [ "$1" = --json ]; then printf '%s' "$MOUNT_JSON"; else printf rw; fi; [ "$FAIL_READ" != mounts ]; }
losetup() { if [ "$1" = --json ]; then printf '%s' "$LOOP_JSON"; fi; [ "$FAIL_READ" != loops ]; }
'''
        for failed in ['none','uname','cmdline','target','boot','blocks','mounts','loops']:
            with tempfile.TemporaryDirectory() as tmp:
                script=query.replace('/sys/fs/btrfs',tmp+'/btrfs')
                r=subprocess.run(['/bin/sh','-c',prefix+script,'phase3-snapshot','native'],capture_output=True,text=True,
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
            mounts['filesystems'][0 if path=='/' else 1]=mount(path,'/dev/loop0','7:0','ext4')
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
        fsid='abcdefab-1234-1234-1234-123456789abc'
        graph=json.loads(json.dumps(BLOCKS));graph['blockdevices'][0]['children'][0]['uuid']=fsid
        mounts={'filesystems':[mount('/',source='/dev/sdb3[/root]',major='0:31',fstype='btrfs'),
                              mount('/var',source='/dev/sdb3[/var]',major='0:32',fstype='btrfs')]}
        for row in mounts['filesystems']: row['uuid']=fsid
        proof=native(graph,mounts,btrfs={fsid:('1',['8:19'])})
        r=self.consumer(PROOF=proof,DATA=userdata(source='/dev/sdb3[/var]',major='0:32',proof=proof))
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

    def test_overlay_requires_complete_unique_active_content_layers(self):
        invalid=['ro,lowerdir++=/run/cfs','ro,lowerdir=/run/cfs,upperdir+=/var/upper,workdir=/var/work','rw,workdir=/var/work','ro,datadir=/sysroot/objects','ro,lowerdir=',
                 'ro,lowerdir=/run/cfs,lowerdir+=/sysroot/objects',
                 'ro,lowerdir=/run/cfs,upperdir=/var/upper',
                 'ro,lowerdir=/run/cfs,workdir=/var/work',
                 'ro,lowerdir=::/sysroot/objects','ro,lowerdir=/run/cfs::',
                 r'ro,lowerdir=/sysroot/escaped\040path']
        for options in invalid:
            r=self.consumer(PROOF=self.projection(options=options))
            self.assertNotEqual(r.returncode,0)
            self.assertIn('INFRA',r.stdout)
            self.assertNotIn('PRODUCT-PASS',r.stdout)

    def test_measured_symlink_backing_must_resolve_on_target(self):
        proof=self.projection()
        fields=dict(line.split('=',1) for line in proof.splitlines())
        paths=base64.b64decode(fields['PATHS']).decode().replace('/sysroot/native.cfs\t/sysroot/native.cfs',
                                                               '/sysroot/native.cfs\t/mnt/windows/native.cfs')
        changed=proof.replace('PATHS='+fields['PATHS'],'PATHS='+base64.b64encode(paths.encode()).decode())
        r=self.consumer(PROOF=changed)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('PRODUCT-FAIL',r.stdout)
        unknown=proof.replace('PATHS='+fields['PATHS'],'PATHS='+base64.b64encode(paths.replace('/mnt/windows/native.cfs','-').encode()).decode())
        r=self.consumer(PROOF=unknown)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('INFRA',r.stdout)

    def btrfs(self, members=('8:19',), valid='1'):
        fsid='abcdefab-1234-1234-1234-123456789abc'
        graph=json.loads(json.dumps(BLOCKS));graph['blockdevices'][0]['children'][0]['uuid']=fsid
        graph['blockdevices'].append(node('/dev/sda','8:0','disk',[node('/dev/sda3','8:3','part')]))
        graph['blockdevices'][1]['children'][0]['uuid']=fsid
        mounts={'filesystems':[mount('/',source='/dev/sdb3[/root]',major='0:31',fstype='btrfs'),
                              mount('/var',source='/dev/sdb3[/var]',major='0:32',fstype='btrfs')]}
        for row in mounts['filesystems']: row['uuid']=fsid
        return native(graph,mounts,btrfs={fsid:(valid,list(members))})

    def test_btrfs_all_current_members_must_be_measured_on_target(self):
        for members,valid in [(('8:19','8:3'),'1'),(('8:19',),'0'),(('8:19','8:99'),'1'),(('8:19','8:19'),'1')]:
            proof=self.btrfs(members,valid)
            r=self.consumer(PROOF=proof,DATA=userdata('/dev/sdb3[/var]','0:32',proof=proof))
            self.assertNotEqual(r.returncode,0)
            self.assertNotIn('PRODUCT-PASS',r.stdout)
        proof=self.btrfs()
        r=self.consumer(PROOF=proof,DATA=userdata('/dev/sdb3[/var]','0:32',proof=proof))
        self.assertEqual(r.returncode,0,r.stderr)

    def test_actual_snapshot_resolves_owned_symlink_and_refuses_failed_plausible_readlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);local=base/'native';foreign=base/'windows';local.mkdir();foreign.mkdir()
            lower=local/'lower';lower.mkdir();alias=local/'alias';alias.symlink_to(lower)
            graph={'blockdevices':BLOCKS['blockdevices']+[node('/dev/sda','8:0','disk',[node('/dev/sda3','8:3','part')])]}
            options='ro,lowerdir='+str(alias)
            mounts={'filesystems':[mount('/','overlay','0:51','overlay',options),mount('/var'),
                                   mount(str(local)),mount(str(foreign),'/dev/sda3','8:3')]}
            script=(ROOT/'tests/e2e/phase3-snapshot.sh').read_text().replace('/sys/fs/btrfs',tmp+'/no-btrfs')
            prefix='''uname() { printf Linux; }
cat() { case "$1" in /proc/sys/kernel/random/boot_id) printf '%s' "$BOOT";; /proc/cmdline) printf 'root=UUID=native ro';; /etc/wootc/native-target) printf /dev/sdb;; *) return 1;; esac; }
lsblk() { printf '%s' "$BLOCK_JSON"; }
findmnt() { if [ "$1" = --json ]; then printf '%s' "$MOUNT_JSON"; else printf '%s' "$ROOT_OPTIONS"; fi; }
losetup() { if [ "$1" = --json ]; then printf '%s' "$LOOP_JSON"; fi; }
'''
            environment={**os.environ,'BOOT':BOOT,'BLOCK_JSON':json.dumps(graph),'MOUNT_JSON':json.dumps(mounts),
                         'LOOP_JSON':json.dumps(LOOPS),'ROOT_OPTIONS':options}
            def snapshot(extra=''):
                return subprocess.run(['/bin/sh','-c',prefix+extra+script,'snapshot','native'],
                                      capture_output=True,text=True,env=environment,timeout=3)
            good=snapshot();self.assertEqual(good.returncode,0,good.stderr)
            self.assertEqual(self.consumer(PROOF=good.stdout,DATA=userdata(proof=good.stdout)).returncode,0)
            alias.unlink();alias.symlink_to(foreign)
            wrong=snapshot();self.assertEqual(wrong.returncode,0,wrong.stderr)
            refused=self.consumer(PROOF=wrong.stdout)
            self.assertNotEqual(refused.returncode,0)
            self.assertIn('PRODUCT-FAIL',refused.stdout)
            failed=snapshot('readlink() { printf "%s" "'+str(lower)+'"; return 7; }\n')
            self.assertEqual(failed.returncode,0,failed.stderr)
            refused=self.consumer(PROOF=failed.stdout)
            self.assertNotEqual(refused.returncode,0)
            self.assertIn('INFRA',refused.stdout)


    def test_actual_snapshot_reads_all_btrfs_members_and_refuses_failed_metadata(self):
        fsid='abcdefab-1234-1234-1234-123456789abc'
        proof=self.btrfs()
        values=dict(line.split('=',1) for line in proof.splitlines())
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp)/'btrfs'/fsid
            def member(number,name,major):
                info=base/'devinfo'/str(number); info.mkdir(parents=True)
                for key,value in [('missing','0'),('in_fs_metadata','1'),('replace_target','0')]:
                    (info/key).write_text(value)
                device=base/'devices'/name;device.mkdir(parents=True);(device/'dev').write_text(major)
            member(1,'sdb3','8:19')
            query=(ROOT/'tests/e2e/phase3-snapshot.sh').read_text().replace('/sys/fs/btrfs',tmp+'/btrfs')
            prefix='''uname() { printf Linux; }
cat() { case "$1" in
 /proc/sys/kernel/random/boot_id) printf '%s' "$BOOT";;
 /proc/cmdline) printf 'root=UUID=native ro';;
 /etc/wootc/native-target) printf /dev/sdb;;
 */missing) if [ "$FAIL_META" = yes ]; then printf 0; return 7; fi; /bin/cat "$1";;
 *) /bin/cat "$1";; esac; }
lsblk() { printf '%s' "$BLOCK_JSON"; }
findmnt() { if [ "$1" = --json ]; then printf '%s' "$MOUNT_JSON"; else printf rw; fi; }
losetup() { if [ "$1" = --json ]; then printf '%s' "$LOOP_JSON"; fi; }
'''
            env={**os.environ,'BOOT':BOOT,'BLOCK_JSON':base64.b64decode(values['BLOCKS']).decode(),
                 'MOUNT_JSON':base64.b64decode(values['MOUNTS']).decode(),'LOOP_JSON':json.dumps(LOOPS),'FAIL_META':'no'}
            def snapshot(fail='no'):
                return subprocess.run(['/bin/sh','-c',prefix+query,'snapshot','native'],capture_output=True,
                                      text=True,env={**env,'FAIL_META':fail},timeout=3)
            good=snapshot();self.assertEqual(good.returncode,0,good.stderr)
            data=userdata('/dev/sdb3[/var]','0:32',proof=good.stdout)
            self.assertEqual(self.consumer(PROOF=good.stdout,DATA=data).returncode,0)
            failed=snapshot('yes');self.assertNotEqual(failed.returncode,0)
            self.assertEqual(failed.stdout,'')
            (base/'devinfo'/'1'/'missing').write_text('1')
            missing=snapshot();self.assertEqual(missing.returncode,0,missing.stderr)
            refused=self.consumer(PROOF=missing.stdout);self.assertIn('INFRA',refused.stdout)
            self.assertNotIn('PRODUCT-PASS',refused.stdout)
            (base/'devinfo'/'1'/'missing').write_text('0')
            member(2,'sda3','8:3')
            foreign=snapshot();self.assertEqual(foreign.returncode,0,foreign.stderr)
            refused=self.consumer(PROOF=foreign.stdout);self.assertIn('PRODUCT-FAIL',refused.stdout)
            self.assertNotIn('PRODUCT-PASS',refused.stdout)

    def test_parser_process_failure_remains_infrastructure_unknown(self):
        source=(ROOT/'tests/e2e/run-e2e.sh').read_text()
        with tempfile.TemporaryDirectory() as tmp:
            altered=Path(tmp)/'runner.sh'
            altered.write_text(source.replace('    # A failed guest command cannot establish facts even with plausible stdout.',
                                              '    # A failed guest command cannot establish facts even with plausible stdout.\npython3() { return 7; }'))
            result=self.consumer(module=altered)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('INFRA',result.stdout)
        self.assertNotIn('PRODUCT-',result.stdout)

    def test_metadata_bounds_and_cyclic_block_graph_refuse(self):
        graphs=[]
        deep=node('/dev/sdb3','8:19','part')
        for index in range(66):
            deep=node('/dev/dm'+str(index),'253:'+str(index),'dm',[deep])
        graphs.append({'blockdevices':[node('/dev/sdb','8:16','disk',[deep])]})
        cycle=node('/dev/sdb3','8:19','part',[node('/dev/sdb','8:16','disk')])
        graphs.append({'blockdevices':[node('/dev/sdb','8:16','disk',[cycle])]})
        graphs.append({'blockdevices':[node('/dev/sdb','8:16','disk')]+
                       [node('/dev/x'+str(index),'250:'+str(index),'disk') for index in range(1025)]})
        for graph in graphs:
            result=self.consumer(PROOF=native(blocks=graph))
            self.assertNotEqual(result.returncode,0)
            self.assertIn('INFRA',result.stdout)
            self.assertNotIn('PRODUCT-PASS',result.stdout)


def load_e2e(name, filename):
    spec=importlib.util.spec_from_file_location(name, ROOT/'tests/e2e'/filename)
    module=importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(ROOT/'tests/e2e'))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(str(ROOT/'tests/e2e'))
    return module


ancestry=load_e2e('phase3_ancestry_under_test','phase3_ancestry.py')
receipt=load_e2e('phase3_receipt_under_test','phase3-native-receipt.py')
# The native snapshot lines from hosted run 39007144179 (job 117321813725),
# timestamps stripped. binfmt_misc had been triggered, so findmnt lists the
# systemd autofs and the real binfmt_misc on /proc/sys/fs/binfmt_misc.
REAL_SNAPSHOT=ROOT/'tests/unit/fixtures/phase3-native/run-39007144179.snapshot'
BINFMT='/proc/sys/fs/binfmt_misc'


class StackedMountTargets(unittest.TestCase):
    def real(self):
        # The run predates the ROOT field; it carried no root probe export.
        return receipt.parse(REAL_SNAPSHOT.read_text()+'ROOT=\n')

    def with_mounts(self, fields, edit):
        value=json.loads(base64.b64decode(fields['MOUNTS']))
        edit(value['filesystems'])
        return dict(fields, MOUNTS=encode(value))

    def test_real_native_snapshot_with_stacked_binfmt_misc_parses(self):
        fields=self.real()
        graph=ancestry.Ancestry(fields,'/dev/sdb')
        self.assertEqual(graph.stacked,{BINFMT})
        self.assertEqual(graph.mount('/')['source'],'composefs')
        self.assertEqual(graph.mount('/sysroot')['maj:min'],'8:19')
        self.assertEqual(graph.mount('/boot')['source'],'/dev/sdb2')
        # Real ancestry through the strict /var row still reaches only /dev/sdb.
        graph.verify_data('/dev/sdb3[/ostree/deploy/default/var]','8:19','/var')
        with self.assertRaisesRegex(ValueError,'Ambiguous mount target'):
            graph.mount(BINFMT)

    def test_stacked_dependency_target_in_real_snapshot_still_refuses(self):
        fields=self.real()
        def stack(target):
            def edit(rows):
                rows.append(dict(next(row for row in self.walk(rows) if row['target']==target), children=None))
            return edit
        for target in ['/', '/sysroot', '/boot', '/var']:
            with self.subTest(target=target), self.assertRaisesRegex(ValueError,'Ambiguous mount target'):
                ancestry.Ancestry(self.with_mounts(fields, stack(target)),'/dev/sdb')

    @staticmethod
    def walk(rows):
        for row in rows:
            yield row
            yield from StackedMountTargets.walk(row.get('children') or [])

    def test_stacked_unrelated_target_is_tolerated_end_to_end(self):
        autofs=mount(BINFMT,'systemd-1','0:33','autofs')
        autofs['children']=[mount(BINFMT,'binfmt_misc','0:72','binfmt_misc')]
        mounts={'filesystems':[mount('/'),mount('/var'),autofs]}
        proof=native(mounts=mounts)
        r=Phase3Tests.consumer(self, PROOF=proof, DATA=userdata(proof=proof))
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn('PRODUCT-PASS native-boot',r.stdout)
        self.assertIn('PRODUCT-PASS native-user-data',r.stdout)

    def test_stacked_data_mount_refuses_end_to_end(self):
        mounts={'filesystems':[mount('/'),mount('/srv'),mount('/srv')]}
        proof=native(mounts=mounts)
        r=Phase3Tests.consumer(self, PROOF=proof, DATA=userdata(target='/srv',proof=proof))
        self.assertNotEqual(r.returncode,0)
        self.assertIn('PRODUCT-PASS native-boot',r.stdout)
        self.assertIn('INFRA',r.stdout)
        self.assertNotIn('PRODUCT-PASS native-user-data',r.stdout)

    def test_projection_on_stacked_target_refuses_not_parent_fallback(self):
        # /run/cfs is stacked; resolving the lower layer must not fall back to
        # the parent '/sysroot' row (which is on the target) and pass.
        options='ro,lowerdir=/sysroot/run/cfs'
        mounts={'filesystems':[mount('/','composefs','0:51','overlay',options),mount('/var'),mount('/sysroot'),
                               mount('/sysroot/run/cfs','/dev/sda3','8:3'),mount('/sysroot/run/cfs')]}
        graph={'blockdevices':BLOCKS['blockdevices']+[node('/dev/sda','8:0','disk',[node('/dev/sda3','8:3','part')])]}
        r=Phase3Tests.consumer(self, PROOF=native(graph,mounts))
        self.assertNotEqual(r.returncode,0)
        self.assertIn('INFRA',r.stdout)
        self.assertNotIn('PRODUCT-PASS',r.stdout)


def real_fields():
    return dict(line.split('=',1) for line in REAL_SNAPSHOT.read_text().splitlines())


REAL=real_fields()
REAL_KARG=next(token[len('ostree='):] for token in REAL['CMDLINE'].split() if token.startswith('ostree='))
REAL_OPTIONS=json.loads(base64.b64decode(REAL['MOUNTS']))['filesystems'][0]['options']
# The deployment the kernel's /etc bind row of the run names.
REAL_DEPLOY='/sysroot/ostree/deploy/default/deploy/e0425953c86e0854c86c727501ffcbe375273065652db409ead13c84aecc1b89.0'
LOWER='/run/ostree/.private/cfsroot-lower'
OBJECTS='/sysroot/ostree/repo/objects'
INVOCATION='0123456789abcdef0123456789abcdef'


def probe_body(boot=None, invocation=INVOCATION, options=REAL_OPTIONS, layers=None, deploy=None, image=None):
    """The export the boot-time root probe would write on run 39007144179's
    root. Run 39007144179 had no probe; every value is taken from that run's
    own observations (root options, cmdline ostree=, the /etc bind row)."""
    if layers is None:
        layers=[(LOWER,LOWER,'empty'),(OBJECTS,OBJECTS,'populated')]
    deploy=deploy or (REAL_KARG,REAL_DEPLOY)
    image=image or (REAL_DEPLOY+'/.ostree.cfs','8:19')
    lines=['ROOT_SCHEMA=1','ROOT_BOOT_ID='+(boot or REAL['BOOT_ID']),'ROOT_INVOCATION='+invocation,'ROOT_OPTIONS='+options]
    lines+=['LAYER='+'\t'.join(layer) for layer in layers]
    if deploy != 'none':
        lines.append('DEPLOY='+'\t'.join(deploy))
    if image != 'none':
        lines.append('IMAGE='+'\t'.join(image))
    return '\n'.join(lines)


def root_field(body=None, owner='0:0:644'):
    """The snapshot's ROOT value: the export's observed owner/mode, then the export."""
    return 'FILE='+owner+'\n'+(probe_body() if body is None else body)


def real_proof(root=None, **fields):
    values=dict(REAL, **fields)
    if root is not None:
        values['ROOT']=base64.b64encode(root.encode()).decode()
    return ''.join(key+'='+value+'\n' for key,value in values.items())


def receipt_status(proof):
    return subprocess.run([sys.executable,str(ROOT/'tests/e2e/phase3-native-receipt.py'),'/dev/sdb'],
                          input=proof,capture_output=True,text=True,timeout=10)


SNAPSHOT_MOCKS='''uname() { printf Linux; }
cat() { for last; do :; done; case "$last" in
 /proc/sys/kernel/random/boot_id) printf '%s' "$BOOT";;
 /proc/cmdline) printf '%s' "$CMDLINE";;
 /etc/wootc/native-target) printf /dev/sdb;;
 *) /bin/cat "$@";; esac; }
lsblk() { printf '%s' "$BLOCK_JSON"; }
findmnt() { if [ "$1" = --json ]; then printf '%s' "$MOUNT_JSON"; else printf '%s' "$ROOT_OPTIONS"; fi; }
losetup() { if [ "$1" = --json ]; then printf '%s' "$LOOP_JSON"; fi; }
'''


class ComposefsRootProbe(unittest.TestCase):
    def accepted(self, proof):
        r=receipt_status(proof)
        self.assertEqual((r.returncode,r.stdout.strip()),(0,REAL['BOOT_ID']),r.stderr)

    def refused(self, proof, code=2):
        r=receipt_status(proof)
        self.assertEqual(r.returncode,code,r.stdout+r.stderr)
        self.assertNotIn(REAL['BOOT_ID'],r.stdout)

    def test_real_composefs_root_passes_with_boot_probe_observations(self):
        # Before this change the same observations refused: the detached
        # cfsroot-lower resolved to the /run tmpfs and the datadir was '-'.
        self.accepted(real_proof(root_field()))

    def test_missing_root_field_refuses(self):
        self.refused(real_proof())

    def test_absent_probe_export_refuses(self):
        self.refused(real_proof(''))

    def test_malformed_root_field_refuses(self):
        self.refused(real_proof(ROOT='not base64!'))
        bad=[root_field()+'\nNOISE=1', root_field()+'\nLAYER='+LOWER+'\t'+LOWER+'\tempty',
             root_field()+'\nDEPLOY='+REAL_KARG+'\t'+REAL_DEPLOY, root_field().replace('ROOT_SCHEMA=1','ROOT_SCHEMA=2'),
             root_field(probe_body(options='')), root_field(probe_body(layers=[(LOWER,'relative','empty')])),
             root_field(probe_body(image=(REAL_DEPLOY+'/.ostree.cfs','sdb3'))), 'FILE=0:0:644', root_field()+'\n']
        for raw in bad:
            with self.subTest(raw=raw[-60:]):
                self.refused(real_proof(raw))

    def test_export_not_written_by_the_probe_unit_refuses(self):
        for root in [root_field(owner='1000:1000:644'), root_field(owner='0:0:666'),
                     root_field(probe_body(invocation='')), root_field(probe_body(invocation='f'*31)),
                     root_field().replace('FILE=0:0:644\n','')]:
            with self.subTest(root=root[:40]):
                self.refused(real_proof(root))

    def test_export_from_another_boot_or_root_refuses(self):
        self.refused(real_proof(root_field(probe_body(boot='00000000-0000-0000-0000-000000000000'))))
        self.refused(real_proof(root_field(probe_body(options=REAL_OPTIONS.replace('metacopy=on','metacopy=off')))))

    def test_composefs_chain_must_hold_end_to_end(self):
        other=REAL_DEPLOY.replace('e0425953','f0425953')
        for body in [probe_body(image='none'), probe_body(deploy='none'),
                     probe_body(deploy=('/ostree/boot.0/default/other/0',REAL_DEPLOY)),
                     probe_body(deploy=(REAL_KARG,other),image=(other+'/.ostree.cfs','8:19')),
                     probe_body(image=(REAL_DEPLOY+'/other.cfs','8:19')),
                     probe_body(image=(REAL_DEPLOY+'/.ostree.cfs','8:3')),
                     probe_body(layers=[(LOWER,LOWER,'populated'),(OBJECTS,OBJECTS,'populated')]),
                     probe_body(layers=[(LOWER,'/run/ostree','empty'),(OBJECTS,OBJECTS,'populated')]),
                     probe_body(layers=[(LOWER,LOWER,'empty')]),
                     probe_body(layers=[(LOWER,LOWER,'empty'),(OBJECTS,'/run/objects','populated')])]:
            with self.subTest(body=body[-120:]):
                self.refused(real_proof(root_field(body)))
        # The kernel's /etc bind row must name the probed deployment.
        mounts=json.loads(base64.b64decode(REAL['MOUNTS']))
        for row in mounts['filesystems'][0]['children']:
            if row['target']=='/etc':
                row['source']=row['source'].replace('e0425953','f0425953')
        self.refused(real_proof(root_field(),MOUNTS=encode(mounts)))

    def test_image_on_another_disk_is_a_product_mismatch(self):
        # /sysroot itself moved to the Windows disk: the chain is consistent
        # but the backing is outside the target, so the receipt says mismatch.
        mounts=json.loads(base64.b64decode(REAL['MOUNTS']))
        for row in mounts['filesystems'][0]['children']:
            if row['target'] in {'/sysroot','/etc'}:
                row['source']=row['source'].replace('/dev/sdb3','/dev/sda3'); row['maj:min']='8:3'
        self.refused(real_proof(root_field(probe_body(image=(REAL_DEPLOY+'/.ostree.cfs','8:3'))),MOUNTS=encode(mounts)),3)

    def test_agent_and_probe_resolutions_must_agree(self):
        paths='\n'.join([LOWER+'\t'+LOWER, OBJECTS+'\t/sysroot/ostree/elsewhere'])
        self.refused(real_proof(root_field(),PATHS=base64.b64encode(paths.encode()).decode()))

    def snapshot(self, export=None, mode=0o644, symlink=False):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp); out=base/'export'
            if export is not None:
                target=base/'real-export' if symlink else out
                target.write_text(export); target.chmod(mode)
                if symlink:
                    out.symlink_to(target)
            script=((ROOT/'tests/e2e/phase3-snapshot.sh').read_text()
                    .replace('/run/wootc-e2e-native-root',str(out)).replace('/sys/fs/btrfs',str(base/'no-btrfs')))
            env={**os.environ,'BOOT':REAL['BOOT_ID'],'CMDLINE':REAL['CMDLINE'],'ROOT_OPTIONS':REAL_OPTIONS,
                 'BLOCK_JSON':base64.b64decode(REAL['BLOCKS']).decode(),'MOUNT_JSON':base64.b64decode(REAL['MOUNTS']).decode(),
                 'LOOP_JSON':base64.b64decode(REAL['LOOPS']).decode()}
            r=subprocess.run(['/bin/sh','-c',SNAPSHOT_MOCKS+script,'snapshot','native'],capture_output=True,text=True,env=env,timeout=5)
            self.assertEqual(r.returncode,0,r.stderr)
            return r.stdout

    def test_actual_snapshot_carries_probe_provenance(self):
        if os.geteuid()!=0:
            self.skipTest('the owner observation needs a root-owned export')
        self.accepted(self.snapshot(probe_body()))
        self.refused(self.snapshot(None))
        self.refused(self.snapshot(probe_body(),mode=0o666))
        self.refused(self.snapshot(probe_body(),symlink=True))


class RootProbeScript(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        base=self.base=Path(self.temporary.name)
        self.bin=base/'bin'; self.bin.mkdir()
        self.sysroot=base/'sysroot'; deploy=self.sysroot/'ostree/deploy/default/deploy/abc.0'; deploy.mkdir(parents=True)
        self.image=deploy/'.ostree.cfs'; self.image.write_bytes(b'erofs')
        boot=self.sysroot/'ostree/boot.1/default/csum'; boot.mkdir(parents=True)
        (boot/'0').symlink_to('../../../deploy/default/deploy/abc.0')
        self.deploy=deploy
        self.lower=base/'cfsroot-lower'; self.lower.mkdir()
        self.objects=self.sysroot/'ostree/repo/objects'; self.objects.mkdir(parents=True); (self.objects/'00').mkdir()
        (base/'boot').write_text(REAL['BOOT_ID']+'\n')
        (base/'cmdline').write_text('root=UUID=x rw ostree=/ostree/boot.1/default/csum/0 quiet\n')
        self.out=base/'export'
        source=(ROOT/'payload/migration/wootc-go-native').read_text()
        script=re.search(r"<<'ROOTPROBE'\n(.*?)\nROOTPROBE",source,re.S)[1]
        script=(script.replace('/run/wootc-e2e-native-root',str(self.out))
                .replace('/proc/sys/kernel/random/boot_id',str(base/'boot'))
                .replace('/proc/cmdline',str(base/'cmdline')).replace('"/sysroot$karg"','"'+str(self.sysroot)+'$karg"'))
        self.script=base/'probe'; self.script.write_text(script)
        self.options=f'ro,relatime,lowerdir+={self.lower},datadir+={self.objects},redirect_dir=on'
        (self.bin/'findmnt').write_text('#!/bin/bash\nprintf "%s\\n" "$PROBE_OPTIONS"\n'); (self.bin/'findmnt').chmod(0o700)
        self.env=dict(os.environ,PATH=str(self.bin)+':/usr/bin:/bin',PROBE_OPTIONS=self.options,INVOCATION_ID=INVOCATION)

    def run_probe(self, **env):
        return subprocess.run(['/bin/bash',str(self.script)],env={**self.env,**env},capture_output=True,text=True,timeout=5)

    def test_exact_export(self):
        r=self.run_probe(); self.assertEqual(r.returncode,0,r.stderr)
        info=os.stat(self.image)
        self.assertEqual(self.out.read_text(),'\n'.join([
            'ROOT_SCHEMA=1','ROOT_BOOT_ID='+REAL['BOOT_ID'],'ROOT_INVOCATION='+INVOCATION,'ROOT_OPTIONS='+self.options,
            f'LAYER={self.lower}\t{self.lower}\tempty',f'LAYER={self.objects}\t{self.objects}\tpopulated',
            f'DEPLOY=/ostree/boot.1/default/csum/0\t{self.deploy}',
            f'IMAGE={self.image}\t{os.major(info.st_dev)}:{os.minor(info.st_dev)}'])+'\n')
        self.assertEqual(self.out.stat().st_mode & 0o777,0o644)
        parsed=ancestry.root_probe('FILE=0:0:644\n'+self.out.read_text().rstrip('\n'),REAL['BOOT_ID'])
        self.assertEqual(parsed['deploy'],('/ostree/boot.1/default/csum/0',str(self.deploy)))

    def refused(self, **env):
        self.out.write_text('stale prior success')
        r=self.run_probe(**env)
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(self.out.exists())
        self.assertEqual(list(self.base.glob('export.*')),[])

    def test_outside_the_unit_no_export(self):
        self.refused(INVOCATION_ID='')

    def test_unresolvable_layer_no_export(self):
        self.refused(PROBE_OPTIONS=self.options.replace(str(self.objects),str(self.base/'missing')))

    def test_symlinked_image_no_export(self):
        real=self.base/'elsewhere.cfs'; real.write_bytes(b'x'); self.image.unlink(); self.image.symlink_to(real)
        self.refused()

    def test_ambiguous_deployment_no_export(self):
        (self.base/'cmdline').write_text('ostree=/ostree/boot.1/default/csum/0 ostree=/ostree/boot.1/default/csum/0\n')
        self.refused()



# The native snapshot from hosted run 39886118219 (bluefin:stable, composefs
# root), timestamps stripped. The confined agent could not read systemd's
# unit invocation record, so the snapshot carried an empty UNIT line under
# the old protocol; the probe's own export was complete.
REAL_STABLE=ROOT/'tests/unit/fixtures/phase3-native/run-39886118219.snapshot'


def stable_fields():
    return dict(line.split('=',1) for line in REAL_STABLE.read_text().splitlines())


class RealStableRootProbe(unittest.TestCase):
    def proof(self, root):
        fields=stable_fields()
        fields['ROOT']=base64.b64encode(root.encode()).decode()
        return ''.join(key+'='+value+'\n' for key,value in fields.items())

    def root(self):
        # Drop the old protocol's UNIT line; the rest is the run's own export.
        lines=base64.b64decode(stable_fields()['ROOT']).decode().split('\n')
        self.assertEqual(lines[1],'UNIT=')
        return '\n'.join(lines[:1]+lines[2:])

    def test_real_composefs_root_of_the_run_passes(self):
        fields=stable_fields()
        r=receipt_status(self.proof(self.root()))
        self.assertEqual((r.returncode,r.stdout.strip()),(0,fields['BOOT_ID']),r.stderr)

    def test_real_run_still_refuses_a_foreign_deployment_or_device(self):
        root=self.root()
        deploy=next(l for l in root.split('\n') if l.startswith('DEPLOY='))
        for bad in [root.replace(deploy,deploy.replace('fe8e62ad','0e8e62ad')),
                    root.replace('/.ostree.cfs\t8:19','/.ostree.cfs\t8:3'),
                    root.replace('FILE=0:0:644','FILE=0:0:666'),
                    '\n'.join(l for l in root.split('\n') if not l.startswith('IMAGE='))]:
            with self.subTest(bad=bad[-80:]):
                r=receipt_status(self.proof(bad))
                self.assertNotEqual(r.returncode,0,r.stdout)
                self.assertNotIn(stable_fields()['BOOT_ID'],r.stdout)


if __name__ == '__main__':
    unittest.main()
