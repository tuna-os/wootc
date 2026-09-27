"""Independent read-only guest probe after package phases; QGA must execute this."""
import hashlib
import json
from pathlib import Path
import platform
import re
import runpy


def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def probe(seed,workspace,challenge):
    seed,workspace=Path(seed),Path(workspace)
    manifest=json.loads((seed/'manifest.json').read_text())
    if (not re.fullmatch('[0-9a-f]{64}',challenge) or challenge==manifest['challenge']):
        raise ValueError('independent fresh readback challenge required')
    required={'bootstrap.py','package-consumer.py','packages.json','readback.py'}
    if set(manifest['helperHashes'])!=required:raise ValueError('complete readback source closure required')
    for name,expected in manifest['helperHashes'].items():
        if (seed/name).is_symlink() or sha(seed/name)!=expected:raise ValueError('readback source differs')
    if sha(__file__)!=manifest['helperHashes']['readback.py']:raise ValueError('executing readback differs')
    bootstrap=runpy.run_path(str(seed/'bootstrap.py'))
    if platform.system()!='Linux':raise ValueError('actual current OS is not Linux')
    bootstrap['actual_environment'](manifest,seed)
    before=bootstrap['boot_id']()
    consumer=runpy.run_path(str(seed/'package-consumer.py'))
    policy=json.loads((seed/'packages.json').read_text())
    retired={name:policy['phases']['old']['beforeInventory'][name]
             for name in policy['phases']['old']['allowedRemovals']}
    inventory=consumer['inventory'](consumer['execute'],retired)
    result=json.loads((workspace/'result.json').read_text())
    if bootstrap['boot_id']()!=before:raise ValueError('boot changed across readback')
    return {'os':'Linux','bootId':before,'challenge':challenge,'currentInventory':inventory,
            'result':result,'sourceSha256':sha(__file__),'exitStatus':0}


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('seed');parser.add_argument('workspace');parser.add_argument('challenge');args=parser.parse_args()
    print(json.dumps(probe(args.seed,args.workspace,args.challenge),sort_keys=True))
