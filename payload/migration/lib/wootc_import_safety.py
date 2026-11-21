#!/usr/bin/env python3
"""Office, Steam, developer-setup and external-file import: preserve native files, publish complete copies.

All destination operations are relative to an owned, no-symlink directory fd.
Only newly created inodes are chowned. Existing application files are never
replaced; the dictionary's append-only recovery record is the sole exception.
"""
import argparse
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import uuid


# useradd --create-home copies the image's skeleton into every new home before
# any import runs; a file still byte-identical to it is the distribution's
# placeholder, not a native edit.
SKEL = Path('/etc/skel')
RENAME_EXCHANGE = 2


class Refusal(ValueError):
    pass


def parts(relative):
    path = Path(relative)
    if path.is_absolute() or not path.parts or any(p in ('', '.', '..') for p in path.parts):
        raise Refusal('unsafe relative path: ' + str(relative))
    return path.parts


@contextlib.contextmanager
def source_authority():
    """Use root authority only to read a source, never to write user files."""
    original = os.geteuid()
    try:
        if os.getuid() == 0:
            os.seteuid(0)
        yield
    finally:
        if os.geteuid() != original:
            os.seteuid(original)


def source_mounted(host):
    """The writable host mount sits below root-only /run/initramfs (0700), so a
    mount check run as the target user sees EACCES and reports it unmounted."""
    with source_authority():
        return subprocess.run(['mountpoint', '-q', str(host)], check=False).returncode == 0


@contextlib.contextmanager
def source_file(path):
    """Reject symlinks in the entire source path, not just its final component."""
    path = Path(path)
    file_fd = None
    with source_authority():
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        try:
            for name in path.absolute().parts[1:-1]:
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
            file_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        finally:
            os.close(fd)
    try:
        if not stat.S_ISREG(os.fstat(file_fd).st_mode):
            raise Refusal('not a regular source file: ' + str(path))
        with os.fdopen(file_fd, 'rb', closefd=False) as stream:
            yield stream
    finally:
        os.close(file_fd)


def source_bytes(path):
    with source_file(path) as stream:
        return stream.read()


def skel_digest(relative):
    """sha256 of the image's skeleton copy of a home-relative file, or None."""
    try:
        with source_file(SKEL / relative) as stream:
            digest = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
            return digest.digest()
    except FileNotFoundError:
        return None


def exchange(parent, first, second):
    """Atomically swap two names in one directory: renameat2(RENAME_EXCHANGE)."""
    rename = getattr(ctypes.CDLL(None, use_errno=True), 'renameat2', None)
    if rename is None:
        raise Refusal('renameat2(RENAME_EXCHANGE) is required')
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(parent, os.fsencode(first), parent, os.fsencode(second), RENAME_EXCHANGE) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), second)


