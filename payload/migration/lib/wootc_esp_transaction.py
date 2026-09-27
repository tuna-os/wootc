"""Durable signed-trio transaction; all callers must hold the writer lock."""
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import uuid
from pathlib import Path
from wootc_chain_verify import FILES, verify_transition


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)


def write_bytes(path, data, exclusive=False):
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if exclusive else os.O_TRUNC)
    fd = os.open(path, flags, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        raise


def atomic_json(path, data):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        write_bytes(temporary, (json.dumps(data, sort_keys=True) + '\n').encode(), exclusive=True)
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path):
    raw = path.read_bytes()
    if len(raw) > 65536:
        raise ValueError('oversized ESP transaction record')
    return json.loads(raw)


def relative_path(value):
    normalized = value.strip().replace('\\', '/').strip('/').lower()
    if (not normalized or any(part in ('', '.', '..') for part in normalized.split('/'))
            or ':' in normalized):
        raise ValueError('invalid ESP owned path')
    return normalized


def find_owned_path(esp, relative):
    """Resolve FAT paths case-insensitively; reject ambiguity and symlinks."""
    current = esp
    for part in relative_path(relative).split('/'):
        matches = [p for p in current.iterdir() if p.name.lower() == part]
        if len(matches) != 1 or matches[0].is_symlink():
            raise ValueError('missing/ambiguous ESP owned path: ' + relative)
        current = matches[0]
    if not current.is_file():
        raise ValueError('owned ESP path is not a file: ' + relative)
    return current


def ownership(esp, local_manifest, receipt, observed_uuid, check_contents=True):
    if (receipt.get('schemaVersion') != 1 or
            receipt.get('hostEspUuid') != observed_uuid):
        raise ValueError('ESP identity/receipt mismatch')
    mirror = local_manifest.read_bytes()
    manifest = find_owned_path(esp, 'EFI/wootc/wootc-owned.txt').read_bytes()
    if (manifest != mirror or
            hashlib.sha256(mirror).hexdigest() != receipt.get('ownedManifestSha256')):
        raise ValueError('actual Phase1 owned manifest differs from mirror/receipt')
    owned = {relative_path(line) for line in mirror.decode('utf-8-sig').splitlines()
             if line.strip()}
    if not isinstance(receipt.get('files'), dict) or not receipt['files']:
        raise ValueError('missing ESP ownership content receipt')
    if len({relative_path(path) for path in receipt['files']}) != len(receipt['files']):
        raise ValueError('ambiguous duplicate receipt paths')
    for relative, expected in receipt['files'].items():
        if relative_path(relative) not in owned:
            raise ValueError('receipt path absent from actual owned manifest')
        if not isinstance(expected, str) or not re.fullmatch('[0-9a-f]{64}', expected):
            raise ValueError('invalid owned content hash')
        if check_contents and digest(find_owned_path(esp, relative)) != expected:
            raise ValueError('owned ESP content changed outside transaction: ' + relative)
    return owned


