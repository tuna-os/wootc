"""Freeze complete bootupd bundles, including its current versioned layout."""
import json
from pathlib import Path
from wootc_esp_transaction import digest, write_bytes, sync_directory
from wootc_chain_verify import FILES


def freeze_sources(destination, vendor=None, updates=Path('/usr/lib/bootupd/updates'),
                   versioned=Path('/usr/lib/efi')):
    metadata=updates/'EFI.json'
    raw=metadata.read_bytes()
    if len(raw)>65536:raise ValueError('oversized bootupd metadata')
    info=json.loads(raw)
    if (not isinstance(info,dict) or not isinstance(info.get('version'),str) or
            not info['version'] or not isinstance(info.get('timestamp'),str) or not info['timestamp']):
        raise ValueError('incomplete bootupd source metadata')
    direct=updates/'EFI'
    candidates={}
    if direct.is_dir():
        for folder in direct.iterdir():
            if folder.is_dir() and all((folder/n).is_file() for n in FILES):
                candidates[folder.name]={n:folder/n for n in FILES}
    versions={}
    entries=info.get('versions',[])
    if not isinstance(entries,list):raise ValueError('invalid bootupd package versions')
    for entry in entries:
        if (not isinstance(entry,dict) or not isinstance(entry.get('name'),str) or
                not isinstance(entry.get('rpm_evr'),str) or not entry['rpm_evr'] or
                entry['name'] in versions):
            raise ValueError('invalid/duplicate bootupd package version')
        versions[entry['name']]=entry['rpm_evr']
    if 'shim' in versions and 'grub2' in versions:
        for value in versions.values():
            if '/' in value or value in ('.','..'):raise ValueError('invalid bootupd package version')
        shim_root=versioned/'shim'/versions['shim']/'EFI'
        grub_root=versioned/'grub2'/versions['grub2']/'EFI'
        if shim_root.is_dir():
            for folder in shim_root.iterdir():
                paths={'shimx64.efi':folder/'shimx64.efi','mmx64.efi':folder/'mmx64.efi',
                       'grubx64.efi':grub_root/folder.name/'grubx64.efi'}
                if all(p.is_file() for p in paths.values()):
                    if folder.name in candidates and any(digest(paths[n])!=digest(candidates[folder.name][n]) for n in FILES):
                        raise ValueError('ambiguous bootupd source layouts for '+folder.name)
                    candidates[folder.name]=paths
    if vendor is not None:candidates={name:paths for name,paths in candidates.items() if name==vendor}
    if not candidates:raise ValueError('no complete same-vendor bootupd signed trio')
    destination=Path(destination);destination.mkdir(parents=True,exist_ok=True)
    write_bytes(destination/'EFI.json',raw,exclusive=True)
    result={}
    for name,paths in candidates.items():
        if name in ('.','..') or '/' in name:raise ValueError('invalid source vendor')
        before={n:digest(paths[n]) for n in FILES}
        target=destination/'EFI'/name;target.mkdir(parents=True)
        for n in FILES:write_bytes(target/n,paths[n].read_bytes(),exclusive=True)
        # Detect a source update across the snapshot, rather than pairing a new
        # metadata record with files read during an earlier bootupd transaction.
        if metadata.read_bytes()!=raw or any(digest(paths[n])!=before[n] or digest(target/n)!=before[n] for n in FILES):
            raise ValueError('bootupd bundle changed while freezing')
        sync_directory(target);sync_directory(target.parent)
        result[name]=target
    sync_directory(destination)
    return result


def classic_os_release(path):
    """Parse data, never source os-release as a shell program."""
    import shlex
    raw=Path(path).read_bytes()
    if len(raw)>65536:raise ValueError('oversized classic os-release')
    fields={}
    for line in raw.decode('utf-8').splitlines():
        if not line.strip() or line.lstrip().startswith('#'):continue
        if '=' not in line:raise ValueError('invalid classic os-release')
        key,value=line.split('=',1)
        if key in fields:raise ValueError('duplicate classic os-release field')
        tokens=shlex.split(value,comments=False,posix=True) if value else ['']
        if len(tokens)!=1:raise ValueError('invalid classic os-release value')
        fields[key]=tokens[0]
    if not fields.get('ID') or not fields.get('VERSION_ID'):
        raise ValueError('missing classic OS identity')
    return {key:fields[key] for key in ('ID','VERSION_ID')}


