"""Private in-memory mutant; source worktree and host services are unchanged."""
import os,runpy,signal,unittest
from pathlib import Path
source=Path('tests/e2e/package-runtime/bootstrap.py').read_text()
a=source.index('    def cleanup(self,child):');b=source.index('\n    def release(self):',a)
source=source[:a]+"    def cleanup(self,child):\n        child.wait(timeout=2)\n        return {'empty':True}\n"+source[b:]
source=source.replace("        if self.children():raise ValueError('agent children remain: subreaper lease retained')\n",'')
namespace={'__file__':str(Path('tests/e2e/package-runtime/bootstrap.py').resolve())}
exec(compile(source,namespace['__file__'],'exec'),namespace)
tests=runpy.run_path('tests/unit/test_linux_package_agent_command.py')
tests['AgentCommandTests'].command.__globals__['MODULE']=namespace
try:
    result=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite([tests['AgentCommandTests']('test_closed_stream_survivor_and_escaped_group_are_reaped')]))
    if result.wasSuccessful():raise SystemExit('MUTANT UNEXPECTEDLY PASSED')
    if result.errors:raise SystemExit('MUTANT CONTROL ERROR')
    print('REMOVED-CLEANUP RED: actual owned descendants survived accepted parent completion')
finally:
    for pid in Path('/proc/self/task/'+str(os.getpid())+'/children').read_text().split():
        os.kill(int(pid),signal.SIGKILL);os.waitpid(int(pid),0)
