@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" -Action Install -Launch zh-Hans
if errorlevel 1 pause
