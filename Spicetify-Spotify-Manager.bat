@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Spicetify and Spotify Update Manager

rem This utility is for the Spotify desktop client installed from spotify.com.
rem Update blocking is limited to %LOCALAPPDATA%\Spotify\Update.

if not defined LOCALAPPDATA (
    echo ERROR: LOCALAPPDATA is not available for the current Windows account.
    echo The utility cannot safely determine Spotify's Update folder.
    echo.
    pause
    goto END
)

set "SPOTIFY_DIR=%LOCALAPPDATA%\Spotify"
set "UPDATE_DIR=%LOCALAPPDATA%\Spotify\Update"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "CURRENT_USER_SID="

:MENU
cls
echo ==========================================================
echo              SPICETIFY / SPOTIFY MANAGER
echo ==========================================================
echo.
echo  [1] Install or update Spicetify
echo.
echo  --- Spotify update controls (desktop installer only) ---
echo  [2] Block Spotify automatic updates
echo  [3] Unblock Spotify automatic updates
echo.
echo  [4] Exit
echo.
choice /C 1234 /N /M "Choose an option (1-4): "
if errorlevel 4 goto END
if errorlevel 3 goto UNBLOCK_UPDATES
if errorlevel 2 goto BLOCK_UPDATES
goto INSTALL_SPICETIFY


:INSTALL_SPICETIFY
cls
echo Installing or updating Spicetify from the official project...
echo.
if not exist "%POWERSHELL_EXE%" (
    echo ERROR: Windows PowerShell was not found.
    echo Spicetify's official installer requires Windows PowerShell 5.1 or later.
    echo.
    pause
    goto MENU
)

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/spicetify/cli/main/install.ps1' | Invoke-Expression"
echo.
if errorlevel 1 (
    echo ERROR: Spicetify's installer returned an error.
    echo Read the installer output above before trying again.
) else (
    echo Spicetify's official install or update command finished successfully.
)
echo.
pause
goto MENU


:BLOCK_UPDATES
cls
echo This will, if blocking is needed:
echo   - Fully close Spotify
echo   - Clear and recreate its Update folder
echo   - Lock write and delete access for your Windows account
echo.
echo Target: "%UPDATE_DIR%"
echo No other folder will be changed.
echo.
choice /C YN /N /M "Continue? [Y/N]: "
if errorlevel 2 goto BLOCK_CANCELLED

if not exist "%SPOTIFY_DIR%\" (
    echo.
    echo ERROR: Spotify's local data folder was not found:
    echo "%SPOTIFY_DIR%"
    echo.
    echo Open the spotify.com desktop client once, close it, then try again.
    echo This option is not intended for the Microsoft Store version.
    echo.
    pause
    goto MENU
)

call :GET_CURRENT_USER_SID
if errorlevel 1 (
    echo.
    echo ERROR: The current Windows account could not be resolved to a SID.
    echo No permissions were changed.
    echo.
    pause
    goto MENU
)

if exist "%UPDATE_DIR%" (
    call :CHECK_UPDATE_ITEM_SAFE
    if errorlevel 1 (
        echo.
        echo ERROR: The Update path is a link, junction, or cannot be inspected safely.
        echo Refusing to change permissions because it may point outside the expected folder.
        echo.
        pause
        goto MENU
    )
)

if exist "%UPDATE_DIR%\" (
    call :VERIFY_BLOCKED
    if not errorlevel 1 (
        echo.
        echo Spotify automatic updates are already blocked for this Windows account.
        echo Nothing was changed and Spotify was not closed.
        echo.
        pause
        goto MENU
    )
)

call :CLOSE_SPOTIFY
if errorlevel 1 (
    echo.
    echo ERROR: Spotify is still running, so the Update folder was not changed.
    echo Close Spotify manually and try again.
    echo.
    pause
    goto MENU
)

