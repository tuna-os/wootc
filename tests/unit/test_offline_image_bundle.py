"""Execute the real shell consumer against bounded OCI byte fixtures."""
import hashlib,json,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
HELPER=ROOT/'payload/deployer/offline-bundle.sh'
class BundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix=".offline-fixture-",dir=ROOT);self.folder=Path(self.tmp.name);self.bundle=self.folder/'bundle'
        self.checker=self.folder/'json-check';subprocess.run(['go','build','-o',str(self.checker),str(ROOT/'payload/json-check/main.go')],check=True)
        self.blobs=self.bundle/'oci/blobs/sha256';self.blobs.mkdir(parents=True)
        self.config=self.blob({'os':'linux','architecture':'amd64'})
        self.layer=self.blob(b'actual layer bytes')
        self.manifest=self.blob({'schemaVersion':2,'mediaType':'application/vnd.oci.image.manifest.v1+json','config':self.config,'layers':[self.layer]})
        (self.bundle/'oci/index.json').write_text(json.dumps({'schemaVersion':2,'manifests':[self.manifest]}))
        (self.bundle/'oci/oci-layout').write_text('{"imageLayoutVersion":"1.0.0"}')
        (self.bundle/'bundle.json').write_text(json.dumps({'image':'example.test/os:tag','digest':self.manifest['digest']}))
    def tearDown(self):self.tmp.cleanup()
    def blob(self,value):
        raw=value if isinstance(value,bytes) else json.dumps(value).encode();digest=hashlib.sha256(raw).hexdigest()
        (self.blobs/digest).write_bytes(raw);return {'digest':'sha256:'+digest,'size':len(raw)}
    def run_helper(self,command='wootc_bundle_validate',prefix=''):
        return subprocess.run(['bash','-c',f'set -euo pipefail; wootc-json-check() {{ "{self.checker}" "$@"; }}; source "$1"; {prefix}; {command} "$2" example.test/os:tag','fixture',str(HELPER),str(self.bundle)],capture_output=True,text=True)
    def test_complete_actual_bytes(self):
        result=self.run_helper(prefix=':');self.assertEqual(result.returncode,0,result.stderr);self.assertIn(self.manifest['digest'],result.stdout)
    def test_corrupt_missing_symlink_and_wrong_pin_refuse_before_pull(self):
        for mode in ('corrupt','missing','symlink','pin'):
            with self.subTest(mode=mode):
                path=self.blobs/self.layer['digest'][7:];original=path.read_bytes()
                if mode=='corrupt':path.write_bytes(b'x'*len(original))
                elif mode=='missing':path.unlink()
                elif mode=='symlink':path.unlink();target=self.folder/'foreign';target.write_bytes(original);path.symlink_to(target)
                else:(self.bundle/'bundle.json').write_text(json.dumps({'image':'example.test/os:tag','digest':'sha256:'+'0'*64}))
                result=self.run_helper('wootc_bundle_ingest','podman() { echo CALLED; return 0; }')
                self.assertNotEqual(result.returncode,0);self.assertNotIn('CALLED',result.stdout)
                if path.is_symlink():path.unlink()
                path.write_bytes(original)
                (self.bundle/'bundle.json').write_text(json.dumps({'image':'example.test/os:tag','digest':self.manifest['digest']}))
    def test_ambiguous_metadata_sizes_and_oversized_config_refuse(self):
        original=(self.bundle/'bundle.json').read_text()
        for raw in ('{"image":"wrong","image":"example.test/os:tag","digest":"'+self.manifest['digest']+'"}',
                    '{"x":{"a":1},"x":{"b":2},"image":"example.test/os:tag","digest":"'+self.manifest['digest']+'"}'):
            (self.bundle/'bundle.json').write_text(raw)
            self.assertNotEqual(self.run_helper(prefix=':').returncode,0)
        (self.bundle/'bundle.json').write_text(original)
        for raw in ('{"size":1.0}','{"size":-1}','{"size":"1"}','{"size":1e2}'):
            r=subprocess.run([str(self.checker),'1024'],input='{"config":'+raw+'}',text=True,capture_output=True)
            self.assertNotEqual(r.returncode,0)
        self.assertNotEqual(subprocess.run([str(self.checker),'1024'],input=b'{"image":"\xff"}',capture_output=True).returncode,0)
        self.assertNotEqual(subprocess.run([str(self.checker),'4'],input='{"x":123}',text=True,capture_output=True).returncode,0)
    def test_failed_plausible_pull_and_unbounded_inspect_never_tag(self):
        for prefix in (
            "timeout() { shift; \"$@\"; }; podman() { printf '%064d\\n' 1; return 7; }",
            "timeout() { shift; \"$@\"; }; podman() { if [[ $1 == pull ]]; then printf '%064d\\n' 1; elif [[ $1 == image ]]; then head -c 2097152 /dev/zero; else echo TAGGED; fi; }"):
            result=self.run_helper('wootc_bundle_ingest',prefix)
            self.assertNotEqual(result.returncode,0);self.assertNotIn('TAGGED',result.stdout)
    def test_selected_digest_cannot_be_replaced_by_metadata(self):
        selected='example.test/os@sha256:'+'0'*64
        (self.bundle/'bundle.json').write_text(json.dumps({'image':selected,'digest':self.manifest['digest']}))
        result=subprocess.run(['bash','-c','source "$1"; checker=$4; wootc-json-check() { "$checker" "$@"; }; wootc_bundle_validate "$2" "$3"','fixture',str(HELPER),str(self.bundle),selected,str(self.checker)],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
    def test_pinned_multiarch_nested_chain_and_ambiguity_controls(self):
        child=dict(self.manifest,mediaType='application/vnd.oci.image.manifest.v1+json',platform={'os':'linux','architecture':'amd64'})
        nested=self.blob({'schemaVersion':2,'mediaType':'application/vnd.oci.image.index.v1+json','manifests':[child]})
        root=self.blob({'schemaVersion':2,'mediaType':'application/vnd.oci.image.index.v1+json','manifests':[dict(nested,mediaType='application/vnd.oci.image.index.v1+json')]})
        selected='example.test/os@'+root['digest']
        (self.bundle/'bundle.json').write_text(json.dumps({'image':selected,'digest':self.manifest['digest'],'sourceDigest':root['digest']}))
        script='source "$1"; checker=$4; wootc-json-check() { "$checker" "$@"; }; wootc_bundle_validate "$2" "$3"'
        command=['bash','-euo','pipefail','-c',script,'fixture',str(HELPER),str(self.bundle),selected,str(self.checker)]
        result=subprocess.run(command,capture_output=True,text=True);self.assertEqual(result.returncode,0,result.stderr)
        leaf_path=self.blobs/self.manifest['digest'][7:];original=leaf_path.read_bytes();leaf_path.write_bytes(original+b' ')
        self.assertNotEqual(subprocess.run(command,capture_output=True).returncode,0);leaf_path.write_bytes(original)
        duplicate=self.blob({'schemaVersion':2,'mediaType':'application/vnd.oci.image.index.v1+json','manifests':[child,child]})
        (self.bundle/'bundle.json').write_text(json.dumps({'image':'example.test/os:tag','digest':self.manifest['digest'],'sourceDigest':duplicate['digest']}))
        self.assertNotEqual(self.run_helper(prefix=':').returncode,0)
    def test_missing_wrong_type_and_overdeep_source_chain_refuse(self):
        child=dict(self.manifest,mediaType='application/vnd.oci.image.manifest.v1+json',platform={'os':'linux','architecture':'amd64'})
        for mode in ('missing','wrongtype','overdeep'):
            with self.subTest(mode=mode):
                if mode=='missing':entry=dict(child,digest='sha256:'+'0'*64)
                elif mode=='wrongtype':entry=dict(child,mediaType='application/vnd.docker.distribution.manifest.v2+json')
                else:entry=child
                for index in range(10 if mode=='overdeep' else 1):
                    ref=self.blob({'schemaVersion':2,'mediaType':'application/vnd.oci.image.index.v1+json','manifests':[entry]})
                    entry=dict(ref,mediaType='application/vnd.oci.image.index.v1+json')
                (self.bundle/'bundle.json').write_text(json.dumps({'image':'example.test/os:tag','digest':self.manifest['digest'],'sourceDigest':ref['digest']}))
                self.assertNotEqual(self.run_helper(prefix=':').returncode,0)
    def test_imported_wrong_identity_cannot_tag(self):
        prefix='''timeout() { shift; "$@"; }; podman() { if [[ $1 == pull ]]; then printf '%064d\\n' 1; elif [[ $1 == image ]]; then echo '[{"Id":"sha256:wrong","Digest":"sha256:wrong"}]'; else echo TAGGED; fi; }'''
        result=self.run_helper('wootc_bundle_ingest',prefix);self.assertNotEqual(result.returncode,0);self.assertNotIn('TAGGED',result.stdout)
    def test_actual_consumer_import_and_tag_require_readback(self):
        identity=json.dumps([{'Id':self.config['digest'],'Digest':self.manifest['digest']}])
        prefix=f'''timeout() {{ shift; "$@"; }}; podman() {{ if [[ $1 == pull ]]; then printf '%064d\\n' 1; elif [[ $1 == image ]]; then printf '%s' '{identity}'; else echo TAGGED; fi; }}'''
        result=self.run_helper('wootc_bundle_ingest',prefix);self.assertEqual(result.returncode,0,result.stderr);self.assertIn('TAGGED',result.stdout)
if __name__=='__main__':unittest.main()
