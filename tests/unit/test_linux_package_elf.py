"""Actual installed ELF/ldd/readelf controls; no QEMU process or guest is started."""
import json
from pathlib import Path
import runpy
import struct
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/hosted-execute.py'))
MODULE_PATH=Path('/usr/lib/x86_64-linux-gnu/qemu/hw-display-virtio-gpu-pci.so')


class ElfTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.copy=Path(self.temp.name)/'module.so'
        self.copy.write_bytes(MODULE_PATH.read_bytes())

    def test_actual_module_zero_needed_matches_native_readelf_and_ldd(self):
        facts=MODULE['elf_needed'](MODULE_PATH)
        self.assertEqual(facts['neededNames'],[]);self.assertEqual(facts['elfType'],3)
        self.assertFalse(facts['hasInterpreter']);self.assertGreater(facts['dynamicEntries'],1)
        output=subprocess.run(['/usr/bin/readelf','-d','-W',str(MODULE_PATH)],check=True,capture_output=True,text=True).stdout
        self.assertIn('(NULL)',output);self.assertNotIn('(NEEDED)',output)
        native=subprocess.run(['/usr/bin/ldd',str(MODULE_PATH)],check=True,capture_output=True,text=True).stdout
        self.assertEqual(native.strip(),'statically linked')
        MODULE['dependency_class'](MODULE_PATH,facts,set(),{MODULE_PATH})

    def test_actual_needed_executable_empty_ldd_is_refused(self):
        facts=MODULE['elf_needed']('/usr/bin/true')
        self.assertIn('libc.so.6',facts['neededNames'])
        with self.assertRaisesRegex(ValueError,'true.*ldd-readback'):
            MODULE['dependency_class'](Path('/usr/bin/true'),facts,set(),{Path('/usr/bin/true')})

    def test_zero_needed_nonmodule_does_not_enable_blanket_empty_ldd(self):
        facts=MODULE['elf_needed'](MODULE_PATH)
        with self.assertRaises(ValueError):MODULE['dependency_class'](MODULE_PATH,facts,set(),set())

    def test_actual_truncated_elf_program_table_refuses(self):
        self.copy.write_bytes(self.copy.read_bytes()[:100])
        with self.assertRaises(ValueError):MODULE['elf_needed'](self.copy)

    def dynamic(self,data):
        header=struct.unpack_from('<16sHHIQQQIHHHHHH',data)
        for index in range(header[10]):
            row=struct.unpack_from('<IIQQQQQQ',data,header[5]+index*56)
            if row[0]==2:return row[2],row[5]
        self.fail('fixture lacks dynamic table')

    def test_actual_dynamic_address_not_bound_to_loaded_bytes_refuses(self):
        data=bytearray(self.copy.read_bytes());header=struct.unpack_from('<16sHHIQQQIHHHHHH',data)
        for index in range(header[10]):
            position=header[5]+index*56
            if struct.unpack_from('<I',data,position)[0]==2:
                struct.pack_into('<Q',data,position+16,2**63);break
        self.copy.write_bytes(data)
        with self.assertRaisesRegex(ValueError,'loaded bytes'):MODULE['elf_needed'](self.copy)

    def test_actual_missing_dynamic_terminator_refuses(self):
        data=bytearray(self.copy.read_bytes());offset,size=self.dynamic(data)
        for pos in range(offset,offset+size,16):
            tag,value=struct.unpack_from('<qQ',data,pos)
            if tag==0:struct.pack_into('<qQ',data,pos,12,0)
        self.copy.write_bytes(data)
        with self.assertRaisesRegex(ValueError,'terminator missing'):MODULE['elf_needed'](self.copy)

    def test_actual_invalid_needed_string_offset_refuses(self):
        data=bytearray(self.copy.read_bytes());offset,_=self.dynamic(data)
        struct.pack_into('<qQ',data,offset,1,2**63)
        self.copy.write_bytes(data)
        with self.assertRaisesRegex(ValueError,'needed string offset'):MODULE['elf_needed'](self.copy)

    def test_sparse_oversized_elf_refuses_before_read(self):
        with self.copy.open('wb') as stream:stream.truncate(64*1024**2+1)
        with self.assertRaisesRegex(ValueError,'size/type'):MODULE['elf_needed'](self.copy)


if __name__=='__main__':unittest.main()