if exist "%UPDATE_DIR%" (
    call :RESTORE_UPDATE_PERMISSIONS
    if errorlevel 1 (
        echo.
        echo ERROR: Existing Update permissions could not be normalized safely.
        echo Try this option again as administrator if the folder was locked by another tool.
        echo.
        pause
        goto MENU
    )

    call :REMOVE_UPDATE_ITEM
    if errorlevel 1 (
        echo.
        echo ERROR: The existing Update item could not be removed.
        echo Its normal permissions were restored, so updates are not left partially blocked.
        echo.
        pause
        goto MENU
    )
)

mkdir "%UPDATE_DIR%" >nul 2>&1
if not exist "%UPDATE_DIR%\" (
    echo.
    echo ERROR: The Update folder could not be created.
    echo Spotify updates remain unblocked.
    echo.
    pause
    goto MENU
)

call :CHECK_UPDATE_ITEM_SAFE
if errorlevel 1 (
    echo.
    echo ERROR: The new Update folder could not be verified as a normal folder.
    echo No locking permissions were applied.
    echo.
    pause
    goto MENU
)

rem Remove inherited entries, retain recovery access for well-known Windows
rem system groups, give the signed-in user read access, then deny writes/deletes.
set "LOCK_STEP=disable inherited permissions"
icacls "%UPDATE_DIR%" /inheritance:r /L /Q >nul 2>&1
if errorlevel 1 goto LOCK_FAILED

set "LOCK_STEP=grant SYSTEM recovery access"
icacls "%UPDATE_DIR%" /grant:r "*S-1-5-18:(OI)(CI)(F)" /L /Q >nul 2>&1
if errorlevel 1 goto LOCK_FAILED

set "LOCK_STEP=grant Administrators recovery access"
icacls "%UPDATE_DIR%" /grant:r "*S-1-5-32-544:(OI)(CI)(F)" /L /Q >nul 2>&1
if errorlevel 1 goto LOCK_FAILED

set "LOCK_STEP=grant the current user read access"
icacls "%UPDATE_DIR%" /grant:r "*%CURRENT_USER_SID%:(OI)(CI)(RX)" /L /Q >nul 2>&1
if errorlevel 1 goto LOCK_FAILED

set "LOCK_STEP=deny the current user write and delete access"
icacls "%UPDATE_DIR%" /deny "*%CURRENT_USER_SID%:(OI)(CI)(W,D)" /L /Q >nul 2>&1
if errorlevel 1 goto LOCK_FAILED

call :VERIFY_BLOCKED
if errorlevel 1 (
    set "LOCK_STEP=verify the completed lock"
    goto LOCK_FAILED
)

echo.
echo Spotify automatic updates are now blocked.
echo The requested ACL state was verified successfully.
echo.
echo To update Spotify later, unblock updates with option 3, let Spotify
echo update, close it, reapply Spicetify if needed, then block updates again.
echo.
pause
goto MENU


:LOCK_FAILED
echo.
echo ERROR: Could not %LOCK_STEP%.
echo Attempting to restore normal access so the folder is not left half-locked...
call :RESTORE_UPDATE_PERMISSIONS
if errorlevel 1 (
    echo WARNING: Automatic recovery also failed.
    echo Run option 3 as administrator to repair the Update folder permissions.
) else (
    echo Normal inherited permissions and user ownership were restored.
    echo Spotify updates remain unblocked.
)
echo.
pause
goto MENU


:BLOCK_CANCELLED
echo.
echo Cancelled. Nothing was changed.
timeout /t 1 /nobreak >nul
goto MENU


:UNBLOCK_UPDATES
cls
echo This will restore normal inherited permissions and user ownership to:
echo "%UPDATE_DIR%"
echo.
echo Spotify will be closed only if a permissions change is needed.
echo.
choice /C YN /N /M "Continue? [Y/N]: "
if errorlevel 2 goto UNBLOCK_CANCELLED

call :GET_CURRENT_USER_SID
if errorlevel 1 (
    echo.
    echo ERROR: The current Windows account could not be resolved to a SID.
    echo No permissions were changed.
    echo.
    pause
    goto MENU
)

if not exist "%UPDATE_DIR%" (
    echo.
    echo No Update item exists. Spotify can recreate it with normal permissions,
    echo so automatic updates are already allowed.
    echo Nothing was changed and Spotify was not closed.
    echo.
    pause
    goto MENU
)

