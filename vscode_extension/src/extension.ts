import { ExtensionContext, commands, window } from "vscode";

import * as path from "path";
import * as fs from "fs";

import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions
} from "vscode-languageclient/node";

let client: LanguageClient;

export function activate(context: ExtensionContext) {
    let jails_executable = `jails-${process.platform}-${process.arch}`;
    if (process.platform == "win32") {
        jails_executable += ".exe";
    }

    const extensionPath = context.extensionPath;
    const devServerPath = path.normalize(`${extensionPath}/out/${jails_executable}`);

    if (!fs.existsSync(devServerPath)) {
        window.showErrorMessage(`Jails on ${process.platform}-${process.arch} is not yet supported. But you can build Jails yourself https://github.com/SogoCZE/Jails?tab=readme-ov-file#vs-code.`);
        process.exit();
    }

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
