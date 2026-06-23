@echo off
setlocal

cd /d "%~dp0"

set "BUILDER_DIR=%~dp0..\builder"

if not exist "%BUILDER_DIR%\build_locale.bat" (
	echo [ERROR] 未找到 builder 目录: %BUILDER_DIR%
	echo 请先执行: scripts\init_submodules.bat
	exit /b 1
)

cd /d "%BUILDER_DIR%"
call "%BUILDER_DIR%\build_locale.bat" memreduct
set "EXIT_CODE=%ERRORLEVEL%"

pause
exit /b %EXIT_CODE%
