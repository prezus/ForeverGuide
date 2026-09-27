@echo off
rem ============================================================
rem ForeverGuide / tools\sync_to_github.cmd
rem Push whatever changed in this addon folder to GitHub.
rem Double-click after editing (or run from a terminal):
rem     tools\sync_to_github.cmd            commit message = "update <date time>"
rem     tools\sync_to_github.cmd "message"  your own commit message
rem The first run sets the folder up as a git checkout of the repo and
rem pulls what is already there; git will ask you to sign in to GitHub
rem in the browser once (Git Credential Manager).
rem Needs Git for Windows: https://git-scm.com/download/win
rem ============================================================
setlocal
set REPO=https://github.com/RevoltLive85/ForeverGuide.git
cd /d "%~dp0.."
where git >nul 2>nul || (echo Git is not installed. Get it from https://git-scm.com/download/win & pause & exit /b 1)

if not exist ".git" (
    echo Setting this folder up as a checkout of %REPO% ...
    git init -b main || git init
    git remote add origin %REPO%
    git fetch origin
    git reset --soft origin/main 2>nul
)

rem the beta overwrites SavedVariables at every reload: harvest what the addon recorded first
where python >nul 2>nul && (
    python tools\merge_recorded.py >nul 2>nul && echo contributed data merged into data-src\forever.json
    python tools\collect_reports.py >nul 2>nul
)

set MSG=%~1
if "%MSG%"=="" set MSG=update %date% %time%
git add -A
rem commit as the identity you set in git, never the Windows login name
git config user.name >nul 2>nul || goto noidentity
git commit -m "%MSG%" >nul 2>nul && echo committed: %MSG% || echo nothing new to commit
git pull --rebase origin main
git push -u origin main || (echo push failed - see the message above & pause & exit /b 1)
echo done.
timeout /t 3 >nul
exit /b 0

:noidentity
echo Set a git identity first (it is shown on every commit):
echo     git config --global user.name "your GitHub name"
echo     git config --global user.email "you@users.noreply.github.com"
pause
exit /b 1
