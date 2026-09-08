[CmdletBinding()]
param(
    [switch]$NoMain,
    [ValidateSet('', 'Menu', 'Help', 'Version', 'Status', 'Invalid')]
    [string]$CliAction = '',
    [AllowEmptyCollection()][AllowEmptyString()]
    [string[]]$NativeArguments = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:ManagerName = 'Spicetify Spotify Manager'
$script:ManagerVersion = '__SPICETIFY_MANAGER_VERSION__'
$script:OfficialInstallerUrl = 'https://raw.githubusercontent.com/spicetify/cli/main/install.ps1'
$script:ElevatedAclHelperTemplateBase64 = '__SPICETIFY_MANAGER_ELEVATED_HELPER_BASE64__'
$script:DirectoryAclSourceBase64 = '__SPICETIFY_MANAGER_DIRECTORY_ACL_BASE64__'
$script:TestHooks = @{}
$script:PermitAclElevation = $false
$script:AclElevationAction = ''
$script:ReadOnlyMode = $false

function Set-ManagerTestHooks {
    [CmdletBinding()]
    param([hashtable]$Hooks = @{})
    $script:TestHooks = $Hooks
}

function Invoke-ManagerHook {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [object[]]$Arguments = @()
    )
    if ($script:TestHooks.ContainsKey($Name)) {
        return & $script:TestHooks[$Name] @Arguments
    }
    throw "Test hook '$Name' is not configured."
}

function Write-ManagerMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Detail')]
        [string]$Kind = 'Info'
    )
    $colour = switch ($Kind) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        'Detail' { 'DarkGray' }
        default { 'Gray' }
    }
    Write-Host $Message -ForegroundColor $colour
}

function Get-ManagerDataDirectory {
    if ($script:TestHooks.ContainsKey('DataDirectory')) {
        return [string](Invoke-ManagerHook 'DataDirectory')
    }
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'Windows did not provide a Local AppData directory.'
    }
    return Join-Path $localAppData 'SpicetifySpotifyManager'
}

function Initialize-ManagerDataDirectory {
    $directory = Get-ManagerDataDirectory
    Assert-SafeManagerDataDirectory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Assert-SafeManagerDataDirectory
    return $directory
}

function Assert-SafeManagerDataDirectory {
    $directory = Get-ManagerDataDirectory
    Assert-NoReparsePath $directory
    if (-not (Test-Path -LiteralPath $directory)) { return }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'Manager state path is not a directory.' }
    $acl = Get-Acl -LiteralPath $directory
    $sid = Get-CurrentUserSid
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid) { throw 'Manager state directory has an unexpected owner.' }
    $writeRights = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writeRights) -ne 0 -and
            $rule.IdentityReference.Value -notin @($sid, 'S-1-5-18', 'S-1-5-32-544', 'S-1-3-0')) {
            throw 'Manager state directory grants write access to an unexpected account.'
        }
    }
}

function Get-ManagerStatePath {
    param([ValidateSet('Update', 'Guided')][string]$Kind)
    Assert-SafeManagerDataDirectory
    $fileName = if ($Kind -eq 'Update') { 'update-state.json' } else { 'guided-state.json' }
    return Join-Path (Get-ManagerDataDirectory) $fileName
}

function Write-ManagerLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    if ($script:ReadOnlyMode) { return }
    try {
        $directory = Initialize-ManagerDataDirectory
        Assert-NoReparsePath (Join-Path $directory 'manager.log')
        $line = '{0:u} [{1}] {2}' -f (Get-Date), $Level, ($Message -replace "[\r\n]+", ' ')
        Add-Content -LiteralPath (Join-Path $directory 'manager.log') -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never hide the operation's real result.
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-NoReparsePath $Path
    if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "State path is not a file: $Path" }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $Path -Force).Length -gt 1048576) { throw "State file is unexpectedly large: $Path" }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "State file is not valid JSON: $Path. $($_.Exception.Message)"
    }
}

function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $directory = Split-Path -Parent $Path
    Assert-NoReparsePath $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString('N'))
    try {
        $json = $Value | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-ManagerStateFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-NoReparsePath $Path
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Protect-ManagerTemporaryDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = Normalize-WindowsPath $Path
    $temporaryRoot = Normalize-WindowsPath ([IO.Path]::GetTempPath())
    if (-not (Test-WindowsPathEqual (Split-Path -Parent $resolved) $temporaryRoot) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^SpicetifySpotifyManager(?:-install|-cli)?-[0-9a-f]{32}$') {
        throw "Refusing to protect an unexpected temporary directory: '$resolved'."
    }
    $item = Get-Item -LiteralPath $resolved -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The manager temporary path is not a normal directory: '$resolved'."
    }
    $sid = New-Object Security.Principal.SecurityIdentifier((Get-CurrentUserSid))
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $rights, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $resolved -AclObject $acl
    $verified = Get-Acl -LiteralPath $resolved
    $expectedDacl = Get-ComparableAccessSddl $acl
    $actualDacl = Get-ComparableAccessSddl $verified
    $actualOwner = $verified.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if (-not $verified.AreAccessRulesProtected -or $actualOwner -ne $sid.Value -or $actualDacl -ne $expectedDacl) {
        throw "The manager could not protect its temporary directory: '$resolved'."
    }
    return $resolved
}

function Remove-ManagerTemporaryDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolved = Normalize-WindowsPath $Path
    $temporaryRoot = Normalize-WindowsPath ([IO.Path]::GetTempPath())
    $name = [IO.Path]::GetFileName($resolved)
    if (-not (Test-WindowsPathEqual (Split-Path -Parent $resolved) $temporaryRoot) -or $name -notmatch '^SpicetifySpotifyManager(?:-install|-cli)?-[0-9a-f]{32}$') {
        throw "Refusing to remove an unexpected temporary directory: '$resolved'."
    }
    $item = Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        [IO.Directory]::Delete($resolved)
        return
    }
    if (-not $item.PSIsContainer) { throw "Refusing to remove a temporary path that is not a directory: '$resolved'." }
    function Remove-TemporaryChild {
        param([string]$Child)
        if (-not (Test-WindowsPathWithin $Child $resolved)) { throw 'Temporary cleanup escaped its validated directory.' }
        $entry = Get-Item -LiteralPath $Child -Force
        if ($entry.PSIsContainer) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                foreach ($nested in @(Get-ChildItem -LiteralPath $Child -Force)) { Remove-TemporaryChild $nested.FullName }
            }
            [IO.Directory]::Delete($Child)
        }
        else { [IO.File]::Delete($Child) }
    }
    try { Remove-TemporaryChild $resolved }
    catch { Write-Warning "Temporary cleanup could not finish for '$resolved': $($_.Exception.Message)" }
}

function Normalize-WindowsPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ([string]::IsNullOrWhiteSpace($expanded)) { throw 'A path cannot be empty.' }
    $fullPath = [IO.Path]::GetFullPath($expanded)
    $root = [IO.Path]::GetPathRoot($fullPath)
    while ($fullPath.Length -gt $root.Length -and ($fullPath.EndsWith('\') -or $fullPath.EndsWith('/'))) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath.Replace('/', '\')
}

function Get-PublicCliAction {
    param([AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
    if ($Arguments.Count -eq 0) { return 'Menu' }
    if ($Arguments.Count -eq 1) {
        switch -CaseSensitive ($Arguments[0]) {
            '--help' { return 'Help' }
            '-h' { return 'Help' }
            '--version' { return 'Version' }
            '-V' { return 'Version' }
            '--status' { return 'Status' }
        }
    }
    return 'Invalid'
}

function Test-WindowsPathEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    return [string]::Equals((Normalize-WindowsPath $Left), (Normalize-WindowsPath $Right), [StringComparison]::OrdinalIgnoreCase)
}

function Test-WindowsPathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $candidate = Normalize-WindowsPath $Path
    $container = Normalize-WindowsPath $Parent
    if (Test-WindowsPathEqual $candidate $container) { return $true }
    return $candidate.StartsWith($container.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-UniqueWindowsPaths {
    param([string[]]$Paths)
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $result = New-Object 'Collections.Generic.List[string]'
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $normalized = Normalize-WindowsPath $path
        if ($seen.Add($normalized)) { $result.Add($normalized) }
    }
    return @($result)
}

function Test-IsAdministrator {
    if ($script:TestHooks.ContainsKey('IsAdministrator')) {
        return [bool](Invoke-ManagerHook 'IsAdministrator')
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentUserSid {
    if ($script:TestHooks.ContainsKey('CurrentUserSid')) {
        return [string](Invoke-ManagerHook 'CurrentUserSid')
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity.User) { throw 'Windows did not provide the current user SID.' }
    return $identity.User.Value
}

function Get-SpotifyContext {
    if ($script:TestHooks.ContainsKey('SpotifyContext')) {
        return Invoke-ManagerHook 'SpotifyContext'
    }
    $roaming = [Environment]::GetFolderPath('ApplicationData')
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($roaming) -or [string]::IsNullOrWhiteSpace($local)) {
        throw 'Windows did not provide the required AppData directories.'
    }
    $installDirectory = Normalize-WindowsPath (Join-Path $roaming 'Spotify')
    $localDirectory = Normalize-WindowsPath (Join-Path $local 'Spotify')
    return [pscustomobject]@{
        InstallDirectory = $installDirectory
        Executable = Normalize-WindowsPath (Join-Path $installDirectory 'Spotify.exe')
        AppsDirectory = Normalize-WindowsPath (Join-Path $installDirectory 'Apps')
        Preferences = Normalize-WindowsPath (Join-Path $installDirectory 'prefs')
        LocalDirectory = $localDirectory
        UpdateDirectory = Normalize-WindowsPath (Join-Path $localDirectory 'Update')
    }
}

function Test-StandaloneSpotifyInstalled {
    param([Parameter(Mandatory = $true)]$Context)
    if ($script:TestHooks.ContainsKey('StandaloneInstalled')) {
        return [bool](Invoke-ManagerHook 'StandaloneInstalled' @($Context))
    }
    return Test-Path -LiteralPath $Context.Executable -PathType Leaf
}

function Test-MicrosoftStoreSpotifyInstalled {
    if ($script:TestHooks.ContainsKey('StoreInstalled')) {
        return [bool](Invoke-ManagerHook 'StoreInstalled')
    }
    try {
        return $null -ne (Get-AppxPackage -Name 'SpotifyAB.SpotifyMusic' -ErrorAction Stop | Select-Object -First 1)
    }
    catch {
        Write-ManagerLog "Microsoft Store detection failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Assert-StandaloneSpotifySupported {
    param([Parameter(Mandatory = $true)]$Context)
    if (-not (Test-StandaloneSpotifyInstalled $Context)) {
        if (Test-MicrosoftStoreSpotifyInstalled) {
            throw 'Only the Microsoft Store Spotify app was found. This manager supports the standalone client downloaded from spotify.com and will not modify the Store app.'
        }
        throw "The standalone Spotify client was not found at '$($Context.Executable)'. Install Spotify from spotify.com first."
    }
}

function Assert-SafeUpdateDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [switch]$AllowMissing
    )
    $expectedLocal = Normalize-WindowsPath $Context.LocalDirectory
    $expectedUpdate = Normalize-WindowsPath (Join-Path $expectedLocal 'Update')
    $actualUpdate = Normalize-WindowsPath $Context.UpdateDirectory
    if (-not (Test-WindowsPathEqual $actualUpdate $expectedUpdate)) {
        throw "Safety check refused an unexpected update path: '$actualUpdate'."
    }
    if (-not (Test-WindowsPathEqual (Split-Path -Parent $actualUpdate) $expectedLocal)) {
        throw "Safety check refused an update path outside '$expectedLocal'."
    }
    if (-not (Test-WindowsPathWithin $actualUpdate $expectedLocal)) {
        throw 'Safety check refused a path outside the intended Spotify local directory.'
    }
    Assert-NoReparsePath $actualUpdate
    if (Test-Path -LiteralPath $actualUpdate) {
        $item = Get-Item -LiteralPath $actualUpdate -Force
        if (-not $item.PSIsContainer) { throw "The Spotify Update path exists but is not a directory: '$actualUpdate'." }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Safety check refused the Spotify Update directory because it is a reparse point or junction: '$actualUpdate'."
        }
        $resolved = Normalize-WindowsPath $item.FullName
        if (-not (Test-WindowsPathEqual $resolved $actualUpdate)) {
            throw "Safety check refused an Update directory that resolves elsewhere: '$resolved'."
        }
    }
    elseif (-not $AllowMissing) {
        throw "The Spotify Update directory does not exist: '$actualUpdate'."
    }
    return $actualUpdate
}

function Assert-NoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = Normalize-WindowsPath $Path
    while (-not [string]::IsNullOrEmpty($current)) {
        $attributes = 0
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
        # Permission and other I/O failures are not evidence that a path is safe.
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Safety check refused a reparse point or junction in '$Path': '$current'."
        }
        $current = Split-Path -Parent $current
    }
}

