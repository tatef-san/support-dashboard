@echo off
cd /d "C:\Users\t.atef\OneDrive - ISM eGroup\Dashboard"
git add index.html
git commit -m "Dashboard update %date% %time%"
git push origin main
echo.
echo Done! GitHub Pages will update in ~1 minute.
echo URL: https://tatef-san.github.io/support-dashboard/
pause
