"""Resolve measured mount/block relationships; labels never establish ancestry."""
import base64
import json
import re


class Mismatch(ValueError):
    """Successfully observed backing is outside the native target."""


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON field')
        result[key] = value
    return result


def decode(value):
    try:
        return json.loads(text(value), object_pairs_hook=unique_object)
    except RecursionError as exc:
        raise ValueError('Observation nesting exceeds bound') from exc


def text(value):
    if len(value) > 2_000_000:
        raise ValueError('Observation exceeds bound')
    return base64.b64decode(value, validate=True).decode('utf-8')


class Ancestry:
    def __init__(self, fields, target):
        self.nodes, self.aliases, self.parents = {}, {}, {}
        def blocks(rows, parent=None, depth=0):
            if not isinstance(rows, list):
                raise ValueError('Invalid block graph')
            if depth > 64:
                raise ValueError('Block graph nesting exceeds bound')
            for row in rows:
                major = row['maj:min']
                if not re.fullmatch(r'[0-9]+:[0-9]+', major):
                    raise ValueError('Invalid block identity')
                core = {key: row[key] for key in ('name', 'kname', 'type')}
                core['uuid'] = row.get('uuid')
                if any(not isinstance(core[key], str) or not core[key] for key in ('name', 'kname', 'type')):
                    raise ValueError('Invalid block attributes')
                if major in self.nodes and self.nodes[major] != core:
                    raise ValueError('Conflicting block identity')
                if major not in self.nodes and len(self.nodes) >= 1024:
                    raise ValueError('Block graph exceeds bound')
                self.nodes[major] = core
                for alias in (core['name'], core['kname']):
                    if not isinstance(alias, str) or not alias.startswith('/dev/'):
                        raise ValueError('Invalid measured block name')
                    if alias in self.aliases and self.aliases[alias] != major:
                        raise ValueError('Ambiguous measured block name')
                    self.aliases[alias] = major
                self.parents.setdefault(major, set())
                if parent:
                    self.parents[major].add(parent)
                if row.get('children'):
                    blocks(row['children'], major, depth+1)
        blocks(decode(fields['BLOCKS'])['blockdevices'])
        self.target = self.aliases.get(target)
        if not self.target or self.nodes[self.target]['type'] != 'disk':
            raise ValueError('Expected whole target is not measured')
        self.mounts = {}
        def mounts(rows, depth=0):
            if not isinstance(rows, list):
                raise ValueError('Invalid mount observations')
            if depth > 64:
                raise ValueError('Mount graph nesting exceeds bound')
            for row in rows:
                if not isinstance(row, dict):
                    raise ValueError('Invalid mount row')
                if any(not isinstance(row.get(key), str) or not row[key]
                       for key in ('target', 'source', 'fstype', 'maj:min', 'options')):
                    raise ValueError('Incomplete mount row')
                path = row['target']
                if not re.fullmatch(r'[0-9]+:[0-9]+', row['maj:min']):
                    raise ValueError('Invalid measured mount identity')
                if not isinstance(path, str) or not path.startswith('/') or path in self.mounts:
                    raise ValueError('Ambiguous mount target')
                if len(self.mounts) >= 4096:
                    raise ValueError('Mount observations exceed bound')
                self.mounts[path] = row
                if row.get('children'):
                    mounts(row['children'], depth+1)
        mounts(decode(fields['MOUNTS'])['filesystems'])
        self.loops = {}
        for row in decode(fields['LOOPS'])['loopdevices']:
            major = row['maj:min']
            if major in self.loops or self.aliases.get(row['name']) != major:
                raise ValueError('Ambiguous loop relationship')
            if len(self.loops) >= 512:
                raise ValueError('Loop observations exceed bound')
            self.loops[major] = row['back-file']
        self.paths = {}
        for line in text(fields['PATHS']).splitlines():
            pair = line.split('\t')
            if len(pair) != 2 or pair[0] in self.paths or len(self.paths) >= 512:
                raise ValueError('Invalid or ambiguous resolved path observations')
            self.paths[pair[0]] = pair[1]
        self.btrfs = {}
        for line in text(fields['BTRFS']).splitlines():
            values = line.split('\t')
            if len(values) != 3 or values[0] in self.btrfs or len(self.btrfs) >= 128:
                raise ValueError('Invalid Btrfs membership observations')
            if not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', values[0]) or values[1] not in {'0', '1'}:
                raise ValueError('Invalid registered Btrfs identity')
            self.btrfs[values[0]] = (values[1], values[2].split(','))

    def mount_for(self, path):
        path = self.paths.get(path)
        if not isinstance(path, str) or not path.startswith('/') or '..' in path.split('/'):
            raise ValueError('Invalid observed projection path')
        candidates = [target for target in self.mounts if target == '/' or path == target or path.startswith(target+'/')]
        if not candidates:
            raise ValueError('Projection mount unavailable')
        return self.mounts[max(candidates, key=len)]

    def disk_ancestors(self, major, projected=False, seen=None):
        seen = set() if seen is None else set(seen)
        if major in seen or major not in self.nodes:
            raise ValueError('Missing or cyclic block relationship')
        seen.add(major)
        node = self.nodes[major]
        if node['type'] not in {'disk', 'part', 'loop', 'crypt', 'lvm', 'dm', 'mpath', 'md', 'raid0', 'raid1', 'raid4', 'raid5', 'raid6', 'raid10'}:
            raise ValueError('Unsupported block layer')
        if node['type'] == 'loop':
            if not projected:
                raise Mismatch('Native root/data is loop-backed')
            backing = self.loops.get(major)
            if not isinstance(backing, str) or not backing.startswith('/') or backing.endswith(' (deleted)'):
                raise ValueError('Projected image backing unavailable')
            return self.mount_ancestors(self.mount_for(backing), False, seen)
        parents = self.parents[major]
        if node['type'] == 'disk':
            if parents:
                raise ValueError('Whole disk has unexpected parents')
            return {major}
        if not parents:
            raise ValueError('Block parents unavailable')
        result = set()
        for parent in parents:
            result.update(self.disk_ancestors(parent, projected, seen))
        return result

    def mount_ancestors(self, row, projected=False, seen=None):
        major, source = row['maj:min'], row['source']
        base = source.split('[', 1)[0]
        if row['fstype'] == 'btrfs':
            physical = self.aliases.get(base)
            fsid = row.get('uuid')
            if not physical or not fsid or self.nodes[physical]['uuid'] != fsid:
                raise ValueError('Btrfs source and mounted filesystem identity disagree')
            valid, members = self.btrfs.get(fsid, (None, []))
            if valid != '1' or not members or physical not in members or len(members) != len(set(members)):
                raise ValueError('Complete current Btrfs membership unavailable')
            ancestors = set()
            for member in members:
                ancestors.update(self.disk_ancestors(member, False, seen))
            return ancestors
        if self.aliases.get(base) != major:
            raise ValueError('Mount source and block identity disagree')
        return self.disk_ancestors(major, projected, seen)

    def require_target(self, ancestors):
        if ancestors != {self.target}:
            raise Mismatch('Observed backing is outside expected whole target')

    def verify_root(self):
        row = self.mounts.get('/')
        if not row:
            raise ValueError('Current root mount unavailable')
        if row['fstype'] != 'overlay':
            self.require_target(self.mount_ancestors(row, row['fstype'] == 'erofs'))
            return
        paths, layers = [], {}
        for option in row['options'].split(','):
            key, sep, value = option.partition('=')
            raw_key = key
            key = key.rstrip('+')
            if key in {'lowerdir', 'datadir', 'upperdir', 'workdir'}:
                if raw_key not in {key, key+'+'} or (raw_key.endswith('+') and key not in {'lowerdir', 'datadir'}):
                    raise ValueError('Invalid projection layer option')
                if not sep or not value or key in layers or '\\' in value or any(c.isspace() for c in value):
                    raise ValueError('Invalid or duplicate active projection layer')
                layers[key] = value
        if 'lowerdir' not in layers or ('upperdir' in layers) != ('workdir' in layers):
            raise ValueError('Complete active root content layers unavailable')
        for key, value in layers.items():
            if key == 'lowerdir' and '::' in value:
                if value.count('::') != 1:
                    raise ValueError('Ambiguous data-only lower layers')
                lower, data = value.split('::')
                if not lower or not data:
                    raise ValueError('Missing metadata or data lower layer')
                parts = lower.split(':')+data.split(':')
            else:
                parts = value.split(':')
            if any(not path for path in parts) or (key in {'upperdir', 'workdir'} and len(parts) != 1):
                raise ValueError('Empty or invalid active layer path')
            paths.extend(parts)
        if len(paths) > 32:
            raise ValueError('Current root projection is not observed')
        if 'upperdir' in layers:
            upper = self.mount_for(layers['upperdir'])
            work = self.mount_for(layers['workdir'])
            if upper['maj:min'] != work['maj:min'] or upper['source'] != work['source']:
                raise ValueError('Upper and work layers do not share the observed filesystem')
        for path in paths:
            backing = self.mount_for(path)
            if backing is row:
                raise ValueError('Projection cannot resolve through itself')
            self.require_target(self.mount_ancestors(backing, backing['fstype'] == 'erofs'))

    def verify_data(self, source, major, target):
        row = self.mounts.get(target)
        if not row or row['source'] != source or row['maj:min'] != major:
            raise ValueError('Exported source does not match current mount row')
        self.require_target(self.mount_ancestors(row))
