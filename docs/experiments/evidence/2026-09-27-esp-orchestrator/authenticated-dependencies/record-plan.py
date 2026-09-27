from pathlib import Path
import json,hashlib,re,subprocess,os,shutil,datetime,importlib.util,tempfile,lzma
p=Path(__file__).resolve().parent;s=p/'solver';indices={n:json.loads((p/(n+'-package-index.json')).read_text()) for n in ('old9','new')}
def sha(path):
 with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
auth=[]
for n in ('old9','new'):
 r=subprocess.run(['gpgv','--status-fd','1','--keyring',str(p/'keys.gpg'),'--output',str(p/(n+'-record-Release')),str(p/(n+'-InRelease'))],capture_output=True,timeout=15);assert r.returncode==0
 (p/(n+'-record-status.txt')).write_bytes(r.stdout);(p/(n+'-record-stderr.txt')).write_bytes(r.stderr)
 parsed=(p/(n+'-record-Release')).read_text();e=next(line.split() for line in parsed.split('SHA256:\n')[1].split('\nSHA')[0].splitlines() if line.endswith('main/binary-amd64/Packages.xz'));assert sha(p/(n+'-Packages.xz'))==e[0]
 parsed_index={}
 for paragraph in lzma.decompress((p/(n+'-Packages.xz')).read_bytes()).decode().split('\n\n'):
  row={};last=None
  for line in paragraph.splitlines():
   if line.startswith(' ') and last:row[last]+='\n'+line
   elif ': ' in line:last,value=line.split(': ',1);row[last]=value
  if 'Package' in row:parsed_index.setdefault(row['Package'],[]).append(row)
 assert parsed_index==indices[n], 'cached package facts differ from authenticated compressed index'
 auth.append({'generation':n,'signatureExit':0,'validSignatures':[line for line in r.stdout.decode().splitlines() if 'VALIDSIG' in line],'releaseSha256':sha(p/(n+'-InRelease')),'indexSha256':e[0],'indexBytes':int(e[1]),'releaseDates':[line for line in parsed.splitlines() if line.startswith(('Date:','Valid-Until:'))],'scope':'historical signed metadata; source-local cache disables Valid-Until only for planning; no live repository freshness claim'})
with tempfile.TemporaryDirectory(prefix='counter-',dir=p) as d:
 d=Path(d);original=(p/'new-InRelease').read_bytes();assert b'Suite: stable' in original;(d/'mutated').write_bytes(original.replace(b'Suite: stable',b'Suite: broken',1));r=subprocess.run(['gpgv','--keyring',str(p/'keys.gpg'),str(d/'mutated')],capture_output=True,timeout=15);assert r.returncode!=0;(p/'bad-release.stderr').write_bytes(r.stderr)
 b=bytearray((p/'new-Packages.xz').read_bytes());b[-1]^=1;assert hashlib.sha256(b).hexdigest()!=auth[1]['indexSha256'];controls={'actualModifiedReleaseSignatureRejected':r.returncode,'actualModifiedIndexDigestRejected':True}
cloud=Path('/tmp/wootc-333-classic-asset-plan/debian-13-generic-amd64.json');obj=json.loads(cloud.read_text());inventory=next(x['data']['packages'] for x in obj['items'] if x['kind']=='Build');baseline=[]
for item in inventory:
 name=item['name'].split(':',1)[0];entries=[e for e in indices['new'][name] if e['Version']==item['version']];assert len(entries)==1;e=entries[0];baseline.append({k:e[k] for k in ('Package','Version','Architecture','SHA256','Filename','Size')})
plans={}
for n in ('old9','new'):
 installed=[];removed=[];assert json.loads((s/(n+'-exit.json')).read_text())['returncode']==0; text=(s/(n+'-stdout.txt')).read_text();assert (s/(n+'-stderr.txt')).read_text()==''
 for line in text.splitlines():
  if line.startswith('Remv '):removed.append(line.split()[1])
  if line.startswith('Inst '):
   name,version=re.match(r'^Inst (\S+)(?: \[[^]]+\])? \(([^ ]+)',line).groups();candidates=[e for index in indices.values() for e in index.get(name,[]) if e['Version']==version];e=candidates[0];assert all(v['SHA256']==e['SHA256'] for v in candidates);installed.append({k:e[k] for k in ('Package','Version','Architecture','SHA256','Filename','Size','Depends','Pre-Depends','Breaks','Conflicts') if k in e})
 plans[n]={'scope':'real apt simulation over declared cloud inventory; new follows resolved old status; no actual guest dpkg state','solverExit':0,'installs':installed,'removals':removed,'downloadBytes':sum(int(e['Size']) for e in installed)}
info=dict(line.split(':',1) for line in Path('/proc/meminfo').read_text().splitlines());tools={n:shutil.which(n) for n in ('qemu-img','qemu-system-x86_64','virt-customize','guestfish','swtpm','gpgv','apt-get')};host={'observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'cpus':os.cpu_count(),'memAvailableBytes':int(info['MemAvailable'].strip().split()[0])*1024,'kvmExists':Path('/dev/kvm').exists(),'kvmAccessible':os.access('/dev/kvm',os.R_OK|os.W_OK),'freeBytes':shutil.disk_usage(p).free,'tools':tools,'pythonGuestfsModulePresent':importlib.util.find_spec('guestfs') is not None,'qualifiedHost':False}
r={'schemaVersion':1,'scope':'authenticated official metadata, native apt simulations and observed eligibility; no package, image or VM acquisition','authenticatedMetadata':auth,'authenticationCountercontrols':controls,'trustAnchors':{'publishedKeysUrl':'https://ftp-master.debian.org/keys.html','primaryFingerprints':['1F89983E0081FDE018F3CC9673A4F27B8DD47936','B8B80B5B623EAB6AD8775C45B7C5D7D6350947F8','04B54C3CDCA79751B16BC6B5225629DF75B188BD','41587F7DB8C774BCCF131416762F67A0B2C39DE4'],'keyringSha256':sha(p/'keys.gpg'),'bootstrap':'official primary HTTPS published key material/fingerprints; no preinstalled Debian keyring existed'},'cloudInventorySha256':sha(cloud),'cloudInventoryPackages':baseline,'solverPlans':plans,'sourceDependencySetsResolved':True,'actualGuestDependencyResolution':False,'producerOfflinePinnedPackageConsumerImplemented':False,'newPackagesAcquired':False,'producerExecuted':False,'firmwareAcceptance':False,'classicOsBootAcceptance':False,'hostObservation':host,'remaining':['acquired bytes must match signed-index SHA256 pins','actual guest dpkg inventory/maintainer scripts/initramfs outcomes unobserved','producer must consume full offline pinned bundles instead of network apt update/install','allowlisted removal of initramfs-tools/cloud-initramfs-growroot only in owned scratch','pristine Windows disk+TPM+NVRAM+UUID and clone observation missing','qualified KVM/libguestfs host missing'],'preservedMetadataRoot':str(p),'preservedHashes':{f.name:sha(f) for f in p.iterdir() if f.is_file() and f.name not in ('authenticated-dependency-plan.json',)}}
(p/'authenticated-dependency-plan.json').write_text(json.dumps(r,indent=2,sort_keys=True)+'\n');print(json.dumps({'cloudPackages':len(baseline),'oldPins':len(plans['old9']['installs']),'newPins':len(plans['new']['installs']),'oldBytes':plans['old9']['downloadBytes'],'newBytes':plans['new']['downloadBytes'],'controls':controls,'host':host}))
