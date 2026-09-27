"""Owned Linux-only package proof; VM execution requires measured qualified host."""
import fcntl
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import signal
import stat
import subprocess
import time

ROOT=Path(__file__).resolve().parents[3]
BOOTSTRAP=runpy.run_path(str(Path(__file__).with_name('bootstrap.py')))
COMPARE=runpy.run_path(str(Path(__file__).with_name('serial-proof.py')))['validate']


def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def qualify(folder):
    memory=dict(line.split(':',1) for line in Path('/proc/meminfo').read_text().splitlines())
    facts={'cpus':os.cpu_count(),'memAvailableBytes':int(memory['MemAvailable'].split()[0])*1024,
           'freeBytes':shutil.disk_usage(folder).free}
    if facts['cpus']<4 or facts['memAvailableBytes']<11*1024**3 or facts['freeBytes']<64*1024**3:
        raise ValueError('actual host resource gate failed')
    descriptor=os.open('/dev/kvm',os.O_RDWR)
    try:facts['kvmApi']=fcntl.ioctl(descriptor,0xAE00,0)
    finally:os.close(descriptor)
    if facts['kvmApi']!=12:raise ValueError('actual KVM API differs')
    return facts


def checked(folder):
    folder=Path(folder).resolve(strict=True);info=folder.stat()
    if not re.fullmatch('[A-Za-z0-9_/.-]+',str(folder)):
        raise ValueError('unsafe scratch path for QEMU argument encoding')
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:
        raise ValueError('scratch directory is not private and owned')
    record=json.loads((folder/'ownership.json').read_text())
    if record['stage']!=str(folder) or record['runtimeExecuted'] is not False:
        raise ValueError('scratch identity differs or was already executed')
    prefix=Path(record['hostDataPrefix'])
    runpy.run_path(str(Path(__file__).with_name('host-namespace.py')))['require_bound'](prefix)
    if record.get('diskSerial')!=BOOTSTRAP['disk_serial'](record['scratchId'],record['challenge']):
        raise ValueError('scratch disk serial binding differs')
    if sha(prefix/'host-data.json')!=record['hostDataSourceSha256'] or record['qemuDataPath']!=str(prefix/'usr/share/qemu'):
        raise ValueError('recorded host data source contract differs')
    for name,expected in {'base.qcow2':record['baseSha256'],'seed.iso':record['seedSha256'],
                          **record['firmwareSourceHashes'],**record['hostHelperHashes']}.items():
        path=folder/name;meta=path.lstat()
        if not stat.S_ISREG(meta.st_mode) or meta.st_uid!=os.getuid() or meta.st_nlink!=1 or sha(path)!=expected:
            raise ValueError('scratch source identity differs')
    for name in ('qga.sock','serial.log','pid.json'):
        if (folder/name).exists() or (folder/name).is_symlink():raise ValueError('scratch runtime path already exists')
    image=subprocess.run(['/usr/bin/qemu-img','info','--output=json',str(folder/'overlay.qcow2')],
                         check=True,capture_output=True,timeout=10)
    overlay=json.loads(image.stdout)
    if (overlay.get('format')!='qcow2' or overlay.get('full-backing-filename')!=str(folder/'base.qcow2') or
            overlay.get('virtual-size')!=record['actualVirtualBytes'] or
            overlay.get('format-specific',{}).get('data',{}).get('data-file')):
        raise ValueError('overlay ancestry differs')
    return folder,record


def process_identity(pid):
    root=Path('/proc')/str(pid)
    # stat comm may contain spaces and closing parentheses.
    fields=(root/'stat').read_text().rsplit(') ',1)[1].split()
    return {'pid':pid,'startTime':fields[19],
            'cmdlineSha256':hashlib.sha256((root/'cmdline').read_bytes()).hexdigest()}


