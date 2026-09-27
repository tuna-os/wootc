#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "GUI editor proof rejects disabled Save and missing desktop/accessibility/close/reopen" {
    run python3 -m unittest discover -s "$ROOT/tests/unit" -p test_gui_document_proof.py -v
    [ "$status" -eq 0 ]
}

@test "GUI Documents dispatch is an explicit BitLocker acceptance gate" {
    grep -Fq "gui_documents: { description: 'Require GNOME editor save and persistence proof (BitLocker on)'" "$ROOT/.github/workflows/e2e-nightly.yml"
    grep -Fq "gui_documents: \${{ github.event.inputs.gui_documents == 'true' }}" "$ROOT/.github/workflows/e2e-nightly.yml"
    grep -Fq "WOOTC_E2E_GUI_DOCUMENTS: \${{ inputs.gui_documents && '1' || '0' }}" "$ROOT/.github/workflows/e2e-hosted.yml"
    grep -Fq 'GUI Documents proof requires the real BitLocker on fixture' "$ROOT/tests/e2e/run-e2e.sh"
    grep -Fq 'gui-document-proof.py" edit' "$ROOT/tests/e2e/run-e2e.sh"
    grep -Fq 'gui-document-proof.py" reopen' "$ROOT/tests/e2e/run-e2e.sh"
}
