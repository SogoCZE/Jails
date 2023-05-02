#run {
    set_build_options_dc(.{do_output=false});

    make_directory_if_it_does_not_exist("./bin/");

    root_options := get_build_options();
    args := root_options.compile_time_command_line;
	import_path: [..] string;
    array_add(*import_path, .. root_options.import_path);
    array_add(*import_path, "./modules");

    profile_server := array_find(args, "-profile_server");
    launch_vscode := array_find(args, "-vscode");

    // Metaprogram Library
    {
        w := compiler_create_workspace("Metaprogram library");

        options := get_build_options(w);
        copy_commonly_propagated_fields(get_build_options(), *options);
        options.output_type = .DYNAMIC_LIBRARY;
        options.output_executable_name = "jails_metaprogram_library";
        options.output_path = "./metaprogram_modules";
        options.import_path = import_path;
        set_build_options(options, w);

        compiler_begin_intercept(w);
        add_build_file("./metaprogram/library.jai", w);
        message_loop(w, args, null);
        compiler_end_intercept(w);
    }


    // Server 
    {
        w := compiler_create_workspace("Server");

        options := get_build_options(w);
        copy_commonly_propagated_fields(get_build_options(), *options);
        options.output_executable_name = "jails";
        options.output_path = "./bin";
        options.import_path = import_path;
        set_build_options(options, w);

        tracy: *Metaprogram_Plugin;
        if profile_server {
            log("Adding tracy plugin");
            Tracy :: #import "tracy";
            tracy = Tracy.get_plugin();
            tracy.workspace = w;

            assert(tracy.handle_one_option != null);
            tracy.handle_one_option(tracy, .["-modules"], 0);
            tracy.handle_one_option(tracy, .["-min_size", "0"], 0);
        }

        flags: Intercept_Flags;
        if tracy && tracy.before_intercept tracy.before_intercept(tracy, *flags);

        compiler_begin_intercept(w, flags);
        if tracy && tracy.add_source tracy.add_source(tracy);
        add_build_file("./server/main.jai", w);
        message_loop(w, args, tracy);
        compiler_end_intercept(w);

        if tracy && tracy.finish tracy.finish(tracy);
        if tracy && tracy.shutdown tracy.shutdown(tracy);
    }

    // When we provide -vscode argument automatically launch vscode with our extension installed.
    if launch_vscode {
        vscode_extension_directory := join(get_working_directory(), "/vscode_extension");
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
            if !file_exists(vscode_path) {
                vscode_path = "C:/Program Files/Microsoft VS Code/Code.exe"; // Try program files in case it's installed for all users
            }
        }

        if OS == .MACOS {
            vscode_path = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code";
        }

        run_command(vscode_path, "--profile=jails_dev", vscode_extension_development_path);
    }
}

message_loop :: (w: Workspace, args: []string, tracy: *Metaprogram_Plugin) {
    while true {
        message := compiler_wait_for_message();
        if tracy && tracy.message tracy.message(tracy, message);
        if message.kind != .COMPLETE continue;

        complete := cast(*Message_Complete) message;
        if complete.error_code != .NONE {
            return;
        }

        break;
    }
}

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";
#import "Process";
#import "System";
