#Requires -Version 7.2
# Frees real space on C: of a hosted Windows runner so the installed-preview
# UI test can check an honest install plan.
#
# The engine only offers a plan whose Linux disk (20 GB at least) and the
# image's working space (22 GB at least, GetNativeInstallSpace) both fit in
# the drive's actual free space. The hosted runner's C: has had about 28 GB
# free (run 38908347372), and its other drive is not an eligible volume, so
# no plan could be checked there. This removes preinstalled toolchains that
# the remaining steps of the job do not use, then measures the drive again.
# It never reports more space than the drive has: the form, the engine and
# the test all read the drive's own free space.
#
# Run it after the publish and engine build steps: they use the Go and .NET
# toolchains, which this script never touches.
param(
    [int]$RequiredFreeGB = 50,
    [int]$TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
function FreeGB { [math]::Floor(([IO.DriveInfo]::new('C')).AvailableFreeSpace / 1GB) }
$before = FreeGB
Write-Output "C: has $before GB free before reclaim; the plan check needs $RequiredFreeGB GB"
if ($before -lt $RequiredFreeGB) {
    # Toolchains the packaging test never runs. dotnet, the NuGet cache, Go,
    # Git, PowerShell, the Windows SDK and Visual Studio stay.
    $candidates = @(
        'C:\Android',
        'C:\Program Files (x86)\Android',
        'C:\hostedtoolcache\windows\CodeQL',
        'C:\hostedtoolcache\windows\PyPy',
        'C:\hostedtoolcache\windows\Ruby',
        'C:\hostedtoolcache\windows\Java_Temurin-Hotspot_jdk',
        'C:\hostedtoolcache\windows\Python',
        'C:\hostedtoolcache\windows\node',
        'C:\ghcup',
        'C:\tools\ghc',
        'C:\msys64',
        'C:\Strawberry',
        'C:\Miniconda',
        'C:\Program Files\LLVM',
        'C:\Program Files\PostgreSQL',
        'C:\Program Files\MongoDB',
        'C:\Program Files\R',
        'C:\Program Files\Julia',
        'C:\SeleniumWebDrivers',
        'C:\vcpkg',
        'C:\Rust',
        (Join-Path $env:USERPROFILE '.rustup'),
        (Join-Path $env:USERPROFILE '.cargo')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $jobs = foreach ($path in $candidates) {
        Write-Output "  removing $path"
        Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList @('/d', '/c', 'rd', '/s', '/q', "`"$path`"") -WindowStyle Hidden -PassThru
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    foreach ($job in @($jobs)) {
        $left = [math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $job.WaitForExit($left)) { Write-Output "  still removing after $TimeoutSeconds s (pid $($job.Id)); measuring what is free now" }
    }
}
$after = FreeGB
Write-Output "C: has $after GB free after reclaim (freed $($after - $before) GB)"
if ($after -lt $RequiredFreeGB) {
    throw "C: has $after GB free, below the $RequiredFreeGB GB the installed-preview plan check needs. The test cannot check a plan honestly on this runner; see docs/winui-shell.md (Hosted plan check)."
}
if ($env:GITHUB_ENV) { Add-Content -LiteralPath $env:GITHUB_ENV -Value 'WOOTC_NATIVE_REQUIRE_PLAN_CHECK=1' }
