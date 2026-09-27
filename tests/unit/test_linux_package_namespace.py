"""Component failure/ordering controls; actual privileged positive probe belongs to source CI."""
import ctypes
import errno
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/host-namespace.py'))


class NamespaceTests(unittest.TestCase):
    def test_actual_missing_prefix_never_claims_namespace_or_source(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):MODULE['checked'](Path(folder))

    def test_kernel_unshare_refusal_cannot_call_any_mount(self):
        class Libc:
            def __init__(self):self.mounts=[]
            def unshare(self,flags):
                self.flags=flags;ctypes.set_errno(errno.EPERM);return -1
            def mount(self,*args):self.mounts.append(args);return 0
        libc=Libc()
        with patch.dict(MODULE['_private_namespace'].__globals__,{'checked':lambda *_:{}}),patch.object(ctypes,'CDLL',lambda *args,**kwargs:libc):
            with self.assertRaises(OSError) as caught:MODULE['_private_namespace']('/run/fixture')
        self.assertEqual(caught.exception.errno,errno.EPERM);self.assertEqual(libc.flags,0x00020000)
        self.assertEqual(libc.mounts,[])

    def test_private_propagation_refusal_cannot_bind_any_data(self):
        class Libc:
            def __init__(self):self.mounts=[]
            def unshare(self,flags):return 0
            def mount(self,*args):self.mounts.append(args);ctypes.set_errno(errno.EPERM);return -1
        libc=Libc()
        with patch.dict(MODULE['_private_namespace'].__globals__,{'checked':lambda *_:{}}),patch.object(ctypes,'CDLL',lambda *args,**kwargs:libc):
            with self.assertRaises(OSError):MODULE['_private_namespace']('/run/fixture')
        self.assertEqual(len(libc.mounts),1)
        self.assertEqual(libc.mounts[0][0],None);self.assertEqual(libc.mounts[0][1],b'/')
        self.assertEqual(libc.mounts[0][3],(1<<14)|(1<<18))


if __name__=='__main__':unittest.main()
