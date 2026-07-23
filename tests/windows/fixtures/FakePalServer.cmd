@echo off
setlocal

if "%~1"=="" exit /b 90
if "%~2"=="" exit /b 91

set "CGCE_UE4SS_ROOT=%~1"
set "CGCE_MODE=%~2"

if /I "%CGCE_MODE%"=="nonzero" exit /b 7
if /I "%CGCE_MODE%"=="timeout" (
    cgce-fake-sleeper.exe 127.0.0.1 -n 4 > nul
    exit /b 0
)
if /I "%CGCE_MODE%"=="unlisted-child" (
    cgce-fake-sleeper.exe 127.0.0.1 -n 4 > nul
    exit /b 0
)
if /I "%CGCE_MODE%"=="grandchild" (
    cgce-fake-launcher.exe /d /c cgce-fake-grandchild.cmd
    if errorlevel 1 exit /b 93
)
if /I "%CGCE_MODE%"=="detached-listener" (
    if "%~3"=="" exit /b 94
    start "" /b cgce-fake-listener.exe %~3
    cgce-fake-sleeper.exe 127.0.0.1 -n 2 > nul
)

if not exist "%CGCE_UE4SS_ROOT%\CXXHeaderDump" (
    mkdir "%CGCE_UE4SS_ROOT%\CXXHeaderDump" || exit /b 92
)

if /I "%CGCE_MODE%"=="missing-object" goto write_header
if /I "%CGCE_MODE%"=="empty-object" (
    type nul > "%CGCE_UE4SS_ROOT%\UE4SS_ObjectDump.txt"
) else (
    > "%CGCE_UE4SS_ROOT%\UE4SS_ObjectDump.txt" echo SyntheticObject
)

:write_header
if /I not "%CGCE_MODE%"=="missing-header" (
    > "%CGCE_UE4SS_ROOT%\CXXHeaderDump\Synthetic.hpp" echo struct Synthetic {};
)

if /I "%CGCE_MODE%"=="missing-completion" (
    > "%CGCE_UE4SS_ROOT%\UE4SS.log" echo SYNTHETIC_NO_COMPLETION
) else if /I "%CGCE_MODE%"=="blocked" (
    > "%CGCE_UE4SS_ROOT%\UE4SS.log" echo [LogLua] CGCE_INVENTORY_BLOCKED SYNTHETIC
) else if /I "%CGCE_MODE%"=="duplicate-completion" (
    > "%CGCE_UE4SS_ROOT%\UE4SS.log" echo [LogLua] CGCE_INVENTORY_COMPLETE ALL
    >> "%CGCE_UE4SS_ROOT%\UE4SS.log" echo [LogLua] CGCE_INVENTORY_COMPLETE ALL
) else (
    > "%CGCE_UE4SS_ROOT%\UE4SS.log" echo [LogLua] CGCE_INVENTORY_COMPLETE ALL
)

exit /b 0
