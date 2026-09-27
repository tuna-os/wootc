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

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]


def hosted(env):
    if (env.get('GITHUB_ACTIONS')!='true' or env.get('RUNNER_ENVIRONMENT')!='github-hosted' or
            env.get('RUNNER_OS')!='Linux' or not re.fullmatch('[0-9]+',env.get('GITHUB_RUN_ID','')) or
            not re.fullmatch('[0-9]+',env.get('GITHUB_RUN_ATTEMPT','')) or
            not re.fullmatch('[0-9a-f]{40}',env.get('GITHUB_SHA',''))):
        raise ValueError('fresh GitHub-hosted Linux execution contract required')


def protected(path):
    path=Path(path).resolve(strict=True);info=path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or info.st_mode&0o022:
        raise ValueError('host tool/firmware source is not protected regular root file')
    for parent in path.parents:
        meta=parent.stat()
        if meta.st_uid!=0 or meta.st_mode&0o022:raise ValueError('host source parent is writable')
    return path


def closure(run=subprocess.run):
    paths=set()
    env={'PATH':'/usr/bin:/bin','LANG':'C','LC_ALL':'C'}
    sources=['/usr/bin/qemu-system-x86_64','/usr/bin/qemu-img','/usr/bin/genisoimage']
    modules=sorted(Path('/usr/lib/x86_64-linux-gnu/qemu').glob('*.so'))
    if not modules:raise ValueError('installed QEMU module closure absent')
    sources.extend(str(path) for path in modules)
    for source in sources:
        executable=protected(source);paths.add(executable)
        reply=run(['/usr/bin/ldd',str(executable)],check=True,capture_output=True,text=True,timeout=10,env=env)
        dependencies=set()
        for line in reply.stdout.splitlines():
            if 'not found' in line:raise ValueError('host dynamic tool dependency missing')
            candidates=re.findall(r'(?<!\S)(/[^\s]+)',line)
            for value in candidates:dependencies.add(protected(value))
        if not dependencies:raise ValueError('tool dependency closure absent')
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
             'pid.json','old-phase-readback.json','old-phase-advance.json','serial.log','process.stdout','process.stderr'}
    total=0
    for parent in (folder,folder/'inputs',folder/'guest'):
        if not parent.is_dir():continue
        for name in sorted(allowed):
            path=parent/name
            if not path.exists() or path.is_symlink():continue
            info=path.stat()
            if not stat.S_ISREG(info.st_mode):continue
            with path.open('rb') as stream:data=stream.read(262145)
            truncated=len(data)>262144;data=data[:262144];total+=len(data)
            if total>4*1024**2:raise ValueError('retention quota exceeded')
            (artifacts/(parent.name+'-'+name)).write_bytes(data)
            if truncated:(artifacts/(parent.name+'-'+name+'.truncated')).write_text('bounded at 262144 bytes\n')


def execute(folder,env=None,load=runpy.run_path,measure_closure=closure):
    hosted(os.environ if env is None else env)
    folder=Path(folder).absolute()
    if not re.fullmatch('[A-Za-z0-9_/.-]+',str(folder)):raise ValueError('unsafe owned stage path')
    folder.mkdir(mode=0o700,parents=False,exist_ok=False)
    artifacts=folder/'artifacts';artifacts.mkdir(mode=0o700)
    record={'schemaVersion':1,'sourceCommit':(os.environ if env is None else env).get('GITHUB_SHA'),
            'runId':(os.environ if env is None else env)['GITHUB_RUN_ID'],
            'runAttempt':(os.environ if env is None else env)['GITHUB_RUN_ATTEMPT'],
            'runtimeExecuted':False,'packageInstallationAccepted':False,
            'firmwareAcceptance':False,'classicOsBootAcceptance':False}
    def save():(folder/'execution.json').write_text(json.dumps(record,sort_keys=True,indent=2)+'\n')
    save()
    try:
        facts=load(str(HERE/'qualify.py'))['qualify'](folder,folder/'host.json')
        if not facts['qualified']:raise ValueError('actual qualified hosted resource/tool gate failed')
        record['hostClosure']=measure_closure();save()
        load(str(HERE/'acquire.py'))['acquire'](folder/'inputs')
        unchanged(record['hostClosure'])
        load(str(HERE/'prepare.py'))['prepare'](folder/'inputs',folder/'guest')
        unchanged(record['hostClosure'])
        launcher=load(str(HERE/'launch.py'))
        record['runtimeExecuted']=True;save()
        result=launcher['launch'](folder/'guest',launcher['readback'],launcher['acknowledge'])
        if result.get('packageInstallationAccepted') is not True:raise ValueError('actual package proof absent')
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