def stop_owned(child,identity):
    if child.poll() is not None:return child.wait()
    if process_identity(child.pid)!=identity:raise ValueError('owned process identity changed; refusal to signal')
    os.killpg(child.pid,signal.SIGTERM)
    try:return child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        if process_identity(child.pid)!=identity:raise ValueError('owned process changed before cancellation')
        os.killpg(child.pid,signal.SIGKILL)
        return child.wait(timeout=2)


def run_owned(command,folder,observe,seconds=1200,on_started=None):
    """Actual process controls use native fixture commands; production supplies only QEMU."""
    folder=Path(folder)
    with (folder/'process.stdout').open('xb') as output,(folder/'process.stderr').open('xb') as errors:
        child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=output,stderr=errors,start_new_session=True)
    identity=None
    deadline=time.monotonic()+seconds
    try:
        identity=process_identity(child.pid)
        (folder/'pid.json').write_text(json.dumps(identity,sort_keys=True)+'\n')
        if on_started is not None:on_started(identity)
        while True:
            remaining=deadline-time.monotonic()
            if remaining<=0:raise TimeoutError('owned runtime absolute deadline expired')
            if child.poll() is not None:raise ValueError('owned guest process exited before accepted observation')
            result=observe(child,remaining)
            if result is not None:return result
            time.sleep(min(.1,max(0,deadline-time.monotonic())))
    finally:
        if identity is not None:
            code=stop_owned(child,identity)
            receipt={'schemaVersion':1,'ownedProcessIdentity':identity,'waitCompleted':True,'returnCode':code}
            with (folder/'process-reap.json').open('x') as output:
                json.dump(receipt,output,sort_keys=True);output.write('\n');output.flush();os.fsync(output.fileno())
        elif child.poll() is not None:child.wait()
        else:
            # Popen owns this child even when initial /proc observation fails.
            child.terminate();child.wait(timeout=2)


def owned_qga_socket(child,folder):
    path=Path(folder)/'qga.sock';info=path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid!=os.getuid():
        raise ValueError('QGA path is not the owned actual socket')
    rows=[line.split(maxsplit=7) for line in Path('/proc/net/unix').read_text().splitlines()[1:]]
    inodes={row[6] for row in rows if len(row)==8 and row[7]==str(path)}
    links=set()
    for descriptor in (Path('/proc')/str(child.pid)/'fd').iterdir():
        try:links.add(os.readlink(descriptor))
        except FileNotFoundError:continue
    if len(inodes)!=1 or 'socket:['+next(iter(inodes))+']' not in links:
        raise ValueError('QGA socket is not held by exact owned guest process')


def protected_qemu():
    qemu=Path('/usr/bin/qemu-system-x86_64');info=qemu.stat()
    if info.st_uid!=0 or info.st_mode&0o022:raise ValueError('QEMU executable is not protected installed source')
    return str(qemu)


def command(folder,record):
    if record.get('diskSerial')!=BOOTSTRAP['disk_serial'](record['scratchId'],record['challenge']):
        raise ValueError('command disk serial binding differs')
    qemu=protected_qemu()
    return [qemu,'-L',record['qemuDataPath'],'-name','wootc-package-'+record['scratchId'],'-uuid',record['vmUuid'],
            '-machine','q35,accel=kvm','-m','2048','-smp','2','-display','none','-monitor','none',
            '-nic','none','-serial','file:'+str(folder/'serial.log'),
            '-drive','if=pflash,format=raw,readonly=on,file='+str(folder/'code.fd'),
            '-drive','if=pflash,format=raw,file='+str(folder/'vars.fd'),
            '-drive','if=none,id=root,format=qcow2,file='+str(folder/'overlay.qcow2'),
            '-device','virtio-blk-pci,drive=root,serial='+record['diskSerial'],
            '-drive','if=ide,media=cdrom,readonly=on,format=raw,file='+str(folder/'seed.iso'),
            '-device','virtio-serial-pci','-chardev','socket,id=qga,path='+str(folder/'qga.sock')+',server=on,wait=off',
            '-device','virtserialport,chardev=qga,name=org.qemu.guest_agent.0']


