@echo off
REM =========================================
REM Patroni PostgreSQL Backup - Batch Wrapper
REM =========================================


REM Path to Git Bash
set "GITBASH=C:\Program Files\Git\bin\bash.exe"

REM Full path to the backup script (.sh)
set "SCRIPT=/c/Users/chridodd/backups/db/backup-patroni-db.sh"

REM Optional: log output (creates logs folder if it doesn't exist)
set "LOGDIR=C:\Users\chridodd\backups\db\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

REM Format date/time for filename: YYYYMMDD_HHMMSS
for /f "tokens=1-4 delims=/ " %%a in ('date /t') do set mydate=%%c%%a%%b
for /f "tokens=1-3 delims=:." %%a in ("%TIME%") do (
    set mytime=%%a%%b%%c
)
set "LOGFILE=%LOGDIR%\backup-%mydate%_%mytime%.log"

REM Log start
echo Backup started at %DATE% %TIME% > "%LOGFILE%"

REM Run the script and log output
"%GITBASH%" -c "%SCRIPT%" >> "%LOGFILE%" 2>&1

REM Log end
echo Backup finished at %DATE% %TIME% >> "%LOGFILE%"
