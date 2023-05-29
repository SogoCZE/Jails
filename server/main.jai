VERSION :: "1.0.0";

PROJECT_FOLDER_PATH :: #run join(path_strip_filename(#file), "..");
METAPROGRAM_MODULES_PATH :: #run tprint("%/metaprogram_modules", PROJECT_FOLDER_PATH);

Args :: struct {
    verbose: bool;
    profile: bool;
    channel_id: u64;
    jai_path: string = #run find_current_jai_path();
}

Server :: struct {
    args: Args;
    quit := false;

    project_root: string;
    workspaces: []Project_Workspace;

    modified_files_lock: Mutex;
    modified_files: Table(string, [..]u8); // @todo: This is probably dumb - store files as array of lines instead (is this good idea?) // @ToDo: Keep track of a modified flag per file
}

server: Server;

// @TODO: make this more robust?
// There is workaround for modules because they teoreticly dont have workspace.
// We need to track module cache somewhere seperated from the workspace user cache.
// It will also eliminate duplicated module cache across workspaces and also speedup
// metaprogram processing time.
find_workspace_by_path :: (path: string) -> *Project_Workspace {
    for * workspace: server.workspaces {
        if !contains(path, workspace.working_directory) /*&& !path_in_imported_modules_or_files(workspace, path)*/ {
            continue;
        }

        return workspace;
    }

    return *server.workspaces[0];
}

Workspace_Config :: struct {
    entry: string;
    local_modules: string;
}

Config :: struct {
    entry: string;
    workspaces: []Workspace_Config;
}

// @TODO: This is temporary solution until we will figure better way how to do it.
// It would be good to look at LSP workspace feature
load_config_file :: (root: string) -> bool, Config {
    config_path := join(root, "/jails.json");
    if !file_exists(config_path) return false, .{};

    config_content := read_entire_file(config_path);

    ok, config := json_parse_string(config_content, Config);
    if !ok {
        log("Failed to parse config file!");
        return false, .{};
    }

    return true, config;
}

setup_workspaces :: (root: string) {
    ok, config := load_config_file(root);
    if ok {
        server.workspaces = NewArray(config.workspaces.count, Project_Workspace);

        for workspace_config: config.workspaces {
            absolute_entry := join(root, trim(workspace_config.entry, "/"), separator = "/");

            absolute_modules: string;
            if workspace_config.local_modules.count > 0 {
                absolute_modules = join(root, trim(workspace_config.local_modules, "/"), separator = "/");
            }

            init_workspace(*server.workspaces[it_index], absolute_entry, xx it_index, absolute_modules);
        }

        return;
    }

    // When we dont have a config backup to the old entry resolution.
    // @TODO: In the future we need to improve this to properly resolve workspaces even without config.
    entry := find_entry_file(root);
    server.workspaces = NewArray(1, Project_Workspace);
    init_workspace(*server.workspaces[0], entry, 0);
}

find_entry_file :: (root: string) -> string {

    contains_main_procedure :: (file: string) -> bool {
        content := read_entire_file(file);
        return contains(content, "main ::") || contains(content, "main::");
    }

    // @Fixme: This does not take the root into account!
    COMMON_MAIN_PATH :: string.["/src/main.jai", "main.jai"]; // Maybe build.jai ... etc?

    for path: COMMON_MAIN_PATH {
        if file_exists(path) && contains_main_procedure(path) {
            return path;
        }
    }

    files := file_list(root, true);

    for file: files {
        if contains(file, "main.jai") && contains_main_procedure(file) {
            return file;
        }
    }

    for file: files {
        if contains_main_procedure(file) {
            return file;
        }
    }

    return ""; // What we gonna do when we do not find any
}

// @ToDo: This is a very, very temporary solution:
find_local_modules :: (root: string) -> string {
    DIRS_TO_CHECK :: string.["modules", "Local_Modules"];
    for DIRS_TO_CHECK {
        modules_path := sprint("%/%", root, it);
        if is_directory(modules_path) return modules_path;

        free(modules_path);
    }

    return "";
}

// refresh_program_if_needed :: (workspace: *Project_Workspace) {
//     if workspace.last_refresh_time == APOLLO_TIME_INVALID return;

//     // @Incomplete: We want to use the workspace.last_refresh_time to debounce.
//     // But since we’re blocking on messages right now, we can’t use a timeout to start recompiling.
//     // So we just use workspace.last_refresh_time as dirty flag.

//     success := refresh_program(workspace);
//     if !success return;
// }

