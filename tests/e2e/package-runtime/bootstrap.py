"""Guest-only NoCloud package proof; no host-package or VM launcher entry point."""
import base64
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import selectors
import signal
import stat
import struct
import subprocess
import sys
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


# Exact public Debian archive content pins. The archive itself is already part
# of the approved old-phase policy; changing it requires a reviewed profile.
AGENT_ARCHIVE = '7d7d6be6a52d6ea21eabdb78f686e4bb886f933171d33f5f3cf3cf2390343abd'
AGENT_FILES = {
    '/usr/sbin/qemu-ga':'ffaa27fa0ace4d0803c6c1393ecd1c382c2e0fb88bf81f72788a36fde33badea',
    '/usr/lib/systemd/system/qemu-guest-agent.service':'fb4fbdbf513be055bd6cabb974aee312dba0e900402ce0404941ea2e979c9cef',
    '/usr/lib/udev/rules.d/60-qemu-guest-agent.rules':'c25178c4315fddc557245f023464c6cd8d7325c9ec8f79db292db20d082a4c7a'}
AGENT_PORT = 'org.qemu.guest_agent.0'


def agent_read(path,limit=8192):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid!=0 or before.st_mode&0o022:
            raise ValueError('agent protected observation file unavailable')
        data=bytearray()
        while len(data)<=limit:
            chunk=os.read(fd,min(65536,limit+1-len(data)))
            if not chunk:break
            data.extend(chunk)
        after=os.fstat(fd)
        current=Path(path).stat(follow_symlinks=False)
        identity=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns)
        if len(data)>limit or identity(before)!=identity(after) or identity(after)!=identity(current):
            raise ValueError('agent observation changed or exceeds bound')
        return bytes(data)
    finally:os.close(fd)


class AgentChildren:
    """Single-threaded child-free lease: adopted processes belong to this call."""
    def __init__(self):
        self.active=False
        self.previous=ctypes.c_int()
        self.libc=ctypes.CDLL(None,use_errno=True)

    def children(self):
        values=Path('/proc/self/task/'+str(os.getpid())+'/children').read_text().split()
        if len(values)>128:raise ValueError('agent child inventory exceeds bound')
        return [int(pid) for pid in values]

    def acquire(self):
        if len(list(Path('/proc/self/task').iterdir()))!=1 or self.children():
            raise ValueError('agent command requires single-threaded child-free owner')
        if self.libc.prctl(37,ctypes.byref(self.previous),0,0,0)!=0 or self.libc.prctl(36,1,0,0,0)!=0:
            raise OSError(ctypes.get_errno(),'agent subreaper lease unavailable')
        self.active=True

    def cleanup(self,child):
        facts={'leader':child.pid,'groupSignalled':False,'descendants':[],'empty':False}
        deadline=time.monotonic()+2
        try:
            # The leader is deliberately not reaped before this signal. Its PID
            # therefore cannot be reused as an unrelated process group identity.
            try:os.killpg(child.pid,signal.SIGKILL);facts['groupSignalled']=True
            except ProcessLookupError:pass
            while True:
                others=[pid for pid in self.children() if pid!=child.pid]
                for pid in others:
                    descriptor=os.pidfd_open(pid)
                    try:
                        fields=Path('/proc/'+str(pid)+'/stat').read_text().rpartition(')')[2].split()
                        if int(fields[1])!=os.getpid():raise ValueError('agent descendant ownership changed')
                        if len(facts['descendants'])>=128:raise ValueError('agent descendant receipts exceed bound')
                        entry={'pid':pid,'startTicks':fields[19],'reaped':False}
                        signal.pidfd_send_signal(descriptor,signal.SIGKILL)
                        while True:
                            reaped,status=os.waitpid(pid,os.WNOHANG)
                            if reaped:
                                entry['reaped']=True;entry['status']=status;facts['descendants'].append(entry);break
                            if time.monotonic()>=deadline:raise TimeoutError('agent descendant reap deadline expired')
                            time.sleep(.005)
                    finally:os.close(descriptor)
                # Reaping the leader only after group cleanup preserves its exit
                # status; orphan adoption happens synchronously when it exits.
                if child.returncode is None:
                    exited=os.waitid(os.P_PID,child.pid,os.WEXITED|os.WNOHANG|os.WNOWAIT)
                    if exited is not None:child.wait(timeout=.001)
                if child.returncode is not None and not self.children():
                    facts['empty']=True;return facts
                if time.monotonic()>=deadline:raise TimeoutError('agent owned cleanup deadline expired')
                time.sleep(.005)
        except BaseException as error:
            error.agentCommandFacts=facts
            raise

    def release(self):
        if not self.active:return
        if self.children():raise ValueError('agent children remain: subreaper lease retained')
        if self.libc.prctl(36,self.previous.value,0,0,0)!=0:
            raise OSError(ctypes.get_errno(),'agent subreaper restoration failed')
        self.active=False


