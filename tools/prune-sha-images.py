#!/usr/bin/env python3
"""Remove legacy GHCR versions only when every tag is a SHA tag."""
import argparse
import json
import subprocess
from urllib.parse import quote


def api(path, method='GET'):
    return subprocess.check_output(['gh', 'api', '--method', method, path], text=True)


def sha_only(version):
    tags = version['metadata']['container']['tags']
    return bool(tags) and all(tag.startswith('sha-') for tag in tags)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='delete eligible versions (default: dry run)')
    args = parser.parse_args()
    for image in ('gufo-runtime', 'gufo-dev'):
        base = f'orgs/gufo-org/packages/container/{quote("toolboxes/" + image, safe="")}/versions'
        # Collect all pages before deleting so pagination cannot skip versions.
        versions = []
        page = 1
        while True:
            batch = json.loads(api(f'{base}?per_page=100&page={page}'))
            versions.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        for version in versions:
            if not sha_only(version):
                continue
            path = f'{base}/{version["id"]}'
            # Recheck immediately before deletion to protect newly attached tags.
            current = json.loads(api(path))
            if not sha_only(current):
                continue
            print(f'{"Deleting" if args.apply else "Would delete"} {image} version {version["id"]}: '
                  f'{current["metadata"]["container"]["tags"]}', flush=True)
            if args.apply:
                api(path, 'DELETE')


if __name__ == '__main__':
    main()
