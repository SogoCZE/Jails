VERSION :: "1.0.0";

MEMORY_DEBUG :: false;

Args :: struct {
    verbose: bool;
    profile: bool;
    jai_path: string;
}

Server :: struct {
    args: Args;
    quit := false;

    // This is from the config file
    local_modules: [..]string;
    roots: []string;
    build_root: string;

    project_root: string;
    files: Table(string, *Program_File);
    files_to_be_analyzed: [..]*Program_File;

    memory_files_lock: Mutex;
    memory_files: Table(string, [..]u8); // @todo: This is probably dumb - store files as array of lines instead (is this good idea?) // @ToDo: Keep track of a modified flag per file

    previously_errored_file: string;

    diagnostics_metaprogram_path: string;
}

server: Server;

// @TODO: move this to somewhere else
is_hex_digit :: (c: u32) -> bool {
    return (c >= #char "a" && c <= #char "f") || (c >= #char "A" && c <= #char "F") || (c >= #char "0" && c <= #char "9");
}

// @TODO: move this to somewhere else
decode_url :: (url: string) -> string {
    out_url := copy_string(url);

    i, j: int;
    hex: [2]u8 = .[#char "0", #char "0"];

    while i < out_url.count {

        defer {
            i += 1;
            j += 1;
        }

        if out_url[i] != #char "%" || out_url[i+1] == 0 {
            out_url[j] = out_url[i];
            continue;
        }

        if is_hex_digit(out_url[i+1]) && is_hex_digit(out_url[i+2]) {
            hex[0] = out_url[i+1];
            hex[1] = out_url[i+2];

            out_url[j] = xx string_to_int(xx hex, 16);
            i += 2;
        }


    }
    out_url.count = j;

    return out_url;
}

find_entry_file :: (root: string) -> string {

    contains_main_procedure :: (file: string) -> bool {
        content := read_entire_file(file);
        return contains(content, "main ::") || contains(content, "main::");
    }

    // @Fixme: This does not take the root into account!
    COMMON_MAIN_PATH :: string.["/src/main.jai", "main.jai"]; // Maybe build.jai ... etc?

    for path: COMMON_MAIN_PATH {
        if file_exists(join(root, path, separator = "/")) && contains_main_procedure(path) {
            return path;
        }
    }

    files := file_list(root, true);

    for file: files {
        if contains(file, "main.jai") && contains_main_procedure(file) {
            return replace(file, root, "");
        }
    }

    for file: files {
        if contains_main_procedure(file) {
            return replace(file, root, "");
        }
    }

    return ""; // TODO: What we gonna do when we do not find any?
}

find_jai_path :: (executable_name: string) -> string {
    result: Process_Result;
    raw_path: string;
    err: string;

    #if OS == .WINDOWS {
        result, raw_path, err = run_command("where.exe", executable_name, capture_and_return_output=true);
        path_overwrite_separators(raw_path, #char "/");
        raw_path = trim(raw_path);
    } else {
        #if OS == .MACOS {
            result, raw_path, err = run_command("whereis", "-q", executable_name, capture_and_return_output=true);
        } else { // Linux does not have the -q argument.
            result, raw_path, err = run_command("whereis", executable_name, capture_and_return_output=true);
        }

        raw_path = trim(raw_path);

        BUFFER_SIZE :: 4096;
        buf: [BUFFER_SIZE] u8;

        length := readlink(to_c_string(raw_path), buf.data, BUFFER_SIZE);
        if length > 0 {
            raw_path = to_string(buf.data);
        }
    }

    // @TODO: error that we cant find jai path
    if raw_path.count == 0 {
        log_error("Error while resolving Jai path % %.", result, err);

        #if OS == .MACOS {
            if executable_name == "jai-macos" return "";
            return find_jai_path("jai-macos");
        } else #if OS == .LINUX {
            if executable_name == "jai-linux" return "";
            return find_jai_path("jai-linux");
        }

        return "";
    }

    path := split(raw_path, "/");

    pop(*path); // jai.exe or jai
    pop(*path); // bin

    return join(..path, separator="/");
}

load_config_file :: () {
    Config :: struct {
        local_modules: []string;
        roots: []string;
        build_root: string;
        jai_path: string;
    }

    config_path := join(server.project_root, "/jails.json");
    if !file_exists(config_path) return;

    config_content := read_entire_file(config_path);

    ok, config := json_parse_string(config_content, Config);
    if !ok {
        log("Failed to parse config file!");
        return;
    }

    for config.local_modules {
        array_add_if_unique(*server.local_modules, it);
    }

    server.roots = config.roots;
    server.build_root = config.build_root;

    if config.jai_path.count > 0 {
        server.args.jai_path = config.jai_path;
    }
}

