setlocal

echo.
echo === Running Setup Script ===
echo.

:: Run setup.ps1 lcoated in the 'bin' directory
Powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\DC Initial Setupv2.95.ps1"

echo.
pause
