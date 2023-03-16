#import "Basic";
#import "Compiler";
#import "File";
#import "String";
#import "Process";

// Základní build file
#run {
    w := compiler_create_workspace("Target Program");
    if !w {
        print("Workspace creation failed.\n");
        return;
    }

    options := get_build_options(w);
    options.output_executable_name = "jlsp";
    options.output_path = "./bin";   

    set_build_options(options, w);

	make_directory_if_it_does_not_exist("./bin/");

    compiler_begin_intercept(w);

    add_build_file("./src/main.jai", w); 

    message_loop(w, options.compile_time_command_line);

    compiler_end_intercept(w);

    set_build_options_dc(.{do_output=false});
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

    // Tohle by nemělo být povinné.. (TODO: zapínat jen přes argument)
    vscode_extension_directory := replace(get_working_directory(), "server", "vscode_extension");
    vscode_extension_development_path := join("--extensionDevelopmentPath=", vscode_extension_directory);
    
    assert(OS == .WINDOWS || OS == .MACOS, "Openning vscode on Linux is not supported at the time.");

    vscode_path: string;

    if OS == .WINDOWS {
        vscode_path = "C:/Users/sogoc/AppData/Local/Programs/Microsoft VS Code/Code.exe";
    } 

    if OS == .MACOS {
        vscode_path = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code";
    }

    run_command(vscode_path, "--profile=lsp_dev", vscode_extension_development_path);
}   