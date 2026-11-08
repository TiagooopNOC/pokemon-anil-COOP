@echo off
cd /d "%~dp0"
where py >nul 2>nul
if errorlevel 1 (
  echo No se encontro Python. Instala Python 3.10 o posterior y vuelve a abrir este archivo.
  pause
  exit /b 1
)
py -3 -B tools\launch_menu.py
if errorlevel 1 (
  echo.
  echo El inicio fallo. Copia el mensaje de error que aparece arriba.
  pause
)
