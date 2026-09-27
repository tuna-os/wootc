"""Real outer/caller control flow, controlled mount/tool leaves; no mounts."""
import json
from pathlib import Path
import runpy
import shlex
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
STAGE=runpy.run_path(str(ROOT/'payload/vm-observer/stage_bundle.py'))

class OuterCallerControls(unittest.TestCase):
    def run_outer(self,fail=False,subshell=False):
        with tempfile.TemporaryDirectory(prefix='wootc-outer-call-') as temporary:
            directory=Path(temporary);bundle=directory/'bundle';STAGE['stage'](bundle)
            raw=subprocess.check_output(['python3','-I','-S','-B',str(ROOT/'tests/unit/vm_observer_receipt_fixture.py')],timeout=3)
            receipt=directory/'receipt.json';receipt.write_bytes(raw)
            # Substitute only the authenticated bundle namespace for the private
            # source fixture. Mount/preflight leaves are explicit controlled spies.
            outer=(ROOT/'payload/vm-observer/outer_install.sh').read_text().replace('/usr/lib/wootc-observer',str(bundle))
            helper=directory/'outer.sh';helper.write_text(outer)
            builder=(ROOT/'payload/builder/wootc-builder.sh').read_text()
            call=next(l.strip() for l in builder.splitlines() if l.strip().startswith('observer_install_owned "$deployment"'))
            publish=next(l.strip() for l in builder.splitlines() if l.strip().startswith('emit "$OBS_INSTALL_RECEIPT"'))
            if subshell:call=call.replace('observer_install_owned "$deployment" "$part"','OBS_INSTALL_RECEIPT=$(observer_install_owned "$deployment" "$part")')
            script='''set -eu
. "$1"
RECEIPT=$2 TRACE=$3 IPC=$4
ROOT_CONTEXT=$BASHPID
IMAGE=ghcr.io/example/image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RUN_ID=run_test123 INSTALL_ID=install_test123
trap 'printf exit >> "$TRACE.exit"' EXIT
ORIGINAL_TRAP=$(trap -p EXIT)
observer_directory() { return 0; }
observer_prepare_boot() {
 OBS_BOOT_MAJOR=8:2 OBS_BOOT_ORIGINAL=/controlled/boot OBS_BOOT_ORIGINAL_OWN=boot-own OBS_BOOT_ORIGINAL_SOURCE=boot-source OBS_BOOT_ORIGINAL_ACTIVE=true
}
observer_bind_view() {
 [ "$BASHPID" = "$ROOT_CONTEXT" ] || return 1
 row='{"filesystems":[{"source":"rootfs[/usr/lib/wootc-observer]","maj:min":"8:3"}]}'
 case "$1" in
 input) OBS_INPUT=$3 OBS_INPUT_OWN=input-own OBS_INPUT_SOURCE=input-source;;
 sysroot) OBS_SYSROOT=$3 OBS_SYSROOT_OWN=sysroot-own OBS_SYSROOT_SOURCE=sysroot-source;;
 boot) OBS_BOOT_VIEW=$3 OBS_BOOT_VIEW_OWN=boot-own OBS_BOOT_VIEW_SOURCE=boot-source;;
 proc) observer_proc_current /proc || return 1; OBS_PROC=$3 OBS_PROC_OWN=proc-own OBS_PROC_SOURCE=proc-source;;
 sys) OBS_SYS=$3 OBS_SYS_OWN=sys-own OBS_SYS_SOURCE=sys-source;;
 usr) OBS_USR=$3 OBS_USR_OWN=usr-own OBS_USR_SOURCE=usr-source;;
 *) return 1;; esac
}
observer_target_interpreter() { [ "$BASHPID" = "$ROOT_CONTEXT" ]; }
observer_release_view() {
 [ "$BASHPID" = "$ROOT_CONTEXT" ] || return 1
 [ -n "$1" ] || return 0
 [ -n "$2" ] && [ -n "$3" ] || return 1
 printf '%s\\n' "$1" >> "$TRACE"
}
timeout() {
 limit=$1;shift
 case "$1" in
 blkid) printf 11111111-1111-1111-1111-111111111111;;
 env) [ "$FAIL_TARGET" = false ] || return 1; cat "$RECEIPT";;
 *) command timeout "$limit" "$@";; esac
}
failed() { exit 99; }
emit() { printf '%s\\n' "$1" > "$IPC"; }
deployment=/controlled/deployment part=/dev/vda3
'''+f'FAIL_TARGET={str(fail).lower()}\n'+call+'\n'+publish+'''
[ -n "$OBS_INSTALL_RECEIPT" ]
[ "$OBS_BOOT_ORIGINAL_ACTIVE" = false ]
[ "$(trap -p EXIT)" = "$ORIGINAL_TRAP" ]
'''
            trace=directory/'release';ipc=directory/'ipc'
            result=subprocess.run(['/bin/bash','-c',script,'fixture',str(helper),str(receipt),str(trace),str(ipc)],capture_output=True,text=True,timeout=8)
            return result,trace.read_text().splitlines() if trace.exists() else [],ipc.read_bytes() if ipc.exists() else b'',raw

    def test_actual_outer_direct_caller_retains_context_receipt_cleanup_and_exit_trap(self):
        result,released,ipc,raw=self.run_outer()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(ipc,raw)
        self.assertEqual(len(released),7)
        self.assertTrue(released[0].endswith('/usr'))
        self.assertEqual(released[-1],'/controlled/boot')

    def test_target_refusal_cleans_all_leases_and_never_publishes(self):
        result,released,ipc,_=self.run_outer(fail=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(len(released),7)
        self.assertEqual(ipc,b'')

    def test_actual_subshell_caller_mutant_refuses_context_and_never_publishes(self):
        result,_,ipc,_=self.run_outer(subshell=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(ipc,b'')

if __name__=='__main__':unittest.main()
