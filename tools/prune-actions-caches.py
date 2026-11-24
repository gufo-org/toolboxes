#!/usr/bin/env python3
"""Keep only the newest Actions cache entry per key prefix and branch.

Release and warm-up builds save rolling caches under keys that end in
`-<run id>-<run attempt>` (a run id of at least 8 digits, as in Gufo's
caches.yml) and restore the newest entry by prefix, so older
entries with the same prefix are never restored again but still count toward
the repository's 10 GB limit. Keys without that suffix are left alone.
"""
import argparse
import json
import re
import subprocess
import sys

RUN_SUFFIX = re.compile(r'-\d{8,}-\d+$')


def api(path, method='GET'):
    return subprocess.check_output(['gh', 'api', '--method', method, path], text=True)


def delete(path):
    """Delete an entry; one GitHub already removed (404) counts as deleted."""
    result = subprocess.run(['gh', 'api', '--method', 'DELETE', path], capture_output=True, text=True)
    if result.returncode == 0:
        return True
    if 'HTTP 404' in result.stderr:
        print(f'{path} was already deleted')
        return False
    sys.stderr.write(result.stderr)
    raise subprocess.CalledProcessError(result.returncode, result.args)


def prefix(key):
    return RUN_SUFFIX.sub('', key) if RUN_SUFFIX.search(key) else None


def superseded(caches):
    """Return the entries a newer entry with the same prefix and ref replaces."""
    # Offset pages can repeat an entry when the list changes between requests;
    # a repeated newest entry must not count as its own older copy.
    caches = {cache['id']: cache for cache in caches}.values()
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
    # Creation order, unlike the default access order, does not change when a
    # running build restores an entry.
    caches = []
    page = 1
    while True:
        batch = json.loads(api(f'{base}?per_page=100&page={page}&sort=created_at&direction=asc'))['actions_caches']
        caches.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    freed = 0
    for cache in superseded(caches):
        action = 'Deleting' if args.apply else 'Would delete'
        print(f"{action} {cache['key']} ({cache['ref']}, {cache['size_in_bytes'] / 2**20:.0f} MiB)")
        if not args.apply or delete(f"{base}/{cache['id']}"):
            freed += cache['size_in_bytes']
    print(f'{"Freed" if args.apply else "Would free"} {freed / 2**30:.2f} GiB')


if __name__ == '__main__':
    main()
