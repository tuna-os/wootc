#!/usr/bin/env bats
# import.bats — external-disk / BitLocker discovery (wootc-import scan). The
# scan is pure lsblk-JSON parsing behind the WOOTC_IMPORT_LSBLK / _ROOTDISK
# fixture hooks, so the whole classifier runs on the host with no real disks:
# it must find NTFS + BitLocker partitions, flag BitLocker locked, and never
# offer a partition on the disk Linux is running from.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    IMP="$REPO_ROOT/payload/migration/wootc-import"
    FIX="$BATS_TEST_TMPDIR/lsblk.json"
    cat >"$FIX" <<'JSON'
{"blockdevices":[
  {"path":"/dev/sda","type":"disk","fstype":null,"size":512110190592,"pkname":null,"children":[
    {"path":"/dev/sda1","type":"part","fstype":"ntfs","size":499999999999,"label":"Windows","pkname":"sda"}
  ]},
  {"path":"/dev/sdb","type":"disk","fstype":null,"size":1000204886016,"pkname":null,"children":[
    {"path":"/dev/sdb1","type":"part","fstype":"ntfs","size":999999999999,"label":"Backup","pkname":"sdb"}
  ]},
  {"path":"/dev/sdc","type":"disk","fstype":null,"size":256060514304,"pkname":null,"children":[
    {"path":"/dev/sdc1","type":"part","fstype":"BitLocker","size":250000000000,"label":"Encrypted","pkname":"sdc"},
    {"path":"/dev/sdc2","type":"part","fstype":"ext4","size":6000000000,"label":"linux","pkname":"sdc"}
  ]}
]}
JSON
    export WOOTC_IMPORT_LSBLK="$FIX" WOOTC_IMPORT_ROOTDISK="sda"
}

vols() { python3 -c 'import sys,json; print(json.load(sys.stdin))'; }

@test "scan finds the spare NTFS and the BitLocker disk, not the running disk" {
    run bash "$IMP" scan
    [ "$status" -eq 0 ]
    devs=$(echo "$output" | python3 -c 'import sys,json; print(sorted(v["device"] for v in json.load(sys.stdin)))')
    [[ "$devs" == "['/dev/sdb1', '/dev/sdc1']" ]]
}

@test "the running-disk (sda) partitions are excluded" {
    run bash "$IMP" scan
    echo "$output" | python3 -c 'import sys,json; assert all(v["device"]!="/dev/sda1" for v in json.load(sys.stdin))'
}

@test "BitLocker volume is flagged fs=bitlocker + locked=true" {
    run bash "$IMP" scan
    echo "$output" | python3 -c 'import sys,json; v=[x for x in json.load(sys.stdin) if x["device"]=="/dev/sdc1"][0]; assert v["fs"]=="bitlocker" and v["locked"] is True, v'
}

@test "plain NTFS volume is fs=ntfs + locked=false, with its label" {
    run bash "$IMP" scan
    echo "$output" | python3 -c 'import sys,json; v=[x for x in json.load(sys.stdin) if x["device"]=="/dev/sdb1"][0]; assert v["fs"]=="ntfs" and v["locked"] is False and v["label"]=="Backup", v'
}

@test "non-Windows filesystems (ext4) are not offered" {
    run bash "$IMP" scan
    echo "$output" | python3 -c 'import sys,json; assert all(v["device"]!="/dev/sdc2" for v in json.load(sys.stdin))'
}

@test "empty disk list is a clean empty scan" {
    echo '{"blockdevices":[]}' >"$WOOTC_IMPORT_LSBLK"
    run bash "$IMP" scan
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | tr -d '[:space:]')" == "[]" ]]
}
