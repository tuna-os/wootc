#!/usr/bin/env python3
"""Normalize Windows transcripts and remove recovery passwords before publication."""
import argparse
import os
from pathlib import Path
import re
import sys
import tempfile

PASSWORD = re.compile(r'(?<!\d)(?:\d{6}(?:-\d{6}){7}|\d{48})(?!\d)')
PASSWORD_BYTES = re.compile(rb'(?<!\d)(?:\d{6}(?:-\d{6}){7}|\d{48})(?!\d)')


def normalize(raw):
    # Detect ASCII secrets without any encoding alignment assumption.
    compact = raw.replace(b'\x00', b'')
    if PASSWORD_BYTES.search(compact):
        compact = PASSWORD_BYTES.sub(b'[REDACTED recovery password]', compact)
        return compact.decode('utf-8-sig', errors='replace').rstrip('\r\n') + '\n'
    # A transcript can mix UTF-8 headers and UTF-16LE native output.
    raw = raw.lstrip(b'\x00')
    if raw.startswith(b'\xff\xfe'):
        raw = raw[2:]
    content = raw.rstrip(b'\n')
    if content and content.count(b'\x00') > len(content) // 5:
        text = content.decode('utf-16le', errors='replace')
    else:
        text = content.decode('utf-8-sig', errors='replace')
    text = text.replace('\x00', '')
    return PASSWORD.sub('[REDACTED recovery password]', text).rstrip('\r\n') + '\n'


def stream(source, destination):
    for raw in source:
        destination.write(normalize(raw))
        destination.flush()


def sanitize(path):
    if path.is_symlink():
        raise ValueError('Refusing a linked log')
    fd, temporary = tempfile.mkstemp(prefix='.safe-log-', dir=path.parent)
    try:
        with path.open('rb') as source, os.fdopen(fd, 'w', encoding='utf-8') as destination:
            stream(source, destination)
            os.fsync(destination.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def diagnostic_text(path):
    if path.suffix in {'.log', '.txt', '.pty', '.stdout', '.stderr', '.jsonl'}:
        return True
    # Binary VM media remain binary evidence; do not treat them as transcripts.
    if path.suffix in {'.qcow2', '.iso', '.img', '.mp4', '.webm', '.exe', '.efi'}:
        return False
    with path.open('rb') as source:
        sample = source.read(4096)
    if sample.startswith((b'\x89PNG', b'\xff\xd8', b'P6\n', b'QFI\xfb', b'MZ')):
        return False
    if sample.startswith(b'\xff\xfe') or PASSWORD_BYTES.search(sample.replace(b'\x00', b'')):
        return True
    compact = sample.replace(b'\x00', b'')
    try:
        text = compact.decode('utf-8')
    except UnicodeDecodeError:
        return False
    return all(character.isprintable() or character in '\n\r\t\x1b' for character in text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tree', type=Path)
    args = parser.parse_args()
    if args.tree:
        for path in args.tree.rglob('*'):
            if path.is_symlink():
                raise ValueError('Refusing a linked artifact')
            if path.is_file() and diagnostic_text(path):
                sanitize(path)
    else:
        stream(sys.stdin.buffer, sys.stdout)


if __name__ == '__main__':
    main()
