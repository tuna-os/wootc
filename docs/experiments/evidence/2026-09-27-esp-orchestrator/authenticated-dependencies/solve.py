import json,lzma,subprocess,hashlib,re
from pathlib import Path
p=Path(__file__).resolve().parent;s=p/'solver';s.mkdir(exist_ok=True);(s/'lists').mkdir(exist_ok=True);(s/'cache').mkdir(exist_ok=True)
index={tag:json.loads((p/(tag+'-package-index.json')).read_text()) for tag in ('old9','new')}
for tag in index:(s/'lists'/('snapshot_'+tag+'_dists_fixture_main_binary-amd64_Packages')).write_bytes(lzma.decompress((p/(tag+'-Packages.xz')).read_bytes()))

cloud=json.loads(Path('/tmp/wootc-333-classic-asset-plan/debian-13-generic-amd64.json').read_text());packages=next(x['data']['packages'] for x in cloud['items'] if x['kind']=='Build')
status=[];unmatched=[]
for package in packages:
 name=package['name'].split(':',1)[0];version=package['version'];matching=[e for e in index['new'].get(name,[]) if e['Version']==version]
 row=matching[0] if len(matching)==1 else {'Package':name,'Version':version,'Architecture':'amd64'}
 if not matching:unmatched.append({'package':name,'version':version})
 status.append('Package: '+name+'\nStatus: install ok installed\n'+''.join(k+': '+row[k]+'\n' for k in ('Version','Architecture','Essential','Multi-Arch','Provides','Depends','Pre-Depends','Conflicts','Breaks') if k in row))
(s/'status').write_text('\n'.join(status));(s/'inventory-unmatched.json').write_text(json.dumps(unmatched,indent=2)+'\n')
options=['-o','Dir::State::status='+str(s/'status'),'-o','Dir::State::lists='+str(s/'lists'),'-o','Dir::Etc::sourcelist='+str(s/'sources.list'),'-o','Dir::Etc::sourceparts=-','-o','Dir::Cache='+str(s/'cache'),'-o','Debug::NoLocking=1','-o','APT::Architecture=amd64','-o','APT::Install-Recommends=false']
roots=['dracut','ntfs-3g','qemu-guest-agent','python3','efibootmgr','shim-signed','shim-helpers-amd64-signed']
for tag,version in [('old9','2.12-9'),('new','2.12-9+deb13u2')]:
 targets=roots+[n+'='+version for n in ('grub-common','grub2-common','grub-efi-amd64-bin','grub-efi-amd64-unsigned','grub-pc-bin')]+['grub-efi-amd64-signed=1+'+version.replace('-','+')]
 result=subprocess.run(['apt-get',*options,'--simulate','--allow-downgrades','install',*targets],capture_output=True,text=True,timeout=30)
 (s/(tag+'-exit.json')).write_text(json.dumps({'returncode':result.returncode})+'\n')
 (s/(tag+'-stdout.txt')).write_text(result.stdout);(s/(tag+'-stderr.txt')).write_text(result.stderr)

 if result.returncode == 0 and tag == 'old9':
  current={row.split('\n',1)[0].split(': ',1)[1]:row for row in status}
  for line in result.stdout.splitlines():
   if line.startswith('Remv '):current.pop(line.split()[1],None)
   if line.startswith('Inst '):
    match=re.match(r'^Inst (\S+)(?: \[[^]]+\])? \(([^ ]+)',line);name,version=match.groups()
    entries=[e for database in index.values() for e in database.get(name,[]) if e['Version']==version]
    row=entries[0];assert all(e['SHA256']==row['SHA256'] for e in entries)
    current[name]='Package: '+name+'\nStatus: install ok installed\n'+''.join(k+': '+row[k]+'\n' for k in ('Version','Architecture','Essential','Multi-Arch','Provides','Depends','Pre-Depends','Conflicts','Breaks') if k in row)
  (s/'status').write_text('\n'.join(current.values()));(s/'resolved-old-status').write_text('\n'.join(current.values()))
 print(json.dumps({'generation':tag,'returncode':result.returncode,'unmatchedInventoryPackages':len(unmatched),'stderr':result.stderr,'transactions':[line for line in result.stdout.splitlines() if line.startswith(('Inst ','Remv '))]}))
