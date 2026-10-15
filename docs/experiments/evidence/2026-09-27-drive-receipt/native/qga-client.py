import base64,json,os,subprocess,sys,time
prefix=['kubectl','--kubeconfig','/home/ubuntu/.kube/config-aws-migration','--request-timeout=15s','exec','-n','wootc-e2e',os.environ.get('WOOTC_QGA_POD','virt-launcher-phase1-whpx-zk2nz'),'-c','compute','--','virsh','-c','qemu:///session','qemu-agent-command',os.environ.get('WOOTC_QGA_DOMAIN','wootc-e2e_phase1-whpx')]
def call(req):
 r=subprocess.run(prefix+[json.dumps(req)],capture_output=True,text=True,timeout=25)
 if r.returncode:raise RuntimeError(r.stderr)
 d=json.loads(r.stdout)
 if 'error' in d:raise RuntimeError(d['error'])
 return d['return']
script=open(sys.argv[1],encoding='utf-8-sig').read()
encoded=base64.b64encode(script.encode('utf-16le')).decode()
path=chr(92).join(['C:','Windows','System32','WindowsPowerShell','v1.0','powershell.exe'])
pid=call({'execute':'guest-exec','arguments':{'path':path,'arg':['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',encoded],'capture-output':True}})['pid']
deadline=time.monotonic()+120
while time.monotonic()<deadline:
 d=call({'execute':'guest-exec-status','arguments':{'pid':pid}})
 if d.get('exited'):
  for k in ['out-data','err-data']:
   if k in d:print(base64.b64decode(d[k]).decode('utf-8',errors='replace'),end='',file=sys.stdout if k=='out-data' else sys.stderr)
  sys.exit(d.get('exitcode',1))
 time.sleep(1)
raise TimeoutError('guest command is still running; do not replay it')
