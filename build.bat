@echo off
setlocal

cd /d "%~dp0"

call "%~dp0scripts\setup_build_paths.bat"

set "BUILDER_DIR=%~dp0..\builder"
set "OUT_DIR=%~dp0build"
set "APP_VERSION=3.5.3"

if not exist "%BUILDER_DIR%\build.bat" (
	echo [ERROR] builder not found: %BUILDER_DIR%
	echo Run scripts\init_submodules.bat first.
	exit /b 1
)

if not exist "bin\64\memreduct.exe" (
	echo [ERROR] bin\64\memreduct.exe not found. Run build_vc.bat first.
	exit /b 1
)

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
set "BUILDER_OUT_DIRECTORY=%OUT_DIR%"

where makensis.exe >nul 2>&1
if errorlevel 1 (
	echo [WARNING] makensis.exe not in PATH. setup.exe will not be created.
	echo Install NSIS 3.10+ from https://nsis.sourceforge.io/Download
)

cd /d "%BUILDER_DIR%"
call "%BUILDER_DIR%\build.bat" memreduct %APP_VERSION% "Mem Reduct"
set "EXIT_CODE=%ERRORLEVEL%"

if %EXIT_CODE% neq 0 (
	echo [ERROR] package failed, code: %EXIT_CODE%
) else (
	if exist "%OUT_DIR%\memreduct-%APP_VERSION%-setup.exe" (
		echo [OK] output: %OUT_DIR%\memreduct-%APP_VERSION%-setup.exe
	) else (
		echo [OK] portable: %OUT_DIR%\memreduct-%APP_VERSION%-bin.7z
		echo [WARNING] setup.exe was not created ^(see NSIS log above^)
	)
)

pause
exit /b %EXIT_CODE%
