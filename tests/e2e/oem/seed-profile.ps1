# seed-profile.ps1
# Populates a comprehensive, realistic "typical" Windows user profile for testing wootc.
#
# Covers:
#   1. Standard personal folders (Documents, Pictures, Downloads, Music, Videos, Desktop)
#   2. Browser profiles & preferences (Google Chrome, Microsoft Edge, Mozilla Firefox)
#   3. MS Office / Productivity components (Custom dictionary, templates, fonts, autocorrect)
#   4. Developer & productivity applications (VS Code settings/keybindings/snippets/extensions,
#      Discord, Spotify, Telegram Desktop, VLC, GIMP, OBS Studio, Steam library), the
#      Windows OpenSSH key pair, ssh config, known_hosts and a git config
#   4b. Printers: network (reachable and not), parallel-port, virtual; the user's default
#   5. Windows Registry entries (Installed apps in Uninstall keys, URL associations, Run startup keys, Theme/Accent color)
#   6. Canary marker wootc-e2e-userdata.txt for E2E persistence assertions
#   7. Migration corpus (nested, unicode-named, empty to 64 MiB files with fixed
#      timestamps in every known folder), a real font, account picture and
#      wallpaper, Windows time zone and languages, the account's full name, and
#      the expected-state manifest the Linux side is checked against
#      (tests/e2e/migration-check.py)

param(
    [string]$Username = "wootc",
    [string]$Drive = "C:",
    [string]$RunId = "test-run",
    [switch]$IncludeRegistry = $true,
    # Expected-state manifest: UTF-8 TSV, "#key=value" header lines then
    # "category<TAB>profile-relative path<TAB>size<TAB>sha256<TAB>mtime".
    [string]$ManifestPath = "C:\ProgramData\wootc-e2e\migration-expected.tsv"
)

$ErrorActionPreference = "Stop"

if (-not $Drive.EndsWith(":")) {
    $Drive = "${Drive}:"
}

$userProfile = "$Drive\Users\$Username"
$appDataRoaming = "$userProfile\AppData\Roaming"
$appDataLocal = "$userProfile\AppData\Local"

Write-Host "[seed-profile] Seeding pre-filled Windows profile for '$Username' at '$userProfile' (RunId: $RunId)..."

# A per-run tag for names a person chooses (printers, the full name): the same
# six hex digits the harness derives (sha256sum of RunId) for Wi-Fi SSIDs.
$runHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($RunId))).Replace("-", "").ToLowerInvariant()
$suffix = $runHash.Substring(0, 6)
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Full name (vault full_name -> GECOS): unicode and an apostrophe, both of
# which a recipe built by string interpolation would mangle.
$fullName = "Zo$([char]0x00EB) O'Brien-$([char]0x00C5)berg $suffix"
Set-LocalUser -Name $Username -FullName $fullName

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-TextFile([string]$Path, [string]$Content, [string]$Encoding = "UTF8") {
    $parent = Split-Path -Parent $Path
    Ensure-Directory $parent
    Set-Content -LiteralPath $Path -Value $Content -Encoding $Encoding -Force
}

# ── 1. Standard Personal Folders ─────────────────────────────────────────────
$docsDir = "$userProfile\Documents"
$picsDir = "$userProfile\Pictures"
$wallpaper = "$picsDir\wootc-e2e-wallpaper.jpg"
$downDir = "$userProfile\Downloads"
$musicDir = "$userProfile\Music"
$videoDir = "$userProfile\Videos"
$deskDir = "$userProfile\Desktop"

Ensure-Directory $docsDir
Ensure-Directory $picsDir
Ensure-Directory $downDir
Ensure-Directory $musicDir
Ensure-Directory $videoDir
Ensure-Directory $deskDir

# Canary marker required by E2E runner for data persistence proof
Write-TextFile "$docsDir\wootc-e2e-userdata.txt" "wootc-e2e-userdata $RunId" "ASCII"

# Realistic documents and files
Write-TextFile "$docsDir\Work\Quarterly_Report.docx" "Fake Word Document Content for Quarterly Report"
Write-TextFile "$docsDir\Work\Notes.txt" "Meeting notes: Linux migration plan and requirements."
Write-TextFile "$docsDir\Finance\2025_Tax_Return.pdf" "%PDF-1.4 Mock Tax Return PDF Document Content"
Write-TextFile "$docsDir\Projects\wootc-notes.md" "# wootc Notes`nTesting with pre-filled Windows profile."

