# First logon: OpenSSH server (PowerShell shell, key auth for the host), no sleep or lock, then a marker.
$ErrorActionPreference = 'Continue'
Start-Transcript C:\firstlogon.log
$src = Split-Path $MyInvocation.MyCommand.Path
powercfg /change monitor-timeout-ac 0; powercfg /change standby-timeout-ac 0
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization" /v NoLockScreen /t REG_DWORD /d 1 /f
reg add "HKCU\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 0 /f
Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
# OpenSSH: the built-in capability first, else the zip on this disc.
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 }
if (-not (Get-Service sshd -ErrorAction SilentlyContinue) -and (Test-Path "$src\OpenSSH-ARM64.zip")) {
  Expand-Archive "$src\OpenSSH-ARM64.zip" 'C:\Program Files' -Force
  & 'C:\Program Files\OpenSSH-ARM64\install-sshd.ps1'
}
Set-Service sshd -StartupType Automatic; Start-Service sshd
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Protocol TCP -LocalPort 22 -Action Allow -ErrorAction SilentlyContinue
New-Item -ItemType Directory C:\ProgramData\ssh -Force | Out-Null
Copy-Item "$src\authorized_keys" C:\ProgramData\ssh\administrators_authorized_keys -Force
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
Restart-Service sshd
Set-Content C:\firstlogon.done (Get-Date)
Stop-Transcript