function Get-DirectorySecurity {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($script:TestHooks.ContainsKey('GetDirectorySecurity')) {
        return Invoke-ManagerHook 'GetDirectorySecurity' @($Path)
    }
    return Get-Acl -LiteralPath $Path
}

function Initialize-DirectoryAclApi {
    if (-not (Get-Command Open-BoundDirectoryAclSession -ErrorAction SilentlyContinue)) {
        $source = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:DirectoryAclSourceBase64))
        . ([scriptblock]::Create($source))
    }
}

function Set-DirectorySecurity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Acl
    )
    try {
        if ($script:TestHooks.ContainsKey('SetDirectorySecurity')) {
            Invoke-ManagerHook 'SetDirectorySecurity' @($Path, $Acl) | Out-Null
            return
        }
        $context = Get-SpotifyContext
        $safePath = Assert-SafeUpdateDirectory -Context $context
        if (-not (Test-WindowsPathEqual $Path $safePath)) { throw 'The ACL write target differs from the validated Spotify Update path.' }
        Initialize-DirectoryAclApi
        $session = Open-BoundDirectoryAclSession $safePath
        try {
            $session.Write($Acl)
            $verified = $session.Read()
            if ((Get-ComparableAccessSddl $verified) -ne (Get-ComparableAccessSddl $Acl)) {
                throw 'The bound Spotify Update ACL write could not be verified.'
            }
        }
        finally { $session.Dispose() }
    }
    catch {
        if ($script:PermitAclElevation -and -not (Test-IsAdministrator) -and (Test-PermissionFailure $_)) {
            Write-ManagerMessage 'Windows denied this exact ACL write. Administrator permission is required only for its integrity-checked helper retry.' 'Warning'
            Invoke-ElevatedAclSet -Path $Path -Acl $Acl -Action $script:AclElevationAction
            return
        }
        throw
    }
}

function Get-AclSddl {
    param([Parameter(Mandatory = $true)]$Acl)
    return $Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
}

function Get-ComparableAccessSddl {
    param([Parameter(Mandatory = $true)]$Acl)
    $descriptor = New-Object Security.AccessControl.RawSecurityDescriptor($Acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access))
    # Windows may mark a persisted DACL auto-inherited without changing any ACE.
    # Keep protection, ACE order, rights and inheritance flags in the comparison.
    $descriptor.SetFlags($descriptor.ControlFlags -band (-bnot [Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited))
    return $descriptor.GetSddlForm([Security.AccessControl.AccessControlSections]::Access)
}

function Get-AclFingerprint {
    param([Parameter(Mandatory = $true)]$Acl)
    $accessRules = foreach ($rule in @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
        '{0}|{1}|{2}|{3}|{4}|{5}' -f
            $rule.IdentityReference.Value,
            [int]$rule.AccessControlType,
            [int64]$rule.FileSystemRights,
            [int]$rule.InheritanceFlags,
            [int]$rule.PropagationFlags,
            [bool]$rule.IsInherited
    }
    $auditRules = try {
        foreach ($rule in @($Acl.GetAuditRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
            '{0}|{1}|{2}|{3}|{4}|{5}' -f
                $rule.IdentityReference.Value,
                [int]$rule.AuditFlags,
                [int64]$rule.FileSystemRights,
                [int]$rule.InheritanceFlags,
                [int]$rule.PropagationFlags,
                [bool]$rule.IsInherited
        }
    }
    catch { @() }
    $fingerprint = [ordered]@{
        Owner = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        Group = $Acl.GetGroup([Security.Principal.SecurityIdentifier]).Value
        AccessProtected = [bool]$Acl.AreAccessRulesProtected
        AuditProtected = [bool]$Acl.AreAuditRulesProtected
        AccessRules = @($accessRules | Sort-Object)
        AuditRules = @($auditRules | Sort-Object)
    }
    return $fingerprint | ConvertTo-Json -Compress -Depth 4
}

function Get-SavedStateValue {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) { return '' }
    return [string]$property.Value
}

function Test-AclMatchesSavedState {
    param(
        [Parameter(Mandatory = $true)]$Acl,
        [Parameter(Mandatory = $true)]$State,
        [ValidateSet('Original', 'Blocked')][string]$Kind
    )
    $fingerprint = Get-SavedStateValue -State $State -Name ($Kind + 'Fingerprint')
    if (-not [string]::IsNullOrWhiteSpace($fingerprint)) {
        return (Get-AclFingerprint $Acl) -eq $fingerprint
    }
    $sddl = Get-SavedStateValue -State $State -Name ($Kind + 'Sddl')
    return -not [string]::IsNullOrWhiteSpace($sddl) -and (Get-AclSddl $Acl) -eq $sddl
}

function New-ManagerAccessRule {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][Security.AccessControl.FileSystemRights]$Rights,
        [Parameter(Mandatory = $true)][Security.AccessControl.AccessControlType]$Type
    )
    $identity = New-Object Security.Principal.SecurityIdentifier($Sid)
    return New-Object Security.AccessControl.FileSystemAccessRule(
        $identity,
        $Rights,
        ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
        [Security.AccessControl.PropagationFlags]::None,
        $Type
    )
}

