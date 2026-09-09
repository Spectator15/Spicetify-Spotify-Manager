$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'src\SpicetifySpotifyManager.ps1') -NoMain

# Load the exact committed fixture definitions without running the test suite.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Run-Tests.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Test source did not parse.' }
foreach ($name in @('New-TestRoot', 'Use-TestEnvironment')) {
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($definition.Count -ne 1) { throw 'Fixture function was not unique.' }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$script:TemporaryRoots = New-Object 'Collections.Generic.List[string]'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
[ordered]@{
    UserSid = $identity.User.Value
    TokenDefaultOwnerSid = $identity.Owner.Value
    ActualAdministratorToken = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Creation = 'Committed New-TestRoot, then production Initialize-ManagerDataDirectory using New-Item'
    FixtureAdministratorHook = $false
} | ConvertTo-Json -Compress | Write-Output
try {
    $root = New-TestRoot
    Use-TestEnvironment -Root $root -Context ([pscustomobject]@{})
    $directory = Get-ManagerDataDirectory
    if (Test-Path -LiteralPath $directory) { throw 'The diagnostic state directory must start absent.' }
    try { [void](Initialize-ManagerDataDirectory); Write-Output 'ProductionGuard=accepted' }
    catch { Write-Output ('ProductionGuard=' + $_.Exception.Message) }
    foreach ($entry in @(@('TempParent', [IO.Path]::GetTempPath()), @('FixtureRoot', $root), @('ManagerState', $directory))) {
        $acl = Get-Acl -LiteralPath $entry[1]
        [ordered]@{
            Directory = $entry[0]
            OwnerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            OwnerMatchesCurrentUser = ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $identity.User.Value)
            DaclInheritanceProtected = $acl.AreAccessRulesProtected
        } | ConvertTo-Json -Compress | Write-Output
    }
}
finally {
    Set-ManagerTestHooks @{}
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    foreach ($root in $script:TemporaryRoots) {
        $resolved = [IO.Path]::GetFullPath($root)
        if (-not $resolved.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^SpicetifyManagerTests-[0-9a-f]{32}$') { throw 'Unexpected diagnostic cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    $identity.Dispose()
}
