import copy
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import unittest
import zipfile

ROOT = Path(__file__).parents[2]
spec = importlib.util.spec_from_file_location('soak', ROOT / 'tools/soak/ledger.py')
soak = importlib.util.module_from_spec(spec)
spec.loader.exec_module(soak)


def config():
    return {**json.loads((ROOT / 'tools/soak/config.json').read_text()), 'startDate': '2026-09-20'}


def issues():
    result = {i: {'state': 'closed', 'closed_at': '2026-09-19T00:00:00Z'} for i in [345, 211, 178, 203, 229, 230, 323]}
    result[212] = {'body': '\n'.join('- [x] ' + text for text in soak.RC_REQUIREMENTS) + '\n- [ ] **Soak starts**: wait'}
    return result


def row(day, number=1, **changes):
    return {'date': day, 'runId': number, 'runAttempt': 1, 'event': 'schedule', 'verdict': 'success',
            'eligible': True, 'shellTreeSha256': 'a' * 64, 'transportTreeSha256': 'b' * 64, **changes}


def proof_fixture():
    run = {'id': 42, 'run_attempt': 1, 'head_sha': 'a' * 40, 'run_started_at': '2026-09-20T07:00:00Z',
           'updated_at': '2026-09-20T08:00:00Z'}
    files = {}
    proof = {'schemaVersion': 1, 'shell': 'winui3', 'observer': 'windows-uia', 'runId': 42,
             'runAttempt': 1, 'sourceSha': run['head_sha'], 'processName': 'Wootc.Shell.exe',
             'processImageSha256': 'b' * 64,
             'identity': {'artifactSha256': 'b' * 64, 'shellTreeSha256': 'c' * 64, 'transportTreeSha256': 'd' * 64},
             'observations': []}
    facts = {'runId': 42, 'sourceSha': run['head_sha'], 'observer': 'linux-qga', 'uname': 'Linux',
             'sourceImage': 'image@sha256:' + 'e' * 64, 'kernel': '6.12.1', 'bridge': 'mounted'}
    files['installed-boot-observation.json'] = json.dumps(facts).encode()
    values = {'InstalledBootSource': facts['sourceImage'], 'InstalledBootKernel': facts['kernel'], 'InstalledBootBridge': facts['bridge']}
    for journey, required in soak.REQUIRED.items():
        frame = journey + '.png'
        uia = journey + '.json'
        files[frame] = b'\x89PNG\r\n\x1a\nsynthetic-test-frame'
        checks = [{'automationId': name, 'property': prop, 'expected': literal or values[name]} for name, (prop, literal) in required.items()]
        controls = [{'automationId': check['automationId'], 'visible': True, 'enabled': True, check['property']: check['expected']} for check in checks]
        files[uia] = json.dumps({'runId': 42, 'processImageSha256': 'b' * 64, 'controls': controls}).encode()
        proof['observations'].append({'journey': journey, 'capturedAt': '2026-09-20T07:30:00Z',
                                      'framebufferFile': frame, 'framebufferSha256': soak.digest(files[frame]),
                                      'uiaFile': uia, 'checks': checks})
    return run, proof, files


def archive(proof, files):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w') as out:
        out.writestr('native-gui-proof.json', json.dumps(proof))
        for name, data in files.items():
            out.writestr(name, data)
    data = stream.getvalue()
    artifact = {'id': 99, 'expired': False, 'digest': 'sha256:' + soak.digest(data),
                'workflow_run': {'id': 42, 'head_sha': 'a' * 40, 'head_branch': 'main'}}
    return data, artifact