Write-TextFile "$picsDir\wallpaper.jpg" "JPEG_MOCK_IMAGE_DATA_WALLPAPER" "ASCII"
Write-TextFile "$picsDir\Vacation\beach.jpg" "JPEG_MOCK_IMAGE_DATA_VACATION" "ASCII"
Write-TextFile "$picsDir\Screenshots\screenshot_01.png" "PNG_MOCK_IMAGE_DATA_SCREENSHOT" "ASCII"

Write-TextFile "$downDir\sample_installer.exe" "MOCK_EXE_BINARY_DATA" "ASCII"
Write-TextFile "$downDir\dataset.zip" "PK_ZIP_MOCK_ARCHIVE_DATA" "ASCII"

Write-TextFile "$musicDir\SampleArtist - SampleSong.mp3" "MOCK_MP3_AUDIO_DATA" "ASCII"
Write-TextFile "$videoDir\family_trip.mp4" "MOCK_MP4_VIDEO_DATA" "ASCII"
Write-TextFile "$deskDir\Daily_Tasks.txt" "1. Check emails`n2. Test wootc migration`n3. Review Linux apps"

# ── 2. Browser Profiles & Preferences ────────────────────────────────────────
# Google Chrome
$chromeUserData = "$appDataLocal\Google\Chrome\User Data\Default"
Ensure-Directory $chromeUserData
$chromeBookmarksJson = @'
{
  "checksum": "d41d8cd98f00b204e9800998ecf8427e",
  "roots": {
    "bookmark_bar": {
      "children": [
        {
          "date_added": "13300000000000000",
          "id": "1",
          "name": "GitHub - TunaOS",
          "type": "url",
          "url": "https://github.com/tuna-os/wootc"
        },
        {
          "date_added": "13300000000000001",
          "id": "2",
          "name": "Linux Documentation",
          "type": "url",
          "url": "https://docs.kernel.org"
        },
        {
          "children": [
            {
              "date_added": "13300000000000002",
              "id": "4",
              "name": "DuckDuckGo",
              "type": "url",
              "url": "https://duckduckgo.com"
            }
          ],
          "date_added": "13300000000000003",
          "id": "3",
          "name": "Dev Tools",
          "type": "folder"
        }
      ],
      "date_added": "13300000000000000",
      "id": "0",
      "name": "Bookmarks bar",
      "type": "folder"
    },
    "other": { "children": [], "date_added": "0", "id": "other", "name": "Other bookmarks", "type": "folder" },
    "synced": { "children": [], "date_added": "0", "id": "synced", "name": "Mobile bookmarks", "type": "folder" }
  },
  "version": 1
}
'@
Write-TextFile "$chromeUserData\Bookmarks" $chromeBookmarksJson
Write-TextFile "$chromeUserData\History" "SQLite format 3 - Mock Chrome History Database" "ASCII"
Write-TextFile "$chromeUserData\Preferences" '{"browser":{"show_home_button":true}}'

# Microsoft Edge
$edgeUserData = "$appDataLocal\Microsoft\Edge\User Data\Default"
Ensure-Directory $edgeUserData
# Distinct from Chrome's, so a Linux copy of either is attributable.
Write-TextFile "$edgeUserData\Bookmarks" $chromeBookmarksJson.Replace("Linux Documentation", "Edge Reading List $RunId")
Write-TextFile "$edgeUserData\History" "SQLite format 3 - Mock Edge History Database" "ASCII"

# Mozilla Firefox
$firefoxDir = "$appDataRoaming\Mozilla\Firefox"
$firefoxProfileRel = "Profiles/typical.default-release"
$firefoxProfileDir = "$firefoxDir\$firefoxProfileRel"
Ensure-Directory $firefoxProfileDir

$firefoxProfilesIni = @"
[Install0]
Default=$firefoxProfileRel

[Profile0]
Name=default
IsRelative=1
Path=$firefoxProfileRel
Default=1

[General]
StartWithLastProfile=1
Version=2
"@
Write-TextFile "$firefoxDir\profiles.ini" $firefoxProfilesIni
Write-TextFile "$firefoxProfileDir\places.sqlite" "SQLite format 3 - Mock Firefox Places History/Bookmarks" "ASCII"
$firefoxLoginsJson = @'
{
  "nextId": 2,
  "logins": [
    {
      "id": 1,
      "hostname": "https://github.com",
      "httpRealm": null,
      "formSubmitURL": "https://github.com/session",
      "usernameField": "login",
      "passwordField": "password",
      "encryptedUsername": "alice",
      "encryptedPassword": "password123",
      "guid": "{11111111-2222-3333-4444-555555555555}"
    }
  ],
  "version": 3
}
'@
Write-TextFile "$firefoxProfileDir\logins.json" $firefoxLoginsJson
Write-TextFile "$firefoxProfileDir\prefs.js" 'user_pref("browser.startup.homepage", "https://github.com/tuna-os/wootc");'
Write-TextFile "$firefoxProfileDir\extensions.json" '{"addons":[{"id":"uBlock0@raymondhill.net","name":"uBlock Origin"}]}'

