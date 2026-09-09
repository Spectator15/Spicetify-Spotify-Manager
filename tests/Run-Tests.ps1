[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = Join-Path $repositoryRoot 'src\SpicetifySpotifyManager.ps1'
$buildPath = Join-Path $repositoryRoot 'build\Build-Release.ps1'
$releasePath = Join-Path $repositoryRoot 'Spicetify-Spotify-Manager.exe'
$helperSourcePath = Join-Path $repositoryRoot 'src\ElevatedAclHelper.ps1'

. $sourcePath -NoMain
$script:DirectoryAclSourceBase64 = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes([IO.File]::ReadAllText((Join-Path $repositoryRoot 'src\DirectoryAcl.ps1'))))
$helperTemplate = [IO.File]::ReadAllText($helperSourcePath).Replace('__SPICETIFY_MANAGER_DIRECTORY_ACL_BASE64__', $script:DirectoryAclSourceBase64)
$script:ElevatedAclHelperTemplateBase64 = [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($helperTemplate))

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

function Assert-NotMatch {
    param([string]$Value, [string]$Pattern)
    if ($Value -match $Pattern) { throw "Expected '$Value' not to match '$Pattern'." }
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
    # Isolate fixtures from the host TEMP ACL (the sandbox has a separate SID).
    $acl = Get-Acl -LiteralPath $root
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($userSid)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidValue in @($userSid.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $root -AclObject $acl
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
    $directory = Join-Path $Root 'Manager Data'
    if (-not (Test-Path -LiteralPath $directory)) {
        # The hosted runner's token can default to Administrators as owner.
        # Access-rule inheritance and the IsAdministrator hook do not change
        # that token default. Establish the normal-user invariant explicitly,
        # preserving the inherited DACL and never repairing an existing fixture.
        New-Item -ItemType Directory -Path $directory | Out-Null
        $acl = Get-Acl -LiteralPath $directory
        $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        Set-Acl -LiteralPath $directory -AclObject $acl
    }
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

function Invoke-TestElevatedBootstrap {
    param([Parameter(Mandatory = $true)][string]$EncodedCommand)
    $bootstrap = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($EncodedCommand))
    try {
        & ([scriptblock]::Create($bootstrap))
        return [pscustomobject]@{ ExitCode = 0 }
    }
    catch {
        return [pscustomobject]@{ ExitCode = 1; Error = $_.Exception.Message }
    }
}

function Invoke-TestRawBatch {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$RawArguments, [switch]$DelayedExpansion)
    # Test-only command construction exercises CMD's real caller boundary.
    # No user data, real package operation or system path is a test command.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $expansionMode = if ($DelayedExpansion) { 'on' } else { 'off' }
    $start.Arguments = '/d /v:' + $expansionMode + ' /s /c ""' + $Path + '" ' + $RawArguments + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # A rejected CMD line can skip the wrapper's cleanup. Keep every wrapper
    # this adversarial probe creates inside a fixture owned by the test suite.
    $testTemporary = New-TestRoot
    $start.EnvironmentVariables['TMP'] = $testTemporary
    $start.EnvironmentVariables['TEMP'] = $testTemporary
    # Delayed expansion inserts these as data at the caller boundary. The EXE
    # must not turn their metacharacters back into operators on a second pass.
    $start.EnvironmentVariables['SSM_CLI_LITERAL'] = '!literal&echo SSM_CLI|echo SSM_CLI%'
    $process = [Diagnostics.Process]::Start($start)
    try {
        $process.StandardInput.Close()
        $outputRead = $process.StandardOutput.ReadToEndAsync()
        $errorRead = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            throw 'The generated CLI did not exit within its test deadline.'
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outputRead.Result; Error = $errorRead.Result }
    }
    finally { $process.Dispose() }
}

function Invoke-TestNativeExecutable {
    param([string]$Path, [AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentValues = @(), [switch]$InspectArguments, [string]$InputText = '')
    # Test caller only: .NET Framework ProcessStartInfo lacks ArgumentList.
    # Encode the Windows CLR/CRT convention, not CMD syntax. The production
    # launcher NEVER joins/encodes its argument array or starts another shell.
    $encoded = foreach ($value in $ArgumentValues) {
        $quoted = New-Object Text.StringBuilder
        [void]$quoted.Append([char]34)
        $slashes = 0
        foreach ($character in $value.ToCharArray()) {
            if ($character -eq [char]92) { $slashes++; continue }
            if ($character -eq [char]34) {
                [void]$quoted.Append([char]92, (2 * $slashes + 1))
            }
            else { [void]$quoted.Append([char]92, $slashes) }
            [void]$quoted.Append($character)
            $slashes = 0
        }
        [void]$quoted.Append([char]92, (2 * $slashes))
        [void]$quoted.Append([char]34)
        $quoted.ToString()
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Path
    $start.Arguments = $encoded -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $start.WorkingDirectory = New-TestRoot
    $start.EnvironmentVariables['TMP'] = $start.WorkingDirectory
    $start.EnvironmentVariables['TEMP'] = $start.WorkingDirectory
    if ($InspectArguments) { $start.EnvironmentVariables['SPICETIFY_MANAGER_TEST_MODE'] = '1' }
    else { $start.EnvironmentVariables.Remove('SPICETIFY_MANAGER_TEST_MODE') }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $outputRead = $process.StandardOutput.ReadToEndAsync()
        $errorRead = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Native CLI exceeded its test deadline.' }
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $start.WorkingDirectory -Force).Count 'The launcher extracted a payload into its empty working/temp directory.'
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outputRead.Result; Error = $errorRead.Result }
    }
    finally { $process.Dispose() }
}

function Read-EmbeddedManager {
    param([string]$Path = $releasePath)
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($Path))
    $stream = $assembly.GetManifestResourceStream('SpicetifyManager.Manager.ps1')
    Assert-True ($null -ne $stream)
    $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false, $true)))
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

function Write-TestElevatedResult {
    param(
        [Parameter(Mandatory = $true)][string]$TemporaryRoot,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [bool]$Success = $true,
        [string]$Message = 'Test helper result.'
    )
    Write-JsonFileAtomic -Path (Join-Path $TemporaryRoot 'result.json') -Value ([ordered]@{
        SchemaVersion = 1
        OperationId = $OperationId
        Action = $Action
        TargetPath = $TargetPath
        HelperHash = $ExpectedHash
        Success = $Success
        Changed = $Success
        Message = $Message
    })
}