class Home:
    def __init__(self, account):
        self.uid, self.gid = account.pw_uid, account.pw_gid
        # Fedora uses /home -> /var/home. Resolve that account-level alias once;
        # no imported relative path is resolved through a symlink.
        self.path = Path(account.pw_dir).resolve(strict=True)
        self.fd = os.open(self.path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        if os.fstat(self.fd).st_uid != self.uid:
            os.close(self.fd)
            raise Refusal('target home is not owned by the target user')

    def close(self):
        os.close(self.fd)

    @contextlib.contextmanager
    def directory(self, relative, create=True):
        fd = os.dup(self.fd)
        try:
            for name in (() if relative == '.' else parts(relative)):
                made = False
                if create:
                    try:
                        os.mkdir(name, mode=0o700 if name == '.ssh' else 0o755, dir_fd=fd)
                        made = True
                    except FileExistsError:
                        pass
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                if made:
                    os.fchown(child, self.uid, self.gid)
                    os.fsync(fd)
                if os.fstat(child).st_uid != self.uid:
                    os.close(child)
                    raise Refusal('destination directory is not target-owned: ' + str(relative))
                os.close(fd)
                fd = child
            yield fd
        finally:
            os.close(fd)

    def verify_directory(self, relative, fd):
        root = os.stat(self.path, follow_symlinks=False)
        pinned = os.fstat(self.fd)
        if (root.st_dev, root.st_ino, root.st_uid) != (pinned.st_dev, pinned.st_ino, self.uid):
            raise Refusal('target home changed during import')
        with self.directory(relative, create=False) as current:
            a, b = os.fstat(current), os.fstat(fd)
            if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
                raise Refusal('destination parent changed during import: ' + str(relative))

    def read(self, relative):
        path = Path(relative)
        try:
            with self.directory(str(path.parent), create=False) as parent:
                fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                try:
                    info = os.fstat(fd)
                    if not stat.S_ISREG(info.st_mode) or info.st_uid != self.uid or info.st_nlink != 1:
                        raise Refusal('destination must be a target-owned, single-link regular file: ' + str(relative))
                    with os.fdopen(fd, 'rb', closefd=False) as stream:
                        return stream.read()
                finally:
                    os.close(fd)
        except FileNotFoundError:
            return None

    def file_digest(self, relative, parent):
        path = Path(relative)
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != self.uid or info.st_nlink != 1:
                raise Refusal('unsafe existing destination: ' + str(relative))
            digest = hashlib.sha256()
            with os.fdopen(fd, 'rb', closefd=False) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            after = os.fstat(fd)
            named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if ((info.st_size, info.st_mtime_ns, info.st_ctime_ns) !=
                    (after.st_size, after.st_mtime_ns, after.st_ctime_ns) or
                    (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino)):
                raise Refusal('existing destination changed during comparison: ' + str(relative))
            self.verify_directory(str(path.parent), parent)
            return digest.digest()
        finally:
            os.close(fd)

    def publish(self, relative, source=None, data=None, mode=0o644, replace_skel=False):
        """Return copied/already-present/preserved. link(2) never clobbers a race.

        replace_skel: an existing destination still byte-identical to the
        image's /etc/skel copy is exchanged for the import. If it changed
        before the exchange, it is exchanged back and preserved."""
        path = Path(relative)
        with self.directory(str(path.parent)) as parent:
            try:
                existing = self.file_digest(relative, parent)
            except FileNotFoundError:
                existing = None
            if existing is not None:
                digest = hashlib.sha256()
                if source is None:
                    digest.update(data)
                else:
                    with source_file(source) as stream:
                        before = os.fstat(stream.fileno())
                        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                            digest.update(chunk)
                        after = os.fstat(stream.fileno())
                        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                            raise Refusal('source changed during comparison: ' + str(source))
                self.verify_directory(str(path.parent), parent)
                if existing == digest.digest():
                    return 'already-present'
                if not replace_skel or existing != skel_digest(relative):
                    return 'preserved'
            skeleton = existing
            temporary = '.wootc-import-' + uuid.uuid4().hex
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=parent)
            try:
                digest = hashlib.sha256()
                with os.fdopen(fd, 'wb', closefd=False) as out:
                    if source is None:
                        out.write(data)
                        digest.update(data)
                    else:
                        with source_file(source) as stream:
                            before = os.fstat(stream.fileno())
                            while True:
                                chunk = stream.read(1024 * 1024)
                                if not chunk:
                                    break
                                out.write(chunk)
                                digest.update(chunk)
                            after = os.fstat(stream.fileno())
                            if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                                raise Refusal('source changed while copying: ' + str(source))
                    out.flush()
                    os.fchown(fd, self.uid, self.gid)
                    os.fchmod(fd, mode)
                    os.fsync(fd)
                self.verify_directory(str(path.parent), parent)
                if skeleton is not None:
                    exchange(parent, temporary, path.name)
                    try:
                        replaced = self.file_digest(str(path.parent / temporary), parent)
                    except BaseException:
                        exchange(parent, temporary, path.name)
                        raise
                    if replaced != skeleton:
                        exchange(parent, temporary, path.name)
                        return 'preserved'
                else:
                    try:
                        os.link(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
                    except FileExistsError:
                        existing = self.file_digest(relative, parent)
                        self.verify_directory(str(path.parent), parent)
                        if existing == digest.digest():
                            return 'already-present'
                        return 'preserved'
                os.fsync(parent)
                # Read through the pinned parent, not a possibly swapped path.
                check = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
                try:
                    if os.fstat(check).st_ino != os.fstat(fd).st_ino:
                        raise Refusal('destination changed during publication: ' + str(relative))
                finally:
                    os.close(check)
                self.verify_directory(str(path.parent), parent)
                return 'copied'
            finally:
                os.close(fd)
                os.unlink(temporary, dir_fd=parent)

    @contextlib.contextmanager
    def lock(self, name='.import.lock'):
        if '/' in name or name in ('.', '..'):
            raise Refusal('unsafe import lock name')
        with self.directory('.config/wootc') as parent:
            fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                         0o600, dir_fd=parent)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid not in (self.uid, os.geteuid()):
                    raise Refusal('unsafe import lock')
                os.fchown(fd, self.uid, self.gid)
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                yield
            finally:
                os.close(fd)

    def record(self, relative, value):
        """Only wootc-owned result/receipt files may be replaced atomically."""
        path = Path(relative)
        self.read(relative)  # refuse symlinks, foreign owners, hardlinks
        with self.directory(str(path.parent)) as parent:
            name = '.wootc-result-' + uuid.uuid4().hex
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent)
            try:
                with os.fdopen(fd, 'w', closefd=False) as out:
                    json.dump(value, out, ensure_ascii=True)
                    out.write('\n')
                    out.flush()
                    os.fchown(fd, self.uid, self.gid)
                    os.fsync(fd)
                self.verify_directory(str(path.parent), parent)
                os.replace(name, path.name, src_dir_fd=parent, dst_dir_fd=parent)
                os.fsync(parent)
                self.verify_directory(str(path.parent), parent)
            finally:
                os.close(fd)
                try:
                    os.unlink(name, dir_fd=parent)
                except FileNotFoundError:
                    pass


def outcome():
    return {'status': 'unchanged', 'migrated': [], 'alreadyPresent': [], 'preserved': [], 'failed': []}


def item(result, destination, operation):
    try:
        state = operation()
        key = {'copied': 'migrated', 'already-present': 'alreadyPresent', 'preserved': 'preserved'}[state]
        result[key].append(str(destination))
    except (OSError, ValueError) as error:
        result['failed'].append({'path': str(destination), 'error': str(error)})


def finish(home, record, result):
    result['status'] = ('failed' if result['failed'] else 'partial' if result['preserved']
                        else 'success' if result['migrated'] or result['alreadyPresent'] else 'unchanged')
    home.record(record, result)
    return result


