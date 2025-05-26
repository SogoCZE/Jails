# Jetbrains IDE configuration

Enabling Jai support in Jetbrains products is currently a two-step approach.

1. Code navigation and LSP support is done by installing and configure LSP4IJ plugin to point to `jails.exe`
2. Syntax highlighting is done by configuring the IDE's Textmate bundle support to point to the Textmate bundle included in the Jails repository.

Currently, both of the steps above require cloning the Jails repository to your local machine (or downloading the repository and unpacking it).

Let's do that pre-requisite step first.

## Clone the jails repository

Change to a directory where you would like the jails directory to be located.
Ex: `c:\myprojects`
```
cd <your_projects_dir>
git clone git@github.com:SogoCZE/Jails.git
```

Ensure you have the latest jai.exe downloaded, unpacked and preferably on the path.

Build Jails
```
cd <your_projects_dir>\jails
jai build.jai
```

This will create a `jails.exe` file in the `bin` directory.

## Configure LSP4IJ

### Install
- Open the Jetbrains IDE.
- Open settings > plugins.
- Go to Marketplace.
- Search for LSP4IJ.
- Install the plugin.
- Restart the IDE.

### Configure
- Click on the `Language Servers` icon on the sidebar OR open View > Tool Windows > Language Servers.
- Click the `New Language Server` button OR right-click in the LSP Consoles section and choose `New Language Server`.
- In the `Server` tab:
  - Name: Jails
  - Command: `<path_to_jails_dir>\bin\jails.exe`
- In the `Mapping` tab:
  - Go to `File Name Patterns`
  - Click the `+` button.
  - Put `*.jai` in the `File Name Pattern` field.
- Click OK.

**Optional:**
- You can add `-verbose` after the `jails.exe` command to get more verbose output the communications between the IDE and the language server.

## Configure Textmate bundle

- Open the Jetbrains IDE.
- Open settings > editor > Textmate bundles.
- Click the `+` button.
- Select the `<path_to_jails_dir>\vscode_extension` folder from the Jails repository and click `Select Folder`.
