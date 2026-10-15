@echo off
cd /d "%~dp0"
godot --path "%cd%" %*
