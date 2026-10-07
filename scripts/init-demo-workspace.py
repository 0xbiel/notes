#!/usr/bin/env python3
"""Create an independent, invented workspace without importing any real files."""
from pathlib import Path
import argparse, hashlib, json

parser = argparse.ArgumentParser()
parser.add_argument('workspace', type=Path)
args = parser.parse_args()
root = args.workspace.absolute()
if root.exists() and any(root.iterdir()):
    raise SystemExit('Choose a new or empty workspace; existing files will not be replaced.')
if any(p.is_symlink() for p in [root, *root.parents]):
    raise SystemExit('Choose a workspace without symlink components.')
root.mkdir(parents=True, exist_ok=True)
for folder in ['copied-course', 'session-storage', 'protected-original']:
    (root / folder).mkdir()
text = '# Inicio\n\nEsta nota es inventada. Puedes crear cuadernos y notas desde Notes.\n'
(root / 'copied-course/Inicio.md').write_text(text)
manifest = {'originalRoot': str(root / 'protected-original'), 'copyRoot': str(root / 'copied-course'),
            'originalHashes': {}, 'copyHashes': {'Inicio.md': hashlib.sha256(text.encode()).hexdigest()}}
(root / 'original-hashes.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(root)
