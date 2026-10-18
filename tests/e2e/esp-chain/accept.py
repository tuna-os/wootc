"""Compare captures from actual guest executions; never derive boot success from markers."""
import argparse
import base64
import hashlib
import struct
import sys
import json
import re
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]/'payload/migration/lib'))
from wootc_pe import sbat_policy, PE

FILES = {'shimx64.efi', 'grubx64.efi', 'mmx64.efi'}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def policy_variable(encoded):
    require(isinstance(encoded, str) and bool(encoded), 'SBAT variable bytes absent')
    raw = base64.b64decode(encoded, validate=True)
    require(len(raw) > 4 and struct.unpack('<I', raw[:4])[0] in (6, 7), 'unsupported SBAT variable attributes')
    payload = raw[4:]
    if payload.endswith(b'\0'):
        payload = payload[:-1]
    return raw, sbat_policy(payload)


def embedded_sbat_payloads(shim_bytes):
    body = PE(shim_bytes).sections.get('.sbatlevel', b'')
    require(len(body) >= 12, 'shim has no complete SBAT policies')
    version, automatic, latest = struct.unpack('<III', body[:12])
    require(version == 0 and 8 <= automatic < latest and 4+latest < len(body), 'unknown shim SBAT layout')
    payloads = [body[4+automatic:4+latest], body[4+latest:]]
    for payload in payloads:
        require(payload.endswith(b'\0') and b'\0' not in payload[:-1], 'malformed embedded SBAT payload')
        sbat_policy(payload[:-1])
    return payloads


def sbat_plan(old_variable, new_variable, new_shim):
    old_raw, old_policy = policy_variable(old_variable)
    new_raw, new_policy = policy_variable(new_variable)
    require(new_raw[:4] == old_raw[:4], 'SBAT variable attributes changed')
    if new_raw != old_raw:
        require(new_raw[4:] in embedded_sbat_payloads(Path(new_shim).read_bytes()), 'planned policy is not an exact embedded candidate shim policy')
        require(all(new_policy.get(n, -1) >= g for n, g in old_policy.items()), 'planned policy removes baseline revocations')
    return {'oldVariableBase64': old_variable, 'newVariableBase64': new_variable,
            'newShimSha256': hashlib.sha256(Path(new_shim).read_bytes()).hexdigest()}


def validate_firmware(capture, plan, is_old):
    require(capture.get('firmwareObservationSource') == 'current-boot-efivars', 'actual current-boot firmware observation absent')
    initial = plan.get('initialFirmwarePolicy', {})
    require(initial.get('mode', 'captured-runtime') in ('captured-runtime', 'planned-old-shim-bootstrap'), 'unknown initial firmware policy mode')
    if initial.get('mode') == 'planned-old-shim-bootstrap':
        require(initial['oldShimSha256'] == plan['oldHashes']['shimx64.efi'], 'expected initial policy belongs to another old shim')
        require(initial['expectedVariableBase64'] == plan['sbatTransition']['oldVariableBase64'], 'expected initial policy differs from transition')
    required = {'SecureBoot', 'SetupMode', 'db', 'dbx', 'MokListXRT', 'SbatLevelRT'}
    hashes = capture['firmwareTrustHashes']
    require(set(hashes) == required, 'incomplete firmware trust observations')
    require(all(v is None and k == 'MokListXRT' or isinstance(v, str) and re.fullmatch('[0-9a-f]{64}', v) for k, v in hashes.items()), 'invalid firmware trust hash')
    raw, policy = policy_variable(capture['firmwareSbatVariableBase64'])
    require(hashlib.sha256(raw).hexdigest() == hashes['SbatLevelRT'], 'SBAT bytes do not match observed hash')
    require(policy == capture['firmwareSbatPolicy'], 'SBAT parsed policy differs from observed bytes')
    transition = plan['sbatTransition']
    require(transition['newShimSha256'] == plan['newHashes']['shimx64.efi'], 'SBAT plan is not bound to candidate shim')
    expected, _ = policy_variable(transition['oldVariableBase64' if is_old else 'newVariableBase64'])
    require(raw == expected, 'SBAT policy differs from exact approved transition')
    stable = lambda data: {k: v for k, v in data.items() if k != 'SbatLevelRT'}
    require(stable(hashes) == stable(plan['firmwareTrustHashes']), 'firmware trust changed')
    if is_old:
        require(hashes == plan['firmwareTrustHashes'], 'baseline trust differs from pinned firmware export')


