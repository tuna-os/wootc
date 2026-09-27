#!/usr/bin/env python3
"""The coverage gate must fail on absent, invalid, or insufficient measurements."""
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('coverage_report', ROOT / 'tests/coverage-report.py')
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


class CoverageGate(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.config = json.loads((ROOT / '.coverage-thresholds.json').read_text())
        for module in self.config['modules']:
            self.write(module, 1)

    def write(self, module, count):
        (self.directory / (module['name'] + '.out')).write_text(
            f"mode: atomic\n{module['module']}/file.go:1.1,1.10 10 {count}\n")

    def cli(self):
        return subprocess.run(['python3', str(ROOT / 'tests/coverage-report.py'), str(self.directory)],
            text=True, capture_output=True, env={key: value for key, value in os.environ.items()
                if key not in ('WOOTC_COVERAGE_BASE_SHA', 'GITHUB_STEP_SUMMARY')})

    def test_actual_gate_rejects_uncovered_measurement_and_retains_totals(self):
        self.assertEqual(self.cli().returncode, 0)
        for module in self.config['modules']:
            self.write(module, 0)
        result = self.cli()
        self.assertEqual(result.returncode, 1, result.stderr)
        evidence = json.loads((self.directory / 'summary.json').read_text())
        self.assertEqual(evidence['covered'], 0)
        self.assertFalse(evidence['thresholdPassed'])

    def test_missing_module_cannot_satisfy_project_gate(self):
        (self.directory / 'fisherman-core.out').unlink()
        self.assertNotEqual(self.cli().returncode, 0)

    def test_measured_module_cannot_be_omitted_from_denominator(self):
        self.config['modules'].pop()
        with self.assertRaisesRegex(ValueError, 'unconfigured'):
            reporter.generate(self.directory, self.config)
        self.config['modules'].append(dict(self.config['modules'][0]))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            reporter.generate(self.directory, self.config)

    def test_gate_weights_statements_instead_of_averaging_packages(self):
        module = self.config['modules'][0]
        (self.directory / (module['name'] + '.out')).write_text(
            f"mode: atomic\n{module['module']}/file.go:1.1,1.10 100 0\n")
        evidence = reporter.generate(self.directory, self.config)
        self.assertEqual(evidence['covered'], 20)
        self.assertEqual(evidence['statements'], 120)
        self.assertFalse(evidence['thresholdPassed'])

    def test_exact_threshold_is_enforced(self):
        self.config['minimumStatementPercent'] = 100
        self.assertTrue(reporter.generate(self.directory, self.config)['thresholdPassed'])
        self.write(self.config['modules'][0], 0)
        self.assertFalse(reporter.generate(self.directory, self.config)['thresholdPassed'])

    def test_invalid_or_empty_profile_cannot_pass(self):
        module = self.config['modules'][0]
        row = f"{module['module']}/file.go:1.1,1.10 10 1\n"
        for body in ['mode: count\n' + row, 'mode: atomic\n', 'mode: atomic\ninvalid\n',
            'mode: atomic\n' + row + row, 'mode: atomic\nother/file.go:1.1,1.10 10 1\n',
            f"mode: atomic\n{module['module']}/../file.go:1.1,1.10 10 1\n",
            f"mode: atomic\n{module['module']}/file.go:2.1,1.10 10 1\n"]:
            with self.subTest(body=body):
                (self.directory / (module['name'] + '.out')).write_text(body)
                self.assertNotEqual(self.cli().returncode, 0)

    def test_real_go_zero_statement_block_does_not_inflate_measurement(self):
        module = self.config['modules'][0]
        with (self.directory / (module['name'] + '.out')).open('a') as stream:
            stream.write(f"{module['module']}/empty.go:2.1,2.1 0 1\n")
        evidence = reporter.generate(self.directory, self.config)
        self.assertEqual(evidence['statements'], 30)
        self.assertEqual(evidence['covered'], 30)

    def test_actual_fast_entry_point_rejects_success_without_new_profiles(self):
        fixture = self.directory / 'repo'
        (fixture / 'tests').mkdir(parents=True)
        for name in ('run.sh', 'coverage-report.py'):
            shutil.copy(ROOT / 'tests' / name, fixture / 'tests' / name)
        shutil.copy(ROOT / '.coverage-thresholds.json', fixture)
        for directory in ('app', 'fisherman/tui', 'fisherman/fisherman'):
            (fixture / directory).mkdir(parents=True)
        commands = fixture / 'commands'
        commands.mkdir()
        for name in ('bats', 'pwsh', 'go'):
            path = commands / name
            path.write_text('#!/bin/sh\nexit 0\n')
            path.chmod(0o755)
        output = fixture / 'coverage'
        output.mkdir()
        # A cached success must not replace a measurement that never happened.
        for module in self.config['modules']:
            (output / (module['name'] + '.out')).write_text(
                f"mode: atomic\n{module['module']}/file.go:1.1,1.10 10 1\n")
        (output / 'summary.json').write_text('{"thresholdPassed":true}')
        environment = dict(os.environ)
        environment.update(PATH=str(commands) + os.pathsep + environment['PATH'],
            WOOTC_COVERAGE_DIR=str(output), GOTMPDIR=str(fixture / 'go-temp'))
        environment.pop('WOOTC_COVERAGE_BASE_SHA', None)
        environment.pop('GITHUB_STEP_SUMMARY', None)
        result = subprocess.run(['bash', str(fixture / 'tests/run.sh'), 'fast'],
            text=True, capture_output=True, env=environment)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Coverage gate failed', result.stderr)
        self.assertFalse((output / 'summary.json').exists())
        self.assertFalse(any(output.glob('*.out')))

    def test_changed_lines_use_real_diff_and_require_all_blocks_on_a_line(self):
        fixture = self.directory / 'git'
        (fixture / 'app').mkdir(parents=True)
        source = fixture / 'app/file.go'
        source.write_text('one\ntwo\nthree\nfour\n')
        subprocess.run(['git', 'init', '-q', str(fixture)], check=True)
        subprocess.run(['git', 'add', '.'], cwd=fixture, check=True)
        commit = ['git', '-c', 'user.name=Coverage test', '-c', 'user.email=test@example.invalid',
            'commit', '-qm', 'fixture']
        subprocess.run(commit, cwd=fixture, check=True)
        base = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=fixture, text=True).strip()
        source.write_text('one\nTWO\nTHREE\nfour\n')
        subprocess.run(['git', 'add', '.'], cwd=fixture, check=True)
        subprocess.run(commit, cwd=fixture, check=True)
        previous = reporter.ROOT
        reporter.ROOT = fixture
        self.addCleanup(setattr, reporter, 'ROOT', previous)
        module = self.config['modules'][0]
        (self.directory / (module['name'] + '.out')).write_text(
            f"mode: atomic\n{module['module']}/file.go:2.1,2.10 1 1\n"
            f"{module['module']}/file.go:3.1,3.10 1 1\n"
            f"{module['module']}/file.go:3.11,3.20 1 0\n")
        evidence = reporter.generate(self.directory, self.config, base)
        self.assertEqual(evidence['patch']['instrumentedChangedLines'], 2)
        self.assertEqual(evidence['patch']['covered'], 1)
        self.assertEqual(evidence['patch']['percent'], 50)
        self.assertTrue(evidence['thresholdPassed'])  # Patch target stays informational.
        with self.assertRaises(subprocess.CalledProcessError):
            reporter.generate(self.directory, self.config, 'not-a-real-base')


if __name__ == '__main__':
    unittest.main()