function Get-ManagerAccessRuleDefinitions {
    param([Parameter(Mandatory = $true)][string]$CurrentUserSid)
    return @(
        [pscustomobject]@{ Sid = 'S-1-5-18'; Rights = [Security.AccessControl.FileSystemRights]::FullControl; Type = [Security.AccessControl.AccessControlType]::Allow },
        [pscustomobject]@{ Sid = 'S-1-5-32-544'; Rights = [Security.AccessControl.FileSystemRights]::FullControl; Type = [Security.AccessControl.AccessControlType]::Allow },
        [pscustomobject]@{ Sid = $CurrentUserSid; Rights = [Security.AccessControl.FileSystemRights]::ReadAndExecute; Type = [Security.AccessControl.AccessControlType]::Allow },
        [pscustomobject]@{ Sid = $CurrentUserSid; Rights = ([Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete); Type = [Security.AccessControl.AccessControlType]::Deny }
    )
}

function Test-AccessRuleMatchesDefinition {
    param(
        [Parameter(Mandatory = $true)]$Rule,
        [Parameter(Mandatory = $true)]$Definition
    )
    if ($Rule.IsInherited) { return $false }
    $sid = $Rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    $expectedInheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    return $sid -eq $Definition.Sid -and
        $Rule.AccessControlType -eq $Definition.Type -and
        (($Rule.FileSystemRights -band $Definition.Rights) -eq $Definition.Rights) -and
        (($Rule.InheritanceFlags -band $expectedInheritance) -eq $expectedInheritance)
}

function Test-ManagerAclRulesPresent {
    param(
        [Parameter(Mandatory = $true)]$Acl,
        [Parameter(Mandatory = $true)][string]$CurrentUserSid
    )
    $rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    foreach ($definition in (Get-ManagerAccessRuleDefinitions $CurrentUserSid)) {
        $found = $false
        foreach ($rule in $rules) {
            if (Test-AccessRuleMatchesDefinition $rule $definition) { $found = $true; break }
        }
        if (-not $found) { return $false }
    }
    return $true
}

function Add-ManagerAclRules {
    param(
        [Parameter(Mandatory = $true)]$Acl,
        [Parameter(Mandatory = $true)][string]$CurrentUserSid
    )
    foreach ($definition in (Get-ManagerAccessRuleDefinitions $CurrentUserSid)) {
        $rule = New-ManagerAccessRule -Sid $definition.Sid -Rights $definition.Rights -Type $definition.Type
        [void]$Acl.AddAccessRule($rule)
    }
    return $Acl
}

function Test-UpdateFolderWritable {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$ExpectedWritable
    )
    if ($script:TestHooks.ContainsKey('WriteProbe')) {
        $writable = [bool](Invoke-ManagerHook 'WriteProbe' @($Path))
    }
    else {
        $probe = Join-Path $Path ('.spicetify-manager-probe-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        $writable = $false
        try {
            [IO.File]::WriteAllText($probe, 'probe')
            $writable = $true
        }
        catch [UnauthorizedAccessException] {
            $writable = $false
        }
        catch [Security.SecurityException] {
            $writable = $false
        }
        finally {
            if (Test-Path -LiteralPath $probe) {
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($writable -ne $ExpectedWritable) {
        $expected = if ($ExpectedWritable) { 'writable' } else { 'blocked for writes' }
        throw "Update-folder verification failed. '$Path' was expected to be $expected."
    }
    return $true
}

function Test-LegacyBlockedAcl {
    param(
        [Parameter(Mandatory = $true)]$Acl,
        [Parameter(Mandatory = $true)][string]$CurrentUserSid
    )
    if (-not $Acl.AreAccessRulesProtected) { return $false }
    $knownSids = @($CurrentUserSid, 'S-1-5-18', 'S-1-5-32-544')
    $rules = @($Acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -lt 4) { return $false }
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        if ($knownSids -notcontains $sid) { return $false }
    }
    return Test-ManagerAclRulesPresent $Acl $CurrentUserSid
}

function Restore-LegacyBlockedAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Acl,
        [Parameter(Mandatory = $true)][string]$CurrentUserSid
    )
    if (-not (Test-LegacyBlockedAcl $Acl $CurrentUserSid)) {
        throw 'The existing ACL does not match the known legacy manager rules, so it will not be changed without a saved original ACL.'
    }
    $definitions = Get-ManagerAccessRuleDefinitions $CurrentUserSid
    $explicitRules = @($Acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    foreach ($rule in $explicitRules) {
        foreach ($definition in $definitions) {
            if (Test-AccessRuleMatchesDefinition $rule $definition) {
                [void]$Acl.RemoveAccessRuleSpecific($rule)
                break
            }
        }
    }
    $Acl.SetAccessRuleProtection($false, $true)
    Set-DirectorySecurity $Path $Acl
    $verified = Get-DirectorySecurity $Path
    if ($verified.AreAccessRulesProtected -or (Test-ManagerAclRulesPresent $verified $CurrentUserSid)) {
        throw 'Legacy ACL restoration could not be verified.'
    }
    Test-UpdateFolderWritable -Path $Path -ExpectedWritable $true | Out-Null
}

function New-AclFromSddl {
    param([Parameter(Mandatory = $true)][string]$Sddl)
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm($Sddl, [Security.AccessControl.AccessControlSections]::All)
    return $acl
}

function Get-UpdateStateRecord {
    return Read-JsonFile (Get-ManagerStatePath 'Update')
}

function Assert-StateMatchesCurrentContext {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$CurrentUserSid
    )
    if ($null -eq $State.TargetPath -or -not (Test-WindowsPathEqual ([string]$State.TargetPath) $Context.UpdateDirectory)) {
        throw 'The saved ACL state belongs to a different path. No permissions were changed.'
    }
    if ([string]$State.UserSid -ne $CurrentUserSid) {
        throw 'The saved ACL state belongs to a different Windows user. No permissions were changed.'
    }
}

function Get-UpdateAccessStatus {
    param([Parameter(Mandatory = $true)]$Context)
    $sid = Get-CurrentUserSid
    $path = Assert-SafeUpdateDirectory -Context $Context -AllowMissing
    $state = Get-UpdateStateRecord
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        if ($null -ne $state) { return [pscustomobject]@{ State = 'Recovery required'; Detail = 'Saved ACL state exists but the Update directory is missing.' } }
        return [pscustomobject]@{ State = 'Allowed'; Detail = 'Update directory is not present yet.' }
    }
    $acl = Get-DirectorySecurity $path
    if ($null -ne $state) {
        try { Assert-StateMatchesCurrentContext $state $Context $sid }
        catch { return [pscustomobject]@{ State = 'Recovery required'; Detail = $_.Exception.Message } }
        if ([string]$state.Phase -eq 'Blocked' -and (Test-AclMatchesSavedState -Acl $acl -State $state -Kind Blocked) -and (Test-ManagerAclRulesPresent $acl $sid)) {
            return [pscustomobject]@{ State = 'Blocked'; Detail = 'Managed ACL is active.' }
        }
        if ([string]$state.Phase -eq 'Applying' -and (Test-ManagerAclRulesPresent $acl $sid)) {
            return [pscustomobject]@{ State = 'Recovery required'; Detail = 'Blocking was interrupted before the final state was recorded.' }
        }
        if (Test-AclMatchesSavedState -Acl $acl -State $state -Kind Original) {
            return [pscustomobject]@{ State = 'Recovery required'; Detail = 'Original ACL is present but stale manager state remains.' }
        }
        return [pscustomobject]@{ State = 'Recovery required'; Detail = 'The Update ACL changed after it was managed.' }
    }
    if (Test-LegacyBlockedAcl $acl $sid) {
        return [pscustomobject]@{ State = 'Blocked (legacy)'; Detail = 'ACL was created by an earlier version and can be safely restored.' }
    }
    if (Test-ManagerAclRulesPresent $acl $sid) {
        return [pscustomobject]@{ State = 'Unknown blocked ACL'; Detail = 'Manager-like rules exist without a saved original ACL.' }
    }
    return [pscustomobject]@{ State = 'Allowed'; Detail = 'No managed blocking ACL is active.' }
}

function Restore-SavedOriginalAcl {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State,
        [switch]$Force
    )
    $sid = Get-CurrentUserSid
    Assert-StateMatchesCurrentContext $State $Context $sid
    $path = Assert-SafeUpdateDirectory -Context $Context
    $currentAcl = Get-DirectorySecurity $path
    $knownManagedState = (Test-AclMatchesSavedState -Acl $currentAcl -State $State -Kind Blocked) -or
        (Test-AclMatchesSavedState -Acl $currentAcl -State $State -Kind Original)
    if (-not $Force -and -not $knownManagedState) {
        throw 'The Update ACL changed after blocking. Automatic restore stopped to avoid overwriting unrelated permission changes. Use the recovery option to restore the saved original ACL deliberately.'
    }
    $originalAcl = New-AclFromSddl ([string]$State.OriginalSddl)
    Set-DirectorySecurity $path $originalAcl
    $verifiedAcl = Get-DirectorySecurity $path
    if (-not (Test-AclMatchesSavedState -Acl $verifiedAcl -State $State -Kind Original)) {
        throw 'The original Update ACL was applied but semantic restoration could not be verified.'
    }
    Test-UpdateFolderWritable -Path $path -ExpectedWritable $true | Out-Null
    Remove-ManagerStateFile (Get-ManagerStatePath 'Update')
}

function Invoke-BlockUpdatesCore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)
    Assert-StandaloneSpotifySupported $Context
    $path = Assert-SafeUpdateDirectory -Context $Context -AllowMissing
    $sid = Get-CurrentUserSid
    $existingState = Get-UpdateStateRecord
    if ($null -ne $existingState) {
        Assert-StateMatchesCurrentContext $existingState $Context $sid
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            Remove-ManagerStateFile (Get-ManagerStatePath 'Update')
            $existingState = $null
        }
    }
    if ($null -ne $existingState) {
        $status = Get-UpdateAccessStatus $Context
        if ($status.State -eq 'Blocked') {
            Test-UpdateFolderWritable -Path $path -ExpectedWritable $false | Out-Null
            return [pscustomobject]@{ Changed = $false; Message = 'Spotify updates are already blocked and the ACL was verified.' }
        }
        if (Test-AclMatchesSavedState -Acl (Get-DirectorySecurity $path) -State $existingState -Kind Original) {
            Remove-ManagerStateFile (Get-ManagerStatePath 'Update')
        }
        else {
            throw "Saved ACL recovery is required before blocking again. $($status.Detail)"
        }
    }
    if (-not (Test-Path -LiteralPath $Context.LocalDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $Context.LocalDirectory -Force | Out-Null
    }
    $createdDirectory = $false
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        New-Item -ItemType Directory -Path $path | Out-Null
        $createdDirectory = $true
    }
    $path = Assert-SafeUpdateDirectory -Context $Context
    $currentAcl = Get-DirectorySecurity $path
    if (Test-LegacyBlockedAcl $currentAcl $sid) {
        Test-UpdateFolderWritable -Path $path -ExpectedWritable $false | Out-Null
        return [pscustomobject]@{ Changed = $false; Message = 'Spotify updates are already blocked by the earlier manager ACL.' }
    }
    if (Test-ManagerAclRulesPresent $currentAcl $sid) {
        throw 'Manager-like blocking rules exist without a saved original ACL. Restore or inspect those permissions before continuing.'
    }
    $originalSddl = Get-AclSddl $currentAcl
    $blockedAcl = New-AclFromSddl $originalSddl
    $blockedAcl = Add-ManagerAclRules -Acl $blockedAcl -CurrentUserSid $sid
    $state = [ordered]@{
        SchemaVersion = 1
        Phase = 'Applying'
        TargetPath = $path
        UserSid = $sid
        OriginalSddl = $originalSddl
        OriginalFingerprint = Get-AclFingerprint $currentAcl
        BlockedSddl = Get-AclSddl $blockedAcl
        BlockedFingerprint = Get-AclFingerprint $blockedAcl
        CreatedDirectory = $createdDirectory
        UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-JsonFileAtomic -Path (Get-ManagerStatePath 'Update') -Value $state
    try {
        Set-DirectorySecurity $path $blockedAcl
        $verifiedAcl = Get-DirectorySecurity $path
        if (-not (Test-ManagerAclRulesPresent $verifiedAcl $sid)) {
            throw 'The managed blocking rules were not present after applying the ACL.'
        }
        Test-UpdateFolderWritable -Path $path -ExpectedWritable $false | Out-Null
        $state.Phase = 'Blocked'
        $state.BlockedSddl = Get-AclSddl $verifiedAcl
        $state.UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Write-JsonFileAtomic -Path (Get-ManagerStatePath 'Update') -Value $state
        return [pscustomobject]@{ Changed = $true; Message = 'Spotify updates are now blocked and the resulting ACL was verified.' }
    }
    catch {
        $blockError = $_
        try {
            Set-DirectorySecurity $path (New-AclFromSddl $originalSddl)
            $restored = Get-DirectorySecurity $path
            if ((Get-AclFingerprint $restored) -ne [string]$state.OriginalFingerprint) { throw 'Semantic ACL recovery verification failed.' }
            Remove-ManagerStateFile (Get-ManagerStatePath 'Update')
            Write-ManagerLog "Blocking failed and the original ACL was restored: $($blockError.Exception.Message)" 'ERROR'
            throw "Could not block Spotify updates. The original permissions were restored. $($blockError.Exception.Message)"
        }
        catch {
            if ($_.Exception.Message -like 'Could not block Spotify updates.*') { throw }
            $state.Phase = 'RecoveryRequired'
            $state.UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Write-JsonFileAtomic -Path (Get-ManagerStatePath 'Update') -Value $state
            Write-ManagerLog "Blocking and automatic recovery both failed. Block error: $($blockError.Exception.Message). Recovery error: $($_.Exception.Message)" 'ERROR'
            throw "Could not block Spotify updates, and automatic ACL recovery also failed. Use the recovery option. Blocking error: $($blockError.Exception.Message). Recovery error: $($_.Exception.Message)"
        }
    }
}

