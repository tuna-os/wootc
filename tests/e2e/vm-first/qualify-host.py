#!/usr/bin/env python3
"""Read-only prerequisites for a future Windows/WHPX run; never launches a VM."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import time

GIB = 1024 ** 3
KVM_GET_API_VERSION = 0xAE00
KVM_CHECK_EXTENSION = 0xAE03
KVM_CAP_USER_MEMORY = 3


def cpu_rows(text):
    rows = []
    for block in text.strip().split('\n\n'):
        fields = {}
        for line in block.splitlines():
            if ':' in line:
                key, value = line.split(':', 1)
                if key.strip() in fields:
                    raise ValueError('duplicate CPU field')
                fields[key.strip()] = value.strip()
        if fields:
            rows.append({'vendor': fields.get('vendor_id'), 'flags': fields.get('flags', '').split()})
    if not rows:
        raise ValueError('missing CPU observations')
    return rows


def memory(text):
    fields = {}
    for line in text.splitlines():
        m = re.fullmatch(r'(MemTotal|MemAvailable):\s+([0-9]+) kB', line)
        if m:
            if m[1] in fields:
                raise ValueError('duplicate memory field')
            fields[m[1]] = int(m[2]) * 1024
    if set(fields) != {'MemTotal', 'MemAvailable'}:
        raise ValueError('missing memory observations')
    return fields


def kvm_observation(path='/dev/kvm'):
    # These ioctls only query the existing KVM device. No CREATE_VM/CREATE_VCPU.
    fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
    try:
        return {'apiVersion': fcntl.ioctl(fd, KVM_GET_API_VERSION, 0),
                'userMemory': fcntl.ioctl(fd, KVM_CHECK_EXTENSION, KVM_CAP_USER_MEMORY)}
    finally:
        os.close(fd)


def collect(storage):
    rows = cpu_rows(Path('/proc/cpuinfo').read_text())
    vendors = {r['vendor'] for r in rows}
    module = 'kvm_intel' if vendors == {'GenuineIntel'} else 'kvm_amd' if vendors == {'AuthenticAMD'} else None
    nested = Path('/sys/module/' + module + '/parameters/nested').read_text().strip() if module else None
    resolved = Path(storage).resolve(strict=True)
    if not resolved.is_dir():
        raise ValueError('storage observation path is not a directory')
    fs = os.statvfs(resolved)
    return {'cpus': rows, 'nested': nested, 'memory': memory(Path('/proc/meminfo').read_text()),
            'storage': {'path': str(resolved), 'availableBytes': fs.f_bavail * fs.f_frsize},
            'kvm': kvm_observation()}


def assess(observed, cpu_model, minimum_host_bytes=84 * GIB):
    """Strict prerequisites only; positive receipt is never guest execution proof."""
    reasons = []
    rows = observed['cpus']
    vendors = {r['vendor'] for r in rows}
    if vendors == {'GenuineIntel'}:
        extension, required = 'vmx', {'vmx', 'ept'}
    elif vendors == {'AuthenticAMD'}:
        extension, required = 'svm', {'svm', 'npt'}
    else:
        extension, required = '', set()
        reasons.append('cpu-vendor-unknown')
    if not rows or len(rows) < 4:
        reasons.append('host-cpu-capacity')
    if not required or any(not required.issubset(set(r['flags'])) for r in rows):
        reasons.append('cpu-virtualization-not-observed')
    options = cpu_model.split(',')
    if (options[0] != 'host' or any(not x or x != x.strip() for x in options)
            or not extension or '+' + extension not in options
            or len(options) != len(set(options))
            or any(x.startswith(flag + '=') or x == '-' + flag
                   for flag in required for x in options)):
        reasons.append('outer-cpu-extension-not-explicitly-preserved')
    if observed['nested'] not in {'Y', 'y', '1'}:
        reasons.append('host-nesting-not-enabled')
    if observed['kvm']['apiVersion'] != 12 or observed['kvm']['userMemory'] < 1:
        reasons.append('kvm-unusable')
    if observed['memory']['MemTotal'] < 16_000_000_000 or observed['memory']['MemAvailable'] < int(9.5 * GIB):
        reasons.append('host-memory-capacity')
    if observed['storage']['availableBytes'] < minimum_host_bytes:
        reasons.append('host-storage-capacity')
    return reasons


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--storage-path', required=True)
    p.add_argument('--outer-cpu', required=True, help='exact proposed QEMU CPU argument; e.g. host,+vmx')
    p.add_argument('--receipt', required=True)
    p.add_argument('--run-id', required=True)
    args = p.parse_args(argv)
    receipt = {'schemaVersion': 1, 'runId': args.run_id, 'sourceSha': os.environ.get('GITHUB_SHA'),
               'capturedAtUnix': time.time(), 'scope': 'host-prerequisites-only',
               'guestExecutionQualified': False, 'desktopQualified': False,
               'outerCpuProposed': args.outer_cpu, 'outerCpuExpandedObserved': None,
               'windowsWhpxQualified': False, 'observations': None, 'refusals': []}
    try:
        receipt['observations'] = collect(args.storage_path)
        receipt['refusals'] = assess(receipt['observations'], args.outer_cpu)
    except (OSError, ValueError, KeyError, TypeError) as e:
        receipt['refusals'] = ['host-observation-failed']
        receipt['observationError'] = type(e).__name__ + ': ' + str(e)
    receipt['prerequisitesPassed'] = not receipt['refusals']
    # Publication failure is a failed stage; no success without durable receipt.
    with open(args.receipt, 'x', encoding='utf-8') as f:
        json.dump(receipt, f, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    print(json.dumps({'prerequisitesPassed': receipt['prerequisitesPassed'], 'refusals': receipt['refusals'],
                      'guestExecutionQualified': False, 'desktopQualified': False}))
    return 0 if receipt['prerequisitesPassed'] else 1


if __name__ == '__main__':
    sys.exit(main())