# ── 3. MS Office / Productivity Components ──────────────────────────────────
$uproofDir = "$appDataRoaming\Microsoft\UProof"
Ensure-Directory $uproofDir
# CUSTOM.DIC with CRLF
Write-TextFile "$uproofDir\CUSTOM.DIC" "Kubernetes`r`nwootc`r`nTunaOS`r`ncontainerd`r`nMicroOS`r`n" "UTF8"

$templatesDir = "$appDataRoaming\Microsoft\Templates"
Ensure-Directory $templatesDir
Write-TextFile "$templatesDir\Report.dotx" "MOCK_WORD_TEMPLATE_DATA_REPORT" "ASCII"
Write-TextFile "$templatesDir\Invoice.xltx" "MOCK_EXCEL_TEMPLATE_DATA_INVOICE" "ASCII"
Write-TextFile "$templatesDir\Presentation.potx" "MOCK_POWERPOINT_TEMPLATE_DATA" "ASCII"

$officeDir = "$appDataRoaming\Microsoft\Office"
Ensure-Directory $officeDir
# default.acl: UTF-16LE with sample replacement pairs (e.g. tehm => them, teh => the)
$aclBytes = [System.Text.Encoding]::Unicode.GetBytes("tehm`0them`0teh`0the`0woot`0wootc`0")
[System.IO.File]::WriteAllBytes("$officeDir\default.acl", $aclBytes)

# Per-user fonts the Office bridge copies to ~/.local/share/fonts. A REAL
# TrueType file (a copy of a stock Windows font under a unique name), so the
# Linux side can prove fontconfig parsed it, not merely that bytes moved.
$fontsDir = "$appDataLocal\Microsoft\Windows\Fonts"
Ensure-Directory $fontsDir
$stockFont = @("$env:WINDIR\Fonts\arial.ttf", "$env:WINDIR\Fonts\consola.ttf", "$env:WINDIR\Fonts\segoeui.ttf") |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $stockFont) { throw "no stock TrueType font found to seed the per-user font" }
Copy-Item -LiteralPath $stockFont -Destination "$fontsDir\WootcE2E-Sans.ttf" -Force

# ── 4. Developer & Creative & Comms Applications ────────────────────────────
# VS Code
$vscUserDir = "$appDataRoaming\Code\User"
$vscSnippetsDir = "$vscUserDir\snippets"
Ensure-Directory $vscSnippetsDir
$vscSettings = @'
{
  "editor.fontSize": 14,
  "editor.tabSize": 4,
  "editor.renderWhitespace": "selection",
  "workbench.colorTheme": "Default Dark+",
  "files.autoSave": "afterDelay"
}
'@
$vscKeybindings = @'
[
  {
    "key": "ctrl+shift+t",
    "command": "workbench.action.terminal.toggleTerminal"
  }
]
'@
$vscSnippet = @'
{
  "Header": {
    "prefix": "docheader",
    "body": [
      "# -*- coding: utf-8 -*-",
      "\"\"\"$TM_FILENAME: ${1:Description}\"\"\""
    ]
  }
}
'@
Write-TextFile "$vscUserDir\settings.json" $vscSettings
Write-TextFile "$vscUserDir\keybindings.json" $vscKeybindings
Write-TextFile "$vscSnippetsDir\python.json" $vscSnippet

$vscExtDir = "$userProfile\.vscode\extensions"
Ensure-Directory "$vscExtDir\ms-python.python-2024.1.0"
Ensure-Directory "$vscExtDir\golang.go-0.41.0"
Write-TextFile "$vscExtDir\ms-python.python-2024.1.0\package.json" '{"name":"python","publisher":"ms-python","version":"2024.1.0"}'
Write-TextFile "$vscExtDir\golang.go-0.41.0\package.json" '{"name":"go","publisher":"golang","version":"0.41.0"}'

# Comms apps
Ensure-Directory "$appDataRoaming\discord"
Write-TextFile "$appDataRoaming\discord\settings.json" '{"DCA_USER_SETTINGS":{"theme":"dark"}}'

Ensure-Directory "$appDataRoaming\Slack"
Write-TextFile "$appDataRoaming\Slack\storage.json" '{"teams":{}}'