function Invoke-AllowUpdatesCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [switch]$ForceRecovery
    )
    Assert-StandaloneSpotifySupported $Context
    $path = Assert-SafeUpdateDirectory -Context $Context -AllowMissing
    $state = Get-UpdateStateRecord
    if ($null -ne $state) {
        $sid = Get-CurrentUserSid
        Assert-StateMatchesCurrentContext $state $Context $sid
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            Remove-ManagerStateFile (Get-ManagerStatePath 'Update')
            return [pscustomobject]@{ Changed = $true; Message = 'The Update directory is absent, so stale managed ACL state was cleared and Spotify updates are allowed.' }
        }
        Restore-SavedOriginalAcl -Context $Context -State $state -Force:$ForceRecovery
        return [pscustomobject]@{ Changed = $true; Message = 'Spotify update access was restored to its exact saved ACL and verified.' }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{ Changed = $false; Message = 'Spotify updates are already allowed. The Update directory does not exist yet.' }
    }
    $sid = Get-CurrentUserSid
    $acl = Get-DirectorySecurity $path
    if (Test-LegacyBlockedAcl $acl $sid) {
        Restore-LegacyBlockedAcl -Path $path -Acl $acl -CurrentUserSid $sid
        return [pscustomobject]@{ Changed = $true; Message = 'The earlier manager ACL was removed and inherited access was restored.' }
    }
    if (Test-ManagerAclRulesPresent $acl $sid) {
        throw 'Manager-like rules exist without a saved original ACL. They were not removed because their origin cannot be verified.'
    }
    Test-UpdateFolderWritable -Path $path -ExpectedWritable $true | Out-Null
    return [pscustomobject]@{ Changed = $false; Message = 'Spotify updates are already allowed and write access was verified.' }
}

function Test-PermissionFailure {
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    if ($null -eq $ErrorRecord) { return $false }
    $permissionCategories = @(
        [Management.Automation.ErrorCategory]::PermissionDenied,
        [Management.Automation.ErrorCategory]::SecurityError
    )
    if ($null -ne $ErrorRecord.CategoryInfo -and $permissionCategories -contains $ErrorRecord.CategoryInfo.Category) {
        return $true
    }
    $fullyQualifiedId = [string]$ErrorRecord.FullyQualifiedErrorId
    if (-not [string]::IsNullOrWhiteSpace($fullyQualifiedId)) {
        $identifier = $fullyQualifiedId.Split(',')[0]
        if ($identifier -in @('UnauthorizedAccess', 'UnauthorizedAccessException', 'System.UnauthorizedAccessException', 'SecurityException', 'System.Security.SecurityException', 'PermissionDenied', 'SecurityError', 'SetAcl_AccessError')) {
            return $true
        }
    }
    if ($null -ne $ErrorRecord.CategoryInfo -and [string]$ErrorRecord.CategoryInfo.Reason -in @('UnauthorizedAccessException', 'SecurityException')) {
        return $true
    }
    $exception = $ErrorRecord.Exception
    $depth = 0
    while ($null -ne $exception -and $depth -lt 16) {
        if ($exception -is [UnauthorizedAccessException] -or $exception -is [Security.SecurityException]) { return $true }
        if ($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -in @(5, 1300, 1314)) { return $true }
        $hresultBytes = [BitConverter]::GetBytes([int]$exception.HResult)
        $hresult = [BitConverter]::ToUInt32($hresultBytes, 0)
        if ($hresult -in @([uint32]2147942405, [uint32]2147943700, [uint32]2147943714)) { return $true }
        $exception = $exception.InnerException
        $depth++
    }
    return $false
}

function ConvertTo-PowerShellSingleQuotedContent {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return $Value.Replace("'", "''")
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-ElevatedAclHelperTemplate {
    $bytes = [Convert]::FromBase64String($script:ElevatedAclHelperTemplateBase64)
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    return $utf8.GetString($bytes)
}

function New-ElevatedAclHelperSource {
    param(
        [ValidateSet('Block', 'Allow', 'AllowForce')][string]$Action,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)]$Acl,
        [Parameter(Mandatory = $true)][string]$OperationId
    )
    $source = Get-ElevatedAclHelperTemplate
    $replacements = [ordered]@{
        '__SSM_ELEVATED_ACTION__' = $Action
        '__SSM_ELEVATED_RESULT_PATH__' = $ResultPath
        '__SSM_ELEVATED_TARGET_PATH__' = $TargetPath
        '__SSM_ELEVATED_TARGET_SDDL__' = Get-AclSddl $Acl
        '__SSM_ELEVATED_OPERATION_ID__' = $OperationId
    }
    foreach ($entry in $replacements.GetEnumerator()) {
        if ([regex]::Matches($source, [regex]::Escape($entry.Key)).Count -ne 1) {
            throw "The elevated ACL helper template marker is invalid: $($entry.Key)."
        }
        $source = $source.Replace($entry.Key, (ConvertTo-PowerShellSingleQuotedContent ([string]$entry.Value)))
    }
    if ($source -match '__SSM_ELEVATED_[A-Z_]+__') { throw 'An elevated ACL helper marker remains unresolved.' }
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { throw "The generated elevated ACL helper does not parse: $($errors[0].Message)" }
    return $source
}

function New-ElevatedBootstrapSource {
    param(
        [ValidateSet('Block', 'Allow', 'AllowForce')][string]$Action,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-F]{64}$')][string]$ExpectedHash
    )
    $template = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$action = '__SSM_BOOTSTRAP_ACTION__'
$resultPath = '__SSM_BOOTSTRAP_RESULT_PATH__'
$expectedHash = '__SSM_BOOTSTRAP_HASH__'
$directory = [IO.Path]::GetFullPath((Split-Path -Parent $resultPath)).TrimEnd('\')
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if (-not [string]::Equals((Split-Path -Parent $directory), $temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'The helper directory is outside the Windows temporary directory.' }
if ([IO.Path]::GetFileName($directory) -notmatch '^SpicetifySpotifyManager-[0-9a-f]{32}$') { throw 'The helper directory name is invalid.' }
$directoryItem = Get-Item -LiteralPath $directory -Force
if (-not $directoryItem.PSIsContainer -or ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The helper directory is not a normal directory.' }
if ([IO.Path]::GetFileName($resultPath) -ne 'result.json' -or -not [string]::Equals((Split-Path -Parent ([IO.Path]::GetFullPath($resultPath))), $directory, [StringComparison]::OrdinalIgnoreCase)) { throw 'The result path is invalid.' }
if (Test-Path -LiteralPath $resultPath) { throw 'The result path already exists.' }
$helperPath = Join-Path $directory 'acl-helper.ps1'
$helperItem = Get-Item -LiteralPath $helperPath -Force
if (($helperItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $helperItem.PSIsContainer -or $helperItem.Length -lt 1024 -or $helperItem.Length -gt 131072) { throw 'The helper payload is missing, unsafe, or has an invalid size.' }
$helperBytes = [IO.File]::ReadAllBytes($helperPath)
$sha256 = [Security.Cryptography.SHA256]::Create()
try { $actualHash = ([BitConverter]::ToString($sha256.ComputeHash($helperBytes))).Replace('-', '') } finally { $sha256.Dispose() }
if (-not [string]::Equals($actualHash, $expectedHash, [StringComparison]::OrdinalIgnoreCase)) { throw 'The elevated ACL helper integrity check failed.' }
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$helperText = $utf8.GetString($helperBytes)
$helperScriptBlock = [scriptblock]::Create($helperText)
& $helperScriptBlock -Action $action -ResultPath $resultPath -HelperHash $actualHash
'@
    return $template.Replace('__SSM_BOOTSTRAP_ACTION__', (ConvertTo-PowerShellSingleQuotedContent $Action)).Replace('__SSM_BOOTSTRAP_RESULT_PATH__', (ConvertTo-PowerShellSingleQuotedContent $ResultPath)).Replace('__SSM_BOOTSTRAP_HASH__', $ExpectedHash)
}

function Start-ElevatedAclProcess {
    param(
        [Parameter(Mandatory = $true)][string]$EncodedCommand,
        [Parameter(Mandatory = $true)][string]$TemporaryRoot,
        [ValidateSet('Block', 'Allow', 'AllowForce')][string]$Action,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)]$Acl,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][string]$OperationId
    )
    if ($script:TestHooks.ContainsKey('ElevatedProcess')) {
        return Invoke-ManagerHook 'ElevatedProcess' @($EncodedCommand, $TemporaryRoot, $Action, $TargetPath, $Acl, $ExpectedHash, $OperationId)
    }
    $powerShell = Join-Path $PSHOME 'powershell.exe'
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShell
    $startInfo.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $EncodedCommand
    $startInfo.UseShellExecute = $true
    $startInfo.Verb = 'runas'
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode }
    }
    catch [ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) { throw 'Administrator permission was cancelled. No elevated ACL change was completed.' }
        throw "The elevated ACL helper could not start. $($_.Exception.Message)"
    }
}

