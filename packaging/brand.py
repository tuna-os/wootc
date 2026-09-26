#!/usr/bin/env python3
"""Create and validate distro brands without editing application code."""
import argparse
import json
from pathlib import Path
import re
import shutil
import sys
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
FIELDS = set('$schema name tagline logoEmoji version accent accentText background card text installVerb productName exeName publisher copyright fileDescription websiteURL supportURL catalog defaultImage hideCustomImage preloadImage fontFamily logoDataUri fontDataUri themeCss'.split())
QUESTIONS = ('mark', 'name', 'tagline', 'distributeExe')


def read(path):
    return json.loads(path.read_text())


def write(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def require(ok, message):
    if not ok:
        raise ValueError(message)


def identifier(value):
    require(bool(re.fullmatch(r'[a-z][a-z0-9-]*', value)), 'brand ID must be a lowercase slug')
    return value


def https(value):
    url = urlparse(value)
    require(url.scheme == 'https' and url.hostname and not url.username and not url.password,
            'brand links must be HTTPS URLs without credentials')
    require(not any(ord(c) < 32 for c in value), 'control character in URL')
    return value


def ownership(root):
    return read(root / 'app/branding/ownership.json')


def validate(root, brand):
    identifier(brand)
    directory = root / 'app/branding' / brand
    config = read(directory / 'brand.json')
    require(not (config.keys() - FIELDS), f'{brand}: unknown fields {config.keys() - FIELDS}')
    for field in ('name', 'productName', 'exeName', 'tagline'):
        require(isinstance(config.get(field), str) and config[field].strip(), f'{brand}: missing {field}')
    for key, value in config.items():
        if key == 'catalog':
            require(isinstance(value, list) and all(isinstance(v, str) for v in value), 'catalog must contain image IDs')
        elif key in ('hideCustomImage', 'preloadImage'):
            require(type(value) is bool, f'{key} must be boolean')
        else:
            require(isinstance(value, str), f'{key} must be a string')
    exe = config['exeName']
    require(bool(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', exe)) and not exe.endswith('.')
            and not exe.lower().endswith('.exe'), 'exeName must be a filename stem, not a path')
    require(not re.fullmatch(r'(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?', exe), 'reserved Windows filename')
    for sibling in directory.parent.glob('*/brand.json'):
        if sibling.parent != directory:
            require(read(sibling).get('exeName', '').casefold() != exe.casefold(), 'duplicate executable name')
    for key in ('websiteURL', 'supportURL'):
        if config.get(key):
            https(config[key])
    for key in ('accent', 'accentText', 'background', 'card', 'text'):
        if config.get(key):
            require(bool(re.fullmatch(r'#[0-9a-fA-F]{6}', config[key])), f'{key} must be #RRGGBB')
    catalog_file = directory / 'images.json'
    images = read(catalog_file if catalog_file.exists() else root / 'app/data/images.json')
    require(isinstance(images, list) and images, 'image catalog must be a nonempty array')
    ids = set()
    for image in images:
        require(isinstance(image, dict), 'invalid image entry')
        require(image.get('id') and image.get('name') and image.get('imageRef'), 'image needs id, name and imageRef')
        require(image['id'] not in ids, 'duplicate image ID')
        require(image.get('status') in ('green', 'experimental'), 'image status must be explicit')
        ids.add(image['id'])
    require(set(config.get('catalog', [])) <= ids, 'catalog references an unknown image')
    if config.get('defaultImage'):
        require(config['defaultImage'] in config.get('catalog', []), 'defaultImage must be in catalog')
    decision = read(directory / 'blessing.json')
    require(decision.get('brand') == brand, 'ownership record names another brand')
    answers = decision.get('decisions', {})
    require(set(answers) == set(QUESTIONS), 'ownership decision set is incomplete')
    require(all(v in ('yes', 'no', 'pending') for v in answers.values()), 'invalid ownership answer')
    status = 'declined' if 'no' in answers.values() else ('blessed' if set(answers.values()) == {'yes'} else 'pending')
    require(decision.get('status') == status, 'ownership status disagrees with decisions')
    if decision.get('selfOwned'):
        policy = ownership(root)
        require(brand in policy['selfOwnedBrands'], 'self-owned brand absent from ownership policy')
        require(decision['winget']['identifier'].split('.')[0] in policy['wingetNamespaces'], 'unowned winget namespace')
    elif status != 'pending':
        require(decision.get('ask', {}).get('filed') and decision['ask'].get('evidence'), 'third-party decision needs evidence')
    return config


def update_table(root):
    path = root / 'app/branding/README.md'
    source = path.read_text()
    rows = ['| Brand | Mark owner | Status | Mark | Name | Tagline | Branded exe | winget identifier |',
            '|---|---|---|---|---|---|---|---|']
    for p in sorted((root / 'app/branding').glob('*/blessing.json')):
        b = read(p)
        cells = [f"`{b['brand']}`", b['mark']['owner'], b['status']]
        cells += [b['decisions'][q] for q in QUESTIONS]
        cells += [f"`{b['winget']['identifier']}`"]
        rows.append('| ' + ' | '.join(v.replace('|', r'\|') for v in cells) + ' |')
    table = '\n'.join(rows)
    pattern = r'(?m)^\| Brand \|[^\n]*\n(?:\|[^\n]*\n)+'
    require(re.search(pattern, source), 'branding README has no ownership table')
    path.write_text(re.sub(pattern, lambda _: table + '\n', source, count=1))


def create(root, args):
    brand = identifier(args.id)
    https(args.website)
    https(args.support)
    require(re.fullmatch(r'[A-Za-z0-9]+\.[A-Za-z0-9.]+', args.winget_id), 'winget ID must be Publisher.Package')
    require(args.image_ref and not any(c.isspace() for c in args.image_ref), 'image ref must be one OCI reference')
    directory = root / 'app/branding' / brand
    require(not directory.exists(), 'brand already exists; refusing to overwrite')
    for asset in (args.logo, args.icon):
        if asset:
            require(Path(asset).is_file(), f'asset not found: {asset}')
    config = dict(name=args.name, productName=args.name + ' Installer', exeName=brand + '-Installer',
                  publisher=args.publisher, fileDescription=args.name + ' Installer',
                  copyright=f'Copyright {args.publisher}', websiteURL=args.website, supportURL=args.support,
                  tagline=f'Install {args.name} and keep Windows.', logoEmoji='🐧',
                  accent='#3454d1', accentText='#ffffff', background='#10141b', card='#1b2230', text='#f0f3fa',
                  installVerb='Install', catalog=[brand], defaultImage=brand, hideCustomImage=True, preloadImage=True)
    yes = 'yes' if args.self_owned else 'pending'
    record = dict(brand=brand, selfOwned=args.self_owned, status='blessed' if args.self_owned else 'pending',
                  mark=dict(owner=args.publisher, assetSource=args.website),
                  decisions={q: yes for q in QUESTIONS},
                  winget=dict(identifier=args.winget_id, namespaceOwner=args.publisher, identifierAgreed=args.self_owned),
                  ask=dict(filed=False, venue=args.support, shown=[], openedAt='', decidedAt='', evidence=''),
                  notes='Created by the mark owner with --self-owned.' if args.self_owned else 'No permission requested or granted yet.')
    directory.mkdir()
    write(directory / 'brand.json', config)
    write(directory / 'images.json', [dict(id=brand, name=args.name, emoji='🐧', imageRef=args.image_ref,
                                          description=f'{args.name} desktop', bootloader='auto', status='experimental')])
    write(directory / 'blessing.json', record)
    for src, dst in ((args.logo, 'logo.svg'), (args.icon, 'icon.ico')):
        if src:
            shutil.copyfile(src, directory / dst)
    if args.self_owned:
        policy = ownership(root)
        policy['selfOwnedBrands'] = sorted(set(policy['selfOwnedBrands'] + [brand]))
        policy['wingetNamespaces'] = sorted(set(policy['wingetNamespaces'] + [args.winget_id.split('.')[0]]))
        write(root / 'app/branding/ownership.json', policy)
    validate(root, brand)
    update_table(root)
    print(f'Created {directory}; image status is experimental until E2E evidence exists.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT, help='checkout root')
    commands = parser.add_subparsers(dest='command', required=True)
    init = commands.add_parser('init')
    for name in ('id', 'name', 'publisher', 'website', 'support', 'winget-id', 'image-ref'):
        init.add_argument('--' + name, required=True)
    init.add_argument('--self-owned', action='store_true', help='assert you own this name, mark, and package namespace')
    init.add_argument('--logo')
    init.add_argument('--icon')
    check = commands.add_parser('validate')
    check.add_argument('--brand')
    commands.add_parser('table')
    args = parser.parse_args()
    try:
        if args.command == 'init':
            create(args.root, args)
        elif args.command == 'table':
            update_table(args.root)
        else:
            brands = [args.brand] if args.brand else [p.name for p in (args.root / 'app/branding').iterdir() if p.is_dir()]
            for brand in sorted(brands):
                validate(args.root, brand)
                print(f'{brand}: valid')
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f'brand: {error}\n')


if __name__ == '__main__':
    main()
