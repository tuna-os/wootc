"""Fresh hosted one-shot package proof; never accepts existing scratch or inputs."""
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import signal
import stat
import subprocess
import struct

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]


def hosted(env):
    if (env.get('GITHUB_ACTIONS')!='true' or env.get('RUNNER_ENVIRONMENT')!='github-hosted' or
            env.get('RUNNER_OS')!='Linux' or not re.fullmatch('[0-9]+',env.get('GITHUB_RUN_ID','')) or
            not re.fullmatch('[0-9]+',env.get('GITHUB_RUN_ATTEMPT','')) or
            not re.fullmatch('[0-9a-f]{40}',env.get('GITHUB_SHA',''))):
        raise ValueError('fresh GitHub-hosted Linux execution contract required')


def protected(path):
    source=Path(path);path=source.resolve(strict=True);info=path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or info.st_mode&0o022:
        raise ValueError('host source is not protected regular root file: source='+str(source)+' resolved='+str(path)+
                         ' uid='+str(info.st_uid)+' gid='+str(info.st_gid)+' mode='+oct(stat.S_IMODE(info.st_mode)))
    for parent in path.parents:
        meta=parent.stat()
        if meta.st_uid!=0 or meta.st_mode&0o022:
            raise ValueError('host source parent is writable: source='+str(source)+' resolved='+str(path)+
                             ' parent='+str(parent)+' uid='+str(meta.st_uid)+' gid='+str(meta.st_gid)+
                             ' mode='+oct(stat.S_IMODE(meta.st_mode)))
    return path


def elf_needed(path):
    """Read the actual x86-64 ELF program/dynamic/string tables, bounded and stable."""
    path=Path(path)
    before=path.stat()
    if not stat.S_ISREG(before.st_mode) or not 64<=before.st_size<=64*1024**2:
        raise ValueError('ELF source size/type unsupported')
    with path.open('rb') as stream:data=stream.read(64*1024**2+1)
    after=path.stat()
    identity=lambda value:(value.st_dev,value.st_ino,value.st_size,value.st_mtime_ns,value.st_ctime_ns)
    if identity(before)!=identity(after) or len(data)!=before.st_size:
        raise ValueError('ELF source changed during readback')
    header=struct.unpack_from('<16sHHIQQQIHHHHHH',data)
    ident,kind,machine,version,_,phoff,_,_,ehsize,phsize,phnum,_,_,_=header
    if (ident[:7]!=b'\x7fELF\x02\x01\x01' or kind not in (2,3) or machine!=62 or version!=1 or
            ehsize!=64 or phsize!=56 or not 1<=phnum<=1024 or phoff<64 or phoff+phnum*56>len(data)):
        raise ValueError('ELF header/program table unsupported')
    rows=[struct.unpack_from('<IIQQQQQQ',data,phoff+index*56) for index in range(phnum)]
    for row in rows:
        if row[2]+row[5]>len(data):raise ValueError('ELF program file range truncated')
        if row[0] in (1,2) and row[5]>row[6]:raise ValueError('ELF program memory range smaller than file')
    dynamic=[row for row in rows if row[0]==2]
    if len(dynamic)!=1:raise ValueError('one complete ELF dynamic table required')
    row=dynamic[0];offset,size=row[2],row[5]
    dynamic_mappings=[load[2]+row[3]-load[3] for load in rows if load[0]==1 and
                      load[3]<=row[3] and row[3]+size<=load[3]+load[5]]
    if dynamic_mappings!=[offset]:raise ValueError('ELF dynamic range is not uniquely bound to loaded bytes')
    if not 16<=size<=262144 or size%16:raise ValueError('ELF dynamic table size malformed')
    entries=[];terminated=False
    for position in range(offset,offset+size,16):
        tag,value=struct.unpack_from('<qQ',data,position)
        if terminated:
            if tag or value:raise ValueError('ELF nonzero entries after dynamic terminator')
        elif tag==0:
            if value:raise ValueError('ELF dynamic terminator malformed')
            terminated=True
        else:entries.append((tag,value))
    if not terminated:raise ValueError('ELF dynamic terminator missing')
    needed=[value for tag,value in entries if tag==1]
    if len(set(needed))!=len(needed):raise ValueError('ELF duplicate needed string offsets')
    strings=[value for tag,value in entries if tag==5];sizes=[value for tag,value in entries if tag==10]
    if len(strings)!=1 or len(sizes)!=1 or not 1<=sizes[0]<=1024**2:
        raise ValueError('ELF dynamic string table unsupported')
    mappings=[row[2]+strings[0]-row[3] for row in rows if row[0]==1 and
              row[3]<=strings[0] and strings[0]+sizes[0]<=row[3]+row[5]]
    if len(mappings)!=1:raise ValueError('ELF dynamic string range is not file-backed uniquely')
    start=mappings[0];names=[]
    for value in needed:
        if value>=sizes[0]:raise ValueError('ELF needed string offset outside table')
        end=data.find(b'\0',start+value,start+sizes[0])
        if end<0 or not 0<end-start-value<=4096:raise ValueError('ELF needed string malformed')
        name=data[start+value:end].decode('ascii')
        if any(character.isspace() for character in name):raise ValueError('ELF needed string whitespace')
        names.append(name)
    return {'sourceSha256':hashlib.sha256(data).hexdigest(),'elfType':kind,
            'neededNames':names,'dynamicEntries':len(entries)+1,'hasInterpreter':any(row[0]==3 for row in rows)}


