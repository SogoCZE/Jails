VERSION :: "1.0.0";

Args :: struct {
    verbose: bool;
    profile: bool;
    jai_path: string = #run find_current_jai_path();
}

Server :: struct {
    args: Args;
    quit := false;

    project_root: string;
    files: Table(string, *Program_File);

    memory_files_lock: Mutex;
    memory_files: Table(string, [..]u8); // @todo: This is probably dumb - store files as array of lines instead (is this good idea?) // @ToDo: Keep track of a modified flag per file
}

server: Server;

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

            log("Root URI: %", <<body.params.rootUri);
            log("Root Path: %", <<body.params.rootPath);

            server.project_root = <<body.params.rootPath;

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

            file_path := body.params.textDocument.uri;

            parse_file(file_path);

        case "textDocument/didOpen";
            success, body := json_parse_string(raw_request, LSP_Did_Open_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            file_path := body.params.textDocument.uri;
            content := body.params.textDocument.text;

            create_memory_file(file_path, content);
            
            parse_file(file_path);

        case "textDocument/didChange";
            success, body := json_parse_string(raw_request, LSP_Did_Change_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/didChange message");
                return;
            }

            file_path := body.params.textDocument.uri;
            edit_memory_file(file_path, body.params.contentChanges);

            parse_file(file_path, true);

        case "textDocument/didClose";
            success, body := json_parse_string(raw_request, LSP_Did_Close_Text_Document);
            if !success {
                log_error("Unable to parse textDocument/dicClose message");
                return;
            }
            
            file_path := body.params.textDocument.uri;
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
    }

    log("Shutdown");
}

find_current_jai_path :: () -> string {
    Compiler :: #import "Compiler";
    options := get_build_options();

    remove_trailing_slash :: (path: string) -> string {
        result := path;
        if path[path.count - 1] == #char "/" result.count -= 1;
        return result;
    }

    for options.import_path {
        if find_index_from_left(it, "jai/modules") != -1 {
            modules_path := remove_trailing_slash(it);
            base_path := remove_trailing_slash(path_strip_filename(modules_path));
            log("% -> %", modules_path, base_path);
            return base_path;
        }
    }

    return "";
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

#load "completition.jai";
#load "goto.jai";

#if OS == .WINDOWS {
    #import "Windows";
} else {
    #import "POSIX";
}
