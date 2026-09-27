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
    raw = base64.b64decode(encoded, validate=True)
    require(len(raw) > 4 and struct.unpack('<I', raw[:4])[0] in (6, 7), 'unsupported SBAT variable attributes')
    payload = raw[4:]
    if payload.endswith(b'\0'):
        payload = payload[:-1]
    return raw, sbat_policy(payload)


def sbat_plan(old_variable, new_variable, new_shim):
    old_raw, old_policy = policy_variable(old_variable)
    new_raw, new_policy = policy_variable(new_variable)
    require(new_raw[:4] == old_raw[:4], 'SBAT variable attributes changed')
    if new_raw != old_raw:
        body = PE(Path(new_shim).read_bytes()).sections.get('.sbatlevel', b'')
        require(len(body) >= 12, 'candidate shim has no complete SBAT policies')
        version, automatic, latest = struct.unpack('<III', body[:12])
        require(version == 0 and 8 <= automatic < latest and 4+latest < len(body), 'unknown candidate SBAT layout')
        payloads = [body[4+automatic:4+latest], body[4+latest:]]
        # Exact bytes (including timestamp), not just a monotonic integer map.
        require(new_raw[4:] in payloads, 'planned policy is not an exact embedded candidate shim policy')
        require(all(new_policy.get(n, -1) >= g for n, g in old_policy.items()), 'planned policy removes baseline revocations')
    return {'oldVariableBase64': old_variable, 'newVariableBase64': new_variable,
            'newShimSha256': hashlib.sha256(Path(new_shim).read_bytes()).hexdigest()}


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
    planned_raw = [policy_variable(transition[key])[0] for key in ('oldVariableBase64', 'newVariableBase64')]
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
        required_trust = {'SecureBoot', 'SetupMode', 'db', 'dbx', 'MokListXRT', 'SbatLevelRT'}
        require(set(capture['firmwareTrustHashes']) == required_trust, 'incomplete firmware trust observations')
        require(all(v is None and k == 'MokListXRT' or isinstance(v, str) and re.fullmatch('[0-9a-f]{64}', v) for k, v in capture['firmwareTrustHashes'].items()), 'invalid firmware trust hash')
        raw, policy = policy_variable(capture['firmwareSbatVariableBase64'])
        require(hashlib.sha256(raw).hexdigest() == capture['firmwareTrustHashes']['SbatLevelRT'], 'SBAT bytes do not match observed hash')
        require(policy == capture['firmwareSbatPolicy'], 'SBAT parsed policy differs from observed bytes')
        require(raw == planned_raw[0 if capture is old else 1], 'SBAT policy differs from exact approved transition')
        stable_trust = lambda data: {k: v for k, v in data['firmwareTrustHashes'].items() if k != 'SbatLevelRT'}
        require(stable_trust(capture) == stable_trust(old), 'firmware trust changed')
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
