# Jails
Jails is an experimental language server for the Jai programming language. 

## Features
- Basic Go-To Definition
- Autocomplete for available symbols (types, procedures etc)
- Signature help for procedure calls
- Error reporting from the compiler

In the future, the language server will support all other basic stuff you would get from any other LSP. Also, the plan is to support some specific Jai features from an editor support perspective like for example macro evaluation inside the editor etc. 

### When using a custom Build program
By default, Jails does not generate any output files, however, when using a custom build program it will output whatever your build program is set to. In that case, you should disable the output on your own, by combining `JAILS_DIAGNOSTICS_BUILD` with `#exists` to detect if it is build by the LSP.
```
#if #exists(JAILS_DIAGNOSTICS_BUILD) options.output_type = .NO_OUTPUT;
```

If you happen to have more than one layer of meta programms triggering, you can do the following:

```
default_metaprogram_command_lind := get_build_options(1).compile_time_command_line;
found, index := array_find(default_metaprogram_command_lind, "jails_diagnostics");
if found  child_options.output_type = .NO_OUTPUT;
```


## Usage
Be aware that this language server is still pretty much unstable... Nonetheless, it can be quite useful even in this early stage of development.

### Cloning
This repo uses git submodules. Clone it using `git clone --recurse-submodules`.

### Building
Compile the release version of the server with `jai build.jai - -release`. Jails binary will be generated in the `bin` folder.

### VS Code
Jails for VS Code can be downloaded from [VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=ApparentlyStudio.jails) or you can build it yourself. The prebuilt version supports x64 Windows and ARM64 MacOS at the moment.

#### Manual build

1. Make sure this repo is your working directory (e.g. `cd Jails`).
2. Run `npm install --global @vscode/vsce` to install the Visual Studio Code Extension Manager.
3. Run `jai build.jai - -release` to build the binary.
4. Run `cd vscode_extension` to enter the subdirectory `vscode_extension`.
5. Run `npm install` to install npm dependencies.
6. Run `npm run compile` to generate an extension bundle.
7. Run `npm run pack:unix` or `npm run pack:windows` to pack the bundle into a file called something like `jails-x.x.x.vsix`.
8. Run `code --install-extension jails-x.x.x.vsix` to install the extension in VS Code.

### Config file
You can create a config file `jails.json` inside your project root to specify:
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
