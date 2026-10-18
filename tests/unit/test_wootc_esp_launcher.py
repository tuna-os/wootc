"""Real files/process/socket controls; compiled stand-in is not a QEMU/OS proof."""
import copy
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
MODULE = runpy.run_path(str(ROOT/'tests/e2e/esp-chain/launch.py'))
check_vm = runpy.run_path(str(ROOT/'tests/e2e/esp-chain/orchestrate.py'))['check_vm']


def firmware(entries):
    variables = b''
    for name, guid, data in entries:
        name = (name+'\0').encode('utf-16le')
        variables += struct.pack('<HBxIQ16sIII16s', 0x55aa, 0x3f, 0x27, 0, bytes(16), 0, len(name), len(data), uuid.UUID(guid).bytes_le)+name+data
        variables += bytes([255])*((-len(variables)) % 4)
    header = bytearray(72)
    header[16:32] = MODULE['NV_GUID']; header[40:44] = b'_FVH'
    size = 72+28+len(variables)+128
    struct.pack_into('<Q', header, 32, size); struct.pack_into('<H', header, 48, 72)
    struct.pack_into('<H', header, 50, (-sum(struct.unpack('<36H', header))) & 65535)
    store = MODULE['AUTH_GUID']+struct.pack('<IBBH I', size-72, 0x5a, 0xfe, 0, 0)
    return bytes(header)+store+variables+bytes([255])*128


class LauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler_dir = tempfile.TemporaryDirectory()
        directory = Path(cls.compiler_dir.name)
        source = directory/'fixture.c'
        source.write_text(r'''
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
int main(int argc,char **argv) {
  for(int i=1;i+1<argc;i++) {
    if(!strcmp(argv[i],"-drive")) {
      char *p=strstr(argv[i+1],"file="); if(!p) return 2;
      p+=5; char f[4096]; int n=strcspn(p,","); memcpy(f,p,n); f[n]=0;
      if(open(f,O_RDONLY)<0) return 3;
    }
    if(!strcmp(argv[i],"-chardev")) {
      char *p=strstr(argv[i+1],"path="); if(!p) return 4; p+=5;
      struct sockaddr_un a={0}; a.sun_family=AF_UNIX; int n=strcspn(p,",");
      if(n>=sizeof(a.sun_path)) return 5; memcpy(a.sun_path,p,n);
      int s=socket(AF_UNIX,SOCK_STREAM,0); if(bind(s,(void*)&a,sizeof(a)) || listen(s,1)) return 6;
    }
  }
  for(;;) pause();
}
''')
        compiler = shutil.which('cc')
        if not compiler: raise RuntimeError('native process controls require a C compiler')
        cls.binary = directory/'qemu-system-x86_64'
        subprocess.run([compiler, '-o', str(cls.binary), str(source)], check=True, timeout=30)

    @classmethod
    def tearDownClass(cls):
        cls.compiler_dir.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); parent = Path(self.temporary.name)
        identity = uuid.uuid4(); self.folder = parent/identity.hex; self.folder.mkdir(mode=0o700)
        overlay = self.folder/'disk.qcow2'; overlay.write_bytes(b'explicit image fixture'); overlay.chmod(0o600)
        variables = firmware([('db', MODULE['DB_GUID'], b'explicit db fixture'), ('dbx', MODULE['DB_GUID'], b'explicit dbx fixture')])
        code = parent/'code.fd'; code.write_bytes(b'explicit firmware code fixture'+bytes(72))
        store = parent/'store.fd'; store.write_bytes(variables)
        self.plan = {'scratchId': identity.hex, 'vmUuid': str(identity), 'firmwareTrustHashes': {n: hashlib.sha256(raw).hexdigest() for n, raw in [('db', struct.pack('<I', 0x27)+b'explicit db fixture'), ('dbx', struct.pack('<I', 0x27)+b'explicit dbx fixture')]}}
        plan = self.folder/'plan.json'; plan.write_text(json.dumps(self.plan)); plan.chmod(0o600)
        self.record = {'scratchId': identity.hex, 'vmUuid': str(identity), 'overlay': str(overlay), 'state': 'classic-offline-baseline-produced', 'planSha256': MODULE['digest'](plan)}
        self.config = {'qemu': {'path': str(self.binary), 'sha256': MODULE['digest'](self.binary)}, 'firmwareCode': {'path': str(code), 'sha256': MODULE['digest'](code)}, 'firmwareStore': {'path': str(store), 'sha256': MODULE['digest'](store)}, 'memoryMiB': 2048, 'cpus': 1, 'tpmMode': 'none-unencrypted-qa'}
        self.child = None

    def tearDown(self):
        if self.child is not None:
            self.child.terminate(); self.child.wait(timeout=2)
        self.temporary.cleanup()

    def process_fixture(self):
        launch = MODULE['prepare'](self.folder, self.record, self.config, executable_policy=lambda _: None, firmware_policy=lambda _: None)
        self.child = subprocess.Popen(launch['argv'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic()+2
        while not (self.folder/'qga.sock').exists():
            if self.child.poll() is not None or time.monotonic() > deadline: self.fail('owned process fixture failed')
            time.sleep(.01)
        launch.update(MODULE['process_identity'](self.child.pid), state='running')
        (self.folder/'launch.json').write_text(json.dumps(launch)); (self.folder/'launch.json').chmod(0o400)
        (self.folder/'qemu.pid').write_text(str(self.child.pid)); (self.folder/'qemu.pid').chmod(0o600)
        self.record['launchSha256'] = MODULE['digest'](self.folder/'launch.json')
        return launch

    def test_owned_binary_name_cannot_replace_installed_qemu(self):
        with self.assertRaisesRegex(ValueError, 'protected installed host executable'):
            MODULE['prepare'](self.folder, self.record, self.config)
        self.assertFalse((self.folder/'launch.json').exists())

    def test_unknown_firmware_build_refuses_before_copy(self):
        with self.assertRaisesRegex(ValueError, 'reviewed SMM-required source contract'):
            MODULE['prepare'](self.folder, self.record, self.config, executable_policy=lambda _: None)
        self.assertFalse((self.folder/'firmware-code.fd').exists())

    def test_real_owned_process_socket_files_bound(self):
        launch = self.process_fixture()
        self.assertEqual(check_vm(self.folder, self.record, executable_policy=lambda _: None), self.folder/'qga.sock')
        self.assertFalse(launch['firmwareStoreBindingVerified'])
        self.assertFalse(launch['executableTrustVerified'])
        self.assertFalse(launch['firmwareSourceVerified'])

    def test_wrong_start_time_refuses_pid_reuse(self):
        launch = self.process_fixture(); launch['startTicks'] = '0'
        (self.folder/'launch.json').chmod(0o600); (self.folder/'launch.json').write_text(json.dumps(launch)); (self.folder/'launch.json').chmod(0o400)
        self.record['launchSha256'] = MODULE['digest'](self.folder/'launch.json')
        with self.assertRaisesRegex(ValueError, 'PID was reused'): check_vm(self.folder, self.record, executable_policy=lambda _: None)

    def test_changed_immutable_firmware_refuses(self):
        self.process_fixture(); path = self.folder/'firmware-baseline.fd'; path.chmod(0o600); path.write_bytes(b'changed'); path.chmod(0o400)
        with self.assertRaisesRegex(ValueError, 'firmware source changed'): check_vm(self.folder, self.record, executable_policy=lambda _: None)

    def test_neighbor_socket_cannot_substitute_process_socket(self):
        self.process_fixture(); (self.folder/'qga.sock').unlink()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as neighbor:
            neighbor.bind(str(self.folder/'qga.sock'))
            with self.assertRaisesRegex(ValueError, 'not held by the actual QEMU'): check_vm(self.folder, self.record, executable_policy=lambda _: None)

    def test_arg_spoof_does_not_make_python_qemu(self):
        # exec -a can change argv[0], but /proc/exe remains the actual interpreter.
        self.child = subprocess.Popen(['/bin/bash', '-c', 'exec -a qemu-system-x86_64 /usr/bin/python3 -c "import time;time.sleep(30)" -uuid "$1"', 'fixture', self.record['vmUuid']])
        (self.folder/'qemu.pid').write_text(str(self.child.pid)); (self.folder/'qemu.pid').chmod(0o600)
        with self.assertRaisesRegex(ValueError, 'not one owned QEMU'): check_vm(self.folder, self.record, executable_policy=lambda _: None)

    def test_wrong_nv_export_refuses_before_any_copy(self):
        self.plan['firmwareTrustHashes']['db'] = '0'*64
        path = self.folder/'plan.json'; path.write_text(json.dumps(self.plan)); self.record['planSha256'] = MODULE['digest'](path)
        with self.assertRaisesRegex(ValueError, 'differs from pinned guest export'): MODULE['prepare'](self.folder, self.record, self.config, executable_policy=lambda _: None, firmware_policy=lambda _: None)
        self.assertFalse((self.folder/'firmware-baseline.fd').exists())

    def test_mutating_firmware_copy_refuses(self):
        copy_function = MODULE['shutil'].copyfileobj
        def mutate(reader, writer):
            copy_function(reader, writer); Path(self.config['firmwareCode']['path']).write_bytes(b'changed during copy')
        with patch.object(MODULE['shutil'], 'copyfileobj', mutate):
            with self.assertRaisesRegex(ValueError, 'changed while freezing'): MODULE['prepare'](self.folder, self.record, self.config, executable_policy=lambda _: None, firmware_policy=lambda _: None)
        self.assertFalse((self.folder/'launch.json').exists())

    def test_repeat_prepare_refuses_existing_identity(self):
        MODULE['prepare'](self.folder, self.record, self.config, executable_policy=lambda _: None, firmware_policy=lambda _: None)
        with self.assertRaisesRegex(ValueError, 'already exists'): MODULE['prepare'](self.folder, self.record, self.config, executable_policy=lambda _: None, firmware_policy=lambda _: None)

    def test_oversized_sparse_store_refuses_before_reader_allocation(self):
        path = self.folder/'oversized.fd'
        with path.open('wb') as stream: stream.truncate(17*1024*1024)
        self.assertEqual(path.stat().st_blocks, 0)
        with patch.object(MODULE['os'], 'fdopen', side_effect=AssertionError('reader created before size bound')):
            with self.assertRaisesRegex(ValueError, 'file or size'): MODULE['variables'](path)

    def test_store_change_during_read_refuses(self):
        path = Path(self.config['firmwareStore']['path']); original = path.read_bytes()
        original_fdopen = MODULE['os'].fdopen
        class ChangingReader:
            def __init__(self, stream): self.stream = stream
            def __enter__(self): return self
            def __exit__(self, *args): self.stream.close()
            def fileno(self): return self.stream.fileno()
            def read(self, count):
                raw = self.stream.read(count)
                path.write_bytes(original+b'changed')
                return raw
        with patch.object(MODULE['os'], 'fdopen', side_effect=lambda fd, mode: ChangingReader(original_fdopen(fd, mode))):
            with self.assertRaisesRegex(ValueError, 'changed while reading'): MODULE['variables'](path)

    def test_protected_pflash_and_smm_flags_are_exact(self):
        launch = MODULE['prepare'](self.folder, self.record, self.config, executable_policy=lambda _: None, firmware_policy=lambda _: None)
        self.assertIn('q35,smm=on', launch['argv'])
        self.assertIn('driver=cfi.pflash01,property=secure,value=on', launch['argv'])
        self.assertIn('ICH9-LPC.disable_s3=1', launch['argv'])
        self.assertIn('if=pflash,format=raw,unit=0,readonly=on,file='+str(self.folder/'firmware-code.fd'), launch['argv'])

    def test_unknown_truncated_duplicate_nv_store_refuses(self):
        original = Path(self.config['firmwareStore']['path']).read_bytes()
        duplicate = firmware([('db', MODULE['DB_GUID'], b'first'), ('db', MODULE['DB_GUID'], b'second')])
        for raw in (original[:80], bytes(len(original)), duplicate):
            path = self.folder/'bad-store'; path.write_bytes(raw)
            with self.subTest(size=len(raw)), self.assertRaises(ValueError): MODULE['variables'](path)


if __name__ == '__main__': unittest.main()
