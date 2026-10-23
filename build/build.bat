setlocal

echo.
echo === Running Package Script ===
echo.

:: Run setup.ps1 lcoated in the 'bin' directory
Powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0package.ps1"

echo.
pause
