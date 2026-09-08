[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Block', 'Allow', 'AllowForce')]
    [string]$Action,
    [Parameter(Mandatory = $true)]
    [string]$ResultPath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$HelperHash
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$expectedAction = '__SSM_ELEVATED_ACTION__'
$expectedResultPath = '__SSM_ELEVATED_RESULT_PATH__'
$expectedTargetPath = '__SSM_ELEVATED_TARGET_PATH__'
$targetSddl = '__SSM_ELEVATED_TARGET_SDDL__'
$operationId = '__SSM_ELEVATED_OPERATION_ID__'
$directoryAclSourceBase64 = '__SPICETIFY_MANAGER_DIRECTORY_ACL_BASE64__'

function Normalize-HelperPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    while ($fullPath.Length -gt $root.Length -and ($fullPath.EndsWith('\') -or $fullPath.EndsWith('/'))) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath.Replace('/', '\')
}

function Test-HelperPathEqual {
    param([string]$Left, [string]$Right)
    return [string]::Equals((Normalize-HelperPath $Left), (Normalize-HelperPath $Right), [StringComparison]::OrdinalIgnoreCase)
}

function Get-ComparableAccessSddl {
    param([Parameter(Mandatory = $true)]$Acl)
    $descriptor = New-Object Security.AccessControl.RawSecurityDescriptor($Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access))
    # Ignore only Windows' auto-inherited bookkeeping flag, never ACE differences.
    $descriptor.SetFlags($descriptor.ControlFlags -band (-bnot [Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited))
    return $descriptor.GetSddlForm([Security.AccessControl.AccessControlSections]::Access)
}

function Assert-HelperDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $directory = Normalize-HelperPath $Path
    $temporaryRoot = Normalize-HelperPath ([IO.Path]::GetTempPath())
    if (-not (Test-HelperPathEqual (Split-Path -Parent $directory) $temporaryRoot)) {
        throw 'The elevated helper directory is outside the Windows temporary directory.'
    }
    if ([IO.Path]::GetFileName($directory) -notmatch '^SpicetifySpotifyManager-[0-9a-f]{32}$') {
        throw 'The elevated helper directory name is invalid.'
    }
    $item = Get-Item -LiteralPath $directory -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The elevated helper directory is not a normal directory.'
    }
    return $directory
}

function Assert-ExactSpotifyUpdatePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $roamingAppData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData) -or [string]::IsNullOrWhiteSpace($roamingAppData)) {
        throw 'Windows did not provide the required AppData directories.'
    }
    $expected = Normalize-HelperPath (Join-Path $localAppData 'Spotify\Update')
    $actual = Normalize-HelperPath $Path
    if (-not (Test-HelperPathEqual $actual $expected)) {
        throw 'The elevated ACL target is not the exact Spotify Update directory.'
    }
    $ancestor = $actual
    while (-not [string]::IsNullOrEmpty($ancestor)) {
        $ancestorItem = Get-Item -LiteralPath $ancestor -Force
        if (($ancestorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The Spotify Update path contains a reparse point or junction.'
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    if (-not (Test-Path -LiteralPath (Join-Path $roamingAppData 'Spotify\Spotify.exe') -PathType Leaf)) {
        throw 'The supported standalone Spotify executable was not found.'
    }
    $item = Get-Item -LiteralPath $actual -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The Spotify Update target is not a normal directory.'
    }
    if (-not (Test-HelperPathEqual $item.FullName $actual)) {
        throw 'The Spotify Update target resolves to an unexpected path.'
    }
    return $actual
}

function Write-HelperResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Success,
        [bool]$Changed = $false,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $directory = Assert-HelperDirectory (Split-Path -Parent $expectedResultPath)
    $actualResultPath = Normalize-HelperPath $ResultPath
    if (-not (Test-HelperPathEqual $actualResultPath $expectedResultPath) -or
        -not (Test-HelperPathEqual (Split-Path -Parent $actualResultPath) $directory) -or
        [IO.Path]::GetFileName($actualResultPath) -ne 'result.json') {
        throw 'The elevated result path is invalid.'
    }
    if (Test-Path -LiteralPath $actualResultPath) {
        throw 'The elevated result path already exists.'
    }
    $safeMessage = ($Message -replace "[\r\n]+", ' ')
    if ($safeMessage.Length -gt 4096) { $safeMessage = $safeMessage.Substring(0, 4096) }
    $value = [ordered]@{
        SchemaVersion = 1
        OperationId = $operationId
        Action = $expectedAction
        TargetPath = $expectedTargetPath
        HelperHash = $HelperHash.ToUpperInvariant()
        Success = $Success
        Changed = $Changed
        Message = $safeMessage
    }
    $temporary = Join-Path $directory ('.result.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        $json = $value | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $actualResultPath
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    if ($Action -ne $expectedAction) { throw 'The elevated ACL action does not match the protected helper payload.' }
    if ($operationId -notmatch '^[0-9a-f]{32}$') { throw 'The elevated operation identifier is invalid.' }
    $helperDirectory = Assert-HelperDirectory (Split-Path -Parent $ResultPath)
    if (-not (Test-HelperPathEqual $ResultPath $expectedResultPath)) { throw 'The elevated result path does not match the protected helper payload.' }
    $target = Assert-ExactSpotifyUpdatePath $expectedTargetPath

    $targetAcl = New-Object Security.AccessControl.DirectorySecurity
    $targetAcl.SetSecurityDescriptorSddlForm($targetSddl, [Security.AccessControl.AccessControlSections]::All)
    . ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($directoryAclSourceBase64))))
    $session = Open-BoundDirectoryAclSession $target
    try {
        $session.Write($targetAcl)
        $verifiedAcl = $session.Read()
    }
    finally { $session.Dispose() }
    $expectedDacl = Get-ComparableAccessSddl $targetAcl
    $actualDacl = Get-ComparableAccessSddl $verifiedAcl
    if ($actualDacl -ne $expectedDacl) {
        throw 'The elevated ACL operation completed, but its access rules could not be verified.'
    }
    Write-HelperResult -Success $true -Changed $true -Message 'The exact Spotify Update ACL was applied and verified by the elevated helper.'
}
catch {
    if (-not (Test-Path -LiteralPath $ResultPath)) {
        try { Write-HelperResult -Success $false -Message $_.Exception.Message } catch { }
    }
    throw
}