function Read-VerifiedElevatedResult {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TemporaryRoot,
        [ValidateSet('Block', 'Allow', 'AllowForce')][string]$Action,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][string]$OperationId
    )
    $expectedPath = Normalize-WindowsPath (Join-Path $TemporaryRoot 'result.json')
    if (-not (Test-WindowsPathEqual $Path $expectedPath) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'The elevated ACL helper did not return its expected result file.'
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0 -or $item.Length -gt 32768) {
        throw 'The elevated ACL helper result file is unsafe or has an invalid size.'
    }
    $result = Read-JsonFile $Path
    foreach ($name in @('SchemaVersion', 'OperationId', 'Action', 'TargetPath', 'HelperHash', 'Success', 'Changed', 'Message')) {
        if ($null -eq $result.PSObject.Properties[$name]) { throw "The elevated ACL result is missing '$name'." }
    }
    if ([int]$result.SchemaVersion -ne 1 -or [string]$result.OperationId -ne $OperationId -or
        [string]$result.Action -ne $Action -or -not (Test-WindowsPathEqual ([string]$result.TargetPath) $TargetPath) -or
        -not [string]::Equals([string]$result.HelperHash, $ExpectedHash, [StringComparison]::OrdinalIgnoreCase) -or
        $result.Success -isnot [bool] -or $result.Changed -isnot [bool] -or
        [string]::IsNullOrWhiteSpace([string]$result.Message)) {
        throw 'The elevated ACL helper returned malformed or mismatched result data.'
    }
    return $result
}

function Invoke-ElevatedAclSet {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Acl,
        [ValidateSet('Block', 'Allow', 'AllowForce')][string]$Action
    )
    $context = Get-SpotifyContext
    Assert-StandaloneSpotifySupported $context
    $safePath = Assert-SafeUpdateDirectory -Context $context
    if (-not (Test-WindowsPathEqual $Path $safePath)) { throw 'The elevated ACL target differs from the validated Spotify Update path.' }
    $operationId = [guid]::NewGuid().ToString('N')
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('SpicetifySpotifyManager-{0}' -f [guid]::NewGuid().ToString('N'))
    $sourcePath = Join-Path $temporaryRoot 'acl-helper.ps1'
    $resultPath = Join-Path $temporaryRoot 'result.json'
    try {
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
        $temporaryRoot = Protect-ManagerTemporaryDirectory $temporaryRoot
        $helperSource = New-ElevatedAclHelperSource -Action $Action -ResultPath $resultPath -TargetPath $safePath -Acl $Acl -OperationId $operationId
        $helperBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($helperSource)
        $expectedHash = Get-Sha256Hex $helperBytes
        [IO.File]::WriteAllBytes($sourcePath, $helperBytes)
        $sourceItem = Get-Item -LiteralPath $sourcePath -Force
        if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The elevated helper payload became a reparse point.' }
        if ($script:TestHooks.ContainsKey('BeforeElevatedProcess')) {
            Invoke-ManagerHook 'BeforeElevatedProcess' @($temporaryRoot, $sourcePath, $resultPath, $expectedHash, $operationId) | Out-Null
        }
        $bootstrap = New-ElevatedBootstrapSource -Action $Action -ResultPath $resultPath -ExpectedHash $expectedHash
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
        $process = Start-ElevatedAclProcess -EncodedCommand $encoded -TemporaryRoot $temporaryRoot -Action $Action -TargetPath $safePath -Acl $Acl -ExpectedHash $expectedHash -OperationId $operationId
        $result = Read-VerifiedElevatedResult -Path $resultPath -TemporaryRoot $temporaryRoot -Action $Action -TargetPath $safePath -ExpectedHash $expectedHash -OperationId $operationId
        if ([int]$process.ExitCode -ne 0 -and [bool]$result.Success) { throw "The elevated ACL helper reported success with exit code $($process.ExitCode)." }
        if (-not [bool]$result.Success) { throw [string]$result.Message }
    }
    finally {
        Remove-ManagerTemporaryDirectory $temporaryRoot
    }
}

function Invoke-UpdateAccessAction {
    param(
        [ValidateSet('Block', 'Allow', 'AllowForce')][string]$Action,
        [Parameter(Mandatory = $true)]$Context,
        [switch]$PermitElevation
    )
    $previousPermit = $script:PermitAclElevation
    $previousAction = $script:AclElevationAction
    try {
        $script:PermitAclElevation = [bool]$PermitElevation
        $script:AclElevationAction = $Action
        if ($Action -eq 'Block') { return Invoke-BlockUpdatesCore $Context }
        return Invoke-AllowUpdatesCore $Context -ForceRecovery:($Action -eq 'AllowForce')
    }
    finally {
        $script:PermitAclElevation = $previousPermit
        $script:AclElevationAction = $previousAction
    }
}

function Get-SpotifyProcesses {
    param([Parameter(Mandatory = $true)]$Context)
    if ($script:TestHooks.ContainsKey('SpotifyProcesses')) {
        return @(Invoke-ManagerHook 'SpotifyProcesses' @($Context))
    }
    $result = @()
    foreach ($process in @(Get-Process -Name 'Spotify' -ErrorAction SilentlyContinue)) {
        try { $path = $process.Path } catch { continue }
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-WindowsPathWithin $path $Context.InstallDirectory)) {
            $result += $process
        }
    }
    return @($result)
}

function Test-SpotifyRunning {
    param([Parameter(Mandatory = $true)]$Context)
    return @(Get-SpotifyProcesses $Context).Count -gt 0
}

function Stop-StandaloneSpotify {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)
    if ($script:TestHooks.ContainsKey('StopSpotify')) {
        return [bool](Invoke-ManagerHook 'StopSpotify' @($Context))
    }
    $processes = @(Get-SpotifyProcesses $Context)
    if ($processes.Count -eq 0) { return $false }
    foreach ($process in $processes) {
        try { [void]$process.CloseMainWindow() } catch { }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline -and (Test-SpotifyRunning $Context)) {
        Start-Sleep -Milliseconds 250
    }
    $remaining = @(Get-SpotifyProcesses $Context)
    if ($remaining.Count -gt 0) {
        foreach ($process in $remaining) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while ([DateTime]::UtcNow -lt $deadline -and (Test-SpotifyRunning $Context)) {
            Start-Sleep -Milliseconds 200
        }
    }
    if (Test-SpotifyRunning $Context) { throw 'Spotify did not close after a verified graceful and forced stop attempt.' }
    return $true
}

function Start-StandaloneSpotify {
    param([Parameter(Mandatory = $true)]$Context)
    if ($script:TestHooks.ContainsKey('StartSpotify')) {
        Invoke-ManagerHook 'StartSpotify' @($Context) | Out-Null
        return
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Context.Executable
    $startInfo.WorkingDirectory = $Context.InstallDirectory
    $startInfo.UseShellExecute = $true
    [Diagnostics.Process]::Start($startInfo) | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-SpotifyRunning $Context)) {
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-SpotifyRunning $Context)) { throw 'Spotify was launched, but its standalone process could not be verified.' }
}

function Get-SpotifyVersion {
    param([Parameter(Mandatory = $true)]$Context)
    if ($script:TestHooks.ContainsKey('SpotifyVersion')) {
        return [string](Invoke-ManagerHook 'SpotifyVersion' @($Context))
    }
    if (-not (Test-Path -LiteralPath $Context.Executable -PathType Leaf)) { return '' }
    return [Diagnostics.FileVersionInfo]::GetVersionInfo($Context.Executable).ProductVersion
}

function Find-SpicetifyExecutable {
    if ($script:TestHooks.ContainsKey('SpicetifyExecutable')) {
        return [string](Invoke-ManagerHook 'SpicetifyExecutable')
    }
    $command = Get-Command 'spicetify.exe' -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $candidate = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'spicetify\spicetify.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return ''
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$ShowOutput
    )
    if ($script:TestHooks.ContainsKey('CapturedProcess')) {
        return Invoke-ManagerHook 'CapturedProcess' @($FilePath, $Arguments, [bool]$ShowOutput)
    }
    $escaped = foreach ($argument in $Arguments) { '"{0}"' -f ($argument -replace '"', '\"') }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $escaped -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $standardOutput = $outputTask.Result
    $standardError = $errorTask.Result
    if ($ShowOutput) {
        if (-not [string]::IsNullOrWhiteSpace($standardOutput)) { Write-Host $standardOutput.TrimEnd() }
        if (-not [string]::IsNullOrWhiteSpace($standardError)) { Write-Host $standardError.TrimEnd() -ForegroundColor Yellow }
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = [string]$standardOutput; Error = [string]$standardError }
}

function Invoke-InteractiveProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    if ($script:TestHooks.ContainsKey('InteractiveProcess')) {
        return Invoke-ManagerHook 'InteractiveProcess' @($FilePath, $Arguments)
    }
    $escaped = foreach ($argument in $Arguments) { '"{0}"' -f ($argument -replace '"', '\"') }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $escaped -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode }
}

function Invoke-Spicetify {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$ShowOutput,
        [switch]$AllowFailure
    )
    if (Test-IsAdministrator) {
        throw 'Spicetify must not be run as administrator. Close this window and run the manager normally.'
    }
    $executable = Find-SpicetifyExecutable
    if ([string]::IsNullOrWhiteSpace($executable)) { throw 'Spicetify CLI is not installed.' }
    $result = Invoke-CapturedProcess -FilePath $executable -Arguments $Arguments -ShowOutput:$ShowOutput
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        $detail = @($result.Error, $result.Output) -join "`n"
        $detail = $detail.Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "Exit code $($result.ExitCode)." }
        throw "Spicetify command failed: spicetify $($Arguments -join ' '). $detail"
    }
    return $result
}

function Get-IniValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $currentSection = ''
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $currentSection = $matches[1]; continue }
        if ($currentSection -eq $Section -and $line -match ('^\s*{0}\s*=\s*(.*?)\s*$' -f [regex]::Escape($Key))) {
            return $matches[1]
        }
    }
    return ''
}

