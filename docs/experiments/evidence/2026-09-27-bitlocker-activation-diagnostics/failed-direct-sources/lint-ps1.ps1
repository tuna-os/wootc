#!/usr/bin/env pwsh
# lint-ps1.ps1 — static gate for the repo's PowerShell.
#
# WHY THIS EXISTS
# Nothing in this repo ever parsed its .ps1 files, so two real bugs shipped in
# tests/e2e/setup-wootc.ps1 and only surfaced deep inside a Windows VM, minutes
# into an E2E run, as a confusing mid-deploy failure:
#
#   1. "... exited with code $LASTEXITCODE: $out"
#      PowerShell parses the colon after a variable name as a SCOPE qualifier
#      ($env:X, $script:Y), so "$LASTEXITCODE:" is a syntax error. Five throw
#      statements could therefore never report their message — every one of
#      them died with a ParserError instead, hiding the actual bcdedit error.
#      Fix: ${LASTEXITCODE}:
#
#   2. $out = & bcdedit /enum $guid 2>&1      # <- no | Out-String
#      if ($out -notmatch 'path.*shimx64\.efi') { throw ... }
#      A native command's output is an ARRAY OF LINES. -match/-notmatch against
#      an array is a FILTER, not a boolean: it returns the matching (or
#      non-matching) elements. A multi-line output therefore returns a
#      non-empty array — which is truthy — so the check fired even when the
#      text was plainly present, and BCD verification failed 100% of the time.
#      Fix: pipe the capture through Out-String so it is one string.
#
# Bug 1 is a parse error and is caught definitively below. Bug 2 parses fine, so
# it gets a targeted AST check instead. Both are cheap; the whole thing runs in
# well under a second and needs only pwsh (GitHub's ubuntu images ship it).
#
# Usage: pwsh -NoProfile -File tests/lint-ps1.ps1 [files...]
#        With no arguments, lints every tracked *.ps1.

param([string[]]$Files)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

if (-not $Files -or $Files.Count -eq 0) {
    Push-Location $repoRoot
    try { $Files = @(& git ls-files '*.ps1') } finally { Pop-Location }
}
if (-not $Files -or $Files.Count -eq 0) {
    Write-Host 'no .ps1 files found — nothing to lint'
    exit 0
}

$failed = 0

foreach ($rel in $Files) {
    $path = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $repoRoot $rel }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "  ! skipping missing $rel"
        continue
    }

    # ── 1. Parse ────────────────────────────────────────────────────────────
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) {
            Write-Host "FAIL ${rel}:$($e.Extent.StartLineNumber): $($e.Message)"
        }
        $failed = 1
        # A file that does not parse cannot be walked for check 2.
        continue
    }

    # ── 2. -notmatch against un-stringified command output ──────────────────
    # Scope this tightly, because the naive version is almost all noise:
    #
    #   * -match on an array is FINE and idiomatic — it means "does any line
    #     match", which is exactly what callers want. Only -notmatch is broken,
    #     because it returns the non-matching lines (nearly always a non-empty,
    #     i.e. truthy, array) instead of a boolean.
    #   * Get-Content -Raw already returns ONE string.
    #   * A pipeline ending in Select-Object -First 1 yields a single item.
    #   * $x = "interpolated $(thing)" is a string, not command output — so
    #     only the TOP-LEVEL right-hand side counts, never a nested subexpression.
    $arrayVars = @{}
    $assignments = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true)

    foreach ($a in $assignments) {
        $left = $a.Left -as [System.Management.Automation.Language.VariableExpressionAst]
        if (-not $left) { continue }

        # TOP-LEVEL pipeline only — do not descend into subexpressions.
        $pipeline = $a.Right -as [System.Management.Automation.Language.PipelineAst]
        if (-not $pipeline) { continue }

        # Must actually invoke a command (rules out plain string/number RHS).
        $invokes = $pipeline.PipelineElements | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandAst]
        }
        if (-not $invokes) { continue }

        # Constructs that already collapse the result to a single value.
        $text = $pipeline.Extent.Text
        if ($text -match 'Out-String|-Raw\b|Select-Object\s+-First\s+1') { continue }

        $arrayVars[$left.VariablePath.UserPath] = $a.Extent.StartLineNumber
    }

    if ($arrayVars.Count -gt 0) {
        $binaries = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst]
        }, $true)

        foreach ($b in $binaries) {
            $op = $b.Operator.ToString()
            # -notmatch only; see the note above on why -match is legitimate.
            if ($op -ne 'Inotmatch' -and $op -ne 'Cnotmatch') { continue }

            $v = $b.Left -as [System.Management.Automation.Language.VariableExpressionAst]
            if (-not $v) { continue }

            $name = $v.VariablePath.UserPath
            if (-not $arrayVars.ContainsKey($name)) { continue }

            Write-Host ("FAIL ${rel}:$($b.Extent.StartLineNumber): " +
                "`$$name holds command output (assigned line $($arrayVars[$name])) " +
                'and is used with -match/-notmatch. Native command output is an ' +
                'ARRAY OF LINES, so -match filters instead of returning a bool — ' +
                'a multi-line value is always truthy. Pipe the assignment through ' +
                '| Out-String.')
            $failed = 1
        }
    }

    if ($failed -eq 0) { Write-Host "  ok $rel" }
}

if ($failed -ne 0) {
    Write-Host ''
    Write-Host 'PowerShell lint FAILED'
    exit 1
}
Write-Host 'PowerShell lint passed'
exit 0
