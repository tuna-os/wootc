import base64,hashlib,importlib.util,json,os,subprocess,tempfile,unittest
from pathlib import Path
PATH=Path(__file__).resolve().parents[1]/'offline-release/plan.py'
SPEC=importlib.util.spec_from_file_location('release_plan',PATH); M=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(M)
class PlanTests(unittest.TestCase):
    def fixture(self):
        blobs={}
        def blob(value):
            raw=json.dumps(value).encode(); digest='sha256:'+hashlib.sha256(raw).hexdigest(); blobs[digest]=raw
            return {'digest':digest,'size':len(raw),'mediaType':value['mediaType']}
        config={'digest':'sha256:'+'c'*64,'size':128,'mediaType':'application/vnd.oci.image.config.v1+json'}
        layer={'digest':'sha256:'+'a'*64,'size':1024,'mediaType':'application/vnd.oci.image.layer.v1.tar+gzip'}
        leaf=blob({'schemaVersion':2,'mediaType':next(iter(M.MANIFEST)),'config':config,'layers':[layer]})
        child=dict(leaf,platform={'os':'linux','architecture':'amd64'})
        root=blob({'schemaVersion':2,'mediaType':next(iter(M.INDEX)),'manifests':[child]})
        return blobs,root,leaf
    def test_current_catalogue_only(self):
        rows=json.loads((PATH.parents[2]/'app/data/images.json').read_text())
        self.assertEqual(M.select(rows,'yellowfin-gnome'),'ghcr.io/tuna-os/yellowfin:gnome')
        for identity in ('yellowfin-kde','missing'):
            with self.assertRaises(ValueError): M.select(rows,identity)
        with self.assertRaises(ValueError): M.select(rows+rows,'yellowfin-gnome')
    def test_exact_root_child_and_sizes(self):
        blobs,root,leaf=self.fixture(); plan=M.resolve(blobs.__getitem__,root['digest'])
        self.assertEqual(plan['digest'],leaf['digest']); self.assertEqual(plan['sourceDigest'],root['digest'])
        self.assertEqual(plan['maximumBlobBytes'],1152+sum(map(len,blobs.values())))
    def test_changed_bytes_and_parent_size(self):
        blobs,root,leaf=self.fixture(); blobs[leaf['digest']]+=b' '
        with self.assertRaises(ValueError): M.resolve(blobs.__getitem__,root['digest'])
        with self.assertRaises(ValueError): M.descriptor({'digest':leaf['digest'],'size':True,'mediaType':'x'},100)
    def test_duplicate_ambiguous_and_quota(self):
        with self.assertRaises(ValueError): M.parse(b'{"x":1,"x":2}')
        with self.assertRaises(ValueError): M.parse(b'{"x":"\xff"}')
        blobs,root,leaf=self.fixture(); value=json.loads(blobs[root['digest']]);value['manifests']*=2
        raw=json.dumps(value).encode(); digest='sha256:'+M.sha(raw);blobs[digest]=raw
        with self.assertRaises(ValueError): M.resolve(blobs.__getitem__,digest)
        for size in (-1,1.0,True,M.MAX_BYTES+1):
            with self.assertRaises(ValueError): M.descriptor(dict(leaf,size=size),M.MAX_BYTES)
    def test_variant_requires_absent_or_empty_string(self):
        for variant in ('absent','',0,False,[],{},None,'v3'):
            blobs,root,leaf=self.fixture(); value=json.loads(blobs[root['digest']])
            if variant!='absent': value['manifests'][0]['platform']['variant']=variant
            raw=json.dumps(value).encode();digest='sha256:'+M.sha(raw);blobs[digest]=raw
            if variant in ('absent',''):
                self.assertEqual(M.resolve(blobs.__getitem__,digest)['digest'],leaf['digest'])
            else:
                with self.assertRaises(ValueError): M.resolve(blobs.__getitem__,digest)
class ActualRouteTests(unittest.TestCase):
    fixture=PlanTests.fixture
    def test_actual_metadata_command_status_and_retained_bytes(self):
        root=PATH.parents[2]
        with tempfile.TemporaryDirectory(prefix='.offline-plan-',dir=root) as temporary:
            folder=Path(temporary); checker=folder/'checker'
            subprocess.run(['go','build','-o',str(checker),str(root/'payload/json-check/main.go')],check=True,timeout=60)
            blobs,index,leaf=self.fixture(); fixture=folder/'fixture.json'
            fixture.write_text(json.dumps({k:base64.b64encode(v).decode() for k,v in blobs.items()}))
            skopeo=folder/'skopeo'
            skopeo.write_text('''#!/usr/bin/env python3
import base64,json,os,sys
values=json.load(open(os.environ['FIXTURE']))
mode=os.environ.get('MODE','good')
if mode=='oversize': sys.stdout.buffer.write(b'x'*1048577);sys.exit(0)
key=sys.argv[-1].split('@')[-1] if '@' in sys.argv[-1] else os.environ['ROOT_DIGEST']
sys.stdout.buffer.write(base64.b64decode(values[key]))
sys.exit(7 if mode=='failed-plausible' else 0)
'''); skopeo.chmod(0o700)
            env=dict(os.environ,PATH=str(folder)+':'+os.environ['PATH'],FIXTURE=str(fixture),ROOT_DIGEST=index['digest'])
            for mode in ('good','failed-plausible','oversize'):
                output=folder/(mode+'.json');env['MODE']=mode
                result=subprocess.run(['python3',str(PATH),'--catalogue-id','yellowfin-gnome','--checker',str(checker),'--output',str(output)],env=env,capture_output=True,timeout=30)
                if mode=='good':
                    self.assertEqual(result.returncode,0,result.stderr)
                    plan=json.loads(output.read_bytes());self.assertEqual(plan['digest'],leaf['digest'])
                    for digest,row in plan['metadata'].items():
                        raw=base64.b64decode(row['rawBase64'],validate=True)
                        self.assertEqual(raw,blobs[digest]);self.assertEqual(M.sha(raw),row['sha256'])
                    self.assertFalse(plan['layerAcquisitionExecuted']);self.assertIsNone(plan['expandedStoreBytes'])
                else:
                    self.assertNotEqual(result.returncode,0);self.assertFalse(output.exists())
if __name__=='__main__': unittest.main()
