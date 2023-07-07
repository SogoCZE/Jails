VERSION :: "1.0.0";

Args :: struct {
    verbose: bool;
    profile: bool;
    jai_path: string;
}

Server :: struct {
    args: Args;
    quit := false;

    // This is from the config file
    local_modules: []string;
    roots: []string;

    project_root: string;
    files: Table(string, *Program_File);

    memory_files_lock: Mutex;
    memory_files: Table(string, [..]u8); // @todo: This is probably dumb - store files as array of lines instead (is this good idea?) // @ToDo: Keep track of a modified flag per file
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

find_jai_path :: () -> string {
    raw_path: string;
    #if OS == .WINDOWS {
        _, raw_path = run_command("where.exe", "jai", capture_and_return_output=true);
        path_overwrite_separators(raw_path, #char "/");
        raw_path = trim(raw_path);
    } else {
        _, raw_path = run_command("whereis", "-q", "jai", capture_and_return_output=true);
        raw_path = trim(raw_path);

        BUFFER_SIZE :: 4096;  
        buf: [BUFFER_SIZE] u8;

        length := readlink(to_c_string(raw_path), buf.data, BUFFER_SIZE);
        if length > 0 {
            raw_path = to_string(buf.data);
        }
    }

    // @TODO: error that we cant find jai path
    if raw_path.count == 0 return "";
    
    path := split(raw_path, "/");

    pop(*path); // jai.exe or jai
    pop(*path); // bin

    return join(..path, separator="/");
}

load_config_file :: () {
    
    Config :: struct {
        local_modules: []string;
        roots: []string;
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

    server.local_modules = config.local_modules;
    server.roots = config.roots;

    if config.jai_path.count > 0 {
        server.args.jai_path = config.jai_path; 
    }
}

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

            log("Root URI: %", body.params.rootUri.*);
            log("Root Path: %", body.params.rootPath.*);

            server.project_root = body.params.rootPath.*;

            load_config_file();

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

            file_path := normalize_path(body.params.textDocument.uri);

            parse_file(file_path, true);

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
    }

    log("Args are %", server.args);

    init(*server.files);
    defer deinit(*server.files);

    init_memory_files();
    defer deinit_memory_files();

    while !server.quit {
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

        // reset_temporary_storage();
    }

    log("Shutdown");
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
#import "String";
#import "Shared_Memory_Channel";
#import "Hash_Table";
#import "Random";
#import "Process";
#import "Reflection";
#import "Thread";
#import "jai_parser";

#load "rpc.jai";
#load "lsp_interface.jai";
#load "program.jai";
#load "memory_files.jai";
#load "render.jai";

#load "completition.jai";
#load "goto.jai";

#if OS == .WINDOWS {
    #import "Windows";
} else {
    #import "POSIX";
}
