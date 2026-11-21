#!/usr/bin/env python3
"""Checks app-store-1.0.md against App Store Connect's limits: name and subtitle 30 characters,
promotional text 170, keywords 100 bytes (UTF-8), description 4,000 characters.

    python3 notes/check-listing.py [notes/app-store-1.0.md]
"""
import re, sys

LIMITS = {'Name': 30, 'Subtitle': 30, 'Promotional text': 170, 'Keywords': 100, 'Description': 4000}

path = sys.argv[1] if len(sys.argv) > 1 else 'notes/app-store-1.0.md'
text = open(path, encoding='utf-8').read()
ok = True
for lang in re.split(r'\n## ', text)[1:]:
    title, body = lang.split('\n', 1)
    sections = re.split(r'\n### ', '\n' + body)[1:]
    if not any(sec.startswith('Description') for sec in sections):
        continue                      # not a language: notes
    for sec in sections:
        name, value = sec.split('\n', 1)
        value = value.split('\n---')[0].strip()
        if name not in LIMITS:
            continue
        size = len(value.encode('utf-8')) if name == 'Keywords' else len(value)
        bad = size > LIMITS[name] or (name == 'Keywords' and ', ' in value)
        ok &= not bad
        print(f"{'TOO LONG' if bad else 'ok':8s} {title[:12]:12s} {name:17s} {size:5d} / {LIMITS[name]}")
sys.exit(0 if ok else 1)
