@echo off
rem Start the desktop calendar widget without a console window
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0widget.ps1"
