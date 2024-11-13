import { ExtensionContext, commands, window } from "vscode";

import * as path from "path";

import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions
} from "vscode-languageclient/node";

let client: LanguageClient;

export function activate(context: ExtensionContext) {
    let jails_executable: string;
    switch (process.platform) {
        case "darwin":
            jails_executable = "jails_mac";
            break;
        case "win32":
            jails_executable = "jails_win.exe";
            break;
        // case "linux":
        //     jails_executable = "jails_linux";
        //     break;
        default:
            window.showErrorMessage(`Platform ${process.platform} is not yet supported. But can build Jails yourself https://github.com/SogoCZE/Jails?tab=readme-ov-file#vs-code.`);
            process.exit();
    }

    const extensionPath = context.extensionPath;
    const devServerPath = path.normalize(`${extensionPath}/out/${jails_executable}`);

    let serverOptions: ServerOptions = {
        command: devServerPath,
        args: [],
    };

    let clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: "file", language: "jai" }],
    };

    client = new LanguageClient(
        "jails", "Jai Language Server", serverOptions, clientOptions
    );

    commands.registerCommand("jails.start", () => client.start());
    commands.registerCommand("jails.stop", async () => await client.stop());
    commands.registerCommand("jails.restart", async () => await client.restart());

    client.start();
}

export function deactivate() {
    if (!client) {
        return;
    }

    return client.stop();
}
