@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Spicetify Spotify Manager

set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL_EXE%" (
    echo ERROR: Windows PowerShell 5.1 was not found.
    echo This manager requires the Windows PowerShell included with supported Windows versions.
    echo.
    pause
    exit /b 1
)

set "SPICETIFY_MANAGER_SCRIPT=%~f0"
"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $content=[IO.File]::ReadAllText($env:SPICETIFY_MANAGER_SCRIPT); $marker='# '+[char]60+'SPICETIFY_MANAGER_POWERSHELL'+[char]62; $index=$content.IndexOf($marker, [StringComparison]::Ordinal); if($index -lt 0){throw 'Embedded PowerShell marker was not found.'}; $payload=$content.Substring($index + $marker.Length).TrimStart([char]13,[char]10); & ([scriptblock]::Create($payload))"
set "MANAGER_EXIT=%ERRORLEVEL%"
set "SPICETIFY_MANAGER_SCRIPT="
exit /b %MANAGER_EXIT%
