@echo off
cd /d "%~dp0"

REM Pull latest changes
git pull origin main

REM Add & commit
git add .
git commit -m "Auto Backup on %date% %time%"
git push origin main

echo Backup complete on %date% %time%"
