#!/usr/bin/env python3
"""Read-only compact audit of the committed #333 native proof and source."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
parser=argparse.ArgumentParser()
parser.add_argument('repository',type=Path)
parser.add_argument('--assets',type=Path)
args=parser.parse_args();root=args.repository.resolve()
evidence=root/'docs/experiments/evidence/2026-09-27-esp-chain'
record=json.loads((evidence/'provenance.json').read_text())
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def verify(prefix,hashes):return [name for name,expected in hashes.items() if digest(prefix/name)!=expected]
source_wrong=verify(root,record['sourceHashes'])
result_wrong=verify(evidence,record['resultHashes'])
asset_wrong=verify(args.assets,record['assetHashes']) if args.assets else None
if args.assets and digest(args.assets/'almalinux-signed-vmlinuz')!=record['kernelSha256']:
    asset_wrong.append('almalinux-signed-vmlinuz')
proof=json.loads((evidence/'native-result.json').read_text())
preflight=proof[0]['proof']
old,new=preflight['current'],preflight['candidate']
archive=hashlib.sha256(json.dumps(old,sort_keys=True).encode()).hexdigest()
head=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
clean=not subprocess.check_output(['git','-C',str(root),'status','--porcelain'],text=True).strip()
result={'commit':head,'worktreeClean':clean,'sourceFilesChecked':len(record['sourceHashes']),
        'sourceHashMismatches':source_wrong,'resultFilesChecked':len(record['resultHashes']),
        'resultHashMismatches':result_wrong,
        'assetFilesChecked':len(record['assetHashes'])+1 if args.assets else None,
        'assetHashMismatches':asset_wrong,
        'verifierBuilder':record['verifierBuilder'],
        'verifierCommit':record['sbsigntools']['commit'],
        'decoderOrigin':record['bootIdentityOrigin'],
        'completeTrioChanged':all(old[name]!=new[name] for name in old),
        'fixtureArchivePath':'EFI/wootc/archive/'+archive,
        'proofCases':[item['case'] for item in proof],
        'firmwareAcceptance':False,'classicAcceptance':False}
print(json.dumps(result,separators=(',',':')))
raise SystemExit(bool(source_wrong or result_wrong or asset_wrong))
