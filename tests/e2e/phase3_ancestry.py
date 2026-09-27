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
    return json.loads(base64.b64decode(value, validate=True), object_pairs_hook=unique_object)


class Ancestry:
    def __init__(self, fields, target):
        self.nodes, self.aliases, self.parents = {}, {}, {}
        def blocks(rows, parent=None):
            if not isinstance(rows, list):
                raise ValueError('Invalid block graph')
            for row in rows:
                major = row['maj:min']
                if not re.fullmatch(r'[0-9]+:[0-9]+', major):
                    raise ValueError('Invalid block identity')
                core = {key: row[key] for key in ('name', 'kname', 'type')}
                if major in self.nodes and self.nodes[major] != core:
                    raise ValueError('Conflicting block identity')
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
                    blocks(row['children'], major)
        blocks(decode(fields['BLOCKS'])['blockdevices'])
        self.target = self.aliases.get(target)
        if not self.target or self.nodes[self.target]['type'] != 'disk':
            raise ValueError('Expected whole target is not measured')
        self.mounts = {}
        def mounts(rows):
            if not isinstance(rows, list):
                raise ValueError('Invalid mount observations')
            for row in rows:
                if not isinstance(row, dict):
                    raise ValueError('Invalid mount row')
                if any(not isinstance(row.get(key), str) or not row[key]
                       for key in ('target', 'source', 'fstype', 'maj:min', 'options')):
                    raise ValueError('Incomplete mount row')
                path = row['target']
                if not isinstance(path, str) or not path.startswith('/') or path in self.mounts:
                    raise ValueError('Ambiguous mount target')
                self.mounts[path] = row
                if row.get('children'):
                    mounts(row['children'])
        mounts(decode(fields['MOUNTS'])['filesystems'])
        self.loops = {}
        for row in decode(fields['LOOPS'])['loopdevices']:
            major = row['maj:min']
            if major in self.loops or self.aliases.get(row['name']) != major:
                raise ValueError('Ambiguous loop relationship')
            self.loops[major] = row['back-file']

    def mount_for(self, path):
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
        paths = []
        for option in row['options'].split(','):
            key, sep, value = option.partition('=')
            if sep and key.rstrip('+') in {'lowerdir', 'datadir', 'upperdir', 'workdir'}:
                paths.extend(path for path in value.split(':') if path)
        if not paths or len(paths) > 32:
            raise ValueError('Current root projection is not observed')
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