Ensure-Directory "$appDataRoaming\Spotify"
Write-TextFile "$appDataRoaming\Spotify\prefs" 'autologin.username="alice"'

Ensure-Directory "$appDataRoaming\Telegram Desktop\tdata"
Write-TextFile "$appDataRoaming\Telegram Desktop\tdata\settingss" "MOCK_TELEGRAM_TDATA_PAYLOAD" "ASCII"

# Media / Creative apps
Ensure-Directory "$appDataRoaming\vlc"
Write-TextFile "$appDataRoaming\vlc\vlcrc" "volume=256`n[main]`n"

Ensure-Directory "$appDataRoaming\GIMP\2.10"
Write-TextFile "$appDataRoaming\GIMP\2.10\gimprc" "(language `"en`")`n"
Write-TextFile "$appDataRoaming\audacity\audacity.cfg" "[Directories]`nTempDir=`n"
Write-TextFile "$appDataRoaming\inkscape\preferences.xml" "<inkscape version=`"1.4`" />`n"

Ensure-Directory "$appDataRoaming\obs-studio\basic\scenes"
Write-TextFile "$appDataRoaming\obs-studio\basic\scenes\default.json" '{"name":"Default Scene"}'

# Developer setup (SPEC section 4.6): the Windows OpenSSH client's key pair,
# ssh config and known_hosts, and a git config mixing the identity with
# Windows-only settings. Only public material and the identity may migrate.
$sshDir = "$userProfile\.ssh"
if (Test-Path -LiteralPath $sshDir) { Remove-Item -LiteralPath $sshDir -Recurse -Force }
Ensure-Directory $sshDir
$keygen = "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe"
if (-not (Test-Path -LiteralPath $keygen)) { throw "ssh-keygen.exe (the Windows OpenSSH client) is missing; cannot seed the developer setup" }
# One argument string: PowerShell 5.1 drops an empty-string argument (-N "").
$keygenRun = Start-Process -FilePath $keygen -ArgumentList "-q -t ed25519 -N `"`" -C wootc-e2e-$RunId -f `"$sshDir\id_ed25519`"" -Wait -NoNewWindow -PassThru
if ($keygenRun.ExitCode -ne 0 -or -not (Test-Path -LiteralPath "$sshDir\id_ed25519.pub")) { throw "ssh-keygen.exe failed (exit $($keygenRun.ExitCode))" }
$keyBlob = ([System.IO.File]::ReadAllText("$sshDir\id_ed25519.pub")).Split(" ")[1]
$sshHostAlias = "wootc-e2e-git"
$sshHostName = "git.example.org"
[System.IO.File]::WriteAllText("$sshDir\config", "Host $sshHostAlias`n  HostName $sshHostName`n  User git`n  IdentityFile ~/.ssh/id_ed25519`n", $utf8NoBom)
[System.IO.File]::WriteAllText("$sshDir\known_hosts", "$sshHostName ssh-ed25519 $keyBlob`n", $utf8NoBom)
$gitName = $fullName
$gitEmail = "zoe.obrien+$suffix@example.org"
[System.IO.File]::WriteAllText("$userProfile\.gitconfig",
    "[user]`n`tname = $gitName`n`temail = $gitEmail`n[core]`n`tautocrlf = true`n[credential]`n`thelper = manager`n[init]`n`tdefaultBranch = main`n", $utf8NoBom)

# Steam default library & extra library
$steamProgramFiles = "$Drive\Program Files (x86)\Steam"
Ensure-Directory "$steamProgramFiles\steamapps\common\HL3"
$steamLibraryVdf = @"
"libraryfolders"
{
	"0"
	{
		"path"		"$($steamProgramFiles.Replace('\', '\\'))"
	}
	"1"
	{
		"path"		"$($Drive.Replace('\', '\\'))\\Games\\SteamLibrary"
	}
}
"@
Write-TextFile "$steamProgramFiles\steamapps\libraryfolders.vdf" $steamLibraryVdf "ASCII"
Ensure-Directory "$Drive\Games\SteamLibrary\steamapps\common\Portal9"
Write-TextFile "$steamProgramFiles\steamapps\common\HL3\hl3.exe" "MOCK_STEAM_GAME_EXE" "ASCII"
Write-TextFile "$Drive\Games\SteamLibrary\steamapps\common\Portal9\portal9.exe" "MOCK_STEAM_GAME_EXE" "ASCII"

