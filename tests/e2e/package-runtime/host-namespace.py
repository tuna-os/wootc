"""Run the real controller in an owned private mount namespace, not a QEMU PID proxy."""
import ctypes
import errno
import json
import os
from pathlib import Path
import re
import runpy
import subprocess

HERE=Path(__file__).resolve().parent
TRUST=runpy.run_path(str(HERE/'hosted-execute.py'))
DATA=runpy.run_path(str(HERE/'host-data.py'))
ALIASES={'usr/share':'/usr/share','usr/lib/ipxe/qemu':'/usr/lib/ipxe/qemu'}


def checked(prefix):
    prefix=Path(prefix)
    if not re.fullmatch('/run/wootc-package-host-[0-9]+-[0-9]+',str(prefix)):
        raise ValueError('unexpected protected host prefix')
    source=TRUST['protected'](prefix/'host-data.json')
    if source.stat().st_size>262144:raise ValueError('host data receipt exceeds bound')
    record=json.loads(source.read_text())
    if (type(record.get('schemaVersion')) is not int or record['schemaVersion']!=1 or
            record.get('complete') is not True or record.get('prefix')!=str(prefix) or
            record.get('sourceCommit')!=os.environ.get('GITHUB_SHA') or
            record.get('producerSha256')!=DATA['sha'](HERE/'host-data.py') or
            {pin['Package'] for pin in record.get('packages',[])}!=set(DATA['PACKAGES'])):
        raise ValueError('complete source-bound authenticated prefix receipt required')
    declared=record['resources']
    actual={str(path.relative_to(prefix)) for root in DATA['RESOURCES'] for path in (prefix/root).rglob('*') if path.is_file()}
    if actual!=set(declared):raise ValueError('prefix resource set differs')
    for name,pin in declared.items():
        if not DATA['selected'](name) or '..' in Path(name).parts:raise ValueError('unexpected declared resource')
        path=TRUST['protected'](prefix/name)
        if DATA['sha'](path)!=pin['sha256']:raise ValueError('protected authenticated resource differs')
    return record


def _private_namespace(prefix):
    """Mount only inside CLONE_NEWNS, after propagation is made recursively private."""
    checked(prefix)
    before=os.readlink('/proc/self/ns/mnt')
    libc=ctypes.CDLL(None,use_errno=True)
    if libc.unshare(0x00020000)!=0:raise OSError(ctypes.get_errno(),'private mount namespace unavailable')
    def mount(source,target,flags):
        encoded=lambda value:None if value is None else os.fsencode(value)
        if libc.mount(encoded(source),encoded(target),None,flags,None)!=0:
            raise OSError(ctypes.get_errno(),'owned namespace mount failed: '+str(target))
    mount(None,'/',(1<<14)|(1<<18)) # MS_REC | MS_PRIVATE before any bind
    for relative,target in ALIASES.items():
        source=Path(prefix)/relative
        if not source.is_dir() or not Path(target).is_dir():raise ValueError('complete namespace source/target directory missing')
        mount(source,target,4096) # MS_BIND
        mount(None,target,4096|32|1) # MS_BIND | MS_REMOUNT | MS_RDONLY
    readonly=[]
    for target in ALIASES.values():
        try:
            with (Path(target)/'.wootc-private-readonly-probe').open('xb') as stream:stream.write(b'refuse writable alias')
        except OSError as error:
            if error.errno!=errno.EROFS:raise
            readonly.append(target)
        else:raise ValueError('actual namespace alias accepted root write')
    after=os.readlink('/proc/self/ns/mnt')
    if before==after:raise ValueError('mount namespace did not change')
    checked(prefix)
    evidence={'beforeNamespace':before,'privateNamespace':after,'bindings':ALIASES,'kernelReadonlyWriteRefusals':readonly,'runtimeExecuted':False}
    target=Path(prefix)/'namespace.json'
    with target.open('x') as stream:json.dump(evidence,stream,sort_keys=True);stream.write('\n')
    target.chmod(0o444)
    return evidence


