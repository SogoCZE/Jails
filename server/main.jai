// @TODO:
// - Code block context
// - Workspaces
// - Improve or remake entry point detection
// - Autocomplete
//     - procedures (params etc)
//     - structs (members etc)
// - Error reporting (that shoud be quite easy)

VERSION :: "1.0.0";

PROJECT_FOLDER_PATH :: #run join(path_strip_filename(#file), "..");
METAPROGRAM_MODULES_PATH :: #run tprint("%/metaprogram_modules", PROJECT_FOLDER_PATH);

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

declaration_to_lsp_location :: (decl: Declaration) -> LSP_Location {
    uri := decl.location.file;

    #if OS == .WINDOWS {
        uri = slice(uri, 3, uri.count-1);
    }

    decrement_or_zero :: inline (number: int) -> u32 {
        if number <= 0 return 0;
        return xx (number-1);
    }

    range: LSP_Range;
    range.start.line = decrement_or_zero(decl.location.l0);
    range.start.character = decrement_or_zero(decl.location.c0);
    range.end.line = decrement_or_zero(decl.location.l1);
    range.end.character = decrement_or_zero(decl.location.c1);

    return .{
        uri=uri,
        range=range,
    };
}

last_change_time: Apollo_Time = APOLLO_TIME_INVALID;

refresh_if_needed :: () {
    if last_change_time == APOLLO_TIME_INVALID return;

    // @Incomplete: We want to use the last_change_time to debounce.
    // But since we’re blocking on messages right now, we can’t use a timeout to start recompiling.
    // So we just use last_change_time as dirty flag.

    success := run_metaprogram_analysis();
    if !success return;
}

handle_request :: (request: LSP_Request_Message, raw_request: string) {
    log("Got %", request.method);

    if request.method == {
        case "shutdown";
            quit = true;
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

            program_cache.working_directory       = <<body.params.rootPath;
            program_cache.entry                   = find_entry_file(program_cache.working_directory);
            program_cache.local_modules_directory = find_local_modules(program_cache.working_directory);

            log("Entry file: %/%", program_cache.working_directory, program_cache.entry);


            {
                success, error_details := run_metaprogram_analysis();
                if !success {
                    lsp_respond_with_error(body.id, .PARSE_ERROR, "Could not run Jails metaprogram", error_details);
                    return;
                }
            }

            to_send: LSP_Result_Initialize;
            lsp_respond(body.id, to_send);

        case "textDocument/definition";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Definition);
            if !success {
                log_error("Unable to parse textDocument/definition message");
                return;
            }

            refresh_if_needed();
            handle_goto(body);

        case "textDocument/didSave";
            success, body := json_parse_string(raw_request, LSP_Did_Save_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            // @ToDo: Remove all changes from the "modified files" table so we don’t send that file over on ever compile?

            success = run_metaprogram_analysis();
            if !success return;

        case "textDocument/didOpen";
            success, body := json_parse_string(raw_request, LSP_Did_Open_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            file_path := body.params.textDocument.uri;
            content := body.params.textDocument.text;

            create_file(file_path, content);

        case "textDocument/didChange";
            success, body := json_parse_string(raw_request, LSP_Did_Change_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/didChange message");
                return;
            }

            file_path := body.params.textDocument.uri;
            edit_file(file_path, body.params.contentChanges);

            last_change_time = current_time_consensus();

        case "textDocument/completion";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Completion);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            refresh_if_needed();
            handle_completitions(body);

    }
}

quit := false;

Args :: struct {
    verbose: bool;
    profile: bool;
    jai_path: string = #run find_current_jai_path();
}

args: Args;

main :: () {
    context.logger = lsp_log;

    success: bool;
    success, args = parse_arguments(Args);
    if !success {
        log_error("Could not parse arguments");
        exit(1);
    }

    log("Args are %", args);

    init_cache();
    defer deinit_cache();

    init_files();
    defer deinit_files();

    thread := New(Thread);
    thread_init(thread, listen_to_metaprogram);
    defer {
        thread_deinit(thread);
        free(thread);
    }
    thread_start(thread);

    while !quit {
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

#load "../shared/binary_serialization.jai";
#load "../shared/shared.jai";

#import "Basic";
#import "Command_Line";
#import "File";
#import "File_Utilities";
#import "jason";
#import "String";
#import "Shared_Memory_Channel";
#import "Thread";
#import "Hash_Table";
#import "Process";
#import "Reflection";

#load "rpc.jai";
#load "lsp_interface.jai";
#load "cache.jai";
#load "files.jai";
#load "completition.jai";
#load "goto.jai";
