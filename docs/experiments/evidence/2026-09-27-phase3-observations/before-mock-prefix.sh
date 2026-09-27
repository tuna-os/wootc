set -Eeuo pipefail
P3_TARGET=/dev/sdb
RUN_ID=current-run
step() { :; }
fail() { echo "FAIL $*"; }
product_fail() { echo "PRODUCT-FAIL $*"; }
product_pass() { echo "PRODUCT-PASS $*"; }
qga_call() {
 if [[ "$*" == *UNAME=* ]]; then printf 'UNAME=Linux\nCMDLINE=root=UUID=native ro\nTARGET=/dev/sdb\n'; return "$NATIVE_RC"; fi
 printf 'SRC=/dev/sdb3\nwootc-e2e-userdata current-run\n'; return "$DATA_RC"
}
