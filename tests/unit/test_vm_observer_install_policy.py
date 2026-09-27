"""Controlled policy facts; no target image invocation or installation."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock

SPEC=importlib.util.spec_from_file_location('install_policy',Path(__file__).resolve().parents[2]/'payload/vm-observer/install_policy.py')
policy=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(policy)

class PolicyControls(unittest.TestCase):
    def evaluate(self, conf=None, boot=None):
        files={} if conf is None else {'/target/usr/lib/composefs/setup-root-conf.toml':conf.encode()}
        def optional(p):return files.get(str(p))
        with mock.patch.object(policy.Path,'lstat',return_value=SimpleNamespace(st_mode=0o40755,st_uid=0)),mock.patch.object(policy,'read_optional',side_effect=optional),mock.patch.object(policy.os.path,'lexists',return_value=False):
            return policy.validate_persistence('/target',['options ostree=/ostree/deploy/default rw'] if boot is None else boot)
    def test_default_persistent_configuration_only(self):
        self.assertEqual(self.evaluate(),{'etcPersistent':True,'varPersistent':True,'configurationOnly':True})
        self.assertTrue(self.evaluate('[etc]\nmount="overlay"\n[var]\nmount="bind"')['varPersistent'])
    def test_transient_unknown_or_malformed_refuses(self):
        for conf in ['[etc]\ntransient=true','[root]\ntransient=true','[var]\nmount="none"','[etc]\nmount="root"','[etc]\nmount="unknown"','[etc]\ntransient="false"','[etc]\nmount="bind"\nmount="none"']:
            with self.subTest(conf=conf),self.assertRaises((ValueError,TypeError)):self.evaluate(conf)
    def test_actual_installed_boot_arguments_required(self):
        for boot in [[],{},['options systemd.volatile=state'],['rd.systemd.volatile=yes'],[True]]:
            with self.subTest(boot=boot),self.assertRaises((ValueError,TypeError)):self.evaluate(boot=boot)
        self.assertTrue(self.evaluate(boot=['options systemd.volatile=no'])['configurationOnly'])
    def test_actual_unprotected_namespace_refuses(self):
        # /tmp is actually writable by ordinary users; no metadata mocks here.
        with self.assertRaises(ValueError):policy.validate_persistence('/tmp',['options rw'])
    def test_real_link_dependency_refuses(self):
        with self.assertRaises(ValueError):policy.protected_read('/proc/self/exe')

if __name__=='__main__':unittest.main()