# ── 4b. Printers ─────────────────────────────────────────────────────────────
# A network printer at an address the Linux side can answer driverless IPP
# on (the check runs an IPP Everywhere responder at 127.0.0.2:631), one on an
# unreachable network address, one on a parallel cable, and the stock
# virtual PDF printer. No port is contacted when it is created.
foreach ($stale in @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Office Laser|Lab Printer|Label Printer) [0-9a-f]{6}$' })) {
    Remove-Printer -Name $stale.Name
}
$printerDriver = ""
try {
    Add-PrinterDriver -Name "Microsoft IPP Class Driver" -ErrorAction Stop
    $printerDriver = "Microsoft IPP Class Driver"
} catch {
    $printerDriver = (Get-PrinterDriver | Where-Object { $_.Name -like "Microsoft*" } | Select-Object -First 1).Name
}
if (-not $printerDriver) { throw "no printer driver available to seed the printers" }
foreach ($port in @(@{ Name = "IP_127.0.0.2"; Address = "127.0.0.2" }, @{ Name = "IP_192.0.2.44"; Address = "192.0.2.44" })) {
    if (-not (Get-PrinterPort -Name $port.Name -ErrorAction SilentlyContinue)) {
        Add-PrinterPort -Name $port.Name -PrinterHostAddress $port.Address -PortNumber 9100
    }
}
$officePrinter = "Office Laser $suffix"
$labPrinter = "Lab Printer $suffix"
$labelPrinter = "Label Printer $suffix"
Add-Printer -Name $officePrinter -DriverName $printerDriver -PortName "IP_127.0.0.2"
Add-Printer -Name $labPrinter -DriverName $printerDriver -PortName "IP_192.0.2.44"
Add-Printer -Name $labelPrinter -DriverName $printerDriver -PortName "LPT1:"
$virtualPrinter = (Get-Printer -Name "Microsoft Print to PDF" -ErrorAction SilentlyContinue).Name

