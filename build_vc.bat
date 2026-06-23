@echo off
setlocal enableextensions

cd /d "%~dp0"

set "MSBUILD="
set "ARM64_BUILD=0"

if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" (
	for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe`) do set "MSBUILD=%%i"
	for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.Component.MSBuild -property installationPath 2^>nul`) do set "VS_DIR=%%i"
)

if not defined MSBUILD if exist "D:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=D:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD if exist "%ProgramFiles%\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=%ProgramFiles%\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD if exist "%ProgramFiles%\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=%ProgramFiles%\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD if exist "%ProgramFiles%\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=%ProgramFiles%\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
if not defined MSBUILD if exist "%ProgramFiles%\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe" set "MSBUILD=%ProgramFiles%\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe"

if not defined VS_DIR if exist "D:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools" set "VS_DIR=D:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools"

if not defined MSBUILD (
	echo [ERROR] MSBuild not found. Install VS 2022/2026 Build Tools with C++ desktop workload.
	exit /b 1
)

echo [INFO] MSBuild: %MSBUILD%

if not exist "..\routine\src\routine.c" (
	echo [ERROR] routine SDK missing. Run scripts\init_submodules.bat
	exit /b 1
)

if defined VS_DIR (
	for /f "delims=" %%v in ('dir /b /ad "%VS_DIR%\VC\Tools\MSVC" 2^>nul') do (
		if exist "%VS_DIR%\VC\Tools\MSVC\%%v\bin\Hostx64\arm64\cl.exe" set "ARM64_BUILD=1"
	)
)

if not exist "bin\ARM64" mkdir "bin\ARM64"

tasklist /FI "IMAGENAME eq memreduct.exe" 2>nul | find /I "memreduct.exe" >nul
if not errorlevel 1 (
	echo [WARNING] memreduct.exe is running ^(tray^). Stopping it so the linker can overwrite bin\64\memreduct.exe.
	taskkill /IM memreduct.exe /F >nul 2>&1
	if errorlevel 1 (
		echo [ERROR] Could not stop memreduct.exe. Exit from tray and retry build_vc.bat.
		exit /b 1
	)
	timeout /t 1 /nobreak >nul
)

echo [INFO] Building x64 Release...
"%MSBUILD%" memreduct.sln /p:Configuration=Release /p:Platform=x64 /m /v:minimal
if %ERRORLEVEL% neq 0 (
	echo [ERROR] x64 build failed, code: %ERRORLEVEL%
	exit /b %ERRORLEVEL%
)

if not exist "bin\64\memreduct.exe" (
	echo [ERROR] x64 build finished but bin\64\memreduct.exe is missing.
	exit /b 1
)

if "%ARM64_BUILD%"=="1" (
	echo [INFO] Building ARM64 Release...
	"%MSBUILD%" memreduct.sln /p:Configuration=Release /p:Platform=ARM64 /m /v:minimal
	if %ERRORLEVEL% neq 0 (
		echo [WARNING] ARM64 build failed. Using x64 binary for ARM64 package slot.
		call :copy_arm64_slot
	) else if not exist "bin\ARM64\memreduct.exe" (
		echo [WARNING] ARM64 build reported success but exe is missing. Using x64 binary for ARM64 package slot.
		call :copy_arm64_slot
	) else (
		echo [OK] bin\ARM64\memreduct.exe
	)
) else (
	echo [INFO] ARM64 toolset not installed, skipping native ARM64 build.
	call :copy_arm64_slot
)

if exist "bin\memreduct.lng" copy /Y "bin\memreduct.lng" "bin\64\memreduct.lng" >nul
if exist "bin\memreduct.lng" copy /Y "bin\memreduct.lng" "bin\ARM64\memreduct.lng" >nul

echo [OK] bin\64\memreduct.exe
exit /b 0

:copy_arm64_slot
if exist "bin\64\memreduct.exe" copy /Y "bin\64\memreduct.exe" "bin\ARM64\memreduct.exe" >nul
if exist "bin\64\memreduct.pdb" copy /Y "bin\64\memreduct.pdb" "bin\ARM64\memreduct.pdb" >nul
if exist "bin\ARM64\memreduct.exe" (
	echo [OK] bin\ARM64\memreduct.exe ^(x64 fallback for packaging^)
) else (
	echo [ERROR] Failed to populate bin\ARM64\memreduct.exe
	exit /b 1
)
exit /b 0
