@echo off
where pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 ^(pwsh^) is required. See docs/deployment-quickstart.md. 1>&2
  exit /b 127
)
pwsh.exe -NoLogo -NoProfile -File "%~dp0manager.ps1" %*
exit /b %errorlevel%
