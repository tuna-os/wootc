"""Actual private module/unit/activation IO; UID metadata controlled, no service."""
import hashlib
import importlib.util
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]
SPEC=importlib.util.spec_from_file_location('fixtures',ROOT/'tests/unit/test_vm_observer_install_bundle.py')
fixtures=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(fixtures)
bundle=fixtures.bundle

class UnitControls(unittest.TestCase):
 setUp=fixtures.BundleControls.setUp
 def prepare(self):
  value=b'[Service]\nExecStart=/usr/bin/python3 -I -S -B /var/usrlocal/lib/wootc/observer/boot_probe.py\n'
  (self.source/bundle.UNIT_NAME).write_bytes(value);(self.source/bundle.UNIT_NAME).chmod(0o644)
  self.expected[bundle.UNIT_NAME]=hashlib.sha256(value).hexdigest()
 def transaction(self):return bundle.observer_transaction(self.target,self.source,self.expected)
 def test_actual_three_files_and_enable_link_current_readbacks(self):
  self.prepare()
  with self.transaction() as transaction:
   self.assertEqual(transaction['hashes'],self.expected)
   self.assertFalse((self.target/bundle.ENABLE_PATH).exists())
   transaction['enable']()
  self.assertEqual((self.target/bundle.ENABLE_PATH).readlink(),Path('../'+bundle.UNIT_NAME))
  self.assertEqual((self.target/bundle.UNIT_PATH).read_bytes(),(self.source/bundle.UNIT_NAME).read_bytes())
 def test_failed_label_boundary_rolls_back_before_enable(self):
  self.prepare()
  with self.assertRaisesRegex(ValueError,'native label failed'):
   with self.transaction():raise ValueError('native label failed')
  self.assertFalse((self.target/'etc').exists());self.assertFalse((self.target/'var').exists())
  self.assertTrue(all((self.source/name).exists() for name in self.expected))
 def test_missing_or_repeated_activation_refuses_and_rolls_back(self):
  self.prepare()
  with self.assertRaisesRegex(ValueError,'lacks verified activation'):
   with self.transaction():pass
  self.assertFalse((self.target/'etc').exists())
  with self.assertRaisesRegex(ValueError,'must not repeat'):
   with self.transaction() as transaction:
    transaction['enable']();transaction['enable']()
  self.assertFalse((self.target/'etc').exists());self.assertFalse((self.target/'var').exists())
 def test_changed_unit_bytes_before_enable_refuse(self):
  self.prepare()
  with self.assertRaisesRegex(ValueError,'identity changed'):
   with self.transaction() as transaction:
    (self.target/bundle.UNIT_PATH).write_bytes(b'foreign unit')
    transaction['enable']()
  self.assertFalse((self.target/'etc').exists())
 def test_changed_unit_never_publishes_activation_even_temporarily(self):
  self.prepare()
  with self.assertRaisesRegex(ValueError,'lacks verified activation'):
   with self.transaction() as transaction:
    path=self.target/bundle.UNIT_PATH;original=path.read_bytes();path.write_bytes(b'changed')
    with self.assertRaisesRegex(ValueError,'identity changed'):transaction['enable']()
    self.assertFalse((self.target/bundle.ENABLE_PATH).is_symlink())
    path.write_bytes(original)

 def test_existing_unit_collision_preserves_actual_bytes(self):
  self.prepare();parent=(self.target/bundle.UNIT_PATH).parent;parent.mkdir(parents=True,mode=0o755)
  for directory in [parent,parent.parent,parent.parent.parent]:directory.chmod(0o755)
  (self.target/bundle.UNIT_PATH).write_bytes(b'existing unit')
  with self.assertRaisesRegex(ValueError,'collision'):
   with self.transaction():self.fail('transaction invoked')
  self.assertEqual((self.target/bundle.UNIT_PATH).read_bytes(),b'existing unit')
  self.assertFalse((self.target/'var').exists())
 def test_changed_owned_inode_refuses_deleting_foreign_file(self):
  self.prepare()
  with self.assertRaisesRegex(ValueError,'rollback refuses foreign'):
   with self.transaction():
    unit=self.target/bundle.UNIT_PATH
    unit.rename(unit.with_suffix('.retained'))
    unit.write_bytes(b'foreign replacement')
    raise ValueError('stop')
  self.assertEqual((self.target/bundle.UNIT_PATH).read_bytes(),b'foreign replacement')

if __name__=='__main__':unittest.main()