class Transaction:
    def __init__(self, esp, state, receipt_path, observed_uuid, failpoint=None, local_manifest="/etc/wootc/esp-manifest"):
        self.esp, self.state, self.receipt_path = map(Path, (esp, state, receipt_path))
        self.observed_uuid = observed_uuid
        self.local_manifest = Path(local_manifest)
        self.failpoint = failpoint or (lambda _: None)
        self.journal = self.state / 'pending.json'
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        details = self.state.lstat()
        if (not stat.S_ISDIR(details.st_mode) or details.st_uid != os.geteuid() or
                details.st_mode & 0o077):
            raise ValueError('transaction state is not a private owned directory')
        self.lock_fd = None

    def __enter__(self):
        self.lock_fd = os.open(self.state / 'writer.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        details = os.fstat(self.lock_fd)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.geteuid() or details.st_mode & 0o077:
            os.close(self.lock_fd); self.lock_fd = None
            raise ValueError('writer lock is not a private owned regular file')
        fcntl.flock(self.lock_fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        if self.lock_fd is not None:
            os.close(self.lock_fd)
            self.lock_fd = None

    def require_lock(self):
        if self.lock_fd is None:
            raise ValueError('ESP transaction writer lock is not held')

    def replace_verified(self, source, destination, expected, label):
        if digest(source) != expected:
            raise ValueError('transaction source/archive hash changed')
        temporary = destination.with_name('.wootc-' + uuid.uuid4().hex + '.new')
        try:
            write_bytes(temporary, source.read_bytes(), exclusive=True)
            if digest(temporary) != expected:
                raise ValueError('staged ESP write hash mismatch')
            sync_directory(destination.parent)
            self.failpoint('before-' + label)
            os.replace(temporary, destination)
            sync_directory(destination.parent)
            self.failpoint('after-' + label)
            if digest(destination) != expected:
                raise ValueError('published ESP write hash mismatch')
        finally:
            temporary.unlink(missing_ok=True)

    def write_artifact(self, source, relative, receipt, approved_hash=None):
        """Journal one owned artifact and its receipt; not an atomic kernel pair."""
        self.require_lock()
        if self.journal.exists():
            raise ValueError('pending transaction must recover before artifact write')
        ownership(self.esp, self.local_manifest, receipt, self.observed_uuid)
        relative = relative_path(relative)
        files = {relative_path(path):value for path,value in receipt['files'].items()}
        if relative not in files:
            raise ValueError('artifact destination absent from content receipt')
        source = Path(source); destination = find_owned_path(self.esp, relative)
        expected = digest(source)
        if approved_hash is not None and expected != approved_hash:
            raise ValueError('artifact source differs from authenticated preflight hash')
        if files[relative] == expected:
            return False
        archive = self.state / ('artifact-' + files[relative])
        if archive.is_symlink():
            raise ValueError('invalid artifact rollback archive')
        if not archive.exists():
            write_bytes(archive, destination.read_bytes(), exclusive=True)
            sync_directory(self.state)
        if digest(archive) != files[relative]:
            raise ValueError('artifact rollback archive corrupt')
        record = {'schemaVersion':1,'kind':'artifact','hostEspUuid':self.observed_uuid,
                  'target':relative,'oldHash':files[relative],'newHash':expected,
                  'oldReceipt':receipt}
        atomic_json(self.journal, record)
        try:
            self.replace_verified(source, destination, expected, 'artifact')
            updated = dict(receipt); updated['files'] = files
            updated['files'][relative] = expected
            atomic_json(self.receipt_path, updated)
            self.journal.unlink(); sync_directory(self.state)
            return True
        except BaseException:
            self.recover()
            raise

    def recover(self):
        self.require_lock()
        if not self.journal.exists():
            return
        record = read_json(self.journal)
        if record.get('hostEspUuid') != self.observed_uuid:
            raise ValueError('pending transaction belongs to a different ESP')
        if record.get('kind') == 'artifact':
            receipt = record['oldReceipt']
            owned = ownership(self.esp, self.local_manifest, receipt, self.observed_uuid, check_contents=False)
            relative = relative_path(record['target'])
            files = {relative_path(path):value for path,value in receipt['files'].items()}
            if (record.get('schemaVersion') != 1 or relative not in owned or
                    files.get(relative) != record['oldHash'] or
                    not re.fullmatch('[0-9a-f]{64}', record['newHash'])):
                raise ValueError('invalid pending artifact content ownership')
            archive = self.state / ('artifact-' + record['oldHash'])
            destination = find_owned_path(self.esp, relative)
            if archive.is_symlink() or digest(archive) != record['oldHash']:
                raise ValueError('artifact rollback archive corrupt')
            if digest(destination) not in (record['oldHash'],record['newHash']):
                raise ValueError('artifact changed outside interrupted transaction')
            # Refuse unrelated mutations before restoring this one artifact.
            for path, expected in files.items():
                if path != relative and digest(find_owned_path(self.esp,path)) != expected:
                    raise ValueError('owned ESP content changed outside artifact transaction')
            self.replace_verified(archive,destination,record['oldHash'],'rollback-artifact')
            atomic_json(self.receipt_path,receipt)
            self.journal.unlink(); sync_directory(self.state)
            return
        # Journal contains relative paths only. Revalidate all destinations and
        # the immutable whole-trio archive before the first recovery write.
        if record.get('schemaVersion') != 1 or not re.fullmatch(
                r'EFI/wootc/archive/[0-9a-f]{64}', record.get('archive', '')):
            raise ValueError('invalid pending transaction archive')
        owned = ownership(self.esp, self.local_manifest, record['oldReceipt'], self.observed_uuid, check_contents=False)
        for name in FILES:
            relative = record['targets'][name]
            if (relative_path(relative) != relative_path('EFI/'+record['oldReceipt']['loaderVendor']+'/'+name) or
                    relative_path(relative) not in owned or
                    {relative_path(path):value for path,value in record['oldReceipt']['files'].items()}.get(relative_path(relative)) != record['oldHashes'][name]):
                raise ValueError('pending transaction target lacks content ownership')
        archive = self.esp / record['archive']
        if archive.is_symlink() or archive.parent.is_symlink():
            raise ValueError('invalid rollback archive path')
        targets = {name: find_owned_path(self.esp, record['targets'][name]) for name in FILES}
        for name in FILES:
            if digest(archive / name) != record['oldHashes'][name]:
                raise ValueError('rollback archive corrupt/missing')
            if digest(targets[name]) not in (record['oldHashes'][name], record['newHashes'][name]):
                raise ValueError('ESP changed outside interrupted transaction')
        target_paths = {relative_path(path) for path in record['targets'].values()}
        for relative, expected in record['oldReceipt']['files'].items():
            if relative_path(relative) not in target_paths and digest(find_owned_path(self.esp,relative)) != expected:
                raise ValueError('owned ESP content changed outside interrupted transaction')
        for name in ('grubx64.efi', 'mmx64.efi', 'shimx64.efi'):
            self.replace_verified(archive / name, targets[name], record['oldHashes'][name], 'rollback-' + name)
        atomic_json(self.receipt_path, record['oldReceipt'])
        self.journal.unlink()
        sync_directory(self.state)

    def refresh(self, source, receipt, efivars, closure, verify=verify_transition):
        self.require_lock()
        if self.journal.exists():
            raise ValueError('pending transaction must recover before refresh')
        ownership(self.esp, self.local_manifest, receipt, self.observed_uuid)
        vendor = receipt.get('loaderVendor', '')
        source_vendor = receipt.get('sourceVendor', '')
        if (not vendor or not source_vendor or '/' in vendor or '/' in source_vendor or
                vendor in ('.', '..') or source_vendor in ('.', '..')):
            raise ValueError('invalid source/loader vendor receipt')
        source = Path(source)
        if source.name != source_vendor:
            raise ValueError('candidate source vendor differs from installed receipt')
        targets = {name: find_owned_path(self.esp, 'EFI/' + vendor + '/' + name) for name in FILES}
        old_hashes = {name: digest(path) for name, path in targets.items()}
        transaction_id = uuid.uuid4().hex
        stage = self.state / transaction_id
        stage.mkdir(mode=0o700)
        try:
            current = stage / 'old'; candidate = stage / source_vendor
            current.mkdir(); candidate.mkdir()
            for name in FILES:
                write_bytes(current / name, targets[name].read_bytes(), exclusive=True)
                write_bytes(candidate / name, (source / name).read_bytes(), exclusive=True)
            # Freeze the source provenance and all three components together.
            metadata = source.parent.parent / 'EFI.json'
            if not metadata.is_file():
                raise ValueError('candidate bundle has no source EFI.json')
            metadata_data = metadata.read_bytes()
            if len(metadata_data) > 65536:
                raise ValueError('oversized source EFI.json')
            metadata_json = json.loads(metadata_data)
            if not metadata_json.get('version') or not metadata_json.get('timestamp'):
                raise ValueError('incomplete source EFI.json')
            write_bytes(stage / 'EFI.json', metadata_data, exclusive=True)
            sync_directory(current); sync_directory(candidate); sync_directory(stage)
            proof = verify(current, candidate, efivars, closure)
            new_hashes = {name: digest(candidate / name) for name in FILES}
            if metadata_json.get('sourceKind') == 'classic':
                facts={key:value for key,value in metadata_json.items() if key not in ('version','timestamp')}
                stamp=hashlib.sha256(json.dumps(facts,sort_keys=True,separators=(',',':')).encode()).hexdigest()
                if (metadata_json.get('components') != new_hashes or
                        metadata_json.get('version') != 'classic-sha256:'+stamp):
                    raise ValueError('classic source stamp differs from frozen signed bundle')
            if (proof.get('verified') is not True or proof.get('current') != old_hashes
                    or proof.get('candidate') != new_hashes):
                raise ValueError('verifier evidence differs from frozen bundle')
            if new_hashes == old_hashes:
                return False
            archive_id = hashlib.sha256(json.dumps(old_hashes, sort_keys=True).encode()).hexdigest()
            archive_relative = 'EFI/wootc/archive/' + archive_id
            archive = self.esp / archive_relative
            if archive.is_symlink() or archive.parent.is_symlink():
                raise ValueError('invalid archive path')
            archive.parent.mkdir(exist_ok=True)
            if not archive.exists():
                archive.mkdir()
                for name in FILES:
                    write_bytes(archive / name, (current / name).read_bytes(), exclusive=True)
                atomic_json(archive / 'hashes.json', old_hashes)
                sync_directory(archive); sync_directory(archive.parent)
            if read_json(archive / 'hashes.json') != old_hashes or any(
                    digest(archive / name) != old_hashes[name] for name in FILES):
                raise ValueError('immutable whole-trio archive does not match')
            record = {'schemaVersion': 1, 'hostEspUuid': self.observed_uuid,
                      'archive': archive_relative, 'targets': {name: str(path.relative_to(self.esp)) for name, path in targets.items()},
                      'oldHashes': old_hashes, 'newHashes': new_hashes, 'oldReceipt': receipt}
            atomic_json(self.journal, record)
            try:
                for name in ('grubx64.efi', 'mmx64.efi', 'shimx64.efi'):
                    self.replace_verified(candidate / name, targets[name], new_hashes[name], name)
                updated = dict(receipt); updated['files'] = {relative_path(path):value for path,value in receipt['files'].items()}
                for name, path in targets.items():
                    updated['files'][relative_path(str(path.relative_to(self.esp)))] = new_hashes[name]
                updated['sourceEFI'] = metadata_json
                atomic_json(self.receipt_path, updated)
                self.journal.unlink(); sync_directory(self.state)
                return True
            except BaseException:
                # Recovery failure remains visible, with journal/archive intact.
                self.recover()
                raise
        finally:
            shutil.rmtree(stage)
