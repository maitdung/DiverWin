#requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevated)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-FreshWinUninstallerAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { if ($identity -is [IDisposable]) { $identity.Dispose() } }
}

function Send-FreshWinUninstallEnvironmentChanged {
    try {
        if ($null -eq ('FreshWin.UninstallNativeEnvironment' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace FreshWin {
    public static class UninstallNativeEnvironment {
        [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
    }
}
'@
        }
        $result = [UIntPtr]::Zero
        [void][FreshWin.UninstallNativeEnvironment]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
    }
    catch { }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'The FreshWin uninstaller supports Windows only.' }
$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$installRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($programFiles, 'FreshWin'))
$currentScript = [IO.Path]::GetFullPath($PSCommandPath)
if (-not $currentScript.StartsWith($installRoot.TrimEnd([char]'\') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The uninstaller must run from the protected FreshWin installation.'
}

if (-not $Elevated -and -not (Test-FreshWinUninstallerAdministrator)) {
    $powershell = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Elevated' -f $currentScript
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    if ([int]$process.ExitCode -ne 0) { throw "Elevated FreshWin uninstall failed with exit code $($process.ExitCode)." }
    Write-Host 'FreshWin was uninstalled. User exports, backups, configuration, and logs were preserved.'
    exit 0
}
if (-not (Test-FreshWinUninstallerAdministrator)) { throw 'FreshWin uninstall did not receive administrator rights.' }

$commonPath = Join-Path $installRoot 'installer\Install.Common.ps1'
if (-not [IO.File]::Exists($commonPath)) { throw 'The protected FreshWin uninstall support file is missing.' }
. $commonPath
$item = Get-Item -LiteralPath $installRoot -Force -ErrorAction Stop
if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Refusing to uninstall through a reparse point.' }
$machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
$launcherRoot = Join-Path $installRoot 'bin'
$updatedPath = Remove-FreshWinPathEntryValue -CurrentValue ([string]$machinePath) -Entry $launcherRoot
if (-not [string]::Equals([string]$machinePath, $updatedPath, [StringComparison]::Ordinal)) {
    [Environment]::SetEnvironmentVariable('Path', $updatedPath, [EnvironmentVariableTarget]::Machine)
    Send-FreshWinUninstallEnvironmentChanged
}
[IO.Directory]::Delete($installRoot, $true)
Write-Host 'FreshWin core and machine PATH registration were removed. User exports, backups, configuration, and logs were preserved.'
