#!/usr/bin/env python3
"""Fail when wootc's image catalog disagrees with bootc-migrate's authority."""
import argparse
import json
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen

CANONICAL_SOURCE = 'https://raw.githubusercontent.com/tuna-os/bootc-migrate/main/catalog/sources.json'
MAX_SOURCE_BYTES = 1024 * 1024


def catalog_id(name):
    value = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')
    return re.sub(r'-stable$', '', value)


def canonical_images(source):
    if source.get('version') != 1:
        raise ValueError('bootc-migrate catalog has an unsupported source version')

    images = source.get('images')
    if not isinstance(images, list) or not images:
        raise ValueError('bootc-migrate catalog has no images')

    candidates = []
    seen_refs = set()
    for image in images:
        candidates.append(image)
        ref = image.get('image')
        if ref:
            seen_refs.add(ref)

    families = source.get('families', [])
    if not isinstance(families, list):
        raise ValueError('bootc-migrate catalog families must be a list')
    for family in families:
        try:
            name = family['name']
            repository = family['repository']
            backend = family['backend']
            desktops = family['desktops']
            suffixes = family['suffixes']
        except (KeyError, TypeError) as exc:
            raise ValueError(f'invalid bootc-migrate catalog family: missing {exc}') from exc
        for desktop in desktops:
            for suffix in suffixes:
                tag = desktop + suffix
                ref = f'{repository}:{tag}'
                if ref in seen_refs:
                    continue
                seen_refs.add(ref)
                candidate = {
                    'name': f'{name} {tag}',
                    'image': ref,
                    'backend': backend,
                }
                if 'bootloader' in family:
                    candidate['bootloader'] = family['bootloader']
                candidates.append(candidate)

    result = {}
    for image in candidates:
        try:
            key = catalog_id(image['name'])
            ref = image['image']
            backend = image['backend']
        except (KeyError, TypeError) as exc:
            raise ValueError(f'invalid bootc-migrate catalog image: missing {exc}') from exc
        if not key or backend not in ('ostree', 'composefs'):
            raise ValueError(f'invalid bootc-migrate catalog image {image!r}')
        if not ref:
            if image.get('published') is False:
                continue
            raise ValueError(f'invalid bootc-migrate catalog image {image!r}')
        if key in result:
            raise ValueError(f'duplicate bootc-migrate catalog identity {key!r}')
        result[key] = image
    return result


def compare_catalogs(wootc_catalog, source):
    if not isinstance(wootc_catalog, list) or not wootc_catalog:
        raise ValueError('wootc catalog has no images')

    authority = canonical_images(source)
    errors = []
    matched = 0
    for image in wootc_catalog:
        if not isinstance(image, dict) or not isinstance(image.get('id'), str):
            raise ValueError(f'invalid wootc catalog image {image!r}')
        expected = authority.get(image['id'])
        if expected is None:
            continue
        matched += 1
        if image.get('imageRef') != expected['image']:
            errors.append(
                f"{image['id']}: imageRef is {image.get('imageRef')!r}; "
                f"bootc-migrate requires {expected['image']!r}"
            )
        expected_composefs = expected['backend'] == 'composefs'
        if image.get('composeFs') is not expected_composefs:
            errors.append(
                f"{image['id']}: composeFs is {image.get('composeFs')!r}; "
                f"bootc-migrate backend {expected['backend']!r} requires {expected_composefs!r}"
            )
        if 'bootloader' in expected and image.get('bootloader') != expected['bootloader']:
            errors.append(
                f"{image['id']}: bootloader is {image.get('bootloader')!r}; "
                f"bootc-migrate requires {expected['bootloader']!r}"
            )

    if matched == 0:
        raise ValueError('the catalogs have no shared image identities')
    return matched, errors


def read_json(location):
    if location.startswith('https://'):
        request = Request(location, headers={'User-Agent': 'wootc-catalog-drift-check'})
        with urlopen(request, timeout=30) as response:
            payload = response.read(MAX_SOURCE_BYTES + 1)
        if len(payload) > MAX_SOURCE_BYTES:
            raise ValueError('remote catalog exceeds the 1 MiB limit')
        return json.loads(payload)
    return json.loads(Path(location).read_text(encoding='utf-8'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', default='app/data/images.json', help='wootc images.json path')
    parser.add_argument('--source', default=CANONICAL_SOURCE,
                        help='bootc-migrate sources.json path or HTTPS URL')
    args = parser.parse_args()

    matched, errors = compare_catalogs(read_json(args.catalog), read_json(args.source))
    if errors:
        for error in errors:
            print(f'catalog drift: {error}', file=sys.stderr)
        return 1
    print(f'catalogs agree for {matched} shared images')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        sys.exit(f'catalog check failed: {exc}')