function Get-SpicetifyConfigPath {
    $configuredDirectory = [Environment]::GetEnvironmentVariable('SPICETIFY_CONFIG')
    if (-not [string]::IsNullOrWhiteSpace($configuredDirectory)) {
        return Normalize-WindowsPath (Join-Path $configuredDirectory 'config-xpui.ini')
    }
    return Normalize-WindowsPath (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'spicetify\config-xpui.ini')
}

function Get-SpotifyPreferenceVersion {
    param([Parameter(Mandatory = $true)]$Context)
    if ($script:TestHooks.ContainsKey('SpotifyPreferenceVersion')) {
        return [string](Invoke-ManagerHook 'SpotifyPreferenceVersion' @($Context))
    }
    if (-not (Test-Path -LiteralPath $Context.Preferences -PathType Leaf)) { return '' }
    foreach ($line in Get-Content -LiteralPath $Context.Preferences -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*app\.last-launched-version\s*=\s*"?([^"\s]+)') { return $matches[1] }
    }
    return ''
}

function Get-SpicetifyState {
    param([Parameter(Mandatory = $true)]$Context)
    if ($script:TestHooks.ContainsKey('SpicetifyState')) {
        return Invoke-ManagerHook 'SpicetifyState' @($Context)
    }
    $executable = Find-SpicetifyExecutable
    if ([string]::IsNullOrWhiteSpace($executable)) {
        return [pscustomobject]@{ Installed = $false; Version = ''; AppsState = 'Unavailable'; BackupVersion = ''; SpotifyVersion = ''; NeedsRepair = $false }
    }
    if (Test-IsAdministrator) {
        $version = 'installed; version query skipped while elevated'
    }
    else {
        try {
            $versionResult = Invoke-CapturedProcess -FilePath $executable -Arguments @('-v')
            $version = if ($versionResult.ExitCode -eq 0) { $versionResult.Output.Trim() } else { 'unknown' }
        }
        catch {
            $version = 'unknown'
        }
    }
    $spaCount = 0
    $directoryCount = 0
    if (Test-Path -LiteralPath $Context.AppsDirectory -PathType Container) {
        $spaCount = @(Get-ChildItem -LiteralPath $Context.AppsDirectory -Filter '*.spa' -File -ErrorAction SilentlyContinue).Count
        $directoryCount = @(Get-ChildItem -LiteralPath $Context.AppsDirectory -Directory -ErrorAction SilentlyContinue).Count
    }
    $appsState = if ($spaCount -gt 0 -and $directoryCount -gt 0) { 'Mixed' } elseif ($spaCount -gt 0) { 'Stock' } elseif ($directoryCount -gt 0) { 'Applied' } else { 'Unknown' }
    $configPath = Get-SpicetifyConfigPath
    $backupVersion = Get-IniValue -Path $configPath -Section 'Backup' -Key 'version'
    $spotifyVersion = Get-SpotifyPreferenceVersion $Context
    $versionMismatch = -not [string]::IsNullOrWhiteSpace($spotifyVersion) -and -not [string]::IsNullOrWhiteSpace($backupVersion) -and $spotifyVersion -ne $backupVersion
    $missingBackup = $appsState -eq 'Applied' -and [string]::IsNullOrWhiteSpace($backupVersion)
    $needsRepair = $appsState -ne 'Applied' -or $versionMismatch -or $missingBackup
    return [pscustomobject]@{
        Installed = $true
        Version = $version
        AppsState = $appsState
        BackupVersion = $backupVersion
        SpotifyVersion = $spotifyVersion
        NeedsRepair = $needsRepair
    }
}

function Repair-SpicetifyIfNeeded {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [switch]$Force
    )
    $state = Get-SpicetifyState $Context
    if (-not $state.Installed) { throw 'Spicetify CLI is not installed. Use the install or update action first.' }
    if (-not $Force -and -not $state.NeedsRepair) {
        return [pscustomobject]@{ Changed = $false; Message = 'Spicetify is already applied for the detected Spotify state.' }
    }
    $result = Invoke-Spicetify -Arguments @('backup', 'apply', '--no-restart') -ShowOutput -AllowFailure
    if ($result.ExitCode -ne 0) {
        Write-ManagerMessage 'The normal apply failed. Restoring the old backup and creating a fresh one...' 'Warning'
        Invoke-Spicetify -Arguments @('restore', 'backup', 'apply', '--no-restart') -ShowOutput | Out-Null
    }
    $verified = Get-SpicetifyState $Context
    if ($verified.AppsState -ne 'Applied' -or $verified.NeedsRepair) {
        throw 'Spicetify finished without a usable verified applied state. Review the command output above.'
    }
    return [pscustomobject]@{ Changed = $true; Message = 'Spicetify was reapplied and the resulting state was verified.' }
}

function Assert-OfficialInstallerUri {
    param([Parameter(Mandatory = $true)][uri]$Uri)
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ne 'https' -or
        -not [string]::Equals($Uri.Host, 'raw.githubusercontent.com', [StringComparison]::OrdinalIgnoreCase) -or
        $Uri.AbsolutePath -ne '/spicetify/cli/main/install.ps1' -or
        -not $Uri.IsDefaultPort -or -not [string]::IsNullOrEmpty($Uri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($Uri.Query) -or -not [string]::IsNullOrWhiteSpace($Uri.Fragment)) {
        throw "Refusing an unexpected Spicetify installer address: '$Uri'."
    }
}

function Test-OfficialSpicetifyInstallerContent {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)
    $byteCount = [Text.Encoding]::UTF8.GetByteCount($Content)
    if ($byteCount -lt 4096 -or $byteCount -gt 131072) { return $false }
    $trimmed = $Content.TrimStart([char]0xFEFF, [char]13, [char]10, [char]9, [char]32)
    if ($trimmed.StartsWith('<') -or $trimmed.StartsWith('{') -or $trimmed -notmatch '^\$ErrorActionPreference\s*=\s*''Stop''') { return $false }
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) { return $false }
    $functionNames = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
    foreach ($requiredFunction in @('Test-Admin', 'Test-PowerShellVersion', 'Get-Spicetify', 'Add-SpicetifyToPath', 'Install-Spicetify')) {
        if ($functionNames -notcontains $requiredFunction) { return $false }
    }
    foreach ($marker in @(
        '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12',
        '$spicetifyFolderPath = "$env:LOCALAPPDATA\spicetify"',
        "Invoke-RestMethod -Uri 'https://api.github.com/repos/spicetify/cli/releases/latest'",
        'https://github.com/spicetify/cli/releases/download/v$targetVersion/spicetify-$targetVersion-windows-$architecture.zip',
        'Expand-Archive -Path $archivePath -DestinationPath $spicetifyFolderPath -Force'
    )) {
        if (-not $Content.Contains($marker)) { return $false }
    }
    return $true
}

function Assert-OfficialInstallerResponse {
    param([Parameter(Mandatory = $true)]$Response)
    if ($null -ne $Response.PSObject.Properties['StatusCode'] -and [int]$Response.StatusCode -ne 200) {
        throw "The official installer request returned HTTP $($Response.StatusCode)."
    }
    if ($null -ne $Response.PSObject.Properties['Headers']) {
        $contentType = [string]$Response.Headers['Content-Type']
        if ($contentType -match '^(?i)text/html|application/(?:problem\+)?json') {
            throw "The official installer returned an unexpected content type: '$contentType'."
        }
    }
    $responseUri = $null
    if ($null -ne $Response.PSObject.Properties['BaseResponse'] -and $null -ne $Response.BaseResponse -and
        $null -ne $Response.BaseResponse.PSObject.Properties['ResponseUri']) {
        $responseUri = $Response.BaseResponse.ResponseUri
    }
    elseif ($null -ne $Response.PSObject.Properties['BaseResponse'] -and $null -ne $Response.BaseResponse -and
        $null -ne $Response.BaseResponse.PSObject.Properties['RequestMessage'] -and $null -ne $Response.BaseResponse.RequestMessage) {
        $responseUri = $Response.BaseResponse.RequestMessage.RequestUri
    }
    if ($null -ne $responseUri) { Assert-OfficialInstallerUri ([uri]$responseUri) }
}

function Install-OrUpdateSpicetify {
    param([Parameter(Mandatory = $true)]$Context)
    if (Test-IsAdministrator) {
        throw 'Spicetify must not be installed or updated as administrator. Run this manager normally.'
    }
    $existing = Find-SpicetifyExecutable
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        $before = Invoke-CapturedProcess -FilePath $existing -Arguments @('-v')
        Invoke-Spicetify -Arguments @('update', '--no-restart') -ShowOutput | Out-Null
        $after = Invoke-CapturedProcess -FilePath $existing -Arguments @('-v')
        if ($after.ExitCode -ne 0) { throw 'Spicetify update completed, but the installed CLI version could not be verified.' }
        $changed = $before.ExitCode -eq 0 -and $before.Output.Trim() -ne $after.Output.Trim()
        $message = if ($changed) { 'Spicetify CLI was updated and the new version was verified.' } else { 'The official Spicetify update check completed and the installed CLI is current.' }
        return [pscustomobject]@{ Changed = $changed; Message = $message }
    }
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('SpicetifySpotifyManager-install-{0}' -f [guid]::NewGuid().ToString('N'))
    $installerPath = Join-Path $temporaryDirectory 'install.ps1'
    try {
        New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
        $temporaryDirectory = Protect-ManagerTemporaryDirectory $temporaryDirectory
        Assert-OfficialInstallerUri ([uri]$script:OfficialInstallerUrl)
        Write-ManagerMessage 'Downloading the official Spicetify installer from github.com/spicetify/cli...' 'Info'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -UseBasicParsing -Uri $script:OfficialInstallerUrl -MaximumRedirection 3 -OutFile $installerPath -PassThru -ErrorAction Stop
        Assert-OfficialInstallerResponse $response
        $installerItem = Get-Item -LiteralPath $installerPath -Force
        if (($installerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $installerItem.Length -lt 4096 -or $installerItem.Length -gt 131072) {
            throw 'The downloaded official installer has an unsafe type or unexpected size.'
        }
        $installer = [IO.File]::ReadAllText($installerPath, (New-Object Text.UTF8Encoding($false, $true)))
        if (-not (Test-OfficialSpicetifyInstallerContent $installer)) {
            throw 'The downloaded file did not match the expected structure of the official Spicetify installer.'
        }
        $result = Invoke-InteractiveProcess -FilePath (Join-Path $PSHOME 'powershell.exe') -Arguments @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installerPath)
        if ($result.ExitCode -ne 0) {
            throw "The official Spicetify installer failed with exit code $($result.ExitCode). Review its output above."
        }
    }
    finally {
        Remove-ManagerTemporaryDirectory $temporaryDirectory
    }
    $installedExecutable = Find-SpicetifyExecutable
    if ([string]::IsNullOrWhiteSpace($installedExecutable)) {
        throw 'The official installer completed, but spicetify.exe could not be found.'
    }
    $verification = Invoke-CapturedProcess -FilePath $installedExecutable -Arguments @('-v')
    if ($verification.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($verification.Output)) {
        throw 'The official installer completed, but the installed Spicetify executable did not pass its version check.'
    }
    return [pscustomobject]@{ Changed = $true; Message = 'Spicetify CLI was installed from the official Spicetify repository and verified.' }
}