function New-ValidInstallerFixture {
    $fixture = @'
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$spicetifyFolderPath = "$env:LOCALAPPDATA\spicetify"
function Test-Admin { return $false }
function Test-PowerShellVersion { return $true }
function Get-Spicetify {
    Invoke-RestMethod -Uri 'https://api.github.com/repos/spicetify/cli/releases/latest'
    $url = "https://github.com/spicetify/cli/releases/download/v$targetVersion/spicetify-$targetVersion-windows-$architecture.zip"
}
function Add-SpicetifyToPath { return }
function Install-Spicetify {
    Expand-Archive -Path $archivePath -DestinationPath $spicetifyFolderPath -Force
}
Install-Spicetify
'@
    return $fixture + ("`n# official installer fixture padding" * 180)
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
    Invoke-Test 'current-user-owned state fixture is accepted by the production guard' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed
        Use-TestEnvironment $root $context
        $directory = Get-ManagerDataDirectory
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        Assert-Equal $sid.Value (Get-Acl -LiteralPath $root).GetOwner([Security.Principal.SecurityIdentifier]).Value
        Assert-Equal $sid.Value (Get-Acl -LiteralPath $directory).GetOwner([Security.Principal.SecurityIdentifier]).Value
        $before = (Get-Acl -LiteralPath $directory).Sddl
        Assert-SafeManagerDataDirectory
        Assert-Equal $directory (Initialize-ManagerDataDirectory)
        Use-TestEnvironment $root $context
        Assert-Equal $before (Get-Acl -LiteralPath $directory).Sddl 'Fixture reuse changed an existing security descriptor.'
    }

    Invoke-Test 'wrong-owner state fixture is rejected by the unchanged production guard' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed
        Use-TestEnvironment $root $context
        $directory = Get-ManagerDataDirectory
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $original = Get-Acl -LiteralPath $directory
        $wrongOwnerAcl = Get-Acl -LiteralPath $directory
        try {
            if (-not $identity.Owner.Equals($identity.User)) {
                # The hosted runner can assign its token's default group owner
                # without requesting new privilege. Exercise a real wrong owner.
                $wrongOwnerAcl.SetOwner($identity.Owner)
                Set-Acl -LiteralPath $directory -AclObject $wrongOwnerAcl
                try {
                    Assert-Equal $identity.Owner.Value (Get-Acl -LiteralPath $directory).GetOwner([Security.Principal.SecurityIdentifier]).Value
                    Use-TestEnvironment $root $context
                    Assert-Throws { Assert-SafeManagerDataDirectory } 'Manager state directory has an unexpected owner'
                }
                finally { Set-Acl -LiteralPath $directory -AclObject $original }
                Write-Host '      Wrong-owner regression used a real filesystem owner.'
            }
            else {
                # Unelevated local tokens need not have permission to assign a
                # different on-disk owner. Substitute only the ACL read, not the
                # current SID or guard; request no elevation and change no file.
                $alternate = @($identity.Groups | Where-Object { -not $_.Equals($identity.User) })[0]
                $wrongOwnerAcl.SetOwner($alternate)
                function Get-Acl {
                    param([string]$LiteralPath)
                    Assert-Equal $directory $LiteralPath
                    return $wrongOwnerAcl
                }
                Assert-Throws { Assert-SafeManagerDataDirectory } 'Manager state directory has an unexpected owner'
                Write-Host '      Wrong-owner regression used an ACL-read substitute; no foreign-owner privilege requested.'
            }
        }
        finally { $identity.Dispose() }
    }

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
        $originalFingerprint = Get-AclFingerprint (Get-Acl -LiteralPath $context.UpdateDirectory)
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
        Assert-Equal $originalFingerprint (Get-AclFingerprint (Get-Acl -LiteralPath $context.UpdateDirectory))
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
        $originalFingerprint = Get-AclFingerprint (Get-Acl -LiteralPath $context.UpdateDirectory)
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{ WriteProbe = { param($path) $true } }
        Assert-Throws { Invoke-BlockUpdatesCore $context } 'original permissions were restored'
        Assert-Equal $originalFingerprint (Get-AclFingerprint (Get-Acl -LiteralPath $context.UpdateDirectory))
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

    Invoke-Test 'refuses a junction in a Spotify parent before any ACL mutation' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed
        $outside = Join-Path $root 'Outside Parent'
        [void][IO.Directory]::CreateDirectory((Join-Path $outside 'Update'))
        [IO.Directory]::Delete($context.LocalDirectory)
        New-Item -ItemType Junction -Path $context.LocalDirectory -Target $outside | Out-Null
        $before = Get-AclFingerprint (Get-Acl -LiteralPath (Join-Path $outside 'Update'))
        $script:setCalls = 0
        Use-TestEnvironment $root $context @{ SetDirectorySecurity = { param($path, $acl) $script:setCalls++ } }
        try {
            Assert-Throws { Invoke-BlockUpdatesCore $context } 'reparse point|junction'
            Assert-Equal 0 $script:setCalls
            Assert-Equal $before (Get-AclFingerprint (Get-Acl -LiteralPath (Join-Path $outside 'Update')))
        }
        finally { [IO.Directory]::Delete($context.LocalDirectory) }
    }

    Invoke-Test 'state directory junctions and unexpected writers are refused' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment $root $context
        $directory = Get-ManagerDataDirectory
        $outside = Join-Path $root 'Outside State'
        [void][IO.Directory]::CreateDirectory($outside)
        [IO.Directory]::Delete($directory)
        New-Item -ItemType Junction -Path $directory -Target $outside | Out-Null
        try { Assert-Throws { Get-UpdateStateRecord } 'reparse point|junction' }
        finally { [IO.Directory]::Delete($directory) }
        Use-TestEnvironment $root $context
        [void](Initialize-ManagerDataDirectory)
        $acl = Get-Acl -LiteralPath $directory
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-1-0')), 'Write', 'Allow')
        [void]$acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $directory -AclObject $acl
        Assert-Throws { Get-UpdateStateRecord } 'unexpected account'
    }

    Invoke-Test 'bound ACL session prevents parent and leaf replacement before mutation' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment $root $context
        Initialize-DirectoryAclApi
        $outside = Join-Path $root 'Unrelated Directory'
        [void][IO.Directory]::CreateDirectory($outside)
        $outsideBefore = Get-AclFingerprint (Get-Acl -LiteralPath $outside)
        $session = Open-BoundDirectoryAclSession $context.UpdateDirectory
        try {
            Assert-Match $session.CanonicalRoot '^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$'
            Assert-Throws { [IO.Directory]::Move($context.LocalDirectory, ($context.LocalDirectory + '-moved')) }
            Assert-Throws { [IO.Directory]::Move($context.UpdateDirectory, ($context.UpdateDirectory + '-moved')) }
            $original = $session.Read()
            $changed = Add-ManagerAclRules (New-AclFromSddl (Get-AclSddl $original)) (Get-CurrentUserSid)
            $session.Write($changed)
            Assert-True (Test-ManagerAclRulesPresent ($session.Read()) (Get-CurrentUserSid))
            $session.Write($original)
            Assert-Equal (Get-AclFingerprint $original) (Get-AclFingerprint ($session.Read()))
            Assert-Equal $outsideBefore (Get-AclFingerprint (Get-Acl -LiteralPath $outside))
        }
        finally { $session.Dispose() }
        # Releasing the session must release its ancestor and target handles too.
        [IO.Directory]::Move($context.LocalDirectory, ($context.LocalDirectory + '-moved'))
        [IO.Directory]::Move(($context.LocalDirectory + '-moved'), $context.LocalDirectory)
    }

    Invoke-Test 'bound ACL session refuses a substituted parent and releases partial handles' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment $root $context
        Initialize-DirectoryAclApi
        $outside = Join-Path $root 'Outside Spotify'
        [void][IO.Directory]::CreateDirectory((Join-Path $outside 'Update'))
        $outsideBefore = Get-AclFingerprint (Get-Acl -LiteralPath (Join-Path $outside 'Update'))
        $savedParent = $context.LocalDirectory + '-saved'
        [IO.Directory]::Move($context.LocalDirectory, $savedParent)
        New-Item -ItemType Junction -Path $context.LocalDirectory -Target $outside | Out-Null
        try {
            Assert-Throws { Open-BoundDirectoryAclSession $context.UpdateDirectory } 'reparse point|junction'
            Assert-Equal $outsideBefore (Get-AclFingerprint (Get-Acl -LiteralPath (Join-Path $outside 'Update')))
        }
        finally {
            [IO.Directory]::Delete($context.LocalDirectory)
            [IO.Directory]::Move($savedParent, $context.LocalDirectory)
        }
        $session = Open-BoundDirectoryAclSession $context.UpdateDirectory
        $session.Dispose()
    }

    Invoke-Test 'bound ACL session rejects leaf junctions files missing paths and device paths' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment $root $context
        Initialize-DirectoryAclApi
        $link = Join-Path $root 'Update Link'
        New-Item -ItemType Junction -Path $link -Target $context.UpdateDirectory | Out-Null
        try { Assert-Throws { Open-BoundDirectoryAclSession $link } 'reparse point|junction' }
        finally { [IO.Directory]::Delete($link) }
        Assert-Throws { Open-BoundDirectoryAclSession $context.Executable } 'non-directory'
        Assert-Throws { Open-BoundDirectoryAclSession (Join-Path $root 'missing') }
        Assert-Throws { Open-BoundDirectoryAclSession '\\.\C:' } 'local drive'
    }

    Invoke-Test 'bound ACL restore retains owner group protection and unrelated ACEs' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment $root $context
        Initialize-DirectoryAclApi
        $original = Get-Acl -LiteralPath $context.UpdateDirectory
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-11')), 'ReadAndExecute', 'Allow')
        [void]$original.AddAccessRule($rule)
        Set-Acl -LiteralPath $context.UpdateDirectory -AclObject $original
        $original = Get-Acl -LiteralPath $context.UpdateDirectory
        $session = Open-BoundDirectoryAclSession $context.UpdateDirectory
        try {
            $blocked = Add-ManagerAclRules (New-AclFromSddl (Get-AclSddl $original)) (Get-CurrentUserSid)
            $session.Write($blocked)
            $changedGroup = New-AclFromSddl (Get-AclSddl $blocked)
            $changedGroup.SetGroup((New-Object Security.Principal.SecurityIdentifier((Get-CurrentUserSid))))
            $session.Write($changedGroup)
            Assert-Equal (Get-CurrentUserSid) ($session.Read().GetGroup([Security.Principal.SecurityIdentifier]).Value)
            $session.Write($original)
            Assert-Equal (Get-AclFingerprint $original) (Get-AclFingerprint ($session.Read()))
        }
        finally { $session.Dispose() }
    }

    Invoke-Test 'bound ACL inheritance does not change an external junction target' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment $root $context
        Initialize-DirectoryAclApi
        $outside = Join-Path $root 'Unrelated Resources'
        [void][IO.Directory]::CreateDirectory($outside)
        $outsideAcl = Get-Acl -LiteralPath $outside
        $outsideBefore = Get-AclFingerprint $outsideAcl
        $link = Join-Path $context.UpdateDirectory 'External Link'
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        $session = Open-BoundDirectoryAclSession $context.UpdateDirectory
        $original = $session.Read()
        try {
            $session.Write((Add-ManagerAclRules (New-AclFromSddl (Get-AclSddl $original)) (Get-CurrentUserSid)))
            Assert-Equal $outsideBefore (Get-AclFingerprint (Get-Acl -LiteralPath $outside))
        }
        finally {
            try { $session.Write($original) } finally { $session.Dispose() }
            [IO.Directory]::Delete($link)
            Set-Acl -LiteralPath $outside -AclObject $outsideAcl
        }
    }

    Invoke-Test 'both ACL write paths use the same handle API without path-based fallback' {
        $helper = Get-ElevatedAclHelperTemplate
        Assert-NotMatch $helper '(?i)\bSet-Acl\b|SetNamedSecurityInfo|SetFileSecurity'
        Assert-Match $helper 'Open-BoundDirectoryAclSession \$target'
        Assert-Match $helper '\$session\.Write\(\$targetAcl\)'
        Assert-Match $helper '\$verifiedAcl = \$session\.Read\(\)'
        Assert-True $helper.Contains($script:DirectoryAclSourceBase64)
        Assert-NotMatch ${function:Set-DirectorySecurity}.ToString() '(?i)\bSet-Acl\b'
        $native = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:DirectoryAclSourceBase64))
        Assert-Match $native "GetMethod\('Persist'"
        Assert-Match $native '\$native::GetSecurityInfo\(\$Session.Target'
        Assert-NotMatch $native '(?im)^\s*(Add-Type|Set-Acl)\b|CompilerParameters|ReadAllBytes|ReadAllText|Assembly\]::LoadFrom'
    }

    Invoke-Test 'DACL normalization ignores only AI and still detects changed rights' {
        $original = New-AclFromSddl 'O:SYG:SYD:P(A;;FA;;;SY)'
        $normalized = New-AclFromSddl 'O:SYG:SYD:PAI(A;;FA;;;SY)'
        $changed = New-AclFromSddl 'O:SYG:SYD:PAI(A;;FR;;;SY)'
        Assert-Equal (Get-ComparableAccessSddl $original) (Get-ComparableAccessSddl $normalized)
        Assert-False ((Get-ComparableAccessSddl $original) -eq (Get-ComparableAccessSddl $changed))
        # Exercise the helper's actual comparison function, not a substitute.
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($helperSourcePath, [ref]$tokens, [ref]$errors)
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ComparableAccessSddl' }, $true)
        & {
            . ([scriptblock]::Create($definition.Extent.Text))
            Assert-Equal (Get-ComparableAccessSddl $original) (Get-ComparableAccessSddl $normalized)
            Assert-False ((Get-ComparableAccessSddl $original) -eq (Get-ComparableAccessSddl $changed))
        }
    }

    Invoke-Test 'declining guided recovery retains the saved preferences' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        Use-TestEnvironment $root $context
        Save-GuidedState ([pscustomobject]@{ RestoreBlock = $true; RestoreRunning = $false })
        & {
            function Read-Host { param($Prompt) return 'n' }
            Assert-Throws { Resolve-GuidedRecovery $context } 'deferred'
        }
        Assert-True (Test-Path -LiteralPath (Get-ManagerStatePath Guided))
    }

    Invoke-Test 'temporary cleanup removes junctions without traversing their target' {
        $outside = New-TestRoot
        $sentinel = Join-Path $outside 'preserved.txt'
        [IO.File]::WriteAllText($sentinel, 'preserved')
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('SpicetifySpotifyManager-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($temporary)
        New-Item -ItemType Junction -Path (Join-Path $temporary 'link') -Target $outside | Out-Null
        Remove-ManagerTemporaryDirectory $temporary
        Assert-False (Test-Path -LiteralPath $temporary)
        Assert-Equal 'preserved' ([IO.File]::ReadAllText($sentinel))
    }

    Invoke-Test 'Windows sources and tests parse as Windows PowerShell 5.1 reads them' {
        foreach ($path in @($sourcePath, $helperSourcePath, (Join-Path $repositoryRoot 'src\DirectoryAcl.ps1'), $buildPath, $PSCommandPath)) {
            $tokens = $null; $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            Assert-Equal 0 @($errors).Count
        }
    }

    Invoke-Test 'detects permission failures without relying on English messages' {
        $win32 = New-Object ComponentModel.Win32Exception(1314, 'beliebiger nicht-englischer Text')
        $win32Record = New-Object Management.Automation.ErrorRecord($win32, 'ArbitraryIdentifier', [Management.Automation.ErrorCategory]::NotSpecified, $null)
        Assert-True (Test-PermissionFailure $win32Record)
        $inner = New-Object UnauthorizedAccessException((-join [char[]]@(0x4efb, 0x610f, 0x306e, 0x30e1, 0x30c3, 0x30bb, 0x30fc, 0x30b8)))
        $outer = New-Object Exception('mensaje arbitrario', $inner)
        $innerRecord = New-Object Management.Automation.ErrorRecord($outer, 'OtherIdentifier', [Management.Automation.ErrorCategory]::NotSpecified, $null)
        Assert-True (Test-PermissionFailure $innerRecord)
        $categoryRecord = New-Object Management.Automation.ErrorRecord((New-Object Exception('anything')), 'OtherIdentifier', [Management.Automation.ErrorCategory]::PermissionDenied, $null)
        Assert-True (Test-PermissionFailure $categoryRecord)
        $unrelated = New-Object Management.Automation.ErrorRecord((New-Object Exception('access denied privilege')), 'OtherIdentifier', [Management.Automation.ErrorCategory]::InvalidData, $null)
        Assert-False (Test-PermissionFailure $unrelated)
    }

    Invoke-Test 'does not offer elevation for an unrelated English-looking failure' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $script:elevationCalls = 0
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            SetDirectorySecurity = { param($path, $acl) throw [Exception]::new('access denied privilege') }
            ElevatedProcess = { param($encoded, $temporary, $action, $target, $acl, $hash, $operation) $script:elevationCalls++; [pscustomobject]@{ ExitCode = 1 } }
        }
        Assert-Throws { Invoke-UpdateAccessAction -Action Block -Context $context -PermitElevation } 'access denied privilege'
        Assert-Equal 0 $script:elevationCalls
    }

    Invoke-Test 'accepts only the current official installer structure and address' {
        $valid = New-ValidInstallerFixture
        Assert-True (Test-OfficialSpicetifyInstallerContent $valid)
        Assert-False (Test-OfficialSpicetifyInstallerContent '$ErrorActionPreference = ''Stop''')
        Assert-False (Test-OfficialSpicetifyInstallerContent ('<html>not found</html>' + ('x' * 5000)))
        Assert-False (Test-OfficialSpicetifyInstallerContent ('{"message":"rate limited"}' + (' ' * 5000)))
        Assert-False (Test-OfficialSpicetifyInstallerContent ("`$ErrorActionPreference = 'Stop'`nWrite-Host spicetify" + ('`n# padding' * 600)))
        Assert-False (Test-OfficialSpicetifyInstallerContent ($valid + "`n{"))
        $misleading = "`$ErrorActionPreference = 'Stop'`n# https://github.com/spicetify/cli/releases/download/" + ('`n# spicetify' * 600)
        Assert-False (Test-OfficialSpicetifyInstallerContent $misleading)
        Assert-OfficialInstallerUri ([uri]'https://raw.githubusercontent.com/spicetify/cli/main/install.ps1')
        Assert-Throws { Assert-OfficialInstallerUri ([uri]'http://raw.githubusercontent.com/spicetify/cli/main/install.ps1') } 'unexpected'
        Assert-Throws { Assert-OfficialInstallerUri ([uri]'https://example.com/spicetify/cli/main/install.ps1') } 'unexpected'
        Assert-Throws { Assert-OfficialInstallerUri ([uri]'https://raw.githubusercontent.com:444/spicetify/cli/main/install.ps1') } 'unexpected'
        Assert-Throws { Assert-OfficialInstallerUri ([uri]'https://user@raw.githubusercontent.com/spicetify/cli/main/install.ps1') } 'unexpected'
        Assert-Throws { Assert-OfficialInstallerUri ([uri]'https://raw.githubusercontent.com/spicetify/cli/main/install.ps1?unexpected=1') } 'unexpected'
    }

    Invoke-Test 'rejects misleading installer responses and unexpected redirects' {
        $validResponse = [pscustomobject]@{
            StatusCode = 200
            Headers = @{ 'Content-Type' = 'text/plain; charset=utf-8' }
            BaseResponse = [pscustomobject]@{ ResponseUri = [uri]'https://raw.githubusercontent.com/spicetify/cli/main/install.ps1' }
        }
        Assert-OfficialInstallerResponse $validResponse
        $htmlResponse = [pscustomobject]@{ StatusCode = 200; Headers = @{ 'Content-Type' = 'text/html' }; BaseResponse = $null }
        Assert-Throws { Assert-OfficialInstallerResponse $htmlResponse } 'content type'
        $redirectResponse = [pscustomobject]@{ StatusCode = 200; Headers = @{ 'Content-Type' = 'text/plain' }; BaseResponse = [pscustomobject]@{ ResponseUri = [uri]'https://example.com/install.ps1' } }
        Assert-Throws { Assert-OfficialInstallerResponse $redirectResponse } 'unexpected'
        $failureResponse = [pscustomobject]@{ StatusCode = 404; Headers = @{}; BaseResponse = $null }
        Assert-Throws { Assert-OfficialInstallerResponse $failureResponse } 'HTTP 404'
    }

    Invoke-Test 'elevated bootstrap hashes and executes one in-memory read only' {
        $resultPath = Join-Path ([IO.Path]::GetTempPath()) ('SpicetifySpotifyManager-{0}\result.json' -f [guid]::NewGuid().ToString('N'))
        $bootstrap = New-ElevatedBootstrapSource -Action Block -ResultPath $resultPath -ExpectedHash ('A' * 64)
        Assert-Equal 1 ([regex]::Matches($bootstrap, '\[IO\.File\]::ReadAllBytes\(\$helperPath\)').Count)
        Assert-Equal 1 ([regex]::Matches($bootstrap, 'ComputeHash\(\$helperBytes\)').Count)
        Assert-Equal 1 ([regex]::Matches($bootstrap, 'GetString\(\$helperBytes\)').Count)
        Assert-Equal 1 ([regex]::Matches($bootstrap, '\[scriptblock\]::Create\(\$helperText\)').Count)
        Assert-NotMatch $bootstrap '(?i)Get-Content|ReadAllText|powershell(?:\.exe)?\s+-File|&\s+\$helperPath'
        $readIndex = $bootstrap.IndexOf('[IO.File]::ReadAllBytes($helperPath)', [StringComparison]::Ordinal)
        $hashIndex = $bootstrap.IndexOf('ComputeHash($helperBytes)', [StringComparison]::Ordinal)
        $compareIndex = $bootstrap.IndexOf('[string]::Equals($actualHash, $expectedHash', [StringComparison]::Ordinal)
        $decodeIndex = $bootstrap.IndexOf('$utf8.GetString($helperBytes)', [StringComparison]::Ordinal)
        $scriptBlockIndex = $bootstrap.IndexOf('[scriptblock]::Create($helperText)', [StringComparison]::Ordinal)
        Assert-True (0 -le $readIndex -and $readIndex -lt $hashIndex -and $hashIndex -lt $compareIndex -and $compareIndex -lt $decodeIndex -and $decodeIndex -lt $scriptBlockIndex)
    }

    Invoke-Test 'tampered elevated helper cannot mutate Spotify or its ACL and is cleaned' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $sentinel = Join-Path $context.UpdateDirectory 'spotify-data.txt'
        Set-Content -LiteralPath $sentinel -Value 'untouched'
        $beforeAcl = Get-AclFingerprint (Get-Acl -LiteralPath $context.UpdateDirectory)
        $script:elevatedTemporaryRoot = ''
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            BeforeElevatedProcess = {
                param($temporary, $source, $result, $hash, $operation)
                $script:elevatedTemporaryRoot = $temporary
                [IO.File]::AppendAllText($source, "`n# tampered after hashing")
            }
            ElevatedProcess = { param($encoded, $temporary, $action, $target, $acl, $hash, $operation) Invoke-TestElevatedBootstrap $encoded }
        }
        Assert-Throws { Invoke-ElevatedAclSet -Path $context.UpdateDirectory -Acl (Get-Acl -LiteralPath $context.UpdateDirectory) -Action Block } 'did not return|integrity'
        Assert-Equal $beforeAcl (Get-AclFingerprint (Get-Acl -LiteralPath $context.UpdateDirectory))
        Assert-Equal 'untouched' (Get-Content -LiteralPath $sentinel -Raw).Trim()
        Assert-False (Test-Path -LiteralPath $script:elevatedTemporaryRoot)
    }

    Invoke-Test 'incorrect elevated helper hash fails before scriptblock creation' {
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('SpicetifySpotifyManager-{0}' -f [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $temporary | Out-Null
            Protect-ManagerTemporaryDirectory $temporary | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $temporary 'acl-helper.ps1'), ([Text.Encoding]::UTF8.GetBytes('# payload' + ('x' * 2048))))
            $bootstrap = New-ElevatedBootstrapSource -Action Block -ResultPath (Join-Path $temporary 'result.json') -ExpectedHash ('0' * 64)
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
            $result = Invoke-TestElevatedBootstrap $encoded
            Assert-Equal 1 $result.ExitCode
            Assert-Match $result.Error 'integrity check failed'
            Assert-False (Test-Path -LiteralPath (Join-Path $temporary 'result.json'))
        }
        finally { Remove-ManagerTemporaryDirectory $temporary }
    }

    Invoke-Test 'missing elevated helper and cancelled elevation clean temporary files' {
        foreach ($mode in @('missing', 'cancelled')) {
            $root = New-TestRoot
            $context = New-TestContext -Root $root -Installed -CreateUpdate
            $script:elevatedTemporaryRoot = ''
            $script:elevatedMode = $mode
            $hooks = @{
                BeforeElevatedProcess = {
                    param($temporary, $source, $result, $hash, $operation)
                    $script:elevatedTemporaryRoot = $temporary
                    if ($script:elevatedMode -eq 'missing') { Remove-Item -LiteralPath $source -Force }
                }
                ElevatedProcess = {
                    param($encoded, $temporary, $action, $target, $acl, $hash, $operation)
                    if ($script:elevatedMode -eq 'cancelled') { throw 'Administrator permission was cancelled. No elevated ACL change was completed.' }
                    Invoke-TestElevatedBootstrap $encoded
                }
            }
            Use-TestEnvironment -Root $root -Context $context -ExtraHooks $hooks
            Assert-Throws { Invoke-ElevatedAclSet -Path $context.UpdateDirectory -Acl (Get-Acl -LiteralPath $context.UpdateDirectory) -Action Block } 'did not return|cancelled'
            Assert-False (Test-Path -LiteralPath $script:elevatedTemporaryRoot)
        }
    }

    Invoke-Test 'elevated bootstrap refuses reparse and unexpected helper paths' {
        $root = New-TestRoot
        $outside = Join-Path $root 'outside-helper-directory'
        New-Item -ItemType Directory -Path $outside | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $outside 'acl-helper.ps1'), ([Text.Encoding]::UTF8.GetBytes('# payload' + ('x' * 2048))))
        $link = Join-Path ([IO.Path]::GetTempPath()) ('SpicetifySpotifyManager-{0}' -f [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
            $bootstrap = New-ElevatedBootstrapSource -Action Block -ResultPath (Join-Path $link 'result.json') -ExpectedHash ('0' * 64)
            $result = Invoke-TestElevatedBootstrap ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap)))
            Assert-Equal 1 $result.ExitCode
            Assert-Match $result.Error 'not a normal directory'
            Assert-False (Test-Path -LiteralPath (Join-Path $outside 'result.json'))
        }
        finally {
            if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
        }
        $unexpected = Join-Path $root 'result.json'
        $bootstrap = New-ElevatedBootstrapSource -Action Block -ResultPath $unexpected -ExpectedHash ('0' * 64)
        $result = Invoke-TestElevatedBootstrap ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap)))
        Assert-Equal 1 $result.ExitCode
        Assert-Match $result.Error 'outside the Windows temporary directory|name is invalid'
    }

    Invoke-Test 'interrupted elevated setup cleans its protected temporary directory' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $script:elevatedTemporaryRoot = ''
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            BeforeElevatedProcess = {
                param($temporary, $source, $result, $hash, $operation)
                $script:elevatedTemporaryRoot = $temporary
                throw 'mock interruption before UAC'
            }
        }
        Assert-Throws { Invoke-ElevatedAclSet -Path $context.UpdateDirectory -Acl (Get-Acl -LiteralPath $context.UpdateDirectory) -Action Block } 'mock interruption'
        Assert-False (Test-Path -LiteralPath $script:elevatedTemporaryRoot)
    }

    Invoke-Test 'malformed and failed elevated results are rejected and cleaned' {
        foreach ($mode in @('malformed', 'failed')) {
            $root = New-TestRoot
            $context = New-TestContext -Root $root -Installed -CreateUpdate
            $script:elevatedTemporaryRoot = ''
            $script:elevatedMode = $mode
            Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
                ElevatedProcess = {
                    param($encoded, $temporary, $action, $target, $acl, $hash, $operation)
                    $script:elevatedTemporaryRoot = $temporary
                    if ($script:elevatedMode -eq 'malformed') {
                        Write-JsonFileAtomic -Path (Join-Path $temporary 'result.json') -Value @{ unexpected = $true }
                        return [pscustomobject]@{ ExitCode = 0 }
                    }
                    Write-TestElevatedResult -TemporaryRoot $temporary -Action $action -TargetPath $target -ExpectedHash $hash -OperationId $operation -Success $false -Message 'mock elevated ACL mutation failed'
                    return [pscustomobject]@{ ExitCode = 1 }
                }
            }
            Assert-Throws { Invoke-ElevatedAclSet -Path $context.UpdateDirectory -Acl (Get-Acl -LiteralPath $context.UpdateDirectory) -Action Block } 'missing|mock elevated ACL mutation failed'
            Assert-False (Test-Path -LiteralPath $script:elevatedTemporaryRoot)
        }
    }

    Invoke-Test 'elevated block and allow retries preserve idempotence and recovery' {
        $root = New-TestRoot
        $context = New-TestContext -Root $root -Installed -CreateUpdate
        $original = Get-AclFingerprint (Get-Acl -LiteralPath $context.UpdateDirectory)
        $script:permissionFailures = 1
        $script:elevatedRoots = New-Object 'Collections.Generic.List[string]'
        Use-TestEnvironment -Root $root -Context $context -ExtraHooks @{
            SetDirectorySecurity = {
                param($path, $acl)
                if ($script:permissionFailures -gt 0) { $script:permissionFailures--; throw [UnauthorizedAccessException]::new((-join [char[]]@(0x975e, 0x82f1, 0x8a9e))) }
                Set-Acl -LiteralPath $path -AclObject $acl
            }
            ElevatedProcess = {
                param($encoded, $temporary, $action, $target, $acl, $hash, $operation)
                $script:elevatedRoots.Add($temporary)
                Set-Acl -LiteralPath $target -AclObject $acl
                Write-TestElevatedResult -TemporaryRoot $temporary -Action $action -TargetPath $target -ExpectedHash $hash -OperationId $operation
                [pscustomobject]@{ ExitCode = 0 }
            }
        }
        Assert-True (Invoke-UpdateAccessAction -Action Block -Context $context -PermitElevation).Changed
        Assert-Equal 'Blocked' (Get-UpdateAccessStatus $context).State
        Assert-False (Invoke-UpdateAccessAction -Action Block -Context $context -PermitElevation).Changed
        $script:permissionFailures = 1
        Assert-True (Invoke-UpdateAccessAction -Action Allow -Context $context -PermitElevation).Changed
        Assert-Equal 'Allowed' (Get-UpdateAccessStatus $context).State
        Assert-False (Invoke-UpdateAccessAction -Action Allow -Context $context -PermitElevation).Changed
        Assert-Equal $original (Get-AclFingerprint (Get-Acl -LiteralPath $context.UpdateDirectory))
        foreach ($temporary in $script:elevatedRoots) { Assert-False (Test-Path -LiteralPath $temporary) }
    }

    Invoke-Test 'elevated helper never contains or launches Spicetify' {
        $helper = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:ElevatedAclHelperTemplateBase64))
        Assert-NotMatch $helper '(?i)spicetify\.exe|Invoke-Spicetify|backup\s+apply|Start-Process'
        $startFunction = ${function:Start-ElevatedAclProcess}.ToString()
        Assert-NotMatch $startFunction '(?i)-File|spicetify'
        Assert-Match $startFunction '-EncodedCommand'
    }

    Invoke-Test 'builds the ready-to-run EXE deterministically with embedded source parity' {
        & $buildPath | Out-Null
        $first = (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash
        & $buildPath | Out-Null
        $second = (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash
        Assert-Equal $first $second
        & $buildPath -Check | Out-Null
        $content = Read-EmbeddedManager
        $normalizedSource = [IO.File]::ReadAllText($sourcePath) -replace "`r`n", "`n" -replace "`r", "`n"
        $normalizedAcl = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'src\DirectoryAcl.ps1')) -replace "`r`n", "`n" -replace "`r", "`n"
        $acl64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalizedAcl))
        $normalizedHelper = ([IO.File]::ReadAllText($helperSourcePath) -replace "`r`n", "`n" -replace "`r", "`n").Replace('__SPICETIFY_MANAGER_DIRECTORY_ACL_BASE64__', $acl64)
        $expected = $normalizedSource.Replace('__SPICETIFY_MANAGER_VERSION__', ([IO.File]::ReadAllText((Join-Path $repositoryRoot 'VERSION')).Trim())).Replace('__SPICETIFY_MANAGER_DIRECTORY_ACL_BASE64__', $acl64).Replace('__SPICETIFY_MANAGER_ELEVATED_HELPER_BASE64__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalizedHelper)))
        Assert-Equal $expected $content
        Assert-NotMatch $content '__SPICETIFY_MANAGER_[A-Z_]+__|\r'
        Assert-Equal '1.2.0.0' ([Diagnostics.FileVersionInfo]::GetVersionInfo($releasePath).FileVersion)
        Assert-Match ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($releasePath))) '<requestedExecutionLevel level="asInvoker" uiAccess="false"/>'
        $cleanRoot = Join-Path (New-TestRoot) ('Clean build & ' + [char]0x4e2d)
        [void][IO.Directory]::CreateDirectory($cleanRoot)
        foreach ($inputName in @('src', 'build', 'VERSION')) {
            Copy-Item -LiteralPath (Join-Path $repositoryRoot $inputName) -Destination $cleanRoot -Recurse
        }
        & (Join-Path $cleanRoot 'build\Build-Release.ps1') | Out-Null
        Assert-Equal $first (Get-FileHash -LiteralPath (Join-Path $cleanRoot 'Spicetify-Spotify-Manager.exe') -Algorithm SHA256).Hash 'A clean build from a different Unicode path changed the EXE.'
    }

    Invoke-Test 'Windows build rejects a tampered compiler archive before execution' {
        $cache = New-TestRoot
        $package = Join-Path $cache 'microsoft.net.compilers.toolset.4.14.0.nupkg'
        [IO.File]::WriteAllText($package, 'not a trusted compiler')
        $before = (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash
        Assert-Throws { & $buildPath -ToolCache $cache } 'Cached package hash mismatch'
        Assert-Equal $before (Get-FileHash -LiteralPath $releasePath -Algorithm SHA256).Hash
    }

    Invoke-Test 'runs the generated one-file release under Windows PowerShell 5.1' {
        $oldValue = $env:SPICETIFY_MANAGER_TEST_MODE
        try {
            $env:SPICETIFY_MANAGER_TEST_MODE = '1'
            $output = & $releasePath 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match $output 'SELFTEST OK'
            Assert-Match $output 'SELFTEST ENGINE 5\.1\.'
            Assert-Match $output 'SELFTEST POWERSHELL AVAILABLE True'
        }
        finally {
            if ($null -eq $oldValue) { Remove-Item Env:\SPICETIFY_MANAGER_TEST_MODE -ErrorAction SilentlyContinue }
            else { $env:SPICETIFY_MANAGER_TEST_MODE = $oldValue }
        }
    }

    Invoke-Test 'generated EXE exposes quiet noninteractive help version and status' {
        $versionOutput = & $releasePath --version 2>&1 | Out-String
        Assert-Equal 0 $LASTEXITCODE
        Assert-Match $versionOutput '^Spicetify Spotify Manager 1\.2\.0\s*$'
        $helpOutput = & $releasePath -h 2>&1 | Out-String
        Assert-Equal 0 $LASTEXITCODE
        Assert-Match $helpOutput '--status'
        Assert-NotMatch $helpOutput 'Select an action|Press Enter'
        $managerLog = Join-Path (Get-ManagerDataDirectory) 'manager.log'
        $logHashBefore = if (Test-Path -LiteralPath $managerLog -PathType Leaf) { (Get-FileHash -LiteralPath $managerLog -Algorithm SHA256).Hash } else { '' }
        $statusOutput = & $releasePath --status 2>&1 | Out-String
        $statusExit = $LASTEXITCODE
        Assert-True ($statusExit -in @(0, 3, 70))
        Assert-Match $statusOutput 'Current status'
        Assert-NotMatch $statusOutput 'Select an action|Press Enter'
        $logHashAfter = if (Test-Path -LiteralPath $managerLog -PathType Leaf) { (Get-FileHash -LiteralPath $managerLog -Algorithm SHA256).Hash } else { '' }
        Assert-Equal $logHashBefore $logHashAfter 'The read-only status command changed the manager log.'
    }

    Invoke-Test 'generated EXE rejects conflicting and metacharacter arguments safely' {
        # PowerShell 5.1 wraps native stderr as ErrorRecords. These failures are expected.
        $ErrorActionPreference = 'Continue'
        $root = New-TestRoot
        $sentinel = Join-Path $root 'argument-was-executed.txt'
        $output = & $releasePath '--status & echo unsafe' 2>&1 | Out-String
        Assert-Equal 64 $LASTEXITCODE
        Assert-Match $output 'Unknown or conflicting'
        $output = & $releasePath --help --status 2>&1 | Out-String
        Assert-Equal 64 $LASTEXITCODE
        Assert-NotMatch $output 'Select an action|Press Enter'
        $quotedArgument = '--status" & echo unsafe>"' + $sentinel + '" & rem "'
        $output = & $releasePath $quotedArgument 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -ne 0)
        Assert-False (Test-Path -LiteralPath $sentinel)
        $injectedIf = 'x"=="x" echo injected>"' + $sentinel + '" & rem "'
        $output = & $releasePath $injectedIf 2>&1 | Out-String
        Assert-Equal 64 $LASTEXITCODE
        Assert-False (Test-Path -LiteralPath $sentinel)
        $launcher = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'src\Launcher.cs'))
        Assert-NotMatch $launcher 'cmd\.exe|powershell\.exe|Process\.Start|ProcessStartInfo|GetCommandLine|%\*|WriteAll|CreateDirectory'
        Assert-Match $launcher 'AddParameter\("NativeArguments", arguments\)'
    }

    Invoke-Test 'generated EXE does not execute caret-escaped CMD arguments' {
        $root = New-TestRoot
        $sentinel = Join-Path $root 'forwarded-argument-executed.txt'
        $control = Join-Path $root 'ignore-arguments.cmd'
        [IO.File]::WriteAllText($control, "@echo off`r`nexit /b 64`r`n", [Text.Encoding]::ASCII)
        # The control distinguishes execution introduced by forwarding from
        # commands the caller's shell would have executed even without us.
        $argument = 'unknown^&echo SSM_TEST^>"' + $sentinel + '"'
        foreach ($program in @($control, $releasePath)) {
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $start.Arguments = '/d /v:off /s /c ""' + $program + '" ' + $argument + '"'
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($start)
            try {
                $outputRead = $process.StandardOutput.ReadToEndAsync()
                $errorRead = $process.StandardError.ReadToEndAsync()
                $process.WaitForExit()
                [void]$outputRead.Result
                [void]$errorRead.Result
                Assert-Equal 64 $process.ExitCode
                Assert-False (Test-Path -LiteralPath $sentinel) ("Escaped argument executed a command through '$program'.")
            }
            finally { $process.Dispose() }
        }
    }

    Invoke-Test 'generated CLI preserves valid options through CMD including quoted options' {
        foreach ($argument in @('--help', '-h', '--version', '-V', '"--version"')) {
            $result = Invoke-TestRawBatch $releasePath $argument
            Assert-Equal 0 $result.ExitCode
            Assert-NotMatch $result.Output 'Select an action|Press Enter'
        }
    }

    Invoke-Test 'generated CLI keeps special and empty extra arguments as data' {
        $failures = New-Object 'Collections.Generic.List[string]'
        $redirectionTarget = Join-Path (New-TestRoot) 'must-not-be-created.txt'
        $cases = [ordered]@{
            Spaces = '--version "two words"'
            Quotes = '--version "quoted""value"'
            Caret = '--version ^^'
            Ampersand = '--version ^&'
            Pipe = '--version ^|'
            InputRedirection = '--version ^< NUL'
            OutputRedirection = '--version ^> "' + $redirectionTarget + '"'
            Parentheses = '--version ^(value^)'
            Percent = '--version 100%literal'
            Exclamation = '--version !literal!'
            Unicode = '--version "' + [char]0x00fc + [char]0x4e2d + '"'
            Empty = '--version ""'
        }
        foreach ($case in $cases.GetEnumerator()) {
            $result = Invoke-TestRawBatch $releasePath $case.Value
            if ($result.ExitCode -ne 64 -or $result.Output -match 'Select an action|Press Enter') {
                $failures.Add(('{0}: expected usage exit 64, received {1}' -f $case.Key, $result.ExitCode))
            }
        }
        if (Test-Path -LiteralPath $redirectionTarget) {
            $failures.Add('An escaped output-redirection argument created a file.')
        }
        foreach ($argument in @('--version "!SSM_CLI_LITERAL!"', '--version !SSM_CLI_LITERAL!')) {
            $result = Invoke-TestRawBatch $releasePath $argument -DelayedExpansion
            if ($result.ExitCode -ne 64 -or $result.Output -match 'Select an action|Press Enter') {
                $failures.Add(('Delayed expansion: expected usage exit 64, received {0}' -f $result.ExitCode))
            }
        }
        Assert-Equal 0 $failures.Count ($failures -join '; ')
    }

    Invoke-Test 'native EXE preserves every argument boundary without injected side effects' {
        $root = New-TestRoot
        $sentinel = Join-Path $root 'must-not-exist.txt'
        $vectors = @('', 'two words', '"', '^', '&', '|', '<', '>', '(', ')', '%PATH%', '!SSM_CLI_LITERAL!',
            ([string][char]0x4e2d + [char]0x00fc), 'ends-in-\', 'backslash\"quote',
            ('x" & echo INJECTED>"' + $sentinel + '" & rem "'),
            ('x^&echo INJECTED^>"' + $sentinel + '"'),
            ('x|echo INJECTED>"' + $sentinel + '"'),
            ('$(New-Item -ItemType File -Path ''' + $sentinel + ''')'),
            ("a`r`nb`t c"), ' ^&|<>()%!" ')
        foreach ($vector in $vectors) {
            $values = [string[]]@('--version', $vector, '', 'trailing argument')
            $inspection = Invoke-TestNativeExecutable $releasePath -ArgumentValues $values -InspectArguments
            Assert-Equal 0 $inspection.ExitCode $inspection.Error
            Assert-Match $inspection.Output 'SELFTEST ARGUMENTS ([A-Za-z0-9+/=]+)'
            $record = [regex]::Match($inspection.Output, 'SELFTEST ARGUMENTS ([A-Za-z0-9+/=]+)').Groups[1].Value
            # WinPS 5.1 emits a JSON array as one pipeline object. Assign that
            # array directly instead of adding a second outer array with @().
            $actual = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($record)))
            Assert-Equal $values.Count $actual.Count
            for ($index = 0; $index -lt $values.Count; $index++) { Assert-True ([string]::Equals($values[$index], $actual[$index], [StringComparison]::Ordinal)) 'An argument boundary or character was changed.' }
            Assert-False (Test-Path -LiteralPath $sentinel) 'Argument inspection executed an injected side effect.'
            $rejected = Invoke-TestNativeExecutable $releasePath -ArgumentValues $values
            Assert-Equal 64 $rejected.ExitCode $rejected.Error
            Assert-False (Test-Path -LiteralPath $sentinel) 'Normal CLI validation executed an injected side effect.'
        }
    }

    Invoke-Test 'native EXE rejects internal switches and preserves empty versus absent arguments' {
        foreach ($values in @(@('-NoMain'), @('-CliAction', 'Block'), @('-NativeArguments', '--help'), @(''))) {
            $result = Invoke-TestNativeExecutable $releasePath -ArgumentValues $values
            Assert-Equal 64 $result.ExitCode
            Assert-NotMatch $result.Output 'Select an action|Press Enter'
        }
        $result = Invoke-TestNativeExecutable $releasePath -ArgumentValues @() -InspectArguments
        Assert-Equal 0 $result.ExitCode
        Assert-Match $result.Output 'SELFTEST ARGUMENTS W10='
    }

    Invoke-Test 'compiled console host runs the unchanged menu with isolated discovery' {
        $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($releasePath))
        $hostInstance = [Activator]::CreateInstance($assembly.GetType('SpicetifyManager.ManagerHost'), $true)
        $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($hostInstance)
        $runspace.Open()
        $engine = [Management.Automation.PowerShell]::Create()
        $engine.Runspace = $runspace
        $oldIn = [Console]::In; $oldOut = [Console]::Out
        $inputReader = New-Object IO.StringReader("0`r`n")
        $outputWriter = New-Object IO.StringWriter
        try {
            [Console]::SetIn($inputReader); [Console]::SetOut($outputWriter)
            [void]$engine.AddScript((Read-EmbeddedManager), $false).AddParameter('NoMain', $true)
            [void]$engine.Invoke()
            Assert-False $engine.HadErrors ($engine.Streams.Error | Out-String)
            $engine.Commands.Clear()
            # Only discovery/recovery/status are mocked. The compiled PSHost,
            # Clear-Host, Read-Host and actual Show-MainMenu remain real.
            [void]$engine.AddScript(@'
function Get-SpotifyContext { return [pscustomobject]@{} }
function Resolve-GuidedRecovery { param($Context) }
function Get-ManagerStatus { param($Context) return $null }
function Show-ManagerStatus { param($Status) }
Show-MainMenu
'@)
            [void]$engine.Invoke()
            Assert-False $engine.HadErrors ($engine.Streams.Error | Out-String)
            Assert-Match $outputWriter.ToString() 'Guided Spotify update and Spicetify repair'
            Assert-Match $outputWriter.ToString() 'Select an action'
        }
        finally {
            [Console]::SetIn($oldIn); [Console]::SetOut($oldOut)
            $engine.Dispose(); $runspace.Dispose(); $inputReader.Dispose(); $outputWriter.Dispose()
        }
    }

    Invoke-Test 'generated CLI needs no extracted wrapper and supports special-character directories' {
        $before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'SpicetifySpotifyManager-cli-*' | Select-Object -ExpandProperty FullName)
        $root = New-TestRoot
        $directory = Join-Path $root ('Spaces & Percent% ! ' + [char]0x00fc)
        [void][IO.Directory]::CreateDirectory($directory)
        $copy = Join-Path $directory 'Manager.exe'
        Copy-Item -LiteralPath $releasePath -Destination $copy
        $output = & $copy --version 2>&1 | Out-String
        Assert-Equal 0 $LASTEXITCODE
        Assert-Match $output '1\.2\.0'
        $oldTmp = $env:TMP
        try {
            $env:TMP = $directory
            $output = & $copy --version 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match $output '1\.2\.0'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $directory -Directory -Filter 'SpicetifySpotifyManager-cli-*').Count
        }
        finally { $env:TMP = $oldTmp }
        foreach ($path in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'SpicetifySpotifyManager-cli-*' | Select-Object -ExpandProperty FullName)) {
            Assert-True ($path -in $before) 'The CLI left a private wrapper behind.'
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
