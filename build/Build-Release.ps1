[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$launcherPath = Join-Path $repositoryRoot 'src\launcher.cmd'
$sourcePath = Join-Path $repositoryRoot 'src\SpicetifySpotifyManager.ps1'
$outputPath = Join-Path $repositoryRoot 'Spicetify-Spotify-Manager.bat'
$marker = '# <SPICETIFY_MANAGER_POWERSHELL>'
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function ConvertTo-Lf {
    param([Parameter(Mandatory = $true)][string]$Text)
    return ($Text -replace "`r`n", "`n" -replace "`r", "`n")
}

foreach ($requiredPath in @($launcherPath, $sourcePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required build input was not found: $requiredPath"
    }
}

$launcher = ConvertTo-Lf ([IO.File]::ReadAllText($launcherPath))
$source = ConvertTo-Lf ([IO.File]::ReadAllText($sourcePath))

if ($launcher.Contains($marker) -or $source.Contains($marker)) {
    throw 'A build input contains the reserved embedded PowerShell marker.'
}

$generatedLf = $launcher.TrimEnd("`n") + "`n" + $marker + "`n" + $source.Trim("`n") + "`n"
if ([regex]::Matches($generatedLf, [regex]::Escape($marker)).Count -ne 1) {
    throw 'The generated release must contain exactly one embedded PowerShell marker.'
}

$generated = $generatedLf -replace "`n", "`r`n"
$generatedBytes = $utf8NoBom.GetBytes($generated)

if ($Check) {
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw "Generated release is missing: $outputPath"
    }
    $existingBytes = [IO.File]::ReadAllBytes($outputPath)
    if ($existingBytes.Length -ne $generatedBytes.Length) {
        throw 'Generated release is out of date. Run build\Build-Release.ps1.'
    }
    for ($index = 0; $index -lt $existingBytes.Length; $index++) {
        if ($existingBytes[$index] -ne $generatedBytes[$index]) {
            throw 'Generated release is out of date. Run build\Build-Release.ps1.'
        }
    }
    Write-Host 'Generated release is current and deterministic.' -ForegroundColor Green
    return
}

[IO.File]::WriteAllBytes($outputPath, $generatedBytes)
Write-Host "Generated $outputPath" -ForegroundColor Green
