#!/usr/bin/env bats
# #219: no Windows launch path may open a console window.

setup() {
    cd "$BATS_TEST_DIRNAME/../.."
}

@test "the shared Windows builder links the GUI subsystem" {
    grep -q -- '-H windowsgui' packaging/build-windows.py
}

@test "every direct Windows wootc build links the GUI subsystem" {
    # The WinUI shell starts wootc-engine.exe --native-serve through a runas
    # ShellExecute. A console-subsystem engine gets a fresh elevated console
    # window there, so the engine build must link -H windowsgui as well.
    local line bad=0
    while IFS= read -r line; do
        case "$line" in
            *'-H windowsgui'*) ;;
            *) echo "missing -H windowsgui: $line"; bad=1 ;;
        esac
    done < <(grep -hE 'go build .*-o [^ ]*(wootc|wootc-engine)\.exe' \
        .github/workflows/*.yml tests/e2e/phase1/run-phase1.sh tests/gui/run-cdp.sh)
    [ "$bad" -eq 0 ]
}

@test "headless subcommands attach to the parent console" {
    # A GUI-subsystem binary has no console of its own; install, status and
    # uninstall must still print when run from PowerShell or cmd.
    grep -q 'attachParentConsole()' app/headless.go
    grep -q 'ATTACH_PARENT_PROCESS\|attachParentProcess' app/console_windows.go
}