class SoakTests(unittest.TestCase):
    def test_start_is_unset_and_prerequisites_are_required(self):
        cfg = config()
        cfg['startDate'] = None
        self.assertFalse(soak.summarize([], cfg, issues(), dt.date(2026, 9, 22))['started'])
        for change in ['open', 'missing', 'checklist', 'backdate']:
            evidence = issues()
            cfg = config()
            if change == 'open':
                evidence[345]['state'] = 'open'
            elif change == 'missing':
                cfg['prerequisiteIssues'].remove(323)
            elif change == 'checklist':
                evidence[212]['body'] += '\n- [ ] Offline setup'
            else:
                evidence[345]['closed_at'] = '2026-09-21T00:00:00Z'
            with self.subTest(change=change):
                self.assertFalse(soak.summarize([], cfg, evidence, dt.date(2026, 9, 22))['started'])

    def test_continuity_exclusion_and_identity_reset(self):
        rows = [row('2026-09-20'), row('2026-09-21', 2), row('2026-09-22', 3)]
        self.assertEqual(soak.summarize(rows, config(), issues(), dt.date(2026, 9, 23))['streak'], 3)
        for changed in [rows[:1] + rows[2:], rows[:2] + [row('2026-09-22', 3, eligible=False)],
                        rows[:2] + [row('2026-09-22', 3, shellTreeSha256='e' * 64)],
                        rows[:2] + [row('2026-09-22', 3, transportTreeSha256='f' * 64)],
                        rows[:2] + [row('2026-09-22', 3, event='workflow_dispatch')]]:
            with self.subTest(rows=changed):
                self.assertLessEqual(soak.summarize(changed, config(), issues(), dt.date(2026, 9, 23))['streak'], 1)

    def test_same_day_identity_change_and_return_cannot_hide_reset(self):
        rows = [row('2026-09-20'), row('2026-09-21', 2, shellTreeSha256='c' * 64),
                row('2026-09-21', 3)]
        self.assertEqual(soak.summarize(rows, config(), issues(), dt.date(2026, 9, 22))['streak'], 1)

    def test_unexplained_red_cannot_be_erased_by_retry(self):
        red = row('2026-09-20', verdict='failure', eligible=False)
        retry = row('2026-09-20', runAttempt=2)
        rows = [red, retry, row('2026-09-21', 2)]
        result = soak.summarize(rows, config(), issues(), dt.date(2026, 9, 22))
        self.assertFalse(result['valid'])
        self.assertEqual(result['streak'], 0)
        red['diagnosisIssue'] = 123
        result = soak.summarize(rows, config(), issues(), dt.date(2026, 9, 22))
        self.assertTrue(result['valid'])
        self.assertEqual(result['streak'], 2)

    def test_rerun_of_older_id_is_ordered_by_actual_start(self):
        rows = [row('2026-09-20', 1),
                row('2026-09-21', 10, startedAt='2026-09-21T07:00:00Z'),
                row('2026-09-21', 2, runAttempt=2, startedAt='2026-09-21T09:00:00Z',
                    verdict='failure', eligible=False, diagnosisIssue=123)]
        self.assertEqual(soak.summarize(rows, config(), issues(), dt.date(2026, 9, 22))['streak'], 0)

    def test_current_day_and_prestart_rows_do_not_count(self):
        rows = [row('2026-09-19'), row('2026-09-20', 2), row('2026-09-21', 3)]
        self.assertEqual(soak.summarize(rows, config(), issues(), dt.date(2026, 9, 21))['streak'], 1)

    def test_native_observations_bind_all_evidence(self):
        run, proof, files = proof_fixture()
        data, artifact = archive(proof, files)
        valid = soak.verify_proof(data, run, artifact)
        self.assertTrue(valid['semanticProof'])
        self.assertEqual(valid['proofArchiveSha256'], soak.digest(data))
        mutations = ['wails', 'browser', 'source', 'attempt', 'process', 'no-checks', 'hidden',
                     'wrong-value', 'missing-frame', 'stale', 'facts', 'digest', 'artifact-run']
        for mutation in mutations:
            changed, changed_files = copy.deepcopy(proof), copy.deepcopy(files)
            if mutation == 'wails': changed['shell'] = 'wails'
            elif mutation == 'browser': changed['observer'] = 'playwright'
            elif mutation == 'source': changed['sourceSha'] = 'f' * 40
            elif mutation == 'attempt': changed['runAttempt'] = 2
            elif mutation == 'process': changed['processImageSha256'] = 'f' * 64
            elif mutation == 'no-checks': changed['observations'][0]['checks'] = []
            elif mutation in {'hidden', 'wrong-value'}:
                name = changed['observations'][0]['uiaFile']
                tree = json.loads(changed_files[name])
                if mutation == 'hidden': tree['controls'][0]['visible'] = False
                else: tree['controls'][0]['name'] = 'Did not install'
                changed_files[name] = json.dumps(tree).encode()
            elif mutation == 'missing-frame': changed_files.pop(changed['observations'][0]['framebufferFile'])
            elif mutation == 'stale': changed['observations'][0]['capturedAt'] = '2026-09-19T07:30:00Z'
            elif mutation == 'facts': changed_files['installed-boot-observation.json'] = b'{}'
            data, artifact = archive(changed, changed_files)
            if mutation == 'digest': artifact['digest'] = 'sha256:' + '0' * 64
            if mutation == 'artifact-run': artifact['workflow_run']['id'] = 1
            with self.subTest(mutation=mutation), self.assertRaises((ValueError, KeyError)):
                soak.verify_proof(data, run, artifact)

    def test_actual_packaged_executable_hash_must_match_process(self):
        run, _, _ = proof_fixture()
        executable = b'MZsynthetic-unit-test-native-image'
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            archive.writestr('Wootc.Shell.exe', executable)
        data = stream.getvalue()
        artifact = {'id': 88, 'expired': False, 'digest': 'sha256:' + soak.digest(data),
                    'workflow_run': {'id': 42, 'head_sha': 'a' * 40, 'head_branch': 'main'}}
        identity = {'artifactSha256': soak.digest(executable)}
        self.assertEqual(soak.verify_product(data, run, artifact, identity)['productArtifactId'], 88)
        with self.assertRaises(ValueError):
            soak.verify_product(data, run, artifact, {'artifactSha256': '0' * 64})
        artifact['workflow_run']['head_sha'] = 'f' * 40
        with self.assertRaises(ValueError):
            soak.verify_product(data, run, artifact, identity)

    def test_collector_retains_attempts_and_rejects_job_proxy(self):
        class API:
            repo = 'tuna-os/wootc'
            def pages(self, path, key):
                if 'e2e-gui.yml/runs' in path:
                    return [{'id': 42, 'run_attempt': 2, 'status': 'completed'}]
                if path.endswith('/jobs'):
                    return [{'name': 'Wails browser acceptance', 'conclusion': 'success', 'steps': []}]
                if path.endswith('/releases'):
                    return [{'tag_name': 'auto-v1', 'body': 'https://github.com/tuna-os/wootc/actions/runs/42'}]
                raise AssertionError('Must not download a proof for a browser job: ' + path)
            def api(self, path, binary=False):
                if '/attempts/' in path:
                    attempt = int(path.rsplit('/', 1)[1])
                    return {'id': 42, 'run_attempt': attempt, 'head_sha': 'a' * 40,
                            'head_branch': 'main', 'head_repository': {'full_name': self.repo},
                            'run_started_at': '2026-09-20T07:00:00Z', 'updated_at': '2026-09-20T08:00:00Z',
                            'event': 'schedule', 'conclusion': 'failure' if attempt == 1 else 'success',
                            'html_url': 'https://github.com/tuna-os/wootc/actions/runs/42'}
                if '/compare/' in path:
                    return {'status': 'identical'}
                raise AssertionError(path)
            def issue(self, number):
                if number == 999:
                    return {'body': 'Diagnosis without matching run URL'}
                return issues()[number]
        self.assertFalse(soak.has_run_link('https://github.com/tuna-os/wootc/actions/runs/420', 'https://github.com/tuna-os/wootc/actions/runs/42'))
        cfg = config()
        cfg['diagnoses'] = {'42:1': 999}
        rows, authority = soak.collect(API(), [], cfg, dt.date(2026, 9, 22))
        self.assertEqual(len(rows), 2)
        self.assertEqual([r['verdict'] for r in rows], ['failure', 'success'])
        self.assertFalse(rows[1]['eligible'])
        self.assertIn('Actual native UI', rows[1]['reason'])
        self.assertNotIn('diagnosisIssue', rows[0])
        self.assertEqual(rows[1]['autoReleaseTag'], 'auto-v1')
        self.assertFalse(soak.summarize(rows, cfg, authority, dt.date(2026, 9, 22))['valid'])
        # Retained proof hashes survive refresh and releases cannot create proof.
        rows[1]['proofArchiveSha256'] = 'b' * 64
        refreshed, _ = soak.collect(API(), rows, cfg, dt.date(2026, 9, 22))
        self.assertEqual(refreshed[1]['proofArchiveSha256'], 'b' * 64)
        self.assertFalse(refreshed[1]['eligible'])

    def test_full_collector_binds_source_tree_binary_and_native_proof(self):
        run, proof, files = proof_fixture()
        executable = b'MZsynthetic-native-image'
        tree = [{'path': 'shell/Main.cs', 'sha': '1' * 40, 'type': 'blob'},
                {'path': 'app/serve.go', 'sha': '2' * 40, 'type': 'blob'}]
        for field, prefix in [('shellTreeSha256', 'shell/'), ('transportTreeSha256', 'app/')]:
            paths = sorted((e['path'], e['sha']) for e in tree if e['path'].startswith(prefix))
            proof['identity'][field] = soak.digest(json.dumps(paths, separators=(',', ':')).encode())
        proof['identity']['artifactSha256'] = soak.digest(executable)
        proof['processImageSha256'] = soak.digest(executable)
        for observation in proof['observations']:
            name = observation['uiaFile']
            uia = json.loads(files[name])
            uia['processImageSha256'] = soak.digest(executable)
            files[name] = json.dumps(uia).encode()
        proof_data, proof_artifact = archive(proof, files)
        proof_artifact.update(name='native-gui-soak-proof-42-1', size_in_bytes=len(proof_data))
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as out:
            out.writestr('Wootc.Shell.exe', executable)
        product_data = stream.getvalue()
        product_artifact = {**proof_artifact, 'id': 88, 'name': 'native-shell-build-42-1',
                            'digest': 'sha256:' + soak.digest(product_data), 'size_in_bytes': len(product_data)}
        run.update(status='completed', event='schedule', conclusion='success', head_branch='main',
                   head_repository={'full_name': 'tuna-os/wootc'}, html_url='https://github.com/tuna-os/wootc/actions/runs/42')
        class API:
            repo = 'tuna-os/wootc'
            def pages(self, path, key):
                if 'e2e-gui.yml/runs' in path: return [run]
                if path.endswith('/jobs'): return [{'name': soak.NATIVE_JOB, 'conclusion': 'success',
                    'steps': [{'name': name, 'conclusion': 'success'} for name in soak.NATIVE_STEPS]}]
                if path.endswith('/artifacts'): return [proof_artifact, product_artifact]
                if path.endswith('/releases'): return []
                raise AssertionError(path)
            def api(self, path, binary=False):
                if '/attempts/' in path: return run
                if '/compare/' in path: return {'status': 'identical'}
                if '/git/commits/' in path: return {'tree': {'sha': '3' * 40}}
                if '/git/trees/' in path: return {'tree': tree, 'truncated': False}
                if '/artifacts/99/zip' in path: return proof_data
                if '/artifacts/88/zip' in path: return product_data
                raise AssertionError(path)
            def issue(self, number): return issues()[number]
        rows, _ = soak.collect(API(), [], config(), dt.date(2026, 9, 22))
        self.assertTrue(rows[0]['eligible'])
        self.assertEqual(rows[0]['productArchiveSha256'], soak.digest(product_data))
        # Source-tree mutation cannot inherit the proof's transport identity.
        tree[1]['sha'] = 'f' * 40
        rows, _ = soak.collect(API(), [], config(), dt.date(2026, 9, 22))
        self.assertFalse(rows[0]['eligible'])
        self.assertIn('source tree', rows[0]['reason'])
        run['head_branch'] = 'preview'
        rows, _ = soak.collect(API(), [], config(), dt.date(2026, 9, 22))
        self.assertFalse(rows[0]['eligible'])
        self.assertIn('main', rows[0]['reason'])

    def test_workflow_uses_main_and_does_not_dispatch_vm(self):
        workflow = (ROOT / '.github/workflows/soak-ledger.yml').read_text()
        self.assertIn('ref: main', workflow)
        self.assertNotIn('gh workflow run', workflow)
        self.assertNotIn('run-e2e.sh', workflow)
        self.assertIn('cancel-in-progress: false', workflow)


if __name__ == '__main__':
    unittest.main()
