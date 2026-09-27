"""Execute the fixed installer caller with controlled offline observations.

No target chroot, native mount, labeling, service or image is invoked.
"""
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import runpy
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
ENTRY=runpy.run_path(str(ROOT/'payload/vm-observer/installer_entry.py'))
GRAPH=runpy.run_path(str(ROOT/'payload/vm-observer/install_graph.py'))
COMMAND=runpy.run_path(str(ROOT/'payload/vm-observer/installer_commands.py'))
DISK='11111111-1111-1111-1111-111111111111'

class InstallerCallerControls(unittest.TestCase):
    def setUp(self):
        self.events=[];self.failed_command=False;self.wrong_disk=False;self.final_image_changed=False;self.label_failure=False
        info=Path('/').stat()
        self.args=SimpleNamespace(catalogue_sha256='a'*64,input_inode=str(info.st_dev)+':'+str(info.st_ino),input_source='rootfs[/usr/lib/wootc-observer]',input_major='0:1',root_major='8:3',boot_major='8:2',disk=DISK,image='ghcr.io/example/image@sha256:'+'a'*64,run_id='run_test123',install_id='install_test123')
        self.selected={'deployment':'/','stateVar':'/var','image':self.args.image,'bls':{'options':'root=UUID=selected'}}
        self.environment={'interpreter':'/usr/bin/python3','stdlibRoots':['/usr/lib/python3'],'loadedDependencies':{'/usr/bin/python3':'a'*64},'mappedDependencies':['/usr/bin/python3']}
        @contextmanager
        def transaction(*_):
            self.events.append('write')
            yield {'enable':lambda:self.events.append('enable'),'objects':lambda:[{}]}
            self.events.append('commit')
        def labels(*_):
            self.events.append('label')
            if self.label_failure:raise ValueError('actual native labeling refusal')
            return {'configuredMode':'disabled','labelsRequired':False,'labels':{}}
        def selection(*_):
            self.events.append('selection')
            return dict(self.selected,image='foreign') if self.final_image_changed and self.events.count('selection')>1 else self.selected
        self.modules={'python_environment.py':{'inspect_environment':lambda:self.environment,'protected_path':lambda p:(None,Path(p))},
          'install_bundle.py':{'directory':lambda p:None,'read_owned':lambda p:b'protected','observer_transaction':transaction},
          'installer_commands.py':COMMAND,'deployment_selection.py':{'select_installed_deployment':selection},
          'boot_probe.py':{'_run_owned':self.run_command},'install_policy.py':{'validate_persistence':lambda *_:{'etcPersistent':True,'varPersistent':True,'configurationOnly':True}},
          'label_policy.py':{'label_transaction_objects':labels},'install_graph.py':GRAPH}
    def run_command(self,argv,deadline):
        self.events.append('query')
        if self.failed_command:raise ValueError('successful status required despite plausible stdout')
        if argv[0]=='/usr/sbin/matchpathcon':return 'system_u:object_r:usr_t:s0'
        if '--mountpoint' in argv:
            target=argv[-1]
            major='0:1' if target==str(ENTRY['INPUT']) else '8:2' if target.endswith('/boot') else '8:3'
            source=self.args.input_source if major=='0:1' else '/dev/vda2' if major=='8:2' else '/dev/vda3'
            return json.dumps({'filesystems':[{'target':target,'source':source,'maj:min':major,'fstype':'rootfs' if major=='0:1' else 'ext4','options':'rw' if target=='/var' else 'ro'}]})
        return json.dumps({'blockdevices':[{'name':'/dev/vda','type':'disk','maj:min':'8:0','ptuuid':'22222222-2222-2222-2222-222222222222' if self.wrong_disk else DISK,'children':[{'name':'/dev/vda2','type':'part','maj:min':'8:2','ptuuid':None},{'name':'/dev/vda3','type':'part','maj:min':'8:3','ptuuid':None}]}]})
    def test_full_caller_orders_observations_before_owned_transaction_and_labels_before_commit(self):
        # The mount target is fixed in observed_mount, so INPUT must retain that
        # exact target while the controlled inode readback is supplied separately.
        with patch.object(Path,'lstat',return_value=Path('/').stat()):
            with patch.dict(ENTRY['install'].__globals__,{'load_catalogue':lambda _:({name:'a'*64 for name in ENTRY['FILES']},{name:b'fixed' for name in ENTRY['FILES']}),'load_module':lambda name,raw:self.modules[name]}):
                result=ENTRY['install'](self.args)
        self.assertEqual(self.events[-3:],['label','selection','commit'])
        self.assertLess(self.events.index('selection'),self.events.index('write'))
        self.assertTrue(result['installed']);self.assertFalse(result['guestBootAccepted'])
    def test_actual_entry_composes_real_enforcing_label_consumer(self):
        fixture_module=runpy.run_path(str(ROOT/'tests/unit/test_vm_observer_transaction_labels.py'))
        fixture=fixture_module['LabelControls']('test_native_calls_cover_exact_new_directory_and_activation_link')
        fixture.setUp()
        try:
            self.args.input_inode='1:999'
            actual_labels=fixture_module['labels']
            self.modules['label_policy.py']={'label_transaction_objects':actual_labels.label_transaction_objects}
            self.modules['install_bundle.py']['read_owned']=fixture.read
            @contextmanager
            def transaction(*_):
                self.events.append('write')
                yield {'enable':lambda:self.events.append('enable'),'objects':lambda:fixture.objects}
                self.events.append('commit')
            self.modules['install_bundle.py']['observer_transaction']=transaction
            with patch.dict(ENTRY['install'].__globals__,{'load_catalogue':lambda _:({name:'a'*64 for name in ENTRY['FILES']},{name:b'fixed' for name in ENTRY['FILES']}),'load_module':lambda name,raw:self.modules[name]}):
                receipt=ENTRY['install'](self.args)
            self.assertTrue(receipt['labels']['labelsRequired'])
            self.assertEqual(set(receipt['labels']['labels']),set(fixture.lookup))
            self.assertEqual(set(fixture.writes),set(fixture.lookup))
            self.assertIn('commit',self.events)
        finally:fixture.doCleanups()
        adapter=ENTRY['label_tool_adapter']({'findmnt':Path('/usr/bin/findmnt'),'matchpathcon':Path('/usr/sbin/matchpathcon')})
        with self.assertRaises(ValueError):adapter('/var/home/user/matchpathcon')

    def test_failed_status_and_wrong_selected_gpt_refuse_before_write(self):
        for key in ('failed_command','wrong_disk'):
            self.setUp();setattr(self,key,True)
            with patch.object(Path,'lstat',return_value=Path('/').stat()):
                with patch.dict(ENTRY['install'].__globals__,{'load_catalogue':lambda _:({name:'a'*64 for name in ENTRY['FILES']},{name:b'fixed' for name in ENTRY['FILES']}),'load_module':lambda name,raw:self.modules[name]}):
                    with self.assertRaises(ValueError):ENTRY['install'](self.args)
            self.assertNotIn('write',self.events)
    def test_label_or_final_selection_refusal_never_commits(self):
        for key in ('label_failure','final_image_changed'):
            self.setUp();setattr(self,key,True)
            with patch.object(Path,'lstat',return_value=Path('/').stat()):
                with patch.dict(ENTRY['install'].__globals__,{'load_catalogue':lambda _:({name:'a'*64 for name in ENTRY['FILES']},{name:b'fixed' for name in ENTRY['FILES']}),'load_module':lambda name,raw:self.modules[name]}):
                    with self.assertRaises(ValueError):ENTRY['install'](self.args)
            self.assertIn('write',self.events);self.assertNotIn('commit',self.events)

if __name__=='__main__':unittest.main()
