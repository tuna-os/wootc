#!/usr/bin/env python3
"""Resolve metadata only. This does not acquire layers or authenticate a publisher."""
import argparse, hashlib, json, re, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
INDEX={'application/vnd.oci.image.index.v1+json','application/vnd.docker.distribution.manifest.list.v2+json'}
MANIFEST={'application/vnd.oci.image.manifest.v1+json','application/vnd.docker.distribution.manifest.v2+json'}
MAX_BYTES=12*1024**3

def sha(raw): return hashlib.sha256(raw).hexdigest()
def pairs(values):
    result={}
    for key,value in values:
        if key in result: raise ValueError('duplicate metadata key')
        result[key]=value
    return result

def parse(raw):
    if len(raw)>1048576: raise ValueError('metadata exceeds bound')
    return json.loads(raw.decode('utf-8'),object_pairs_hook=pairs)

def descriptor(value,limit):
    if not isinstance(value,dict) or not re.fullmatch(r'sha256:[0-9a-f]{64}',value.get('digest','')): raise ValueError('invalid descriptor digest')
    size=value.get('size')
    if type(size) is not int or not 0<size<=limit or not isinstance(value.get('mediaType'),str): raise ValueError('invalid descriptor size/type')
    return value

def select(catalogue,identity):
    matches=[row for row in catalogue if row.get('id')==identity]
    if len(matches)!=1 or matches[0].get('status')!='green': raise ValueError('selection is not a unique green catalogue entry')
    ref=matches[0]['imageRef']
    if not re.fullmatch(r'ghcr.io/[a-z0-9._/-]+:[a-z0-9._-]+',ref): raise ValueError('unsupported catalogue registry reference')
    return ref

def resolve(fetch,root_digest):
    metadata={}; leaves=[]
    def walk(digest,depth,expected=None):
        if depth>8 or len(metadata)>=64: raise ValueError('metadata graph bound')
        raw=fetch(digest)
        if 'sha256:'+sha(raw)!=digest: raise ValueError('registry bytes differ from pin')
        value=parse(raw); kind=value.get('mediaType')
        if type(value.get('schemaVersion')) is not int or value['schemaVersion']!=2: raise ValueError('unknown schema')
        if expected and (len(raw)!=expected['size'] or kind!=expected['mediaType']): raise ValueError('parent descriptor mismatch')
        metadata[digest]={'size':len(raw),'mediaType':kind,'sha256':sha(raw)}
        if kind in INDEX:
            children=value.get('manifests')
            if not isinstance(children,list) or not 0<len(children)<=64: raise ValueError('invalid index')
            candidates=[]
            for child in children:
                descriptor(child,1048576)
                platform=child.get('platform')
                if platform=={'os':'linux','architecture':'amd64'} or (isinstance(platform,dict) and platform.get('os')=='linux' and platform.get('architecture')=='amd64' and not platform.get('variant')) or (platform is None and child['mediaType'] in INDEX): candidates.append(child)
            if not candidates: raise ValueError('selected platform absent')
            for child in candidates: walk(child['digest'],depth+1,child)
        elif kind in MANIFEST:
            config=descriptor(value.get('config'),16*1024**2)
            layers=value.get('layers')
            if not isinstance(layers,list) or not 0<len(layers)<=1024: raise ValueError('invalid layers')
            for layer in layers: descriptor(layer,MAX_BYTES)
            leaves.append((digest,config,layers))
        else: raise ValueError('unsupported manifest media type')
    walk(root_digest,0)
    if len(leaves)!=1: raise ValueError('selected platform ambiguous')
    child,config,layers=leaves[0]
    total=sum(row['size'] for row in layers)+config['size']+sum(row['size'] for row in metadata.values())
    if total>MAX_BYTES: raise ValueError('compressed acquisition exceeds 12 GiB')
    return {'sourceDigest':root_digest,'digest':child,'config':config,'layers':layers,'metadata':metadata,'maximumBlobBytes':total}

def main():
    args=argparse.ArgumentParser(); args.add_argument('--catalogue-id',required=True); args.add_argument('--root-digest',default=''); args.add_argument('--checker',required=True); args.add_argument('--output',required=True); options=args.parse_args()
    if options.root_digest and not re.fullmatch(r'sha256:[0-9a-f]{64}',options.root_digest): raise ValueError('root digest required')
    catalogue=ROOT/'app/data/images.json'; raw=catalogue.read_bytes(); ref=select(parse(raw),options.catalogue_id); repository=ref.rsplit(':',1)[0]
    deadline=time.monotonic()+600
    def observe(reference):
        remaining=deadline-time.monotonic()
        if remaining<=0: raise TimeoutError('metadata deadline spent')
        # A bounded pipe exposes overlong output and nonzero producer status.
        result=subprocess.run(['bash','-o','pipefail','-c','timeout "$1" skopeo inspect --raw "docker://$2" | head -c 1048577','metadata',str(min(120,remaining)),reference],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=remaining)
        if result.returncode: raise ValueError('registry metadata observation failed')
        subprocess.run([options.checker,'1048576'],input=result.stdout,check=True,timeout=max(.01,deadline-time.monotonic()))
        return result.stdout
    root_raw=observe(repository+'@'+options.root_digest if options.root_digest else ref)
    root_digest='sha256:'+sha(root_raw)
    if options.root_digest and root_digest!=options.root_digest: raise ValueError('observed root differs from requested pin')
    def fetch(digest):
        return root_raw if digest==root_digest else observe(repository+'@'+digest)
    plan=resolve(fetch,root_digest)
    plan.update(schemaVersion=1,catalogueId=options.catalogue_id,catalogueSha256=sha(raw),catalogueRef=ref,image=repository+'@'+root_digest,sourceCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),scratchQuotaBytes=40*1024**3,minimumFreeBytes=48*1024**3,publisherAuthentication=False,selectedOsBootAcceptance=False,windowsStagingAcceptance=False,layerAcquisitionExecuted=False,expandedStoreBytes=None,storageQualification='Compressed bytes are observed descriptors; expanded store is unknown. A later owned 40 GiB filesystem and reserve monitor must refuse exhaustion. This metadata plan does not qualify execution.',sourceHashes={str(p.relative_to(ROOT)):sha(p.read_bytes()) for p in [Path(__file__),ROOT/'payload/bundle/make-bundle.sh',ROOT/'payload/deployer/offline-bundle.sh',ROOT/'payload/json-check/main.go']})
    with open(options.output,'x') as stream: json.dump(plan,stream,sort_keys=True,indent=2); stream.write('\n')
if __name__=='__main__': main()