# ── 5. Windows Registry Entries (Installed Apps, Associations, Theme) ────────
# QGA runs this script as SYSTEM, so "HKCU:" is SYSTEM's own hive. Everything
# per-user is written into the migrating user's hive (HKEY_USERS\<SID>, or
# their NTUSER.DAT loaded for the duration) — the engine reads the
# interactive user's HKCU, and seeding SYSTEM's hive tested nothing.
# Installed apps go to HKLM: machine-wide installs are the common case and
# the engine enumerates both.
function Open-UserHive {
    $sid = (New-Object System.Security.Principal.NTAccount($Username)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $root = "Registry::HKEY_USERS\$sid"
    if (Test-Path -LiteralPath $root) { return @{ Root = $root; Loaded = $false } }
    $out = & reg.exe load "HKU\wootc-e2e-seed" "$userProfile\NTUSER.DAT" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "cannot load the registry hive of $Username : $out" }
    return @{ Root = "Registry::HKEY_USERS\wootc-e2e-seed"; Loaded = $true }
}
function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Type = "String") {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

if ($IncludeRegistry) {
    Write-Host "[seed-profile] Seeding Windows registry entries for installed apps and associations..."
    $appsToRegister = @(
        @{ Key = "GoogleChrome"; Name = "Google Chrome"; Pub = "Google LLC"; Loc = "$Drive\Program Files\Google\Chrome\Application"; Ver = "124.0.6367.201" },
        @{ Key = "MozillaFirefox"; Name = "Mozilla Firefox"; Pub = "Mozilla"; Loc = "$Drive\Program Files\Mozilla Firefox"; Ver = "125.0.3" },
        @{ Key = "VSCode"; Name = "Microsoft Visual Studio Code"; Pub = "Microsoft Corporation"; Loc = "$appDataLocal\Programs\Microsoft VS Code"; Ver = "1.89.1" },
        @{ Key = "Discord"; Name = "Discord"; Pub = "Discord Inc."; Loc = "$appDataLocal\Discord\app-1.0.9038"; Ver = "1.0.9038" },
        @{ Key = "Spotify"; Name = "Spotify"; Pub = "Spotify Ltd"; Loc = "$appDataRoaming\Spotify"; Ver = "1.2.37.701" },
        @{ Key = "VLC"; Name = "VLC media player"; Pub = "VideoLAN"; Loc = "$Drive\Program Files\VideoLAN\VLC"; Ver = "3.0.20" },
        @{ Key = "MicrosoftOffice"; Name = "Microsoft Office 365 - en-us"; Pub = "Microsoft Corporation"; Loc = "$Drive\Program Files\Microsoft Office\root\Office16"; Ver = "16.0.17531.20120" },
        @{ Key = "Steam"; Name = "Steam"; Pub = "Valve Corporation"; Loc = $steamProgramFiles; Ver = "2.10.91.91" },
        @{ Key = "GIMP"; Name = "GIMP 2.10.36"; Pub = "The GIMP Team"; Loc = "$Drive\Program Files\GIMP 2"; Ver = "2.10.36" },
        @{ Key = "Inkscape"; Name = "Inkscape 1.4.2"; Pub = "Inkscape"; Loc = "$Drive\Program Files\Inkscape"; Ver = "1.4.2" },
        @{ Key = "Audacity_is1"; Name = "Audacity 3.7.1"; Pub = "Audacity Team"; Loc = "$Drive\Program Files\Audacity"; Ver = "3.7.1" },
        @{ Key = "OBSStudio"; Name = "OBS Studio"; Pub = "OBS Project"; Loc = "$Drive\Program Files\obs-studio"; Ver = "30.1.2" },
        @{ Key = "7Zip"; Name = "7-Zip 23.01 (x64)"; Pub = "Igor Pavlov"; Loc = "$Drive\Program Files\7-Zip"; Ver = "23.01" },
        @{ Key = "TelegramDesktop"; Name = "Telegram Desktop"; Pub = "Telegram FZ-LLC"; Loc = "$appDataRoaming\Telegram Desktop"; Ver = "4.16.8" }
    )
    $uninstall = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    foreach ($app in $appsToRegister) {
        $regPath = "$uninstall\wootc-e2e-$($app.Key)"
        Set-RegValue $regPath "DisplayName" $app.Name
        Set-RegValue $regPath "Publisher" $app.Pub
        Set-RegValue $regPath "InstallLocation" $app.Loc
        Set-RegValue $regPath "DisplayVersion" $app.Ver
        Set-RegValue $regPath "UninstallString" "$($app.Loc)\uninstall.exe"
    }

    $hive = Open-UserHive
    try {
        $hkcu = $hive.Root
        # URL associations (default browser = Chrome, default mail = Thunderbird).
        # UserChoice keys carry a deny ACL and a hash on current Windows; a
        # refused write leaves the association out, nothing the migration
        # asserts depends on it.
        try {
            foreach ($scheme in @("http", "https")) {
                Set-RegValue "$hkcu\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$scheme\UserChoice" "ProgId" "ChromeHTML"
            }
            Set-RegValue "$hkcu\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\mailto\UserChoice" "ProgId" "ThunderbirdURL"
        } catch {
            Write-Host "[seed-profile] URL associations not seeded: $($_.Exception.Message)"
        }
        $runKey = "$hkcu\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
        Set-RegValue $runKey "Discord" "$appDataLocal\Discord\Update.exe --processStart Discord.exe"
        Set-RegValue $runKey "Spotify" "$appDataRoaming\Spotify\Spotify.exe"
        Set-RegValue $runKey "Steam" "$steamProgramFiles\steam.exe -silent"
        # Look (collectLook reads these from the user's hive): dark mode, the
        # DWM ColorizationColor accent as Windows stores it (ARGB 0xC4E62D42,
        # a DWORD whose high bit is set: #E62D42 once the alpha is dropped),
        # the wallpaper path, and the preferred UI languages.
        $themeKey = "$hkcu\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        Set-RegValue $themeKey "AppsUseLightTheme" 0 "DWord"
        Set-RegValue $themeKey "SystemUsesLightTheme" 0 "DWord"
        Set-RegValue "$hkcu\Software\Microsoft\Windows\DWM" "ColorizationColor" ([int32]-991548094) "DWord"
        Set-RegValue "$hkcu\Control Panel\Desktop" "WallPaper" $wallpaper
        Set-RegValue "$hkcu\Control Panel\International\User Profile" "Languages" ([string[]]@("de-DE", "en-US")) "MultiString"
        Set-RegValue "$hkcu\Control Panel\International\User Profile\de-DE" "0407:00000407" 1 "DWord"
        # The user's default printer (per-user; Windows would otherwise pick
        # the last one used): the office laser.
        $printerKey = "$hkcu\Software\Microsoft\Windows NT\CurrentVersion\Windows"
        Set-RegValue $printerKey "LegacyDefaultPrinterMode" 1 "DWord"
        Set-RegValue $printerKey "Device" "$officePrinter,winspool,IP_127.0.0.2"
    } finally {
        if ($hive.Loaded) {
            [gc]::Collect()
            & reg.exe unload "HKU\wootc-e2e-seed" | Out-Null
        }
    }
}

# ── 7. Migration corpus, look and the expected-state manifest ───────────────
# Every byte below derives from RunId, so a file left by an earlier run on a
# reused Windows image can never satisfy this run's manifest.
$runSeed = [System.BitConverter]::ToInt32([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($RunId)), 0) -band 0x7fffffff
$rng = New-Object System.Random $runSeed
$epoch = New-Object System.DateTime 1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)
$stampBase = New-Object System.DateTime 2019, 3, 14, 15, 9, 26, ([System.DateTimeKind]::Utc)
$stampIndex = 0

