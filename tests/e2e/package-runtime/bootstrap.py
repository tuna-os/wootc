"""Guest-only NoCloud package proof; no host-package or VM launcher entry point."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import stat
import struct
import subprocess
import tempfile
import time

PREFIX = 'WOOTC_PACKAGE_RUNTIME_V1 '


def disk_serial(scratch_id,challenge):
    if not re.fullmatch('[0-9a-f]{32}',scratch_id) or not re.fullmatch('[0-9a-f]{64}',challenge):
        raise ValueError('complete scratch/challenge disk binding required')
    # Virtio GET_ID carries at most20 bytes. Hash every input byte, and retain
    # the full independent scratch/challenge/VM identities in the manifest.
    return hashlib.sha256(('wootc-package-disk-v1\0'+scratch_id+'\0'+challenge).encode('ascii')).hexdigest()[:20]


class RootIdentityRefusal(ValueError):
    def __init__(self,facts):
        super().__init__('actual root ancestry differs from owned scratch disk')
        self.root_identity_facts=facts


def root_identity(devices,expected):
    if not re.fullmatch('[0-9a-f]{20}',expected):raise ValueError('bounded exact disk serial required')
    roots=[];visited=0
    def walk(rows,serial=None,disk=None,depth=0):
        nonlocal visited
        if depth>32 or len(rows)>128:raise ValueError('root ancestry table exceeds bound')
        for device in rows:
            visited+=1
            if visited>256:raise ValueError('root ancestry node count exceeds bound')
            name=device.get('name');kind=device.get('type');observed=device.get('serial')
            if not isinstance(name,str) or len(name)>128 or (observed is not None and (not isinstance(observed,str) or len(observed)>128)):
                raise ValueError('root ancestry field exceeds bound')
            if kind=='disk':current=observed;owner=name
            elif kind=='part' and disk is not None:current=serial;owner=disk
            else:current=None;owner=None
            if '/' in (device.get('mountpoints') or []):
                roots.append({'rootDevice':name,'rootType':kind,'diskDevice':owner,'serial':current})
            walk(device.get('children',[]),current,owner,depth+1)
    walk(devices)
    facts={'expectedSerial':expected,'roots':roots}
    if len(json.dumps(facts))>8192:raise ValueError('root ancestry facts exceed bound')
    if len(roots)!=1 or roots[0]['serial']!=expected:raise RootIdentityRefusal(facts)
    return facts


def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def boot_id():
    value = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    if not re.fullmatch('[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',value):
        raise ValueError('current kernel boot identity malformed')
    return value


def canonical_inventory(value):
    return hashlib.sha256((json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()).hexdigest()


def atomic_result(workspace,name,data):
    with tempfile.NamedTemporaryFile(dir=workspace,delete=False) as stream:
        stream.write((json.dumps(data,sort_keys=True)+'\n').encode());stream.flush();os.fsync(stream.fileno())
        temporary=Path(stream.name)
    temporary.chmod(0o600);temporary.replace(workspace/name)
    descriptor=os.open(workspace,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)


def wait_advance(workspace,common,observe_boot=boot_id,seconds=300):
    deadline=time.monotonic()+seconds
    path=Path(workspace)/'advance-old.json'
    while time.monotonic()<deadline:
        if observe_boot()!=common['bootId']:raise ValueError('boot changed during phase handshake')
        if path.exists():
            if path.is_symlink() or path.stat().st_size>4096:raise ValueError('invalid phase acknowledgement file')
            value=json.loads(path.read_text())
            for name in ('scratchId','challenge','bootId','seedSha256'):
                if value.get(name)!=common[name]:raise ValueError('phase acknowledgement identity differs')
            if (value.get('validatedPhase')!='old' or
                    not re.fullmatch('[0-9a-f]{64}',value.get('readbackChallenge','')) or
                    value['readbackChallenge']==common['challenge'] or
                    not re.fullmatch('[0-9a-f]{64}',value.get('approvedReadbackSha256',''))):
                raise ValueError('independent approved old phase acknowledgement required')
            return value
        time.sleep(min(.1,max(0,deadline-time.monotonic())))
    raise TimeoutError('old phase independent observation acknowledgement deadline expired')


def run(seed, workspace, emit, observe_boot=boot_id, read_module=runpy.run_path,
        environment=None,advance_wait=None):
    """Injected boundaries exist for native tests; CLI always uses real guest reads."""
    seed, workspace = Path(seed), Path(workspace)
    manifest = json.loads((seed/'manifest.json').read_text())
    if (type(manifest.get('schemaVersion')) is not int or manifest.get('schemaVersion') != 1 or
            not re.fullmatch('[0-9a-f]{32}',manifest.get('scratchId','')) or
            not re.fullmatch('[0-9a-f]{64}',manifest.get('challenge','')) or
            not re.fullmatch('[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',manifest.get('vmUuid',''))):
        raise ValueError('incomplete fresh guest manifest')
    if manifest.get('diskSerial')!=disk_serial(manifest['scratchId'],manifest['challenge']):
        raise ValueError('manifest disk serial differs from full scratch/challenge binding')
    hashes = manifest['helperHashes']
    required = {'bootstrap.py','package-consumer.py','packages.json','readback.py','advance.py'}
    if set(hashes) != required or any(not re.fullmatch('[0-9a-f]{64}',value) for value in hashes.values()):
        raise ValueError('complete helper closure required')
    if sha(__file__) != hashes['bootstrap.py']:
        raise ValueError('executing helper differs from pinned seed closure')
    for name,expected in hashes.items():
        path = seed/name
        if path.is_symlink() or not path.is_file() or sha(path)!=expected:
            raise ValueError('guest helper source differs')
    if environment is None: environment = actual_environment
    facts = environment(manifest,seed)
    if not re.fullmatch('[0-9a-f]{64}',facts.get('seedSha256','')):
        raise ValueError('actual seed digest missing')
    initial_boot = observe_boot()
    module = read_module(str(seed/'package-consumer.py'))
    policy = json.loads((seed/'packages.json').read_text())
    if policy['scratchId'] != manifest['scratchId']:
        raise ValueError('guest policy scratch identity differs')
    expected = policy['phases']['old']['beforeInventory']
    actual = module['inventory'](module['execute'])
    if actual != expected or canonical_inventory(actual) != manifest['baselineSha256']:
        raise ValueError('actual baseline inventory differs')
    if observe_boot()!=initial_boot: raise ValueError('boot changed across baseline observation')
    if workspace.exists(): raise ValueError('guest workspace is not exclusive')
    workspace.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    parent=workspace.parent.lstat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid!=os.geteuid() or parent.st_mode&0o022:
        raise ValueError('guest workspace parent is unowned or writable')
    workspace.mkdir(mode=0o700)
    common = {'schemaVersion':1,'scratchId':manifest['scratchId'],'challenge':manifest['challenge'],
              'bootId':initial_boot,'helperHashes':hashes,'policySha256':hashes['packages.json'],
              'seedSha256':facts['seedSha256']}
    def publication(stage, inventory, status):
        if observe_boot()!=initial_boot: raise ValueError('boot changed across package operation')
        data = dict(common,stage=stage,inventory=inventory,inventorySha256=canonical_inventory(inventory),
                    exitStatus=status)
        atomic_result(workspace,'phase-result.json',data)
        emit(data)
        return data
    publication('baseline-observed',actual,0)
    (workspace/'packages.json').write_bytes((seed/'packages.json').read_bytes())
    (workspace/'packages.json').chmod(0o600)
    (workspace/'ownership.json').write_text(json.dumps({'scope':'exclusive-classic-qa-root',
        'scratchId':manifest['scratchId'],'policySha256':hashes['packages.json']}))
    (workspace/'ownership.json').chmod(0o600)
    unique = {}
    for phase in policy['phases'].values():
        for entry in phase['packages']:
            if entry['name'] in unique and unique[entry['name']]!=entry['sha256']:
                raise ValueError('ambiguous guest archive identity')
            unique[entry['name']]=entry['sha256']
    for name,expected_sha in unique.items():
        if Path(name).name!=name or not name.endswith('.deb'): raise ValueError('unsafe archive name')
        source = seed/name
        if source.is_symlink() or sha(source)!=expected_sha: raise ValueError('guest archive pin differs')
        shutil.copyfile(source,workspace/name)
        (workspace/name).chmod(0o600)
        if sha(workspace/name)!=expected_sha or sha(source)!=expected_sha:
            raise ValueError('guest archive changed during copy')
    for phase in ('old','new'):
        if shutil.disk_usage(workspace).free < 1024**3:
            raise ValueError('actual guest free space below phase floor')
        result = module['consume'](workspace,phase)
        if result.get('installedPhase')!=phase or result.get('scratchId')!=manifest['scratchId']:
            raise ValueError('consumer result does not bind actual phase')
        observed = module['inventory'](module['execute'],
            {name:policy['phases']['old']['beforeInventory'][name]
             for name in policy['phases']['old']['allowedRemovals']})
        if observed!=policy['phases'][phase]['afterInventory']:
            raise ValueError('actual post-phase inventory differs')
        publication(phase+'-installed',observed,0)
        if phase=='old':
            waiter=wait_advance if advance_wait is None else advance_wait
            waiter(workspace,common,observe_boot)
    result = dict(common,stage='complete',inventory=observed,
                  inventorySha256=canonical_inventory(observed),exitStatus=0)
    if observe_boot()!=initial_boot: raise ValueError('boot changed before final publication')
    atomic_result(workspace,'result.json',result)
    emit(result)
    return result


def actual_environment(manifest,seed):
    if os.geteuid()!=0 or Path('/proc/1/comm').read_text().strip()!='systemd':
        raise ValueError('real root/systemd guest environment required')
    observed = Path('/sys/class/dmi/id/product_uuid').read_text().strip().lower()
    if observed != manifest['vmUuid']:
        raise ValueError('guest UUID differs from owned VM')
    result = subprocess.run(['/usr/bin/lsblk','--json','--output','NAME,TYPE,SERIAL,MOUNTPOINTS'],
                            check=True,capture_output=True,timeout=10)
    root_identity(json.loads(result.stdout)['blockdevices'],manifest['diskSerial'])
    mount = subprocess.run(['/usr/bin/findmnt','--json','--target',str(seed),
                            '--output','SOURCE,TARGET,FSTYPE,OPTIONS'],
                           check=True,capture_output=True,timeout=10)
    rows = json.loads(mount.stdout)['filesystems']
    if (len(rows)!=1 or rows[0]['fstype']!='iso9660' or
            'ro' not in rows[0]['options'].split(',') or
            Path(rows[0]['target']).resolve()!=seed.resolve()):
        raise ValueError('seed is not the actual readonly ISO mount')
    descriptor = os.open(rows[0]['source'],os.O_RDONLY)
    try:
        if not stat.S_ISBLK(os.fstat(descriptor).st_mode):
            raise ValueError('seed source is not an observed block device')
        size = struct.unpack('Q',fcntl.ioctl(descriptor,0x80081272,b'\0'*8))[0]
        if not 0<size<=64*1024**2: raise ValueError('seed exceeds bounded device size')
        digest=hashlib.sha256();read=0
        while read<size:
            chunk=os.read(descriptor,min(65536,size-read))
            if not chunk: raise ValueError('seed block read truncated')
            digest.update(chunk);read+=len(chunk)
        return {'seedSha256':digest.hexdigest()}
    finally: os.close(descriptor)


def run_reported(seed,workspace,emit,operation=None,observe_boot=boot_id):
    try:return (run if operation is None else operation)(seed,workspace,emit)
    except Exception as error:
        manifest_path=Path(seed)/'manifest.json'
        if manifest_path.stat().st_size>65536:raise
        manifest=json.loads(manifest_path.read_text())
        failure={'schemaVersion':1,'stage':'failed','scratchId':manifest.get('scratchId'),
                 'challenge':manifest.get('challenge'),'vmUuid':manifest.get('vmUuid'),'bootId':observe_boot(),
                 'failureType':type(error).__name__,'failure':str(error)[:1024]}
        if isinstance(error,RootIdentityRefusal):failure['rootIdentityFacts']=error.root_identity_facts
        if isinstance(error,subprocess.CalledProcessError):
            stdout=error.stdout or b'';stderr=error.stderr or b''
            if isinstance(stdout,str):stdout=stdout.encode()
            if isinstance(stderr,str):stderr=stderr.encode()
            if len(stdout)+len(stderr)>262144:raise ValueError('failure output exceeds command bound') from error
            failure['failure']='package command returned nonzero'
            failure['commandFailure']={'returnCode':error.returncode,
                'operation':getattr(error,'wootc_operation','subprocess'),
                'phase':getattr(error,'wootc_phase','unknown'),
                'stdout':stdout[:512].decode('utf-8',errors='replace'),
                'stderr':stderr[:1024].decode('utf-8',errors='replace'),
                'stdoutBytes':len(stdout),'stderrBytes':len(stderr),
                'stdoutTruncated':len(stdout)>512,'stderrTruncated':len(stderr)>1024,
                'files':{}}
            for name,data in [('stdout',stdout),('stderr',stderr)]:
                failure['commandFailure']['files'][name]={'size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
                # Complete failure-only bytes survive an absent/replaced QGA.
                # Final failure refs authorize reconstruction, never success.
                for index,offset in enumerate(range(0,len(data),8192)):
                    emit({key:failure[key] for key in ('schemaVersion','scratchId','challenge','vmUuid','bootId')} |
                         {'stage':'command-output','stream':name,'index':index,
                          'data':base64.b64encode(data[offset:offset+8192]).decode('ascii')})
        if len(json.dumps(failure))>16384:raise ValueError('guest failure record exceeds bound') from error
        emit(failure)
        raise


if __name__ == '__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('seed');parser.add_argument('workspace');args=parser.parse_args()
    # Only this guest proof helper writes typed success records. Cloud-init logs
    # and general serial text never count as package execution evidence.
    with open('/dev/ttyS0','a',buffering=1) as serial:
        def emit(value): serial.write(PREFIX+json.dumps(value,sort_keys=True)+'\n')
        run_reported(args.seed,args.workspace,emit)
