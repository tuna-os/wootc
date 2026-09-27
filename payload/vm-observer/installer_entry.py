"""Fixed offline target installer entry, invoked only by authenticated initrd.

No guest protocol invokes this entry. Successful installation is not guest boot,
ordinary desktop, editor, or persistence acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time

INPUT=Path('/run/wootc-observer-input')
SYSROOT=Path('/run/wootc-observer-sysroot')
MODULES={'boot_probe.py','python_environment.py','install_policy.py','install_bundle.py',
         'installer_commands.py','deployment_selection.py','label_policy.py','install_graph.py'}
FILES=MODULES|{'wootc_ancestry.py','wootc-observer.service'}


def unique(pairs):
    result={}
    for key,value in pairs:
        if key in result:raise ValueError('duplicate installer catalogue field')
        result[key]=value
    return result


def read_initial(path):
    # Bootstrap uses only fixed protected paths before loading reviewed modules.
    for parent in [path.parent,*path.parent.parents]:
        info=parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or info.st_mode&0o022:
            raise ValueError('installer input parent unprotected')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid!=0 or before.st_mode&0o022 or before.st_nlink!=1 or before.st_size>131072:
            raise ValueError('installer input file unprotected')
        raw=os.read(fd,131073);after=os.fstat(fd);current=path.lstat()
        identity=lambda value:(value.st_dev,value.st_ino,value.st_size,value.st_mtime_ns)
        if len(raw)!=before.st_size or identity(before)!=identity(after) or identity(before)!=identity(current):
            raise ValueError('installer input changed while reading')
        return raw
    finally:os.close(fd)


def load_catalogue(expected):
    if not re.fullmatch('[0-9a-f]{64}',expected):raise ValueError('authenticated catalogue hash missing')
    raw=read_initial(INPUT/'catalogue.json')
    if hashlib.sha256(raw).hexdigest()!=expected:raise ValueError('authenticated catalogue differs')
    catalogue=json.loads(raw,object_pairs_hook=unique)
    if type(catalogue) is not dict or set(catalogue)!=FILES or any(type(value) is not str or not re.fullmatch('[0-9a-f]{64}',value) for value in catalogue.values()):
        raise ValueError('fixed installer catalogue incomplete')
    data={}
    for name,digest in catalogue.items():
        raw=read_initial(INPUT/name)
        if hashlib.sha256(raw).hexdigest()!=digest:raise ValueError('authenticated installer source differs')
        data[name]=raw
    return catalogue,data


def load_module(name,raw):
    # Only authenticated fixed source names above; not a generic import route.
    value={'__name__':'wootc_fixed_'+name.replace('.','_'),'__file__':str(INPUT/name)}
    exec(compile(raw,str(INPUT/name),'exec'),value)
    return value


def label_tool_adapter(tools):
    def protected(path):
        if path != '/usr/sbin/matchpathcon' or set(tools) != {'findmnt', 'matchpathcon'}:
            raise ValueError('target label tool outside fixed scope')
        return tools['matchpathcon']
    return protected


def install(args):
    deadline=time.monotonic()+20
    catalogue,data=load_catalogue(args.catalogue_sha256)
    environment=load_module('python_environment.py',data['python_environment.py'])
    environment['inspect_environment']()
    modules={name:load_module(name,data[name]) for name in MODULES if name!='python_environment.py'}
    initial_environment=environment['inspect_environment']()
    bundle=modules['install_bundle.py'];commands=modules['installer_commands.py']
    selection=modules['deployment_selection.py'];probe=modules['boot_probe.py'];policy=modules['install_policy.py']
    bundle['directory'](SYSROOT)
    tools={}
    for name,path in [('findmnt','/usr/bin/findmnt'),('matchpathcon','/usr/sbin/matchpathcon')]:
        _,resolved=environment['protected_path'](path)
        if not resolved.is_relative_to('/usr'):raise ValueError('target installer tool outside authenticated usr')
        tools[name]=resolved
    # Fixed read-only argv; no obsolete setfiles mutation route.
    def execute(argv):
        if argv==[str(tools['findmnt']),'--json','--output',commands['OUTPUT'],'--mountpoint','/run/wootc-observer-input'] or argv==[str(tools['findmnt']),'--json','--output',commands['OUTPUT'],'--mountpoint','/run/wootc-observer-sysroot'] or argv==[str(tools['findmnt']),'--json','--output',commands['OUTPUT'],'--mountpoint','/run/wootc-observer-sysroot/boot'] or argv==[str(tools['findmnt']),'--json','--output',commands['OUTPUT'],'--mountpoint','/var']:
            return probe['_run_owned'](argv,deadline)
        if len(argv)==3 and argv[:2]==[str(tools['matchpathcon']),'-n'] and argv[2] in commands['LABEL_PATHS']:
            return probe['_run_owned'](argv,deadline)
        raise ValueError('installer command outside fixed production scope')
    input_info=INPUT.lstat()
    if str(input_info.st_dev)+':'+str(input_info.st_ino)!=args.input_inode:
        raise ValueError('input lease inode differs from authenticated initrd')
    row=commands['observed_mount'](execute,tools['findmnt'],str(INPUT),args.input_major,True)
    if row['source']!=args.input_source:raise ValueError('input lease source subtree differs')
    root_row=commands['observed_mount'](execute,tools['findmnt'],str(SYSROOT),args.root_major,True)
    if root_row['fstype'] not in {'ext4','xfs'}:
        raise ValueError('offline target requires measured single-device ext4/xfs; Btrfs member proof unavailable')
    _,lsblk=environment['protected_path']('/usr/bin/lsblk')
    graph=probe['_run_owned']([str(lsblk),'--json','--paths','--output','NAME,TYPE,MAJ:MIN,PTUUID'],deadline)
    ancestry=modules['install_graph.py']['verify_partition'](graph,root_row['source'],root_row['maj:min'],args.disk)
    boot_row=commands['observed_mount'](execute,tools['findmnt'],str(SYSROOT/'boot'),args.boot_major,True)
    if boot_row['fstype'] not in {'ext4','xfs'}:raise ValueError('offline boot filesystem member proof unavailable')
    boot_ancestry=modules['install_graph.py']['verify_partition'](graph,boot_row['source'],boot_row['maj:min'],args.disk)
    selected=selection['select_installed_deployment'](SYSROOT,args.image,bundle['read_owned'],bundle['directory'])
    identity=lambda path:(Path(path).stat().st_dev,Path(path).stat().st_ino)
    if identity(selected['deployment'])!=identity('/') or identity(selected['stateVar'])!=identity('/var'):
        raise ValueError('chroot or persistent var differs from installed BLS selection')
    commands['observed_mount'](execute,tools['findmnt'],'/var',args.root_major,False)
    persistence=policy['validate_persistence'](Path('/'),[selected['bls']['options']])
    expected={name:catalogue[name] for name in ['boot_probe.py','wootc_ancestry.py','wootc-observer.service']}
    with bundle['observer_transaction'](Path('/'),INPUT,expected) as transaction:
        transaction['enable']()
        labels=modules['label_policy.py']['label_transaction_objects'](transaction['objects'](),bundle['read_owned'],label_tool_adapter(tools),execute)
        # Current authenticated input and dependency closure must remain exact.
        if load_catalogue(args.catalogue_sha256)[0]!=catalogue:raise ValueError('installer catalogue changed')
        final_environment=environment['inspect_environment']()
        if (final_environment['interpreter']!=initial_environment['interpreter'] or
                final_environment['stdlibRoots']!=initial_environment['stdlibRoots'] or
                any(final_environment['loadedDependencies'].get(name)!=digest for name,digest in initial_environment['loadedDependencies'].items()) or
                not set(initial_environment['mappedDependencies']).issubset(final_environment['mappedDependencies'])):
            raise ValueError('target dependency closure changed')
        if selection['select_installed_deployment'](SYSROOT,args.image,bundle['read_owned'],bundle['directory'])!=selected:
            raise ValueError('installed BLS/origin selection changed')
        if identity(selected['deployment'])!=identity('/') or identity(selected['stateVar'])!=identity('/var'):
            raise ValueError('installed namespace changed before commit')
        if policy['validate_persistence'](Path('/'),[selected['bls']['options']])!=persistence:
            raise ValueError('installed persistence policy changed')
        if time.monotonic()>=deadline:raise TimeoutError('target installation deadline expired')
    return {'schemaVersion':1,'action':'install-observer','runId':args.run_id,'installId':args.install_id,
            'selectedDisk':args.disk,'image':args.image,'sourceHashes':expected,'labels':labels,'targetDependencies':final_environment,
            'offlineAncestry':ancestry,'offlineBootAncestry':boot_ancestry,'persistenceConfiguration':persistence,
            'installed':True,'guestBootAccepted':False,'desktopQualified':False,'editorQualified':False}


def main():
    parser=argparse.ArgumentParser()
    for name in ['catalogue-sha256','input-inode','input-source','input-major','root-major','boot-major','disk','image','run-id','install-id']:
        parser.add_argument('--'+name,required=True)
    args=parser.parse_args()
    for value in (args.run_id,args.install_id):
        if not re.fullmatch('[A-Za-z0-9][A-Za-z0-9_-]{7,63}',value):raise ValueError('installer identity malformed')
    result=install(args)
    print(json.dumps(result,sort_keys=True))

if __name__=='__main__':main()
