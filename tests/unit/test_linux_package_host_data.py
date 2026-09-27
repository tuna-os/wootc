"""Actual private tar/content controls; fixtures do not prove archive authentication."""
import hashlib
import io
import json
import subprocess
import socket
import time
from unittest.mock import patch
from pathlib import Path
import runpy
import tarfile
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
DATA=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/host-data.py'))


class HostDataTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.folder=Path(self.temp.name);self.objects={}
        self.metadata='Package: ovmf\nVersion: 1\nArchitecture: all\nFilename: pool/main/o/ovmf/ovmf_1_all.deb\nSize: 5\nSHA256: '+'a'*64+'\n'

    def test_actual_blocking_socket_download_read_uses_remaining_deadline(self):
        receiver,sender=socket.socketpair()
        self.addCleanup(receiver.close);self.addCleanup(sender.close)
        stream=receiver.makefile('rb');self.addCleanup(stream.close)
        class Response:
            fp=stream
            def read1(self,size):return self.fp.read1(size)
        start=time.monotonic()
        with self.assertRaises(TimeoutError):DATA['download_chunk'](Response(),lambda:.05)
        self.assertLess(time.monotonic()-start,1)

    def test_download_spent_deadline_refuses_before_socket_or_read(self):
        class Response:
            def read1(self,*_):raise AssertionError('spent deadline reached download read')
        with self.assertRaises(TimeoutError):DATA['download_chunk'](Response(),lambda:0)

    def test_actual_extraction_child_uses_remaining_deadline(self):
        start=time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            DATA['bounded_blob'](['/usr/bin/python3','-c','import time;time.sleep(5)'],
                                 self.folder/'bounded',1024,None,remaining=lambda:.05)
        self.assertLess(time.monotonic()-start,1)

    def test_spent_deadline_refuses_before_any_child_or_output(self):
        with self.assertRaises(TimeoutError):
            DATA['bounded_blob'](['/usr/bin/python3','-c','raise Exception()'],
                                 self.folder/'absent',1024,None,remaining=lambda:0)
        self.assertFalse((self.folder/'absent').exists())

    def test_archive_directory_modes_record_package_fact_without_using_host_mode(self):
        output=io.BytesIO()
        with tarfile.open(fileobj=output,mode='w') as archive:
            member=tarfile.TarInfo('./usr/share');member.type=tarfile.DIRTYPE;member.mode=0o755
            archive.addfile(member)
        directories={}
        DATA['unpack_tar'](output.getvalue(),{},'qemu-system-data',directories)
        self.assertEqual(directories,{'usr/share':[{'package':'qemu-system-data','archiveMode':0o755}]})

    def test_actual_proof_export_keeps_early_failure_pins_without_guest_stage(self):
        proof=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/host-data-proof.py'))
        prefix=self.folder/'prefix';prefix.mkdir()
        (prefix/'host-data.json').write_text('{"complete":false,"authenticatedPackagePins":{"fixture":true}}')
        (prefix/'namespace-failure.json').write_text('{"runtimeExecuted":false}')
        (prefix/'downloads').mkdir();(prefix/'downloads/secret.deb').write_bytes(b'not-exported')
        target=self.folder/'proof'
        with patch.dict(proof['export'].__globals__,{'TRUST':{'protected':lambda path:path}}),patch.object(proof['re'],'fullmatch',return_value=True):
            copied=proof['export'](prefix,target)
        self.assertEqual(set(copied),{'host-data.json','namespace-failure.json'})
        self.assertEqual((target/'host-data.json').read_bytes(),(prefix/'host-data.json').read_bytes())
        self.assertFalse((target/'downloads').exists())
        self.assertFalse(json.loads((target/'export.json').read_text())['runtimeExecuted'])

    def archive(self,rows):
        output=io.BytesIO()
        with tarfile.open(fileobj=output,mode='w') as archive:
            for name,kind,value in rows:
                member=tarfile.TarInfo(name)
                if kind=='link':member.type=tarfile.SYMTYPE;member.linkname=value;archive.addfile(member)
                else:member.size=len(value);archive.addfile(member,io.BytesIO(value))
        return output.getvalue()

    def unpack(self,rows):DATA['unpack_tar'](self.archive(rows),self.objects,'fixture-package')

    def complete(self):
        names=('usr/share/OVMF/OVMF_CODE_4M.fd','usr/share/OVMF/OVMF_VARS_4M.fd',
               'usr/share/seabios/vgabios-stdvga.bin','usr/lib/ipxe/qemu/efi-virtio.rom')
        self.unpack([(name,'file',b'public fixture') for name in names])

    def test_actual_complete_resource_content_and_alias_never_borrow_host(self):
        self.complete()
        self.unpack([('usr/share/qemu/OVMF.fd','link','../OVMF/OVMF_CODE_4M.fd')])
        outputs=DATA['write_tree'](self.objects,self.folder)
        target=self.folder/'usr/share/qemu/OVMF.fd'
        self.assertFalse(target.is_symlink());self.assertEqual(target.read_bytes(),b'public fixture')
        self.assertEqual(target.stat().st_mode&0o777,0o444)
        self.assertEqual(outputs['usr/share/qemu/OVMF.fd']['originalLinkTarget'],'usr/share/OVMF/OVMF_CODE_4M.fd')

    def test_missing_sibling_rom_refuses_before_complete_receipt(self):
        self.unpack([('usr/share/qemu/rom','link','../seabios/missing.bin')])
        with self.assertRaisesRegex(ValueError,'target missing'):DATA['write_tree'](self.objects,self.folder)
        self.assertFalse((self.folder/'host-data.json').exists())

    def test_escaping_link_never_reads_existing_host_source(self):
        with self.assertRaisesRegex(ValueError,'escapes'):
            self.unpack([('usr/share/qemu/rom','link','../../../../etc/passwd')])
        self.assertEqual(self.objects,{})

    def test_cyclic_links_refuse(self):
        self.unpack([('usr/share/qemu/a','link','b'),('usr/share/qemu/b','link','a')])
        with self.assertRaisesRegex(ValueError,'cycle'):DATA['resolve'](self.objects,'usr/share/qemu/a')

    def test_path_traversal_archive_refuses(self):
        with self.assertRaisesRegex(ValueError,'escapes'):self.unpack([('../usr/share/qemu/file','file',b'wrong')])

    def test_conflicting_archive_content_refuses(self):
        self.unpack([('usr/share/qemu/file','file',b'first')])
        with self.assertRaisesRegex(ValueError,'conflicting'):self.unpack([('usr/share/qemu/file','file',b'changed')])

    def test_resource_file_cannot_be_used_as_directory(self):
        self.unpack([('usr/share/qemu/parent','file',b'one'),('usr/share/qemu/parent/file','file',b'two')])
        with self.assertRaisesRegex(ValueError,'parent'):DATA['write_tree'](self.objects,self.folder)

    def test_exact_metadata_pin_and_wrong_or_missing_sha_refusal(self):
        self.assertEqual(DATA['package_pin'](self.metadata,'ovmf','1')['SHA256'],'a'*64)
        for text in (self.metadata.replace('a'*64,'wrong'),self.metadata.replace('SHA256: '+'a'*64+'\n','')):
            with self.assertRaises(ValueError):DATA['package_pin'](text,'ovmf','1')
        with self.assertRaises(ValueError):DATA['package_pin'](self.metadata,'ovmf','stale')

    def test_conflicting_metadata_pin_refuses(self):
        with self.assertRaisesRegex(ValueError,'ambiguous'):
            DATA['package_pin'](self.metadata+'\n'+self.metadata.replace('a'*64,'b'*64),'ovmf','1')

    def test_private_apt_config_excludes_host_sources_keys_and_insecure_flags(self):
        config=DATA['apt_config'](self.folder).read_text()
        self.assertIn('Acquire::AllowInsecureRepositories "false"',config)
        self.assertIn('APT::Get::AllowUnauthenticated "false"',config)
        self.assertIn('Dir::Etc::sourceparts "-"',config)
        sources=(self.folder/'apt/etc/ubuntu.sources').read_text()
        self.assertNotIn('trusted',sources.lower());self.assertNotIn('/usr/share/keyrings',sources)
        self.assertIn('https://archive.ubuntu.com/ubuntu',sources)
        self.assertIn(str(self.folder/'archive-key.gpg'),sources)

    def test_signed_release_sha_table_requires_exact_valid_entries(self):
        text='SHA256:\n '+('a'*64)+' 5 main/binary-amd64/Packages\nSHA512:\n'
        self.assertEqual(DATA['release_checksums'](text)['main/binary-amd64/Packages'],('a'*64,5))
        with self.assertRaises(ValueError):DATA['release_checksums'](text.replace('a'*64,'wrong'))
        with self.assertRaises(ValueError):DATA['release_checksums']('missing')


if __name__=='__main__':unittest.main()
