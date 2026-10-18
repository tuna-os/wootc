"""Real public Ubuntu/RPM source verification and transaction; boot fixtures."""
import hashlib,json,runpy,shutil,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'payload/migration/lib'))
import wootc_chain_verify as verify
import wootc_esp_transaction as tx
from wootc_pe import PE
if len(sys.argv)!=3:raise SystemExit('usage: probe-classic-providers-real.py PUBLIC_ASSETS VERIFIER_CLOSURE')
assets=Path(sys.argv[1]).resolve();closure=Path(sys.argv[2]).resolve()
record=json.loads((root/'docs/experiments/evidence/2026-09-27-classic-providers/provenance.json').read_text())
for relative,expected in record['assetHashes'].items():
    if hashlib.sha256((assets/relative).read_bytes()).hexdigest()!=expected:
        raise SystemExit('public asset hash differs: '+relative)
for relative,expected in record['verifierClosureHashes'].items():
    if hashlib.sha256((closure/relative).read_bytes()).hexdigest()!=expected:
        raise SystemExit('verifier closure hash differs: '+relative)
Fixture=runpy.run_path(str(root/'tests/unit/test_wootc_classic_source.py'))['ClassicSourceTests']
results=[]
for provider,vendor in [('ubuntu','ubuntu'),('rpm','almalinux')]:
    fixture=Fixture();fixture.setUp()
    try:
        if provider=='ubuntu':
            fixture.release.write_text('ID=ubuntu\nVERSION_ID="24.04"\n')
            (fixture.fat/'EFI/debian').rename(fixture.fat/'EFI/ubuntu')
            roles={'shimx64.efi':('shim-signed','usr/lib/shim/shimx64.efi.signed.latest'),
                   'mmx64.efi':('shim-signed','usr/lib/shim/mmx64.efi'),
                   'grubx64.efi':('grub-efi-amd64-signed','usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed')}
            fixture.paths={}
            for name,(package,relative) in roles.items():
                canonical=fixture.install/relative;canonical.parent.mkdir(parents=True,exist_ok=True)
                canonical.write_bytes((assets/'ubuntu-trio'/name).read_bytes())
                fixture.paths[str(canonical)]=package
                (fixture.fat/'EFI/ubuntu'/name).write_bytes(canonical.read_bytes())
            shim=fixture.install/'usr/lib/shim/shimx64.efi.signed'
            shim.unlink();shim.symlink_to(shim.with_name('shimx64.efi.signed.latest'))
            command=fixture.command
            versions={'shim-signed':'1.58+15.8-0ubuntu1', 'grub-efi-amd64-signed':'1.202.5+2.12-1ubuntu7.3'}
            def package_command(*args):
                if args[0]=='dpkg-query' and args[1]=='--show':
                    return args[-1]+'\t'+versions[args[-1]]+'\tinstalled\tamd64\n'
                return command(*args)
            fixture.command=package_command
            old=assets/'ubuntu-previous-trio';efi=assets/'ubuntu-efivars'
            package_scope='explicit installed-package observation fixtures from public package control headers'
        else:
            fixture.rpm_layout()
            rpm_root=assets/'rpm-query-root'
            for name in verify.FILES:
                (fixture.fat/'EFI/almalinux'/name).write_bytes((rpm_root/'boot/efi/EFI/almalinux'/name).read_bytes())
            command=fixture.command
            rpm=assets/'rpm-closure'
            rpm_command=[str(rpm/'ld-linux-x86-64.so.2'),'--library-path',str(rpm),str(rpm/'rpm'),
                         '--rcfile',str(assets/'rpm-config/rpmrc'),'--macros',str(assets/'rpm-config/macros'),
                         '--dbpath','/root/.rpmdb','--root',str(rpm_root)]
            def package_command(*args):
                if args[0]!='rpm':return command(*args)
                translated=list(args[1:])
                if args[1]=='-qf':translated[-1]='/boot/efi/EFI/almalinux/'+Path(translated[-1]).name
                output=subprocess.check_output(rpm_command+translated,text=True,timeout=30)
                return output.replace('/boot/efi',str(fixture.fat))
            fixture.command=package_command
            old=assets/'almalinux-old-trio'
            # The old/new proof's explicit firmware fixture uses the same public
            # Microsoft anchor; create a local fixture if no retained EFI folder.
            import struct
            from wootc_pe import signature_certificates,X509
            efi=fixture.root/'efivars';efi.mkdir()
            def var(name,guid,value):(efi/(name+'-'+guid)).write_bytes(struct.pack('<I',7)+value)
            cert=signature_certificates(PE((old/'shimx64.efi').read_bytes()).signatures[0])[1]
            esl=X509.bytes_le+struct.pack('<III',44+len(cert),0,16+len(cert))+bytes(16)+cert
            var('SecureBoot',verify.GLOBAL,b'\1');var('SetupMode',verify.GLOBAL,b'\0')
            var('db',verify.DB_GUID,esl);var('dbx',verify.DB_GUID,b'');var('SbatLevelRT',verify.SHIM_GUID,b'sbat,1\n\0')
            package_scope='real RPM database after public RPM installation with scripts and triggers disabled; explicit root path translation'
        source=fixture.freeze()[vendor]
        proof=verify.verify_transition(old,source,efi,closure)
        assert proof['current']['grubx64.efi']!=proof['candidate']['grubx64.efi']
        esp=fixture.esp;target=esp/'EFI'/vendor;target.mkdir(parents=True);(esp/'EFI/wootc').mkdir()
        for name in verify.FILES:shutil.copyfile(old/name,target/name)
        files={'EFI/'+vendor+'/'+name:tx.digest(target/name) for name in verify.FILES}
        manifest=('\n'.join(files)+'\n').encode();mirror=fixture.root/'manifest';mirror.write_bytes(manifest)
        (esp/'EFI/wootc/wootc-owned.txt').write_bytes(manifest)
        receipt={'schemaVersion':1,'hostEspUuid':'fixture-esp','sourceVendor':vendor,'loaderVendor':vendor,
                 'files':files,'ownedManifestSha256':hashlib.sha256(manifest).hexdigest()}
        receipt_path=fixture.root/'receipt';tx.atomic_json(receipt_path,receipt)
        with tx.Transaction(esp,fixture.root/'state',receipt_path,'fixture-esp',local_manifest=mirror) as transaction:
            assert transaction.refresh(source,receipt,efi,closure)
        fresh=tx.read_json(receipt_path);tx.ownership(esp,mirror,fresh,'fixture-esp')
        archive_id=hashlib.sha256(json.dumps(proof['current'],sort_keys=True).encode()).hexdigest()
        archive=esp/'EFI/wootc/archive'/archive_id
        assert all(tx.digest(archive/name)==proof['current'][name] for name in verify.FILES)
        unchanged={name:tx.digest(target/name) for name in verify.FILES}
        data=bytearray((source/'grubx64.efi').read_bytes());data[0x1000]^=1;(source/'grubx64.efi').write_bytes(data)
        try:
            with tx.Transaction(esp,fixture.root/'state',receipt_path,'fixture-esp',local_manifest=mirror) as transaction:
                transaction.refresh(source,fresh,efi,closure)
        except ValueError:pass
        else:raise AssertionError('tampered public GRUB accepted')
        assert all(tx.digest(target/name)==unchanged[name] for name in verify.FILES)
        results.append({'provider':provider,'vendor':vendor,'proof':proof,'packageObservations':package_scope,
                        'wholeOldArchiveVerified':True,'receiptSourceEFI':fresh['sourceEFI'],
                        'tamperedGrubRefusedWithEspUnchanged':True})
    finally:fixture.tearDown()
print(json.dumps({'firmwareAcceptance':False,'classicOsBootAcceptance':False,
                  'rootAndMountObservations':'explicit fixtures','results':results},indent=2))
