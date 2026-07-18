#!/usr/bin/env bats
# wifi-bridge.bats — netsh Wi-Fi XML → NetworkManager keyfile conversion, and
# the consent-tier gate that keeps enterprise/secret material from being copied
# (SPEC §4.6). Pure transform: runs on the host with temp SRC/DST dirs, needs
# only python3. Verifies both the happy path (PSK/SAE/open imported correctly)
# and the security-critical negatives (enterprise skipped, no-key skipped, and
# the cleartext export shredded afterwards).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WB="$REPO_ROOT/payload/migration/wootc-wifi-bridge"
    SRC="$BATS_TEST_TMPDIR/src"; DST="$BATS_TEST_TMPDIR/dst"; STATE="$BATS_TEST_TMPDIR/state"
    mkdir -p "$SRC"
    export WOOTC_WIFI_SRC="$SRC" WOOTC_WIFI_DST="$DST" WOOTC_WIFI_STATE="$STATE"
}

# write a netsh-style profile XML for SSID $1, authentication $2, key $3 (opt),
# and an optional OneX (enterprise) marker if $4 == ent.
write_profile() {
    local ssid="$1" auth="$2" key="${3:-}" ent="${4:-}" f="$SRC/$1.xml" onex=""
    [[ "$ent" == "ent" ]] && onex='<security><OneX xmlns="http://www.microsoft.com/networking/OneX/v1"><EAPConfig/></OneX></security>'
    local sharedkey=""
    [[ -n "$key" ]] && sharedkey="<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>${key}</keyMaterial></sharedKey>"
    cat >"$f" <<XML
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>${ssid}</name>
  <SSIDConfig><SSID><name>${ssid}</name></SSID></SSIDConfig>
  <MSM><security>
    <authEncryption><authentication>${auth}</authentication><encryption>AES</encryption></authEncryption>
    ${sharedkey}
  </security>${onex}</MSM>
</WLANProfile>
XML
}

@test "WPA2-PSK profile becomes a wpa-psk NM keyfile with the passphrase" {
    write_profile "HomeNet" WPA2PSK "s3cret-pass"
    run bash "$WB"
    [ "$status" -eq 0 ]
    [ -f "$DST/HomeNet.nmconnection" ]
    grep -q "key-mgmt=wpa-psk" "$DST/HomeNet.nmconnection"
    grep -q "psk=s3cret-pass" "$DST/HomeNet.nmconnection"
    grep -q "ssid=HomeNet" "$DST/HomeNet.nmconnection"
}

@test "WPA3-SAE profile maps to key-mgmt=sae" {
    write_profile "Modern" WPA3SAE "wpa3-pass"
    run bash "$WB"
    [ -f "$DST/Modern.nmconnection" ]
    grep -q "key-mgmt=sae" "$DST/Modern.nmconnection"
}

@test "open network imports with no wifi-security section" {
    write_profile "CoffeeShop" open
    run bash "$WB"
    [ -f "$DST/CoffeeShop.nmconnection" ]
    grep -q "ssid=CoffeeShop" "$DST/CoffeeShop.nmconnection"
    ! grep -q "wifi-security" "$DST/CoffeeShop.nmconnection"
}

@test "enterprise 802.1X profile is DETECTED but never copied" {
    write_profile "CorpWiFi" WPA2 "" ent
    run bash "$WB"
    [ ! -f "$DST/CorpWiFi.nmconnection" ]
    [[ "$output" == *"not copied"*"CorpWiFi"* ]]
}

@test "PSK profile with no cleartext key is skipped, not written keyless" {
    write_profile "NoKey" WPA2PSK ""
    run bash "$WB"
    [ ! -f "$DST/NoKey.nmconnection" ]
    [[ "$output" == *"no cleartext key"* ]]
}

@test "the transient cleartext export is destroyed after import" {
    write_profile "HomeNet" WPA2PSK "s3cret-pass"
    run bash "$WB"
    [ ! -f "$SRC/HomeNet.xml" ]
}

@test "state json records the imported/skipped counts for the dashboard" {
    write_profile "HomeNet" WPA2PSK "pass1"
    write_profile "CorpWiFi" WPA2 "" ent
    run bash "$WB"
    [ -f "$STATE/wifi-bridge.json" ]
    grep -q '"imported": 1' "$STATE/wifi-bridge.json"
    grep -q '"skippedEnterprise": 1' "$STATE/wifi-bridge.json"
}

@test "an existing NM connection is not clobbered" {
    write_profile "HomeNet" WPA2PSK "new-pass"
    mkdir -p "$DST"; printf 'id=HomeNet\npsk=OLD-PASS\n' >"$DST/HomeNet.nmconnection"
    run bash "$WB"
    grep -q "OLD-PASS" "$DST/HomeNet.nmconnection"
}

@test "empty export dir is a clean no-op" {
    run bash "$WB"
    [ "$status" -eq 0 ]
}