def validate_source(capture):
    facts = capture['sourceFacts']
    prepared = capture['receipt']['sourceEFI']
    require(isinstance(facts, dict) and isinstance(prepared, dict), 'source facts or prepared source absent')
    stable = lambda data: {k: v for k, v in data.items() if k != 'timestamp'}
    require(stable(facts) == stable(prepared), 'prepared source differs from current source facts')
    require(isinstance(facts.get('version'), str) and bool(facts['version'].strip()), 'current source version absent')
    require(isinstance(facts.get('timestamp'), str) and bool(facts['timestamp'].strip()), 'current source timestamp absent')
    kind = capture['observation']['deploymentKind']
    if kind == 'classic':
        require(facts.get('sourceKind') == 'classic', 'classic source facts absent')
        require(set(facts) == {'schemaVersion', 'sourceKind', 'os', 'packages', 'packageManager', 'rootFsUuid', 'sourceFsUuid', 'kernelRelease', 'components', 'version', 'timestamp'}, 'incomplete classic source shape')
        require(type(facts['schemaVersion']) is int and facts['schemaVersion'] == 1, 'unknown classic source schema')
        release = facts['os']
        require(isinstance(release, dict) and set(release) == {'ID', 'VERSION_ID'} and all(isinstance(v, str) and v.strip() for v in release.values()), 'classic OS facts absent')
        managers = {'debian': 'dpkg', 'ubuntu': 'dpkg', 'fedora': 'rpm', 'almalinux': 'rpm', 'rocky': 'rpm', 'centos': 'rpm', 'rhel': 'rpm'}
        require(release['ID'] in managers and facts['packageManager'] == managers[release['ID']], 'unsupported classic package source')
        require(facts['rootFsUuid'] == capture['observation']['rootFsUuid'] and all(isinstance(facts[k], str) and facts[k].strip() for k in ('rootFsUuid', 'sourceFsUuid', 'kernelRelease')), 'classic root or kernel source identity absent')
        require(facts['components'] == capture['sourceHashes'], 'classic source components differ from measured bytes')
        packages = facts['packages']
        expected = {'shim-signed', 'grub-efi-amd64-signed'} if release['ID'] == 'ubuntu' else ({'shim-signed', 'shim-helpers-amd64-signed', 'grub-efi-amd64-signed'} if facts['packageManager'] == 'dpkg' else {'shim-x64', 'grub2-efi-x64'})
        require(isinstance(packages, dict) and set(packages) == expected, 'incomplete classic source package roles')
        require(all(isinstance(p, dict) and set(p) == {'version', 'architecture'} and all(isinstance(v, str) and v.strip() for v in p.values()) for p in packages.values()), 'incomplete classic package identity')
        body = {k: v for k, v in facts.items() if k not in ('version', 'timestamp')}
        stamp = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        require(facts['version'] == 'classic-sha256:'+stamp, 'classic source version is not bound to current facts')
    elif kind == 'bootc':
        require(facts.get('sourceKind') in (None, 'bootupd'), 'unsupported bootupd source kind')
        require(isinstance(facts.get('versions', []), list), 'malformed bootupd package versions')
    else:
        raise ValueError('unsupported deployment source kind')


def validate_initial(plan, capture):
    validate_firmware(capture, plan, True)
    require(capture['vmUuid'].lower() == plan['vmUuid'].lower(), 'first Linux capture belongs to another VM')
    boot = capture['observation']
    require(boot['secureBoot'] is True and boot['rootKind'] == 'loop', 'first Linux Secure Boot/loop root absent')
    for key, expected in plan['identity'].items():
        require(boot[key] == expected, 'first Linux identity differs: '+key)
    require(str(uuid.UUID(boot['bootId'])) == boot['bootId'], 'malformed first Linux boot ID')
    require(capture['sourceHashes'] == capture['trioHashes'] == plan['oldHashes'], 'first Linux source or ESP differs from old pinned trio')
    require(capture['signatureProof']['verified'] is True, 'first Linux signature/policy proof absent')
    require(capture['failedUnits'] == [] and capture['pendingJournal'] is False, 'first Linux has failed units or pending recovery')
    require(capture['receipt']['preparedBootId'] == boot['bootId'] and capture['receipt']['sourceEFI']['version'] == capture['sourceFacts']['version'], 'first Linux source receipt is stale')
    validate_source(capture)
    if boot['deploymentKind'] == 'bootc':
        require(boot['imageDigest'] == plan['oldImageDigest'] and boot['imageRef'] == plan['imageRef'], 'first Linux booted image differs')


