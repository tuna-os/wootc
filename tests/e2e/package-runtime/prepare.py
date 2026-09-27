"""Prepare a new owned Linux-only scratch; this module never starts QEMU."""
import hashlib
import json
import os
import re
from pathlib import Path
import runpy
import shutil
import subprocess
import uuid

ROOT=Path(__file__).resolve().parents[3]
POLICY=runpy.run_path(str(ROOT/'tests/e2e/esp-chain/package-policy.py'))


def sha(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def freeze(source,target,expected):
    source,target=Path(source),Path(target)
    if source.is_symlink() or not source.is_file() or sha(source)!=expected:
        raise ValueError('prepared source differs from reviewed pin')
    with source.open('rb') as reader,target.open('xb') as writer:
        shutil.copyfileobj(reader,writer);writer.flush();os.fsync(writer.fileno())
    target.chmod(0o400)
    if sha(source)!=expected or sha(target)!=expected:raise ValueError('source changed while freezing')


def checked_inputs(inputs):
    inputs=Path(inputs)
    acquisition=json.loads((inputs/'acquisition.json').read_text())
    if acquisition.get('complete') is not True or acquisition.get('runtimeExecuted') is not False:
        raise ValueError('complete acquisition required before seed preparation')
    source=json.loads(POLICY['PLAN'].read_text())
    if sha(POLICY['PLAN'])!=acquisition['sourcePlanSha256']:
        raise ValueError('acquisition dependency source differs')
    wanted={entry['name']:entry['sha256'] for phase in POLICY['build_policy'](source,'0'*32)['phases'].values()
            for entry in phase['packages']}
    observed={entry['name']:entry['localSha256'] for entry in acquisition['files'] if entry.get('complete') is True}
    if set(observed)!=set(wanted)|{'cloud.qcow2'} or any(observed.get(name)!=value for name,value in wanted.items()):
        raise ValueError('acquisition does not contain complete approved archives')
    if (observed.get('cloud.qcow2')!='b6e3a4dac69b38d55a763b1752e8fd7bb12e3948672a79fee4ef13fa53839d2f' or
            (inputs/'cloud.qcow2').stat().st_size!=433651712):
        raise ValueError('cloud source differs from actual pinned acquisition')
    if any(sha(inputs/name)!=value for name,value in observed.items()):
        raise ValueError('acquired bytes changed before preparation')
    return acquisition,source,wanted,observed


def prepare(inputs,scratch,run=subprocess.run):
    inputs,scratch=Path(inputs).resolve(strict=True),Path(scratch).absolute()
    if not re.fullmatch('[A-Za-z0-9_/.-]+',str(scratch)):
        raise ValueError('scratch path cannot be encoded in QEMU arguments')
    acquisition,source,wanted,observed=checked_inputs(inputs)
    scratch.mkdir(mode=0o700,parents=False,exist_ok=False)
    seed=scratch/'seed';seed.mkdir(mode=0o700)
    scratch_id=uuid.uuid4().hex;vm_uuid=str(uuid.uuid4());challenge=os.urandom(32).hex()
    policy=POLICY['build_policy'](source,scratch_id)
    (seed/'packages.json').write_text(json.dumps(policy,sort_keys=True)+'\n')
    for name,value in wanted.items():freeze(inputs/name,seed/name,value)
    for name,source_path in {'bootstrap.py':Path(__file__).with_name('bootstrap.py'),
                             'readback.py':Path(__file__).with_name('readback.py'),
                             'package-consumer.py':ROOT/'tests/e2e/esp-chain/package-consumer.py'}.items():
        freeze(source_path,seed/name,sha(source_path))
    hashes={name:sha(seed/name) for name in ('bootstrap.py','readback.py','package-consumer.py','packages.json')}
    before=policy['phases']['old']['beforeInventory']
    baseline_sha=hashlib.sha256((json.dumps(before,sort_keys=True,separators=(',',':'))+'\n').encode()).hexdigest()
    manifest={'schemaVersion':1,'scratchId':scratch_id,'vmUuid':vm_uuid,'challenge':challenge,
              'helperHashes':hashes,'baselineSha256':baseline_sha}
    (seed/'manifest.json').write_text(json.dumps(manifest,sort_keys=True)+'\n')
    command='set -eu; mkdir -p /run/wootc-package-seed; mount -t iso9660 -o ro /dev/disk/by-label/CIDATA /run/wootc-package-seed; exec /usr/bin/python3 /run/wootc-package-seed/bootstrap.py /run/wootc-package-seed /var/lib/wootc/package-proof'
    (seed/'user-data').write_text('#cloud-config\npackage_update: false\npackage_upgrade: false\npackages: []\nresize_rootfs: false\ngrowpart:\n  mode: off\nssh_pwauth: false\nruncmd:\n  - '+json.dumps(['/bin/sh','-c',command])+'\n')
    (seed/'meta-data').write_text('instance-id: '+scratch_id+'\nlocal-hostname: wootc-package-qa\n')
    (seed/'network-config').write_text('version: 2\nethernets: {}\n')
    iso=scratch/'seed.iso'
    run(['/usr/bin/genisoimage','-quiet','-volid','CIDATA','-joliet','-rock','-o',str(iso),str(seed)],
        check=True,capture_output=True,timeout=30)
    if not iso.is_file() or not 0<iso.stat().st_size<=64*1024**2 or iso.stat().st_size%2048:
        raise ValueError('seed ISO exceeds bound or is not sector aligned')
    iso.chmod(0o400)
    freeze(inputs/'cloud.qcow2',scratch/'base.qcow2',observed['cloud.qcow2'])
    image=run(['/usr/bin/qemu-img','info','--output=json',str(scratch/'base.qcow2')],
              check=True,capture_output=True,timeout=30)
    info=json.loads(image.stdout)
    if (info['format']!='qcow2' or info.get('backing-filename') or info.get('data-file') or
            info.get('format-specific',{}).get('data',{}).get('data-file') or
            info['virtual-size']!=acquisition['qemuImgInfo']['virtual-size']):
        raise ValueError('frozen image source shape differs')
    run(['/usr/bin/qemu-img','create','-f','qcow2','-F','qcow2','-b',str(scratch/'base.qcow2'),str(scratch/'overlay.qcow2')],
        check=True,capture_output=True,timeout=30)
    for name,path in (('code.fd','/usr/share/OVMF/OVMF_CODE_4M.fd'),('vars.fd','/usr/share/OVMF/OVMF_VARS_4M.fd')):
        freeze(path,scratch/name,sha(path))
    (scratch/'vars.fd').chmod(0o600)
    for name,path in (('qga-readback.py',Path(__file__).with_name('qga-readback.py')),
                      ('qga-client.py',ROOT/'tests/e2e/qga.py')):
        freeze(path,scratch/name,sha(path))
    ownership=dict(manifest,stage=str(scratch.resolve()),policy=policy,seedSha256=sha(iso),
                   policySha256=hashes['packages.json'],qgaReadbackSourceSha256=hashes['readback.py'],
                   baseSha256=observed['cloud.qcow2'],actualVirtualBytes=info['virtual-size'],
                   firmwareSourceHashes={name:sha(scratch/name) for name in ('code.fd','vars.fd')},
                   hostHelperHashes={name:sha(scratch/name) for name in ('qga-readback.py','qga-client.py')},
                   runtimeExecuted=False,firmwareAcceptance=False,classicOsBootAcceptance=False)
    (scratch/'ownership.json').write_text(json.dumps(ownership,sort_keys=True,indent=2)+'\n')
    (scratch/'ownership.json').chmod(0o600)
    return ownership


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('inputs');parser.add_argument('exclusive_scratch');args=parser.parse_args()
    print(json.dumps(prepare(args.inputs,args.exclusive_scratch),sort_keys=True))
