"""Build the fixed installer bundle inside the authenticated helper initrd."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

ROOT=Path(__file__).resolve().parents[2]
HERE=ROOT/'payload/vm-observer'
MODULES=['boot_probe.py','python_environment.py','install_policy.py','install_bundle.py',
         'installer_commands.py','deployment_selection.py','label_policy.py','install_graph.py']
FILES=MODULES+['wootc-observer.service','wootc_ancestry.py','installer_entry.py','outer_install.sh']


def stage(destination):
    destination=Path(destination)
    if os.path.lexists(destination):raise ValueError('installer bundle destination collision')
    destination.mkdir(mode=0o700)
    retained=[]
    try:
        hashes={}
        for name in FILES:
            source=ROOT/'tests/e2e/phase3_ancestry.py' if name=='wootc_ancestry.py' else HERE/name
            before=source.lstat()
            if not stat.S_ISREG(before.st_mode) or before.st_nlink!=1 or before.st_size>131072:
                raise ValueError('installer build source shape unsupported')
            fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
            try:
                opened=os.fstat(fd)
                raw=os.read(fd,131073)
                if (opened.st_dev,opened.st_ino,opened.st_size,opened.st_mtime_ns)!=(before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns) or len(raw)!=before.st_size:
                    raise ValueError('installer build source changed')
            finally:os.close(fd)
            current=source.lstat()
            if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)!=(current.st_dev,current.st_ino,current.st_size,current.st_mtime_ns):
                raise ValueError('installer build source changed after reading')
            path=destination/name
            with path.open('xb') as writer:writer.write(raw);writer.flush();os.fsync(writer.fileno())
            path.chmod(0o444);retained.append(path)
            if path.read_bytes()!=raw:raise ValueError('staged installer source readback differs')
            hashes[name]=hashlib.sha256(raw).hexdigest()
        catalogue={name:hashes[name] for name in MODULES+['wootc-observer.service','wootc_ancestry.py']}
        path=destination/'catalogue.json';path.write_text(json.dumps(catalogue,sort_keys=True)+'\n');path.chmod(0o444);retained.append(path)
        hashes[path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
        path=destination/'closure.sha256';path.write_text(''.join(digest+'  '+name+'\n' for name,digest in sorted(hashes.items())));path.chmod(0o444);retained.append(path)
        return hashes
    except BaseException:
        for path in reversed(retained):path.unlink()
        destination.rmdir()
        raise

def protocol_metadata(template,hashes):
    value=json.loads(Path(template).read_text())
    observer=value['observerInstall']
    observer['sourceHashes']={name:hashes[name] for name in ('boot_probe.py','wootc_ancestry.py','wootc-observer.service')}
    return json.dumps(value,sort_keys=True,indent=2)+'\n'


if __name__=='__main__':
    if len(sys.argv)!=4:raise SystemExit('fixed destination, template and metadata output required')
    hashes=stage(sys.argv[1])
    # Output is part of the subsequently sealed runtime artifact closure.
    with Path(sys.argv[3]).open('x') as output:
        output.write(protocol_metadata(sys.argv[2],hashes));output.flush();os.fsync(output.fileno())
    print(json.dumps(hashes,sort_keys=True))