def retain_command_output(folder,records,failure):
    facts=failure.get('commandFailure')
    chunks=[value for value in records if value.get('stage')=='command-output']
    if facts is None:
        if chunks:raise ValueError('unbound command output chunks')
        return
    files=facts.get('files')
    if not isinstance(files,dict) or set(files)!= {'stdout','stderr'}:raise ValueError('complete command output refs required')
    total=0;complete={}
    for name in ('stdout','stderr'):
        ref=files[name]
        if type(ref.get('size')) is not int or not 0<=ref['size']<=262144 or not re.fullmatch('[0-9a-f]{64}',ref.get('sha256','')):raise ValueError('invalid command output ref')
        data=bytearray();selected=[value for value in chunks if value.get('stream')==name]
        for index,value in enumerate(selected):
            if (type(value.get('index')) is not int or value['index']!=index or
                any(value.get(key)!=failure.get(key) for key in ('schemaVersion','scratchId','challenge','vmUuid','bootId')) or
                not isinstance(value.get('data'),str) or len(value['data'])>10924):raise ValueError('command output chunk identity differs')
            block=base64.b64decode(value['data'],validate=True)
            if not 0<len(block)<=8192:raise ValueError('command output chunk exceeds bound')
            data.extend(block)
            if len(data)>ref['size']:raise ValueError('command output bytes exceed reference')
        total+=len(data)
        if total>262144 or len(data)!=ref['size'] or hashlib.sha256(data).hexdigest()!=ref['sha256']:raise ValueError('complete command output hash differs')
        complete[name]=data
    if any(value.get('stream') not in files for value in chunks):raise ValueError('unknown command output stream')
    for name,data in complete.items():(Path(folder)/('command-failure.'+name)).write_bytes(data)