def dictionary(home, relative, words):
    """Append-only journal: a crash never causes a partial append to be accepted.

    Recovery continues only when the original prefix and our exact partial suffix
    still match. A Linux edit during an interrupted append is preserved and refuses
    automatic recovery; no truncate/rollback can discard that edit.
    """
    journal = '.config/wootc/office-dictionary-pending.json'
    pending_raw = home.read(journal)
    current = home.read(relative)
    recovered = False
    if current is None:
        initial = b'OOoUserDict1\nlang: <none>\ntype: positive\n---\n'
        state = home.publish(relative, data=initial)
        if state == 'preserved':
            raise Refusal('dictionary appeared during initialization; retry')
        current = home.read(relative)
    if pending_raw is not None:
        pending = json.loads(pending_raw)
        if pending.get('active'):
            length = pending['length']
            addition = pending['addition'].encode('utf-8')
            if (hashlib.sha256(current[:length]).hexdigest() != pending['sha256'] or
                    len(current) < length or not addition.startswith(current[length:])):
                raise Refusal('dictionary changed after interrupted append; pending receipt retained for review')
            remaining = addition[len(current) - length:]
            append_dictionary(home, relative, current, remaining)
            recovered = bool(remaining)
            home.record(journal, {'active': False})
            current = home.read(relative)
    known = set(current.decode('utf-8').splitlines())
    missing = []
    for word in words:
        if word and not word.startswith('#') and word not in known:
            missing.append(word)
            known.add(word)
    if not missing:
        return 'copied' if recovered else 'already-present'
    addition = (('' if current.endswith(b'\n') else '\n') + '\n'.join(missing) + '\n').encode('utf-8')
    home.record(journal, {'active': True, 'length': len(current),
                          'sha256': hashlib.sha256(current).hexdigest(), 'addition': addition.decode('utf-8')})
    append_dictionary(home, relative, current, addition)
    home.record(journal, {'active': False})
    return 'copied'


