#!/usr/bin/env python3
"""Actual typed QMP client, owned paused QEMU and private endpoint controls."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('optical', ROOT/'tests/e2e/qmp-optical-media.py')
OPTICAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OPTICAL)
CD = {'device':'cdrom9','qdev':'/machine/peripheral-anon/device[0]','removable':True,
      'inserted':{'ro':True,'file':'/storage/win11x64.iso'}}
DISK = {'device':'data3','removable':False,'inserted':{'ro':False,'file':'/storage/data.qcow2'}}


class Spy:
    def __init__(self, rows=None, kind='ide-cd', mutation=None, error=None):
        self.rows=copy.deepcopy(rows if rows is not None else [CD,DISK]);self.calls=[]
        self.kind=kind;self.mutation=mutation;self.error=error
    def command(self,name,arguments=None):
        self.calls.append((name,arguments))
        if name==self.error: raise OPTICAL.Refusal('Actual command refusal')
        if name=='query-block': return copy.deepcopy(self.rows)
        if name=='qom-get': return self.kind if arguments['property']=='type' else 9
        if name=='eject':
            if self.mutation=='remain':return {}
            for row in self.rows:
                if row.get('qdev')==arguments['id']:row.pop('inserted',None)
            if self.mutation=='identity':self.rows[0]['device']='replaced'
            return {}
        raise AssertionError(name)


class OpticalTests(unittest.TestCase):
    def test_actual_positive_control_ejects_once_and_never_targets_data(self):
        spy=Spy();receipt=OPTICAL.detach(spy,['/storage/win11x64.iso'])
        self.assertTrue(receipt['empty']);self.assertEqual(receipt['schema'],1)
        ejects=[args for name,args in spy.calls if name=='eject']
        self.assertEqual(ejects,[{'id':CD['qdev'],'force':False}])
        self.assertEqual(spy.rows[1],DISK)

    def test_already_empty_requires_positive_class_and_performs_no_eject(self):
        empty=copy.deepcopy(CD);empty.pop('inserted');spy=Spy([empty,DISK])
        self.assertEqual(OPTICAL.detach(spy,['/storage/win11x64.iso'])['removed'],[])
        self.assertNotIn('eject',[name for name,_ in spy.calls])

    def test_unknown_media_type_or_ambiguous_identity_refuses_before_mutation(self):
        variants=[]
        foreign=copy.deepcopy(CD);foreign['inserted']['file']='/storage/unknown.iso';variants.append([foreign,DISK])
        writable=copy.deepcopy(CD);writable['inserted']['ro']=False;variants.append([writable,DISK])
        no_qdev=copy.deepcopy(CD);no_qdev.pop('qdev');variants.append([no_qdev,DISK])
        variants.extend([[CD,CD],[],[DISK]])
        for rows in variants:
            spy=Spy(rows)
            with self.assertRaises(OPTICAL.Refusal):OPTICAL.detach(spy,['/storage/win11x64.iso'])
            self.assertNotIn('eject',[name for name,_ in spy.calls])
        for kind in ['virtio-blk','floppy','unknown',None]:
            spy=Spy(kind=kind)
            with self.assertRaises(OPTICAL.Refusal):OPTICAL.detach(spy,['/storage/win11x64.iso'])
            self.assertNotIn('eject',[name for name,_ in spy.calls])

    def test_failed_eject_and_plausible_ack_without_empty_readback_refuse(self):
        for spy in [Spy(error='eject'),Spy(mutation='remain'),Spy(mutation='identity')]:
            with self.assertRaises(OPTICAL.Refusal):OPTICAL.detach(spy,['/storage/win11x64.iso'])
            self.assertEqual(len([name for name,_ in spy.calls if name=='eject']),1)

    def test_read_only_current_empty_check_never_ejects_or_repairs_media(self):
        empty=copy.deepcopy(CD);empty.pop('inserted');spy=Spy([empty,DISK])
        value=OPTICAL.check_empty(spy,['/storage/win11x64.iso'])
        self.assertEqual(value['operation'],'check-empty');self.assertEqual(value['removed'],[])
        self.assertNotIn('eject',[name for name,_ in spy.calls])
        for spy in [Spy(),Spy(error='query-block'),Spy([empty,DISK],kind='unknown')]:
            with self.assertRaises(OPTICAL.Refusal):OPTICAL.check_empty(spy,['/storage/win11x64.iso'])
            self.assertNotIn('eject',[name for name,_ in spy.calls])

    def test_read_only_empty_check_refuses_media_reinserted_between_observations(self):
        empty=copy.deepcopy(CD);empty.pop('inserted')
        class Reinsert(Spy):
            def command(self,name,arguments=None):
                value=super().command(name,arguments)
                if name=='query-block':self.rows=copy.deepcopy([CD,DISK])
                return value
        spy=Reinsert([empty,DISK])
        with self.assertRaises(OPTICAL.Refusal):OPTICAL.check_empty(spy,['/storage/win11x64.iso'])
        self.assertNotIn('eject',[name for name,_ in spy.calls])

    def wire(self,response=None,delay=0,timeout=.3,action=None):
        with tempfile.TemporaryDirectory() as tmp:
            path=str(Path(tmp)/'qmp.sock');server=socket.socket(socket.AF_UNIX);server.bind(path);server.listen(1)
            calls=[]
            def serve():
                try:
                    conn,_=server.accept()
                    with conn:
                        conn.sendall(b'{"QMP":{"version":{}}}\n')
                        stream=conn.makefile('rb')
                        for line in stream:
                            request=json.loads(line);calls.append(request)
                            time.sleep(delay)
                            packet=response(request) if callable(response) else response
                            packet=packet or {'return':{},'id':request['id']}
                            if isinstance(packet,bytes):conn.sendall(packet)
                            else:conn.sendall((json.dumps(packet)+'\n').encode())
                except (BrokenPipeError,ConnectionResetError):pass
                finally:server.close()
            thread=threading.Thread(target=serve,daemon=True);thread.start();start=time.monotonic()
            try:
                client=OPTICAL.QMP(path,timeout)
                try:
                    if action=='check-empty':OPTICAL.check_empty(client,['/storage/win11x64.iso'])
                    result=True
                finally:client.close()
            except (OPTICAL.Refusal,OSError):result=False
            elapsed=time.monotonic()-start;thread.join(timeout=1)
            return result,elapsed,calls

    def test_actual_wire_rejects_error_even_with_return_and_wrong_request_id(self):
        for response in [{'return':{},'error':{'class':'GenericError'},'id':'optical-1'},
                         {'return':{},'id':'earlier'},
                         b'{"return":{},"return":{},"id":"optical-1"}\n']:
            result,_,calls=self.wire(response)
            self.assertFalse(result);self.assertEqual(len(calls),1)

    def test_actual_check_empty_wire_refuses_failed_query_with_valid_looking_inventory(self):
        empty=copy.deepcopy(CD);empty.pop('inserted')
        def reply(request):
            if request['execute']=='query-block':
                return {'id':request['id'],'error':{'class':'GenericError'},'return':[empty,DISK]}
            return {'id':request['id'],'return':{}}
        result,_,calls=self.wire(reply,action='check-empty')
        self.assertFalse(result)
        self.assertEqual([item['execute'] for item in calls],['qmp_capabilities','query-block'])

    def test_actual_blocking_socket_obeys_whole_deadline(self):
        result,elapsed,_=self.wire(delay=.5,timeout=.08)
        self.assertFalse(result);self.assertLess(elapsed,.3)

    def test_nonpositive_or_unbounded_timeout_and_public_parent_refuse_before_connect(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=str(Path(tmp)/'qmp.sock');s=socket.socket(socket.AF_UNIX);s.bind(path)
            try:
                for value in [0,-1,16,float('nan'),float('inf')]:
                    with self.assertRaises(OPTICAL.Refusal):OPTICAL.QMP(path,value)
                os.chmod(tmp,0o755)
                with self.assertRaises(OPTICAL.Refusal):OPTICAL.QMP(path,1)
            finally:s.close()

    def test_actual_entrypoint_creates_private_tmpfs_directory_before_qemu(self):
        if not Path('/dev/shm').is_dir():self.skipTest('No tmpfs scratch')
        source=(ROOT/'tests/e2e/build-ssh-image.sh').read_text()
        start=source.index('# The private QMP endpoint')
        body=source[start:source.index('\nwhile true; do',start)]
        with tempfile.TemporaryDirectory(dir='/dev/shm') as tmp:
            script=body.replace('/run/shm',tmp)
            result=subprocess.run(['sh','-c',script],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            private=Path(tmp)/'wootc-control';self.assertEqual(private.stat().st_mode&0o777,0o700)
            private.rmdir();private.symlink_to(tmp)
            self.assertNotEqual(subprocess.run(['sh','-c',script],capture_output=True).returncode,0)
            private.unlink();private.mkdir(mode=0o755)
            self.assertNotEqual(subprocess.run(['sh','-c',script],capture_output=True).returncode,0)
        self.assertIn('-qmp unix:/run/shm/wootc-control/qmp.sock,server=on,wait=off',
                      (ROOT/'tests/e2e/compose.yml').read_text())

    def test_real_paused_qemu_optical_removal_preserves_owned_data_bytes(self):
        binary=shutil.which('qemu-system-x86_64')
        if not binary:self.skipTest('No native QEMU control binary')
        with tempfile.TemporaryDirectory(prefix='wootc-optical-') as tmp:
            root=Path(tmp);iso=root/'owned.iso';iso.write_bytes(b'0'*4096)
            data=root/'owned.raw';original=b'1'*1048576;data.write_bytes(original);endpoint=root/'qmp.sock'
            args=[binary,'-machine','q35,accel=tcg','-m','128','-nodefaults','-display','none','-S',
                  '-qmp',f'unix:{endpoint},server=on,wait=off','-drive',
                  f'file={iso},id=owned-cd,format=raw,readonly=on,media=cdrom,if=none',
                  '-device','ide-cd,drive=owned-cd,bus=ide.0,bootindex=9','-drive',
                  f'file={data},id=owned-data,format=raw,if=none','-device','virtio-blk-pci,drive=owned-data']
            process=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                deadline=time.monotonic()+3
                while not endpoint.exists() and process.poll() is None and time.monotonic()<deadline:time.sleep(.01)
                self.assertTrue(endpoint.exists(),process.stderr.read().decode() if process.poll() is not None else 'Missing QMP')
                client=OPTICAL.QMP(str(endpoint),3)
                try:
                    with self.assertRaises(OPTICAL.Refusal):OPTICAL.detach(client,[str(root/'unknown.iso')])
                    with self.assertRaises(OPTICAL.Refusal):OPTICAL.detach(client,[str(data)])
                    observed=OPTICAL.observe(client,{str(iso)})
                    self.assertEqual(observed[0]['medium'],str(iso))
                    receipt=OPTICAL.detach(client,[str(iso)])
                    current=OPTICAL.check_empty(client,[str(iso)])
                    self.assertEqual(current['operation'],'check-empty')
                    self.assertEqual(current['removed'],[])
                    self.assertEqual(client.command('blockdev-change-medium',{'id':receipt['after'][0]['qdev'],
                                         'filename':str(iso),'format':'raw'}),{})
                    with self.assertRaises(OPTICAL.Refusal):OPTICAL.check_empty(client,[str(iso)])
                    self.assertEqual(OPTICAL.observe(client,{str(iso)})[0]['medium'],str(iso))
                finally:client.close()
                self.assertTrue(receipt['empty']);self.assertEqual(len(receipt['removed']),1)
                self.assertEqual(receipt['before'][0]['type'],'ide-cd')
                self.assertEqual(data.read_bytes(),original)
            finally:
                process.terminate();process.communicate(timeout=3)


if __name__=='__main__':unittest.main()