call :CHECK_UPDATE_ITEM_SAFE
if errorlevel 1 (
    echo.
    echo ERROR: The Update path is a link, junction, or cannot be inspected safely.
    echo Refusing to change permissions because it may point outside the expected folder.
    echo.
    pause
    goto MENU
)

if exist "%UPDATE_DIR%\" (
    call :VERIFY_UNBLOCKED
    if not errorlevel 1 (
        echo.
        echo Spotify updates are already unblocked.
        echo Nothing was changed and Spotify was not closed.
        echo.
        pause
        goto MENU
    )
)

call :CLOSE_SPOTIFY
if errorlevel 1 (
    echo.
    echo ERROR: Spotify is still running, so the Update permissions were not changed.
    echo Close Spotify manually and try again.
    echo.
    pause
    goto MENU
)

call :RESTORE_UPDATE_PERMISSIONS
if errorlevel 1 (
    echo.
    echo ERROR: The Update permissions could not be restored completely.
    echo Try this option again as administrator.
    echo.
    pause
    goto MENU
)

if not exist "%UPDATE_DIR%\" (
    call :REMOVE_UPDATE_ITEM
    if errorlevel 1 (
        echo.
        echo ERROR: The non-folder Update item could not be removed.
        echo It may still prevent Spotify from creating its normal Update folder.
        echo.
        pause
        goto MENU
    )
)

if exist "%UPDATE_DIR%\" (
    call :VERIFY_UNBLOCKED
    if errorlevel 1 (
        echo.
        echo ERROR: Permission restoration finished, but the access check failed.
        echo Try this option again as administrator before opening Spotify.
        echo.
        pause
        goto MENU
    )
)

echo.
echo Spotify updates are unblocked.
echo Normal access was verified. Open Spotify when you are ready to update it.
echo.
pause
goto MENU


:UNBLOCK_CANCELLED
echo.
echo Cancelled. Nothing was changed.
timeout /t 1 /nobreak >nul
goto MENU


:GET_CURRENT_USER_SID
if defined CURRENT_USER_SID exit /b 0
if not exist "%POWERSHELL_EXE%" exit /b 1
for /f "tokens=2 delims=," %%I in ('whoami.exe /USER /FO CSV /NH 2^>nul') do if not defined CURRENT_USER_SID set "CURRENT_USER_SID=%%~I"
if not defined CURRENT_USER_SID exit /b 1
exit /b 0


:CHECK_UPDATE_ITEM_SAFE
"%POWERSHELL_EXE%" -NoProfile -Command "try { $item=Get-Item -LiteralPath $env:UPDATE_DIR -Force -ErrorAction Stop; if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { exit 1 }; exit 0 } catch { exit 1 }" >nul 2>&1
exit /b %ERRORLEVEL%


:VERIFY_BLOCKED
"%POWERSHELL_EXE%" -NoProfile -Command "try { $a=Get-Acl -LiteralPath $env:UPDATE_DIR -ErrorAction Stop; $s=$env:CURRENT_USER_SID; $n=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete; $r=[Security.AccessControl.FileSystemRights]::ReadAndExecute; $d=$u=$false; foreach ($x in $a.Access) { try { $i=$x.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }; if ($i -eq $s -and $x.AccessControlType -eq 'Deny' -and (($x.FileSystemRights -band $n) -eq $n)) { $d=$true }; if ($i -eq $s -and $x.AccessControlType -eq 'Allow' -and (($x.FileSystemRights -band $r) -eq $r)) { $u=$true } }; if ($a.AreAccessRulesProtected -and $d -and $u) { exit 0 } } catch {}; exit 1" >nul 2>&1
if errorlevel 1 exit /b 1
"%POWERSHELL_EXE%" -NoProfile -Command "try { $a=Get-Acl -LiteralPath $env:UPDATE_DIR -ErrorAction Stop; $f=[Security.AccessControl.FileSystemRights]::FullControl; $y=$z=$false; foreach ($x in $a.Access) { try { $i=$x.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }; if ($x.AccessControlType -eq 'Allow' -and (($x.FileSystemRights -band $f) -eq $f)) { if ($i -eq 'S-1-5-18') { $y=$true }; if ($i -eq 'S-1-5-32-544') { $z=$true } } }; if ($y -and $z) { exit 0 } } catch {}; exit 1" >nul 2>&1
exit /b %ERRORLEVEL%


