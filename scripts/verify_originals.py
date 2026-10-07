#!/usr/bin/env python3
"""Read-only verification of the original course against the discovery manifest."""
from pathlib import Path
import hashlib
import json
import sys
import argparse

workspace = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--baseline", default="original-hashes.json")
parser.add_argument("--snapshot")
args = parser.parse_args()
manifest = json.loads((workspace / args.baseline).read_text())
original = Path(manifest["originalRoot"])
actual = {}
links = []
for path in sorted(original.rglob("*")):
    if path.is_symlink():
        links.append(str(path.relative_to(original)))
    elif path.is_file():
        actual[str(path.relative_to(original))] = hashlib.sha256(path.read_bytes()).hexdigest()
expected = manifest["originalHashes"]
if args.snapshot:
    target = (workspace / args.snapshot).resolve()
    if not target.is_relative_to(workspace): raise SystemExit("Snapshot must stay in prototype workspace")
    snapshot = dict(manifest, originalHashes=actual)
    target.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"snapshot": str(target), "files": len(actual)}, ensure_ascii=False))
    sys.exit(0)
changed = [name for name in expected if actual.get(name) != expected[name]]
added = sorted(set(actual) - set(expected))
result = {"originalRoot": str(original), "copyRoot": manifest["copyRoot"],
          "filesVerified": len(expected), "changedOrMissing": changed,
          "added": added, "symlinks": links,
          "unchanged": not (changed or added or links)}
print(json.dumps(result, ensure_ascii=False, indent=2))
sys.exit(0 if result["unchanged"] else 1)
