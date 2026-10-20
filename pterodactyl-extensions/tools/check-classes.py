#!/usr/bin/env python3
"""Fails when a prefixed Tailwind class written in the client source is missing from the built stylesheet.

A class such as `olg:first:pt-0` is only styled when the build generated it. The prefix must come first, before any
variant. Tailwind silently drops classes it does not see, so the page looks wrong instead of failing; this check makes
that a build failure.

usage: check-classes.py <extension-dir> <built-stylesheet>
"""
import glob
import json
import os
import re
import sys


def escape(cls):
    # Tailwind escapes these characters in the selectors it generates.
    return re.sub(r'([:\[\]/.%])', r'\\\1', cls)


def main():
    ext, css_path = sys.argv[1], sys.argv[2]
    with open(os.path.join(ext, 'extension.json'), encoding='utf-8') as handle:
        prefix = json.load(handle)['ui']['prefix']
    with open(css_path, encoding='utf-8') as handle:
        css = handle.read()

    token = re.compile(r'[A-Za-z0-9_\-\[\]:/.%]*?' + re.escape(prefix) + r':[A-Za-z0-9_\-\[\]:/.%]+')
    tokens = set()
    for path in glob.glob(os.path.join(ext, 'src', 'client', '**', '*.ts*'), recursive=True):
        if '.spec.' in path or path.endswith('test-utils.tsx'):
            continue
        with open(path, encoding='utf-8') as handle:
            tokens.update(t for t in token.findall(handle.read()) if prefix + ':' in t)

    missing = [t for t in sorted(tokens) if '.' + escape(t) not in css]
    print(f'{prefix}: {len(tokens)} prefixed classes, {len(missing)} missing from the stylesheet')
    for cls in missing:
        print(f'  MISSING {cls}')

    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