def agent_command(argv,deadline):
    remaining=deadline-time.monotonic()
    if remaining<=0:raise TimeoutError('agent lifecycle deadline expired')
    executable=Path(argv[0]).resolve(strict=True)
    if not executable.is_relative_to('/usr'):
        raise ValueError('agent tool outside protected usr')
    for parent in (executable.parent,*executable.parent.parents):
        facts=parent.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid!=0 or facts.st_mode&0o022:
            raise ValueError('agent tool parent is unprotected')
    fd=os.open(executable,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    child=None
    lease=AgentChildren()
    cleanup_facts=None
    cleanup_attempted=False
    try:
        facts=os.fstat(fd)
        if not stat.S_ISREG(facts.st_mode) or facts.st_uid!=0 or facts.st_mode&0o022 or not facts.st_mode&0o111:
            raise ValueError('agent tool is unprotected')
        lease.acquire()
        child=subprocess.Popen(argv,executable='/proc/self/fd/'+str(fd),pass_fds=(fd,),stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,cwd='/',env={'PATH':'/usr/sbin:/usr/bin:/sbin:/bin','LANG':'C','LC_ALL':'C'})
        output={child.stdout:bytearray(),child.stderr:bytearray()}
        with selectors.DefaultSelector() as ready:
            for stream in output:
                os.set_blocking(stream.fileno(),False);ready.register(stream,selectors.EVENT_READ)
            while ready.get_map():
                remaining=deadline-time.monotonic()
                if remaining<=0:raise TimeoutError('agent command deadline expired')
                for key,_ in ready.select(min(remaining,.05)):
                    data=os.read(key.fileobj.fileno(),8192)
                    if not data:ready.unregister(key.fileobj);continue
                    output[key.fileobj].extend(data)
                    if sum(map(len,output.values()))>16384:raise ValueError('agent command output exceeds bound')
        while os.waitid(os.P_PID,child.pid,os.WEXITED|os.WNOHANG|os.WNOWAIT) is None:
            if time.monotonic()>=deadline:raise TimeoutError('agent command exit deadline expired')
            time.sleep(.005)
        cleanup_attempted=True
        cleanup_facts=lease.cleanup(child)
        status=child.returncode
        stdout,stderr=bytes(output[child.stdout]),bytes(output[child.stderr])
        if status!=0:
            error=subprocess.CalledProcessError(status,argv,stdout,stderr)
            error.wootc_operation='guest-agent-lifecycle';error.wootc_phase='old';raise error
        return stdout.decode('ascii')
    finally:
        failure=sys.exc_info()[1]
        try:
            if child is not None:
                try:
                    if not cleanup_attempted:
                        cleanup_attempted=True
                        cleanup_facts=lease.cleanup(child)
                    if failure is not None:failure.agentCommandFacts=cleanup_facts
                finally:child.stdout.close();child.stderr.close()
            # Unknown cleanup retains the subreaper lease and original facts.
            # Never repeat a group signal after its leader may have been reaped.
            if child is None or cleanup_facts is not None:lease.release()
        finally:os.close(fd)


def agent_device():
    root=Path('/sys/class/virtio-ports')
    entries=list(root.iterdir())
    if len(entries)>32:raise ValueError('agent device inventory exceeds bound')
    matches=[]
    for entry in entries:
        resolved=entry.resolve(strict=True)
        if not resolved.is_relative_to('/sys/devices'):
            raise ValueError('agent kernel device namespace unknown')
        if agent_read(resolved/'name',128).decode('ascii').strip()!=AGENT_PORT:continue
        if not re.fullmatch('vport[0-9]+p[0-9]+',entry.name):raise ValueError('agent kernel device name unknown')
        major=agent_read(resolved/'dev',128).decode('ascii').strip()
        if not re.fullmatch('[0-9]+:[0-9]+',major):raise ValueError('agent device identity malformed')
        node=Path('/dev')/entry.name;facts=node.lstat()
        if not stat.S_ISCHR(facts.st_mode) or facts.st_uid!=0 or major!=str(os.major(facts.st_rdev))+':'+str(os.minor(facts.st_rdev)):
            raise ValueError('agent device node differs from kernel observation')
        matches.append({'kernelPath':str(resolved),'node':str(node),'majorMinor':major,'device':facts.st_dev,'inode':facts.st_ino,'rdev':facts.st_rdev})
    if len(matches)!=1:raise ValueError('unique actual guest-agent device unavailable')
    return matches[0]


def agent_unit(text):
    required={'ActiveState','SubState','MainPID','FragmentPath','DropInPaths'}
    fields={}
    if len(text)>8192:raise ValueError('agent unit observation exceeds bound')
    for line in text.splitlines():
        key,sep,value=line.partition('=')
        if not sep or key not in required or key in fields:raise ValueError('agent unit fields malformed')
        fields[key]=value
    if set(fields)!=required or fields['ActiveState']!='active' or fields['SubState']!='running' or not re.fullmatch('[1-9][0-9]{0,9}',fields['MainPID']) or fields['FragmentPath']!='/usr/lib/systemd/system/qemu-guest-agent.service' or fields['DropInPaths']:
        raise ValueError('actual approved guest-agent unit is not running')
    return fields


def agent_process(unit,device):
    pid=unit['MainPID'];root=Path('/proc')/pid
    status=agent_read(root/'status',8192).decode('ascii')
    uid=re.findall(r'^Uid:\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)$',status,re.M)
    if uid!=[('0','0','0','0')]:raise ValueError('guest-agent process is not root')
    before=agent_read(root/'stat',8192).decode('ascii')
    if not before.startswith(pid+' ('):raise ValueError('agent process identity differs')
    fields=before.rpartition(')')[2].split()
    if len(fields)<20 or not re.fullmatch('[1-9][0-9]{0,19}',fields[19]):raise ValueError('agent process start token unavailable')
    if os.readlink(root/'exe')!='/usr/sbin/qemu-ga' or agent_read(root/'cmdline',4096)!=b'/usr/sbin/qemu-ga\0':
        raise ValueError('agent process executable/argv differs')
    expected=Path('/usr/sbin/qemu-ga').stat();actual=(root/'exe').stat()
    if (actual.st_dev,actual.st_ino)!=(expected.st_dev,expected.st_ino):raise ValueError('agent process uses a different executable inode')
    descriptors=list((root/'fd').iterdir())
    if len(descriptors)>128:raise ValueError('agent process fd inventory exceeds bound')
    matches=[]
    for descriptor in descriptors:
        facts=descriptor.stat()
        if stat.S_ISCHR(facts.st_mode) and facts.st_rdev==device['rdev']:matches.append(descriptor.name)
    if len(matches)!=1:raise ValueError('agent process has not opened the actual named device')
    after=agent_read(root/'stat',8192).decode('ascii')
    if after.rpartition(')')[2].split()[19]!=fields[19]:raise ValueError('agent process changed during observation')
    return {'pid':int(pid),'startTicks':fields[19],'openedDeviceFd':matches[0]}


def prepare_guest_agent(policy,observe_boot=boot_id,command=agent_command,read=agent_read,device=agent_device,process=agent_process):
    packages=[p for p in policy['phases']['old']['packages'] if p['package']=='qemu-guest-agent']
    if len(packages)!=1 or packages[0]['sha256']!=AGENT_ARCHIVE:
        raise ValueError('reviewed guest-agent archive profile absent')
    initial=observe_boot();deadline=time.monotonic()+15
    profile={name:hashlib.sha256(read(name,4*1024**2)).hexdigest() for name in AGENT_FILES}
    if profile!=AGENT_FILES:raise ValueError('installed guest-agent source differs from approved archive')
    observed=device()
    for argv in [
        ['/usr/bin/udevadm','control','--reload'],
        ['/usr/bin/udevadm','trigger','--action=add',observed['kernelPath']],
        ['/usr/bin/udevadm','settle','--timeout=3'],
        ['/usr/bin/systemctl','daemon-reload'],
        ['/usr/bin/systemctl','start','qemu-guest-agent.service']]:
        command(argv,deadline)
    query=['/usr/bin/systemctl','show','qemu-guest-agent.service','--property=ActiveState,SubState,MainPID,FragmentPath,DropInPaths']
    unit=agent_unit(command(query,deadline));identity=process(unit,observed)
    if agent_unit(command(query,deadline))!=unit or process(unit,observed)!=identity or device()!=observed:
        raise ValueError('guest-agent unit/process/device changed')
    if {name:hashlib.sha256(read(name,4*1024**2)).hexdigest() for name in AGENT_FILES}!=profile or observe_boot()!=initial or time.monotonic()>=deadline:
        raise ValueError('guest-agent source/boot changed or deadline expired')
    return {'unitPrepared':True,'bootId':initial,'sourceHashes':profile,'unit':unit,'process':identity,'device':observed,'agentResponding':False}

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
        environment=None,advance_wait=None,agent_prepare=None):
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
        if phase=='old':
            prepare=prepare_guest_agent if agent_prepare is None else agent_prepare
            agent_facts=prepare(policy,observe_boot)
            if (type(agent_facts) is not dict or agent_facts.get('unitPrepared') is not True or
                    agent_facts.get('bootId')!=initial_boot or agent_facts.get('agentResponding') is not False):
                raise ValueError('guest agent preparation receipt unavailable')
            atomic_result(workspace,'agent-lifecycle.json',agent_facts)
            common['agentLifecycle']=agent_facts
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
        if hasattr(error,'agentCommandFacts'):failure['agentCommandFacts']=error.agentCommandFacts
        if isinstance(error,subprocess.CalledProcessError):
            stdout=error.stdout or b'';stderr=error.stderr or b''
            if isinstance(stdout,str):stdout=stdout.encode()
            if isinstance(stderr,str):stderr=stderr.encode()
            if len(stdout)+len(stderr)>262144:raise ValueError('failure output exceeds command bound') from error
            failure['failure']=('guest lifecycle command returned nonzero' if getattr(error,'wootc_operation','').startswith('guest-agent') else 'package command returned nonzero')
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