def private_namespace(prefix):
    try:return _private_namespace(prefix)
    except BaseException as error:
        # Only publish into the checked owned prefix. A failure is evidence,
        # not authority to launch or a claim that isolation succeeded.
        checked(prefix)
        target=Path(prefix)/'namespace-failure.json'
        with target.open('x') as output:
            json.dump({'schemaVersion':1,'failureType':type(error).__name__,
                       'failure':str(error),'runtimeExecuted':False},output,sort_keys=True)
            output.write('\n');output.flush();os.fsync(output.fileno())
        target.chmod(0o444)
        raise


def require_bound(prefix):
    record=checked(prefix);prefix=Path(prefix)
    receipt=TRUST['protected'](prefix/'namespace.json')
    if receipt.stat().st_size>4096:raise ValueError('namespace receipt exceeds bound')
    evidence=json.loads(receipt.read_text())
    current=os.readlink('/proc/self/ns/mnt')
    if (evidence.get('privateNamespace')!=current or evidence.get('beforeNamespace')==current or
            evidence.get('bindings')!=ALIASES):raise ValueError('actual current private namespace differs')
    mounts=[]
    for row in Path('/proc/self/mountinfo').read_text().splitlines():
        left=row.split(' - ',1)[0].split()
        if len(left)>=6:mounts.append(left)
    for relative,alias in ALIASES.items():
        observed=Path(alias).stat();source=(prefix/relative).stat()
        if (observed.st_dev,observed.st_ino)!=(source.st_dev,source.st_ino):raise ValueError('actual data alias does not bind protected prefix')
        selected=[row for row in mounts if row[4]==alias]
        if len(selected)!=1 or 'ro' not in selected[0][5].split(','):raise ValueError('actual data alias is not one readonly namespace mount')
    return dict(evidence,hostDataSourceSha256=DATA['sha'](prefix/'host-data.json'),namespaceReceiptSha256=DATA['sha'](receipt))


def probe(prefix):
    require_bound(prefix)
    output=Path(os.environ['RUNNER_TEMP'])/'protected-namespace-closure.json'
    hashes=TRUST['closure'](proof=output)
    qemu=TRUST['protected']('/usr/bin/qemu-system-x86_64')
    data=Path(prefix)/'usr/share/qemu'
    dirs=subprocess.run([str(qemu),'-L',str(data),'-L','help'],check=True,capture_output=True,text=True,timeout=10).stdout.splitlines()
    if set(dirs)!={str(data),'/usr/share/qemu','/usr/share/seabios','/usr/lib/ipxe/qemu'}:
        raise ValueError('actual QEMU search roots outside protected namespace contract')
    for root in dirs:
        info=Path(root).stat()
        if info.st_uid!=0 or info.st_mode&0o022:raise ValueError('actual searched data directory is writable')
    return {'protectedFiles':len(hashes),'actualDataSearchRoots':dirs,'runtimeExecuted':False}


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('prefix');parser.add_argument('--probe',action='store_true');parser.add_argument('--inside-probe',action='store_true');parser.add_argument('--execute');args=parser.parse_args()
    if args.inside_probe:
        print(json.dumps(probe(args.prefix),sort_keys=True))
    else:
        TRUST['hosted'](os.environ)
        if os.getuid()!=0:raise ValueError('only privileged private namespace creation is supported')
        if bool(args.probe)==bool(args.execute):raise ValueError('one source probe or reviewed execution required')
        identity=private_namespace(args.prefix)
        print(json.dumps(identity,sort_keys=True),flush=True)
        uid,gid=os.environ.get('SUDO_UID',''),os.environ.get('SUDO_GID','')
        if not uid.isdigit() or not gid.isdigit() or int(uid)==0:raise ValueError('actual calling unprivileged identity absent')
        env=dict(os.environ,WOOTC_HOST_DATA_PREFIX=args.prefix)
        argv=['/usr/bin/setpriv','--reuid='+uid,'--regid='+gid,'--clear-groups','/usr/bin/python3']
        if args.probe:argv.extend([str(Path(__file__).resolve()),args.prefix,'--inside-probe'])
        else:argv.extend([str(HERE/'hosted-execute.py'),args.execute])
        TRUST['protected']('/usr/bin/setpriv')
        os.execve(argv[0],argv,env)
