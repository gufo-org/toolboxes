import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('prune_caches', ROOT / 'tools/prune-actions-caches.py')
prune = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prune)


def cache(identity, key, created, ref='refs/heads/main', size=1):
    return {'id': identity, 'key': key, 'ref': ref, 'created_at': created, 'size_in_bytes': size}


class SupersededTests(unittest.TestCase):
    def test_keeps_newest_per_prefix_and_ref(self):
        caches = [
            cache(1, 'gufo-windows-ccache-v1-sdk.tar.gz-100-1', '2026-11-17T10:00:00Z'),
            cache(2, 'gufo-windows-ccache-v1-sdk.tar.gz-200-1', '2026-11-23T18:00:00Z'),
            cache(3, 'gufo-windows-ccache-v1-sdk.tar.gz-200-2', '2026-11-23T19:00:00Z'),
            cache(4, 'gufo-windows-ccache-v1-sdk.tar.gz-300-1', '2026-11-20T00:00:00Z', ref='refs/heads/topic'),
            cache(5, 'gufo-deb-ccache-v1-200-1', '2026-11-23T18:00:00Z'),
        ]
        self.assertEqual(sorted(c['id'] for c in prune.superseded(caches)), [1, 2])

    def test_leaves_keys_without_a_run_suffix(self):
        caches = [
            cache(1, 'gufo-therock-v2-therock-dist-windows-gfx1151-10.0.0.tar.gz', '2026-10-25T00:00:00Z'),
            cache(2, 'gufo-iron-windows-v1-3.12.10-b5f3c2637e665560', '2026-11-17T00:00:00Z'),
            cache(3, 'gufo-npu-output-windows-v1-3.12.10-abc-q8gemm-def', '2026-11-17T00:00:00Z'),
            cache(4, 'gufo-npu-output-windows-v1-3.12.10-abc-q8gemm-def', '2026-11-23T00:00:00Z'),
        ]
        self.assertEqual(prune.superseded(caches), [])

    def test_collects_pages_and_dry_run_does_not_delete(self):
        calls = []
        page1 = [cache(i, f'k-{i}-1', f'2026-11-{10 + i % 10:02d}T00:00:00Z') for i in range(100)]

        def api(path, method='GET'):
            calls.append((path, method))
            if '&page=1' in path:
                return json.dumps({'actions_caches': page1})
            return json.dumps({'actions_caches': [cache(500, 'k-500-1', '2026-11-30T00:00:00Z')]})

        with patch.object(prune, 'api', side_effect=api), \
                patch('sys.argv', ['prune', '--repo', 'o/r']), patch('builtins.print'):
            prune.main()
        self.assertEqual([m for _, m in calls], ['GET', 'GET'])

        calls.clear()
        with patch.object(prune, 'api', side_effect=api), \
                patch('sys.argv', ['prune', '--repo', 'o/r', '--apply']), patch('builtins.print'):
            prune.main()
        # Both pages are listed before anything is deleted; the newest entry,
        # on page 2, replaces all 100 on page 1.
        self.assertEqual([m for _, m in calls[:2]], ['GET', 'GET'])
        self.assertIn('page=2', calls[1][0])
        self.assertEqual(sum(m == 'DELETE' for _, m in calls), 100)

    def test_apply_deletes_superseded_entries(self):
        caches = [cache(1, 'k-1-1', '2026-11-01T00:00:00Z'), cache(2, 'k-2-1', '2026-11-02T00:00:00Z')]
        with patch.object(prune, 'api', side_effect=[json.dumps({'actions_caches': caches}), '']) as api, \
                patch('sys.argv', ['prune', '--repo', 'o/r', '--apply']), patch('builtins.print'):
            prune.main()
        self.assertEqual(api.call_args_list[-1].args, ('repos/o/r/actions/caches/1',))
        self.assertEqual(api.call_args_list[-1].kwargs, {'method': 'DELETE'})


if __name__ == '__main__':
    unittest.main()
