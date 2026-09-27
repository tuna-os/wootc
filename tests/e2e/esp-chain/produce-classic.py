"""Offline classic QA baseline producer. All writes belong to a new private overlay."""
import argparse
import base64
import copy
import tempfile
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'payload/migration/lib'))
from wootc_chain_verify import FILES, verify_transition, Verifier, checked_database, efi_variable, DB_GUID, SHIM_GUID, GLOBAL
from wootc_pe import PE, X509
provision = runpy.run_path(str(Path(__file__).with_name('scratch.py')))['provision']


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def checked_inputs(config):
    inputs = [config['windowsBaseline'], config['classicCloudImage']]
    inputs += config['oldPackages']+config['newPackages']+list(config['oldTrio'].values())+list(config['newTrio'].values())
    if set(config['oldTrio']) != set(FILES) or set(config['newTrio']) != set(FILES):
        raise ValueError('complete pinned new trio required')
    seen = {}
    for entry in inputs:
        path = Path(entry['path'])
        if path.is_symlink() or not path.is_file() or sha(path) != entry['sha256']:
            raise ValueError('pinned producer input differs: '+str(path))
        if ':' in str(path) or path.name.startswith('-'):
            raise ValueError('unsupported upload path')
        if path.name in seen and seen[path.name] != entry['sha256']:
            raise ValueError('ambiguous input filename')
        seen[path.name] = entry['sha256']
    if not re.fullmatch('[A-Z]:', config['windowsVolume']):
        raise ValueError('explicit Windows volume required')
    if config['osId'] not in ('debian', 'ubuntu', 'fedora', 'almalinux', 'rocky', 'centos', 'rhel'):
        raise ValueError('unsupported classic producer OS')
    if not config['oldPackages'] or not config['newPackages']:
        raise ValueError('complete old/new package bundles required')
    # Public native proof pins every byte in the verifier closure.
    closure = Path(config['verifierClosure'])
    pins = json.loads((ROOT/'docs/experiments/evidence/2026-09-27-classic-versioned-rpm/provenance.json').read_text())['verifierClosureHashes']
    for name, expected in pins.items():
        if sha(closure/name) != expected:
            raise ValueError('verifier closure differs')
    variables = Path(config['firmwareVariables'])
    required = [('SecureBoot', GLOBAL), ('SetupMode', GLOBAL), ('db', DB_GUID), ('dbx', DB_GUID), ('SbatLevelRT', SHIM_GUID)]
    if any(n+'-'+g not in config['firmwareVariableHashes'] for n, g in required):
        raise ValueError('complete baseline firmware export required')
    if not config['firmwareVariableHashes']:
        raise ValueError('actual baseline firmware export required')
    for name, expected in config['firmwareVariableHashes'].items():
        if Path(name).name != name or sha(variables/name) != expected:
            raise ValueError('firmware export differs')
    if efi_variable(variables, 'SecureBoot', GLOBAL) != b'\1' or efi_variable(variables, 'SetupMode', GLOBAL) != b'\0':
        raise ValueError('actual baseline firmware is not Secure Boot outside SetupMode')
    if config['minimumFreeBytes'] < 20*1024**3:
        raise ValueError('producer space floor must be at least 20GiB')
    return closure, variables


def freeze_file(source, target, expected):
    source, target = Path(source), Path(target)
    if source.is_symlink() or sha(source) != expected:
        raise ValueError('pinned source changed before freezing')
    with source.open('rb') as reader, target.open('xb') as writer:
        shutil.copyfileobj(reader, writer)
        writer.flush(); os.fsync(writer.fileno())
    target.chmod(0o400)
    if sha(source) != expected or sha(target) != expected:
        raise ValueError('pinned source changed while freezing')
    return target


