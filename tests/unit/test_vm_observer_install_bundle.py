"""Real disposable file IO with controlled root-ownership metadata only."""
import hashlib
import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

SPEC=importlib.util.spec_from_file_location('bundle',Path(__file__).resolve().parents[2]/'payload/vm-observer/install_bundle.py')
bundle=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(bundle)

class BundleControls(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='wootc-observer-install-');self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name);self.target=self.base/'target';self.source=self.base/'bundle';self.target.mkdir(mode=0o755);self.source.mkdir(mode=0o755)
        self.expected={}
        for name in bundle.FILES:
            value=('reviewed '+name+'\n').encode();(self.source/name).write_bytes(value);(self.source/name).chmod(0o644);self.expected[name]=hashlib.sha256(value).hexdigest()
        actual=Path.lstat
        def facts(p):
            s=actual(p);attrs={n:getattr(s,n) for n in dir(s) if n.startswith('st_')};attrs['st_uid']=0
            if str(p)=='/tmp':attrs['st_mode']=0o40755
            return SimpleNamespace(**attrs)
        self.patch=mock.patch.object(Path,'lstat',facts);self.patch.start();self.addCleanup(self.patch.stop)
    def install(self):return bundle.install_owned_bundle(self.target,self.source,self.expected)
    def test_real_write_readback_and_collision_refusal(self):
        self.assertEqual(self.install(),self.expected)
        with self.assertRaises(ValueError):self.install()
        for name in bundle.FILES:self.assertEqual((self.target/bundle.NAMESPACE/name).read_bytes(),(self.source/name).read_bytes())
    def test_hash_and_link_refusal_before_writes(self):
        self.expected['boot_probe.py']='0'*64
        with self.assertRaises(ValueError):self.install()
        self.assertFalse((self.target/'var').exists())
        (self.source/'boot_probe.py').unlink();(self.source/'boot_probe.py').symlink_to(self.source/'wootc_ancestry.py')
        with self.assertRaises(ValueError):self.install()
        self.assertFalse((self.target/'var').exists())
    def test_actual_failed_write_rolls_back_owned_files_and_directories(self):
        with mock.patch.object(bundle.os,'write',side_effect=OSError('injected disk write refusal')):
            with self.assertRaises(OSError):self.install()
        self.assertFalse((self.target/'var').exists())
        self.assertTrue(all((self.source/name).is_file() for name in bundle.FILES))
    def test_zero_write_progress_refuses_and_rolls_back(self):
        with mock.patch.object(bundle.os,'write',return_value=0):
            with self.assertRaises(OSError):self.install()
        self.assertFalse((self.target/'var').exists())
    def test_fsync_failure_refuses_and_preserves_sources(self):
        with mock.patch.object(bundle.os,'fsync',side_effect=OSError('injected fsync refusal')):
            with self.assertRaises(OSError):self.install()
        self.assertFalse((self.target/'var').exists())
    def test_failed_readback_rolls_back(self):
        actual=bundle.read_owned
        def read(p):return b'changed' if self.target in p.parents else actual(p)
        with mock.patch.object(bundle,'read_owned',side_effect=read):
            with self.assertRaises(ValueError):self.install()
        self.assertFalse((self.target/'var').exists())
    def test_writable_source_actual_mode_refuses(self):
        (self.source/'boot_probe.py').chmod(0o666)
        with self.assertRaises(ValueError):self.install()
        self.assertFalse((self.target/'var').exists())

if __name__=='__main__':unittest.main()