:VERIFY_UNBLOCKED
"%POWERSHELL_EXE%" -NoProfile -Command "try { $a=Get-Acl -LiteralPath $env:UPDATE_DIR -ErrorAction Stop; $s=$env:CURRENT_USER_SID; $o=([Security.Principal.NTAccount]$a.Owner).Translate([Security.Principal.SecurityIdentifier]).Value; if ($o -ne $s -or $a.AreAccessRulesProtected) { exit 1 }; foreach ($x in $a.Access) { try { $i=$x.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }; if ($i -eq $s -and $x.AccessControlType -eq 'Deny') { exit 1 } }; exit 0 } catch { exit 1 }" >nul 2>&1
if errorlevel 1 exit /b 1
"%POWERSHELL_EXE%" -NoProfile -Command "try { $t=Join-Path $env:UPDATE_DIR ('.spicetify-manager-test-' + [guid]::NewGuid().ToString('N')); [IO.File]::WriteAllText($t,'test'); Remove-Item -LiteralPath $t -Force -ErrorAction Stop; exit 0 } catch { if ($t -and (Test-Path -LiteralPath $t)) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }; exit 1 }" >nul 2>&1
exit /b %ERRORLEVEL%


:RESTORE_UPDATE_PERMISSIONS
set "ICACLS_RECURSE="
if exist "%UPDATE_DIR%\" set "ICACLS_RECURSE=/T"

rem /L ensures a nested symbolic link is changed as a link, not followed.
icacls "%UPDATE_DIR%" /remove:d "*%CURRENT_USER_SID%" %ICACLS_RECURSE% /C /L /Q >nul 2>&1
if errorlevel 1 exit /b 1

icacls "%UPDATE_DIR%" /inheritance:e %ICACLS_RECURSE% /C /L /Q >nul 2>&1
if errorlevel 1 exit /b 1

icacls "%UPDATE_DIR%" /reset %ICACLS_RECURSE% /C /L /Q >nul 2>&1
if errorlevel 1 exit /b 1

icacls "%UPDATE_DIR%" /setowner "*%CURRENT_USER_SID%" %ICACLS_RECURSE% /C /L /Q >nul 2>&1
if errorlevel 1 exit /b 1

exit /b 0


:REMOVE_UPDATE_ITEM
if exist "%UPDATE_DIR%\" (
    rmdir /S /Q "%UPDATE_DIR%" >nul 2>&1
) else (
    del /F /Q "%UPDATE_DIR%" >nul 2>&1
)
if exist "%UPDATE_DIR%" exit /b 1
exit /b 0


:IS_SPOTIFY_RUNNING
tasklist /FI "IMAGENAME eq Spotify.exe" /NH 2>nul | "%SystemRoot%\System32\find.exe" /I "Spotify.exe" >nul
if not errorlevel 1 exit /b 0
tasklist /FI "IMAGENAME eq SpotifyWebHelper.exe" /NH 2>nul | "%SystemRoot%\System32\find.exe" /I "SpotifyWebHelper.exe" >nul
if not errorlevel 1 exit /b 0
exit /b 1


:CLOSE_SPOTIFY
call :IS_SPOTIFY_RUNNING
if errorlevel 1 (
    echo.
    echo Spotify is already closed.
    exit /b 0
)

echo.
echo Closing Spotify...
for /L %%A in (1,1,5) do (
    taskkill /IM Spotify.exe /F >nul 2>&1
    taskkill /IM SpotifyWebHelper.exe /F >nul 2>&1
    timeout /t 1 /nobreak >nul
    call :IS_SPOTIFY_RUNNING
    if errorlevel 1 goto SPOTIFY_CLOSED
)

exit /b 1

:SPOTIFY_CLOSED
echo Spotify was closed successfully.
exit /b 0


:END
endlocal
exit /b
