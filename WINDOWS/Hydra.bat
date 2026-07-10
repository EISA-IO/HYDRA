@echo off
setlocal enabledelayedexpansion
REM Launch the FULL Hydra GUI (modern tabbed UI: Workspace / Settings /
REM SaaS / Skills / Glossary, responsive window). Builds the exe from source when it
REM is missing OR out of date, then falls back to the lightweight PS1 picker.

set "HERE=%~dp0"
set "EXE=%HERE%Hydra.exe"
set "SRC=%HERE%Hydra.cs"

REM ---- decide whether to (re)build: missing exe OR source newer than exe ----
set "NEEDBUILD="
if not exist "%EXE%" set "NEEDBUILD=1"
if exist "%EXE%" if exist "%SRC%" (
    set "NEWEST="
    for /f "delims=" %%i in ('dir /b /o-d "%SRC%" "%EXE%" 2^>nul') do if not defined NEWEST set "NEWEST=%%i"
    if /i "!NEWEST!"=="Hydra.cs" set "NEEDBUILD=1"
)

REM ---- build the exe when needed ----
if defined NEEDBUILD (
    if exist "%SRC%" (
        set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        if not exist "!CSC!" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
        if exist "!CSC!" (
            echo Building Hydra, one moment...
            set "RES="
            if exist "%HERE%bot.ico" set "RES=/win32icon:"%HERE%bot.ico" /resource:"%HERE%bot.ico",bot.ico"
            if exist "%HERE%bot.png" set "RES=!RES! /resource:"%HERE%bot.png",bot.png"
            "!CSC!" /nologo /target:winexe /out:"%EXE%" !RES! /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll "%SRC%"
        )
    )
)

REM ---- launch the modern GUI, or fall back to the PS1 picker ----
if exist "%EXE%" (
    start "" "%EXE%"
) else (
    echo Full GUI unavailable - no .NET Framework compiler found. Using the lightweight launcher.
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%HERE%Hydra.ps1"
)
endlocal
