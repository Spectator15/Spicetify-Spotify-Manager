[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path $repositoryRoot 'src\SpicetifySpotifyManager.ps1'
$buildPath = Join-Path $repositoryRoot 'build\Build-Release.ps1'
$releasePath = Join-Path $repositoryRoot 'Spicetify-Spotify-Manager.bat'

. $sourcePath -NoMain

$script:Passed = 0
$script:Failed = 0
$script:TemporaryRoots = New-Object 'Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message = 'Expected condition to be true.')
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message = 'Expected condition to be false.')
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -ne $Actual) {
        if ([string]::IsNullOrWhiteSpace($Message)) { $Message = "Expected '$Expected' but received '$Actual'." }
        throw $Message
    }
}

function Assert-Match {
    param([string]$Value, [string]$Pattern)
    if ($Value -notmatch $Pattern) { throw "Expected '$Value' to match '$Pattern'." }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [string]$Pattern = '.*'
    )
    try { & $Script }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Expected error matching '$Pattern', received '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected an error matching '$Pattern', but no error was raised."
}

function New-TestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('SpicetifyManagerTests-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $script:TemporaryRoots.Add([IO.Path]::GetFullPath($root))
    return $root
}

function New-TestContext {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$Installed,
        [switch]$CreateUpdate
    )
    $profileRoot = Join-Path $Root 'Profile With Spaces & Marks'
    $install = Join-Path $profileRoot 'Roaming\Spotify'
    $local = Join-Path $profileRoot 'Local\Spotify'
    New-Item -ItemType Directory -Path $install -Force | Out-Null
    New-Item -ItemType Directory -Path $local -Force | Out-Null
    if ($Installed) { New-Item -ItemType File -Path (Join-Path $install 'Spotify.exe') -Force | Out-Null }
    if ($CreateUpdate) { New-Item -ItemType Directory -Path (Join-Path $local 'Update') -Force | Out-Null }
    return [pscustomobject]@{
        InstallDirectory = Normalize-WindowsPath $install
        Executable = Normalize-WindowsPath (Join-Path $install 'Spotify.exe')
        AppsDirectory = Normalize-WindowsPath (Join-Path $install 'Apps')
        Preferences = Normalize-WindowsPath (Join-Path $install 'prefs')
        LocalDirectory = Normalize-WindowsPath $local
        UpdateDirectory = Normalize-WindowsPath (Join-Path $local 'Update')
    }
}

function Use-TestEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Context,
        [hashtable]$ExtraHooks = @{}
    )
    $hooks = @{
        DataDirectory = { Join-Path $Root 'Manager Data' }.GetNewClosure()
        SpotifyContext = { $Context }.GetNewClosure()
        StandaloneInstalled = { param($ignored) Test-Path -LiteralPath $Context.Executable -PathType Leaf }.GetNewClosure()
        StoreInstalled = { $false }
        CurrentUserSid = { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
        IsAdministrator = { $false }
    }
    foreach ($key in $ExtraHooks.Keys) { $hooks[$key] = $ExtraHooks[$key] }
    Set-ManagerTestHooks $hooks
}

function Invoke-Test {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )
    try {
        Set-ManagerTestHooks @{}
        & $Script
        $script:Passed++
        Write-Host "PASS  $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "      $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
    }
    finally {
        Set-ManagerTestHooks @{}
    }
}

