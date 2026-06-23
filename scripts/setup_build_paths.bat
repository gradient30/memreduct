@echo off
set "PF86=%ProgramFiles(x86)%"
if exist "%~dp0..\tools\nsis\nsis-3.10\makensis.exe" set "PATH=%~dp0..\tools\nsis\nsis-3.10;%PATH%" & set "NSISDIR=%~dp0..\tools\nsis\nsis-3.10"
if exist "%PF86%\NSIS\makensis.exe" set "PATH=%PF86%\NSIS;%PATH%" & set "NSISDIR=%PF86%\NSIS"
if exist "%ProgramFiles%\NSIS\makensis.exe" set "PATH=%ProgramFiles%\NSIS;%PATH%" & set "NSISDIR=%ProgramFiles%\NSIS"