def make_observer(folder,record,readback,acknowledge,on_baseline=None):
    folder=Path(folder);serial=folder/'serial.log';state={'oldVerified':False}
    def observe(child,remaining):
        for path,limit in ((serial,1048576),(folder/'overlay.qcow2',record['actualVirtualBytes']+512*1024**2),
                           (folder/'process.stdout',262144),(folder/'process.stderr',262144)):
            if path.exists() and path.stat().st_size>limit:raise ValueError('owned runtime quota exceeded')
        if shutil.disk_usage(folder).free<2*1024**3:raise ValueError('actual host reserve exhausted')
        if not serial.exists():return None
        with serial.open('rb') as stream:raw=stream.read(1048577)
        if len(raw)>1048576:raise ValueError('serial read exceeds quota')
        # The live writer may be halfway through its final line. Only a complete
        # newline-terminated record can become an observation.
        raw=raw[:raw.rfind(b'\n')+1]
        text=raw.decode('utf-8',errors='strict')
        lines=[line for line in text.splitlines() if line.startswith('WOOTC_PACKAGE_RUNTIME_V1 ')]
        parsed=[json.loads(line.split(' ',1)[1]) for line in lines]
        for value in parsed:
            if value.get('stage')=='failed':
                if (type(value.get('schemaVersion')) is not int or value.get('schemaVersion')!=1 or
                        value.get('vmUuid')!=record.get('vmUuid') or
                        not re.fullmatch('[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',value.get('bootId','')) or
                        value.get('scratchId')!=record['scratchId'] or
                        value.get('challenge')!=record['challenge']):
                    raise ValueError('guest failure identity differs')
                retain_command_output(folder,parsed,value)
                (folder/'guest-failure.json').write_text(json.dumps(value,sort_keys=True)+'\n')
                raise ValueError('guest producer refused: '+str(value.get('failure','unknown'))[:1024])
        if any(value.get('stage')=='command-output' for value in parsed):return None
        if not state['oldVerified']:
            if len(lines)<2:return None
            COMPARE(text,record,through='old')
            if on_baseline is not None:on_baseline()
            owned_qga_socket(child,folder)
            record['readbackChallenge']=os.urandom(32).hex()
            deadline=time.monotonic()+remaining
            current=readback(folder,record,remaining,'old')
            COMPARE(text,record,current,through='old')
            approved=hashlib.sha256(json.dumps(current,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            left=deadline-time.monotonic()
            if left<=0:raise TimeoutError('old readback exhausted shared observer deadline')
            ack=acknowledge(folder,record,approved,left)
            expected={name:current['result'][name] for name in ('scratchId','challenge','bootId','seedSha256')}
            expected.update(validatedPhase='old',readbackChallenge=record['readbackChallenge'],approvedReadbackSha256=approved)
            if ack!=expected:raise ValueError('old phase acknowledgement differs from independent approval')
            (folder/'old-phase-readback.json').write_text(json.dumps(current,sort_keys=True)+'\n')
            (folder/'old-phase-advance.json').write_text(json.dumps(ack,sort_keys=True)+'\n')
            state['oldVerified']=True
            return None
        if len(lines)<4:return None
        COMPARE(text,record)
        owned_qga_socket(child,folder)
        record['readbackChallenge']=os.urandom(32).hex()
        current=readback(folder,record,remaining,'new')
        return COMPARE(text,record,current)
    return observe


def launch(folder,readback,acknowledge,on_started=None,on_baseline=None):
    folder,record=checked(folder)
    record.update(executionRequested=True,processStarted=False,runtimeExecuted=False,guestBaselineObserved=False)
    def save():(folder/'ownership.json').write_text(json.dumps(record,sort_keys=True,indent=2)+'\n')
    save()
    facts=qualify(folder)
    required=2*(folder/'base.qcow2').stat().st_size+3*record['actualVirtualBytes']+4*22012320+64*1024**2+2*1024**3
    if facts['freeBytes']<required:raise ValueError('actual scratch capacity below runtime formula')
    record['measuredHost']=facts;save()
    def started(identity):
        record.update(processStarted=True,runtimeExecuted=True,ownedProcessIdentity=identity);save()
        if on_started is not None:on_started(identity)
    def baseline():
        record['guestBaselineObserved']=True;save()
        if on_baseline is not None:on_baseline()
    observe=make_observer(folder,record,readback,acknowledge,baseline)
    result=run_owned(command(folder,record),folder,observe,on_started=started)
    (folder/'accepted.json').write_text(json.dumps(result,sort_keys=True)+'\n')
    return result


def readback(folder,record,remaining,phase='new'):
    socket=folder/'qga.sock';info=socket.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid!=os.getuid():
        raise ValueError('QGA path is not owned actual socket')
    for name,expected in record['hostHelperHashes'].items():
        if sha(folder/name)!=expected:raise ValueError('host readback closure changed')
    consumer=runpy.run_path(str(ROOT/'tests/e2e/esp-chain/package-consumer.py'))
    response=consumer['execute'](['/usr/bin/python3',str(folder/'qga-readback.py'),str(socket),
        record['readbackChallenge'],str(max(.01,min(30,remaining))),'--phase',phase],timeout=min(30,remaining),capture_output=True)
    return json.loads(response.stdout)

def acknowledge(folder,record,approved,remaining):
    for name,expected in record['hostHelperHashes'].items():
        if sha(folder/name)!=expected:raise ValueError('host acknowledgement closure changed')
    consumer=runpy.run_path(str(ROOT/'tests/e2e/esp-chain/package-consumer.py'))
    response=consumer['execute'](['/usr/bin/python3',str(folder/'qga-readback.py'),str(folder/'qga.sock'),
        record['readbackChallenge'],str(max(.01,min(30,remaining))),'--approved',approved],
        timeout=min(30,remaining),capture_output=True)
    return json.loads(response.stdout)


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('scratch');parser.add_argument('--execute',action='store_true');args=parser.parse_args()
    if not args.execute:
        folder,record=checked(args.scratch)
        print(json.dumps({'inputsMatch':True,'executionRequested':False,'firmwareAcceptance':False}))
    else:print(json.dumps(launch(args.scratch,readback,acknowledge),sort_keys=True))
