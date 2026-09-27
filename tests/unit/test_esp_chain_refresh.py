#!/usr/bin/env python3
"""Actual shell consumer ordering; cryptographic policy has separate controls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]

class ConsumerTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.esp=self.root/'esp';self.boot=self.root/'boot'
        (self.esp/'EFI/wootc').mkdir(parents=True);(self.esp/'EFI/fedora').mkdir()
        (self.esp/'EFI/fedora/grub.cfg').write_text('original config')
        (self.boot/'loader/entries').mkdir(parents=True)
        (self.boot/'vmlinuz-new').write_bytes(b'kernel')
        (self.boot/'initrd-new').write_bytes(b'initrd')
        (self.boot/'loader/entries/test.conf').write_text('linux /vmlinuz-new\ninitrd /initrd-new\noptions ro\n')
        self.cmd=self.root/'cmdline';self.cmd.write_text('loop=/wootc/disks/root.disk wootc.host_uuid=0123456789ABCDEF\n')
        self.calls=self.root/'calls';self.control=self.root/'control.py'
        self.control.write_text('''import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as stream:stream.write(json.dumps(args)+'\\n')
if args[0]=='prepare':
 if os.environ.get('REFUSE'):sys.exit(1)
 print(os.environ.get('PREPARED',json.dumps({'cfgs':['EFI/fedora/grub.cfg'],'chainChanged':False})))
else:
 destination=args[args.index('--destination')+1]
 source=args[args.index('--source')+1]
 esp=args[args.index('--esp')+1]
 (Path(esp)/destination).write_bytes(Path(source).read_bytes())
''')
        # Execute through a real shell/Python wrapper on an executable filesystem.
        self.wrapper=self.root/'control'
        self.wrapper.write_text('#!/bin/sh\nexec python3 "'+str(self.control)+'" "$@"\n');self.wrapper.chmod(0o755)
        probe=subprocess.run([str(self.wrapper),'prepare'],env=dict(os.environ,CALLS=str(self.calls)),capture_output=True)
        self.assertEqual(probe.returncode,0,'fixture filesystem must execute scripts')
        self.calls.unlink()
        self.env=dict(os.environ,WOOTC_ESP_DIR=str(self.esp),WOOTC_BOOT_DIR=str(self.boot),
                      WOOTC_CMDLINE=str(self.cmd),WOOTC_ESP_UUID='fixture',
                      WOOTC_ESP_CONTROL=str(self.wrapper),CALLS=str(self.calls))
    def run_sync(self):return subprocess.run(['bash',str(ROOT/'payload/migration/wootc-esp-sync')],env=self.env,capture_output=True,text=True)
    def snapshot(self):return {str(p.relative_to(self.esp)):p.read_bytes() for p in self.esp.rglob('*') if p.is_file()}
    def test_refused_preflight_writes_nothing(self):
        before=self.snapshot();self.env['REFUSE']='1'
        self.assertNotEqual(self.run_sync().returncode,0);self.assertEqual(self.snapshot(),before)
        self.assertEqual(len(self.calls.read_text().splitlines()),1)
    def test_malformed_controller_response_writes_nothing(self):
        before=self.snapshot();self.env['PREPARED']='{"cfgs":["../foreign/grub.cfg"]}'
        self.assertNotEqual(self.run_sync().returncode,0);self.assertEqual(self.snapshot(),before)
    def test_prepare_precedes_each_delegated_artifact_write(self):
        result=self.run_sync();self.assertEqual(result.returncode,0,result.stderr)
        calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls[0][0],'prepare');self.assertTrue(all(call[0]=='write' for call in calls[1:]))
        self.assertEqual((self.esp/'EFI/wootc/phase2-vmlinuz').read_bytes(),b'kernel')
        self.assertIn('Windows',(self.esp/'EFI/fedora/grub.cfg').read_text())
    def test_neighboring_systemd_binary_does_not_change_observed_shim_route(self):
        folder=self.esp/'EFI/systemd';folder.mkdir()
        neighbor=folder/'systemd-bootx64.efi';neighbor.write_bytes(b'foreign neighboring bootloader')
        self.env['BOOTLOADER']='systemd'
        result=self.run_sync();self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(neighbor.read_bytes(),b'foreign neighboring bootloader')
        self.assertFalse((self.esp/'loader').exists())
        self.assertIn('Windows',(self.esp/'EFI/fedora/grub.cfg').read_text())
        calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
        destinations=[call[call.index('--destination')+1] for call in calls if call[0]=='write']
        self.assertIn('EFI/fedora/grub.cfg',destinations)
        self.assertTrue(all(not path.startswith('loader/') for path in destinations))

    def test_chain_prepare_runs_without_kernel_pair(self):
        (self.boot/'initrd-new').unlink()
        result=self.run_sync();self.assertEqual(result.returncode,0,result.stderr)
        calls=[json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(len(calls),1);self.assertEqual(calls[0][0],'prepare')
        self.assertNotIn('--kernel',calls[0])

if __name__=='__main__':unittest.main()
