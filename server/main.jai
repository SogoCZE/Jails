VERSION :: "1.0.0";

PROJECT_FOLDER_PATH :: #run join(path_strip_filename(#file), "..");
METAPROGRAM_PATH :: #run tprint("%/metaprogram", PROJECT_FOLDER_PATH);

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

find_jai_path :: () -> string {
    result: Process_Result;
    raw_path: string;
    err: string;

    #if OS == .WINDOWS {
        result, raw_path, err = run_command("where.exe", "jai", capture_and_return_output=true);
        path_overwrite_separators(raw_path, #char "/");
        raw_path = trim(raw_path);
    } else {
        result, raw_path, err = run_command("whereis", "-q", "jai", capture_and_return_output=true);
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

    array_add(*server.local_modules, ..config.local_modules);
    server.roots = config.roots;
    server.build_root = config.build_root;

    if config.jai_path.count > 0 {
        server.args.jai_path = config.jai_path; 
    }
}

handle_request :: (request: LSP_Request_Message, raw_request: string) {
    log("Got %", request.method);

    if request.method == {
        case "shutdown";
            server.quit = true;
            lsp_respond(request.id, null);
        case "initialize";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Initialize);
            if !success {
                log_error("Unable to parse initialize message");
                // @Incomplete: report error back!
                return;
            }

            log("Root URI: %", body.params.rootUri.*);
            log("Root Path: %", body.params.rootPath.*);

            server.project_root = body.params.rootPath.*;

            load_config_file();

            if server.build_root.count == 0 {
                server.build_root = find_entry_file(server.project_root);
            }

            if server.roots.count == 0 {
                server.roots = .[find_entry_file(server.project_root)];
            }

            // Include $workingDirectory/modules as a default local module path. @TODO: is this good?
            array_add(*server.local_modules, "modules");

            log("Server.local_modules: %", server.local_modules);
            log("Server.roots: %", server.roots);

            for root: server.roots {
                absolute_path: string;
                if starts_with(root, "/") {
                    absolute_path = root;
                } else {
                    absolute_path = join(server.project_root, root, separator="/");
                }

                absolute_path = normalize_path(absolute_path);
                parse_file(absolute_path, true);
            }

            analyze_files();

            to_send: LSP_Result_Initialize;
            lsp_respond(body.id, to_send);

        case "textDocument/definition";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Definition);
            if !success {
                log_error("Unable to parse textDocument/definition message");
                return;
            }

            handle_goto(body);

        case "textDocument/didSave";
            success, body := json_parse_string(raw_request, LSP_Did_Save_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/divSave message");
                return;
            }

            run_diagnostics();

            file_path := normalize_path(body.params.textDocument.uri);

            parse_file(file_path, true);
            analyze_files();

        case "textDocument/didOpen";
            success, body := json_parse_string(raw_request, LSP_Did_Open_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri);
            content := body.params.textDocument.text;

            create_memory_file(file_path, content);
            
            parse_file(file_path);
            analyze_files();

            log("File_path: %", file_path);

        case "textDocument/didChange";
            success, body := json_parse_string(raw_request, LSP_Did_Change_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/didChange message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri);
            edit_memory_file(file_path, body.params.contentChanges);
            parse_file(file_path, true);
            analyze_files();

        case "textDocument/didClose";
            success, body := json_parse_string(raw_request, LSP_Did_Close_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/dicClose message");
                return;
            }

            file_path := normalize_path(body.params.textDocument.uri);
            remove_memory_file(file_path);

        case "textDocument/completion";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Completion);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            handle_completitions(body);

        case "textDocument/signatureHelp";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Signature_Help);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            handle_signature_help(body);
        
        case "textDocument/hover";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Hover);
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
        server.args.jai_path = find_jai_path();
        log("Jai path: %", server.args.jai_path);
    }

    log("Args are %", server.args);

    init(*server.files);
    defer deinit(*server.files);

    init_memory_files();
    defer deinit_memory_files();

    while !server.quit {
        body, success := read_message_from_stdin();
        if !success {
            log("Failed to read message. Skipping.");
            continue;
        }

        parseOK, request := json_parse_string(body, LSP_Request_Message);
        if !parseOK {
            log_error("Unable to parse as json:\n%\n\n", body);
            continue;
        }

        handle_request(request, body);

        // reset_temporary_storage();
    }

    log("Shutdown");
    exit(0);
}

// @TODO: Move this to some utils file or something?
array_reverse :: (array: []$T) {
    temp: T;
    start := 0;
    end := array.count-1;

    while start < end {
        temp = array[start];  
        array[start] = array[end];
        array[end] = temp;
        start += 1;
        end -= 1;
    }
}

#import "Compiler";
#import "Basic";
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
