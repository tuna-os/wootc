#!/usr/bin/env python3
"""Guards for lost CI verdicts (#363) and workflow input injection (#373/#282).

Uses the workflows' literal blocks so the Bash tests execute shipped code.
No YAML dependency is needed by the fast tier; actionlint validates YAML.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / '.github/workflows'


def block(source, header):
    """Read an indented block after an exact header, failing if absent."""
    lines = source.splitlines()
    for i, line in enumerate(lines):
        if line.strip() != header:
            continue
        indent = len(line) - len(line.lstrip())
        body = []
        for following in lines[i + 1:]:
            if following.strip() and len(following) - len(following.lstrip()) <= indent:
                break
            body.append(following)
        return textwrap.dedent('\n'.join(body))
    raise AssertionError(f'missing block: {header}')


class WorkflowSafety(unittest.TestCase):
    def test_main_runs_do_not_share_a_cancellable_group(self):
        # A false cancel-in-progress alone still drops pending runs in a
        # shared group. Non-PR runs must also have distinct group keys.
        for name in ('ci.yml', 'ci-tests.yml'):
            with self.subTest(workflow=name):
                concurrency = block((WORKFLOWS / name).read_text(), 'concurrency:')
                self.assertIn('${{ github.workflow }}-${{ github.event_name }}', concurrency)
                self.assertIn('${{ github.event.pull_request.number || github.run_id }}', concurrency)
                self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", concurrency)

    def test_write_permissions_are_scoped_to_publishing_and_retry(self):
        allowed = {'release.yml': {'publish:'},
                   'e2e-gui.yml': {'publish:', 'flake-retry:'}}
        for name in ('ci.yml', 'ci-tests.yml', 'ste.yml', *allowed):
            source = (WORKFLOWS / name).read_text()
            with self.subTest(workflow=name):
                self.assertNotIn(': write', block(source, 'permissions:'))
                jobs = block(source, 'jobs:')
                for job in re.findall(r'^([\w-]+:)$', jobs, re.M):
                    if job not in allowed.get(name, set()):
                        self.assertNotIn(': write', block(jobs, job))

    def test_free_form_inputs_never_become_shell_source(self):
        sensitive = re.compile(r'\$\{\{[^}]*\b(?:inputs\.(?:image|tag|release_tag|fault_inject)|'
                               r'github\.event\.release\.tag_name|steps\.chan\.outputs\.tag)\b[^}]*\}\}')
        for name in ('release.yml', 'winget-publish.yml', 'e2e-hosted.yml', 'e2e-gui.yml'):
            source = (WORKFLOWS / name).read_text()
            # Isolate every literal run block; env/with expressions are data.
            for number, chunk in enumerate(re.split(r'(?m)^\s+run: [|>][-+]?\s*\n', source)[1:]):
                lines = chunk.splitlines()
                indent = len(lines[0]) - len(lines[0].lstrip())
                script = []
                for line in lines:
                    if line.strip() and len(line) - len(line.lstrip()) < indent:
                        break
                    script.append(line)
                with self.subTest(workflow=name, script=number):
                    self.assertIsNone(sensitive.search('\n'.join(script)))

    def resolve_tag(self, tag, ref_type='branch'):
        source = (WORKFLOWS / 'release.yml').read_text()
        step = block(source, '- name: Resolve channel + tag')
        self.assertIn('REQUESTED_TAG: ${{ inputs.release_tag }}', step)
        script = block(step, 'run: |')
        # Emulate only GitHub's fixed event fields; dispatch input arrives
        # through the environment, exactly as it does on the runner.
        script = script.replace('${{ github.event_name }}', 'workflow_dispatch')
        script = script.replace('${{ github.event.workflow_run.head_sha }}', '')
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'output'
            output.touch()
            env = {**os.environ, 'REQUESTED_TAG': tag, 'GITHUB_REF_TYPE': ref_type,
                   'GITHUB_REF_NAME': tag if ref_type == 'tag' else 'main',
                   'GITHUB_SHA': 'abcdef0123456789', 'GITHUB_OUTPUT': str(output)}
            result = subprocess.run(['bash', '-eu', '-c', script], env=env,
                                    cwd=tmp, capture_output=True, text=True)
            self.assertFalse((Path(tmp) / 'injected').exists())
            return result.returncode, output.read_text()

    def test_release_tags_preserve_supported_channels(self):
        for tag in ('v1.2.3', '1.2.3', 'v1.2.3-rc.1'):
            for ref_type in ('branch', 'tag'):
                with self.subTest(tag=tag, ref_type=ref_type):
                    rc, output = self.resolve_tag(tag, ref_type)
                    self.assertEqual(rc, 0)
                    self.assertIn(f'tag={tag}\n', output)
                    self.assertIn('prerelease=false\n', output)
        rc, output = self.resolve_tag('')
        self.assertEqual(rc, 0)
        self.assertIn('tag=manual-v', output)
        self.assertIn('prerelease=true\n', output)

    def test_release_tags_reject_code_and_output_injection(self):
        for tag in ('v1.2.3"; touch injected; #', '$(touch injected)',
                    'v1.2.3\nprerelease=true', 'v1.2.3/../../other', 'v1.2.3 extra'):
            for ref_type in ('branch', 'tag'):
                with self.subTest(tag=tag, ref_type=ref_type):
                    rc, output = self.resolve_tag(tag, ref_type)
                    self.assertNotEqual(rc, 0)
                    self.assertEqual(output, '')

    def test_winget_tag_is_data_and_validated_before_download(self):
        source = (WORKFLOWS / 'winget-publish.yml').read_text()
        step = block(source, '- name: Render manifests from the release')
        self.assertIn('RELEASE_TAG: ${{', step)
        script = block(step, 'run: |')
        self.assertIn('$tag = $env:RELEASE_TAG', script)
        self.assertIn('$tag -cnotmatch', script)
        self.assertLess(script.index('$tag -cnotmatch'), script.index('Invoke-WebRequest'))

    def test_renovate_presets_are_unique(self):
        presets = json.loads((ROOT / 'renovate.json').read_text())['extends']
        self.assertEqual(len(presets), len(set(presets)))

    def test_winget_submission_uses_a_verified_tool_in_a_separate_job(self):
        source = (WORKFLOWS / 'winget-publish.yml').read_text()
        jobs = block(source, 'jobs:')
        render = block(jobs, 'render:')
        submit = block(jobs, 'submit:')
        self.assertNotIn('secrets.', render)
        self.assertIn('needs: render', submit)
        prepare = block(submit, '- name: Prepare verified wingetcreate')
        self.assertIn('Install-VerifiedWingetCreate -Destination $env:RUNNER_TEMP', prepare)
        self.assertNotIn('secrets.', prepare)
        send = block(submit, '- name: Submit to winget-pkgs')
        self.assertIn('WINGET_CREATE_GITHUB_TOKEN: ${{ secrets.WINGET_TOKEN }}', send)
        self.assertIn('& $env:WINGETCREATE_EXE submit', send)
        self.assertNotIn('--token', send)
        self.assertNotIn('Invoke-WebRequest', send)
        self.assertLess(submit.index('- name: Prepare verified wingetcreate'),
                        submit.index('- name: Submit to winget-pkgs'))


if __name__ == '__main__':
    unittest.main()