def validate(plan, old, new, reboot, windows):
    require(plan['schemaVersion'] == 1, 'unknown plan schema')
    require(re.fullmatch('[0-9a-f]{32}', plan['scratchId']), 'missing exclusive scratch identity')
    for generation in ('oldHashes', 'newHashes'):
        require(set(plan[generation]) == FILES and all(re.fullmatch('[0-9a-f]{64}', h) for h in plan[generation].values()), 'incomplete pinned trio')
    require(any(plan['oldHashes'][n] != plan['newHashes'][n] for n in FILES), 'fixture has no changed signed component')
    if plan.get('requireAllComponentsChanged'):
        require(all(plan['oldHashes'][n] != plan['newHashes'][n] for n in FILES), 'fixture must change every signed component')
    transition = plan['sbatTransition']
    require(transition['newShimSha256'] == plan['newHashes']['shimx64.efi'], 'SBAT plan is not bound to candidate shim')
    require(old['firmwareTrustHashes'] == plan['firmwareTrustHashes'], 'baseline trust differs from pinned firmware export')
    ids = []
    first = old['observation']
    require(first['rootDiskPath'] == '/wootc/disks/root.disk' and re.fullmatch('[0-9A-F]{16}', first['hostUuid']), 'unsupported host/root identity')
    for capture, expected in ((old, plan['oldHashes']), (new, plan['newHashes']), (reboot, plan['newHashes'])):
        require(capture['vmUuid'].lower() == plan['vmUuid'].lower(), 'Linux booted in another scratch VM')
        boot = capture['observation']
        require(boot['secureBoot'] is True and boot['rootKind'] == 'loop', 'Secure Boot or loop root absent')
        for key in ('hostUuid', 'hostEspUuid', 'rootDiskPath', 'loaderVendor', 'deploymentKind'):
            require(boot[key] == first[key] == plan['identity'][key], 'wrong '+key)
        require(boot['bootCurrent'] == first['bootCurrent'] == plan['identity']['bootCurrent'], 'wrong actual EFI boot entry')
        require(capture['sourceHashes'] == expected, 'fresh package source differs from pinned generation')
        require(capture['trioHashes'] == expected, 'ESP trio differs from pinned generation')
        require(capture['signatureProof']['verified'] is True, 'actual signature/policy proof absent')
        require(capture['failedUnits'] == [] and capture['pendingJournal'] is False, 'failed units or pending recovery')
        require(capture['receipt']['preparedBootId'] == boot['bootId'] and capture['receipt']['sourceEFI']['version'] == capture['sourceFacts']['version'], 'helper receipt is stale')
        require(capture['receipt']['ownedManifestSha256'] == old['receipt']['ownedManifestSha256'], 'ownership changed')
        require(capture['foreignFiles'] == old['foreignFiles'], 'foreign or Windows ESP bytes changed')
        require(str(uuid.UUID(boot['bootId'])) == boot['bootId'], 'malformed kernel boot ID')
        validate_source(capture)
        validate_firmware(capture, plan, capture is old)
        ids.append(boot['bootId'])
    require(len(set(ids)) == 3, 'cached boot capture or no reboot')
    require(new['archiveHashes'] == reboot['archiveHashes'] == plan['oldHashes'], 'whole old archive absent')
    for capture in (new, reboot):
        require(capture['upgradeSignatureProof']['verified'] is True and capture['upgradeSignatureProof']['current'] == plan['oldHashes'] and capture['upgradeSignatureProof']['candidate'] == plan['newHashes'], 'actual mixed-generation verification absent')
    kind = first['deploymentKind']
    if kind == 'bootc':
        for capture, digest in ((old, plan['oldImageDigest']), (new, plan['newImageDigest']), (reboot, plan['newImageDigest'])):
            require(capture['observation']['imageDigest'] == digest and capture['observation']['imageRef'] == plan['imageRef'], 'actual booted image differs')
    elif kind == 'classic':
        stable = lambda capture: {k: v for k, v in capture['sourceFacts'].items() if k != 'timestamp'}
        require(stable(old) != stable(new) == stable(reboot), 'classic source/package upgrade absent')
        for capture in (old, new, reboot):
            require(capture['sourceFacts']['sourceKind'] == 'classic', 'classic source facts absent')
            require(capture['observation']['rootFsUuid'] == plan['identity']['rootFsUuid'], 'classic root changed')
    else:
        raise ValueError('unsupported deployment kind')
    require(windows['vmUuid'].lower() == plan['vmUuid'].lower(), 'Windows returned in another scratch VM')
    require(windows['scratchId'] == plan['scratchId'] and windows['os'] == 'Windows_NT', 'actual Windows return absent')
    require(windows['hostUuid'] == first['hostUuid'], 'Windows returned on another host volume')
    require(windows['afterLinuxBootId'] == ids[-1], 'Windows return is stale or out of order')
    if kind == 'classic':
        for role in ('host', 'system'):
            require(windows.get('bitlocker', {}).get(role) == {'volumeStatus': 'FullyDecrypted', 'protectionStatus': 'Off', 'encryptionPercentage': 0}, 'classic Windows volume encryption state is unsupported')
    return {'observationsMatch': True, 'firmwareAcceptance': False, 'chronologyVerified': False, 'scratchId': plan['scratchId'], 'deploymentKind': kind,
            'scope': 'capture facts match; echoed correlation fields do not prove transport chronology or firmware acceptance'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('plan', 'old', 'new', 'reboot', 'windows'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(*(json.loads(getattr(args, n).read_text()) for n in ('plan', 'old', 'new', 'reboot', 'windows'))), sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, 'acceptance refused: '+str(error)+'\n')
