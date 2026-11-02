param(
    [Parameter(Mandatory=$true)][ValidateSet('install','return')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$Directory
)
# Run in the logged-on fixture session, never in QGA's noninteractive desktop.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeProofDesktop {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
}
'@
$config = Get-Content -LiteralPath (Join-Path $Directory 'context.json') -Raw | ConvertFrom-Json
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-Json($Name, $Value) {
    [IO.File]::WriteAllText((Join-Path $Directory $Name), ($Value | ConvertTo-Json -Depth 16), $utf8)
}
function Observe($Journey, $Required) {
    $processes = @(Get-Process -Name Wootc.Shell -ErrorAction SilentlyContinue)
    if ($processes.Count -ne 1) { return $false }
    $process = $processes[0]
    $path = $process.MainModule.FileName
    if ($path -ne $config.packagePath) { throw 'Observed shell is outside the installed package' }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $config.identity.artifactSha256) { throw 'Observed shell differs from this run package' }
    $condition = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $condition)
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) { return $false }
    [NativeProofDesktop]::ShowWindow($process.MainWindowHandle, 3) | Out-Null
    [uint32]$foregroundProcess = 0
    [NativeProofDesktop]::GetWindowThreadProcessId([NativeProofDesktop]::GetForegroundWindow(), [ref]$foregroundProcess) | Out-Null
    if ($foregroundProcess -ne $process.Id) {
        [NativeProofDesktop]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
        return $false
    }
    $controls = New-Object Collections.Generic.List[object]
    $elements = @{}
    foreach ($window in $windows) {
        $descendants = $window.FindAll([Windows.Automation.TreeScope]::Subtree, [Windows.Automation.Condition]::TrueCondition)
        if ($descendants.Count -gt 4096) { throw 'UIA tree exceeds proof bound' }
        foreach ($element in $descendants) {
            $current = $element.Current
            if ($current.IsPassword) { continue }
            $rect = $current.BoundingRectangle
            $value = $null
            $pattern = $null
            if ($element.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) { $value = $pattern.Current.Value }
            $toggle = $null
            $pattern = $null
            if ($element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { $toggle = $pattern.Current.ToggleState.ToString() }
            $control = [ordered]@{automationId=$current.AutomationId; name=$current.Name; value=$value; toggleState=$toggle;
                visible=(-not $current.IsOffscreen -and $rect.Width -gt 0 -and $rect.Height -gt 0); enabled=$current.IsEnabled;
                controlType=$current.ControlType.ProgrammaticName; processId=$current.ProcessId;
                bounds=@{x=$rect.X;y=$rect.Y;width=$rect.Width;height=$rect.Height}}
            $controls.Add($control)
            if ($current.AutomationId) {
                if (-not $elements.ContainsKey($current.AutomationId)) { $elements[$current.AutomationId] = @() }
                $elements[$current.AutomationId] += $element
            }
        }
    }
    $actionId = $null
    if ($Mode -eq 'return') {
        $connection = @($controls | Where-Object { $_.automationId -eq 'ConnectionStatus' })
        if ($connection.Count -ne 1) { return $false }
        if ($connection[0].name -ne 'Ready') {
            if ($script:startupInvoked) { return $false }
            $actionId = 'ConnectEngine'
        } elseif (-not $script:installationInvoked) {
            $actionId = 'ReadInstallation'
        }
        if ($actionId) { $Required = @($actionId) }
    }
    foreach ($id in $Required) {
        $matches = @($controls | Where-Object { $_.automationId -eq $id })
        if ($matches.Count -ne 1 -or -not $matches[0].enabled) { return $false }
        if (-not $matches[0].visible) {
            # Real UIA scrolling, never marking an offscreen control visible.
            # Re-observe the full tree and framebuffer on the next iteration.
            $element = $elements[$id][0]
            $scroll = $null
            if ($element.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$scroll)) {
                $scroll.ScrollIntoView()
            } else {
                $ancestor = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($element)
                while ($ancestor -and $ancestor.Current.ProcessId -eq $process.Id) {
                    $scroll = $null
                    if ($ancestor.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$scroll) -and $scroll.Current.VerticallyScrollable) {
                        $percent = if ($Journey -eq 'windows-return') { 0.0 } else { 100.0 }
                        $scroll.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, $percent)
                        break
                    }
                    $ancestor = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor)
                }
            }
            return $false
        }
    }
    if ($actionId) {
        # Authenticate/open maintenance through the actual visible UI actions.
        # Connection readiness is re-read from UIA before ReadInstallation.
        $elements[$actionId][0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        if ($actionId -eq 'ConnectEngine') { $script:startupInvoked = $true }
        if ($actionId -eq 'ReadInstallation') { $script:installationInvoked = $true }
        return $false
    }
    if ($Journey -eq 'install-confirmation' -and $elements.InstallConfirmation[0].Current.Name -ne 'Ready to install') { throw 'Unexpected install dialog' }
    if ($Journey -eq 'windows-return') {
        $os = Get-CimInstance Win32_OperatingSystem
        if ($env:OS -ne 'Windows_NT' -or -not $os.Version -or -not $os.LastBootUpTime) { throw 'Current Windows identity unavailable' }
        Write-Json 'windows-current-observation.json' @{runId=$config.runId;runAttempt=$config.runAttempt;sourceSha=$config.sourceSha;
            observer='windows-cim';capturedAt=[DateTime]::UtcNow.ToString('o');version=$os.Version;bootTime=$os.LastBootUpTime.ToUniversalTime().ToString('o')}
    }
    $stamp = [DateTime]::UtcNow.ToString('o')
    $screen = [Windows.Forms.SystemInformation]::VirtualScreen
    $bitmap = New-Object Drawing.Bitmap($screen.Width,$screen.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($screen.Left,$screen.Top,0,0,$bitmap.Size)
        $bitmap.Save((Join-Path $Directory "$Journey.png"), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    $frame = Join-Path $Directory "$Journey.png"
    Write-Json "$Journey.uia.json" @{runId=$config.runId;runAttempt=$config.runAttempt;sourceSha=$config.sourceSha;capturedAt=$stamp;
        processId=$process.Id;processName='Wootc.Shell.exe';processPath=$path;processImageSha256=$hash;controls=@($controls.ToArray())}
    Write-Json "$Journey.observation.json" @{journey=$Journey;capturedAt=$stamp;uiaFile="$Journey.uia.json";
        framebufferFile="$Journey.png";framebufferSha256=(Get-FileHash -LiteralPath $frame -Algorithm SHA256).Hash.ToLowerInvariant()}
    if ($Journey -eq 'install-confirmation') {
        # The observer, not drive mode, accepts the real dialog, only AFTER capture.
        $buttons = $elements.InstallConfirmation[0].FindAll([Windows.Automation.TreeScope]::Descendants,
            (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button)))
        $install = @($buttons | Where-Object { $_.Current.AutomationId -eq 'PrimaryButton' -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
        if ($install.Count -ne 1) { throw 'Unique enabled dialog Install action unavailable' }
        $install[0].GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    return $true
}
try {
    $deadline = [DateTime]::UtcNow.AddMinutes(20)
    $journeys = if ($Mode -eq 'install') { @('install-confirmation') } else { @('installed-boot-summary','windows-return') }
    foreach ($journey in $journeys) {
        $required = switch ($journey) {
            'install-confirmation' { @('InstallConfirmation') }
            'installed-boot-summary' { @('InstalledBootSource','InstalledBootKernel','InstalledBootBridge','InstalledBootId') }
            'windows-return' { @('WindowsReturnStatus') }
        }
        $observed = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Observe $journey $required) { $observed=$true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $observed) { throw "Native UIA journey timed out: $journey" }
    }
    [IO.File]::WriteAllText((Join-Path $Directory "$Mode.done"), 'observed', $utf8)
} catch {
    [IO.File]::WriteAllText((Join-Path $Directory "$Mode.error"), $_.Exception.ToString(), $utf8)
    exit 1
}
