#!/usr/bin/env bash
# test-printers.sh — printer migration against a REAL CUPS (SPEC §4.6).
#
# Runs wootc-printer-import inside a container with cupsd and
# tests/e2e/ipp-everywhere-responder.py on 127.0.0.2:631, against the
# printers the hosted E2E seeds on Windows: a Standard TCP/IP printer at
# 127.0.0.2 (the default), one at the unreachable TEST-NET 192.0.2.44, one on
# LPT1: and "Microsoft Print to PDF". It proves the retry path (waiting while
# the printer is away, added once it answers), that `lp` delivers a document
# to the printer, that a rerun changes nothing, and that a queue the user
# removed is never re-added.
#
# Usage: bash tests/migration/test-printers.sh   (host with podman)
# Image: WOOTC_PRINTER_TEST_IMAGE, else the local bluefin:stable if pulled,
# else Fedora with cups + cups-filters installed. Without podman it skips.

set -Eeuo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

if ! command -v podman >/dev/null 2>&1; then
    echo "SKIP: podman not installed — printer migration CUPS test not run"
    exit 0
fi
IMG="${WOOTC_PRINTER_TEST_IMAGE:-}"
if [[ -z "$IMG" ]]; then
    if podman image exists ghcr.io/ublue-os/bluefin:stable; then
        IMG=ghcr.io/ublue-os/bluefin:stable
    else
        IMG=registry.fedoraproject.org/fedora:latest
    fi
fi

