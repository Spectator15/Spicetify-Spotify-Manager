# Shared, in-memory Windows API binding. No compiler or temporary assembly.
function script:Initialize-BoundDirectoryNativeApi {
    if ('SpicetifyManager.DirectoryAclNative' -as [type]) { return }
    $assemblyName = New-Object Reflection.AssemblyName('SpicetifyManager.DirectoryAclNative')
    $assembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly($assemblyName, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule($assemblyName.Name)
    $type = $module.DefineType($assemblyName.Name, [Reflection.TypeAttributes]'Public,Sealed,Abstract')
    $handleType = [Microsoft.Win32.SafeHandles.SafeFileHandle]
    $pointerRef = [IntPtr].MakeByRefType()
    $signatures = @(
        @('kernel32.dll', 'CreateFileW', $handleType, @([string], [uint32], [uint32], [IntPtr], [uint32], [uint32], [IntPtr])),
        @('kernel32.dll', 'GetFileInformationByHandleEx', [bool], @($handleType, [int], [IntPtr], [uint32])),
        @('kernel32.dll', 'GetFinalPathNameByHandleW', [uint32], @($handleType, [Text.StringBuilder], [uint32], [uint32])),
        @('advapi32.dll', 'GetSecurityInfo', [uint32], @($handleType, [int], [uint32], $pointerRef, $pointerRef, $pointerRef, $pointerRef, $pointerRef)),
        @('advapi32.dll', 'GetSecurityDescriptorLength', [uint32], @([IntPtr])),
        @('kernel32.dll', 'LocalFree', [IntPtr], @([IntPtr]))
    )
    $importConstructor = [Runtime.InteropServices.DllImportAttribute].GetConstructor(@([string]))
    $importFields = [Reflection.FieldInfo[]]@(
        [Runtime.InteropServices.DllImportAttribute].GetField('SetLastError'),
        [Runtime.InteropServices.DllImportAttribute].GetField('CharSet'),
        [Runtime.InteropServices.DllImportAttribute].GetField('ExactSpelling')
    )
    foreach ($signature in $signatures) {
        $method = $type.DefinePInvokeMethod($signature[1], $signature[0], [Reflection.MethodAttributes]'Public,Static,PinvokeImpl',
            [Reflection.CallingConventions]::Standard, $signature[2], [type[]]$signature[3],
            [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Unicode)
        $attribute = New-Object Reflection.Emit.CustomAttributeBuilder($importConstructor, [object[]]@($signature[0]),
            $importFields, [object[]]@($true, [Runtime.InteropServices.CharSet]::Unicode, $true))
        $method.SetCustomAttribute($attribute)
        $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
    }
    [void]$type.CreateType()
}

function script:Normalize-BoundDirectoryPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).Replace('/', '\')
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) {
        throw 'Only a local drive directory can be used for Spotify ACL operations.'
    }
    if ($full.Length -eq 3) { return $full }
    return $full.TrimEnd('\')
}

function script:Add-BoundDirectoryHandle {
    param($Session, [string]$Path, [uint32]$Access)
    $native = 'SpicetifyManager.DirectoryAclNative' -as [type]
    # FILE_SHARE_READ only; OPEN_EXISTING; BACKUP_SEMANTICS | OPEN_REPARSE_POINT.
    $handle = $native::CreateFileW($Path, $Access, 1, [IntPtr]::Zero, 3, 0x02200000, [IntPtr]::Zero)
    if ($handle.IsInvalid) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $handle.Dispose()
        $errorDetail = (New-Object ComponentModel.Win32Exception($code)).Message
        throw (New-Object ComponentModel.Win32Exception($code, "Cannot bind the Spotify directory '$Path'. $errorDetail"))
    }
    $Session.Handles.Add($handle)
    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
    try {
        # FILE_ATTRIBUTE_TAG_INFO, queried on the opened object, not its name.
        if (-not $native::GetFileInformationByHandleEx($handle, 9, $buffer, 8)) {
            throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error()))
        }
        $attributes = [Runtime.InteropServices.Marshal]::ReadInt32($buffer)
        if (($attributes -band 0x10) -eq 0 -or ($attributes -band 0x400) -ne 0) {
            throw "A directory handle refers to a reparse point, junction or non-directory: '$Path'."
        }
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
    $name = New-Object Text.StringBuilder(32768)
    $length = $native::GetFinalPathNameByHandleW($handle, $name, $name.Capacity, 0)
    if ($length -eq 0) { throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error())) }
    if ($length -ge $name.Capacity) { throw 'The bound directory path is too long.' }
    $resolved = $name.ToString()
    if ($resolved.StartsWith('\\?\', [StringComparison]::Ordinal)) { $resolved = $resolved.Substring(4) }
    if (-not [string]::Equals((Normalize-BoundDirectoryPath $resolved), $Path, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The directory handle resolves outside the validated path: '$Path'."
    }
    # Also bind the chain to a volume-GUID path, not just a mutable DOS drive
    # letter. A changed drive mapping cannot make a different volume look equal.
    [void]$name.Clear()
    $length = $native::GetFinalPathNameByHandleW($handle, $name, $name.Capacity, 1)
    if ($length -eq 0) { throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error())) }
    if ($length -ge $name.Capacity) { throw 'The bound volume path is too long.' }
    $canonical = $name.ToString()
    if ([string]::IsNullOrEmpty($Session.CanonicalRoot)) {
        if ($Path.Length -ne 3 -or $canonical -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$') {
            throw 'The local drive does not resolve to a supported volume root.'
        }
        $Session.CanonicalRoot = $canonical
    }
    elseif (-not [string]::Equals($canonical, ($Session.CanonicalRoot + $Path.Substring(3)), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The directory handle is outside the bound volume and ancestor chain.'
    }
    return $handle
}

function script:Read-BoundDirectorySecurity {
    param($Session)
    if ($Session.Disposed) { throw 'The directory ACL session is closed.' }
    $native = 'SpicetifyManager.DirectoryAclNative' -as [type]
    $owner = $group = $dacl = $sacl = $descriptor = [IntPtr]::Zero
    try {
        # SE_FILE_OBJECT; OWNER | GROUP | DACL. Existing audit rules stay untouched.
        $code = $native::GetSecurityInfo($Session.Target, 1, 7, [ref]$owner, [ref]$group, [ref]$dacl, [ref]$sacl, [ref]$descriptor)
        if ($code -ne 0) { throw (New-Object ComponentModel.Win32Exception([int]$code)) }
        $length = $native::GetSecurityDescriptorLength($descriptor)
        if ($length -eq 0 -or $length -gt 1048576) { throw 'Invalid bound security descriptor length.' }
        $bytes = New-Object byte[] $length
        [Runtime.InteropServices.Marshal]::Copy($descriptor, $bytes, 0, $length)
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetSecurityDescriptorBinaryForm($bytes, [Security.AccessControl.AccessControlSections]'Access,Owner,Group')
        return $acl
    }
    finally { if ($descriptor -ne [IntPtr]::Zero) { [void]$native::LocalFree($descriptor) } }
}

function script:Write-BoundDirectorySecurity {
    param($Session, [Security.AccessControl.DirectorySecurity]$Acl)
    $current = Read-BoundDirectorySecurity $Session
    $sections = [Security.AccessControl.AccessControlSections]::Access
    if (-not $current.GetOwner([Security.Principal.SecurityIdentifier]).Equals($Acl.GetOwner([Security.Principal.SecurityIdentifier]))) {
        $sections = $sections -bor [Security.AccessControl.AccessControlSections]::Owner
    }
    if (-not $current.GetGroup([Security.Principal.SecurityIdentifier]).Equals($Acl.GetGroup([Security.Principal.SecurityIdentifier]))) {
        $sections = $sections -bor [Security.AccessControl.AccessControlSections]::Group
    }
    $writer = $Session.Target
    if (($sections -band [Security.AccessControl.AccessControlSections]'Owner,Group') -ne 0) {
        # Add WRITE_OWNER only for an intentional owner/group restore. The
        # original leaf and ancestors remain held while this handle is opened.
        $writer = Add-BoundDirectoryHandle $Session $Session.Path 0x000E0081
    }
    $desired = New-Object Security.AccessControl.DirectorySecurity
    $desired.SetSecurityDescriptorBinaryForm($Acl.GetSecurityDescriptorBinaryForm(), $sections)
    # Invoke the documented protected .NET handle overload. No name-based
    # overload, temporary assembly or Set-Acl fallback is permitted.
    $persist = [Security.AccessControl.NativeObjectSecurity].GetMethod('Persist', [Reflection.BindingFlags]'Instance,NonPublic',
        $null, [type[]]@([Runtime.InteropServices.SafeHandle], [Security.AccessControl.AccessControlSections]), $null)
    if ($null -eq $persist) { throw 'This .NET runtime does not expose the required handle-based ACL operation.' }
    [void]$persist.Invoke($desired, [object[]]@($writer, $sections))
}

function script:Open-BoundDirectoryAclSession {
    param([Parameter(Mandatory = $true)][string]$Path)
    Initialize-BoundDirectoryNativeApi
    $session = [pscustomobject]@{
        Path = Normalize-BoundDirectoryPath $Path
        CanonicalRoot = ''
        Handles = New-Object 'Collections.Generic.List[Microsoft.Win32.SafeHandles.SafeFileHandle]'
        Target = $null
        Disposed = $false
    }
    $session | Add-Member ScriptMethod Read { Read-BoundDirectorySecurity $this }
    $session | Add-Member ScriptMethod Write { param([Security.AccessControl.DirectorySecurity]$Acl) Write-BoundDirectorySecurity $this $Acl }
    $session | Add-Member ScriptMethod Dispose {
        if ($this.Disposed) { return }
        $this.Disposed = $true
        for ($index = $this.Handles.Count - 1; $index -ge 0; $index--) { $this.Handles[$index].Dispose() }
        $this.Handles.Clear()
    }
    try {
        $root = [IO.Path]::GetPathRoot($session.Path)
        # FILE_LIST_DIRECTORY is necessary: metadata-only opens do not enforce
        # the no-write/no-delete share mode. Keep ancestors held root-to-leaf.
        [void](Add-BoundDirectoryHandle $session $root 0x81)
        $parts = $session.Path.Substring($root.Length).Split([char[]]'\', [StringSplitOptions]::RemoveEmptyEntries)
        if ($parts.Count -eq 0) { throw 'A drive root is not an ACL target.' }
        $current = $root
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $current = [IO.Path]::Combine($current, $parts[$index])
            $access = if ($index -eq $parts.Count - 1) { 0x60081 } else { 0x81 }
            $session.Target = Add-BoundDirectoryHandle $session $current $access
        }
        return $session
    }
    catch { $session.Dispose(); throw }
}
