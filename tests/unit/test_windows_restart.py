#!/usr/bin/env python3
"""Exercise actual typed boot and transport wait consumers without a VM."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
LIB=ROOT/'tests/e2e/lib'
PARSER=ROOT/'tests/e2e/windows-boot-receipt.py'
OLD='134000000000000000'
NEW='134000001000000000'
def receipt(token=OLD, **kwargs):
    return json.dumps(dict(schemaVersion=1,os='Windows_NT',bootId=token,**kwargs))

class RestartTests(unittest.TestCase):
    def shell(self,body,module=None,**env):
        with tempfile.TemporaryDirectory() as tmp:
            calls=Path(tmp)/'calls'; calls.touch()
            count=Path(tmp)/'count'; count.write_text('0')
            clock=Path(tmp)/'clock'; clock.write_text('100')
            prefix=f'''set -Eeuo pipefail
date() {{ cat "$CLOCK"; }}
sleep() {{ printf '%s' "$(( $(cat "$CLOCK") + $1 ))" > "$CLOCK"; }}
source '{module or LIB/'qga-transport.sh'}'
wootc_qga_boot_configure '{PARSER}'
wootc_phase_boundary() {{ :; }}
step() {{ :; }}; info() {{ echo "$*"; }}; warn() {{ echo "$*"; }}
pass() {{ echo "PASS $*"; }}; infra_fail() {{ echo "INFRA $*"; }}
qga_call() {{
 printf '%s\\n' "$1" >> "$CALLS"
 case "$1" in
 powershell)
 if [[ "$2" == *LastBootUpTime* ]]; then
  count=$(cat "$COUNT"); printf '%s' "$((count+1))" > "$COUNT"
  if [ "$count" -eq 0 ]; then printf '%s' "$BEFORE"; return "$BEFORE_RC"; fi
  printf '%s' "$AFTER"; return "$AFTER_RC"
 fi
 if [[ "$2" == *shutdown.exe* ]]; then echo restart >> "$CALLS"; printf '%s' "$REQUEST_REPLY"; return "$REQUEST_RC"; fi
 printf '%s' "$IDENTITY"; return "$IDENTITY_RC" ;;
 exec) printf '%s' "$LINUX"; return "$LINUX_RC" ;;
 ping) return "$PING_RC" ;;
 esac
}}
'''
            defaults=dict(BEFORE=receipt(),AFTER=receipt(NEW),BEFORE_RC='0',AFTER_RC='0',
                          REQUEST_RC='0',REQUEST_REPLY='windows-restart-requested',IDENTITY='Windows_NT',IDENTITY_RC='0',LINUX='',LINUX_RC='1',PING_RC='0')
            result=subprocess.run(['bash','-c',prefix+body],text=True,capture_output=True,timeout=4,
                                  env={**os.environ,**defaults,**env,'CALLS':str(calls),'COUNT':str(count),'CLOCK':str(clock)})
            return result,calls.read_text(),int(count.read_text())

    def test_changed_positive_boot_allows_one_restart(self):
        result,calls,count=self.shell('qga_restart_windows test 2; echo COMPLETED')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('COMPLETED',result.stdout)
        self.assertEqual(calls.splitlines().count('restart'),1)
        self.assertEqual(count,2)
        self.assertNotIn('ping',calls)

    def test_uninterrupted_windows_and_agent_restart_cannot_prove_reboot(self):
        result,calls,count=self.shell('qga_restart_windows test 1; echo COMPLETED',AFTER=receipt())
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('COMPLETED',result.stdout)
        self.assertNotIn('PASS',result.stdout)
        self.assertEqual(calls.splitlines().count('restart'),1)
        self.assertGreaterEqual(count,2)

    def test_unknown_baseline_refuses_request(self):
        for value,status in [(receipt(),'7'),('','0'),('null','0'),(receipt().replace('Windows_NT','Linux'),'0'),
                             (receipt()+ '\nnoise','0')]:
            result,calls,count=self.shell('qga_restart_windows test 1; echo COMPLETED',BEFORE=value,BEFORE_RC=status)
            self.assertNotEqual(result.returncode,0)
            self.assertNotIn('restart',calls)
            self.assertEqual(count,1)

    def test_failed_new_boot_token_command_never_establishes_return(self):
        result,calls,count=self.shell('qga_restart_windows test 1; echo COMPLETED',AFTER_RC='7')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('PASS',result.stdout)
        self.assertNotIn('COMPLETED',result.stdout)
        self.assertEqual(calls.splitlines().count('restart'),1)

    def test_removed_command_status_guard_mutant_accepts_failed_facts(self):
        source=(LIB/'qga-transport.sh').read_text()
        start=source.index('qga_windows_boot_observe() {')
        end=source.index('qga_wait_reboot() {',start)
        section=source[start:end]
        guard="' 2>/dev/null) || return 1"
        self.assertIn(guard,section)
        with tempfile.TemporaryDirectory() as tmp:
            mutant=Path(tmp)/'mutant.sh'
            mutant.write_text(source[:start]+section.replace(guard,"' 2>/dev/null || true)",1)+source[end:])
            broken,_,_=self.shell('qga_restart_windows test 1; echo COMPLETED',module=mutant,AFTER_RC='7')
            self.assertEqual(broken.returncode,0,broken.stderr)
            self.assertIn('COMPLETED',broken.stdout)

    def test_failed_request_is_not_replayed_and_does_not_poll(self):
        result,calls,count=self.shell('qga_restart_windows test 1; echo COMPLETED',REQUEST_RC='7')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(calls.splitlines().count('restart'),1)
        self.assertEqual(count,1)

    def test_successful_request_without_exact_ack_does_not_poll(self):
        for reply in ['', 'unknown', 'windows-restart-requested\nnoise']:
            result,calls,count=self.shell('qga_restart_windows test 1; echo COMPLETED',REQUEST_REPLY=reply)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(calls.splitlines().count('restart'),1)
            self.assertEqual(count,1)
            self.assertNotIn('COMPLETED',result.stdout)

    def test_invalid_deadlines_and_missing_baseline_refuse_without_guest_calls(self):
        for body in ['qga_restart_windows test 0','qga_restart_windows test -1','qga_restart_windows test bad',
                     'qga_wait_reboot test','qga_wait test 0','qga_wait_down test 0']:
            result,calls,count=self.shell(body)
            self.assertEqual(result.returncode,2,(body,result.stderr))
            self.assertEqual(calls,'')
            self.assertEqual(count,0)

    def test_failed_identity_with_uninterrupted_live_windows_is_not_departure(self):
        result,_,_=self.shell('qga_wait_down Linux 1; echo DEPARTED',IDENTITY_RC='7')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('DEPARTED',result.stdout)
        self.assertIn('unknown',result.stdout)

    def test_departure_transport_loss_is_not_reboot_or_windows_return(self):
        result,_,_=self.shell('qga_wait_down Linux 1; echo "$WOOTC_QGA_DEPARTURE"',IDENTITY_RC='7',PING_RC='42')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('transport-unavailable',result.stdout)
        self.assertNotIn('PASS',result.stdout)
        result,_,_=self.shell('qga_wait_down Linux 1; echo "$WOOTC_QGA_DEPARTURE"',IDENTITY_RC='7',LINUX='Linux',LINUX_RC='0')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('linux',result.stdout)

    def test_actual_blocking_runtime_obeys_whole_deadlines(self):
        for method in ['qga_restart_windows test 1','qga_wait_reboot test '+OLD+' 1','qga_wait_down test 1','qga_wait test 1']:
            with tempfile.TemporaryDirectory() as tmp:
                runtime=Path(tmp)/'runtime'
                runtime.write_text('#!/bin/bash\nsleep 20\necho Windows_NT\n'); runtime.chmod(0o755)
                script=f'''set -Eeuo pipefail
source '{LIB/'qga-transport.sh'}'
wootc_qga_configure '{runtime}' owned /owned/qga.py
wootc_qga_boot_configure '{PARSER}'
wootc_phase_boundary() {{ :; }}
step() {{ :; }}; info() {{ :; }}; pass() {{ echo PASSED; }}; infra_fail() {{ echo "$*"; }}
{method}
echo COMPLETED
'''
                result=subprocess.run(['bash','-c',script],text=True,capture_output=True,timeout=3)
                self.assertNotEqual(result.returncode,0,method)
                self.assertNotIn('COMPLETED',result.stdout)
                self.assertNotIn('PASSED',result.stdout)

    def test_boot_parser_refuses_duplicate_unknown_and_typed_facts(self):
        spec=importlib.util.spec_from_file_location('boot_receipt',PARSER)
        parser=importlib.util.module_from_spec(spec); spec.loader.exec_module(parser)
        self.assertEqual(parser.parse(receipt()),OLD)
        invalid=['','null','[]',receipt().replace('"schemaVersion": 1','"schemaVersion": true'),
                 receipt().replace('"bootId": "'+OLD+'"','"bootId": 134000000000000000'),
                 receipt().replace('"bootId": "'+OLD+'"','"bootId": "0'+OLD+'"'),
                 receipt().replace('"bootId": "'+OLD+'"','"bootId": "'+OLD+'", "bootId": "'+NEW+'"'),
                 receipt().replace('Windows_NT','Other'),receipt(extra=True)]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises((ValueError,TypeError)):
                parser.parse(value)

    def windows_wait(self):
        source=(ROOT/'tests/e2e/run-e2e.sh').read_text()
        return 'qga_wait_windows() {'+source.split('qga_wait_windows() {',1)[1].split('\n# Cached Windows accounts',1)[0]

    def test_actual_uninstall_consumer_does_not_publish_return_without_new_boot(self):
        source=(ROOT/'tests/e2e/run-e2e.sh').read_text()
        tail=source.split('step "Uninstall: rebooting to prove Windows boots cleanly with no wootc chain..."',1)[1].split('\n}',1)[0]
        body='sleep() { printf 1000 > "$CLOCK"; }; consumer() {'+tail+'\n}; consumer'
        unchanged,_,_=self.shell(body,AFTER=receipt())
        self.assertNotEqual(unchanged.returncode,0)
        self.assertNotIn('machine is restored',unchanged.stdout)
        changed,_,_=self.shell(body)
        self.assertEqual(changed.returncode,0,changed.stderr)
        self.assertIn('machine is restored',changed.stdout)

    def test_windows_wait_requires_positive_identity_even_when_ping_lives(self):
        result,_,_=self.shell(self.windows_wait()+'\nqga_wait_windows 1; echo RETURNED',IDENTITY_RC='7')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('RETURNED',result.stdout)
        self.assertNotIn('PASS',result.stdout)

    def test_actual_deployer_return_waits_without_requesting_another_restart(self):
        source=(ROOT/'tests/e2e/run-e2e.sh').read_text()
        start=source.index('if ! qga_windows_probe; then',source.index('# Only wait for the Windows return'))
        consumer=source[start:source.index('\nfi',start)+3]
        for identity_status in ['0','7']:
            body='''qga_wait_windows() { echo WAIT-WINDOWS; return "$WAIT_RC"; }
qga_restart_windows() { echo UNEXPECTED-RESTART; return 0; }
qga_wait_reboot() { echo UNEXPECTED-REBOOT-WAIT; return 0; }
'''+consumer+'\necho RETURNED'
            result,calls,_=self.shell(body,IDENTITY_RC=identity_status,WAIT_RC='0')
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual('WAIT-WINDOWS' in result.stdout,identity_status=='7')
            self.assertNotIn('UNEXPECTED',result.stdout)
            self.assertNotIn('restart',calls)
        refused,_,_=self.shell(body,IDENTITY_RC='7',WAIT_RC='1')
        self.assertNotEqual(refused.returncode,0)
        self.assertNotIn('RETURNED',refused.stdout)

    def test_failed_cpu_stdout_is_ignored_and_low_cpu_never_proves_setup_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            runtime=Path(tmp)/'runtime'
            runtime.write_text('#!/bin/bash\nprintf "0.0 /usr/bin/qemu-system-x86_64\\n"\nexit "$CPU_RC"\n')
            runtime.chmod(0o755)
            body=self.windows_wait()+f'''\nDOCKER='{runtime}'; CONTAINER_NAME=owned
qga_windows_probe() {{ printf '%s' "$(( $(cat "$CLOCK") + 300 ))" > "$CLOCK"; return 1; }}
qga_wait_windows 2000
'''
            failed,_,_=self.shell(body,CPU_RC='7')
            self.assertNotEqual(failed.returncode,0)
            self.assertIn('CPU observation failed',failed.stdout)
            self.assertNotIn('repeated low CPU',failed.stdout)
            low,_,_=self.shell(body,CPU_RC='0')
            self.assertNotEqual(low.returncode,0)
            self.assertIn('repeated low CPU',low.stdout)
            self.assertNotIn('prompt',low.stdout)
            self.assertNotIn('PASS',low.stdout)

    def test_removed_cpu_status_guard_mutant_stops_before_real_windows_arrives(self):
        with tempfile.TemporaryDirectory() as tmp:
            runtime=Path(tmp)/'runtime'
            runtime.write_text('#!/bin/bash\nprintf "0.0 /usr/bin/qemu-system-x86_64\\n"\nexit 7\n'); runtime.chmod(0o755)
            function=self.windows_wait()
            old="'ps -eo pcpu,args' 2>/dev/null); then"
            self.assertIn(old,function)
            suffix=f'''\nDOCKER='{runtime}'; CONTAINER_NAME=owned; probes=0
qga_windows_probe() {{
 probes=$((probes+1))
 printf '%s' "$(( $(cat "$CLOCK") + 300 ))" > "$CLOCK"
 [ "$probes" -ge 6 ]
}}
qga_wait_windows 2700
echo RETURNED
'''
            fixed,_,_=self.shell(function+suffix)
            self.assertEqual(fixed.returncode,0,fixed.stderr)
            self.assertIn('RETURNED',fixed.stdout)
            broken,_,_=self.shell(function.replace(old,"'ps -eo pcpu,args' 2>/dev/null || true); then",1)+suffix)
            self.assertNotEqual(broken.returncode,0)
            self.assertNotIn('RETURNED',broken.stdout)
            self.assertIn('repeated low CPU',broken.stdout)

    def test_actual_cpu_diagnostic_is_bounded_by_remaining_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            runtime=Path(tmp)/'runtime'
            runtime.write_text('#!/bin/bash\nsleep 20\nprintf "0.0 /usr/bin/qemu-system-x86_64\\n"\n'); runtime.chmod(0o755)
            body=self.windows_wait()+f'''\nDOCKER='{runtime}'; CONTAINER_NAME=owned
qga_windows_probe() {{ printf '%s' "$(( $(cat "$CLOCK") + 900 ))" > "$CLOCK"; return 1; }}
qga_wait_windows 901
'''
            result,_,_=self.shell(body)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('CPU observation failed',result.stdout)
            self.assertNotIn('repeated low CPU',result.stdout)

    def test_actual_windows_wait_blocking_identity_fits_whole_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            runtime=Path(tmp)/'runtime'
            runtime.write_text('#!/bin/bash\nsleep 20\necho Windows_NT\n'); runtime.chmod(0o755)
            script=f'''set -Eeuo pipefail
source '{LIB/'qga-transport.sh'}'
wootc_qga_configure '{runtime}' owned /owned/qga.py
wootc_phase_boundary() {{ :; }}
step() {{ :; }}; pass() {{ echo PASSED; }}; infra_fail() {{ echo "$*"; }}
{self.windows_wait()}
qga_wait_windows 1
echo RETURNED
'''
            result=subprocess.run(['bash','-c',script],text=True,capture_output=True,timeout=3)
            self.assertNotEqual(result.returncode,0)
            self.assertNotIn('RETURNED',result.stdout)
            self.assertNotIn('PASSED',result.stdout)

    def test_same_boot_failure_records_infrastructure_not_product(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger=Path(tmp)/'results.jsonl'
            body=f'''source '{LIB/'results.sh'}'
source '{LIB/'result-runner.sh'}'
RED= NC= GREEN= YELLOW= BLUE=
RUN_ID=controlled-restart
WOOTC_FAILURE_LEDGER='{tmp}/failures.log'
WOOTC_RESULT_LEDGER='{ledger}'
wootc_result_init "$WOOTC_RESULT_LEDGER" "$RUN_ID" full-cycle
qga_restart_windows test 1
'''
            result,_,_=self.shell(body,AFTER=receipt())
            self.assertNotEqual(result.returncode,0)
            rows=[json.loads(line) for line in ledger.read_text().splitlines()]
            failures=[r for r in rows if r['kind']=='failure']
            self.assertEqual(len(failures),1)
            self.assertEqual(failures[0]['domain'],'infrastructure')
            self.assertFalse(any(r['kind']=='assertion' for r in rows))

    def test_restart_phase_clear_happens_in_actual_caller(self):
        result,_,_=self.shell(f'''source '{ROOT}/tests/e2e/steps.sh'
source '{ROOT}/tests/e2e/phase-ledger.sh'
WOOTC_CURRENT_PHASE_ID=fisherman; WOOTC_PHASE_CARRY=stale
qga_restart_windows test 2
[ -z "$WOOTC_CURRENT_PHASE_ID$WOOTC_PHASE_CARRY" ]
''')
        self.assertEqual(result.returncode,0,result.stderr)

if __name__=='__main__':
    unittest.main()
