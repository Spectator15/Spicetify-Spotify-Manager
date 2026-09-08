[CmdletBinding()]
param(
    [switch]$Check,
    [string]$ToolCache = (Join-Path ([IO.Path]::GetTempPath()) 'SpicetifySpotifyManager-build-cache')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Build using Windows PowerShell 5.1.' }
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputPath = Join-Path $repositoryRoot 'Spicetify-Spotify-Manager.exe'
$utf8 = New-Object Text.UTF8Encoding($false, $true)

function Read-BuildSource {
    param([string]$RelativePath)
    $text = [IO.File]::ReadAllText((Join-Path $repositoryRoot $RelativePath), $utf8)
    return ($text -replace "`r`n", "`n" -replace "`r", "`n")
}
function Set-BuildMarker {
    param([string]$Text, [string]$Marker, [string]$Value)
    if ([regex]::Matches($Text, [regex]::Escape($Marker)).Count -ne 1) { throw "Expected exactly one build marker: $Marker" }
    return $Text.Replace($Marker, $Value)
}
function Assert-PowerShellSource {
    param([string]$Text)
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "Embedded source does not parse: $($errors[0].Message)" }
}
$version = (Read-BuildSource 'VERSION').Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION must be a stable semantic version.' }
$source = Read-BuildSource 'src\SpicetifySpotifyManager.ps1'
$helper = Read-BuildSource 'src\ElevatedAclHelper.ps1'
$acl = Read-BuildSource 'src\DirectoryAcl.ps1'
Assert-PowerShellSource $acl
$acl64 = [Convert]::ToBase64String($utf8.GetBytes($acl))
$helper = Set-BuildMarker $helper '__SPICETIFY_MANAGER_DIRECTORY_ACL_BASE64__' $acl64
Assert-PowerShellSource $helper
$source = Set-BuildMarker $source '__SPICETIFY_MANAGER_DIRECTORY_ACL_BASE64__' $acl64
$source = Set-BuildMarker $source '__SPICETIFY_MANAGER_ELEVATED_HELPER_BASE64__' ([Convert]::ToBase64String($utf8.GetBytes($helper)))
$source = Set-BuildMarker $source '__SPICETIFY_MANAGER_VERSION__' $version
if ($source -match '__SPICETIFY_MANAGER_[A-Z_]+__') { throw 'Unresolved manager build marker.' }
Assert-PowerShellSource $source

# Pin build tools independently of the host SDK/runtime. Extract the verified
# archives anew for each build; never execute a previously extracted compiler.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$ToolCache = [IO.Path]::GetFullPath($ToolCache)
[void][IO.Directory]::CreateDirectory($ToolCache)
if ((Get-Item -LiteralPath $ToolCache -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The tool cache cannot be a reparse point.' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('SpicetifyManagerBuild-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $packages = (Read-BuildSource 'build\windows-toolchain.json') | ConvertFrom-Json
    foreach ($package in $packages) {
        if ($package.id -notmatch '^[a-z0-9.]+$' -or $package.version -notmatch '^\d+\.\d+\.\d+$' -or $package.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid toolchain manifest.' }
        $name = '{0}.{1}.nupkg' -f $package.id, $package.version
        $archive = Join-Path $ToolCache $name
        if (-not (Test-Path -LiteralPath $archive)) {
            $download = Join-Path $scratch $name
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri ("https://api.nuget.org/v3-flatcontainer/{0}/{1}/{2}" -f $package.id, $package.version, $name) -OutFile $download
            if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $package.sha256) { throw "Downloaded package hash mismatch: $name" }
            [IO.File]::Copy($download, $archive, $false)
        }
        $item = Get-Item -LiteralPath $archive -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe toolchain archive.' }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $package.sha256) { throw "Cached package hash mismatch: $name" }
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, (Join-Path $scratch $package.id))
    }
    [IO.File]::WriteAllText((Join-Path $scratch 'Launcher.cs'), (Read-BuildSource 'src\Launcher.cs'), $utf8)
    [IO.File]::WriteAllText((Join-Path $scratch 'Manager.ps1'), $source, $utf8)
    [IO.File]::WriteAllText((Join-Path $scratch 'Version.txt'), $version, $utf8)
    $attributes = "[assembly:System.Reflection.AssemblyVersion(`"$version.0`")]`n[assembly:System.Reflection.AssemblyFileVersion(`"$version.0`")]`n[assembly:System.Reflection.AssemblyInformationalVersion(`"$version`")]`n"
    [IO.File]::WriteAllText((Join-Path $scratch 'Version.cs'), $attributes, $utf8)
    $references = Join-Path $scratch 'microsoft.netframework.referenceassemblies.net48\build\.NETFramework\v4.8'
    $compiler = Join-Path $scratch 'microsoft.net.compilers.toolset\tasks\net472\csc.exe'
    $built = Join-Path $scratch 'Spicetify-Spotify-Manager.exe'
    $compilerArguments = @('/nologo', '/noconfig', '/nostdlib+', '/deterministic+', '/optimize+', '/debug-', '/target:exe', '/platform:anycpu', '/langversion:7.3',
        ('/pathmap:{0}=/_/ssm' -f $scratch), ('/out:' + $built),
        ('/reference:' + (Join-Path $references 'mscorlib.dll')), ('/reference:' + (Join-Path $references 'System.dll')),
        ('/reference:' + (Join-Path $references 'System.Core.dll')),
        ('/reference:' + (Join-Path $scratch 'microsoft.powershell.5.referenceassemblies\lib\net4\System.Management.Automation.dll')),
        ('/resource:' + (Join-Path $scratch 'Manager.ps1') + ',SpicetifyManager.Manager.ps1'),
        ('/resource:' + (Join-Path $scratch 'Version.txt') + ',SpicetifyManager.Version'),
        (Join-Path $scratch 'Launcher.cs'), (Join-Path $scratch 'Version.cs'))
    & $compiler @compilerArguments
    if ($LASTEXITCODE -ne 0) { throw "C# compilation failed with exit code $LASTEXITCODE." }
    if ($Check) {
        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash) {
            throw 'Generated executable is out of date. Run build\Build-Release.ps1.'
        }
        Write-Host 'Generated executable matches a fresh deterministic build.'
    }
    else {
        [IO.File]::WriteAllBytes($outputPath, [IO.File]::ReadAllBytes($built))
        Write-Host "Generated $outputPath"
    }
}
finally {
    if ([IO.Path]::GetFileName($scratch) -notmatch '^SpicetifyManagerBuild-[0-9a-f]{32}$' -or
        [IO.Path]::GetDirectoryName($scratch) -ne [IO.Path]::GetTempPath().TrimEnd('\')) { throw 'Unexpected build cleanup path.' }
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
