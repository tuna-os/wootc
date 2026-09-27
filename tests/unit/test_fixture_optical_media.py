import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

root = Path(__file__).resolve().parents[2]
source = root / 'tests/e2e/verify-optical-detach-receipt.py'
spec = importlib.util.spec_from_file_location('optical_receipt', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
image = '/storage/win11x64.iso'
row = dict(device='cdrom9', qdev='/machine/peripheral-anon/device[0]', type='ide-cd', bootIndex=2, medium=image)
receipt = dict(schema=1, before=[row], removed=[row['qdev']], after=[dict(row, medium=None)], empty=True)
boot = dict(schemaVersion=1, os='Windows_NT', bootId='134350000000000000')


class OpticalReceiptTests(unittest.TestCase):
    def test_exact_owned_removal_and_previously_empty_optical(self):
        self.assertTrue(module.validate(json.dumps(receipt), {image})['empty'])
        empty = copy.deepcopy(receipt)
        empty['before'][0]['medium'] = None
        empty['removed'] = []
        self.assertTrue(module.validate(json.dumps(empty), {image})['empty'])

    def test_no_empty_proxy_accepts_unremoved_unknown_changed_or_ambiguous_media(self):
        for change in ['retained', 'unknown', 'changed', 'missing', 'duplicate', 'no-removed', 'schema-bool']:
            value = copy.deepcopy(receipt)
            if change == 'retained':
                value['after'][0]['medium'] = image
            elif change == 'unknown':
                value['before'][0]['medium'] = '/foreign.iso'
            elif change == 'changed':
                value['after'][0]['bootIndex'] = 3
            elif change == 'missing':
                value['after'] = []
            elif change == 'duplicate':
                value['after'].append(dict(value['after'][0], qdev='/different'))
            elif change == 'no-removed':
                value['removed'] = []
            else:
                value['schema'] = True
            with self.subTest(change=change), self.assertRaises(ValueError):
                module.validate(json.dumps(value), {image})
        with self.assertRaises(ValueError):
            module.validate('{"schema":1,"schema":1}', {image})

    def test_current_empty_mode_requires_both_empty_inventories_no_eject_and_previous_identity(self):
        current=copy.deepcopy(receipt)
        current.update(operation='check-empty',removed=[])
        current['before'][0]['medium']=None
        prior=json.dumps(receipt)
        self.assertTrue(module.validate(json.dumps(current),{image},'check-empty',prior)['empty'])
        for case in ('reinserted','ejected','wrong-operation','changed-prior','missing-prior'):
            value=copy.deepcopy(current)
            if case == 'reinserted':
                value['before'][0]['medium']=image
            elif case == 'ejected':
                value['removed']=[row['qdev']]
            elif case == 'wrong-operation':
                value['operation']='detach'
            elif case == 'changed-prior':
                value['before'][0]['bootIndex']=3
                value['after'][0]['bootIndex']=3
            with self.subTest(case=case), self.assertRaises(ValueError):
                module.validate(json.dumps(value),{image},'check-empty',None if case == 'missing-prior' else prior)
        with self.assertRaises(ValueError):
            module.validate(json.dumps(receipt),{image},'check-empty',prior)

    def test_actual_preactivation_caller_observes_fresh_read_only_media_and_same_current_boot(self):
        for case in ('valid','unchanged-boot','wrong-os','reinserted','changed-after','changed-optical','query-failure','expired'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as scratch:
                folder=Path(scratch)
                scripts=folder/'scripts'
                scripts.mkdir()
                (scripts/'lib').mkdir()
                for name in ('verify-fixture-boot-observation.py','verify-optical-detach-receipt.py'):
                    shutil.copyfile(root/'tests/e2e'/name,scripts/name)
                shutil.copyfile(root/'tests/e2e/lib/fixture-optical-media.sh',scripts/'lib/fixture-optical-media.sh')
                (scripts/'qmp-optical-media.py').write_text('# public source fixture')
                (folder/'optical-removal.json').write_text(json.dumps(receipt))
                (folder/'optical-windows-after.json').write_text(json.dumps(boot))
                now=dict(boot,bootId='134350000000000001')
                if case == 'unchanged-boot':
                    now=boot
                elif case == 'wrong-os':
                    now=dict(now,os='Linux')
                (folder/'now').write_text(json.dumps(now))
                (folder/'later').write_text(json.dumps(dict(now,bootId='134350000000000002') if case == 'changed-after' else now))
                current=copy.deepcopy(receipt)
                current.update(operation='check-empty',removed=[])
                current['before'][0]['medium']=None
                if case == 'changed-optical':
                    current['before'][0]['bootIndex']=3
                    current['after'][0]['bootIndex']=3
                (folder/'current').write_text(json.dumps(current))
                script=r"""
source "$SCRIPT_DIR/lib/fixture-optical-media.sh"
fixture_capture_windows_boot() {
    if [[ "$1" == *preactivation-after.json ]]; then cp "$ARTIFACT_DIR/later" "$1"; else cp "$ARTIFACT_DIR/now" "$1"; fi
}
fixture_qmp_optical_command() {
    [[ "$1" == check-empty ]] || return 99
    printf '%s\n' "$1" >> "$ARTIFACT_DIR/qmp-read-calls"
    if [[ "$CASE" == query-failure ]]; then cat "$ARTIFACT_DIR/current"; return 1; fi
    [[ "$CASE" != reinserted ]] || return 1
    cat "$ARTIFACT_DIR/current"
}
deadline=$(( $(date +%s) + 30 ))
[[ "$CASE" != expired ]] || deadline=$(( $(date +%s) - 1 ))
fixture_verify_windows_boot_after_detach "$deadline"
"""
                result=subprocess.run(['bash','-c',script],env={'SCRIPT_DIR':str(scripts),'ARTIFACT_DIR':scratch,'RUN_ID':'run-1','CASE':case,'PATH':'/usr/bin:/bin'},capture_output=True)
                self.assertEqual(result.returncode==0,case=='valid',result.stderr)
                calls=(folder/'qmp-read-calls').read_text().splitlines() if (folder/'qmp-read-calls').exists() else []
                self.assertEqual(calls,[] if case in ('unchanged-boot','wrong-os','expired') else ['check-empty'])
                if case=='valid':
                    self.assertEqual(json.loads((folder/'optical-preactivation-source-run-context.json').read_text())['operation'],'check-empty')

    def test_query_read_failure_cannot_invoke_guest_even_if_guest_would_return_valid_json(self):
        for case in ('missing','directory','empty'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as scratch:
                folder=Path(scratch)
                if case == 'directory':
                    (folder/'windows-boot-observation.ps1').mkdir()
                elif case == 'empty':
                    (folder/'windows-boot-observation.ps1').write_text('')
                script = r"""
source "$LIBRARY"
qga_powershell() {
    printf 'called\n' > "$ARTIFACT_DIR/guest-call"
    printf '%s' '{"schemaVersion":1,"os":"Windows_NT","bootId":"134350000000000000"}'
}
fixture_capture_windows_boot "$ARTIFACT_DIR/observation.json"
"""
                result=subprocess.run(['bash','-c',script],env={'LIBRARY':str(root/'tests/e2e/lib/fixture-optical-media.sh'),'SCRIPT_DIR':scratch,'ARTIFACT_DIR':scratch,'PATH':'/usr/bin:/bin'},capture_output=True)
                self.assertNotEqual(result.returncode,0)
                self.assertFalse((folder/'guest-call').exists())

    def test_actual_shell_caller_refuses_before_mutation_and_never_replays(self):
        for case in ['valid', 'wrong-before', 'qmp-failure', 'invalid-receipt', 'changed-after']:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as scratch:
                folder = Path(scratch)
                before = dict(boot, os='Linux') if case == 'wrong-before' else boot
                after = dict(boot, bootId='134350000000000001') if case == 'changed-after' else boot
                (folder/'before').write_text(json.dumps(before))
                (folder/'after').write_text(json.dumps(after))
                (folder/'receipt').write_text('{}' if case == 'invalid-receipt' else json.dumps(receipt))
                scripts=folder/'scripts'
                scripts.mkdir()
                (scripts/'lib').mkdir()
                for name in ['verify-fixture-boot-observation.py','verify-optical-detach-receipt.py']:
                    shutil.copyfile(root/'tests/e2e'/name,scripts/name)
                shutil.copyfile(root/'tests/e2e/lib/fixture-optical-media.sh',scripts/'lib/fixture-optical-media.sh')
                (scripts/'qmp-optical-media.py').write_text('# public source fixture')
                script = r'''
source "$SCRIPT_DIR/lib/fixture-optical-media.sh"
fixture_capture_windows_boot() {
    if [[ "$1" == *optical-windows-before.json ]]; then cp "$ARTIFACT_DIR/before" "$1"; else cp "$ARTIFACT_DIR/after" "$1"; fi
}
fixture_qmp_optical_command() {
    printf 'called\n' >> "$ARTIFACT_DIR/qmp-calls"
    [[ "$CASE" != qmp-failure ]] || return 1
    cat "$ARTIFACT_DIR/receipt"
}
fixture_detach_optical_media
'''
                result = subprocess.run(['bash','-c',script],env={'SCRIPT_DIR':str(scripts),'ARTIFACT_DIR':scratch,'RUN_ID':'run-1','CASE':case,'PATH':'/usr/bin:/bin'},capture_output=True)
                self.assertEqual(result.returncode == 0, case == 'valid')
                calls=(folder/'qmp-calls').read_text().splitlines() if (folder/'qmp-calls').exists() else []
                self.assertEqual(len(calls), 0 if case == 'wrong-before' else 1)
                if case == 'valid':
                    context=json.loads((folder/'optical-source-run-context.json').read_text())
                    self.assertEqual(context['runId'],'run-1')
                    self.assertEqual(context['sourceSha256'],hashlib.sha256(b'# public source fixture').hexdigest())
                    canonical=json.dumps(receipt,sort_keys=True,separators=(',',':')).encode()
                    self.assertEqual(context['canonicalObservationSha256'],hashlib.sha256(canonical).hexdigest())
                    self.assertEqual((folder/'optical-source-run-context.json').stat().st_mode & 0o777,0o600)


if __name__ == '__main__':
    unittest.main()
