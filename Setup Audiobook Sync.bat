@echo off
title Audiobook Sync - Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-Audiobooks.ps1" -Setup
