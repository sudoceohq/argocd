#!/usr/bin/env python3
"""Fetch pinned public archives/schemas into an operator cache, checking committed hashes."""
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

root = Path(__file__).resolve().parents[1]
cache = Path(sys.argv[1])
cache.mkdir(parents=True, exist_ok=True)
lock = json.loads((root / 'dependencies.lock.json').read_text())
for artifact in lock['charts'] + lock['vaultProvider']['schemas']:
    path = cache / artifact.get('archive', artifact.get('file'))
    data = path.read_bytes() if path.exists() else urllib.request.urlopen(artifact['url'], timeout=60).read()
    if hashlib.sha256(data).hexdigest() != artifact['sha256']:
        raise ValueError(f'Hash mismatch: {path.name}; never replace the lock implicitly')
    path.write_bytes(data)
    print(f'Verified {path.name}')
