"""Compare captures from actual guest executions; never derive boot success from markers."""
import argparse
import json
import re
import uuid
from pathlib import Path

FILES = {'shimx64.efi', 'grubx64.efi', 'mmx64.efi'}


def require(value, reason):
    if not value:
        raise ValueError(reason)


def validate(plan, old, new, reboot, windows):
    require(plan['schemaVersion'] == 1, 'unknown plan schema')
    require(re.fullmatch('[0-9a-f]{32}', plan['scratchId']), 'missing exclusive scratch identity')
    for generation in ('oldHashes', 'newHashes'):
        require(set(plan[generation]) == FILES and all(re.fullmatch('[0-9a-f]{64}', h) for h in plan[generation].values()), 'incomplete pinned trio')
    require(all(plan['oldHashes'][n] != plan['newHashes'][n] for n in FILES), 'fixture must change whole trio')
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
        require(capture['firmwareTrustHashes'] == old['firmwareTrustHashes'], 'firmware trust changed')
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
    return {'accepted': True, 'scratchId': plan['scratchId'], 'deploymentKind': kind,
            'scope': 'three observed Secure Boot Linux boots and subsequent Windows return; no hardware power-cut claim'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('plan', 'old', 'new', 'reboot', 'windows'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(*(json.loads(getattr(args, n).read_text()) for n in ('plan', 'old', 'new', 'reboot', 'windows'))), sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, 'acceptance refused: '+str(error)+'\n')
