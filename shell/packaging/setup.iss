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
#ifndef Version
  #error Version is required
#endif
#ifndef OutputBaseName
  #error OutputBaseName is required
#endif

[Setup]
AppId=wootc-native-{#BrandId}
AppName={#ProductName}
AppVersion={#Version}
AppPublisher={#Publisher}
DefaultDirName={autopf}\wootc Native\{#BrandId}
DefaultGroupName={#ProductName}
DisableDirPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
Compression=lzma2
SolidCompression=yes
CloseApplications=no
RestartApplications=no
UninstallDisplayIcon={app}\bundle\Wootc.Shell.exe
UninstallDisplayName={#ProductName}

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}\bundle"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#ProductName}"; Filename: "{app}\bundle\Wootc.Shell.exe"

; A setup package owns only its protected shell bundle. Linux state lives in
; C:\wootc and is removed by the shell's explicit uninstall flow, not by this
; Windows package removal.

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if DirExists(ExpandConstant('{app}')) then
    Result := 'This setup destination already exists. Remove the existing shell before installing this release.';
end;
