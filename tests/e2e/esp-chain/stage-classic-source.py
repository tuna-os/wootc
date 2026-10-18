"""QA-only FAT source copies from actual installed package payloads, never /usr edits."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0, '/var/usrlocal/lib/wootc')
from wootc_chain_source import classic_os_release

FILES = ('shimx64.efi', 'grubx64.efi', 'mmx64.efi')


def stage(run=subprocess.check_output):
    os_id = classic_os_release('/etc/os-release')['ID']
    vendors = {'debian': 'debian', 'ubuntu': 'ubuntu', 'fedora': 'fedora',
               'almalinux': 'almalinux', 'rocky': 'rocky', 'centos': 'centos', 'rhel': 'redhat'}
    vendor = vendors[os_id]
    roles = {'shimx64.efi': ('shim-signed', '/usr/lib/shim/shimx64.efi.signed'),
             'grubx64.efi': ('grub-efi-amd64-signed', '/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed'),
             'mmx64.efi': ('shim-helpers-amd64-signed', '/usr/lib/shim/mmx64.efi.signed')}
    if os_id == 'ubuntu':
        roles['mmx64.efi'] = ('shim-signed', '/usr/lib/shim/mmx64.efi')
    captured = {}
    def query(*args):
        value = run(list(args), text=True, timeout=30)
        captured[args] = value
        return value
    target = Path('/boot/efi/EFI')/vendor
    target.mkdir(parents=True, exist_ok=True)
    sources = {}
    for name in FILES:
        if os_id in ('debian', 'ubuntu'):
            package, path = roles[name]
            path = Path(path).resolve(strict=True)
            owner = query('dpkg-query', '--search', str(path)).strip().rsplit(': ', 1)
            if len(owner) != 2 or owner[1] != str(path) or owner[0] not in (package, package+':amd64'):
                raise ValueError('canonical package owner differs')
            fields = query('dpkg-query', '--show', '--showformat=${binary:Package}\t${Version}\t${db:Status-Status}\t${Architecture}', package).split('\t')
            if len(fields) != 4 or fields[0] not in (package, package+':amd64') or fields[2:] != ['installed', 'amd64']:
                raise ValueError('canonical package is not installed amd64')
            expected = hashlib.sha256(path.read_bytes()).hexdigest()
        else:
            package = 'grub2-efi-x64' if name == 'grubx64.efi' else 'shim-x64'
            fields = query('rpm', '-q', '--qf', '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{FILEDIGESTALGO}\n', package).strip().split('\t')
            if len(fields) != 4 or fields[0] != package or fields[2:] != ['x86_64', '8']:
                raise ValueError('invalid canonical RPM facts')
            version = fields[1].removeprefix('0:')
            if '/' in version or version in ('.', '..'):
                raise ValueError('unsafe RPM version')
            family = 'grub2' if name == 'grubx64.efi' else 'shim'
            versioned = Path('/usr/lib/efi')/family/version/'EFI'/vendor/name
            rows = query('rpm', '-q', '--qf', '[%{FILENAMES}\t%{FILEDIGESTS}\t%{FILESTATES}\t%{FILEMODES:octal}\n]', package).splitlines()
            selected = [line.split('\t') for line in rows if line.split('\t')[0] in (str(target/name), str(versioned))]
            if len(selected) != 1 or len(selected[0]) != 4 or selected[0][2] != '0' or int(selected[0][3], 8)&0o170000 != 0o100000:
                raise ValueError('ambiguous or abnormal installed RPM payload')
            path = Path(selected[0][0]); expected = selected[0][1]
            if query('rpm', '-qf', '--qf', '%{NAME}', str(path)) != package:
                raise ValueError('canonical RPM owner differs')
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('canonical payload differs')
        sources[name] = path, expected
    with tempfile.TemporaryDirectory(prefix='wootc-qa-source-') as temporary:
        for name, (path, expected) in sources.items():
            copied = Path(temporary)/name
            shutil.copyfile(path, copied)
            if hashlib.sha256(copied.read_bytes()).hexdigest() != expected or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise ValueError('source changed during snapshot')
        for args, value in captured.items():
            if run(list(args), text=True, timeout=30) != value:
                raise ValueError('package changed during snapshot')
        for name in FILES:
            destination = target/('.qa-'+name)
            if destination.exists() or destination.is_symlink():
                raise ValueError('foreign source staging file')
            with destination.open('xb') as stream:
                stream.write((Path(temporary)/name).read_bytes()); stream.flush(); os.fsync(stream.fileno())
            os.replace(destination, target/name)
        descriptor = os.open(target, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    return vendor


if __name__ == '__main__':
    print(stage())
