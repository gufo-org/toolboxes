import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('prune', ROOT / 'tools/prune-sha-images.py')
prune = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prune)


def version(tags, identity=1):
    return {'id': identity, 'metadata': {'container': {'tags': tags}}}


class CleanupTests(unittest.TestCase):
    def test_protects_shared_and_untagged_versions(self):
        for tags in ([], ['edge'], ['latest'], ['1.2.3'], ['sha-abc', 'edge'],
                     ['sha-abc', '1.2'], ['sha-abc', 'latest']):
            with self.subTest(tags=tags):
                self.assertFalse(prune.sha_only(version(tags)))
        self.assertTrue(prune.sha_only(version(['sha-abc', 'sha-def'])))

    def test_rechecks_tags_before_deleting(self):
        with patch.object(prune, 'api', side_effect=[
            json.dumps([version(['sha-abc'])]),
            json.dumps(version(['sha-abc', 'edge'])),
            '[]',
        ]) as api, patch('sys.argv', ['prune', '--apply']):
            prune.main()
        self.assertTrue(all(call.args[1:] != ('DELETE',) for call in api.call_args_list))

    def test_collects_pages_before_deletion(self):
        calls = []

        def api(path, method='GET'):
            calls.append((path, method))
            if 'gufo-dev' in path:
                return '[]'
            if '&page=1' in path:
                return json.dumps([version(['sha-a'], i) for i in range(100)])
            if '&page=2' in path:
                return '[]'
            return json.dumps(version(['sha-a'])) if method == 'GET' else ''

        with patch.object(prune, 'api', side_effect=api), patch('sys.argv', ['prune', '--apply']), patch('builtins.print'):
            prune.main()
        self.assertIn('page=2', calls[1][0])
        self.assertEqual(sum(method == 'DELETE' for _, method in calls), 100)

    def test_dry_run_does_not_delete(self):
        with patch.object(prune, 'api', side_effect=[
            json.dumps([version(['sha-a'])]), json.dumps(version(['sha-a'])), '[]',
        ]) as api, patch('sys.argv', ['prune']), patch('builtins.print'):
            prune.main()
        self.assertEqual(api.call_count, 3)


class MergeTests(unittest.TestCase):
    def test_merge_mode_and_revision_guard(self):
        for state in ('CLEAN', 'BLOCKED', 'UNKNOWN'):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temp:
                folder = Path(temp)
                gh = folder / 'gh'
                gh.write_text('#!/bin/sh\nif [ "$2" = view ]; then echo "$STATE"; else printf "%s\\n" "$@" > "$CAPTURE"; fi\n')
                gh.chmod(0o755)
                env = dict(os.environ, PATH=f'{folder}:{os.environ["PATH"]}',
                           STATE=state, CAPTURE=str(folder / 'args'))
                subprocess.run([str(ROOT / 'tools/merge-dependency-pr'), 'deps/update-gufo', 'abc123'],
                               env=env, check=True)
                args = (folder / 'args').read_text().splitlines()
                self.assertEqual('--auto' in args, state != 'CLEAN')
                self.assertIn('--squash', args)
                self.assertEqual(args[args.index('--match-head-commit') + 1], 'abc123')


    def test_mergeability_race_and_failed_auto_merge(self):
        for second_state, expected_status in [('CLEAN', 0), ('BLOCKED', 7)]:
            with self.subTest(second_state=second_state), tempfile.TemporaryDirectory() as temp:
                folder = Path(temp)
                gh = folder / 'gh'
                gh.write_text('''#!/bin/sh
if [ "$2" = view ]; then
  if [ -f "$MARKER" ]; then echo "$SECOND_STATE"; else echo UNKNOWN; fi
else
  printf '%s\\n' "$*" >> "$CAPTURE"
  case "$*" in
    *--auto*) touch "$MARKER"; exit 7 ;;
  esac
fi
''')
                gh.chmod(0o755)
                env = dict(os.environ, PATH=f'{folder}:{os.environ["PATH"]}',
                           MARKER=str(folder / 'attempted'), SECOND_STATE=second_state,
                           CAPTURE=str(folder / 'args'))
                result = subprocess.run([str(ROOT / 'tools/merge-dependency-pr'), 'deps/update-gufo', 'abc123'], env=env)
                self.assertEqual(result.returncode, expected_status)
                calls = (folder / 'args').read_text().splitlines()
                self.assertEqual(len(calls), 2 if second_state == 'CLEAN' else 1)
                self.assertIn('--auto', calls[0])
                if second_state == 'CLEAN':
                    self.assertNotIn('--auto', calls[1])
                    self.assertIn('--match-head-commit abc123', calls[1])


class PublishTests(unittest.TestCase):
    def test_publication_guards(self):
        cases = [
            ('current', 'gufo-rev', '0', True),
            ('newer', 'gufo-rev', '0', False),
            ('current', 'wrong-rev', '0', False),
            ('current', 'gufo-rev', '1', False),
        ]
        for head, label, run_status, publish in cases:
            with self.subTest(head=head, label=label, run_status=run_status), tempfile.TemporaryDirectory() as temp:
                folder = Path(temp)
                (folder / 'flake.lock').write_text(json.dumps({'nodes': {'gufo-engine': {'locked': {'rev': 'gufo-rev'}}}}))
                (folder / 'result-gufo-runtime').touch()
                gh = folder / 'gh'
                gh.write_text('#!/bin/sh\necho "$CURRENT_HEAD"\n')
                docker = folder / 'docker'
                docker.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$CAPTURE"
case "$1" in
  image) echo "$LABEL" ;;
  run) exit "$RUN_STATUS" ;;
esac
''')
                gh.chmod(0o755)
                docker.chmod(0o755)
                env = dict(os.environ, PATH=f'{folder}:{os.environ["PATH"]}',
                           CURRENT_HEAD=head, LABEL=label, RUN_STATUS=run_status,
                           CAPTURE=str(folder / 'commands'), IMAGE_PREFIX='ghcr.io/gufo-org/toolboxes',
                           TARGET='gufo-runtime', EXPECTED_REVISION='current',
                           GITHUB_REPOSITORY='gufo-org/toolboxes', GITHUB_STEP_SUMMARY=str(folder / 'summary'))
                result = subprocess.run([str(ROOT / 'tools/publish-edge')], env=env, cwd=folder,
                                        capture_output=True, text=True)
                pushes = [line for line in (folder / 'commands').read_text().splitlines() if line.startswith('push ')]
                self.assertEqual(pushes, ['push ghcr.io/gufo-org/toolboxes/gufo-runtime:edge'] if publish else [])
                self.assertEqual(result.returncode == 0, label == 'gufo-rev' and run_status == '0')


if __name__ == '__main__':
    unittest.main()