def freeze_inputs(parent, config):
    parent = Path(parent)
    if parent.is_symlink() or parent.stat().st_uid != os.getuid() or parent.stat().st_mode & 0o077:
        raise ValueError('scratch parent must be caller-owned and private')
    folder = Path(tempfile.mkdtemp(prefix='producer-inputs-', dir=parent))
    frozen = copy.deepcopy(config)
    entries = [frozen['windowsBaseline'], frozen['classicCloudImage']]+frozen['oldPackages']+frozen['newPackages']+list(frozen['oldTrio'].values())+list(frozen['newTrio'].values())
    for index, entry in enumerate(entries):
        destination = folder/str(index); destination.mkdir(mode=0o700)
        entry['path'] = str(freeze_file(entry['path'], destination/Path(entry['path']).name, entry['sha256']))
    return frozen


def mount_os(guest, root):
    points = guest.inspect_get_mountpoints(root)
    for mount, device in sorted(points.items(), key=lambda row: len(row[0])):
        guest.mount(device, mount)


def guest_open(module, path, readonly=False):
    guest = module.GuestFS(python_return_dict=True)
    guest.add_drive_opts(str(path), readonly=readonly)
    guest.launch()
    return guest


def produce(parent, config, run=subprocess.run):
    source_pins = {p: sha(p) for directory in (ROOT/'payload/migration', ROOT/'platform/dracut/99wootc-boot', Path(__file__).parent) for p in directory.rglob('*') if p.is_file() and p.suffix != '.pyc' and '__pycache__' not in p.parts}
    closure, variables = checked_inputs(config)  # Refuse malformed sources before any write.
    for executable in ('qemu-img', 'virt-customize'):
        if not shutil.which(executable):
            raise ValueError('producer dependency absent: '+executable)
    guestfs = importlib.import_module('guestfs')
    parent = Path(parent).resolve(strict=True)
    if shutil.disk_usage(parent).free < config['minimumFreeBytes']:
        raise ValueError('insufficient private QA build space')
    original_config = copy.deepcopy(config)
    config = freeze_inputs(parent, config)
    record = provision(parent, Path(config['windowsBaseline']['path']), config['windowsBaseline']['sha256'], run)
    Path(record['overlay']).chmod(0o600)
    folder = Path(record['overlay']).parent
    source_folder = folder/'source-closure'; source_folder.mkdir(mode=0o700)
    frozen_sources = {p: freeze_file(p, source_folder/str(i), h) for i, (p, h) in enumerate(source_pins.items())}
    frozen_variables = folder/'firmware-vars'; frozen_variables.mkdir()
    for name, expected in config['firmwareVariableHashes'].items():
        shutil.copyfile(variables/name, frozen_variables/name)
        if sha(frozen_variables/name) != expected or sha(variables/name) != expected:
            raise ValueError('firmware export changed while freezing')
    variables = frozen_variables
    frozen_closure = folder/'verifier-closure'; shutil.copytree(closure, frozen_closure)
    closure_pins = json.loads((ROOT/'docs/experiments/evidence/2026-09-27-classic-versioned-rpm/provenance.json').read_text())['verifierClosureHashes']
    if any(sha(frozen_closure/n) != expected or sha(closure/n) != expected for n, expected in closure_pins.items()):
        raise ValueError('verifier changed while freezing')
    closure = frozen_closure
    record['state'] = 'classic-producing'
    (folder/'scratch.json').write_text(json.dumps(record, indent=2)+'\n')
    disk = folder/'root.disk'
    run(['qemu-img', 'convert', '-f', 'qcow2', '-O', 'raw', config['classicCloudImage']['path'], str(disk)],
        check=True, timeout=1800)
    cloud = guest_open(guestfs, disk)
    try:
        roots = cloud.inspect_os()
        if len(roots) != 1 or cloud.inspect_get_type(roots[0]) != 'linux' or cloud.inspect_get_arch(roots[0]) != 'x86_64':
            raise ValueError('classic source is not one complete amd64 Linux OS')
        mount_os(cloud, roots[0])
        release = cloud.read_file('/etc/os-release').decode()
        if not re.search(r'^ID=["\']?'+re.escape(config['osId'])+r'["\']?$', release, re.M):
            raise ValueError('actual classic OS differs from planned provider')
        if cloud.is_file('/usr/bin/bootc'):
            raise ValueError('classic producer cannot relabel a bootc image')
        cloud.umount_all()
    finally:
        cloud.close()
    uploads = {}
    for path in (ROOT/'platform/dracut/99wootc-boot').iterdir():
        if path.is_file():
            uploads[path] = '/usr/lib/dracut/modules.d/99wootc-boot/'+path.name
    for path in (ROOT/'payload/migration/lib').glob('wootc_*.py'):
        uploads[path] = '/var/usrlocal/lib/wootc/'+path.name
    for name in ('wootc-esp-control', 'wootc-esp-sync'):
        uploads[ROOT/'payload/migration'/name] = '/var/usrlocal/bin/'+name
    uploads[ROOT/'payload/migration/wootc-host-view'] = '/etc/wootc/host-view'
    for name in ('wootc-esp-sync.service', 'wootc-esp-sync.path', 'wootc-host-bind.service'):
        uploads[ROOT/'payload/migration'/name] = '/etc/systemd/system/'+name
    for path in closure.iterdir():
        if path.is_file():
            uploads[path] = '/var/usrlocal/lib/wootc/sbverify/'+path.name
    for name in ('capture.py', 'upgrade-classic.py', 'stage-classic-source.py'):
        uploads[Path(__file__).with_name(name)] = '/var/usrlocal/lib/wootc-qa/'+name
    for entry in config['oldPackages']+config['newPackages']:
        uploads[Path(entry['path'])] = '/var/lib/wootc/qa-upgrade/'+Path(entry['path']).name
    manager = 'dpkg' if config['osId'] in ('debian', 'ubuntu') else 'rpm'
    package_record = folder/'packages.json'
    package_record.write_text(json.dumps({'manager': manager, 'newPackages': {Path(e['path']).name: e['sha256'] for e in config['newPackages']}}))
    uploads[package_record] = '/var/lib/wootc/qa-upgrade/packages.json'
    prepare = folder/'prepare-classic.sh'
    old_names = [shlex.quote('/var/lib/wootc/qa-upgrade/'+Path(e['path']).name) for e in config['oldPackages']]
    prerequisites = ('apt-get update\nDEBIAN_FRONTEND=noninteractive apt-get install -y dracut ntfs-3g qemu-guest-agent python3 efibootmgr' if manager == 'dpkg' else 'dnf install -y dracut ntfs-3g qemu-guest-agent python3 efibootmgr')
    install = ('dpkg --install ' if manager == 'dpkg' else 'dnf --assumeyes --allowerasing install ')+ ' '.join(old_names)
    prepare.write_text('''#!/bin/bash
set -Eeuo pipefail
'''+prerequisites+'\n'+install+'''
chmod 0755 /var/usrlocal/bin/wootc-esp-* /var/usrlocal/lib/wootc/sbverify/ld-linux-x86-64.so.2 /var/usrlocal/lib/wootc/sbverify/sbverify /var/usrlocal/lib/wootc/sbverify/sbpehash
python3 /var/usrlocal/lib/wootc-qa/stage-classic-source.py
kernel=$(find /boot -maxdepth 1 -name 'vmlinuz-*' -type f | sort -V | tail -1)
[[ -n "$kernel" ]]
kver=${kernel##*/vmlinuz-}
printf '%s\\n' "$kernel" > /var/lib/wootc/qa-upgrade/kernel-path
printf '%s\\n' "/boot/initrd.img-$kver" > /var/lib/wootc/qa-upgrade/initrd-path
dracut --force --no-hostonly --add wootc-boot "/boot/initrd.img-$kver" "$kver"
lsinitrd "/boot/initrd.img-$kver" > /var/lib/wootc/qa-upgrade/initrd-contents.txt
grep -q wootc-attach.service /var/lib/wootc/qa-upgrade/initrd-contents.txt
touch /etc/cloud/cloud-init.disabled
systemctl enable qemu-guest-agent.service wootc-host-bind.service wootc-esp-sync.service wootc-esp-sync.path
''')
    directories = sorted({str(Path(path).parent) for path in uploads.values()})
    package_pins = {Path(e['path']): e['sha256'] for e in config['oldPackages']+config['newPackages']}
    uploaded_hashes = {}
    frozen_uploads = {}
    upload_folder = folder/'uploads'; upload_folder.mkdir(mode=0o700)
    for index, (path, destination) in enumerate(uploads.items()):
        expected = package_pins[path] if path in package_pins else source_pins[path] if path in source_pins else sha(path)
        frozen_path = freeze_file(frozen_sources.get(path, path), upload_folder/str(index), expected)
        frozen_uploads[frozen_path] = destination
        uploaded_hashes[destination] = expected
    uploads = frozen_uploads
    source_provenance = {str(p.relative_to(ROOT)): h for p, h in source_pins.items()}
    if any(sha(p) != h for p, h in source_pins.items()):
        raise ValueError('production source changed before upload')
    command = ['virt-customize', '-a', str(disk), '--run-command', 'mkdir -p '+' '.join(shlex.quote(d) for d in directories)]
    for path, destination in uploads.items():
        command += ['--upload', str(path)+':'+destination]
    command += ['--run', str(prepare)]
    run(command, check=True, timeout=3600)
    cloud = guest_open(guestfs, disk)
    old = folder/'old-trio'; old.mkdir()
    try:
        roots = cloud.inspect_os(); mount_os(cloud, roots[0])
        if any(cloud.checksum('sha256', path) != expected for path, expected in uploaded_hashes.items()):
            raise ValueError('actual uploaded helper or package hash differs')
        root_uuid = cloud.vfs_uuid(roots[0])
        vendor = {'rhel': 'redhat'}.get(config['osId'], config['osId'])
        for name in FILES:
            cloud.download('/boot/efi/EFI/'+vendor+'/'+name, str(old/name))
        kernel_path = cloud.read_file('/var/lib/wootc/qa-upgrade/kernel-path').decode().strip()
        initrd_path = cloud.read_file('/var/lib/wootc/qa-upgrade/initrd-path').decode().strip()
        cloud.download(kernel_path, str(folder/'vmlinuz'))
        cloud.download(initrd_path, str(folder/'initrd'))
        cloud.umount_all()
    finally:
        cloud.close()
    if any(sha(old/n) != config['oldTrio'][n]['sha256'] for n in FILES):
        raise ValueError('actual installed old trio differs from pinned package fixture')
    if not any(config['oldTrio'][n]['sha256'] != config['newTrio'][n]['sha256'] for n in FILES):
        raise ValueError('fixture has no actual signed upgrade')
    new = folder/'new-trio'; new.mkdir()
    for name, entry in config['newTrio'].items():
        shutil.copyfile(entry['path'], new/name)
    proof = verify_transition(old, new, variables, closure)
    baseline_policy = base64.b64encode((variables/('SbatLevelRT-'+SHIM_GUID)).read_bytes()).decode()
    transition = runpy.run_path(str(Path(__file__).with_name('accept.py')))['sbat_plan'](
        baseline_policy, config.get('expectedSbatVariableBase64', baseline_policy), new/'shimx64.efi')
    anchors, denied = PE((old/'shimx64.efi').read_bytes()).vendor_trust()
    new_anchors, new_denied = PE((new/'shimx64.efi').read_bytes()).vendor_trust()
    denied += new_denied
    verifier = Verifier(closure)
    for trust in (anchors, new_anchors):
        verifier.authenticate(folder/'vmlinuz', [data for kind, data in trust if kind == X509])
    denied += checked_database(efi_variable(variables, 'dbx', DB_GUID))
    denied += checked_database(efi_variable(variables, 'MokListXRT', SHIM_GUID, optional=True))
    verifier.check_revocations(folder/'vmlinuz', PE((folder/'vmlinuz').read_bytes()), denied)
    windows = guest_open(guestfs, record['overlay'])
    try:
        roots = windows.inspect_os()
        if len(roots) != 1 or windows.inspect_get_type(roots[0]) != 'windows':
            raise ValueError('QA baseline is not one installed Windows OS')
        mappings = windows.inspect_get_drive_mappings(roots[0])
        volume = mappings.get(config['windowsVolume'][0]) or mappings.get(config['windowsVolume'][0].lower())
        if not volume or windows.vfs_type(volume) != 'ntfs':
            raise ValueError('actual requested root.disk volume is not NTFS')
        host_uuid = windows.vfs_uuid(volume).upper()
        if not re.fullmatch('[0-9A-F]{16}', host_uuid):
            raise ValueError('incomplete actual NTFS identity')
        windows.mount(volume, '/')
        if windows.exists('/wootc/disks/root.disk') or windows.exists('/wootc/install/installation.json'):
            raise ValueError('baseline is already armed or deployed; use pristine QA Windows')
        windows.mkdir_p('/wootc/disks'); windows.mkdir_p('/wootc/qa')
        windows_helpers = {}
        for script_name in ('capture-windows.ps1', 'arm-classic.ps1'):
            ps = frozen_sources[Path(__file__).with_name(script_name)].read_bytes().decode('utf-8-sig').replace('\r\n', '\n')
            staged = folder/script_name; staged.write_bytes(b'\xef\xbb\xbf'+ps.replace('\n', '\r\n').encode())
            windows.upload(str(staged), '/wootc/qa/'+script_name)
            windows_helpers[config['windowsVolume']+'\\wootc\\qa\\'+script_name] = sha(staged)
        windows.umount_all()
        esps = [device for device, fs in windows.list_filesystems().items() if fs == 'vfat']
        if len(esps) != 1:
            raise ValueError('no unique Windows FAT ESP')
        esp = esps[0]; windows.mount(esp, '/')
        if not windows.is_file('/EFI/Microsoft/Boot/bootmgfw.efi'):
            raise ValueError('selected FAT is not Windows boot ESP')
        esp_uuid = windows.vfs_uuid(esp)
        device = windows.part_to_dev(esp); partition = windows.part_to_partnum(esp)
        esp_guid = windows.part_get_gpt_guid(device, partition).lower()
        loader = 'wootc-classic'
        if windows.is_dir('/EFI/'+loader):
            raise ValueError('foreign QA loader directory exists')
        foreign_before = {p: windows.checksum('sha256', p) for p in windows.find('/') if windows.is_file(p)}
        windows.mkdir_p('/EFI/'+loader); windows.mkdir_p('/EFI/wootc')
        owned = ['EFI/'+loader+'/'+n for n in FILES]+['EFI/'+loader+'/grub.cfg', 'EFI/'+vendor+'/grub.cfg', 'EFI/wootc/phase2-vmlinuz', 'EFI/wootc/phase2-initramfs.img']
        if windows.is_file('/EFI/wootc/wootc-owned.txt'):
            raise ValueError('baseline ESP already has a wootc ownership manifest')
        if any(windows.exists('/'+p) for p in owned):
            raise ValueError('reserved QA boot path already exists')
        manifest = '\n'.join(owned)+'\n'
        windows.write('/EFI/wootc/wootc-owned.txt', manifest)
        for name in FILES:
            windows.upload(str(old/name), '/EFI/'+loader+'/'+name)
        windows.upload(str(folder/'vmlinuz'), '/EFI/wootc/phase2-vmlinuz')
        windows.upload(str(folder/'initrd'), '/EFI/wootc/phase2-initramfs.img')
        config_text = 'set default=0\nset timeout=3\nmenuentry Linux {\n linux /EFI/wootc/phase2-vmlinuz root=UUID='+root_uuid+' ro loop=/wootc/disks/root.disk wootc.host_uuid='+host_uuid+' console=ttyS0,115200\n initrd /EFI/wootc/phase2-initramfs.img\n}\n'
        windows.mkdir_p('/EFI/'+vendor)
        windows.write('/EFI/'+loader+'/grub.cfg', config_text)
        windows.write('/EFI/'+vendor+'/grub.cfg', config_text)
        if any(windows.checksum('sha256', p) != expected for p, expected in foreign_before.items()):
            raise ValueError('foreign or Microsoft ESP bytes changed')
        windows.umount_all()
    finally:
        windows.close()
    # Final root configuration must be inside root.disk before its last upload.
    cloud = guest_open(guestfs, disk)
    try:
        mount_os(cloud, cloud.inspect_os()[0])
        cloud.write('/etc/wootc/esp-manifest', manifest)
        cloud.write('/etc/wootc/host-esp.conf', 'HOST_ESP_UUID='+shlex.quote(esp_uuid)+'\nBOOTLOADER=grub2\n')
        old_hashes = {n: sha(old/n) for n in FILES}
        cloud.write('/var/lib/wootc/qa-upgrade/old-hashes.json', json.dumps(old_hashes))
        cloud.umount_all()
    finally:
        cloud.close()
    windows = guest_open(guestfs, record['overlay'])
    try:
        windows.mount(volume, '/'); windows.upload(str(disk), '/wootc/disks/root.disk'); windows.umount_all()
    finally:
        windows.close()
    for entry in [original_config['windowsBaseline'], original_config['classicCloudImage']]+original_config['oldPackages']+original_config['newPackages']+list(original_config['oldTrio'].values())+list(original_config['newTrio'].values()):
        if sha(entry['path']) != entry['sha256']:
            raise ValueError('retained source changed during producer')
    record.update(state='classic-offline-baseline-produced', hostUuid=host_uuid, hostEspUuid=esp_uuid,
                  espPartitionGuid=esp_guid, rootFsUuid=root_uuid, sourceVendor=vendor, retainedForeignEspHashes=foreign_before,
                  loaderPath='\\EFI\\'+loader+'\\shimx64.efi', oldHashes=old_hashes, signatureProof=proof,
                  firmwareAcceptance=False, classicOsBootAcceptance=False,
                  gatesRemaining=['actual Windows QA BCD arm', 'first installed classic loop boot', 'upgrade/Windows return'])
    if any(sha(p) != h for p, h in source_pins.items()):
        raise ValueError('production source changed during producer')
    if any(sha(path) != uploaded_hashes[destination] for path, destination in uploads.items()):
        raise ValueError('host source changed during producer')
    helpers_linux = {destination: uploaded_hashes[destination] for path, destination in uploads.items()
                     if destination.startswith('/var/usrlocal/')}
    plan = {'schemaVersion': 1, 'scratchId': record['scratchId'], 'vmUuid': record['vmUuid'],
            'firmwareTrustHashes': {n: sha(variables/(n+'-'+g)) if (variables/(n+'-'+g)).exists() else None for n, g in [('SecureBoot', GLOBAL), ('SetupMode', GLOBAL), ('db', DB_GUID), ('dbx', DB_GUID), ('SbatLevelRT', SHIM_GUID), ('MokListXRT', SHIM_GUID)]},
            'sbatTransition': transition, 'oldHashes': old_hashes, 'newHashes': {n: sha(new/n) for n in FILES},
            'espMount': '/run/wootc-qa-esp', 'windowsVolume': config['windowsVolume'],
            'helperHashesLinux': helpers_linux, 'producerSourceHashes': source_provenance,
            'helperHashesWindows': windows_helpers,
            'identity': {'hostUuid': host_uuid, 'hostEspUuid': esp_uuid, 'rootFsUuid': root_uuid,
                         'rootDiskPath': '/wootc/disks/root.disk', 'loaderVendor': loader, 'deploymentKind': 'classic',
                         'bootCurrent': {'espPartitionGuid': esp_guid, 'loaderPath': record['loaderPath']}}}
    (folder/'plan.json').write_text(json.dumps(plan, indent=2)+'\n')
    (folder/'plan.json').chmod(0o600)
    record['planSha256'] = sha(folder/'plan.json')
    (folder/'scratch.json').write_text(json.dumps(record, indent=2)+'\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('private_parent', type=Path)
    parser.add_argument('config', type=Path)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text())
        checked_inputs(config)
        if not args.execute:
            print(json.dumps({'inputsMatch': True, 'executed': False, 'firmwareAcceptance': False,
                              'classicOsBootAcceptance': False}, sort_keys=True))
        else:
            print(json.dumps(produce(args.private_parent, config), sort_keys=True))
    except (OSError, ValueError, KeyError, ImportError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, 'classic producer refused: '+str(error)+'\n')
