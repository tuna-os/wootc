#!/usr/bin/env python3
"""Real local OCI import/readback; no registry, selected OS boot or VM."""
import gzip,hashlib,io,json,os,subprocess,sys,tarfile,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def run(command,**kwargs):
    result=subprocess.run(command,capture_output=True,text=True,timeout=60,**kwargs)
    if result.returncode:raise RuntimeError(str(command[:2])+': '+result.stderr[-4096:])
    return result
def main():
    with tempfile.TemporaryDirectory(prefix='.offline-native-',dir=ROOT) as temporary, tempfile.TemporaryDirectory(prefix='woci-') as runtime:
        folder=Path(temporary);bundle=folder/'bundle';blobs=bundle/'oci/blobs/sha256';blobs.mkdir(parents=True)
        def blob(raw,kind):
            digest=hashlib.sha256(raw).hexdigest();(blobs/digest).write_bytes(raw)
            return {'digest':'sha256:'+digest,'size':len(raw),'mediaType':kind}
        buffer=io.BytesIO()
        with tarfile.open(fileobj=buffer,mode='w') as archive:
            item=tarfile.TarInfo('proof');item.size=5;archive.addfile(item,io.BytesIO(b'proof'))
        docker='--docker' in sys.argv
        diff_id='sha256:'+hashlib.sha256(buffer.getvalue()).hexdigest()
        layer=blob(gzip.compress(buffer.getvalue(),mtime=0) if docker else buffer.getvalue(),'application/vnd.docker.image.rootfs.diff.tar.gzip' if docker else 'application/vnd.oci.image.layer.v1.tar')
        config=blob(json.dumps({'architecture':'amd64','os':'linux','config':{},'rootfs':{'type':'layers','diff_ids':[diff_id]}}).encode(),'application/vnd.docker.container.image.v1+json' if docker else 'application/vnd.oci.image.config.v1+json')
        manifest_type='application/vnd.docker.distribution.manifest.v2+json' if docker else 'application/vnd.oci.image.manifest.v1+json'
        manifest=blob(json.dumps({'schemaVersion':2,'mediaType':manifest_type,'config':config,'layers':[layer]}).encode(),manifest_type)
        (bundle/'oci/index.json').write_text(json.dumps({'schemaVersion':2,'manifests':[manifest]}))
        (bundle/'oci/oci-layout').write_text('{"imageLayoutVersion":"1.0.0"}')
        selected='localhost/wootc-offline-native:fixed'
        (bundle/'bundle.json').write_text(json.dumps({'image':selected,'digest':manifest['digest']}))
        checker=folder/'json-check';run(['go','build','-o',str(checker),str(ROOT/'payload/json-check/main.go')])
        podman=['/usr/bin/podman','--root',str(folder/'store'),'--runroot',runtime,'--storage-driver','vfs']
        (folder/'bin').mkdir(); wrapper=folder/'bin/podman';wrapper.write_text('#!/bin/bash\nexec /usr/bin/podman --root "$STORE" --runroot "$RUN" --storage-driver vfs "$@"\n');wrapper.chmod(0o700)
        script='source "$HELPER"; wootc-json-check() { "$CHECKER" "$@"; }; wootc_bundle_ingest "$BUNDLE" "$SELECTED"'
        env=dict(os.environ,PATH=str(folder/"bin")+":"+os.environ["PATH"],HELPER=str(ROOT/'payload/deployer/offline-bundle.sh'),CHECKER=str(checker),STORE=str(folder/'store'),RUN=runtime,BUNDLE=str(bundle),SELECTED=selected)
        producer_status=None
        if '--producer' in sys.argv:
            # Only the registry boundary is redirected to the bounded local
            # OCI fixture. Actual skopeo raw inspect/copy and producer run.
            skopeo=folder/'bin/skopeo'
            skopeo.write_text('#!/bin/bash\nargs=(); for arg in "$@"; do if [[ "$arg" == docker://* ]]; then arg="oci:$BUNDLE/oci"; fi; args+=("$arg"); done; exec /usr/bin/skopeo "${args[@]}"\n')
            skopeo.chmod(0o700);(folder/'bin/wootc-json-check').symlink_to(checker)
            produced=folder/'produced'
            producer_status=run(['bash',str(ROOT/'payload/bundle/make-bundle.sh'),selected,str(produced)],env=env).returncode
            metadata=json.loads((produced/'bundle.json').read_text())
            if metadata['digest']!=manifest['digest'] or metadata['sourceDigest']!=manifest['digest']:raise ValueError('actual producer root/child pin differs')
            env['BUNDLE']=str(produced);blobs=produced/'oci/blobs/sha256'
        result=run(['bash','-euo','pipefail','-c',script],env=env)
        observed=json.loads(run(podman+['image','inspect',selected]).stdout)
        if len(observed)!=1 or observed[0]['Digest']!=manifest['digest'] or observed[0]['Id']!=config['digest'][7:]:raise ValueError('actual imported identity differs')
        # Corrupt the actual layer and run the actual consumer again. It must
        # fail; prior local image presence cannot authorize invalid bundle bytes.
        (blobs/layer['digest'][7:]).write_bytes(b'x'*layer['size'])
        refusal=subprocess.run(['bash','-euo','pipefail','-c',script],env=env,capture_output=True,text=True,timeout=60)
        if not refusal.returncode:raise ValueError('actual corrupt source accepted')
        print(json.dumps({'schemaVersion':1,'scope':'native local OCI byte import/readback only','sourceHashes':{str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in (ROOT/'payload/deployer/offline-bundle.sh',ROOT/'payload/json-check/main.go',Path(__file__))},'manifestMediaType':manifest_type,'producerExitStatus':producer_status,'producerRegistryBoundary':'redirected to native OCI fixture' if producer_status is not None else None,'podmanVersion':run(['/usr/bin/podman','--version']).stdout.strip(),'manifestDigest':manifest['digest'],'configDigest':config['digest'],'observedDigest':observed[0]['Digest'],'observedImageId':observed[0]['Id'],'importExitStatus':result.returncode,'corruptionRefusalStatus':refusal.returncode,'selectedOsBootAcceptance':False,'publisherAuthentication':False,'firmwareAcceptance':False,'vmExecuted':False},sort_keys=True))
if __name__=='__main__':main()
