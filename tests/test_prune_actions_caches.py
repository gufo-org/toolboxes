import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('prune_caches', ROOT / 'tools/prune-actions-caches.py')
prune = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prune)


def cache(identity, key, created, ref='refs/heads/main', size=1):
    return {'id': identity, 'key': key, 'ref': ref, 'created_at': created, 'size_in_bytes': size}


def page(entries):
    return json.dumps({'actions_caches': entries})


def run(*argv):
    with patch('sys.argv', ['prune', '--repo', 'o/r', *argv]), patch('builtins.print'):
        prune.main()


class SupersededTests(unittest.TestCase):
    def test_keeps_newest_per_prefix_and_ref(self):
        caches = [
            cache(1, 'gufo-windows-ccache-v1-sdk.tar.gz-44060095410-1', '2026-11-17T10:00:00Z'),
            cache(2, 'gufo-windows-ccache-v1-sdk.tar.gz-45228411660-1', '2026-11-23T18:00:00Z'),
            cache(3, 'gufo-windows-ccache-v1-sdk.tar.gz-45228411660-2', '2026-11-23T19:00:00Z'),
            cache(4, 'gufo-windows-ccache-v1-sdk.tar.gz-45300000000-1', '2026-11-20T00:00:00Z',
                  ref='refs/heads/topic'),
            cache(5, 'gufo-deb-ccache-v1-45228411660-1', '2026-11-23T18:00:00Z'),
        ]
        self.assertEqual(sorted(c['id'] for c in prune.superseded(caches)), [1, 2])

    def test_leaves_keys_without_a_run_suffix(self):
        caches = [
            cache(1, 'gufo-therock-v2-therock-dist-windows-gfx1151-10.0.0.tar.gz', '2026-10-25T00:00:00Z'),
            cache(2, 'gufo-iron-windows-v1-3.12.10-b5f3c2637e665560', '2026-11-17T00:00:00Z'),
            cache(3, 'gufo-npu-output-windows-v1-3.12.10-abc-q8gemm-def', '2026-11-17T00:00:00Z'),
            cache(4, 'gufo-npu-output-windows-v1-3.12.10-abc-q8gemm-def', '2026-11-23T00:00:00Z'),
            # Short numeric tails are versions, not run ids.
            cache(5, 'tool-v1-2026-1', '2026-11-01T00:00:00Z'),
            cache(6, 'tool-v1-2027-1', '2026-11-02T00:00:00Z'),
        ]
        self.assertEqual(prune.superseded(caches), [])

    def test_repeated_newest_entry_is_kept(self):
        newest = cache(2, 'k-45228411660-1', '2026-11-23T00:00:00Z')
        older = cache(1, 'k-44060095410-1', '2026-11-17T00:00:00Z')
        self.assertEqual([c['id'] for c in prune.superseded([newest, older, dict(newest)])], [1])


class MainTests(unittest.TestCase):
    def test_lists_every_page_in_creation_order_before_deleting(self):
        calls = []
        first = [cache(i, f'k-{10_000_000 + i}-1', f'2026-11-01T00:{i // 60:02d}:{i % 60:02d}Z')
                 for i in range(100)]
        last = cache(500, 'k-20000000-1', '2026-11-30T00:00:00Z')

        def api(path, method='GET'):
            calls.append(path)
            self.assertIn('sort=created_at&direction=asc', path)
            # The page boundary shifted: page 2 repeats page 1's last entry.
            return page(first) if '&page=1&' in path else page([first[-1], last])

        with patch.object(prune, 'api', side_effect=api), \
                patch.object(prune, 'delete', return_value=True) as delete:
            run()
            delete.assert_not_called()
            run('--apply')
        self.assertIn('&page=2&', calls[-1])
        deleted = [c.args[0] for c in delete.call_args_list]
        self.assertEqual(len(deleted), 100)
        self.assertNotIn('repos/o/r/actions/caches/500', deleted)

    def test_already_deleted_entry_does_not_stop_the_prune(self):
        caches = [cache(1, 'k-10000001-1', '2026-11-01T00:00:00Z'),
                  cache(2, 'k-10000002-1', '2026-11-02T00:00:00Z'),
                  cache(3, 'k-10000003-1', '2026-11-03T00:00:00Z')]
        gone = subprocess.CompletedProcess([], 1, '', 'gh: Not Found (HTTP 404)\n')
        done = subprocess.CompletedProcess([], 0, '', '')
        with patch.object(prune, 'api', return_value=page(caches)), \
                patch.object(prune.subprocess, 'run', side_effect=[gone, done]) as gh:
            run('--apply')
        self.assertEqual([c.args[0][-1] for c in gh.call_args_list],
                         ['repos/o/r/actions/caches/2', 'repos/o/r/actions/caches/1'])

    def test_other_delete_failures_stop_the_prune(self):
        caches = [cache(1, 'k-10000001-1', '2026-11-01T00:00:00Z'),
                  cache(2, 'k-10000002-1', '2026-11-02T00:00:00Z')]
        denied = subprocess.CompletedProcess([], 1, '', 'gh: Forbidden (HTTP 403)\n')
        with patch.object(prune, 'api', return_value=page(caches)), \
                patch.object(prune.subprocess, 'run', return_value=denied), \
                patch('sys.stderr'), self.assertRaises(subprocess.CalledProcessError):
            run('--apply')


if __name__ == '__main__':
    unittest.main()