def dependency_class(executable,facts,dependencies,modules):
    if not dependencies and (facts['neededNames'] or executable not in modules or
                             facts['elfType']!=3 or facts['hasInterpreter']):
        raise ValueError(str(executable)+' [ldd-readback]: required dependency closure absent')


def closure(run=subprocess.run,proof=None):
    paths=set();observations=[]
    def save():
        if proof is not None:Path(proof).write_text(json.dumps(observations,sort_keys=True,indent=2)+'\n')
    env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C'}
    sources=['/usr/bin/qemu-system-x86_64','/usr/bin/qemu-img','/usr/bin/genisoimage']
    modules=sorted(Path('/usr/lib/x86_64-linux-gnu/qemu').glob('*.so'))
    if not modules:raise ValueError('installed QEMU module closure absent')
    sources.extend(str(path) for path in modules)
    for source in sources:
        executable=protected(source);paths.add(executable)
        observation={'source':str(executable),'stage':'elf-readback'};observations.append(observation);save()
        try:facts=elf_needed(executable)
        except Exception as error:raise ValueError(str(executable)+' [elf-readback]: '+str(error)) from error
        observation.update(facts,stage='ldd-readback');save()
        reply=run(['/usr/bin/ldd',str(executable)],check=True,capture_output=True,text=True,timeout=10,env=env)
        dependencies=set()
        for line in reply.stdout.splitlines():
            if 'not found' in line:raise ValueError(str(executable)+' [ldd-readback]: dynamic dependency missing')
            candidates=re.findall(r'(?<!\S)(/[^\s]+)',line)
            for value in candidates:dependencies.add(protected(value))
        dependency_class(executable,facts,dependencies,{path.resolve() for path in modules})
        if hashlib.sha256(executable.read_bytes()).hexdigest()!=facts['sourceSha256']:
            raise ValueError(str(executable)+' [ldd-readback]: source changed after ELF inspection')
        observation.update(stage='verified',dependencyPaths=sorted(str(path) for path in dependencies));save()
        paths.update(dependencies)
    for path in Path('/usr/share/qemu').rglob('*'):
        if path.is_file():paths.add(protected(path))
    paths.update(protected('/usr/share/OVMF/'+name) for name in ('OVMF_CODE_4M.fd','OVMF_VARS_4M.fd'))
    hashes={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths)}
    return hashes


def unchanged(expected):
    for name,digest in expected.items():
        path=protected(name)
        if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:raise ValueError('host production closure changed')


