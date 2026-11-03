"""Offline YAML/command contracts, not GitHub Actions or Xcode execution."""
from pathlib import Path
import subprocess
import unittest
import yaml
ROOT = Path(__file__).resolve().parents[1]
class WorkflowContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml.load((ROOT/'.github/workflows/build.yml').read_text(), Loader=yaml.BaseLoader)
        cls.jobs = cls.workflow['jobs']
    def test_parallel_and_publication_gate(self):
        self.assertEqual(set(self.jobs), {'test','build','publish'})
        for job in ['test','build']:
            self.assertNotIn('needs',self.jobs[job])
            self.assertEqual(self.jobs[job]['permissions']['contents'],'read')
        publish=self.jobs['publish']
        self.assertEqual(set(publish['needs']),{'test','build'})
        for token in ["needs.test.result == 'success'", "needs.build.result == 'success'", '!inputs.build_only','!inputs.widget_diagnostics','success()']:
            self.assertIn(token,publish['if'])
        self.assertIn('!inputs.build_only',self.jobs['test']['if'])
    def test_fixed_preboot_and_complete_tests(self):
        steps=self.jobs['test']['steps']
        commands='\n'.join(x.get('run','') for x in steps)
        for token in ['SimDeviceType.iPhone-16','SimRuntime.iOS-18-5','simctl boot ','simctl bootstatus','build-for-testing','test-without-building','-parallel-testing-enabled NO']:
            self.assertIn(token,commands)
        self.assertLess(commands.index('simctl boot '),commands.index('build-for-testing'))
        self.assertNotIn('-only-testing',commands)
        self.assertNotIn('-skip-testing',commands)
        self.assertEqual(commands.count('-derivedDataPath build/TestDerivedData'),2)
        self.assertTrue(any(x.get('if')=='${{ always() }}' for x in steps))
    def test_artifact_identity_and_validation(self):
        commands='\n'.join(x.get('run','') for x in self.jobs['publish']['steps'])
        self.assertLess(commands.index('sha256sum --check'),commands.index('gh release create'))
        self.assertIn('test "$(cat build/SOURCE_SHA.txt)" = "$GITHUB_SHA"',commands)
        self.assertIn('scripts/verify_ipa.py build/ParcelKeeper-unsigned.ipa',commands)
        self.assertIn('--target "$GITHUB_SHA"',commands)
        self.assertNotIn('xcodebuild',commands)
    def test_shell_syntax(self):
        for job in self.jobs.values():
            for step in job['steps']:
                if 'run' in step:
                    result=subprocess.run(['bash','-n'],input=step['run'],text=True,capture_output=True)
                    self.assertEqual(result.returncode,0,(step['name'],result.stderr))
if __name__=='__main__': unittest.main()
