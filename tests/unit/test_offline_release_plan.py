import hashlib,importlib.util,json,unittest
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
if __name__=='__main__': unittest.main()
