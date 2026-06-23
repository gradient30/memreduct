@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0\.."

set "VERSION="
for /f "tokens=1 delims=|" %%a in ('findstr /b "memreduct=" VERSION') do (
  for /f "tokens=2 delims==" %%b in ("%%a") do set "VERSION=%%b"
)

if not defined VERSION (
  echo Cannot parse version from VERSION file
  exit /b 1
)

findstr /c:"APP_VERSION L\"!VERSION!\"" src\app.h >nul || (echo src\app.h version mismatch & exit /b 1)
findstr /c:"v!VERSION!" CHANGELOG.md >nul || (echo CHANGELOG.md missing v!VERSION! & exit /b 1)
findstr /c:"v!VERSION! " bin\History.txt >nul || (echo bin\History.txt missing v!VERSION! & exit /b 1)
findstr /c:"APP_VERSION=!VERSION!" build.bat >nul || (echo build.bat version mismatch & exit /b 1)

echo Version !VERSION! verified
exit /b 0