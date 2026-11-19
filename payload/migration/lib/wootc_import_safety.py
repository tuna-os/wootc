#!/usr/bin/env python3
"""Office, Steam and external-file import: preserve native files, publish complete copies.

All destination operations are relative to an owned, no-symlink directory fd.
Only newly created inodes are chowned. Existing application files are never
replaced; the dictionary's append-only recovery record is the sole exception.
"""
import argparse
import contextlib
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

    def publish(self, relative, source=None, data=None, mode=0o644):
        """Return copied/already-present/preserved. link(2) never clobbers a race."""
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
                return 'already-present' if existing == digest.digest() else 'preserved'
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
    if not source.is_dir() or source.is_symlink():
        raise Refusal('missing or symlinked Windows profile')
    lo = '.config/libreoffice/4/user'
    microsoft = source / 'AppData/Roaming/Microsoft'
    result = outcome()
    words = []
    for path in sorted((microsoft / 'UProof').glob('*')) + sorted((microsoft / 'Spelling').glob('*/default.dic')):
        if path.suffix.lower() != '.dic':
            continue
        try:
            raw = source_bytes(path)
            encoding = 'utf-16' if raw.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
            words.extend(raw.decode(encoding).splitlines())
        except (OSError, ValueError) as error:
            result['failed'].append({'path': str(path), 'error': str(error)})
    pending_raw = home.read('.config/wootc/office-dictionary-pending.json')
    pending = json.loads(pending_raw) if pending_raw is not None else {}
    if not isinstance(pending, dict):
        raise Refusal('invalid dictionary pending receipt; retained for review')
    if words or pending.get('active'):
        destination = lo + '/wordbook/standard.dic'
        item(result, destination, lambda: dictionary(home, destination, words))
    for directory, extensions, destination in (
            (microsoft / 'Templates', {'.dotx', '.dotm', '.xltx', '.potx'}, lo + '/template'),
            (source / 'AppData/Local/Microsoft/Windows/Fonts', {'.ttf', '.otf', '.ttc'}, '.local/share/fonts')):
        for path in sorted(directory.glob('*')):
            if path.suffix.lower() in extensions:
                relative = destination + '/' + path.name
                item(result, relative, lambda p=path, r=relative: home.publish(r, source=p))
    for acl in sorted((microsoft / 'Office').glob('*.acl'))[:1]:
        try:
            strings = re.findall(rb'(?:[\x20-\x7e]\x00){2,40}', source_bytes(acl))
            pairs = [value.decode('utf-16le') for value in strings]
            if len(pairs) >= 2:
                text = '# AutoCorrect entries recovered from MS Office (review/import):\n'
                text += ''.join(f'{pairs[i]}\t=>\t{pairs[i+1]}\n' for i in range(0, len(pairs)-1, 2))
                relative = lo + '/wootc-office-autocorrect.txt'
                item(result, relative, lambda: home.publish(relative, data=text.encode('utf-8')))
        except (OSError, ValueError) as error:
            result['failed'].append({'path': str(acl), 'error': str(error)})
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
    for folder in ('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos'):
        source = host / 'Users' / winuser / folder
        if not source.exists() and not source.is_symlink():
            continue
        if source.is_symlink() or not source.is_dir():
            result['failed'].append({'path': str(source), 'error': 'source folder must be a real directory'})
            continue
        def walk_error(error):
            result['failed'].append({'path': str(source), 'error': str(error)})
        for root, directories, names in os.walk(source, followlinks=False, onerror=walk_error):
            relative_dir = str(Path(folder) / Path(root).relative_to(source))
            try:
                with home.directory(relative_dir):
                    pass
            except (OSError, ValueError) as error:
                result['failed'].append({'path': relative_dir, 'error': str(error)})
                directories[:] = []
                continue
            for name in directories[:]:
                path = Path(root) / name
                if path.is_symlink():
                    result['failed'].append({'path': str(path), 'error': 'source symlink refused'})
                    directories.remove(name)
            for name in names:
                source_file_path = Path(root) / name
                relative = str(Path(relative_dir) / name)
                item(result, relative, lambda p=source_file_path, r=relative: home.publish(r, source=p))
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
    if subprocess.run(['mountpoint', '-q', str(host)], check=False).returncode != 0:
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
    parser.add_argument('category', choices=('office', 'steam', 'files', 'wsl', 'external'))
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
                         'wsl': 'wsl-bridge.json'}[args.category]
                home.record(record, {**outcome(), 'status': 'partial',
                                     'note': 'Import started; no completed result yet.'})
                try:
                    if args.category != 'wsl' and subprocess.run(['mountpoint', '-q', str(host)], check=False).returncode != 0:
                        raise Refusal('Windows source is not mounted')
                    if args.category == 'office':
                        result = office(home, host, args.winuser)
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
