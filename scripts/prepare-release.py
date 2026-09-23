#!/usr/bin/env python3
"""Validate both CI installers and stage only public release assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--artifacts', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--tag', required=True)
parser.add_argument('--commit', required=True)
args = parser.parse_args()
tag = re.fullmatch(r'v(\d+\.\d+\.\d+)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?', args.tag)
if not tag or not re.fullmatch(r'[0-9a-f]{40}', args.commit):
    parser.error('Expected vX.Y.Z[-preview] and a full commit SHA.')
version = tag.group(1)
metadata_files = list(args.artifacts.rglob('build-info.json'))
if len(metadata_files) != 2:
    parser.error('Expected exactly two architecture artifacts.')
assets = []
architectures = set()
for path in metadata_files:
    info = json.loads(path.read_text())
    arch = info.get('architecture')
    if arch not in {'arm64', 'x86_64'} or arch in architectures:
        parser.error('Artifacts must contain one arm64 and one x86_64 build.')
    architectures.add(arch)
    if info.get('commit') != args.commit or info.get('version') != version or info.get('notarized') is not False:
        parser.error(f'{arch}: source commit, version or signing metadata does not match.')
    filename = f'RightMouse-{version}-{arch}.dmg'
    dmg = path.parent / filename
    checksum = path.parent / (filename + '.sha256')
    for source in [path, dmg, checksum]:
        if source.is_symlink() or not source.is_file():
            parser.error(f'Missing or invalid release file: {source.name}')
    fields = checksum.read_text().split()
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    if fields != [digest, filename]:
        parser.error(f'{arch}: DMG checksum does not match.')
    assets.extend([(dmg, filename), (checksum, checksum.name), (path, f'build-info-{arch}.json')])
if args.output.exists() and any(args.output.iterdir()):
    parser.error('Output directory must be empty; existing release files are never replaced.')
args.output.mkdir(parents=True, exist_ok=True)
for source, name in assets:
    shutil.copy2(source, args.output / name)
print(f'Validated {args.tag}: both architectures, commit {args.commit}, six public assets.')