def classic_mount(path, mounts):
    """Resolve the actual deepest mount; a directory name is not provenance."""
    resolved=Path(path).resolve(strict=True)
    rows=[row for row in mounts if resolved==Path(row['target']) or Path(row['target']) in resolved.parents]
    if not rows:raise ValueError('classic source lacks measured mount')
    depth=max(len(Path(row['target']).parts) for row in rows)
    selected=[row for row in rows if len(Path(row['target']).parts)==depth]
    if len(selected)!=1:raise ValueError('ambiguous classic source mount')
    return resolved,selected[0]


def freeze_classic_sources(destination, observation, esp, host,
                           source=Path('/boot/efi'), os_release=Path('/etc/os-release'),
                           proc=Path('/proc'), sysroot=Path('/sys'), prefix=Path('/'), run=None):
    """Freeze package-owned classic payloads from this observed loop install.

    Signature verification remains mandatory in the common transaction. Package
    queries bind source/version facts; they do not stand in for signed trust.
    """
    import hashlib
    import datetime
    from wootc_boot_identity import command, mount_rows, loop_backings, read, require
    run=command if run is None else run
    require(observation.get('deploymentKind')=='classic', 'classic source requires observed classic root')
    mounts=mount_rows(proc)
    release_path,release_mount=classic_mount(os_release,mounts)
    require(release_mount['device']==observation['rootDevice'], 'os-release is outside installed classic root')
    release=classic_os_release(release_path)
    # These are the distro's canonical, installed package payloads. Source FAT
    # copies must match them exactly. Other providers need their own contract.
    rpm_vendors={'fedora':'fedora','almalinux':'almalinux','rocky':'rocky',
                 'centos':'centos','rhel':'redhat'}
    require(release['ID'] in ('debian','ubuntu') or release['ID'] in rpm_vendors,
            'no classic package source contract for this OS')
    manager='rpm' if release['ID'] in rpm_vendors else 'dpkg'
    vendor=rpm_vendors.get(release['ID'],release['ID'])
    roles={
        'shimx64.efi':('shim-signed','usr/lib/shim/shimx64.efi.signed'),
        'mmx64.efi':('shim-helpers-amd64-signed','usr/lib/shim/mmx64.efi.signed'),
        'grubx64.efi':('grub-efi-amd64-signed','usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed')}
    if vendor=='ubuntu':
        roles['shimx64.efi']=('shim-signed','usr/lib/shim/shimx64.efi.signed')
        roles['mmx64.efi']=('shim-signed','usr/lib/shim/mmx64.efi')
    if manager=='rpm':
        roles={name:('grub2-efi-x64' if name=='grubx64.efi' else 'shim-x64',None) for name in FILES}
    source_path,source_mount=classic_mount(source,mounts)
    _,destination_mount=classic_mount(esp,mounts)
    require(source_mount['device']!=destination_mount['device'], 'classic source aliases refresh destination')
    require(source_mount['type'] in ('vfat','msdos') or
            source_mount['device']==observation['rootDevice'],
            'classic source is neither an internal FAT nor the measured root filesystem')
    require(loop_backings(sysroot/'dev/block'/source_mount['device'])==[str(host)+observation['rootDiskPath']],
            'classic source is outside installed root.disk')
    source_uuid=run('blkid','-s','UUID','-o','value',source_mount['source']).strip()
    require(bool(source_uuid), 'missing classic source filesystem UUID')
    require(source_mount['device']!=observation['rootDevice'] or source_uuid==observation['rootFsUuid'],
            'classic source root filesystem UUID changed')
    candidates={};packages={};queries={};canonical_paths={}
    def query(*args):
        output=run(*args)
        require(args not in queries or queries[args]==output,
                'classic package changed between component queries')
        queries[args]=output
        return output
    for name,(package,relative) in roles.items():
        path=source_path/'EFI'/vendor/name
        require(path.parent.resolve(strict=True)==path.parent and not path.is_symlink() and path.is_file(),
                'missing regular complete classic signed trio')
        if manager=='dpkg':
            canonical,canonical_mount=classic_mount(Path(prefix)/relative,mounts)
            canonical_paths[Path(prefix)/relative]=canonical
            require(canonical_mount['device']==observation['rootDevice'], 'canonical payload outside classic root')
            owner=query('dpkg-query','--search',str(canonical)).strip()
            require(owner in (package+': '+str(canonical),package+':amd64: '+str(canonical)),
                    'canonical payload package owner differs')
            facts=query('dpkg-query','--show','--showformat=${binary:Package}\t${Version}\t${db:Status-Status}\t${Architecture}\n',package).strip().split('\t')
            require(len(facts)==4 and facts[3]=='amd64' and facts[0] in (package,package+':amd64') and facts[1] and facts[2]=='installed',
                    'classic signed package is not installed')
            expected=digest(canonical)
        else:
            format_info='%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{FILEDIGESTALGO}\n'
            facts_raw=query('rpm','-q','--qf',format_info,package)
            facts=facts_raw.strip().split('\t')
            require(len(facts)==4 and facts[0]==package and facts[1] and facts[2]=='x86_64' and facts[3]=='8',
                    'classic RPM owner/architecture/digest algorithm differs')
            rows=query('rpm','-q','--qf','[%{FILENAMES}\t%{FILEDIGESTS}\t%{FILESTATES}\t%{FILEMODES:octal}\n]',package).splitlines()
            version=facts[1].removeprefix('0:')
            require('/' not in version and version not in ('.','..'), 'invalid classic RPM version path')
            family='grub2' if name=='grubx64.efi' else 'shim'
            versioned=Path(prefix)/'usr/lib/efi'/family/version/'EFI'/vendor/name
            entries=[row.split('\t') for row in rows if row.split('\t')[0] in (str(path),str(versioned))]
            require(len(entries)==1 and len(entries[0])==4 and entries[0][2]=='0',
                    'classic RPM payload is missing, ambiguous or not installed normally')
            entry=entries[0];canonical=Path(entry[0])
            if canonical!=path:
                canonical,canonical_mount=classic_mount(canonical,mounts)
                require(canonical_mount['device']==observation['rootDevice'], 'canonical RPM payload outside classic root')
                canonical_paths[Path(entry[0])]=canonical
            require(query('rpm','-qf','--qf',format_info,str(canonical))==facts_raw,
                    'canonical RPM payload owner differs')
            require(len(entry[1])==64 and all(c in '0123456789abcdef' for c in entry[1]) and
                    int(entry[3],8)&0o170000==0o100000, 'invalid classic RPM file digest/type')
            expected=entry[1]
            require(digest(canonical)==expected, 'canonical RPM payload differs from installed package')
        package_fact={'version':facts[1],'architecture':facts[3] if manager=='dpkg' else facts[2]}
        require(package not in packages or packages[package]==package_fact,
                'classic package changed between component queries')
        packages[package]=package_fact
        require(digest(path)==expected, 'classic ESP payload differs from installed signed package')
        candidates[name]=(path,canonical,expected)
    kernel=read(proc/'sys/kernel/osrelease').decode().strip()
    require(bool(kernel), 'missing observed classic kernel release')
    facts={'schemaVersion':1,'sourceKind':'classic','os':release,'packages':packages,
           'packageManager':manager,'rootFsUuid':observation['rootFsUuid'],'sourceFsUuid':source_uuid,'kernelRelease':kernel,
           'components':{name:item[2] for name,item in candidates.items()}}
    stamp=hashlib.sha256(json.dumps(facts,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    facts.update(version='classic-sha256:'+stamp,
                 timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z'))
    destination=Path(destination);target=destination/'EFI'/vendor;target.mkdir(parents=True)
    for name,(path,canonical,expected) in candidates.items():
        write_bytes(target/name,path.read_bytes(),exclusive=True)
        require(digest(target/name)==expected and digest(path)==expected and digest(canonical)==expected,
                'classic payload changed while freezing')
    require(all(path.resolve(strict=True)==canonical for path,canonical in canonical_paths.items()),
            'classic payload selection changed while freezing')
    require(mount_rows(proc)==mounts, 'classic mount identity changed while freezing')
    require(Path(os_release).resolve(strict=True)==release_path, 'classic os-release selection changed while freezing')
    require(loop_backings(sysroot/'dev/block'/source_mount['device'])==[str(host)+observation['rootDiskPath']],
            'classic source loop ancestry changed while freezing')
    require(classic_os_release(release_path)==release, 'classic OS facts changed while freezing')
    # Re-query owners, versions and file metadata, closing an upgrade race.
    for args,expected in queries.items():
        require(run(*args)==expected, 'classic package changed while freezing')
    write_bytes(destination/'EFI.json',json.dumps(facts,sort_keys=True).encode(),exclusive=True)
    sync_directory(target);sync_directory(target.parent);sync_directory(destination)
    return {vendor:target}
