#import "Basic";
#import "Compiler";
#import "File";
#import "String";
#import "Process";
#import "System";

// Basic build file
#run {
    set_build_options_dc(.{do_output=false});

    w := compiler_create_workspace("Target Program");

    make_directory_if_it_does_not_exist("./bin/");

    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);
    options.output_executable_name = "jls";
    options.output_path = "./bin";

	import_path: [..] string;
    array_add(*import_path, .. options.import_path);
    array_add(*import_path, "../modules");
    options.import_path = import_path;

    set_build_options(options, w);

    compiler_begin_intercept(w);

    add_build_file("./src/main.jai", w);

    message_loop(w, options.compile_time_command_line);

    compiler_end_intercept(w);
}

message_loop :: (w: Workspace, args: []string) {
    while true {
        message := compiler_wait_for_message();
        if message.kind != .COMPLETE continue;

        complete := cast(*Message_Complete) message;
        if complete.error_code != .NONE {
            return;
        }

        break;
    }

    // When we provide -vscode argument automatically launch vscode with our extension installed.
    if args.count > 2 && args[2] == "-vscode" {
        vscode_extension_directory := join(get_working_directory(), "/../vscode_extension");
        vscode_extension_development_path := join("--extensionDevelopmentPath=", vscode_extension_directory);

        print("%\n", vscode_extension_development_path);

        assert(OS == .WINDOWS || OS == .MACOS, "Openning vscode on Linux is not supported at the time.");

        vscode_path: string;

        if OS == .WINDOWS {
            username, ok := get_username();
            if !ok {
                log_error("Cannot resolve Windows username. Cannot launch vscode.");
                return;
            }

            vscode_path = tprint("C:/Users/%/AppData/Local/Programs/Microsoft VS Code/Code.exe", username);
        }

        if OS == .MACOS {
            vscode_path = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code";
        }

        run_command(vscode_path, "--profile=lsp_dev", vscode_extension_development_path);
    }

}