create_diagnostics_metaprogram :: () {
    METAPROGRAM_SOURCE := #run -> string {
        project_dir := join(path_strip_filename(#file), "..");
        metaprogram_dir := tprint("%/metaprogram", project_dir);
        return read_entire_file(tprint("%/jails_diagnostics.jai", metaprogram_dir));
    };

    jails_exe_dir := trim_right(path_strip_filename(get_path_of_running_executable()), "/");
    metaprogram_dir := sprint("%/metaprogram", jails_exe_dir);
    if !make_directory_if_it_does_not_exist(metaprogram_dir) {
        log_error("Failed to create metaprogram directory!");
        return;
    }

    metaprogram_source_file_path := tprint("%/jails_diagnostics.jai", metaprogram_dir);

    if !write_entire_file(metaprogram_source_file_path, METAPROGRAM_SOURCE) {
        log_error("Failed to create metaprogram file!");
        return;
    }

    server.diagnostics_metaprogram_path = metaprogram_dir;
    log("Metaprogram file created! (%)", metaprogram_source_file_path);
}

handle_request :: (request: LSP_Request_Message, raw_request: string) {
    log("Got %", request.method);

    if request.method == {
        case "shutdown";
            server.quit = true;
            lsp_respond(request.id, null);
        case "initialize";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Initialize,, temp);
            if !success {
                log_error("Unable to parse initialize message");
                // @Incomplete: report error back!
                return;
            }

            create_diagnostics_metaprogram();

            log("Root URI: %", body.params.rootUri.*);
            log("Root Path: %", body.params.rootPath.*);

            server.project_root = copy_string(body.params.rootPath.*);

            load_config_file();

            if server.build_root.count == 0 {
                server.build_root = find_entry_file(server.project_root);
            }

            if server.roots.count == 0 {
                server.roots = .[find_entry_file(server.project_root)];
            }

            // Include $workingDirectory/modules as a default local module path (like a compiler)
            array_add_if_unique(*server.local_modules, "modules");

            log("Server.local_modules: %", server.local_modules);
            log("Server.roots: %", server.roots);

            for root: server.roots {
                absolute_path: string;
                if starts_with(root, "/") {
                    absolute_path = root;
                } else {
                    absolute_path = join(server.project_root, root, separator="/",, temp);
                }

                absolute_path = normalize_path(absolute_path,, temp);
                parse_file(absolute_path, true);
            }

            // Parse Runtime Support and Preload
            {
                parse_file(tprint("%/modules/Runtime_Support.jai", server.args.jai_path), true);
                parse_file(tprint("%/modules/Preload.jai", server.args.jai_path), true);
            }

            analyze_files();

            to_send: LSP_Result_Initialize;
            lsp_respond(body.id, to_send);

        case "textDocument/definition";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Definition,, temp);
            if !success {
                log_error("Unable to parse textDocument/definition message");
                return;
            }

            handle_goto(body);

        case "textDocument/didSave";
            success, body := json_parse_string(raw_request, LSP_Did_Save_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/divSave message");
                return;
            }

            run_diagnostics();

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            parse_file(file_path, true);
            analyze_files();

        case "textDocument/didOpen";
            success, body := json_parse_string(raw_request, LSP_Did_Open_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            content := body.params.textDocument.text;

            create_memory_file(file_path, content);

            parse_file(file_path);
            analyze_files();

            log("File_path: %", file_path);

        case "textDocument/didChange";

            success, body := json_parse_string(raw_request, LSP_Did_Change_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/didChange message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);
            edit_memory_file(file_path, body.params.contentChanges);
            parse_file(file_path, true);
            analyze_files();

        case "textDocument/didClose";
            success, body := json_parse_string(raw_request, LSP_Did_Close_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/dicClose message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri,, temp);
            remove_memory_file(file_path);

        case "textDocument/completion";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Completion,, temp);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            handle_completitions(body);

        case "textDocument/signatureHelp";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Signature_Help,, temp);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            handle_signature_help(body);

        case "textDocument/hover";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Hover,, temp);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            handle_hover(body);
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

    if server.args.jai_path.count == 0 {
        server.args.jai_path = find_jai_path("jai");
        log("Jai path: %", server.args.jai_path);
    }

    log("Args are %", server.args);

    init(*server.files);
    defer deinit(*server.files);

    server.files_to_be_analyzed.allocator = context.default_allocator;

    init_memory_files();
    defer deinit_memory_files();

    while !server.quit {
        body, success := read_message_from_stdin(,, temp);
        if !success {
            log("Failed to read message. Skipping.");
            continue;
        }

        parseOK, request := json_parse_string(body, LSP_Request_Message,, temp);
        if !parseOK {
            log_error("Unable to parse as json:\n%\n\n", body);
            continue;
        }

        handle_request(request, body);

        reset_temporary_storage();
        #if MEMORY_DEBUG report_memory_leaks();
    }

    log("Shutdown");
    exit(0);
}

#import "Compiler";
#import "Basic"()(MEMORY_DEBUGGER=MEMORY_DEBUG);
#import "Command_Line";
#import "File";
#import "File_Utilities";
#import "jason";
#import "unicode_utils";
#import "String";
#import "Shared_Memory_Channel";
#import "Hash_Table";
#import "Random";
#import "Process";
#import "Reflection";
#import "Thread";
#import "Pool";
#import "jai_parser";
#import "Default_Allocator";
#import "System";

#load "rpc.jai";
#load "lsp_interface.jai";
#load "program.jai";
#load "memory_files.jai";

#load "completition.jai";
#load "goto.jai";
#load "signature_help.jai";
#load "hover.jai";

#if OS == .WINDOWS {
    #import "Windows";
} else {
    #import "POSIX";
}
