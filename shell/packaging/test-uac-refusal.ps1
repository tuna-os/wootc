#Requires -Version 7.2
# Real UAC refusal against the installed preview. A disposable standard user
# runs the installed shell; ConsentPromptBehaviorUser=0 makes Windows itself
# deny that user's elevation request (ERROR_ACCESS_DISABLED_BY_POLICY). The prior policy
# value and the account are restored/removed whatever the outcome.
param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [Parameter(Mandatory=$true)][string]$BrandSource,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$BrandId
)
$ErrorActionPreference='Stop'
$policyPath='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$policy=Get-ItemProperty -LiteralPath $policyPath
$priorUser=$policy.ConsentPromptBehaviorUser
$observed=[ordered]@{schemaVersion=1;brandId=$BrandId;enableLua=$policy.EnableLUA;consentPromptBehaviorAdmin=$policy.ConsentPromptBehaviorAdmin;priorConsentPromptBehaviorUser=$priorUser;promptOnSecureDesktop=$policy.PromptOnSecureDesktop}
$name='wootc_uac_' + [guid]::NewGuid().ToString('N').Substring(0,8)
$secret=[guid]::NewGuid().ToString('N') + 'aA1!'
$computer=[ADSI]"WinNT://$env:COMPUTERNAME,computer"
$created=$false
$sid=$null
try {
    $account=$computer.Create('User',$name)
    $account.SetPassword($secret)
    $account.Put('Description','wootc disposable UAC refusal fixture')
    $account.SetInfo()
    $created=$true
    $sid=([Security.Principal.NTAccount]::new($name)).Translate([Security.Principal.SecurityIdentifier]).Value
    $admins=([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    $members=@(([ADSI]"WinNT://$env:COMPUTERNAME/$admins,group").psbase.Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('Name','GetProperty',$null,$_,$null) })
    if ($members -contains $name) { throw 'Disposable refusal account is an administrator' }
    Set-ItemProperty -LiteralPath $policyPath -Name ConsentPromptBehaviorUser -Value 0 -Type DWord
    $env:WOOTC_UAC_REFUSAL_USER=$name
    $env:WOOTC_UAC_REFUSAL_PASSWORD=$secret
    $env:WOOTC_NATIVE_INSTALLED_EXE=$Executable
    $env:WOOTC_NATIVE_BRAND_SOURCE=$BrandSource
    $info=[Diagnostics.ProcessStartInfo]::new('dotnet')
    $info.UseShellExecute=$false
    foreach ($argument in @('test',(Join-Path $PSScriptRoot '../Wootc.Shell.UiTests'),'--configuration','Release','--no-build','--filter','FullyQualifiedName~UacRefusalTests','--logger',"trx;LogFileName=uac-refusal-$BrandId.trx")) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit(240000)) { $process.Kill($true); $process.WaitForExit(); throw 'UAC refusal test exceeded its deadline' }
        if ($process.ExitCode -ne 0) { throw "UAC refusal test failed with exit $($process.ExitCode)" }
    } finally { $process.Dispose() }
    $observed.standardUserSid=$sid
    $observed.realUacRefusalObserved=$true
} finally {
    foreach ($key in @('WOOTC_UAC_REFUSAL_USER','WOOTC_UAC_REFUSAL_PASSWORD')) { [Environment]::SetEnvironmentVariable($key,$null,'Process') }
    if ($null -eq $priorUser) { Remove-ItemProperty -LiteralPath $policyPath -Name ConsentPromptBehaviorUser -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -LiteralPath $policyPath -Name ConsentPromptBehaviorUser -Value $priorUser -Type DWord }
    if ($created) {
        $computer.Delete('User',$name)
        if ($sid) { Get-CimInstance Win32_UserProfile | Where-Object SID -eq $sid | Remove-CimInstance }
    }
    $observed.restoredConsentPromptBehaviorUser=(Get-ItemProperty -LiteralPath $policyPath).ConsentPromptBehaviorUser
    $observed | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory "uac-refusal-$BrandId.json") -Encoding utf8
}
if ($observed.restoredConsentPromptBehaviorUser -ne $priorUser) { throw 'UAC policy was not restored' }
Write-Output "PASS actual $BrandId UAC refusal by Windows for a standard user; branded assessment and retry retained"
