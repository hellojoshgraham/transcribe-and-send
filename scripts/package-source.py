#!/usr/bin/env python3
"""Build a reviewed, source-only archive. Never recursively zip the workspace."""
import hashlib
import json
import plistlib
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIRECTORIES = ('Sources', 'Tests', 'Resources', 'scripts', 'docs', '.github')
FILES = ('Package.swift', 'README.md', 'LICENSE', 'SECURITY.md', 'CONTRIBUTING.md', 'CHANGELOG.md', '.gitignore')
SUFFIXES = {'.swift', '.plist', '.icns', '.sh', '.py', '.md', '.yml', '.yaml'}
PATTERNS = (
    re.compile(rb'/Users/[A-Za-z0-9_.-]+/'),
    re.compile(rb'/home/[A-Za-z0-9_.-]+/'),
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    re.compile(rb'ts-pair:1:[A-Za-z0-9+/]{80,}={0,2}'),
    re.compile(rb'(?i)(?:ghp_|github_pat_|sk_live_)[A-Za-z0-9_]{20,}'),
)

def build():
    paths = [ROOT / name for name in FILES]
    for name in DIRECTORIES:
        for path in sorted((ROOT / name).rglob('*')):
            if path.is_symlink():
                raise SystemExit(f'Symlink not allowed: {path.relative_to(ROOT)}')
            if path.is_file():
                if path.suffix not in SUFFIXES or any(p.startswith('.') and p != '.github' for p in path.relative_to(ROOT).parts):
                    raise SystemExit(f'Unexpected source file: {path.relative_to(ROOT)}')
                paths.append(path)
    entries = {}
    for path in sorted(paths):
        if not path.is_file() or path.is_symlink():
            raise SystemExit(f'Missing or unsafe source: {path.relative_to(ROOT)}')
        data = path.read_bytes()
        if len(data) > 4 * 1024 * 1024:
            raise SystemExit(f'Unexpectedly large source: {path.relative_to(ROOT)}')
        if any(pattern.search(data) for pattern in PATTERNS):
            raise SystemExit(f'Potential private data: {path.relative_to(ROOT)} (contents withheld)')
        entries[path.relative_to(ROOT).as_posix()] = data
    version = plistlib.loads(entries['Resources/Info.plist'])['CFBundleShortVersionString']
    manifest = {name: hashlib.sha256(data).hexdigest() for name, data in entries.items()}
    entries['SOURCE-MANIFEST.json'] = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode()
    output = ROOT / 'dist' / version
    output.mkdir(parents=True, exist_ok=True)
    archive = output / 'TandS-source.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as package:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo('transcribe-and-send/' + name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            package.writestr(info, data)
    with zipfile.ZipFile(archive) as package:
        assert package.testzip() is None
        for name, digest in manifest.items():
            assert hashlib.sha256(package.read('transcribe-and-send/' + name)).hexdigest() == digest
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / 'TandS-source.sha256').write_text(f'{digest}  TandS-source.zip\n')
    print(f'Checked {len(manifest)} source files; archive and manifest verified.')
    print(f'Output: dist/{version}/TandS-source.zip')
    print(f'SHA-256: {digest}')

if __name__ == '__main__':
    build()
