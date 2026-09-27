"""Read-only offline OSTree/BLS selection; unsupported layouts refuse.

This is not current guest boot identity. The owned builder retains mount/block
observations separately and uses this selection before observer installation.
"""
import configparser
import os
import stat
from pathlib import Path
import re

CHECKSUM = r'[0-9a-f]{64}'


def protected_boot_link(link, sysroot, directory):
    # Relative OSTree boot links are supported; absolute targets and a chain
    # escaping the selected offline sysroot refuse instead of using host paths.
    current = Path(link)
    seen = set()
    for _ in range(32):
        current.relative_to(sysroot)
        parts = current.relative_to(sysroot).parts
        cursor = sysroot
        for index, part in enumerate(parts):
            directory(cursor)
            cursor = cursor / part
            facts = cursor.lstat()
            if stat.S_ISLNK(facts.st_mode):
                if facts.st_uid != 0 or cursor in seen:
                    raise ValueError('unprotected or cyclic installed boot link')
                seen.add(cursor)
                target = os.readlink(cursor)
                if len(target) > 4096 or any(char.isspace() for char in target) or '\\' in target or target.startswith('/'):
                    raise ValueError('absolute offline boot link unsupported')
                current = Path(os.path.normpath(str(cursor.parent / target / Path(*parts[index+1:]))))
                break
        else:
            directory(current)
            return current
    raise ValueError('installed boot link depth exceeds bound')


def select_installed_deployment(sysroot, expected_image, protected_read, directory):
    sysroot = Path(sysroot)
    directory(sysroot)
    if type(expected_image) is not str or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:' + CHECKSUM, expected_image):
        raise ValueError('installed image expectation is not pinned')
    base = sysroot / 'ostree/deploy'
    directory(base)
    roots = sorted(base.iterdir())
    if not roots or len(roots) > 16:
        raise ValueError('stateroot inventory unavailable')
    candidates = []
    for root in roots:
        directory(root)
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', root.name):
            raise ValueError('stateroot name unsupported')
        deployments = root / 'deploy'
        directory(deployments)
        entries = sorted(deployments.iterdir())
        if len(entries) > 128:
            raise ValueError('deployment inventory exceeds bound')
        for entry in entries:
            if entry.name.endswith('.origin'):
                continue
            if not re.fullmatch(CHECKSUM + r'\.[0-9]+', entry.name):
                raise ValueError('deployment shape unsupported')
            directory(entry)
            # This checks shape only; origin plus installed BLS choose identity.
            protected_read(entry / 'usr/lib/os-release')
            candidates.append((root, entry))
    if len(candidates) != 1:
        raise ValueError('unique installed deployment required')
    root, deployment = candidates[0]
    origin_file = deployment.with_name(deployment.name + '.origin')
    origin = configparser.ConfigParser(interpolation=None, strict=True)
    origin_bytes = protected_read(origin_file)
    origin.read_string(origin_bytes.decode('utf-8'))
    if origin.defaults():
        raise ValueError('default origin authority unsupported')
    ref = origin.get('origin', 'container-image-reference', fallback='')
    # Match the complete pinned reference, never just the digest suffix.
    if ref not in {'ostree-unverified-registry:' + expected_image,
                   'ostree-image-signed:docker://' + expected_image}:
        raise ValueError('installed deployment origin differs from pinned image')
    state_var = root / 'var'
    directory(state_var)
    selections = []
    for relative in ['boot/loader/entries', 'boot/efi/loader/entries']:
        entries = sysroot / relative
        if not entries.exists():
            continue
        directory(entries)
        files = sorted(entries.iterdir())
        if len(files) > 128:
            raise ValueError('installed BLS inventory exceeds bound')
        for file in files:
            if file.suffix != '.conf':
                raise ValueError('installed BLS inventory entry unsupported')
            content = protected_read(file).decode('utf-8')
            options = [line[8:] for line in content.splitlines() if line.startswith('options ')]
            if len(options) != 1:
                raise ValueError('installed BLS options unavailable')
            paths = [part[7:] for part in options[0].split() if part.startswith('ostree=')]
            if len(paths) != 1 or not re.fullmatch(r'/ostree/boot\.[01]/' + re.escape(root.name) + '/' + CHECKSUM + '/[0-9]+', paths[0]):
                raise ValueError('installed BLS deployment selector unsupported')
            link = sysroot / paths[0].lstrip('/')
            # OSTree boot links are expected. Retain the resolved inode and
            # require that the selected real directory is the unique candidate.
            resolved = protected_boot_link(link, sysroot, directory)
            if resolved != deployment.resolve(strict=True):
                raise ValueError('installed BLS selects another deployment')
            directory(resolved)
            if (resolved.stat().st_dev, resolved.stat().st_ino) != (deployment.stat().st_dev, deployment.stat().st_ino):
                raise ValueError('installed BLS deployment inode differs')
            selections.append({'path': str(file), 'options': options[0], 'content': content})
    if len(selections) != 1:
        raise ValueError('unique current installed BLS selector required')
    if protected_read(origin_file) != origin_bytes or protected_read(Path(selections[0]['path'])).decode('utf-8') != selections[0].pop('content'):
        raise ValueError('installed origin/BLS changed during selection')
    return {'deployment': str(deployment), 'stateVar': str(state_var),
            'image': expected_image, 'bls': selections[0], 'configurationOnly': True}
