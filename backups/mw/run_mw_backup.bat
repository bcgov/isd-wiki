@echo off
REM =========================================
REM MediaWiki Backup - Task Scheduler Wrapper
REM =========================================

REM Set working directory explicitly
cd /d C:\Users\chridodd\backups\mw

REM -----------------------
REM Set Git Bash path
REM -----------------------
set "GITBASH=C:\Program Files\Git\bin\bash.exe"

REM -----------------------
REM Path to MediaWiki backup script
REM -----------------------
set "SCRIPT=/c/Users/chridodd/backups/mw/mw-backup.sh"

REM -----------------------
REM Ensure LOGDIR exists and use absolute path
REM -----------------------
set "LOGDIR=C:\Users\chridodd\backups\mw\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

REM Format date/time for filename: YYYYMMDD_HHMMSS
for /f "tokens=1-4 delims=/ " %%a in ('date /t') do set mydate=%%c%%a%%b
for /f "tokens=1-3 delims=:." %%a in ("%TIME%") do (
    set mytime=%%a%%b%%c
)
set "LOGFILE=%LOGDIR%\mw-backup-%mydate%_%mytime%.log"

REM -----------------------
REM Log start
REM -----------------------
echo Backup started at %DATE% %TIME% > "%LOGFILE%"

REM -----------------------
REM Run the script and log output
REM Use --login (-l) so Git Bash reads .bashrc/.bash_profile
REM -----------------------
"%GITBASH%" -l -c "%SCRIPT%" >> "%LOGFILE%" 2>&1

REM -----------------------
REM Log end
REM -----------------------
echo Backup finished at %DATE% %TIME% >> "%LOGFILE%"

