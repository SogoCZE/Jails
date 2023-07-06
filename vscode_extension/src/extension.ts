import { ExtensionContext, window } from "vscode";

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
        outputChannel: window.createOutputChannel("Jai Language Server"),
    };

    client = new LanguageClient(
        "jails", "Jai Language Server", serverOptions, clientOptions
    );

    client.start();
}


export function deactivate() {
    if (!client) {
        return undefined;
    }

    return client.stop();
}
