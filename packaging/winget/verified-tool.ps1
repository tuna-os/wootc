# The release pin and SHA256 are reviewed together. Never execute a tool from
# the mutable aka.ms/wingetcreate/latest redirect with the submission token.
# Upstream release: https://github.com/microsoft/winget-create/releases/tag/v1.12.13.0

function Assert-ToolHash {
    param([string]$Path, [string]$Expected)
    if ($Expected -notmatch '\A[0-9a-fA-F]{64}\z') { throw 'Invalid tool SHA256 pin' }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actual -ne $Expected) { throw 'wingetcreate SHA256 does not match the reviewed pin' }
}

function Install-VerifiedWingetCreate {
    param([Parameter(Mandatory)][string]$Destination)
    $url = 'https://github.com/microsoft/winget-create/releases/download/v1.12.13.0/wingetcreate.exe'
    $sha256 = '24042bd37915805615e6cf969ac57c6439124c3fe85823327f5f3fb24bd9ffea'
    # Use a fresh directory under runner temp, never an executable from the
    # manifest artifact or checkout directory.
    $directory = Join-Path $Destination ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    $path = Join-Path $directory 'wingetcreate.exe'
    try {
        Invoke-WebRequest -Uri $url -OutFile $path -ErrorAction Stop
        Assert-ToolHash -Path $path -Expected $sha256
        return (Get-Item -LiteralPath $path).FullName
    } catch {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}