function Write-RandomFile([string]$Path, [long]$Bytes) {
    Ensure-Directory (Split-Path -Parent $Path)
    $stream = [System.IO.File]::Create($Path)
    try {
        $buffer = New-Object byte[] 1048576
        $left = $Bytes
        while ($left -gt 0) {
            $rng.NextBytes($buffer)
            $n = [int][Math]::Min([long]$buffer.Length, $left)
            $stream.Write($buffer, 0, $n)
            $left -= $n
        }
    } finally {
        $stream.Close()
    }
}
function Set-FixedStamp([string]$Path) {
    # A distinct, whole-second, years-old mtime per file: a copy that resets
    # timestamps (cp without -p, a fresh write) cannot match by accident.
    $script:stampIndex++
    [System.IO.File]::SetLastWriteTimeUtc($Path, $stampBase.AddDays($script:stampIndex).AddSeconds($script:stampIndex * 37))
}

$eAcute = [char]0x00E9
$uUml = [char]0x00DC
$iUml = [char]0x00EF
$oUml = [char]0x00F6
$enDash = [char]0x2013
$check = [char]0x2713
$fish = [char]::ConvertFromUtf32(0x1F41F)
$nihongo = -join ([char[]](0x65E5, 0x672C, 0x8A9E))
$memo = -join ([char[]](0x30E1, 0x30E2))
$corpusFiles = New-Object System.Collections.Generic.List[string]
foreach ($folder in @("Documents", "Pictures", "Music", "Videos", "Desktop", "Downloads")) {
    $corpus = "$userProfile\$folder\wootc-e2e-corpus"
    if (Test-Path -LiteralPath $corpus) { Remove-Item -LiteralPath $corpus -Recurse -Force }
}
$docs = "$docsDir\wootc-e2e-corpus"
$texts = @(
    @("$docs\Projekte 2025\R${eAcute}sum${eAcute} $enDash final $check.txt", "Curriculum vitae $RunId`r`n"),
    @("$docs\$nihongo\$memo.md", "# $nihongo $RunId`n"),
    @("$docs\${uUml}n${iUml}c${oUml}d${eAcute} $fish notes.txt", "unicode $RunId`n"),
    @("$docs\empty.txt", ""),
    @("$deskDir\wootc-e2e-corpus\todo.txt", "1. migrate $RunId`r`n")
)
foreach ($t in $texts) {
    Ensure-Directory (Split-Path -Parent $t[0])
    [System.IO.File]::WriteAllText($t[0], $t[1], (New-Object System.Text.UTF8Encoding $false))
    $corpusFiles.Add($t[0])
}
$binaries = @(
    @("$docs\deep\a\b\c\d\nested.bin", 4096),
    @("$docs\tiny.bin", 1),
    @("$picsDir\wootc-e2e-corpus\Vacation 2024\IMG_0001.jpg", 1048576),
    @("$picsDir\wootc-e2e-corpus\Screenshots\Screenshot (1).png", 262144),
    @("$musicDir\wootc-e2e-corpus\Artist $enDash Album\01 Track.mp3", 3145728),
    @("$videoDir\wootc-e2e-corpus\family-trip.mp4", 67108864),
    @("$downDir\wootc-e2e-corpus\installer-1.2.3.exe", 2097152),
    @("$downDir\wootc-e2e-corpus\archive.zip", 524288)
)
foreach ($b in $binaries) {
    Write-RandomFile $b[0] $b[1]
    $corpusFiles.Add($b[0])
}
foreach ($f in $corpusFiles) { Set-FixedStamp $f }
$corpusFiles.Add("$docsDir\wootc-e2e-userdata.txt")

