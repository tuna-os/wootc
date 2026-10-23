"""Resolve measured mount/block relationships; labels never establish ancestry."""
import base64
import json
import re


class Mismatch(ValueError):
    """Successfully observed backing is outside the native target."""


# Targets whose backing the native checks depend on. More than one mount on
# any of these is refused outright, before any lookup: which row is on top is
# not something findmnt's tree states, and guessing would let a lower mount
# speak for the one actually serving the path. Stacking anywhere else (for
# example the systemd autofs automount under the real binfmt_misc at
# /proc/sys/fs/binfmt_misc) is tolerated, but every lookup that lands on a
# stacked target still refuses; see Ancestry.mount.
STRICT_MOUNT_TARGETS = frozenset({'/', '/sysroot', '/boot', '/boot/efi', '/etc', '/usr',
                                  '/var', '/home', '/var/home'})


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


def plain_path(value):
    return (isinstance(value, str) and value.startswith('/') and '..' not in value.split('/')
            and not any(c.isspace() or c == '\\' for c in value))



def root_probe(raw, boot_id):
    """Boot-time root observations made from init's context (wootc-go-native).

    The confined guest agent cannot search /sysroot/ostree, and a composefs
    metadata image is mounted detached, so these are the only observations of
    the root's layer paths and its ostree deployment. The snapshot prefixes
    the export with its observed owner and mode (FILE). Only root writes
    /run; the export must name the observed boot and describe the live root
    mount, and every path it reports is checked against the agent's own
    mount observations (verify_composefs_metadata), so it can add only what
    the agent cannot see, never contradict what it does. systemd's record
    of the unit run (/run/systemd/units/invocation:*) is not a usable
    witness: the confined agent cannot read it (run 39886118219 observed an
    empty UNIT for an export the unit had written). ROOT_INVOCATION stays
    as the probe's proof that it ran under a systemd unit at all.
    Anything else, or any mismatch, is refused.
    """
    if not raw:
        return None
    lines = raw.split('\n')
    if len(lines) < 5 or len(lines) > 64:
        raise ValueError('Invalid root probe')
    if lines[0] != 'FILE=0:0:644':
        raise ValueError('Root probe export is not a root-owned 0644 file')
    if lines[1] != 'ROOT_SCHEMA=1':
        raise ValueError('Invalid root probe')
    if not boot_id or lines[2] != 'ROOT_BOOT_ID='+boot_id:
        raise ValueError('Root probe is not from the observed boot')
    if not re.fullmatch(r'ROOT_INVOCATION=[0-9a-f]{32}', lines[3]):
        raise ValueError('Root probe was not written by a systemd unit run')
    if not lines[4].startswith('ROOT_OPTIONS=') or not lines[4][len('ROOT_OPTIONS='):]:
        raise ValueError('Root probe has no root options')
    probe = {'options': lines[4][len('ROOT_OPTIONS='):], 'layers': {}, 'deploy': None, 'image': None}
    for line in lines[5:]:
        key, sep, value = line.partition('=')
        values = value.split('\t')
        if key == 'LAYER' and sep and len(values) == 3 and values[2] in {'empty', 'populated'}:
            if values[0] in probe['layers'] or not plain_path(values[0]) or not plain_path(values[1]):
                raise ValueError('Invalid or duplicate root probe layer')
            probe['layers'][values[0]] = (values[1], values[2])
        elif key == 'DEPLOY' and sep and len(values) == 2 and probe['deploy'] is None:
            if not plain_path(values[0]) or not plain_path(values[1]):
                raise ValueError('Invalid root probe deployment')
            probe['deploy'] = tuple(values)
        elif key == 'IMAGE' and sep and len(values) == 2 and probe['image'] is None:
            if not plain_path(values[0]) or not re.fullmatch(r'[0-9]+:[0-9]+', values[1]):
                raise ValueError('Invalid root probe image')
            probe['image'] = tuple(values)
        else:
            raise ValueError('Invalid or duplicate root probe observation')
    return probe


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
        self.mounts, self.stacked, count = {}, set(), 0
        def mounts(rows, depth=0):
            nonlocal count
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
                if not isinstance(path, str) or not path.startswith('/'):
                    raise ValueError('Invalid mount target')
                if count >= 4096:
                    raise ValueError('Mount observations exceed bound')
                count += 1
                if path in self.mounts or path in self.stacked:
                    if path in STRICT_MOUNT_TARGETS:
                        raise ValueError('Ambiguous mount target')
                    self.mounts.pop(path, None)
                    self.stacked.add(path)
                else:
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
        self.cmdline = fields.get('CMDLINE')
        self.probe = root_probe(text(fields.get('ROOT', '')), fields.get('BOOT_ID'))
        if self.probe and (not self.mounts.get('/') or self.mounts['/']['options'] != self.probe['options']):
            raise ValueError('Root probe describes another root mount')

    def mount(self, target):
        """The one mount row on target; None if unmounted, refused if stacked."""
        if target in self.stacked:
            raise ValueError('Ambiguous mount target')
        return self.mounts.get(target)

    def resolve(self, path):
        """The observed canonical path. The agent's own '-' (it could not
        resolve the path) may be filled in only by the boot-time probe's
        observation of the same path; two observations must agree."""
        measured = self.paths.get(path)
        probed = (self.probe['layers'].get(path) or (None,))[0] if self.probe else None
        if measured == '-':
            measured = None
        if measured is not None and probed is not None and measured != probed:
            raise ValueError('Resolved path observations disagree')
        resolved = measured if measured is not None else probed
        if not isinstance(resolved, str) or not resolved.startswith('/') or '..' in resolved.split('/'):
            raise ValueError('Invalid observed projection path')
        return resolved

    def mount_for(self, path):
        return self.mount_containing(self.resolve(path))

    def mount_containing(self, path):
        # Stacked targets stay candidates: if one is the deepest match, the
        # path resolves there and must refuse, not fall back to a parent mount.
        candidates = [target for target in (*self.mounts, *self.stacked)
                      if target == '/' or path == target or path.startswith(target+'/')]
        if not candidates:
            raise ValueError('Projection mount unavailable')
        return self.mount(max(candidates, key=len))

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

    def block_backed(self, row):
        return row['fstype'] in {'btrfs', 'erofs'} or row['source'].split('[', 1)[0] in self.aliases

    def verify_composefs_metadata(self, path, backing):
        """A composefs metadata layer whose erofs mount was detached.

        Nothing in the kernel names a detached file-backed erofs mount's
        backing file (its sysfs node is only the anonymous device), so the
        layer is accepted only on this measured chain: the boot command
        line's ostree= deployment, resolved on /sysroot; the kernel's /etc
        bind row naming that same deployment; and that deployment's
        .ostree.cfs as a regular file whose device is the /sysroot
        filesystem, which must trace to the target alone.

        ASSUMPTION (ostree-prepare-root): the initramfs mounts the composefs
        image <deployment>/.ostree.cfs of the same deployment whose /etc it
        binds. That is ostree's contract, not something observed here.
        """
        probe = self.probe
        if not probe or not probe['deploy'] or not probe['image']:
            raise ValueError('Detached composefs metadata layer has no observed image')
        resolved, state = probe['layers'].get(path, (None, None))
        if resolved != self.resolve(path) or state != 'empty' or backing['target'] == resolved:
            raise ValueError('Composefs metadata layer is not a detached mount point')
        karg, deploy = probe['deploy']
        kargs = [token[len('ostree='):] for token in (self.cmdline or '').split() if token.startswith('ostree=')]
        if kargs != [karg]:
            raise ValueError('Root probe deployment is not this boot')
        sysroot = self.mount('/sysroot')
        if not sysroot or not deploy.startswith('/sysroot/') or self.mount_containing(deploy) is not sysroot:
            raise ValueError('Deployment is not on the observed physical root')
        base, _, subpath = sysroot['source'].partition('[')
        expected = base+'['+subpath.rstrip(']')+deploy[len('/sysroot'):]+'/etc]'
        etc = self.mount('/etc')
        if not etc or etc['source'] != expected or etc['maj:min'] != sysroot['maj:min']:
            raise ValueError('Booted /etc is not the observed deployment')
        image, device = probe['image']
        if image != deploy+'/.ostree.cfs' or self.mount_containing(image) is not sysroot or device != sysroot['maj:min']:
            raise ValueError('Composefs image is not on the observed physical root')
        self.require_target(self.mount_ancestors(sysroot))

    def require_target(self, ancestors):
        if ancestors != {self.target}:
            raise Mismatch('Observed backing is outside expected whole target')

    def verify_root(self):
        row = self.mount('/')
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
        metadata, data_only = set(), 'datadir' in layers
        for key, value in layers.items():
            if key == 'lowerdir' and '::' in value:
                if value.count('::') != 1:
                    raise ValueError('Ambiguous data-only lower layers')
                lower, data = value.split('::')
                if not lower or not data:
                    raise ValueError('Missing metadata or data lower layer')
                parts = lower.split(':')+data.split(':')
                metadata.update(lower.split(':'))
                data_only = True
            else:
                parts = value.split(':')
                if key == 'lowerdir':
                    metadata.update(parts)
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
            if data_only and path in metadata and not self.block_backed(backing):
                self.verify_composefs_metadata(path, backing)
                continue
            self.require_target(self.mount_ancestors(backing, backing['fstype'] == 'erofs'))

    def verify_data(self, source, major, target):
        row = self.mount(target)
        if not row or row['source'] != source or row['maj:min'] != major:
            raise ValueError('Exported source does not match current mount row')
        self.require_target(self.mount_ancestors(row))
