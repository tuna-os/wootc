"""Public Debian PE trust and classic source/transaction controls.

Mount/root observations and package queries are explicit fixtures. The actual
source collector, Authenticode verifier and transaction run without trust mocks.
No real firmware or installed classic OS acceptance is claimed.
"""
import hashlib,json,runpy,shutil,sys,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'payload/migration/lib'))
import wootc_chain_verify as verify
import wootc_esp_transaction as tx
from wootc_pe import PE
assets=Path(sys.argv[1]).resolve() if len(sys.argv)==3 else None
if assets is None:raise SystemExit('usage: probe-classic-esp-chain-real.py PUBLIC_ASSET_DIRECTORY VERIFIER_CLOSURE')
closure=Path(sys.argv[2]).resolve()
record=json.loads((root/'docs/experiments/evidence/2026-09-27-classic-esp/provenance.json').read_text())
for relative,expected in record['assetHashes'].items():
    if hashlib.sha256((assets/relative).read_bytes()).hexdigest()!=expected:
        raise SystemExit('public asset hash differs: '+relative)
closure_record=json.loads((root/'docs/experiments/evidence/2026-09-27-esp-chain/provenance.json').read_text())
for relative,expected in closure_record['assetHashes'].items():
    if relative.startswith('verifier-script-closure/'):
        if hashlib.sha256((closure/relative.split('/',1)[1]).read_bytes()).hexdigest()!=expected:
            raise SystemExit('verifier closure hash differs: '+relative)
fixture=runpy.run_path(str(root/'tests/unit/test_wootc_classic_source.py'))['ClassicSourceTests']()
fixture.setUp()
results=[]
try:
    for name,canonical in [(Path(path).name,path) for path in fixture.paths]:
        component='shimx64.efi' if name.startswith('shim') else 'mmx64.efi' if name.startswith('mm') else 'grubx64.efi'
        data=(assets/'debian-trio'/component).read_bytes()
        Path(canonical).write_bytes(data);(fixture.fat/'EFI/debian'/component).write_bytes(data)
    source=fixture.freeze()['debian']
    proof=verify.verify_transition(assets/'debian13-previous-trio',source,assets/'efivars',closure)
    assert proof['current']['grubx64.efi']!=proof['candidate']['grubx64.efi']
    results.append({'case':'classic-package-bound-real-signed-source','proof':proof,
                    'observations':'explicit root/mount/package fixtures'})
    esp=fixture.esp;vendor=esp/'EFI/debian';vendor.mkdir(parents=True)
    (esp/'EFI/wootc').mkdir()
    for name in verify.FILES:shutil.copyfile(assets/'debian13-previous-trio'/name,vendor/name)
    files={'EFI/debian/'+name:tx.digest(vendor/name) for name in verify.FILES}
    manifest=('\n'.join(files)+'\n').encode();mirror=fixture.root/'manifest';mirror.write_bytes(manifest)
    (esp/'EFI/wootc/wootc-owned.txt').write_bytes(manifest)
    receipt={'schemaVersion':1,'hostEspUuid':'fixture-esp','sourceVendor':'debian','loaderVendor':'debian',
             'files':files,'ownedManifestSha256':hashlib.sha256(manifest).hexdigest()}
    receipt_path=fixture.root/'receipt';tx.atomic_json(receipt_path,receipt)
    with tx.Transaction(esp,fixture.root/'state',receipt_path,'fixture-esp',local_manifest=mirror) as transaction:
        assert transaction.refresh(source,receipt,assets/'efivars',closure)
    fresh=tx.read_json(receipt_path);tx.ownership(esp,mirror,fresh,'fixture-esp')
    assert fresh['sourceEFI']['sourceKind']=='classic'
    assert fresh['sourceEFI']['version'].startswith('classic-sha256:')
    archive_id=hashlib.sha256(json.dumps(proof['current'],sort_keys=True).encode()).hexdigest()
    archive=esp/'EFI/wootc/archive'/archive_id
    assert all(tx.digest(archive/name)==proof['current'][name] for name in verify.FILES)
    results.append({'case':'classic-real-signed-upgrade-publication','wholeOldArchiveVerified':True,
                    'receiptSourceVersion':fresh['sourceEFI']['version']})
    unchanged={name:tx.digest(vendor/name) for name in verify.FILES}
    body=bytearray((source/'grubx64.efi').read_bytes());body[0x1000]^=1;(source/'grubx64.efi').write_bytes(body)
    try:
        with tx.Transaction(esp,fixture.root/'state',receipt_path,'fixture-esp',local_manifest=mirror) as transaction:
            transaction.refresh(source,fresh,assets/'efivars',closure)
    except ValueError:pass
    else:raise AssertionError('tampered real GRUB was accepted')
    assert all(tx.digest(vendor/name)==unchanged[name] for name in verify.FILES)
    results.append({'case':'tampered-classic-grub-refused','allEspTrioHashesUnchanged':True})
finally:fixture.tearDown()
print(json.dumps({'firmwareAcceptance':False,'classicOsBootAcceptance':False,'results':results},indent=2))