# Account picture (identity bridge → ~/.face) and wallpaper (Windows-Style
# Mode → slurp/wallpaper.jpg): real images whose pixels carry RunId.
Add-Type -AssemblyName System.Drawing
function Write-Image([string]$Path, [int]$Width, [int]$Height, $Format) {
    Ensure-Directory (Split-Path -Parent $Path)
    $bmp = New-Object System.Drawing.Bitmap $Width, $Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::FromArgb(255, $rng.Next(256), $rng.Next(256), $rng.Next(256)))
        $font = New-Object System.Drawing.Font "Arial", 9
        $g.DrawString($RunId, $font, [System.Drawing.Brushes]::White, 2, 2)
        $bmp.Save($Path, $Format)
    } finally {
        $g.Dispose()
        $bmp.Dispose()
    }
}
$picture = "$appDataRoaming\Microsoft\Windows\AccountPictures\wootc-e2e.png"
Get-ChildItem -LiteralPath (Split-Path -Parent $picture) -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @(".png", ".jpg", ".jpeg", ".bmp") } | Remove-Item -Force
Write-Image $picture 192 192 ([System.Drawing.Imaging.ImageFormat]::Png)
Write-Image $wallpaper 640 360 ([System.Drawing.Imaging.ImageFormat]::Jpeg)
# collectLook prefers the rendered TranscodedWallpaper over the WallPaper
# value; make both the seeded image. Windows re-renders TranscodedWallpaper
# from the WallPaper value at the user's next logon, so the harness re-hashes
# it at the handoff and the manifest names the source (#wallpaperSource).
$transcoded = "$appDataRoaming\Microsoft\Windows\Themes\TranscodedWallpaper"
Ensure-Directory (Split-Path -Parent $transcoded)
Copy-Item -LiteralPath $wallpaper -Destination $transcoded -Force

# Time zone: a mapped zone far from the image default (UTC).
Set-TimeZone -Id "Tokyo Standard Time"

# ── Expected-state manifest ──────────────────────────────────────────────────
$rows = New-Object System.Collections.Generic.List[string]
function Add-Row([string]$Category, [string]$Path) {
    $item = Get-Item -LiteralPath $Path
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $mtime = [long][Math]::Floor(($item.LastWriteTimeUtc - $epoch).TotalSeconds)
    $relative = $Path.Substring($userProfile.Length + 1).Replace('\', '/')
    $rows.Add("$Category`t$relative`t$($item.Length)`t$hash`t$mtime")
}
foreach ($f in $corpusFiles) { Add-Row "file" $f }
Add-Row "font" "$fontsDir\WootcE2E-Sans.ttf"
foreach ($t in @("Report.dotx", "Invoice.xltx", "Presentation.potx")) { Add-Row "template" "$templatesDir\$t" }
Add-Row "vscode" "$vscUserDir\settings.json"
Add-Row "vscode" "$vscUserDir\keybindings.json"
Add-Row "vscode" "$vscSnippetsDir\python.json"
Add-Row "telegram" "$appDataRoaming\Telegram Desktop\tdata\settingss"
Add-Row "obs" "$appDataRoaming\obs-studio\basic\scenes\default.json"
Add-Row "face" $picture
Add-Row "chrome" "$chromeUserData\Bookmarks"
Add-Row "chrome" "$chromeUserData\History"
Add-Row "edge" "$edgeUserData\Bookmarks"
foreach ($f in @("places.sqlite", "logins.json", "prefs.js", "extensions.json")) { Add-Row "firefox" "$firefoxProfileDir\$f" }
Add-Row "wallpaper" $transcoded
Add-Row "ssh-pub" "$sshDir\id_ed25519.pub"
Add-Row "ssh-config" "$sshDir\config"
Add-Row "ssh-known-hosts" "$sshDir\known_hosts"
$header = @(
    "#schema=1",
    "#runId=$RunId",
    "#windowsUser=$Username",
    "#profileRoot=$userProfile",
    "#fullName=$fullName",
    "#dictionary=Kubernetes,wootc,TunaOS,containerd,MicroOS",
    "#vscodeExtensions=golang.go,ms-python.python",
    "#timezone=Asia/Tokyo",
    "#language=de-DE",
    "#darkMode=true",
    "#accentColor=#E62D42",
    "#wallpaperSource=$wallpaper",
    "#steamLibraries=Program Files (x86)/Steam/steamapps,Games/SteamLibrary/steamapps",
    "#sshPrivate=.ssh/id_ed25519",
    "#sshHostAlias=$sshHostAlias",
    "#sshHostName=$sshHostName",
    "#gitName=$gitName",
    "#gitEmail=$gitEmail",
    "#printerOffice=$officePrinter",
    "#printerLab=$labPrinter",
    "#printerLabel=$labelPrinter"
)
if ($virtualPrinter) { $header += "#printerVirtual=$virtualPrinter" }
Ensure-Directory (Split-Path -Parent $ManifestPath)
[System.IO.File]::WriteAllText($ManifestPath, (($header + $rows) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))
Write-Host "[seed-profile] Manifest: $($rows.Count) expected items in $ManifestPath"

Write-Host "[seed-profile] Profile seeding complete for '$Username'."
