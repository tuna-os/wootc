#!/usr/bin/python3
"""Run inside the installed guest; inspect fresh sources and actual firmware trust."""
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, '/var/usrlocal/lib/wootc')
from wootc_boot_identity import observe_installed_boot
from wootc_chain_source import freeze_sources, freeze_classic_sources
from wootc_chain_verify import FILES, verify_transition, GLOBAL, DB_GUID, SHIM_GUID
from wootc_pe import sbat_policy
from wootc_esp_transaction import ownership, read_json, digest, find_owned_path, relative_path


def capture(args):
    esp, host = Path(args.esp), Path(args.host)
    efivars = Path('/sys/firmware/efi/efivars')
    trust_files = [(n, g) for n, g in [('SecureBoot', GLOBAL), ('SetupMode', GLOBAL), ('db', DB_GUID), ('dbx', DB_GUID), ('SbatLevelRT', SHIM_GUID), ('MokListXRT', SHIM_GUID)]]
    def trust_hashes():
        return {n: digest(efivars/(n+'-'+g)) if (efivars/(n+'-'+g)).exists() else None for n, g in trust_files}
    trust = trust_hashes()
    sbat_raw = (efivars/('SbatLevelRT-'+SHIM_GUID)).read_bytes()
    if hashlib.sha256(sbat_raw).hexdigest() != trust['SbatLevelRT']:
        raise ValueError('SBAT policy changed before capture')
    sbat_payload = sbat_raw[4:]
    policy = sbat_policy(sbat_payload[:-1] if sbat_payload.endswith(b'\0') else sbat_payload)
    before = observe_installed_boot(esp, host, args.uuid)
    receipt = read_json(Path(args.receipt))
    ownership(esp, Path(args.manifest), receipt, before['hostEspUuid'])
    if Path(args.state, 'pending.json').exists():
        raise ValueError('pending publication or recovery journal')
    vendor = receipt['loaderVendor']
    if vendor.lower() != before['loaderVendor'].lower():
        raise ValueError('receipt loader differs from BootCurrent')
    with tempfile.TemporaryDirectory(prefix='wootc-333-capture-') as folder:
        temporary = Path(folder)
        if before['deploymentKind'] == 'classic':
            candidates = freeze_classic_sources(temporary/'source', before, esp, host)
        else:
            candidates = freeze_sources(temporary/'source', receipt['sourceVendor'])
        candidate = candidates[receipt['sourceVendor']]
        current = temporary/'current'
        current.mkdir()
        for name in FILES:
            (current/name).write_bytes(find_owned_path(esp, 'EFI/'+vendor+'/'+name).read_bytes())
        # No injected verdict: execute real Authenticode, db/dbx, shim and SBAT checks.
        signature = verify_transition(current, candidate, Path('/sys/firmware/efi/efivars'), Path(args.verifier))
        source = read_json(candidate.parent.parent/'EFI.json')
        if receipt.get('preparedBootId') != before['bootId'] or receipt.get('sourceEFI', {}).get('version') != source['version']:
            raise ValueError('installed helper has no fresh source receipt for this boot')
        hashes = {name: digest(current/name) for name in FILES}
        archive = None
        upgrade_signature = None
        if args.old_hashes:
            old = json.loads(Path(args.old_hashes).read_text())
            if set(old) != set(FILES):
                raise ValueError('incomplete old trio')
            archive_id = hashlib.sha256(json.dumps(old, sort_keys=True).encode()).hexdigest()
            directory = esp/'EFI/wootc/archive'/archive_id
            if directory.is_symlink() or directory.parent.is_symlink():
                raise ValueError('archive symlink')
            if read_json(directory/'hashes.json') != old:
                raise ValueError('archive manifest differs')
            archive = {name: digest(directory/name) for name in FILES}
            if archive != old:
                raise ValueError('archive bytes differ')
            upgrade_signature = verify_transition(directory, candidate, efivars, Path(args.verifier))
        owned = {relative_path(line) for line in Path(args.manifest).read_text(encoding='utf-8-sig').splitlines() if line.strip()}
        archive_prefix = ('efi/wootc/archive/'+archive_id+'/') if args.old_hashes else None
        foreign = {str(p.relative_to(esp)): digest(p) for p in esp.rglob('*')
                   if p.is_file() and relative_path(str(p.relative_to(esp))) not in owned
                   and not (archive_prefix and relative_path(str(p.relative_to(esp))).startswith(archive_prefix))}
        after = observe_installed_boot(esp, host, args.uuid)
        ownership(esp, Path(args.manifest), receipt, after['hostEspUuid'])
        if read_json(Path(args.receipt)) != receipt:
            raise ValueError('content receipt changed during capture')
        if archive is not None and any(digest(directory/n) != archive[n] for n in FILES):
            raise ValueError('old archive changed during capture')
        if trust_hashes() != trust:
            raise ValueError('actual firmware policy changed during capture')
        if before != after or any(digest(find_owned_path(esp, 'EFI/'+vendor+'/'+n)) != hashes[n] for n in FILES):
            raise ValueError('boot or ESP bytes changed during capture')
        failed = subprocess.run(['systemctl', '--failed', '--no-legend', '--plain'], check=True,
                                text=True, capture_output=True, timeout=20).stdout.strip()
        if failed:
            raise ValueError('failed installed systemd units')
        return {'schemaVersion': 1, 'transportNonce': args.transport_nonce, 'vmUuid': Path('/sys/class/dmi/id/product_uuid').read_text().strip().lower(), 'observation': after, 'trioHashes': hashes, 'sourceHashes': {n: digest(candidate/n) for n in FILES},
                'archiveHashes': archive, 'upgradeSignatureProof': upgrade_signature, 'firmwareObservationSource': 'current-boot-efivars', 'firmwareTrustHashes': trust, 'firmwareSbatPolicy': policy, 'firmwareSbatVariableBase64': base64.b64encode(sbat_raw).decode(), 'receipt': receipt, 'sourceFacts': source,
                'foreignFiles': foreign, 'signatureProof': signature, 'failedUnits': [], 'pendingJournal': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--esp', required=True)
    parser.add_argument('--uuid', required=True)
    parser.add_argument('--host', default='/run/initramfs/wootc-host')
    parser.add_argument('--receipt', default='/etc/wootc/esp-chain.json')
    parser.add_argument('--manifest', default='/etc/wootc/esp-manifest')
    parser.add_argument('--state', default='/var/lib/wootc/esp-transactions')
    parser.add_argument('--verifier', default='/var/usrlocal/lib/wootc/sbverify')
    parser.add_argument('--old-hashes')
    parser.add_argument('--transport-nonce', required=True)
    parser.add_argument('--mount-esp', action='store_true')
    args = parser.parse_args()
    mounted = False
    try:
        if args.mount_esp:
            if args.esp != '/run/wootc-qa-esp' or not re.fullmatch('[A-Za-z0-9-]+', args.uuid):
                raise ValueError('unsupported QA inspection mount identity')
            directory = Path(args.esp)
            directory.mkdir(mode=0o700, exist_ok=True)
            if directory.is_symlink() or directory.stat().st_uid != 0:
                raise ValueError('foreign QA mountpoint')
            if subprocess.run(['mountpoint', '-q', args.esp], timeout=10).returncode == 0:
                raise ValueError('QA inspection mount is already occupied')
            subprocess.run(['mount', '-t', 'vfat', '-o', 'ro', '/dev/disk/by-uuid/'+args.uuid, args.esp], check=True, timeout=30)
            mounted = True
        print(json.dumps(capture(args), sort_keys=True))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, 'capture refused: '+str(error)+'\n')
    finally:
        if mounted:
            subprocess.run(['umount', args.esp], check=True, timeout=30)