handle_request :: (request: LSP_Request_Message, raw_request: string) {
    log("Got %", request.method);

    if request.method == {
        case "shutdown";
            server.quit = true;
        case "initialize";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Initialize);
            if !success {
                log_error("Unable to parse initialize message");
                // @Incomplete: report error back!
                return;
            }

            log("Workspace Folders: %", <<body.params.workspaceFolders);
            log("Root URI: %", <<body.params.rootUri);
            log("Root Path: %", <<body.params.rootPath);

            server.project_root = <<body.params.rootPath;

            setup_workspaces(server.project_root);

            for * workspace: server.workspaces {
                log("Workspace #%: %", it_index, workspace.working_directory);
                log("Entry file: %", workspace.entry);

                // success, error_details := refresh_program(workspace);
                // if !success {
                    // lsp_respond_with_error(body.id, .PARSE_ERROR, tprint("Could not run initial metaprogram run", workspace.entry), error_details);
                    // return; // We cant return here because LSP client is waiting for response - if he wont get one the editor thinks the LSP crashed...
                // }                
            }

            to_send: LSP_Result_Initialize;
            lsp_respond(body.id, to_send);

        case "textDocument/definition";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Definition);
            if !success {
                log_error("Unable to parse textDocument/definition message");
                return;
            }

            // refresh_program_if_needed();
            handle_goto(body);

        case "textDocument/didSave";
            success, body := json_parse_string(raw_request, LSP_Did_Save_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            // @ToDo: Remove all changes from the "modified files" table so we don’t send that file over on ever compile?

            file_path := body.params.textDocument.uri;

            workspace := find_workspace_by_path(file_path);
            if !workspace return;

            parse_file(workspace, file_path);

            // success = refresh_program(workspace, true);
            // if !success return;

        case "textDocument/didOpen";
            success, body := json_parse_string(raw_request, LSP_Did_Open_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            file_path := body.params.textDocument.uri;
            content := body.params.textDocument.text;

            create_modified_file(file_path, content);
            
            workspace := find_workspace_by_path(file_path);
            if !workspace return;

            parse_file(workspace, file_path);

        case "textDocument/didChange";
            success, body := json_parse_string(raw_request, LSP_Did_Change_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/didChange message");
                return;
            }

            file_path := body.params.textDocument.uri;
            edit_modified_file(file_path, body.params.contentChanges);

            workspace := find_workspace_by_path(file_path);
            if !workspace return;

            parse_file(workspace, file_path);

            workspace.last_refresh_time = current_time_consensus();


        case "textDocument/didClose";
            success, body := json_parse_string(raw_request, LSP_Did_Close_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/dicClose message");
                return;
            }
            
            log("Close!");

        case "textDocument/completion";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Completion);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            // refresh_program_if_needed();
            handle_completitions(body);

    }
}

main :: () {
    context.logger = lsp_log;

    success: bool;
    success, server.args = parse_arguments(Args);
    if !success {
        log_error("Could not parse arguments");
        exit(1);
    }

    if server.args.channel_id == 0 {
        #if OS == .WINDOWS {
            process_id := cast(u64) GetCurrentProcessId();
        } else {
            process_id := cast(u64) getpid();
        }
        server.args.channel_id = process_id;
    }

    log("Args are %", server.args);

    init_modified_files();
    defer deinit_modified_files();

    // thread := New(Thread);
    // thread_init(thread, listen_to_metaprogram);
    // defer {
    //     thread_deinit(thread);
    //     free(thread);
    // }
    // thread_start(thread);

    while !server.quit {
        reset_temporary_storage();

        body, success := get_message();
        if !success {
            log("Failed to read message");
            continue;
        }

        parseOK, request := json_parse_string(body, LSP_Request_Message);
        if !parseOK {
            log_error("Unable to parse as json:\n%\n\n", body);
            continue;
        }

        handle_request(request, body);
    }

    for * workspace: server.workspaces {
        deinit_workspace(workspace);
    }

    log("Shutdown");
}

find_current_jai_path :: () -> string {
    Compiler :: #import "Compiler";
    options := get_build_options();
    for options.import_path {
        if find_index_from_left(it, "jai/modules") != -1 {
            modules_path := remove_trailing_slash(it);
            base_path := remove_trailing_slash(path_strip_filename(modules_path));
            log("% -> %", modules_path, base_path);
            return base_path;
        }
    }

    return "";

    remove_trailing_slash :: (path: string) -> string {
        result := path;
        if path[path.count - 1] == #char "/" result.count -= 1;
        return result;
    }
}

// #load "../shared/binary_serialization.jai";
// #load "../shared/shared.jai";

#import "Compiler";
#import "Basic";
#import "Command_Line";
#import "File";
#import "File_Utilities";
#import "jason";
#import "String";
#import "Shared_Memory_Channel";
#import "Thread";
#import "Hash_Table";
#import "Random";
#import "Process";
#import "Reflection";
#import "File_Watcher";
#import "jai_parser";

#load "rpc.jai";
#load "lsp_interface.jai";
#load "program.jai";
#load "modified_files.jai";
#load "cursor_context.jai";

#load "completition.jai";
#load "goto.jai";

#if OS == .WINDOWS {
    #import "Windows";
} else {
    #import "POSIX";
}
