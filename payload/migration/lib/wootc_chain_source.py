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
