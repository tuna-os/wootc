#!/usr/bin/env bats

@test "native move summary accepts measured fields and rejects absent or malformed records" {
    run python3 - "$BATS_TEST_DIRNAME/../../payload/migration/wootc-go-native-gui" "$BATS_TEST_TMPDIR" <<'PY'
import importlib.machinery, importlib.util, json, pathlib, sys
loader = importlib.machinery.SourceFileLoader('native_gui', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
path = pathlib.Path(sys.argv[2]) / 'summary.json'
assert module.firstboot_summary(path) is None
record = dict(kernel='6.12.1', sourceImageRef='ghcr.io/tuna-os/yellowfin:gnome',
              imageDigest='sha256:' + 'a'*64, writtenAt='2026-09-27T05:00:00Z',
              boundFolders=3, matchedUsers=1)
path.write_text(json.dumps(record))
assert module.firstboot_summary(path) == record
text = module.firstboot_summary_text(record)
assert 'Verified boot before this move' in text and '6.12.1' in text and '3 connected folders' in text
for broken in ({}, dict(record, boundFolders=-1), dict(record, matchedUsers=True), dict(record, imageDigest='')):
    path.write_text(json.dumps(broken))
    assert module.firstboot_summary(path) is None, broken
path.write_text('{' * 8193)
assert module.firstboot_summary(path) is None
PY
    [ "$status" -eq 0 ]
}

@test "E2E compares product firstboot record to current observed Linux facts" {
    local runner="$BATS_TEST_DIRNAME/../e2e/run-e2e.sh"
    grep -q 'current=module.collect(host)' "$runner"
    grep -q 'persisted.get(key) != current\[key\]' "$runner"
    grep -q 'Installed Linux first-boot record is absent, incomplete or differs from this boot' "$runner"
}
