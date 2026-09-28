@echo off
setlocal
rem Launch the FC27 Token Updater GUI (STA required for WPF, window hidden).
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0update_token.ps1" %*
exit /b 0
