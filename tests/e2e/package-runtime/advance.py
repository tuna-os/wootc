"""Acknowledge only the exact old phase readback already approved by the host."""
import hashlib
import json
from pathlib import Path
import re
import runpy


def advance(seed,workspace,challenge,approved):
    if not re.fullmatch('[0-9a-f]{64}',approved):raise ValueError('approved readback digest malformed')
    seed,workspace=Path(seed),Path(workspace)
    manifest=json.loads((seed/'manifest.json').read_text())
    actual=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if actual!=manifest['helperHashes']['advance.py']:raise ValueError('executing advance helper differs')
    probe=runpy.run_path(str(seed/'readback.py'))['probe']
    observed=probe(seed,workspace,challenge,'old')
    digest=hashlib.sha256(json.dumps(observed,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    if digest!=approved:raise ValueError('old phase changed after independent host approval')
    target=workspace/'advance-old.json'
    if target.exists() or target.is_symlink():raise ValueError('old phase acknowledgement already exists')
    result={name:observed['result'][name] for name in ('scratchId','challenge','bootId','seedSha256')}
    result.update(validatedPhase='old',readbackChallenge=challenge,approvedReadbackSha256=approved)
    bootstrap=runpy.run_path(str(seed/'bootstrap.py'))
    bootstrap['atomic_result'](workspace,'advance-old.json',result)
    return result


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('seed');parser.add_argument('workspace');parser.add_argument('challenge');parser.add_argument('approved');args=parser.parse_args()
    print(json.dumps(advance(args.seed,args.workspace,args.challenge,args.approved),sort_keys=True))
