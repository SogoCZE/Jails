jai build.jai - -release
if %errorlevel% neq 0 exit /b %errorlevel%

cd vscode_extension

npm run compile && npm run pack:windows && code --install-extension .\jails-0.2.0.vsix

cd ..
