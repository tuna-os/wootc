"""Check the classic source checkpoint without printing its full receipt."""
import argparse,hashlib,json,subprocess
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('worktree',type=Path)
parser.add_argument('--assets',type=Path,required=True)
parser.add_argument('--closure',type=Path,required=True)
parser.add_argument('--evidence',default='2026-09-27-classic-providers')
args=parser.parse_args()
proof=args.worktree/'docs/experiments/evidence'/args.evidence
record=json.loads((proof/'provenance.json').read_text())
def check(base,entries):
    for relative,expected in entries.items():
        if hashlib.sha256((base/relative).read_bytes()).hexdigest()!=expected:
            raise SystemExit('hash differs: '+str(base/relative))
    return len(entries)
counts={'sources':check(args.worktree,record['sourceHashes']),
        'results':check(proof,record['resultHashes']),
        'assets':check(args.assets,record['assetHashes']),
        'verifierClosure':check(args.closure,record['verifierClosureHashes'])}
clean=not subprocess.check_output(['git','status','--porcelain'],cwd=args.worktree,text=True).strip()
print(json.dumps({'hashesMatch':True,'counts':counts,'worktreeClean':clean,
                  'providersImplemented':record.get('providersImplemented',[]),
                  'sourceFormatsRemaining':record['sourceFormatsRemaining'],
                  'firmwareAcceptance':record['firmwareAcceptance'],
                  'classicOsBootAcceptance':record['classicOsBootAcceptance']},sort_keys=True))
