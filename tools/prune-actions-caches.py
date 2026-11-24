#!/usr/bin/env python3
"""Keep only the newest Actions cache entry per key prefix and branch.

Release and warm-up builds save rolling caches under keys that end in
`-<run id>-<run attempt>` and restore the newest entry by prefix, so older
entries with the same prefix are never restored again but still count toward
the repository's 10 GB limit. Keys without that suffix are left alone.
"""
import argparse
import json
import re
import subprocess

RUN_SUFFIX = re.compile(r'-\d+-\d+$')


def api(path, method='GET'):
    return subprocess.check_output(['gh', 'api', '--method', method, path], text=True)


def prefix(key):
    return RUN_SUFFIX.sub('', key) if RUN_SUFFIX.search(key) else None


def superseded(caches):
    """Return the entries a newer entry with the same prefix and ref replaces."""
    newest = {}
    stale = []
    for cache in sorted(caches, key=lambda c: (c['created_at'], c['id']), reverse=True):
        group = prefix(cache['key'])
        if group is None:
            continue
        if (cache['ref'], group) in newest:
            stale.append(cache)
        else:
            newest[(cache['ref'], group)] = cache
    return stale


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, help='owner/name')
    parser.add_argument('--apply', action='store_true', help='delete superseded entries (default: dry run)')
    args = parser.parse_args()
    base = f'repos/{args.repo}/actions/caches'
    # Collect all pages before deleting so pagination cannot skip entries.
    caches = []
    page = 1
    while True:
        batch = json.loads(api(f'{base}?per_page=100&page={page}'))['actions_caches']
        caches.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    freed = 0
    for cache in superseded(caches):
        freed += cache['size_in_bytes']
        action = 'Deleting' if args.apply else 'Would delete'
        print(f"{action} {cache['key']} ({cache['ref']}, {cache['size_in_bytes'] / 2**20:.0f} MiB)")
        if args.apply:
            api(f"{base}/{cache['id']}", method='DELETE')
    print(f'{"Freed" if args.apply else "Would free"} {freed / 2**30:.2f} GiB')


if __name__ == '__main__':
    main()
