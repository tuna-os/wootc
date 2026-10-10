@{
ModuleVersion = '1.0.0.0'
GUID = '0ff02bb8-300a-4262-ac08-e06dd810f1b6'
Author = 'Microsoft Corporation'
CompanyName = 'Microsoft Corporation'
Copyright = '(c) Microsoft Corporation. All rights reserved.'
FormatsToProcess = @('BitLocker.Format.ps1xml')
ModuleToProcess = 'BitLocker'
NestedModules=@('Microsoft.BitLocker.Structures')
HelpInfoUri="https://aka.ms/winsvr-2025-pshelp"
PowerShellVersion='5.1'
CompatiblePSEditions = @('Desktop', 'Core')
CLRVersion='4.0'
FunctionsToExport=@('Unlock-BitLocker', 'Suspend-BitLocker', 'Resume-BitLocker', 'Remove-BitLockerKeyProtector', 'Lock-BitLocker', 'Get-BitLockerVolume', 'Enable-BitLockerAutoUnlock', 'Enable-BitLocker', 'Disable-BitLockerAutoUnlock', 'Disable-BitLocker', 'Clear-BitLockerAutoUnlock', 'Backup-BitLockerKeyProtector', 'BackupToAAD-BitLockerKeyProtector', 'BackupToMSA-BitLockerKeyProtector', 'Add-BitLockerKeyProtector')
}

