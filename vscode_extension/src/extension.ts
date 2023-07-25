import { ExtensionContext, commands, window } from "vscode";

import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions
} from "vscode-languageclient/node";

let client: LanguageClient;

export function activate(context: ExtensionContext) {
    var isWin = process.platform === "win32";
    const pathDelimeter = isWin ? "\\" : "/";

    const devServerPath = __dirname.replace(`vscode_extension${pathDelimeter}out`, `bin`) + pathDelimeter + "jails" + (isWin ? ".exe" : "");

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
        return undefined;
    }

    return client.stop();
}
