"""Independent read-only guest probe after package phases; QGA must execute this."""
import hashlib
import json
from pathlib import Path
import platform
import re
import runpy


def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def probe(seed,workspace,challenge,phase='new'):
    if phase not in ('old','new'):raise ValueError('unknown readback phase')
    seed,workspace=Path(seed),Path(workspace)
    manifest=json.loads((seed/'manifest.json').read_text())
    if (not re.fullmatch('[0-9a-f]{64}',challenge) or challenge==manifest['challenge']):
        raise ValueError('independent fresh readback challenge required')
    required={'bootstrap.py','package-consumer.py','packages.json','readback.py','advance.py'}
    if set(manifest['helperHashes'])!=required:raise ValueError('complete readback source closure required')
    for name,expected in manifest['helperHashes'].items():
        if (seed/name).is_symlink() or sha(seed/name)!=expected:raise ValueError('readback source differs')
    if sha(__file__)!=manifest['helperHashes']['readback.py']:raise ValueError('executing readback differs')
    bootstrap=runpy.run_path(str(seed/'bootstrap.py'))
    if platform.system()!='Linux':raise ValueError('actual current OS is not Linux')
    facts=bootstrap['actual_environment'](manifest,seed)
    before=bootstrap['boot_id']()
    consumer=runpy.run_path(str(seed/'package-consumer.py'))
    policy=json.loads((seed/'packages.json').read_text())
    retired={name:policy['phases']['old']['beforeInventory'][name]
             for name in policy['phases']['old']['allowedRemovals']}
    inventory=consumer['inventory'](consumer['execute'],retired)
    filename='phase-result.json' if phase=='old' else 'result.json'
    result=json.loads((workspace/filename).read_text())
    expected_stage='old-installed' if phase=='old' else 'complete'
    if result.get('stage')!=expected_stage or inventory!=policy['phases'][phase]['afterInventory']:
        raise ValueError('actual phase state differs from requested independent readback')
    if bootstrap['boot_id']()!=before:raise ValueError('boot changed across readback')
    return {'os':'Linux','bootId':before,'challenge':challenge,'currentInventory':inventory,
            'result':result,'sourceSha256':sha(__file__),'seedSha256':facts['seedSha256'],'exitStatus':0}


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('seed');parser.add_argument('workspace');parser.add_argument('challenge');parser.add_argument('--phase',choices=('old','new'),default='new');args=parser.parse_args()
    print(json.dumps(probe(args.seed,args.workspace,args.challenge,args.phase),sort_keys=True))
