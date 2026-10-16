"""Record actual host eligibility only; never acquire inputs or start a VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess


def qualify(folder,output):
    record={'schemaVersion':1,'qualified':False,'runtimeExecuted':False,'acquisitionPerformed':False,
            'cpus':os.cpu_count(),'freeBytes':shutil.disk_usage(folder).free,
            'tools':{name:shutil.which(name) for name in ('qemu-system-x86_64','qemu-img','genisoimage')}}
    memory=dict(line.split(':',1) for line in Path('/proc/meminfo').read_text().splitlines())
    record['memAvailableBytes']=int(memory['MemAvailable'].split()[0])*1024
    try:
        checker=runpy.run_path(str(Path(__file__).with_name('launch.py')))['qualify']
        record['measuredResources']=checker(folder)
        if not all(record['tools'].values()):raise ValueError('required installed tools missing')
        trust=runpy.run_path(str(Path(__file__).with_name('hosted-execute.py')))['protected']
        firmware=[Path('/usr/share/OVMF')/name for name in ('OVMF_CODE_4M.fd','OVMF_VARS_4M.fd')]
        if not all(path.is_file() for path in firmware):raise ValueError('installed firmware closure missing')
        record['toolSha256']={name:hashlib.sha256(Path(path).read_bytes()).hexdigest()
                             for name,path in record['tools'].items()}
        record['firmwareSha256']={str(path):hashlib.sha256(trust(path).read_bytes()).hexdigest() for path in firmware}
        record['qualified']=True
    except Exception as error:
        record['failureType']=type(error).__name__;record['failure']=str(error)
    Path(output).write_text(json.dumps(record,sort_keys=True,indent=2)+'\n')
    return record


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('scratch_parent');parser.add_argument('output');args=parser.parse_args()
    result=qualify(args.scratch_parent,args.output)
    print(json.dumps({'qualified':result['qualified'],'runtimeExecuted':False,'acquisitionPerformed':False}))
    if not result['qualified']:raise SystemExit(1)
