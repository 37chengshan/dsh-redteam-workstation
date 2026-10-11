@echo off
set FARM=C:\Users\YOURUSER\.dsh\profiles\node_modules\@deepseek-ai
if not exist "%FARM%" ( echo NOT_FOUND & exit /b 0 )
set /a n=0
for /d %%D in ("%FARM%\*") do (
  rmdir "%%D" 2>nul
  set /a n+=1
)
echo REMOVED=%n%
rmdir "%FARM%" 2>nul
if exist "%FARM%" ( echo STILL_EXISTS ) else ( echo GONE )