function Get-ManagerStatus {
    param([Parameter(Mandatory = $true)]$Context)
    $standalone = Test-StandaloneSpotifyInstalled $Context
    $store = Test-MicrosoftStoreSpotifyInstalled
    $running = if ($standalone) { Test-SpotifyRunning $Context } else { $false }
    $version = if ($standalone) { Get-SpotifyVersion $Context } else { '' }
    $spicetify = Get-SpicetifyState $Context
    $updates = if ($standalone) { Get-UpdateAccessStatus $Context } else { [pscustomobject]@{ State = 'Unavailable'; Detail = 'Standalone Spotify is not installed.' } }
    return [pscustomobject]@{
        StandaloneInstalled = $standalone
        StoreInstalled = $store
        SpotifyRunning = $running
        SpotifyVersion = $version
        Spicetify = $spicetify
        Updates = $updates
    }
}

function Show-ManagerStatus {
    param([Parameter(Mandatory = $true)]$Status)
    $spotifyText = if ($Status.StandaloneInstalled) {
        $version = if ([string]::IsNullOrWhiteSpace($Status.SpotifyVersion)) { 'version unknown' } else { $Status.SpotifyVersion }
        "Standalone installed ($version), " + $(if ($Status.SpotifyRunning) { 'running' } else { 'closed' })
    }
    elseif ($Status.StoreInstalled) { 'Microsoft Store version only (unsupported)' }
    else { 'Not found' }
    $spicetifyText = if ($Status.Spicetify.Installed) {
        "$($Status.Spicetify.Version), $($Status.Spicetify.AppsState)"
    }
    else { 'Not installed' }
    Write-Host ''
    Write-Host 'Current status' -ForegroundColor White
    Write-Host ('  Spotify:    {0}' -f $spotifyText)
    if ($Status.StandaloneInstalled -and $Status.StoreInstalled) {
        Write-Host '  Store app:  Also installed; it will not be modified.' -ForegroundColor Yellow
    }
    Write-Host ('  Spicetify:  {0}' -f $spicetifyText)
    Write-Host ('  Updates:    {0}' -f $Status.Updates.State)
    if ($Status.Updates.State -eq 'Recovery required') {
        Write-Host ('              {0}' -f $Status.Updates.Detail) -ForegroundColor Yellow
    }
}

function Write-ManagerHelp {
    param([switch]$ErrorStream)
    $text = @"
Usage: Spicetify-Spotify-Manager.exe [option]

Options:
  --help, -h       Show this help text.
  --version, -V    Show the manager version.
  --status         Print the current read-only status.

With no option, the manager opens its interactive menu.

Exit codes:
  0   The command completed successfully.
  3   Status completed, but supported standalone Spotify was not found.
  64  The command-line arguments were not valid.
  70  An operational or status error occurred.
"@.TrimEnd()
    if ($ErrorStream) { [Console]::Error.WriteLine($text) } else { [Console]::Out.WriteLine($text) }
}

function Write-CommandLineStatus {
    $script:ReadOnlyMode = $true
    $context = Get-SpotifyContext
    $status = Get-ManagerStatus $context
    $spotifyText = if ($status.StandaloneInstalled) {
        $version = if ([string]::IsNullOrWhiteSpace($status.SpotifyVersion)) { 'version unknown' } else { $status.SpotifyVersion }
        "Standalone installed ($version), " + $(if ($status.SpotifyRunning) { 'running' } else { 'closed' })
    }
    elseif ($status.StoreInstalled) { 'Microsoft Store version only (unsupported)' }
    else { 'Not found' }
    $spicetifyText = if ($status.Spicetify.Installed) { "$($status.Spicetify.Version), $($status.Spicetify.AppsState)" } else { 'Not installed' }
    [Console]::Out.WriteLine(('{0} {1}' -f $script:ManagerName, $script:ManagerVersion))
    [Console]::Out.WriteLine('Current status')
    [Console]::Out.WriteLine(('  Spotify:    {0}' -f $spotifyText))
    if ($status.StandaloneInstalled -and $status.StoreInstalled) {
        [Console]::Out.WriteLine('  Store app:  Also installed; it will not be modified.')
    }
    [Console]::Out.WriteLine(('  Spicetify:  {0}' -f $spicetifyText))
    [Console]::Out.WriteLine(('  Updates:    {0}' -f $status.Updates.State))
    if ($status.Updates.State -eq 'Recovery required') { [Console]::Out.WriteLine(('              {0}' -f $status.Updates.Detail)) }
    if ($status.StandaloneInstalled) { return 0 }
    return 3
}

function Invoke-CommandLineAction {
    param([ValidateSet('Help', 'Version', 'Status', 'Invalid')][string]$Action)
    switch ($Action) {
        'Help' { Write-ManagerHelp; return 0 }
        'Version' { [Console]::Out.WriteLine(('{0} {1}' -f $script:ManagerName, $script:ManagerVersion)); return 0 }
        'Status' { return Write-CommandLineStatus }
        default {
            [Console]::Error.WriteLine('ERROR: Unknown or conflicting command-line arguments.')
            Write-ManagerHelp -ErrorStream
            return 64
        }
    }
}

function Save-GuidedState {
    param([Parameter(Mandatory = $true)][object]$State)
    Write-JsonFileAtomic -Path (Get-ManagerStatePath 'Guided') -Value $State
}

function Wait-ForSpotifyUpdateConfirmation {
    if ($script:TestHooks.ContainsKey('UpdateConfirmation')) {
        Invoke-ManagerHook 'UpdateConfirmation' | Out-Null
        return
    }
    [void](Read-Host)
}