try {
    Invoke-Test 'detects standalone Spotify installed and missing' {
        $root = New-TestRoot
        $installed = New-TestContext -Root $root -Installed
        Assert-True (Test-StandaloneSpotifyInstalled $installed)
        Remove-Item -LiteralPath $installed.Executable -Force
        Assert-False (Test-StandaloneSpotifyInstalled $installed)
    }

    Invoke-Test 'normalizes and deduplicates Windows paths case-insensitively' {
        $root = New-TestRoot
        $path = Join-Path $root 'Folder With Spaces'
        New-Item -ItemType Directory -Path $path | Out-Null
        $paths = Get-UniqueWindowsPaths @($path, ($path.ToUpperInvariant() + '\'), (Join-Path $root 'Other'))
        Assert-Equal 2 @($paths).Count
        Assert-True (Test-WindowsPathEqual $path ($path.ToUpperInvariant() + '\'))
        Assert-True (Test-WindowsPathWithin (Join-Path $path 'child.txt') $path)
        Assert-False (Test-WindowsPathWithin (Join-Path $root 'Folder With Spaces Elsewhere') $path)
    }

    Invoke-Test 'reports Spotify running and not running from one process source' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{ SpotifyProcesses = { param($ignored) @() } }
        Assert-False (Test-SpotifyRunning $context)
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{ SpotifyProcesses = { param($ignored) @([pscustomobject]@{ Id = 123 }) } }
        Assert-True (Test-SpotifyRunning $context)
    }

    Invoke-Test 'reports Spicetify installed and missing' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{ SpicetifyExecutable = { '' } }
        Assert-False (Get-SpicetifyState $context).Installed
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            SpicetifyExecutable = { 'C:\Tools With Spaces\spicetify.exe' }
            CapturedProcess = { param($file, $arguments, $show) [pscustomobject]@{ ExitCode = 0; Output = '2.44.0'; Error = '' } }
        }
        Assert-True (Get-SpicetifyState $context).Installed
    }

    Invoke-Test 'reads current official Spicetify config and preference keys' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed
        $configRoot = Join-Path $root 'Custom Spicetify Config'
        New-Item -ItemType Directory -Path $configRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $configRoot 'config-xpui.ini') -Value "[Backup]`r`nversion = 1.2.3.4"
        Set-Content -LiteralPath $context.Preferences -Value 'app.last-launched-version="1.2.3.4"'
        $oldConfig = $env:SPICETIFY_CONFIG
        try {
            $env:SPICETIFY_CONFIG = $configRoot
            Assert-True (Test-WindowsPathEqual (Get-SpicetifyConfigPath) (Join-Path $configRoot 'config-xpui.ini'))
            Assert-Equal '1.2.3.4' (Get-SpotifyPreferenceVersion $context)
            Assert-Equal '1.2.3.4' (Get-IniValue -Path (Get-SpicetifyConfigPath) -Section 'Backup' -Key 'version')
        }
        finally {
            if ($null -eq $oldConfig) { Remove-Item Env:\SPICETIFY_CONFIG -ErrorAction SilentlyContinue }
            else { $env:SPICETIFY_CONFIG = $oldConfig }
        }
    }

    Invoke-Test 'detects updates initially allowed' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment -Root $root -Context $context
        $status = Get-UpdateAccessStatus $context
        Assert-Equal 'Allowed' $status.State
    }

    Invoke-Test 'blocks twice safely and preserves unrelated files' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $unrelatedPath = Join-Path $context.UpdateDirectory 'keep-me.txt'
        Set-Content -LiteralPath $unrelatedPath -Value 'preserve this file'
        $originalSddl = Get-AclSddl (Get-Acl -LiteralPath $context.UpdateDirectory)
        Use-TestEnvironment -Root $root -Context $context
        $first = Invoke-BlockUpdatesCore $context
        Assert-True $first.Changed
        Assert-Equal 'Blocked' (Get-UpdateAccessStatus $context).State
        $second = Invoke-BlockUpdatesCore $context
        Assert-False $second.Changed
        Assert-True (Test-Path -LiteralPath $unrelatedPath -PathType Leaf)
        Assert-Equal 'preserve this file' (Get-Content -LiteralPath $unrelatedPath -Raw).Trim()
        $allow = Invoke-AllowUpdatesCore $context
        Assert-True $allow.Changed
        Assert-Equal $originalSddl (Get-AclSddl (Get-Acl -LiteralPath $context.UpdateDirectory))
    }

    Invoke-Test 'does not close Spotify for an already-blocked menu action' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $script:stopCalls = 0
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            SpotifyProcesses = { param($ignored) @([pscustomobject]@{ Id = 123 }) }
            StopSpotify = { param($ignored) $script:stopCalls++; $true }
        }
        Invoke-BlockUpdatesCore $context | Out-Null
        Invoke-MenuAction -Choice '4' -Context $context
        Assert-Equal 0 $script:stopCalls
        Invoke-AllowUpdatesCore $context | Out-Null
    }

    Invoke-Test 'restores twice safely' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment -Root $root -Context $context
        Invoke-BlockUpdatesCore $context | Out-Null
        Assert-True (Invoke-AllowUpdatesCore $context).Changed
        Assert-False (Invoke-AllowUpdatesCore $context).Changed
        Assert-Equal 'Allowed' (Get-UpdateAccessStatus $context).State
    }

    Invoke-Test 'recovers an interrupted applying state' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment -Root $root -Context $context
        Invoke-BlockUpdatesCore $context | Out-Null
        $statePath = Get-ManagerStatePath 'Update'
        $state = Read-JsonFile $statePath
        $state.Phase = 'Applying'
        Write-JsonFileAtomic -Path $statePath -Value $state
        Assert-Equal 'Recovery required' (Get-UpdateAccessStatus $context).State
        Assert-True (Invoke-AllowUpdatesCore $context).Changed
        Assert-Equal 'Allowed' (Get-UpdateAccessStatus $context).State
    }

    Invoke-Test 'does not overwrite ACL changes made after blocking without confirmation' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment -Root $root -Context $context
        Invoke-BlockUpdatesCore $context | Out-Null
        $acl = Get-Acl -LiteralPath $context.UpdateDirectory
        $extraRule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier('S-1-5-11')),
            [Security.AccessControl.FileSystemRights]::ReadAttributes,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($extraRule)
        Set-Acl -LiteralPath $context.UpdateDirectory -AclObject $acl
        Assert-Equal 'Recovery required' (Get-UpdateAccessStatus $context).State
        Assert-Throws { Invoke-AllowUpdatesCore $context } 'changed after blocking'
        Assert-True (Test-Path -LiteralPath (Get-ManagerStatePath 'Update'))
        Assert-True (Invoke-AllowUpdatesCore -Context $context -ForceRecovery).Changed
        Assert-Equal 'Allowed' (Get-UpdateAccessStatus $context).State
    }

    Invoke-Test 'attempts exact ACL recovery after a permission-command failure' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $setCalls = 0
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            SetDirectorySecurity = {
                param($path, $acl)
                $script:setCalls++
                if ($script:setCalls -eq 1) { throw [UnauthorizedAccessException]::new('Access is denied by the test.') }
            }
        }
        $script:setCalls = 0
        Assert-Throws { Invoke-BlockUpdatesCore $context } 'original permissions were restored'
        Assert-Equal 2 $script:setCalls
        Assert-False (Test-Path -LiteralPath (Get-ManagerStatePath 'Update'))
    }

    Invoke-Test 'fails verification and rolls back a partial block' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $originalSddl = Get-AclSddl (Get-Acl -LiteralPath $context.UpdateDirectory)
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{ WriteProbe = { param($path) $true } }
        Assert-Throws { Invoke-BlockUpdatesCore $context } 'original permissions were restored'
        Assert-Equal $originalSddl (Get-AclSddl (Get-Acl -LiteralPath $context.UpdateDirectory))
        Assert-False (Test-Path -LiteralPath (Get-ManagerStatePath 'Update'))
    }

    Invoke-Test 'rejects the unsupported Microsoft Store-only installation' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -CreateUpdate
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            StandaloneInstalled = { param($ignored) $false }
            StoreInstalled = { $true }
        }
        Assert-Throws { Invoke-BlockUpdatesCore $context } 'Microsoft Store'
    }

    Invoke-Test 'handles update paths containing spaces and special characters' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment -Root $root -Context $context
        Assert-Match $context.UpdateDirectory 'Spaces & Marks'
        Invoke-BlockUpdatesCore $context | Out-Null
        Invoke-AllowUpdatesCore $context | Out-Null
        Assert-Equal 'Allowed' (Get-UpdateAccessStatus $context).State
    }

    Invoke-Test 'surfaces failed Spicetify commands with captured diagnostics' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            SpicetifyExecutable = { 'C:\Tools\spicetify.exe' }
            CapturedProcess = { param($file, $arguments, $show) [pscustomobject]@{ ExitCode = 9; Output = ''; Error = 'mock CLI failure' } }
        }
        Assert-Throws { Invoke-Spicetify -Arguments @('backup', 'apply') } 'mock CLI failure'
    }

    Invoke-Test 'skips Spicetify reapply when the detected state is current' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed
        $script:commandCalls = 0
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            SpicetifyState = { param($ignored) [pscustomobject]@{ Installed = $true; NeedsRepair = $false; AppsState = 'Applied' } }
            CapturedProcess = { param($file, $arguments, $show) $script:commandCalls++; [pscustomobject]@{ ExitCode = 0; Output = ''; Error = '' } }
        }
        $result = Repair-SpicetifyIfNeeded $context
        Assert-False $result.Changed
        Assert-Equal 0 $script:commandCalls
    }

    Invoke-Test 'guided workflow restores blocked and running preferences without unnecessary reapply' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $script:spotifyRunning = $true
        $script:spicetifyCommands = 0
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            SpotifyProcesses = { param($ignored) if ($script:spotifyRunning) { @([pscustomobject]@{ Id = 123 }) } else { @() } }
            StopSpotify = { param($ignored) $script:spotifyRunning = $false; $true }
            StartSpotify = { param($ignored) $script:spotifyRunning = $true }
            SpotifyVersion = { param($ignored) '1.2.3.4' }
            SpicetifyState = { param($ignored) [pscustomobject]@{ Installed = $true; Version = '2.44.0'; NeedsRepair = $false; AppsState = 'Applied' } }
            CapturedProcess = { param($file, $arguments, $show) $script:spicetifyCommands++; [pscustomobject]@{ ExitCode = 0; Output = ''; Error = '' } }
            UpdateConfirmation = { }
        }
        Invoke-BlockUpdatesCore $context | Out-Null
        $result = Invoke-GuidedSpotifyUpdate $context
        Assert-True $result.Changed
        Assert-True $script:spotifyRunning
        Assert-Equal 0 $script:spicetifyCommands
        Assert-Equal 'Blocked' (Get-UpdateAccessStatus $context).State
        Assert-False (Test-Path -LiteralPath (Get-ManagerStatePath 'Guided'))
        Invoke-AllowUpdatesCore $context | Out-Null
    }

    Invoke-Test 'failed guided repair restores previous preferences immediately' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $script:spotifyRunning = $true
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            SpotifyProcesses = { param($ignored) if ($script:spotifyRunning) { @([pscustomobject]@{ Id = 123 }) } else { @() } }
            StopSpotify = { param($ignored) $script:spotifyRunning = $false; $true }
            StartSpotify = { param($ignored) $script:spotifyRunning = $true }
            SpotifyVersion = { param($ignored) '1.2.3.4' }
            SpicetifyExecutable = { 'C:\Tools\spicetify.exe' }
            SpicetifyState = { param($ignored) [pscustomobject]@{ Installed = $true; Version = '2.44.0'; NeedsRepair = $true; AppsState = 'Stock' } }
            CapturedProcess = { param($file, $arguments, $show) [pscustomobject]@{ ExitCode = 9; Output = ''; Error = 'mock repair failure' } }
            UpdateConfirmation = { }
        }
        Invoke-BlockUpdatesCore $context | Out-Null
        Assert-Throws { Invoke-GuidedSpotifyUpdate $context } 'previous update and running-state preferences were restored'
        Assert-True $script:spotifyRunning
        Assert-Equal 'Blocked' (Get-UpdateAccessStatus $context).State
        Assert-False (Test-Path -LiteralPath (Get-ManagerStatePath 'Guided'))
        Invoke-AllowUpdatesCore $context | Out-Null
    }

    Invoke-Test 'requires verified final ACL state before reporting success' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $script:getAclCalls = 0
        $originalAcl = Get-Acl -LiteralPath $context.UpdateDirectory
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            GetDirectorySecurity = { param($path) $script:getAclCalls++; $originalAcl }
            SetDirectorySecurity = { param($path, $acl) }
            WriteProbe = { param($path) $true }
        }
        Assert-Throws { Invoke-BlockUpdatesCore $context } 'original permissions were restored'
        Assert-True ($script:getAclCalls -ge 2)
    }

    Invoke-Test 'refuses reparse points and never reaches an ACL command' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed
        $outside = Join-Path $root 'Outside Target'
        New-Item -ItemType Directory -Path $outside | Out-Null
        New-Item -ItemType Junction -Path $context.UpdateDirectory -Target $outside | Out-Null
        $script:setCalls = 0
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{ SetDirectorySecurity = { param($path, $acl) $script:setCalls++ } }
        Assert-Throws { Invoke-BlockUpdatesCore $context } 'reparse point|junction'
        Assert-Equal 0 $script:setCalls
    }

    Invoke-Test 'restricts every ACL action to the exact Spotify Update path' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $context.UpdateDirectory = Normalize-WindowsPath (Join-Path $context.LocalDirectory 'Not-Update')
        New-Item -ItemType Directory -Path $context.UpdateDirectory | Out-Null
        $script:setCalls = 0
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{ SetDirectorySecurity = { param($path, $acl) $script:setCalls++ } }
        Assert-Throws { Invoke-BlockUpdatesCore $context } 'unexpected update path'
        Assert-Equal 0 $script:setCalls
    }

    Invoke-Test 'builds the ready-to-run batch deterministically' {
        & $buildPath | Out-Null
        $first = (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash
        & $buildPath | Out-Null
        $second = (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash
        Assert-Equal $first $second
        & $buildPath -Check | Out-Null
        $content = [IO.File]::ReadAllText($releasePath)
        Assert-Equal 1 ([regex]::Matches($content, [regex]::Escape('# <SPICETIFY_MANAGER_POWERSHELL>')).Count)
        Assert-False ($content -match '(?<!\r)\n') 'Generated batch contains a bare LF line ending.'
    }

    Invoke-Test 'runs the generated one-file release under Windows PowerShell 5.1' {
        $oldValue = $env:SPICETIFY_MANAGER_TEST_MODE
        try {
            $env:SPICETIFY_MANAGER_TEST_MODE = '1'
            $output = & $releasePath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match $output 'SELFTEST OK'
        }
        finally {
            if ($null -eq $oldValue) { Remove-Item Env:\SPICETIFY_MANAGER_TEST_MODE -ErrorAction SilentlyContinue }
            else { $env:SPICETIFY_MANAGER_TEST_MODE = $oldValue }
        }
    }
}
finally {
    Set-ManagerTestHooks @{}
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    foreach ($root in $script:TemporaryRoots) {
        $resolved = [IO.Path]::GetFullPath($root)
        if (-not $resolved.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'SpicetifyManagerTests-*') {
            throw "Refusing to clean an unexpected test path: $resolved"
        }
        if (Test-Path -LiteralPath $resolved) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
Write-Host ("Tests: {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -ne 0) { exit 1 }
