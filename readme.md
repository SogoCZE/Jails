# Jails
Jails is an experimental language server for the Jai programming language. 

## Features
- Basic Go-To Definition
- Autocomplete for available symbols (types, procedures etc)
- Signature help for procedure calls

In the future, the language server will support all other basic stuff you would get from any other LSP. Also, the plan is to support some specific Jai features from an editor support perspective like for example macro evaluation inside the editor etc. 

## Usage
Be aware that this language server is still pretty much unstable... Nonetheless, it can be quite useful even in this early stage of development. 

### Building
Compile the release version of the server with `jai build - -release`. Jails binary will be generated in the `bin` folder.

### VSCode
1. You need to [build](#building) Jails and install npm dependencies inside `vscode_extension` with `npm i`
2. Run `npm run compile` to generate an extension bundle
3. Run `npm run pack:unix` or `npm run pack:windows`.

This process will create `jails-x.x.x.vsix` which you can install and use.

### Config file
You can create a config file to specify:
- `roots` (`main.jai`, `build.jai`) - this is used to set up files that are being parsed on init - you don't need to set this but it will improve your experience.
- `local modules` (`modules`) - this tells the language server to also search for modules in these folders.
- `build_root` - entry file for compiling (currently used for running compiler diagnostics - errors in the editor)

```json
{
    "local_modules": [
        "modules"
    ],
    "roots": [
        "server/main.jai",
        "build.jai"
    ],
    "build_root": "build.jai"
}
```

## Run (dev)
Compile server with `jai build.jai` or compile and run test VSCode with preinstalled LSP with `jai build.jai - -vscode`.

## Dependencies
- [jai_parser](https://github.com/SogoCZE/jai_parser)
- [Jason](https://github.com/rluba/jason)
- [Jai unicode](https://github.com/rluba/jai-unicode)
- [Tracy](https://github.com/rluba/jai-tracy) (profiling)