def serial_emit(value, serial_path='/dev/ttyS0', seconds=3):
    """One bounded publication on the current TTY generation; never retry bytes.

    Package/service changes may invalidate an already-open terminal descriptor.
    Opening for each record avoids retaining that descriptor across mutation.
    Any current open/write failure still refuses publication and acceptance.
    """
    if not isinstance(value,dict) or type(seconds) not in (int,float) or not 0<seconds<=3:
        raise ValueError('bounded serial publication required')
    data=(PREFIX+json.dumps(value,sort_keys=True,allow_nan=False)+'\n').encode('utf-8')
    if len(data)>65536:raise ValueError('serial record exceeds bound')
    deadline=time.monotonic()+seconds
    descriptor=os.open(serial_path,os.O_WRONLY|os.O_NONBLOCK|os.O_NOCTTY)
    try:
        if not stat.S_ISCHR(os.fstat(descriptor).st_mode) or not os.isatty(descriptor):
            raise ValueError('serial publication requires current TTY')
        with selectors.DefaultSelector() as ready:
            ready.register(descriptor,selectors.EVENT_WRITE)
            offset=0
            while offset<len(data):
                remaining=deadline-time.monotonic()
                if remaining<=0 or not ready.select(remaining):
                    raise TimeoutError('serial publication deadline expired')
                try:count=os.write(descriptor,data[offset:])
                except BlockingIOError:continue
                if count<=0:raise OSError('serial publication made no progress')
                offset+=count
    finally:os.close(descriptor)


if __name__ == '__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('seed');parser.add_argument('workspace');args=parser.parse_args()
    # Only this guest proof helper writes typed success records. Cloud-init logs
    # and general serial text never count as package execution evidence.
    run_reported(args.seed,args.workspace,serial_emit)
