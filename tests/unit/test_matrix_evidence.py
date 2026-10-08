#!/usr/bin/env python3
"""tools/release/matrix-evidence.py — the RC full-matrix evidence grader (#240)."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).parents[2]
spec = importlib.util.spec_from_file_location('evidence', ROOT / 'tools/release/matrix-evidence.py')
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)

SHA = 'a' * 40
KEY = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
MATRIX = '\n'.join([
    '# comment',
    f'smoke\tbase\tghcr.io/x/y:gnome\t11\tpro\t{KEY}',
    f'full\tkde\tghcr.io/x/y:kde\t11\tpro\t{KEY}',
    f'full\tbase-phase3\tghcr.io/x/y:gnome\t11\tpro\t{KEY}\tphase3=on',
    f'smoke\tbase-btrfs\tghcr.io/x/y:gnome\t11\tpro\t{KEY}\tfilesystem=btrfs',
    f'smoke\tbase-bitlocker\tghcr.io/x/y:gnome\t11\tpro\t{KEY}\tbitlocker=on',
    f'smoke\tbase-offline\tghcr.io/x/y:gnome\t11\tpro\t{KEY}\toffline=on',
    f'full\trecovery-pre-reboot\tghcr.io/x/y:gnome\t11\tpro\t{KEY}\tfault=pre-reboot',
    f'full\tsb-db-none-refusal\tghcr.io/x/y:gnome\t11\tpro\t{KEY}\tfirmware_db=none',
    '',
])
SCRIPT_CELLS = ['base', 'kde', 'base-btrfs', 'base-bitlocker', 'base-offline',
                'recovery-pre-reboot', 'sb-db-none-refusal']
GUI_CELLS = ['base', 'kde', 'recovery-pre-reboot', 'sb-db-none-refusal']
MARKER = {'recovery-pre-reboot': 'recovery', 'sb-db-none-refusal': 'sb-refusal'}


def job(cell, jid, conclusion='success', attempt=1, **extra):
    entry = {'id': jid, 'name': f'{cell} / e2e', 'conclusion': conclusion, 'run_attempt': attempt,
             'head_sha': SHA}
    if conclusion == 'success':
        marker = MARKER.get(cell, 'banner')
        entry.update(passMarkers=[marker], passBanner=marker == 'banner', ledgerDump=False)
    else:
        entry['flake'] = ''
    entry.update(extra)
    return entry


def run(rid, mode, cells, grep='', created='2026-10-01T00:00:00Z', **extra):
    title = f'E2E matrix (full, {mode}' + (f', grep={grep}' if grep else '') + ')'
    jobs = [{'id': rid * 100, 'name': 'plan', 'conclusion': 'success', 'run_attempt': 1, 'head_sha': SHA}]
    jobs += [job(c, rid * 100 + i + 1) for i, c in enumerate(cells)]
    return {'id': rid, 'path': ev.WORKFLOW, 'head_sha': SHA, 'display_title': title,
            'created_at': created, 'jobs': jobs, **extra}


def green():
    return {'schemaVersion': 1, 'repo': 'tuna-os/wootc', 'sha': SHA,
            'runs': [run(1, 'script', SCRIPT_CELLS), run(2, 'gui', GUI_CELLS)]}


def cell_job(snap, rid, cell):
    r = next(r for r in snap['runs'] if r['id'] == rid)
    return next(j for j in r['jobs'] if j['name'] == f'{cell} / e2e')


class Grade(unittest.TestCase):
    def grade(self, snap, matrix=MATRIX):
        ok, problems, rows, cells, skipped = ev.grade(snap, matrix)
        return ok, problems

    def test_green_run_set_passes(self):
        ok, problems = self.grade(green())
        self.assertTrue(ok, problems)

    def test_expected_cells_follow_the_workflow_guards(self):
        cells, skipped = ev.parse_matrix(MATRIX)
        self.assertEqual(ev.expected(cells), {'script': SCRIPT_CELLS, 'gui': GUI_CELLS})
        self.assertEqual(skipped, ['base-phase3'])
        cells, skipped = ev.parse_matrix(MATRIX, include_phase3=True)
        self.assertIn('base-phase3', ev.expected(cells)['script'])

    def test_missing_cell_fails(self):
        snap = green()
        snap['runs'][0]['jobs'] = [j for j in snap['runs'][0]['jobs'] if j['name'] != 'kde / e2e']
        ok, problems = self.grade(snap)
        self.assertFalse(ok)
        self.assertIn('script: kde has no job in the run set', problems)

    def test_missing_gui_run_fails(self):
        snap = green()
        snap['runs'].pop()
        ok, problems = self.grade(snap)
        self.assertFalse(ok)
        self.assertIn('no unfiltered tier=full gui-mode run at the RC SHA', problems)

    def test_inherited_green_from_another_sha_fails(self):
        snap = green()
        snap['runs'][1]['head_sha'] = 'b' * 40
        ok, problems = self.grade(snap)
        self.assertFalse(ok)
        self.assertTrue(any('not the RC SHA' in p for p in problems), problems)

    def test_smoke_tier_and_untitled_runs_do_not_count(self):
        snap = green()
        snap['runs'][0]['display_title'] = 'E2E matrix (smoke, script)'
        snap['runs'][1]['display_title'] = 'E2E matrix (hosted)'
        ok, problems = self.grade(snap)
        self.assertFalse(ok)
        self.assertTrue(any('tier=smoke' in p for p in problems), problems)
        self.assertTrue(any('does not name its tier and mode' in p for p in problems), problems)

    def test_other_workflow_does_not_count(self):
        snap = green()
        snap['runs'][1]['path'] = '.github/workflows/e2e-gui.yml'
        ok, problems = self.grade(snap)
        self.assertFalse(ok)

    def test_success_without_pass_banner_is_not_green(self):
        # The job conclusion is a proxy. The banner is printed only after the
        # failure ledger was found empty.
        snap = green()
        cell_job(snap, 1, 'kde').update(passBanner=False, passMarkers=[])
        ok, problems = self.grade(snap)
        self.assertFalse(ok)
        self.assertTrue(any('ALL TESTS PASSED' in p for p in problems), problems)

    def test_short_cells_grade_on_their_own_marker(self):
        # Recovery and Secure Boot refusal cells exit 0 before the full-cycle
        # banner; each is green on the marker its scenario prints.
        ok, problems = self.grade(green())
        self.assertTrue(ok, problems)
        for cell, wrong in (('recovery-pre-reboot', 'banner'), ('sb-db-none-refusal', 'recovery')):
            snap = green()
            cell_job(snap, 1, cell).update(passMarkers=[wrong])
            ok, problems = self.grade(snap)
            self.assertFalse(ok, cell)
            self.assertTrue(any(cell in p and 'marker' in p for p in problems), problems)

    def test_old_snapshots_without_markers_still_grade_on_the_banner(self):
        job = {'passBanner': True}
        self.assertEqual(ev.markers_of(job), {'banner'})
        self.assertEqual(ev.markers_of({'passBanner': False}), set())

    def test_pass_markers_match_run_e2e(self):
        script = (ROOT / 'tests/e2e/run-e2e.sh').read_text()
        for marker in ev.PASS_MARKERS.values():
            self.assertIn(marker, script)

    def test_ledger_dump_is_not_green(self):
        snap = green()
        cell_job(snap, 1, 'kde')['ledgerDump'] = True
        ok, problems = self.grade(snap)
        self.assertFalse(ok)

    def test_final_red_fails(self):
        snap = green()
        cell_job(snap, 1, 'base-bitlocker').update(conclusion='failure', passBanner=False)
        ok, problems = self.grade(snap)
        self.assertFalse(ok)
        self.assertTrue(any('base-bitlocker final attempt is failure' in p for p in problems), problems)

    def test_infra_red_retried_green_passes(self):
        snap = green()
        cell_job(snap, 1, 'base-offline').update(conclusion='failure', flake='runner-disk')
        retry = run(3, 'script', ['base-offline'], grep='base-offline', created='2026-10-01T05:00:00Z')
        snap['runs'].append(retry)
        ok, problems = self.grade(snap)
        self.assertTrue(ok, problems)
        _, _, rows, cells, skipped = ev.grade(snap, MATRIX)
        text = ev.render(snap, True, [], rows, cells, skipped)
        self.assertIn('1#1 runner-disk', text)

    def test_rerun_attempt_in_same_run_counts(self):
        snap = green()
        cell_job(snap, 1, 'kde').update(conclusion='failure', flake='kvm-unavailable')
        snap['runs'][0]['jobs'].append(job('kde', 999, attempt=2))
        ok, problems = self.grade(snap)
        self.assertTrue(ok, problems)

    def test_unexplained_red_fails_even_when_retry_is_green(self):
        snap = green()
        cell_job(snap, 1, 'kde').update(conclusion='failure')
        snap['runs'][0]['jobs'].append(job('kde', 999, attempt=2))
        ok, problems = self.grade(snap)
        self.assertFalse(ok)
        self.assertTrue(any('unexplained red' in p for p in problems), problems)

    def test_matrix_without_offline_or_bitlocker_cell_fails(self):
        matrix = '\n'.join(l for l in MATRIX.splitlines() if 'offline=on' not in l and 'bitlocker=on' not in l)
        snap = green()
        ok, problems = self.grade(snap, matrix)
        self.assertFalse(ok)
        self.assertIn('matrix has no offline=on cell (M2.3)', problems)
        self.assertIn('matrix has no bitlocker=on cell (M3.2)', problems)

    def test_render_names_sha_runs_and_verdict(self):
        snap = green()
        ok, problems, rows, cells, skipped = ev.grade(snap, MATRIX)
        text = ev.render(snap, ok, problems, rows, cells, skipped)
        self.assertIn(SHA, text)
        self.assertIn('**Verdict:** GREEN', text)
        self.assertIn('https://github.com/tuna-os/wootc/actions/runs/1', text)
        self.assertIn('base-bitlocker, base-offline', text)
        self.assertIn('base-phase3', text)

    def test_cli_grade_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            m = Path(d, 'matrix.tsv')
            m.write_text(MATRIX)
            for snap, code in ((green(), 0), ({**green(), 'runs': green()['runs'][:1]}, 1)):
                s = Path(d, 'snap.json')
                s.write_text(json.dumps(snap))
                r = subprocess.run([sys.executable, str(ROOT / 'tools/release/matrix-evidence.py'), 'grade',
                                    str(s), '--matrix', str(m)], capture_output=True, text=True)
                self.assertEqual(r.returncode, code, r.stdout + r.stderr)


class WorkflowContract(unittest.TestCase):
    """The grader mirrors e2e-matrix.yml. Hold the two together."""

    wf = (ROOT / '.github/workflows/e2e-matrix.yml').read_text()

    def test_run_name_matches_the_grader(self):
        m = re.search(r'^run-name: "(.*)"$', self.wf, re.M)
        self.assertIsNotNone(m, 'e2e-matrix.yml must set run-name')
        expr = m.group(1)
        self.assertIn("${{ inputs.tier }}", expr)
        self.assertIn("inputs.gui_install && 'gui' || 'script'", expr)
        self.assertIn("format(', grep={0}', inputs.grep)", expr)
        for tier in ('smoke', 'full'):
            for mode in ('script', 'gui'):
                for grep in ('', 'kde'):
                    title = (expr.replace('${{ inputs.tier }}', tier)
                             .replace("${{ inputs.gui_install && 'gui' || 'script' }}", mode)
                             .replace("${{ inputs.grep && format(', grep={0}', inputs.grep) || '' }}",
                                      f', grep={grep}' if grep else ''))
                    self.assertEqual(ev.run_mode({'display_title': title}), (tier, mode, grep))

    def test_plan_step_and_grader_agree_on_the_full_tier(self):
        body = re.search(r"<<'EOF' >> \"\$GITHUB_OUTPUT\"\n(.*?)\n\s*EOF\n", self.wf, re.S).group(1)
        lines = body.splitlines()
        indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
        code = '\n'.join(l[indent:] for l in lines)
        env = {k: v for k, v in os.environ.items() if k != 'INCLUDE_PHASE3'}
        r = subprocess.run([sys.executable, '-c', code, 'full', ''], cwd=ROOT, env=env,
                           capture_output=True, text=True, check=True)
        planned = json.loads(r.stdout.split('matrix=', 1)[1])['include']
        cells, _ = ev.parse_matrix((ROOT / 'tests/e2e/matrix.tsv').read_text())
        self.assertEqual([c['name'] for c in planned], [c['name'] for c in cells])
        for p, c in zip(planned, cells):
            self.assertEqual(p['bitlocker'] == 'on', c['bitlocker'])
            self.assertEqual(p['filesystem'], c['filesystem'])

    def test_gui_guard_matches_the_workflow(self):
        guard = re.search(r'^\s*gui_install: \$\{\{ (.*) \}\}$', self.wf, re.M).group(1)
        self.assertIn("matrix.bitlocker != 'on'", guard)
        self.assertIn("matrix.filesystem == ''", guard)
        # The offline axis (#217) adds its own exclusion to the guard. When it
        # does, gui_applies must already drop offline cells.
        self.assertFalse(ev.gui_applies({'bitlocker': False, 'filesystem': '', 'offline': True}))


if __name__ == '__main__':
    unittest.main()
