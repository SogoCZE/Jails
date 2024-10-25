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
    release := array_find(args, "-release");
    arm := array_find(args, "-arm");

    ok: bool;

    // Server
    {
        w := compiler_create_workspace("Server");

        options := get_build_options(w);
        copy_commonly_propagated_fields(get_build_options(), *options);
        options.output_executable_name = "jails";
        options.output_path = "./bin";
        options.import_path = import_path;

        if release set_optimization(*options, .OPTIMIZED);

        if arm options.cpu_target = .ARM64;

        set_build_options(options, w);

        tracy: *Metaprogram_Plugin;
        if profile_server {
            // log("Adding tracy plugin");
            // Tracy :: #import "tracy";
            // tracy = Tracy.get_plugin();
            // tracy.workspace = w;

            // assert(tracy.handle_one_option != null);
            // tracy.handle_one_option(tracy, .["-modules"], 0);
            // tracy.handle_one_option(tracy, .["-min_size", "0"], 0);
        }

        flags: Intercept_Flags;
        if tracy && tracy.before_intercept tracy.before_intercept(tracy, *flags);

        compiler_begin_intercept(w, flags);
        if tracy && tracy.add_source tracy.add_source(tracy);
        add_build_file("./server/main.jai", w);
        ok = message_loop(w, args, tracy);
        compiler_end_intercept(w);

        if tracy && tracy.finish tracy.finish(tracy);
        if tracy && tracy.shutdown tracy.shutdown(tracy);
    }

    // When we provide -vscode argument automatically launch vscode with our extension installed.
    if ok && launch_vscode {
        vscode_extension_directory := join(get_working_directory(), "/vscode_extension");
        vscode_extension_development_path := join("--extensionDevelopmentPath=", vscode_extension_directory);

        print("%\n", vscode_extension_development_path);

        assert(OS == .WINDOWS || OS == .MACOS, "Opening vscode on Linux is not supported at the time.");

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

message_loop :: (w: Workspace, args: []string, tracy: *Metaprogram_Plugin) -> bool {
    options := get_build_options(w);

    while true {
        message := compiler_wait_for_message();
        if tracy && tracy.message tracy.message(tracy, message);
        if message.kind != .COMPLETE continue;

        if options.os_target == .MACOS macos_codesign(w);

        complete := cast(*Message_Complete) message;
        if complete.error_code != .NONE {
            return false;
        }

        break;
    }

    return true;
}

// CodeSign for MacOS instruments
macos_codesign :: (w: Workspace) {
    build_options := get_build_options(w);
    executable_path := tprint("%/%", build_options.output_path, build_options.output_executable_name);
    run_command("codesign", "-s", "-", "-v", "-f", "--entitlements", "./debug.plist", executable_path);
}

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";
#import "Process";
#import "System";