INNER=$(cat <<'INNER'
set -Euo pipefail
PASS=0; FAIL=0
ok()   { echo "[PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
check(){ if eval "$1"; then ok "$2"; else bad "$2"; fi; }

# A failed install is a failure, not a skip: CI runs this on plain Fedora, and
# a test that skips there proves nothing.
if ! command -v lpadmin >/dev/null 2>&1; then
    dnf install -y -q cups cups-filters python3 >/dev/null 2>&1 \
        || { echo "[FAIL] cannot install cups + cups-filters in this image"; exit 1; }
fi
# A booted system has these from tmpfiles and a sticky /tmp; a container has
# neither, and CUPS then fails to write its PPD and filter temp files.
chmod 1777 /tmp
systemd-tmpfiles --create --prefix=/var/spool/cups --prefix=/var/cache/cups \
    --prefix=/var/log/cups --prefix=/run/cups >/dev/null 2>&1 || true
mkdir -p /run/cups /var/spool/cups/tmp
/usr/sbin/cupsd
for _ in $(seq 50); do lpstat -r 2>/dev/null | grep -q "scheduler is running" && break; sleep 0.2; done

export WOOTC_HOST=/tmp/host WOOTC_PRINTER_PROBE_TIMEOUT=3
mkdir -p "$WOOTC_HOST/wootc/install"
cat > "$WOOTC_HOST/wootc/install/printers.json" <<'JSON'
{"schemaVersion":1,"printers":[
 {"name":"Office Laser 5eed","portName":"127.0.0.2","driverName":"Generic / Text Only","default":true,"shared":false,"portKind":"tcpip","host":"127.0.0.2","port":9100,"protocol":"raw"},
 {"name":"Lab Printer 5eed","portName":"IP_192.0.2.44","driverName":"Generic / Text Only","default":false,"shared":false,"portKind":"tcpip","host":"192.0.2.44","port":9100,"protocol":"raw"},
 {"name":"Label Printer 5eed","portName":"LPT1:","driverName":"Generic / Text Only","default":false,"shared":false,"portKind":"lpt"},
 {"name":"Microsoft Print to PDF","portName":"PORTPROMPT:","driverName":"Microsoft Print To PDF","default":false,"shared":false,"portKind":"virtual"}]}
JSON
IMPORT=/repo/payload/migration/wootc-printer-import
STATE=/var/lib/wootc/printers.json
status() { python3 -c 'import json,sys; print({r["name"]: r for r in json.load(open(sys.argv[1]))["printers"]}[sys.argv[2]][sys.argv[3]])' "$STATE" "$1" "$2" 2>/dev/null; }
Q=Office_Laser_5eed

# Boot 1: the office printer is away (no responder yet).
python3 "$IMPORT" > /tmp/run1.log
check '[[ $(status "Office Laser 5eed" status) == waiting ]]' "away from the office: Office Laser is waiting"
check '! lpstat -v 2>/dev/null | grep -q "$Q"' "no queue is created for a printer that did not answer"

# Boot 2 (the E2E retry path): the printer answers now.
python3 /repo/tests/e2e/ipp-everywhere-responder.py --listen 127.0.0.2:631 --spool /tmp/spool > /tmp/responder.log 2>&1 &
for _ in $(seq 50); do grep -q "IPP listening" /tmp/responder.log && break; sleep 0.2; done
python3 "$IMPORT" | tee /tmp/run2.log
check '[[ $(status "Office Laser 5eed" status) == added ]]' "Office Laser added once it answers"
check '[[ $(status "Office Laser 5eed" queue) == "$Q" ]]' "queue name is the sanitised Windows name ($Q)"
check '[[ $(status "Office Laser 5eed" uri) == ipp://127.0.0.2:631/ipp/print ]]' "Office Laser uri is ipp://127.0.0.2:631/ipp/print"
check 'grep -qx "wootc-printer-import: Office Laser 5eed: added ipp://127.0.0.2:631/ipp/print" /tmp/run2.log' "journal line: added <uri>"
check 'lpstat -v | grep -qx "device for $Q: ipp://127.0.0.2:631/ipp/print"' "lpstat -v shows the queue at the responder"
check 'lpstat -d | grep -qx "system default destination: $Q"' "the Windows default is the Linux default"
check '[[ -s /etc/cups/ppd/$Q.ppd ]]' "CUPS generated the IPP Everywhere PPD"
check '[[ $(status "Lab Printer 5eed" status) == waiting ]]' "unreachable TEST-NET printer is waiting"
check 'grep -q "^wootc-printer-import: Lab Printer 5eed: waiting: " /tmp/run2.log' "journal line: waiting: <reason>"
check '[[ $(status "Label Printer 5eed" status) == not-migrated ]]' "LPT1: printer is not migrated"
check '[[ $(status "Label Printer 5eed" reason) == "connected by cable to this PC: plug it in, and a driverless USB printer is set up automatically; others need their Linux driver" ]]' "LPT1: reason"
check '[[ $(status "Microsoft Print to PDF" status) == not-migrated ]]' "Microsoft Print to PDF is not migrated"
check '[[ $(status "Microsoft Print to PDF" reason) == "Windows-only virtual printer" ]]' "Microsoft Print to PDF reason"
check 'grep -qx "wootc-printer-import: Microsoft Print to PDF: not migrated: Windows-only virtual printer" /tmp/run2.log' "journal line: not migrated: <reason>"
check '[[ $(stat -c %a "$STATE") == 644 ]]' "the report is readable by the user (0644)"

# A job reaches the printer.
lp -d "$Q" /etc/os-release >/dev/null
for _ in $(seq 60); do compgen -G "/tmp/spool/job-*" >/dev/null && break; sleep 1; done
check 'compgen -G "/tmp/spool/job-*" >/dev/null' "lp delivered a document into the responder spool"
check 'grep -q "^IPP Get-Printer-Attributes" /tmp/responder.log' "responder logged IPP operations"

# Rerun: idempotent.
before=$(python3 -c 'import json; print(json.dumps(json.load(open("/var/lib/wootc/printers.json"))["printers"][0], sort_keys=True))')
python3 "$IMPORT" > /tmp/run3.log
after=$(python3 -c 'import json; print(json.dumps(json.load(open("/var/lib/wootc/printers.json"))["printers"][0], sort_keys=True))')
check '[[ "$before" == "$after" ]]' "rerun leaves the added record untouched"
check '[[ $(lpstat -v | wc -l) == 1 ]]' "rerun adds no second queue"

# The user removes the queue: wootc never brings it back.
lpadmin -x "$Q"
python3 "$IMPORT" > /tmp/run4.log
check '! lpstat -v 2>/dev/null | grep -q "$Q"' "a queue the user removed is not re-added"
check '[[ $(status "Office Laser 5eed" status) == added ]]' "its record still says wootc added it"

echo "printers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
INNER
)

podman run --rm -v "$REPO_ROOT:/repo:ro,z" --entrypoint bash "$IMG" -c "$INNER"
