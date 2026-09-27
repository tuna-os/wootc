"""Source execution-route controls; no VM, network or host package installation."""
import json
from pathlib import Path
import runpy
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'tests/e2e/package-runtime/hosted-execute.py'))
ENV=dict(GITHUB_ACTIONS='true',RUNNER_ENVIRONMENT='github-hosted',RUNNER_OS='Linux',GITHUB_RUN_ID='1',GITHUB_RUN_ATTEMPT='1',GITHUB_SHA='a'*40)


class HostedTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.folder=Path(self.temp.name)/'owned';self.calls=[];self.qualified=True;self.fail=None

    def load(self,name):
        phase=Path(name).stem
        def action(*args,**kwargs):
            self.calls.append(phase)
            if self.fail==phase:raise InterruptedError('owned cancellation fixture')
            if phase=='qualify':
                value={'qualified':self.qualified};Path(args[1]).write_text(json.dumps(value));return value
            if phase in ('acquire','prepare'):
                args[0 if phase=='acquire' else 1].mkdir();return {}
            if phase=='launch':
                kwargs['on_started']({'fixtureOwnedIdentity':True});kwargs['on_baseline']()
                return {'packageInstallationAccepted':True}
        key={'qualify':'qualify','acquire':'acquire','prepare':'prepare','launch':'launch'}[phase]
        return {key:action,'readback':None,'acknowledge':None}

    def execute(self):return MODULE['execute'](self.folder,ENV,self.load,lambda:{})

    def test_actual_root_tool_is_protected_but_private_tmp_is_refused(self):
        self.assertTrue(MODULE['protected']('/usr/bin/true').is_file())
        path=Path(self.temp.name)/'mutable-tool';path.write_text('fixture')
        with self.assertRaises(ValueError):MODULE['protected'](path)

    def test_malformed_source_sha_refuses_before_any_stage(self):
        env=dict(ENV);env['GITHUB_SHA']='unreviewed'
        with self.assertRaises(ValueError):MODULE['execute'](self.folder,env,self.load,lambda:{})
        self.assertFalse(self.folder.exists())

    def test_fixture_route_order_is_qualification_acquisition_prepare_launch(self):
        result=self.execute();self.assertEqual(self.calls,['qualify','acquire','prepare','launch'])
        self.assertTrue(result['packageInstallationAccepted']);self.assertFalse(result['firmwareAcceptance'])

    def test_local_or_shared_runner_refuses_before_stage_creation(self):
        for field,value in [('GITHUB_ACTIONS','false'),('RUNNER_ENVIRONMENT','self-hosted'),('RUNNER_OS','Windows')]:
            env=dict(ENV);env[field]=value
            with self.assertRaises(ValueError):MODULE['execute'](self.folder,env,self.load,lambda:{})
            self.assertFalse(self.folder.exists())

    def test_unqualified_host_never_acquires_or_prepares(self):
        self.qualified=False
        with self.assertRaises(ValueError):self.execute()
        self.assertEqual(self.calls,['qualify'])
        self.assertTrue((self.folder/'artifacts'/'owned-execution.json').exists())

    def test_failed_launcher_never_claims_process_or_guest_execution(self):
        self.fail='launch'
        with self.assertRaises(InterruptedError):self.execute()
        record=json.loads((self.folder/'execution.json').read_text())
        self.assertTrue(record['executionRequested'])
        for field in ('runtimeExecuted','processStarted','guestBaselineObserved','packageInstallationAccepted'):
            self.assertFalse(record[field])

    def test_existing_owned_stage_is_never_reused_or_removed(self):
        self.folder.mkdir();(self.folder/'foreign').write_text('preserve')
        with self.assertRaises(FileExistsError):self.execute()
        self.assertEqual((self.folder/'foreign').read_text(),'preserve');self.assertEqual(self.calls,[])

    def test_cancellation_retains_failure_and_never_continues(self):
        self.fail='acquire'
        with self.assertRaises(InterruptedError):self.execute()
        self.assertEqual(self.calls,['qualify','acquire'])
        record=json.loads((self.folder/'artifacts'/'owned-execution.json').read_text())
        self.assertEqual(record['failureType'],'InterruptedError');self.assertFalse(record['runtimeExecuted'])

    def test_retention_bounds_logs_and_excludes_large_images(self):
        self.folder.mkdir();artifacts=self.folder/'artifacts';artifacts.mkdir()
        (self.folder/'serial.log').write_bytes(b'x'*300000)
        (self.folder/'cloud.qcow2').write_bytes(b'private image fixture')
        MODULE['retain'](self.folder,artifacts)
        self.assertEqual((artifacts/'owned-serial.log').stat().st_size,262144)
        self.assertTrue((artifacts/'owned-serial.log.truncated').exists())
        self.assertFalse((artifacts/'owned-cloud.qcow2').exists())


if __name__=='__main__':unittest.main()
