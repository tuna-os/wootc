"""Export bounded authentication receipts; never export mutable host resource trees."""
import json
import os
from pathlib import Path
import re
import runpy

HERE=Path(__file__).resolve().parent
TRUST=runpy.run_path(str(HERE/'hosted-execute.py'))


def export(prefix,target):
    prefix=Path(prefix);target=Path(target)
    if not re.fullmatch('/run/wootc-package-host-[0-9]+-[0-9]+',str(prefix)):
        raise ValueError('unowned host prefix proof path')
    if target.exists():raise ValueError('host proof destination already exists')
    target.mkdir(mode=0o755)
    names=['host-data.json','namespace.json','namespace-failure.json','archive-key.gpg','apt/config','apt/etc/ubuntu.sources']
    if prefix.exists():names.extend(str(path.relative_to(prefix)) for path in sorted((prefix/'apt/lists').glob('*_InRelease')))
    total=0;copied=[]
    for name in names:
        source=prefix/name
        if not source.exists():continue
        source=TRUST['protected'](source)
        size=source.stat().st_size;total+=size
        if size>4*1024**2 or total>16*1024**2:raise ValueError('authentication proof exceeds bound')
        destination=target/name;destination.parent.mkdir(mode=0o755,parents=True,exist_ok=True)
        with source.open('rb') as input_file,destination.open('xb') as output:
            remaining=size
            while remaining:
                chunk=input_file.read(min(65536,remaining))
                if not chunk:raise ValueError('authentication proof truncated')
                output.write(chunk);remaining-=len(chunk)
            if input_file.read(1):raise ValueError('authentication proof grew')
        destination.chmod(0o644);copied.append(name)
    (target/'export.json').write_text(json.dumps({'schemaVersion':1,'prefix':str(prefix),'files':copied,'bytes':total,'runtimeExecuted':False},sort_keys=True)+'\n')
    return copied


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('prefix');parser.add_argument('target');args=parser.parse_args()
    TRUST['hosted'](os.environ)
    export(args.prefix,args.target)
