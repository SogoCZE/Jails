# Jails
Jails is an experimental language server for the Jai programming language. 

## Features
It currently support basic GOTO with some problems. But its the thing currently being worked on. In the future the LSP will support completions and all other basic stuff you would get from any other LSP. Also the plan is to support some specific Jai features from editor support perspective like for example macro evaluation inside editor etc. 

## Run (dev)
Compile server with `jai build.jai` or compile and run test VSCode with preinstalled LSP with `jai build.jai - -vscode`.

## Dependencies
- [jai_parser](https://github.com/SogoCZE/jai_parser)
- [Jason](https://github.com/rluba/jason)
- [Tracy](https://github.com/rluba/jai-tracy) (profiling)