function Invoke-GuidedSpotifyUpdate {
    param([Parameter(Mandatory = $true)]$Context)
    Assert-StandaloneSpotifySupported $Context
    if (Test-IsAdministrator) {
        throw 'The guided workflow must run normally because it may run Spicetify. ACL elevation is requested separately only if Windows requires it.'
    }
    $initialStatus = Get-ManagerStatus $Context
    if ($initialStatus.Updates.State -eq 'Recovery required') {
        throw 'Resolve the update-permission recovery state before starting the guided workflow.'
    }
    if ($initialStatus.Updates.State -eq 'Unknown blocked ACL') {
        throw 'The Update directory contains untracked manager-like ACL rules. Inspect or restore them before continuing.'
    }
    $wasBlocked = $initialStatus.Updates.State -in @('Blocked', 'Blocked (legacy)')
    $wasRunning = $initialStatus.SpotifyRunning
    $initialVersion = $initialStatus.SpotifyVersion
    $guidedState = [ordered]@{
        SchemaVersion = 1
        Phase = 'Preparing'
        RestoreBlock = $wasBlocked
        RestoreRunning = $wasRunning
        InitialSpotifyVersion = $initialVersion
        UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-GuidedState $guidedState
    try {
        if ($wasRunning) {
            Write-ManagerMessage 'Closing the standalone Spotify client...' 'Info'
            Stop-StandaloneSpotify $Context | Out-Null
        }
        if ($wasBlocked) {
            Write-ManagerMessage 'Temporarily allowing Spotify updates...' 'Info'
            Invoke-UpdateAccessAction -Action Allow -Context $Context -PermitElevation | Out-Null
        }
        $guidedState.Phase = 'WaitingForSpotify'
        $guidedState.UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Save-GuidedState $guidedState
        Write-ManagerMessage 'Opening Spotify with update access allowed.' 'Info'
        Start-StandaloneSpotify $Context
        Write-Host ''
        Write-Host 'Let Spotify finish opening and updating normally.' -ForegroundColor White
        Write-Host 'When Spotify is fully usable, return here and press Enter.' -ForegroundColor Gray
        Wait-ForSpotifyUpdateConfirmation
        Write-ManagerMessage 'Closing Spotify so its installed state can be checked...' 'Info'
        Stop-StandaloneSpotify $Context | Out-Null
        $newVersion = Get-SpotifyVersion $Context
        if (-not [string]::IsNullOrWhiteSpace($newVersion) -and $newVersion -ne $initialVersion) {
            Write-ManagerMessage "Spotify changed from $initialVersion to $newVersion." 'Success'
        }
        else {
            Write-ManagerMessage 'No Spotify version change was detected. The existing installation will still be checked.' 'Detail'
        }
        $spicetify = Get-SpicetifyState $Context
        if ($spicetify.Installed -and $spicetify.NeedsRepair) {
            Write-ManagerMessage 'Spotify changed the app state, so Spicetify will be reapplied.' 'Info'
            $repair = Repair-SpicetifyIfNeeded $Context
            Write-ManagerMessage $repair.Message 'Success'
        }
        elseif ($spicetify.Installed) {
            Write-ManagerMessage 'Spicetify is already applied for the detected Spotify state.' 'Success'
        }
        else {
            Write-ManagerMessage 'Spicetify is not installed, so no reapply command was run.' 'Warning'
        }
        if ($wasBlocked) {
            Write-ManagerMessage 'Restoring the previous blocked-update preference...' 'Info'
            $blockResult = Invoke-UpdateAccessAction -Action Block -Context $Context -PermitElevation
            Write-ManagerMessage $blockResult.Message 'Success'
        }
        if ($wasRunning) {
            Start-StandaloneSpotify $Context
        }
        $final = Get-ManagerStatus $Context
        if ($wasBlocked -and $final.Updates.State -notin @('Blocked', 'Blocked (legacy)')) {
            throw 'The guided workflow finished, but the previous blocked-update preference was not restored.'
        }
        if (-not $wasBlocked -and $final.Updates.State -ne 'Allowed') {
            throw 'The guided workflow finished, but update access is not in the original allowed state.'
        }
        if ($wasRunning -and -not $final.SpotifyRunning) {
            throw 'The guided workflow finished, but Spotify did not return to its previous running state.'
        }
        if (-not $wasRunning -and $final.SpotifyRunning) {
            throw 'The guided workflow finished, but Spotify remained running even though it was initially closed.'
        }
        Remove-ManagerStateFile (Get-ManagerStatePath 'Guided')
        return [pscustomobject]@{ Changed = $true; Message = 'The guided Spotify update check completed and the final state was verified.' }
    }
    catch {
        $workflowError = $_
        $guidedState.Phase = 'RecoveryRequired'
        $guidedState.UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Save-GuidedState $guidedState
        $recoveryError = $null
        try {
            if (Test-SpotifyRunning $Context) { Stop-StandaloneSpotify $Context | Out-Null }
            if ($wasBlocked) {
                Invoke-UpdateAccessAction -Action Block -Context $Context -PermitElevation | Out-Null
            }
            if ($wasRunning) { Start-StandaloneSpotify $Context }
            $recovered = Get-ManagerStatus $Context
            if ($wasBlocked -and $recovered.Updates.State -notin @('Blocked', 'Blocked (legacy)')) {
                throw 'The previous blocked-update preference was not restored.'
            }
            if (-not $wasBlocked -and $recovered.Updates.State -ne 'Allowed') {
                throw 'The previous allowed-update preference was not restored.'
            }
            if ($recovered.SpotifyRunning -ne $wasRunning) {
                throw 'The previous Spotify running state was not restored.'
            }
        }
        catch {
            $recoveryError = $_
        }
        if ($null -eq $recoveryError) {
            Remove-ManagerStateFile (Get-ManagerStatePath 'Guided')
            throw "The guided workflow stopped, but its previous update and running-state preferences were restored. $($workflowError.Exception.Message)"
        }
        throw "The guided workflow stopped before final verification. Its previous preferences were saved for recovery. Original error: $($workflowError.Exception.Message). Recovery error: $($recoveryError.Exception.Message)"
    }
}

function Resolve-GuidedRecovery {
    param([Parameter(Mandatory = $true)]$Context)
    $path = Get-ManagerStatePath 'Guided'
    $state = Read-JsonFile $path
    if ($null -eq $state) { return }
    Write-ManagerMessage 'An interrupted guided workflow was detected.' 'Warning'
    if ([bool]$state.RestoreBlock) {
        $answer = Read-Host 'Restore the previous blocked-update preference now? [Y/n]'
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(?i)y') {
            $wasRunning = Test-SpotifyRunning $Context
            if ($wasRunning) { Stop-StandaloneSpotify $Context | Out-Null }
            try {
                $result = Invoke-UpdateAccessAction -Action Block -Context $Context -PermitElevation
                Write-ManagerMessage $result.Message 'Success'
            }
            finally {
                if ([bool]$state.RestoreRunning -and -not (Test-SpotifyRunning $Context)) { Start-StandaloneSpotify $Context }
            }
        }
        else { throw 'Guided recovery was deferred. Its saved preferences have been retained.' }
    }
    $currentlyRunning = Test-SpotifyRunning $Context
    $shouldBeRunning = [bool]$state.RestoreRunning
    if ($currentlyRunning -ne $shouldBeRunning) {
        $desiredState = if ($shouldBeRunning) { 'running' } else { 'closed' }
        $answer = Read-Host "Restore Spotify's previous $desiredState state now? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(?i)y') {
            if ($shouldBeRunning) { Start-StandaloneSpotify $Context }
            else { Stop-StandaloneSpotify $Context | Out-Null }
        }
        else { throw 'Guided recovery was deferred. Its saved preferences have been retained.' }
    }
    Remove-ManagerStateFile $path
}

function Invoke-WithSpotifyStopped {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [bool]$StopRequired = $true
    )
    if (-not $StopRequired) { return & $Action }
    $wasRunning = Test-SpotifyRunning $Context
    if ($wasRunning) { Stop-StandaloneSpotify $Context | Out-Null }
    try {
        return & $Action
    }
    finally {
        if ($wasRunning) { Start-StandaloneSpotify $Context }
    }
}

function Invoke-MenuAction {
    param(
        [Parameter(Mandatory = $true)][string]$Choice,
        [Parameter(Mandatory = $true)]$Context
    )
    switch ($Choice) {
        '1' {
            $result = Invoke-GuidedSpotifyUpdate $Context
            Write-ManagerMessage $result.Message 'Success'
        }
        '2' {
            $result = Install-OrUpdateSpicetify $Context
            Write-ManagerMessage $result.Message 'Success'
        }
        '3' {
            Assert-StandaloneSpotifySupported $Context
            $result = Invoke-WithSpotifyStopped -Context $Context -Action { Repair-SpicetifyIfNeeded -Context $Context -Force }
            Write-ManagerMessage $result.Message 'Success'
        }
        '4' {
            Assert-StandaloneSpotifySupported $Context
            $updateStatus = Get-UpdateAccessStatus $Context
            $stopRequired = $updateStatus.State -notin @('Blocked', 'Blocked (legacy)')
            $result = Invoke-WithSpotifyStopped -Context $Context -StopRequired $stopRequired -Action { Invoke-UpdateAccessAction -Action Block -Context $Context -PermitElevation }
            Write-ManagerMessage $result.Message 'Success'
        }
        '5' {
            Assert-StandaloneSpotifySupported $Context
            $updateStatus = Get-UpdateAccessStatus $Context
            $stopRequired = $updateStatus.State -ne 'Allowed'
            $result = Invoke-WithSpotifyStopped -Context $Context -StopRequired $stopRequired -Action { Invoke-UpdateAccessAction -Action Allow -Context $Context -PermitElevation }
            Write-ManagerMessage $result.Message 'Success'
        }
        '7' {
            $status = Get-UpdateAccessStatus $Context
            if ($status.State -ne 'Recovery required') { throw 'No ACL recovery state is currently detected.' }
            $answer = Read-Host 'Restore the exact saved original ACL, overwriting later ACL changes? [y/N]'
            if ($answer -match '^(?i)y') {
                $result = Invoke-WithSpotifyStopped -Context $Context -Action { Invoke-UpdateAccessAction -Action AllowForce -Context $Context -PermitElevation }
                Write-ManagerMessage $result.Message 'Success'
            }
        }
        '6' { }
        default { Write-ManagerMessage 'Choose a listed menu number.' 'Warning' }
    }
}

function Show-MainMenu {
    $context = Get-SpotifyContext
    Resolve-GuidedRecovery $context
    while ($true) {
        Clear-Host
        Write-Host $script:ManagerName -ForegroundColor White
        Write-Host ('Version {0}' -f $script:ManagerVersion) -ForegroundColor DarkGray
        try {
            $status = Get-ManagerStatus $context
            Show-ManagerStatus $status
        }
        catch {
            Write-ManagerMessage "Status check failed: $($_.Exception.Message)" 'Error'
            $status = $null
        }
        Write-Host ''
        Write-Host '  1. Guided Spotify update and Spicetify repair'
        Write-Host '  2. Install or update Spicetify CLI'
        Write-Host '  3. Reapply or repair Spicetify'
        Write-Host '  4. Block Spotify updates'
        Write-Host '  5. Allow Spotify updates'
        Write-Host '  6. Refresh status'
        if ($null -ne $status -and $status.Updates.State -eq 'Recovery required') {
            Write-Host '  7. Restore saved ACL (recovery)' -ForegroundColor Yellow
        }
        Write-Host '  0. Exit'
        Write-Host ''
        $choice = [string](Read-Host 'Select an action')
        $choice = $choice.Trim()
        if ([string]::IsNullOrWhiteSpace($choice) -and [Console]::IsInputRedirected) { return }
        if ($choice -eq '0') { return }
        try {
            Invoke-MenuAction -Choice $choice -Context $context
        }
        catch {
            Write-ManagerLog $_.Exception.Message 'ERROR'
            Write-ManagerMessage "ERROR: $($_.Exception.Message)" 'Error'
        }
        if ($choice -ne '6') {
            Write-Host ''
            [void](Read-Host 'Press Enter to return to the menu')
        }
    }
}

if ($env:SPICETIFY_MANAGER_TEST_MODE -eq '1') {
    Write-Host 'SELFTEST OK'
    [Console]::Out.WriteLine('SELFTEST ENGINE ' + $PSVersionTable.PSVersion.ToString())
    [Console]::Out.WriteLine('SELFTEST POWERSHELL AVAILABLE ' + (Test-Path -LiteralPath (Join-Path $PSHOME 'powershell.exe') -PathType Leaf))
    # Read-only test evidence comes from the bound PowerShell parameter, not a
    # separately parsed copy in the launcher. No argument is evaluated as code.
    $jsonArguments = ConvertTo-Json -InputObject $NativeArguments -Compress
    [Console]::Out.WriteLine('SELFTEST ARGUMENTS ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jsonArguments)))
    return
}

if (-not $NoMain) {
    if ([string]::IsNullOrWhiteSpace($CliAction)) { $CliAction = Get-PublicCliAction -Arguments $NativeArguments }
    if ($CliAction -ne 'Menu') {
        try { exit (Invoke-CommandLineAction $CliAction) }
        catch {
            [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
            exit 70
        }
    }
    try {
        Show-MainMenu
    }
    catch {
        Write-ManagerLog $_.Exception.Message 'ERROR'
        Write-ManagerMessage "ERROR: $($_.Exception.Message)" 'Error'
        [void](Read-Host 'Press Enter to close')
        throw
    }
}
