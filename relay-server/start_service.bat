@echo off
cd /d "d:\Antigravity Companion\relay-server"
"C:\Program Files\nodejs\node.exe" dist\index.js >> service.log 2>&1
