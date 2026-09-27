#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef BrandId
  #error BrandId is required
#endif
#ifndef ProductName
  #error ProductName is required
#endif
#ifndef Publisher
  #error Publisher is required
#endif
#ifndef BuildId
  #error BuildId is required
#endif

[Setup]
AppId=wootc-native-preview-{#BrandId}
AppName={#ProductName} Native Preview
AppVersion=0.1
AppPublisher={#Publisher}
DefaultDirName={autopf}\wootc Native Preview\{#BrandId}
DefaultGroupName={#ProductName} Native Preview
DisableDirPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename={#BrandId}-native-preview-{#BuildId}
Compression=lzma2
SolidCompression=yes
CloseApplications=no
RestartApplications=no
UninstallDisplayIcon={app}\bundle\Wootc.Shell.exe
UninstallDisplayName={#ProductName} Native Preview

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}\bundle"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#ProductName} Native Preview"; Filename: "{app}\bundle\Wootc.Shell.exe"

; The uninstaller owns only these recorded preview package files. There is no
; Linux uninstall callback, state cleanup, disk removal or boot configuration.

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if DirExists(ExpandConstant('{app}')) then
    Result := 'This preview destination already exists. Preserve its files and choose a fresh preview destination.';
end;
