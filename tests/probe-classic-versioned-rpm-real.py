"""Real Fedora versioned RPM metadata and signatures; explicit classic boot fixtures."""
import hashlib,json,runpy,shutil,struct,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'payload/migration/lib'))
import wootc_chain_verify as verify
from wootc_pe import PE,signature_certificates,X509
if len(sys.argv)!=3:raise SystemExit('usage: probe-classic-versioned-rpm-real.py PUBLIC_ASSETS VERIFIER_CLOSURE')
assets=Path(sys.argv[1]).resolve();closure=Path(sys.argv[2]).resolve()
pins=json.loads((root/'docs/experiments/evidence/2026-09-27-classic-versioned-rpm/provenance.json').read_text())
for base,entries in ((assets,pins['assetHashes']),(closure,pins['verifierClosureHashes'])):
    for relative,expected in entries.items():
        if hashlib.sha256((base/relative).read_bytes()).hexdigest()!=expected:
            raise SystemExit('pinned input differs: '+str(base/relative))
image='ghcr.io/projectbluefin/bluefin@sha256:a50af2d633f72b549b395d0973a2cc317654e4e4ad679543b9c52c63c34a0d61'
Fixture=runpy.run_path(str(root/'tests/unit/test_wootc_classic_source.py'))['ClassicSourceTests']
fixture=Fixture();fixture.setUp();calls=[]
try:
    fixture.release.write_text('ID=fedora\nVERSION_ID="44"\n')
    (fixture.fat/'EFI/debian').rename(fixture.fat/'EFI/fedora')
    canonical={}
    for name in verify.FILES:
        folder='grub2/1:2.12-64.fc44' if name=='grubx64.efi' else 'shim/16.1-5'
        path=fixture.install/'usr/lib/efi'/folder/'EFI/fedora'/name
        path.parent.mkdir(parents=True,exist_ok=True)
        source=assets/('grub-payload' if name=='grubx64.efi' else 'shim-payload')/name
        shutil.copyfile(source,path);shutil.copyfile(source,fixture.fat/'EFI/fedora'/name)
        canonical[name]=path
    original=fixture.command
    def command(*args):
        if args[0]!='rpm':return original(*args)
        translated=list(args[1:])
        if args[1]=='-qf':translated[-1]=str(Path('/usr/lib/efi')/Path(args[-1]).relative_to(fixture.install/'usr/lib/efi'))
        invocation=['podman','run','--rm','--pull','never','--read-only','--network','none',
                    '--entrypoint','/usr/bin/rpm',image]+translated
        result=subprocess.run(invocation,check=True,text=True,capture_output=True,timeout=30)
        calls.append({'args':translated,'stdout':result.stdout})
        return result.stdout.replace('/usr/lib/efi/',str(fixture.install/'usr/lib/efi')+'/')
    fixture.command=command
    candidate=fixture.freeze()['fedora']
    efi=fixture.root/'efi';efi.mkdir()
    def var(name,guid,value):(efi/(name+'-'+guid)).write_bytes(struct.pack('<I',7)+value)
    cert=signature_certificates(PE((candidate/'shimx64.efi').read_bytes()).signatures[0])[1]
    esl=X509.bytes_le+struct.pack('<III',44+len(cert),0,16+len(cert))+bytes(16)+cert
    var('SecureBoot',verify.GLOBAL,b'\1');var('SetupMode',verify.GLOBAL,b'\0');var('db',verify.DB_GUID,esl)
    var('dbx',verify.DB_GUID,b'');var('SbatLevelRT',verify.SHIM_GUID,b'sbat,1\n\0')
    proof=verify.verify_transition(candidate,candidate,efi,closure)
    assert proof['verified'] is True
    metadata=json.loads((candidate.parent.parent/'EFI.json').read_text())
    assert metadata['sourceKind']=='classic' and metadata['packageManager']=='rpm'
    assert 'imageRef' not in metadata and 'imageDigest' not in metadata
    print(json.dumps({'firmwareAcceptance':False,'classicOsBootAcceptance':False,
          'scope':'Actual public Fedora package metadata and signature verification; explicit classic OS/root/mount observations',
          'artifactSourceImage':image,'sourceFacts':metadata,'signatureProof':proof,
          'freshNativeRpmQueries':len(calls),'queries':calls},indent=2))
finally:fixture.tearDown()
