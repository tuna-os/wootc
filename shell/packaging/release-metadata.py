#!/usr/bin/env python3
"""Derive native engine stamps from one release's downloaded key and shim."""
import argparse
import importlib.util
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location('shim_authorities', ROOT / 'packaging/shim-authorities.py')
shim = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(shim)


def metadata(directory, tag, source_commit, release_commit, repository):
    if not re.fullmatch(r'[0-9A-Za-z][0-9A-Za-z._-]{0,99}', tag):
        raise ValueError('invalid release tag')
    if not re.fullmatch(r'[0-9a-f]{40}', source_commit) or source_commit != release_commit:
        raise ValueError('dispatch this workflow at the exact release commit')
    if not re.fullmatch(r'[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('invalid artifact repository')
    key = ''.join((directory / 'artifact-public-key.hex').read_text().split())
    if not re.fullmatch(r'[0-9a-fA-F]{64}', key):
        raise ValueError('release artifact-public-key.hex is not 32-byte hex')
    authorities = shim.authorities(directory / 'shimx64.efi')
    if '2023' not in authorities:
        raise ValueError('the released shim is not signed by Microsoft UEFI CA 2023')
    stamp = ','.join(authorities)
    flags = (f'-X main.artifactPublicKey={key} -X main.releaseTag={tag} '
             f'-X main.shimAuthorities={stamp} '
             f'-X main.releasesBaseURL=https://github.com/{repository}/releases/')
    return {'production': 'true', 'tag': tag, 'artifact_public_key': key,
            'shim_authorities': stamp, 'engine_ldflags': flags}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--release-commit', required=True)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--github-output', type=Path)
    args = parser.parse_args()
    try:
        result = metadata(args.directory, args.tag, args.source_commit, args.release_commit, args.repository)
        if args.github_output:
            with args.github_output.open('a') as output:
                for key, value in result.items():
                    output.write(f'{key}={value}\n')
        else:
            print(json.dumps(result))
    except (ValueError, OSError, shim.PEError) as error:
        parser.exit(1, f'native release: {error}\n')


if __name__ == '__main__':
    main()