def retain(folder,artifacts):
    """Bounded proof-only export; archives, overlay, firmware and seed are excluded."""
    allowed={'execution.json','host.json','acquisition.json','ownership.json','accepted.json',
             'command-failure.stdout','command-failure.stderr','pid.json','process-reap.json','guest-failure.json','tool-closure.json','old-phase-readback.json','old-phase-advance.json','serial.log','process.stdout','process.stderr'}
    total=0
    for parent in (folder,folder/'inputs',folder/'guest'):
        if not parent.is_dir():continue
        for name in sorted(allowed):
            path=parent/name
            if not path.exists() or path.is_symlink():continue
            info=path.stat()
            if not stat.S_ISREG(info.st_mode):continue
            limit=1048576 if name=='serial.log' else 262144
            with path.open('rb') as stream:data=stream.read(limit+1)
            truncated=len(data)>limit;data=data[:limit];total+=len(data)
            if total>4*1024**2:raise ValueError('retention quota exceeded')
            (artifacts/(parent.name+'-'+name)).write_bytes(data)
            if truncated:(artifacts/(parent.name+'-'+name+'.truncated')).write_text('bounded at '+str(limit)+' bytes\n')


def execute(folder,env=None,load=runpy.run_path,measure_closure=None,namespace_check=None):
    hosted(os.environ if env is None else env)
    folder=Path(folder).absolute()
    if not re.fullmatch('[A-Za-z0-9_/.-]+',str(folder)):raise ValueError('unsafe owned stage path')
    folder.mkdir(mode=0o700,parents=False,exist_ok=False)
    artifacts=folder/'artifacts';artifacts.mkdir(mode=0o700)
    record={'schemaVersion':1,'sourceCommit':(os.environ if env is None else env).get('GITHUB_SHA'),
            'runId':(os.environ if env is None else env)['GITHUB_RUN_ID'],
            'runAttempt':(os.environ if env is None else env)['GITHUB_RUN_ATTEMPT'],
            'executionRequested':False,'processStarted':False,'runtimeExecuted':False,
            'guestBaselineObserved':False,'packageInstallationAccepted':False,
            'firmwareAcceptance':False,'classicOsBootAcceptance':False}
    def save():(folder/'execution.json').write_text(json.dumps(record,sort_keys=True,indent=2)+'\n')
    save()
    try:
        if namespace_check is None:
            namespace_check=runpy.run_path(str(HERE/'host-namespace.py'))['require_bound']
        prefix=os.environ.get('WOOTC_HOST_DATA_PREFIX','')
        record['hostNamespace']=namespace_check(prefix);save()
        facts=load(str(HERE/'qualify.py'))['qualify'](folder,folder/'host.json')
        if not facts['qualified']:raise ValueError('actual qualified hosted resource/tool gate failed')
        record['hostClosure']=(closure(proof=folder/'tool-closure.json') if measure_closure is None else measure_closure());save()
        load(str(HERE/'acquire.py'))['acquire'](folder/'inputs')
        unchanged(record['hostClosure'])
        load(str(HERE/'prepare.py'))['prepare'](folder/'inputs',folder/'guest')
        unchanged(record['hostClosure'])
        launcher=load(str(HERE/'launch.py'))
        record['executionRequested']=True;save()
        def started(identity):
            record.update(processStarted=True,runtimeExecuted=True,ownedProcessIdentity=identity);save()
        def baseline():
            record['guestBaselineObserved']=True;save()
        result=launcher['launch'](folder/'guest',launcher['readback'],launcher['acknowledge'],
                                 on_started=started,on_baseline=baseline)
        if (not record['processStarted'] or not record['guestBaselineObserved'] or
                result.get('packageInstallationAccepted') is not True):raise ValueError('actual package proof absent')
        record['packageInstallationAccepted']=True;save()
        return record
    except BaseException as error:
        record['failureType']=type(error).__name__;record['failure']=str(error);save();raise
    finally:retain(folder,artifacts)


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('exclusive_stage');args=parser.parse_args()
    def cancelled(*_):raise InterruptedError('hosted cancellation received')
    signal.signal(signal.SIGTERM,cancelled);signal.signal(signal.SIGINT,cancelled)
    execute(args.exclusive_stage)