def append_dictionary(home, relative, before, addition):
    path = Path(relative)
    with home.directory(str(path.parent), create=False) as parent:
        fd = os.open(path.name, os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != home.uid or info.st_nlink != 1:
                raise Refusal('unsafe dictionary ownership/type')
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with os.fdopen(fd, 'rb', closefd=False) as stream:
                if stream.read() != before:
                    raise Refusal('dictionary changed before append; pending receipt retained')
            home.verify_directory(str(path.parent), parent)
            named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
                raise Refusal('dictionary replaced before append; pending receipt retained')
            view = memoryview(addition)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise OSError('dictionary append made no progress')
                view = view[written:]
            os.fsync(fd)
            os.lseek(fd, 0, os.SEEK_SET)
            with os.fdopen(fd, 'rb', closefd=False) as stream:
                if stream.read() != before + addition:
                    raise Refusal('dictionary changed during append; pending receipt retained')
            home.verify_directory(str(path.parent), parent)
            named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
                raise Refusal('dictionary replaced during append; pending receipt retained')
        finally:
            os.close(fd)


DEFAULTS = b'''<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
 <item oor:path="/org.openoffice.Setup/Office/Factories/org.openoffice.Setup:Factory['com.sun.star.text.TextDocument']"><prop oor:name="ooSetupFactoryDefaultFilter" oor:op="fuse"><value>MS Word 2007 XML</value></prop></item>
 <item oor:path="/org.openoffice.Setup/Office/Factories/org.openoffice.Setup:Factory['com.sun.star.sheet.SpreadsheetDocument']"><prop oor:name="ooSetupFactoryDefaultFilter" oor:op="fuse"><value>Calc MS Excel 2007 XML</value></prop></item>
 <item oor:path="/org.openoffice.Setup/Office/Factories/org.openoffice.Setup:Factory['com.sun.star.presentation.PresentationDocument']"><prop oor:name="ooSetupFactoryDefaultFilter" oor:op="fuse"><value>Impress MS PowerPoint 2007 XML</value></prop></item>
</oor:items>
'''


def office(home, host, winuser):
    source = host / 'Users' / winuser
    lo = '.config/libreoffice/4/user'
    microsoft = source / 'AppData/Roaming/Microsoft'
    result = outcome()
    words, copies, autocorrect = [], [], None
    # Listing and reading the source need its authority; publishing below runs
    # without it, as the target user.
    with source_authority():
        if not source.is_dir() or source.is_symlink():
            raise Refusal('missing or symlinked Windows profile')
        for path in sorted((microsoft / 'UProof').glob('*')) + sorted((microsoft / 'Spelling').glob('*/default.dic')):
            if path.suffix.lower() != '.dic':
                continue
            try:
                raw = source_bytes(path)
                encoding = 'utf-16' if raw.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
                words.extend(raw.decode(encoding).splitlines())
            except (OSError, ValueError) as error:
                result['failed'].append({'path': str(path), 'error': str(error)})
        for directory, extensions, destination in (
                (microsoft / 'Templates', {'.dotx', '.dotm', '.xltx', '.potx'}, lo + '/template'),
                (source / 'AppData/Local/Microsoft/Windows/Fonts', {'.ttf', '.otf', '.ttc'}, '.local/share/fonts')):
            copies += [(path, destination + '/' + path.name) for path in sorted(directory.glob('*'))
                       if path.suffix.lower() in extensions]
        for acl in sorted((microsoft / 'Office').glob('*.acl'))[:1]:
            try:
                strings = re.findall(rb'(?:[\x20-\x7e]\x00){2,40}', source_bytes(acl))
                pairs = [value.decode('utf-16le') for value in strings]
                if len(pairs) >= 2:
                    autocorrect = '# AutoCorrect entries recovered from MS Office (review/import):\n'
                    autocorrect += ''.join(f'{pairs[i]}\t=>\t{pairs[i+1]}\n' for i in range(0, len(pairs)-1, 2))
            except (OSError, ValueError) as error:
                result['failed'].append({'path': str(acl), 'error': str(error)})
    pending_raw = home.read('.config/wootc/office-dictionary-pending.json')
    pending = json.loads(pending_raw) if pending_raw is not None else {}
    if not isinstance(pending, dict):
        raise Refusal('invalid dictionary pending receipt; retained for review')
    if words or pending.get('active'):
        destination = lo + '/wordbook/standard.dic'
        item(result, destination, lambda: dictionary(home, destination, words))
    for path, relative in copies:
        item(result, relative, lambda p=path, r=relative: home.publish(r, source=p))
    if autocorrect is not None:
        relative = lo + '/wootc-office-autocorrect.txt'
        item(result, relative, lambda: home.publish(relative, data=autocorrect.encode('utf-8')))
    relative = lo + '/registrymodifications.xcu'
    # An existing native setting is a deliberate choice, not an imported setting.
    try:
        if home.read(relative) is None:
            item(result, relative, lambda: home.publish(relative, data=DEFAULTS))
    except (OSError, ValueError) as error:
        result['failed'].append({'path': relative, 'error': str(error)})
    result['note'] = ('Existing Linux files are preserved. AutoCorrect is a review file, not active replacements. '
                      'OOXML defaults are installed only when no native configuration exists; ribbon layout and macros do not transfer.')
    return finish(home, '.config/wootc/bridge-office.json', result)


def vdf_paths(raw):
    """Parse enough KeyValues to validate structure, exact paths and unique indices."""
    text = raw.decode('utf-8-sig')
    token = re.compile(r'\s+|//[^\n]*|"(?:\\.|[^"\\])*"|[{}]')
    tokens = []
    end = 0
    for match in token.finditer(text):
        if match.start() != end:
            raise Refusal('malformed Steam libraryfolders.vdf')
        end = match.end()
        value = match.group()
        if value.isspace() or value.startswith('//'):
            continue
        if value.startswith('"'):
            value = re.sub(r'\\([\\"])', r'\1', value[1:-1])
            tokens.append(('string', value))
        else:
            tokens.append((value, value))
    if end != len(text):
        raise Refusal('malformed Steam libraryfolders.vdf')
    position = 0
    def block(nested=False):
        nonlocal position
        entries = {}
        while position < len(tokens):
            kind, key = tokens[position]
            position += 1
            if kind == '}':
                if nested:
                    return entries
                raise Refusal('unexpected Steam VDF closing brace')
            if kind != 'string' or position >= len(tokens):
                raise Refusal('malformed Steam VDF key')
            value_kind, value = tokens[position]
            position += 1
            if value_kind == '{':
                value = block(True)
            elif value_kind != 'string':
                raise Refusal('malformed Steam VDF value')
            if key in entries:
                raise Refusal('duplicate Steam VDF key/index: ' + key)
            entries[key] = value
        if nested:
            raise Refusal('unterminated Steam VDF block')
        return entries
    root = block()
    if set(root) != {'libraryfolders'} or not isinstance(root['libraryfolders'], dict):
        raise Refusal('missing Steam libraryfolders object')
    paths = []
    for key, value in root['libraryfolders'].items():
        if key.isdigit():
            path = value.get('path') if isinstance(value, dict) else value
            if not isinstance(path, str):
                raise Refusal('Steam library entry has no path')
            paths.append(path)
    return paths


def steam_libraries(host):
    with source_authority():
        default = host / 'Program Files (x86)/Steam'
        libraries = {str(default)} if (default / 'steamapps').is_dir() else set()
        vdf = default / 'steamapps/libraryfolders.vdf'
        if vdf.exists() or vdf.is_symlink():
            for path in vdf_paths(source_bytes(vdf)):
                if re.match(r'^[cC]:[\\/]', path):
                    relative = path[3:].replace('\\', '/')
                    parts(relative)
                    library = host / relative
                    if (library / 'steamapps').is_dir():
                        libraries.add(str(library))
    return sorted(libraries)


def steam_running(uid):
    # /proc is observed directly rather than trusting a PATH-provided pgrep.
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid == uid:
                command = (entry / 'comm').read_text().strip().lower()
                if command in ('steam', 'steamwebhelper', 'steamservice'):
                    return True
        except FileNotFoundError:
            continue
    return False


def steam(home, libraries):
    result = outcome()
    result['libraries'] = [{'path': path + '/steamapps'} for path in libraries]
    if not libraries:
        result['registered'] = False
        return finish(home, '.config/wootc/bridge-steam.json', result)
    initialized = False
    for root in ('.local/share/Steam', '.var/app/com.valvesoftware.Steam/.local/share/Steam'):
        relative = root + '/steamapps/libraryfolders.vdf'
        try:
            with home.directory(root + '/steamapps', create=False):
                pass
            initialized = True
            raw = home.read(relative)
            if raw is not None:
                existing = vdf_paths(raw)
                for library in libraries:
                    if library in existing:
                        result['alreadyPresent'].append(library)
                    else:
                        result['failed'].append({'path': relative, 'library': library,
                            'error': 'Existing Steam metadata preserved. Use Steam Settings > Storage > Add Library for this path.'})
                continue
            if steam_running(home.uid):
                raise Refusal('Steam is running; close Steam before registering libraries')
            body = '"libraryfolders"\n{\n'
            for index, library in enumerate([str(home.path / root)] + libraries):
                escaped = library.replace('\\', '\\\\').replace('"', '\\"')
                body += f'\t"{index}"\n\t{{\n\t\t"path"\t\t"{escaped}"\n\t}}\n'
            body += '}\n'
            state = home.publish(relative, data=body.encode('utf-8'))
            if state == 'preserved':
                raise Refusal('Steam metadata appeared during registration; existing file preserved; retry')
            result['migrated' if state == 'copied' else 'alreadyPresent'].extend(libraries)
        except FileNotFoundError:
            continue
        except (OSError, ValueError) as error:
            result['failed'].append({'path': relative, 'error': str(error)})
    if libraries and not initialized:
        result['failed'].append({'path': 'Steam', 'error': 'Initialize Linux Steam, close it, then use Settings > Storage > Add Library for each detected path.'})
    result['registered'] = bool(libraries and not result['failed'])
    return finish(home, '.config/wootc/bridge-steam.json', result)


def files(home, host, winuser):
    result = outcome()
    # Walk the source with its authority first; directories and copies are
    # then created without it, as the target user.
    tree = []
    with source_authority():
        for folder in ('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos'):
            source = host / 'Users' / winuser / folder
            if not source.exists() and not source.is_symlink():
                continue
            if source.is_symlink() or not source.is_dir():
                result['failed'].append({'path': str(source), 'error': 'source folder must be a real directory'})
                continue
            def walk_error(error, source=source):
                result['failed'].append({'path': str(source), 'error': str(error)})
            for root, directories, names in os.walk(source, followlinks=False, onerror=walk_error):
                for name in directories[:]:
                    path = Path(root) / name
                    if path.is_symlink():
                        result['failed'].append({'path': str(path), 'error': 'source symlink refused'})
                        directories.remove(name)
                tree.append((Path(folder) / Path(root).relative_to(source), [Path(root) / name for name in names]))
    refused = []
    for relative_dir, paths in tree:
        if any(relative_dir.is_relative_to(parent) for parent in refused):
            continue
        try:
            with home.directory(str(relative_dir)):
                pass
        except (OSError, ValueError) as error:
            result['failed'].append({'path': str(relative_dir), 'error': str(error)})
            refused.append(relative_dir)
            continue
        for path in paths:
            relative = str(relative_dir / path.name)
            item(result, relative, lambda p=path, r=relative: home.publish(r, source=p))
    return finish(home, '.config/wootc/import-files.json', result)


def wsl(home, rootfs, formulae, target):
    result = outcome()
    with source_authority():
        candidates = sorted((rootfs / 'home').glob('*'))
        source = next((path for path in candidates if path.is_dir()), rootfs / 'root')
        if not source.is_dir() or source.is_symlink():
            raise Refusal('no real WSL home directory')
        dotfiles = ('.bashrc', '.bash_profile', '.bash_aliases', '.profile', '.zshrc',
                    '.zprofile', '.zshenv', '.gitconfig', '.gitignore_global', '.vimrc',
                    '.tmux.conf', '.aliases', '.inputrc', '.editorconfig', '.p10k.zsh',
                    '.config/starship.toml', '.curlrc', '.wgetrc', '.digrc')
        copies = [(source / name, name) for name in dotfiles
                  if (source / name).exists() or (source / name).is_symlink()]
        public = sorted((source / '.ssh').glob('*.pub'))
        public += [source / '.ssh' / name for name in ('config', 'known_hosts')
                   if (source / '.ssh' / name).exists() or (source / '.ssh' / name).is_symlink()]
        copies += [(path, '.ssh/' + path.name) for path in public]
    for path, relative in copies:
        item(result, relative, lambda p=path, r=relative: home.publish(r, source=p, mode=0o600))
    brewfile = '.config/wootc/Brewfile'
    body = ('# Generated by wootc-wsl-bridge from your WSL packages.\n'
            '# Rebuild your toolchain with: brew bundle --file=~/.config/wootc/Brewfile\n')
    body += ''.join('brew ' + json.dumps(name) + '\n' for name in sorted(set(formulae)))
    item(result, brewfile, lambda: home.publish(brewfile, data=body.encode('utf-8')))
    if os.environ.get('WOOTC_WSL_BREW_INSTALL') == '1' and not result['failed'] and not result['preserved']:
        try:
            completed = subprocess.run(['brew', 'bundle', '--file=' + str(home.path / brewfile)],
                                       check=False, stdout=sys.stderr, stderr=sys.stderr,
                                       env={**os.environ, 'HOME': str(home.path)})
            if completed.returncode:
                raise Refusal('brew bundle failed; inspect its output before retrying')
        except (OSError, ValueError) as error:
            result['failed'].append({'path': brewfile, 'error': str(error)})
    result.update(found=True, dotfiles=len([name for name in result['migrated'] if name != brewfile]),
                  brewFormulae=len(set(formulae)), brewfile=str(home.path / brewfile),
                  note='Existing Linux files and Brewfile are preserved. Merge preserved collisions manually. Private SSH/GPG keys were not copied.')
    return finish(home, '.config/wootc/wsl-bridge.json', result)


# Destination mode per copyable ~/.ssh file. config and authorized_keys are
# 0600 because OpenSSH refuses a config or authorized_keys others can write,
# and a config can name private hosts; keys and known_hosts are public.
SSH_MODES = {'config': 0o600, 'authorized_keys': 0o600, 'known_hosts': 0o644}
# The only Git settings that describe the person rather than the machine.
GIT_IDENTITY = (('user', 'name'), ('user', 'email'), ('user', 'signingkey'), ('init', 'defaultbranch'))
GIT_WINDOWS_ONLY = {'credential': 'Windows credential store; sign in again on Linux',
                    'core.autocrlf': 'Windows line-ending conversion; Linux uses LF',
                    'core.sshcommand': 'points at a Windows SSH client',
                    'include': 'included config files are not followed',
                    'includeif': 'included config files are not followed'}
WINDOWS_PATH = re.compile(r'^(?:[A-Za-z]:[\\/]|\\\\)')


def git_entries(text):
    """Yield (section, subsection, key, value) using git's own value rules.

    A misread quote or continuation would attribute a key to the wrong
    section, so anything git itself would reject is refused, not guessed.
    """
    lines = text.splitlines()
    section = subsection = None
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        index += 1
        if line.startswith('['):
            header = re.match(r'\[\s*([A-Za-z0-9.-]+)(?:\s+"((?:[^"\\]|\\.)*)")?\s*\]\s*(.*)$', line)
            if not header:
                raise Refusal('unparseable .gitconfig section header')
            name, quoted, line = header.groups()
            section, _, legacy = name.lower().partition('.')
            subsection = re.sub(r'\\(.)', r'\1', quoted) if quoted is not None else (legacy or None)
        if not line or line[0] in '#;':
            continue
        if section is None:
            raise Refusal('.gitconfig key outside a section')
        entry = re.match(r'([A-Za-z][A-Za-z0-9-]*)\s*(=?)(.*)$', line)
        if not entry or (not entry.group(2) and entry.group(3).strip()[:1] not in ('', '#', ';')):
            raise Refusal('unparseable .gitconfig line')
        key, assigned, chars = entry.group(1).lower(), entry.group(2), entry.group(3)
        if not assigned:
            yield section, subsection, key, None
            continue
        # git's parse_value: unquoted whitespace runs collapse into spaces
        # only between characters, #/; start a comment, \ at end continues.
        value, space, quote, position = [], 0, False, 0
        while True:
            if position >= len(chars):
                if quote:
                    raise Refusal('unterminated quote in .gitconfig')
                break
            char = chars[position]
            position += 1
            if char in ' \t' and not quote:
                space += 1 if value else 0
                continue
            if char in '#;' and not quote:
                break
            if space:
                value.append(' ' * space)
            space = 0
            if char == '\\':
                if position >= len(chars):
                    if index >= len(lines):
                        break
                    chars, position, index = lines[index], 0, index + 1
                    continue
                escaped = {'n': '\n', 't': '\t', 'b': '\b', '\\': '\\', '"': '"'}.get(chars[position])
                if escaped is None:
                    raise Refusal('invalid escape in .gitconfig')
                position += 1
                value.append(escaped)
            elif char == '"':
                quote = not quote
            else:
                value.append(char)
        yield section, subsection, key, ''.join(value)


def git_quote(value):
    escaped = (value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
               .replace('\t', '\\t').replace('\b', '\\b'))
    return '"' + escaped + '"' if escaped != escaped.strip() or any(c in escaped for c in '#;') else escaped


def git_identity(raw, result):
    """Return a .gitconfig holding only identity keys; record every key left behind."""
    identity, skipped = {}, {}
    for section, subsection, key, value in git_entries(raw.decode('utf-8-sig')):
        name = '.'.join(part for part in (section, subsection, key) if part is not None)
        if subsection is not None or (section, key) not in GIT_IDENTITY:
            skipped.setdefault(name, GIT_WINDOWS_ONLY.get(section + '.' + key) or GIT_WINDOWS_ONLY.get(section)
                               or 'only the Git identity (user name, email, signing key) and init.defaultBranch are carried')
            continue
        # git uses the last value, so a later unusable one cancels an earlier one.
        identity.pop((section, key), None)
        skipped.pop(name, None)
        if value is None or not value.strip():
            skipped[name] = 'no value'
        elif WINDOWS_PATH.match(value):
            skipped[name] = 'Windows path'
        else:
            identity[(section, key)] = value
    result['notCarried'] += [{'path': '.gitconfig', 'key': name, 'reason': reason}
                             for name, reason in sorted(skipped.items())]
    if not identity:
        return None
    body = ('# Git identity carried over from Windows by wootc. Only these keys were\n'
            '# copied; ~/.config/wootc/bridge-developer.json lists what stayed behind.\n')
    for section in ('user', 'init'):
        keys = [(key, identity[(s, key)]) for s, key in GIT_IDENTITY if s == section and (s, key) in identity]
        if keys:
            body += '[' + section + ']\n'
            body += ''.join('\t' + {'defaultbranch': 'defaultBranch'}.get(key, key) + ' = ' + git_quote(value) + '\n'
                            for key, value in keys)
    return body.encode('utf-8')


def developer(home, host, winuser):
    """Public SSH material and Git identity; private keys are refused and listed."""
    source = host / 'Users' / winuser
    result = outcome()
    result.update(leftOnWindows=[], notCarried=[])
    copies, git_raw = [], None
    with source_authority():
        if not source.is_dir() or source.is_symlink():
            raise Refusal('missing or symlinked Windows profile')
        ssh = source / '.ssh'
        entries = []
        if ssh.is_symlink() or (ssh.exists() and not ssh.is_dir()):
            result['failed'].append({'path': '.ssh', 'error': 'source .ssh must be a real directory'})
        elif ssh.is_dir():
            entries = sorted(ssh.iterdir())
        names = {path.name for path in entries}
        for path in entries:
            relative = '.ssh/' + path.name
            wanted = path.name in SSH_MODES or path.name.endswith('.pub')
            if path.is_dir() and not path.is_symlink():
                result['notCarried'].append({'path': relative, 'reason': 'subdirectories are not copied'})
                continue
            # Name rules first: a private key is never opened just to classify it.
            if path.name + '.pub' in names:
                reason = 'private key: a matching .pub file exists'
            elif path.name.startswith('id_') and '.' not in path.name:
                reason = 'private key: id_* file without an extension'
            elif path.suffix.lower() == '.ppk':
                reason = 'private key: PuTTY key file'
            else:
                try:
                    with source_file(path) as stream:
                        head = stream.readline(4096)
                except (OSError, ValueError) as error:
                    if wanted:
                        result['failed'].append({'path': relative, 'error': str(error)})
                    else:
                        result['notCarried'].append({'path': relative, 'reason': 'not a regular file'})
                    continue
                reason = 'private key: first line is a PRIVATE KEY header' if b'PRIVATE KEY' in head else None
            if reason:
                result['leftOnWindows'].append({'path': relative, 'reason': reason})
            elif wanted:
                copies.append((path, relative, SSH_MODES.get(path.name, 0o644)))
            else:
                result['notCarried'].append({'path': relative, 'reason':
                                             'only SSH public keys, config, known_hosts and authorized_keys are copied'})
        gitconfig = source / '.gitconfig'
        if gitconfig.exists() or gitconfig.is_symlink():
            try:
                git_raw = source_bytes(gitconfig)
            except (OSError, ValueError) as error:
                result['failed'].append({'path': '.gitconfig', 'error': str(error)})
    for path, relative, mode in copies:
        item(result, relative, lambda p=path, r=relative, m=mode: home.publish(r, source=p, mode=m))
    if git_raw is not None:
        try:
            body = git_identity(git_raw, result)
            # git also reads ~/.config/git/config; a native one is the user's
            # identity, and a new ~/.gitconfig would silently override it.
            if body is not None and home.read('.config/git/config') is not None:
                result['preserved'].append('.config/git/config')
            elif body is not None:
                item(result, '.gitconfig', lambda: home.publish('.gitconfig', data=body))
        except (OSError, ValueError) as error:
            result['failed'].append({'path': '.gitconfig', 'error': str(error)})
    result['note'] = ('Private SSH keys and Windows-only Git settings stay on Windows. '
                      'Existing Linux files are preserved, never overwritten.')
    return finish(home, '.config/wootc/bridge-developer.json', result)


@contextlib.contextmanager
def target_home(account):
    original_uid, original_gid = os.geteuid(), os.getegid()
    home = None
    try:
        if original_uid == 0:
            os.setegid(account.pw_gid)
            os.seteuid(account.pw_uid)
        home = Home(account)
        yield home
    finally:
        if home is not None:
            home.close()
        if original_uid == 0:
            os.seteuid(original_uid)
            os.setegid(original_gid)


def external(winuser, target, categories):
    account = pwd.getpwnam(target)
    # This distinct lock spans helpers without nesting their per-consumer lock.
    with contextlib.ExitStack() as locks:
        with target_home(account) as home:
            locks.enter_context(home.lock('.external-import.lock'))
        return external_categories(account, winuser, target, categories)


def external_categories(account, winuser, target, categories):
    """Category success requires a fresh item result, never just exit zero."""
    result = {'status': 'partial', 'imported': [], 'unchanged': [], 'failed': [],
              'partial': [], 'categories': {}}
    helpers = {'apps': 'wootc-detect-apps', 'browsers': 'wootc-import-browser',
               'steam': 'wootc-steam-bridge', 'office': 'wootc-office-bridge',
               'wsl': 'wootc-wsl-bridge'}
    records = {'apps': 'bridge-apps.json', 'browsers': 'bridge-browser.json',
               'steam': 'bridge-steam.json', 'office': 'bridge-office.json',
               'wsl': 'wsl-bridge.json', 'files': 'import-files.json'}
    with target_home(account) as home:
        home.record('.config/wootc/import-result.json', result)
    host = Path(os.environ.get('WOOTC_HOST', '/run/wootc/host'))
    if not source_mounted(host):
        result['status'] = 'failed'
        result['failed'] = list(categories)
        result['categories'] = {category: {'status': 'failed', 'migrated': [],
                                'note': 'Windows source is not mounted.'} for category in categories}
        with target_home(account) as home:
            home.record('.config/wootc/import-result.json', result)
        return result
    for category in categories:
        if category == 'look':
            record = {'status': 'partial', 'migrated': [],
                      'note': 'Desktop appearance has not been applied. Review it from the migration dashboard while the source is available.'}
            rc = 0
        else:
            try:
                # Clear stale success before starting even a legacy helper.
                with target_home(account) as home:
                    home.record('.config/wootc/' + records[category],
                                {'status': 'partial', 'migrated': [], 'imported': [],
                                 'note': 'Requested external import; no completed result yet.'})
                if category == 'files':
                    with target_home(account) as home:
                        with home.lock():
                            copied = files(home, host, winuser)
                    rc = 1 if copied['status'] == 'failed' else 0
                else:
                    completed = subprocess.run([helpers[category], winuser, target],
                                               capture_output=True, text=True, check=False)
                    rc = completed.returncode
                    if completed.stderr:
                        print(completed.stderr, file=sys.stderr, end='')
                with target_home(account) as home:
                    raw = home.read('.config/wootc/' + records[category])
                record = json.loads(raw) if raw is not None else {}
                if not isinstance(record, dict):
                    raise Refusal('import helper returned an invalid result')
                # Our structured helpers also return their current result on
                # stdout; the ledger remains authoritative for legacy helpers.
                if category == 'browsers':
                    record['migrated'] = record.get('imported', []) if record.get('state') == 'native' else []
                    if record.get('state') == 'failed':
                        record['status'] = 'failed'
                    elif record.get('state') == 'unchanged':
                        record['status'] = 'unchanged'
                if rc != 0:
                    record['status'] = 'failed'
                    record.setdefault('note', 'The helper failed; completed items may remain. Review item errors before retrying.')
                elif record.get('status') == 'success' and not record.get('migrated') and not record.get('alreadyPresent'):
                    record['status'] = 'partial'
                    record['note'] = 'The helper returned no item-level completion evidence.'
            except (OSError, ValueError, KeyError) as error:
                rc = 1
                record = {'status': 'failed', 'migrated': [], 'failed': [{'error': str(error)}]}
        state = record.get('status', 'partial')
        result['categories'][category] = record
        if rc or state == 'failed':
            result['failed'].append(category)
        elif state == 'success':
            result['imported' if record.get('migrated') else 'unchanged'].append(category)
        elif state == 'unchanged':
            result['unchanged'].append(category)
        else:
            result['partial'].append(category)
    result['status'] = 'failed' if result['failed'] else 'partial' if result['partial'] else 'success'
    with target_home(account) as home:
        home.record('.config/wootc/import-result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('category', choices=('office', 'steam', 'files', 'wsl', 'developer', 'external'))
    parser.add_argument('winuser', nargs='?')
    parser.add_argument('target', nargs='?')
    parser.add_argument('categories', nargs='*')
    parser.add_argument('--rootfs', type=Path)
    parser.add_argument('--brew', nargs='*', default=[])
    args = parser.parse_args()
    host = Path(os.environ.get('WOOTC_HOST', '/run/wootc/host'))
    if args.category != 'steam' and (not args.winuser or args.winuser in ('.', '..') or '/' in args.winuser):
        raise Refusal('select one Windows profile name')
    if args.category == 'external':
        result = external(args.winuser, args.target, args.categories)
        print(json.dumps(result))
        return 0 if result['status'] == 'success' else 1
    if args.category == 'steam':
        if args.target:
            accounts = [pwd.getpwnam(args.target)]
        else:
            accounts = [account for account in pwd.getpwall() if account.pw_uid >= 1000 and Path(account.pw_dir).is_dir() and account.pw_shell not in ('/usr/sbin/nologin', '/bin/false')]
    else:
        accounts = [pwd.getpwnam(args.target or args.winuser)]
    results = []
    for account in accounts:
        # User-home mutations never run with root authority, including chown.
        original_uid, original_gid = os.geteuid(), os.getegid()
        home = None
        try:
            if original_uid == 0:
                os.setegid(account.pw_gid)
                os.seteuid(account.pw_uid)
            home = Home(account)
            with home.lock():
                record = '.config/wootc/' + {'office': 'bridge-office.json',
                         'steam': 'bridge-steam.json', 'files': 'import-files.json',
                         'wsl': 'wsl-bridge.json', 'developer': 'bridge-developer.json'}[args.category]
                home.record(record, {**outcome(), 'status': 'partial',
                                     'note': 'Import started; no completed result yet.'})
                try:
                    if args.category != 'wsl' and not source_mounted(host):
                        raise Refusal('Windows source is not mounted')
                    if args.category == 'office':
                        result = office(home, host, args.winuser)
                    elif args.category == 'developer':
                        result = developer(home, host, args.winuser)
                    elif args.category == 'files':
                        result = files(home, host, args.winuser)
                    elif args.category == 'wsl':
                        if args.rootfs is None:
                            result = outcome()
                            result.update(found=False, note='No WSL source was selected or found; no files imported.')
                            finish(home, record, result)
                        else:
                            result = wsl(home, args.rootfs, args.brew, account.pw_name)
                    else:
                        result = steam(home, steam_libraries(host))
                except (OSError, ValueError) as error:
                    result = outcome()
                    result['failed'].append({'error': str(error)})
                    finish(home, record, result)
            results.append(result)
        finally:
            if home is not None:
                home.close()
            if original_uid == 0:
                os.seteuid(original_uid)
                os.setegid(original_gid)
    if len(results) == 1:
        result = results[0]
    else:
        states = {record['status'] for record in results}
        state = next((value for value in ('failed', 'partial', 'success') if value in states), 'unchanged')
        result = {'status': state, 'users': results}
    print(json.dumps(result))
    return 1 if result['status'] == 'failed' else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as error:
        result = outcome()
        result['status'] = 'failed'
        result['failed'].append({'error': str(error)})
        print(json.dumps(result))
        sys.exit(1)
