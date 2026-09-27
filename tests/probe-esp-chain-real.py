"""Real Authenticode trio upgrade and killed-writer recovery; public assets only."""
import hashlib,json,os,shutil,struct,subprocess,sys,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'payload/migration/lib'))
import wootc_esp_transaction as t
import wootc_chain_verify as c
from wootc_pe import PE,signature_certificates,X509
proof=Path(sys.argv[1]).resolve() if len(sys.argv)==2 else None
if proof is None:raise SystemExit('usage: probe-esp-chain-real.py PUBLIC_ASSET_DIRECTORY')
record=json.loads((root/'docs/experiments/evidence/2026-09-27-esp-chain/provenance.json').read_text())
for relative,expected in record['assetHashes'].items():
 if relative.startswith(('almalinux-old-trio/','almalinux-new-trio/')):
  if hashlib.sha256((proof/relative).read_bytes()).hexdigest()!=expected:
   raise SystemExit('public asset hash differs: '+relative)
if hashlib.sha256((proof/'almalinux-signed-vmlinuz').read_bytes()).hexdigest()!=record['kernelSha256']:
 raise SystemExit('public kernel hash differs')
old=proof/'almalinux-old-trio';new=proof/'almalinux-new-trio'
results=[]
with tempfile.TemporaryDirectory(prefix='wootc-real-upgrade-',dir=Path.home()/'.cache') as tmp:
 d=Path(tmp);closure=d/'closure';shutil.copytree(proof/'verifier-script-closure',closure)
 ef=d/'efivars';ef.mkdir()
 def var(name,guid,value):(ef/(name+'-'+guid)).write_bytes(struct.pack('<I',7)+value)
 def esl(kind,value):return kind.bytes_le+struct.pack('<III',44+len(value),0,16+len(value))+bytes(16)+value
 cert=signature_certificates(PE((new/'shimx64.efi').read_bytes()).signatures[0])[1]
 var('SecureBoot',c.GLOBAL,b'\1');var('SetupMode',c.GLOBAL,b'\0');var('db',c.DB_GUID,esl(X509,cert));var('dbx',c.DB_GUID,b'')
 var('SbatLevelRT',c.SHIM_GUID,b'sbat,1,2025051000\nshim,4\ngrub,5\n\0')
 real=c.verify_transition(old,new,ef,closure)
 assert all(real['current'][n]!=real['candidate'][n] for n in c.FILES)
 results.append({'case':'real-three-role-upgrade-preflight','proof':real})
 esp=d/'esp';vendor=esp/'EFI/fedora';vendor.mkdir(parents=True);(esp/'EFI/wootc').mkdir()
 source=d/'updates/EFI/almalinux';source.mkdir(parents=True)
 for n in c.FILES:shutil.copyfile(old/n,vendor/n);shutil.copyfile(new/n,source/n)
 metadata={'timestamp':'2026-08-31T14:21:00Z','version':'grub2-efi-x64-2.12-55.el10.alma.1.x86_64,shim-x64-16.1-4.el10.alma.1.x86_64'}
 (source.parent.parent/'EFI.json').write_text(json.dumps(metadata)+'\n')
 files={f'EFI/fedora/{n}':t.digest(vendor/n) for n in c.FILES}
 manifest=('\n'.join(files)+'\n').encode();(esp/'EFI/wootc/wootc-owned.txt').write_bytes(manifest)
 mirror=d/'esp-manifest';mirror.write_bytes(manifest)
 receipt={'schemaVersion':1,'hostEspUuid':'public-fixture','sourceVendor':'almalinux','loaderVendor':'fedora',
          'files':files,'ownedManifestSha256':hashlib.sha256(manifest).hexdigest()}
 receipt_path=d/'receipt.json';t.atomic_json(receipt_path,receipt);state=d/'state'
 script='''import os,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import wootc_esp_transaction as t
r=Path(sys.argv[2]);point=sys.argv[3]
def fail(value):
 if value=='after-'+point:os._exit(73)
with t.Transaction(r/'esp',r/'state',r/'receipt.json','public-fixture',fail,r/'esp-manifest') as tx:
 tx.refresh(r/'updates/EFI/almalinux',t.read_json(r/'receipt.json'),r/'efivars',r/'closure')
'''
 for name in ('grubx64.efi','mmx64.efi','shimx64.efi'):
  killed=subprocess.run([sys.executable,'-c',script,str(root/'payload/migration/lib'),str(d),name])
  assert killed.returncode==73
  with t.Transaction(esp,state,receipt_path,'public-fixture',local_manifest=mirror) as tx:tx.recover()
  assert all(t.digest(vendor/n)==real['current'][n] for n in c.FILES)
  assert t.read_json(receipt_path)==receipt
  results.append({'case':'real-upgrade-powerloss-after-'+name,'killedExit':73,'wholeOldTrioRestored':True})
 with t.Transaction(esp,state,receipt_path,'public-fixture',local_manifest=mirror) as tx:
  assert tx.refresh(source,receipt,ef,closure)
 assert all(t.digest(vendor/n)==real['candidate'][n] for n in c.FILES)
 t.ownership(esp,mirror,t.read_json(receipt_path),'public-fixture')
 results.append({'case':'real-upgrade-publication','wholeNewTrioPublished':True,'receiptVerified':True})
 # Exercise the production controller with the same real signatures. The
 # observation here is an explicit fixture; native observation has separate controls.
 import importlib.machinery,importlib.util,types
 os.environ['WOOTC_CHAIN_LIBRARY']=str(root/'payload/migration/lib')
 loader=importlib.machinery.SourceFileLoader('esp_control',str(root/'payload/migration/wootc-esp-control'))
 spec=importlib.util.spec_from_loader('esp_control',loader);control=importlib.util.module_from_spec(spec);loader.exec_module(control)
 kernel=proof/'almalinux-signed-vmlinuz'
 shutil.copyfile(kernel,esp/'EFI/wootc/phase2-vmlinuz')
 (esp/'EFI/wootc/phase2-initramfs.img').write_bytes(b'public initramfs fixture')
 (vendor/'grub.cfg').write_text('menuentry Linux {\n linux /EFI/wootc/phase2-vmlinuz ro\n}\n')
 files={str(path.relative_to(esp)):t.digest(path) for path in list(vendor.iterdir())+[esp/'EFI/wootc/phase2-vmlinuz',esp/'EFI/wootc/phase2-initramfs.img']}
 manifest=('\n'.join(files)+'\n').encode();mirror.write_bytes(manifest);(esp/'EFI/wootc/wootc-owned.txt').write_bytes(manifest)
 receipt_path.unlink()
 args=types.SimpleNamespace(state=str(state),esp=str(esp),receipt=str(receipt_path),manifest=str(mirror),uuid='public-fixture',updates=str(source.parent.parent),versioned=str(d/'absent-versioned'),efivars=str(ef),verifier=str(closure),kernel=str(kernel))
 observed={'loaderVendor':'fedora','bootId':'public-observation-fixture','rootKind':'loop'}
 prepared=control.prepare(args,observed)
 assert prepared['sourceVendor']=='almalinux' and prepared['cfgs']
 t.ownership(esp,mirror,t.read_json(receipt_path),'public-fixture')
 results.append({'case':'production-control-real-signed-kernel-and-trio','freshBootObservation':'explicit fixture; no hardware claim','receiptVerified':True})
 config=d/'config';config.write_text('new public config')
 args.source=str(config);args.destination='EFI/fedora/grub.cfg'
 assert control.write(args,observed)['changed']
 t.ownership(esp,mirror,t.read_json(receipt_path),'public-fixture')
 results.append({'case':'production-control-owned-artifact-publication','receiptVerified':True})
print(json.dumps(results,indent=2))
