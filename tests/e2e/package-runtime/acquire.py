"""Acquire only reviewed public package-runtime inputs into an exclusive stage."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = ROOT/'docs/experiments/evidence/2026-09-27-linux-package-runtime'
PLAN = ROOT/'docs/experiments/evidence/2026-09-27-esp-orchestrator/authenticated-dependencies/authenticated-dependency-plan.json'
QUOTA = 1024**3


def sha(path, algorithm='sha256'):
    digest = hashlib.new(algorithm)
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(65536), b''): digest.update(chunk)
    return digest.hexdigest()


def acquire(stage, opener=urllib.request.urlopen):
    stage = Path(stage)
    stage.mkdir(mode=0o700, parents=False, exist_ok=False)
    record = {'schemaVersion':1, 'scratchId':uuid.uuid4().hex, 'stage':str(stage.resolve()),
              'scope':'authorized exact public acquisition only; no VM or host package installation',
              'quotaBytes':QUOTA, 'files':[], 'complete':False, 'runtimeExecuted':False}
    def save():
        temporary = stage/'acquisition.json.tmp'
        with temporary.open('w') as stream:
            json.dump(record,stream,sort_keys=True,indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        temporary.replace(stage/'acquisition.json')
    save()
    try:
        if (sha(PLAN) != 'ada5ba0f52a7c42620a5d0e5b8c2926c452022accd3877b5fe6a436ec3cb83a8' or
                sha(EVIDENCE/'candidate-plan.json') != 'e0e6e11b7f2ff4184f1b155be79610280a548c3af46614a66159b03136099dda'):
            raise ValueError('reviewed acquisition source pins differ')
        source = json.loads(PLAN.read_text())
        candidate = json.loads((EVIDENCE/'candidate-plan.json').read_text())
        wanted = {}
        for phase in source['solverPlans'].values():
            for entry in phase['installs']:
                name = Path(entry['Filename']).name
                value = {'name':name,'size':int(entry['Size']),'algorithm':'sha256','digest':entry['SHA256'],
                         'urls':['https://snapshot.debian.org/archive/debian/'+stamp+'/'+entry['Filename']
                                 for stamp in ('20260914T000000Z','20250801T000000Z')]}
                if name in wanted and wanted[name] != value: raise ValueError('ambiguous package filename')
                wanted[name] = value
        cloud = candidate['cloud']
        wanted['cloud.qcow2'] = {'name':'cloud.qcow2','size':cloud['publishedBytes'],'algorithm':'sha512',
                                'digest':cloud['publishedSha512'],'urls':[cloud['url']]}
        total = sum(entry['size'] for entry in wanted.values())
        if total != 455664032 or total > QUOTA or shutil.disk_usage(stage).free < QUOTA+2*1024**3:
            raise ValueError('acquisition size or current free-space gate differs')
        record['sourcePlanSha256'] = sha(PLAN)
        record['candidatePlanSha256'] = sha(EVIDENCE/'candidate-plan.json')
        record['currentFreeBytes'] = shutil.disk_usage(stage).free
        deadline = time.monotonic()+1800
        for entry in sorted(wanted.values(),key=lambda value:value['name']):
            partial = stage/(entry['name']+'.partial')
            observed = dict(entry, bytes=0, complete=False)
            record['files'].append(observed); save()
            response = None
            for url in entry['urls']:
                remaining = deadline-time.monotonic()
                if remaining <= 0: raise TimeoutError('acquisition deadline expired')
                try:
                    response = opener(url,timeout=min(30,remaining)); observed['url']=url; break
                except urllib.error.HTTPError as error:
                    if error.code != 404: raise
            if response is None: raise ValueError('pinned archive absent at official source locators')
            with response, partial.open('xb') as output:
                while True:
                    if time.monotonic() >= deadline: raise TimeoutError('acquisition deadline expired')
                    chunk = response.read(65536)
                    if not chunk: break
                    observed['bytes'] += len(chunk)
                    if observed['bytes'] > entry['size'] or sum(f['bytes'] for f in record['files']) > QUOTA:
                        raise ValueError('acquisition exceeded exact size or stage quota')
                    output.write(chunk)
                output.flush(); os.fsync(output.fileno())
            if observed['bytes'] != entry['size'] or sha(partial,entry['algorithm']) != entry['digest']:
                raise ValueError('acquired size or published digest differs')
            observed['localSha256'] = sha(partial)
            target = stage/entry['name']; partial.replace(target); target.chmod(0o400)
            observed['complete']=True; save()
        result = subprocess.run(['/usr/bin/qemu-img','info','--output=json',str(stage/'cloud.qcow2')],
                                check=True,capture_output=True,timeout=30)
        image = json.loads(result.stdout)
        if (image.get('format') != 'qcow2' or image.get('backing-filename') or image.get('full-backing-filename') or
                image.get('data-file') or image.get('format-specific',{}).get('data',{}).get('data-file') or
                not 0 < image.get('virtual-size',0) <= 8*1024**3):
            raise ValueError('cloud image is not bounded standalone qcow2')
        record['qemuImgInfo']=image; record['complete']=True; save()
        return record
    except Exception as error:
        record['failureType']=type(error).__name__; record['failure']=str(error); save(); raise


if __name__ == '__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('exclusive_stage');args=parser.parse_args()
    result=acquire(args.exclusive_stage)
    print(json.dumps({'complete':result['complete'],'files':len(result['files']),
                      'bytes':sum(entry['bytes'] for entry in result['files']),
                      'virtualBytes':result['qemuImgInfo']['virtual-size'],'runtimeExecuted':False},sort_keys=True))
