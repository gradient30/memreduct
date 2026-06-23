@echo off
setlocal
cd /d "%~dp0"
call "%~dp0scripts\setup_build_paths.bat"
echo === 1/3 locale ===
call build_locale.bat
if errorlevel 1 exit /b 1
echo === 2/3 compile ===
call build_vc.bat
if errorlevel 1 exit /b 1
if not exist "bin\64\memreduct.exe" (echo missing exe & exit /b 1)
echo === 3/3 package ===
call build.bat
exit /b %ERRORLEVEL%
