@echo off
title Sync Utilities
echo Syncing master utils.js with index.html and index.test.html...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync_utils.ps1"
pause
