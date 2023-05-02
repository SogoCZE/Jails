Program :: struct {
    imported_modules: [..]Module;
    imported_files: [..]Source_File;

    declarations_by_serial: Table(ID, *Declaration);
    declarations_by_name: Table(string, *Declaration);

    code_blocks: [..]*Block;
    code_blocks_by_serial: Table(ID, *Block);
}

init_program :: (program: Program) {
    init(*program.declarations_by_serial);
    init(*program.declarations_by_name);
    init(*program.code_blocks_by_serial);
}

deinit_program :: (program: Program) {
    deinit(*program.declarations_by_serial);
    deinit(*program.declarations_by_name);
    deinit(*program.code_blocks_by_serial);
}

reset_program :: (program: Program) {
    table_reset(*program.declarations_by_name);
    table_reset(*program.declarations_by_serial);
    table_reset(*program.code_blocks_by_serial);

    array_reset(*program.imported_modules);
    array_reset(*program.imported_files);
    array_reset(*program.code_blocks);
}

Project_Workspace :: struct {
    index: u8;
    
    entry: string;
    working_directory: string;
    local_modules_directory: string;
    
    last_refresh_time: Apollo_Time = APOLLO_TIME_INVALID;

    import_path: []string;

    previously_errored_file: string;

    program_a: Program;
    program_b: Program;

    work_program: *Program;
    program: *Program;   
}

init_workspace :: (workspace: *Project_Workspace, entry: string, index: u8, local_modules_directory: string = "") {
    workspace.index = index;
    workspace.entry = entry;
    workspace.working_directory = path_strip_filename(entry);

    if local_modules_directory.count > 0 {
        workspace.local_modules_directory = local_modules_directory;
    } else {
        workspace.local_modules_directory = find_local_modules(workspace.working_directory);
    }

    init_program(workspace.program_a);
    init_program(workspace.program_b);

    workspace.work_program = *workspace.program_b;
    workspace.program = *workspace.program_a;
}

deinit_workspace :: (workspace: *Project_Workspace) {
    deinit_program(*workspace.program_a);
    deinit_program(*workspace.program_b);
}

path_in_imported_modules_or_files :: (workspace: *Project_Workspace, path: string) -> bool {
    for module: workspace.program.imported_modules {
        if contains(path, tprint("/modules/%", module.name)) return true;
    }

    for file: workspace.program.imported_files {
        if contains(path, file.path) && file.project return true;
    }

    return false;
}

find_struct_or_enum_member :: (workspace: *Project_Workspace, base: *Declaration, name: string) -> *Declaration {
    block: *Block;

    if base.kind == {
        case .ENUM; block = get_block(workspace, cast(*Enum) base);
        case .STRUCT; block = get_block(workspace, cast(*Struct) base);

        case; return null;
    }

    if !block return null;

    for get_block_declarations(workspace, block) {
        log("name % %", it.name, it.location);
        if it.name != name continue;
        return it;
    }

    return null;
}

get_block :: (workspace: *Project_Workspace, _struct: *Struct) -> *Block {
    block, ok := table_find(*workspace.program.code_blocks_by_serial, _struct.block);
    if !ok return null;
    return block;
}

get_block :: (workspace: *Project_Workspace, _enum: *Enum) -> *Block {
    block, ok := table_find(*workspace.program.code_blocks_by_serial, _enum.block);
    if !ok return null;
    return block;
}

get_block :: (workspace: *Project_Workspace, procedure: *Procedure) -> *Block {
    block, ok := table_find(*workspace.program.code_blocks_by_serial, procedure.body);
    if !ok return null;
    return block;
}

get_type_declaration :: (workspace: *Project_Workspace, base_type_or_serial_to: Base_Type_Or_Serial_To) -> *Declaration {
    if base_type_or_serial_to.type_kind == {
        case .BASE; #through;
        case .ARRAY; return null; // @TODO: What do we do about this one??

        case .SERIAL; return get_declaration(workspace, base_type_or_serial_to.serial_to);
        case .POINTER; 
            decl := get_declaration(workspace, base_type_or_serial_to.serial_to);
            assert(decl != null && decl.kind == .TYPE_INSTANTIATION);
            return get_type_declaration(workspace, (cast(*Type_Instantiation) decl).type);
    }

    return null;
}

get_block_declarations :: (workspace: *Project_Workspace, block: *Block) -> []*Declaration {
    declarations := NewArray(block.declarations.count, *Declaration);
    for block.declarations {
        decl := get_declaration(workspace, it);
        assert(decl != null);
        declarations[it_index] = decl;
    }

    return declarations;
}

get_declaration :: (workspace: *Project_Workspace, serial: ID) -> *Declaration {
    decl, ok := table_find(*workspace.program.declarations_by_serial, serial);
    if !ok return null;
    return decl;
}

find_declarations :: (workspace: *Project_Workspace, name: string, available_from_file: string, available_from_block: *Block) -> []*Declaration {
    decls := table_find_multiple(*workspace.program.declarations_by_name, name);
    if decls.count == 0 {
        return .[];
    }

    declarations: [..]*Declaration;

    // Scope related
    if available_from_block {
        for decl: decls {
            if decl.flags & .IS_GLOBAL continue;
            
            decl_block := find_block(workspace, decl.location.l0, decl.location.c0, decl.location.file);
            if !decl_block || decl_block.serial != available_from_block.serial continue;

            array_add(*declarations, decl);
        }

        // Look into arguments of procedure or struct
        available_from_block_parent, ok := table_find(*workspace.program.declarations_by_serial, available_from_block.parent);
        if ok {
            procedure := cast(*Procedure) available_from_block_parent;

            for argument_id: procedure.arguments {
                argument, ok := table_find(*workspace.program.declarations_by_serial, argument_id);

                if argument.name == name {
                    array_add(*declarations, argument);
                }
            }
        }
    }

    // Globals
    for decl: decls {
        if !(decl.flags & .IS_GLOBAL) continue;
        if decl.flags & .SCOPE_FILE && available_from_file != decl.location.file continue;
        array_add(*declarations, decl);
    }

    return declarations;
}

declaration_to_lsp_location :: (decl: Declaration) -> LSP_Location {
    uri := decl.location.file;
    // #if OS == .WINDOWS then uri = slice(uri, 3, uri.count-1);

    range: LSP_Range;
    range.start.line      = xx max(decl.location.l0-1, 0);
    range.start.character = xx max(decl.location.c0-1, 0);
    range.end.line        = xx ifx decl.location.l1 < decl.location.l0 then max(decl.location.l0-1, 0) else max(decl.location.l1-1, 0);
    range.end.character   = xx ifx decl.location.c1 < decl.location.c0 then max(decl.location.c0-1, 0) else max(decl.location.c1-1, 0);

    return .{
        uri=uri,
        range=range,
    };
}

// Find nearest block by line, char and file
// @todo: make this more robust and cleaver (this is initial experimental implementation)
find_block :: (workspace: *Project_Workspace, line: s32, char: s32, file: string) -> *Block {
    nearest_block: *Block;

    is_in_range :: (loc: Declaration.Location, line: s32, char: s32) -> bool {
        if loc.l0 > line || loc.l1 < line return false;

        if loc.l0 == line && loc.c0 > char return false;
        if loc.l1 == line && loc.c1 < char return false;

        return true;
    }

    for block: workspace.program.code_blocks {
        if block.serial == 0 continue;

        block_file := block.location.file;
        file_final := file;
        #if OS == .WINDOWS  {
            // TODO: Fix this! This is total non-sense.
            block_file = replace(replace(block_file, "c:", ""), "C:", "c:");
            file_final = replace(replace(file_final, "c:", ""), "C:", "c:");
        }

        if block_file != file_final {
            continue;
        }

        // If the location is not present in the block we skip.
        if !is_in_range(block.location, line, char) continue;

        // Skip if, while, empty ... blocks
        parent, parent_exists := table_find(*workspace.program.declarations_by_serial, block.parent);
        if !parent_exists continue;

        // If we are not smaller than so far nearest block we skip.
        if nearest_block {
            if !is_in_range(nearest_block.location, block.location.l0, block.location.c0) continue;
            if !is_in_range(nearest_block.location, block.location.l1, block.location.c1) continue;
        }

        nearest_block = block;
    }

    return nearest_block;
}

reset_diagnostics :: (workspace: *Project_Workspace) {
    if workspace.previously_errored_file {
        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = workspace.previously_errored_file,
                diagnostics = LSP_Diagnostic.[]
            }
        });
    }
}

// Currently, parse only the first error (maybe parsing multiple errors is not that useful because Jai mostly report one error at a time)
// @TODO: Make it work with multiple errors
// @todo: add support for warnings
send_compiler_errors_as_diagnostics :: (workspace: *Project_Workspace, output: string) {
    lines := split(output, "\n");

    file: string;
    diagnostic: LSP_Diagnostic;

    ERROR_MARKER :: ": Error:";
    // Get the first error
    for output_line: lines {
        if !contains(output_line, ERROR_MARKER) continue;

        message_index := find_index_from_right(output_line, ERROR_MARKER);
        message := slice(output_line, message_index + ERROR_MARKER.count, output_line.count - message_index);
        rest := slice(output_line, 0, message_index);
        
        ok: bool;
        location: string;
        ok, file, location = split_from_right(rest, ":");
        if !ok continue;

        line_and_character := split(location, ",");
        if line_and_character.count < 2 continue;

        line, l_ok := parse_int(*line_and_character[0], u32);
        if !l_ok continue;

        character, c_ok := parse_int(*line_and_character[1], u32);
        if !c_ok continue;

        diagnostic.message = message;
        diagnostic.serverity = xx LSP_Diagnostic_Severity.ERROR;

        diagnostic.range.start.line = line-1;
        diagnostic.range.start.character = character-1;
    }

    highlight_found := false;
    highlighted_chars: u32;

    for line: lines {
        if highlight_found || !contains(line, #char "^") continue;

        for char: cast([]u8) line {
            if char != #char "^" continue;
            highlighted_chars += 1;
        }

        highlight_found = true;
    }

    diagnostic.range.end.line = diagnostic.range.start.line;
    diagnostic.range.end.character = diagnostic.range.start.character+highlighted_chars;

    diagnostics: [1]LSP_Diagnostic;
    diagnostics[0] = diagnostic;

    lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
        method="textDocument/publishDiagnostics",
        params = .{
            uri = file,
            diagnostics = diagnostics
        }
    });

    workspace.previously_errored_file = file;
}

refresh_program :: (workspace: *Project_Workspace, send_diagnostics := false) -> success: bool, error: string {
    // @Stability @Incomplete: This modifies structs also modified by the cache thread!!
    // So this needs to take a lock or something!
    start := current_time_consensus();
    result: Process_Result;
    output: string;
    error: string;

    command: [..] string;
    array_add(*command, "jai");
    if server.args.profile {
        array_add(*command,
            tprint("%/modules/Default_Metaprogram.jai", server.args.jai_path), // Tell the Default_Metaprogram (Inception level 0) to compile the Default_Metaprogram (Inception level 1)...
            "-quiet", "-no_color", "-no_cwd", // (+ some basic args for Inception level 0)
            "-plug", "tracy", "-modules", "-import_dir", METAPROGRAM_MODULES_PATH, // ... but use the tracy module to instrument Inception level 1
        );
        if workspace.local_modules_directory {
            array_add(*command, "-import_dir", workspace.local_modules_directory);
        }
        array_add(*command, "-", workspace.entry, "-plug", "jails"); // ... and tell Inception level 1 to compile the actual entry point while using our JAILS metaprogram which will be instrumented by tracy
    } else {
        array_add(*command, workspace.entry, "-quiet", "-no_color", "-plug", "jails");
        if workspace.local_modules_directory {
            array_add(*command, "-import_dir", workspace.local_modules_directory);
        }
    }


    array_add(*command, "-", "-channel_id", tprint("%", server.args.channel_id), "-workspace", tprint("%", workspace.index)); // Add unique shared memory channel ID @TOOD: is there way how to more easily transform u64 to string? @TODO: test this with the tracy pipeline.
    array_add(*command, "---", "import_dir", METAPROGRAM_MODULES_PATH); // Import dir for the initial Default_Metaprogram so that it can find our plugins (tracy for Inception level 0 if we’re profiling or Jails if we’re not profiling).

    result, output, error = run_command(..command, working_directory=workspace.working_directory, capture_and_return_output=true);

    if send_diagnostics {
       reset_diagnostics(workspace);
    }

    if result.exit_code != 0 {
        log_error("Could not run jai compiler: %\nError: %\nOutput: %", result, error, output);

        if send_diagnostics {
            send_compiler_errors_as_diagnostics(workspace, error);
        }

        return false, error;
    }

    end := current_time_consensus();
    duration_ms := to_milliseconds(end - start);

    workspace.last_refresh_time = APOLLO_TIME_INVALID;
    // @Stability @Incomplete: This reads structs also modified by the cache thread!!
    // It needs to wait for a signal from the cache thread that all messages have been received!?
    log("Cache refreshed in %ms! Nodes: %", duration_ms, workspace.work_program.declarations_by_name.count);

    if server.args.verbose {
        log("Compiler stdout: %", output);
        log_error("Compiler stderr: %", error);
    }

    // Swap programs
    Swap(*workspace.program, *workspace.work_program);
    reset_program(workspace.work_program);

    return true, "";
}

listen_to_metaprogram :: (thread: *Thread) -> s64 {
    channel_name := tprint("%-%", IPC_CHANNEL_NAME_FROM_META, server.args.channel_id);

    #if OS != .WINDOWS {
        POSIX :: #import "POSIX";
        POSIX.shm_unlink(channel_name.data);
    }

    success, channel := reader_create_channel(channel_name, CHANNEL_DATA_BYTES);
    if !success {
        return -1;
    }

    defer reader_release_channel(*channel);

    messages_read := 0;
    write_channel: Write_Channel;
    while !server.quit {
        message_success, fatal_error, message := reader_poll_for_message(*channel);

        if fatal_error {
            log_error("Fatal error");
            return -1;
        }

        if !message_success {
            // @ToDo: We should probably not busy-loop here all the time.
            // Instead we could use a semaphore to only wait for messages after kicking of a compile command.
            sleep_milliseconds(10);
            continue;
        }

        defer {
            reader_done_with_message(*message);
            messages_read += 1;
        }

        bytes := message.user_read_bytes;
        if bytes < JAILS_HEADER_SIZE {
            log_error("Got a message that is too short (% bytes)! Quitting.", bytes);
            return -1;
        }

        success, workspace_index, command, body_bytes := decode_mesage_header(message, Protocol_Tag);
        if !success return -1;

        workspace := *server.workspaces[workspace_index];

        if command == {
            case .INITIALIZATION;

                initialization := deserialize(body_bytes, Initialization);
                workspace.import_path = initialization.import_path;

                // Disabled for now. Probably broken because of workspace changes. This will be useful when the compiler support replacing files. @TODO: Fix this.
                // write_channel_success: bool;
                // write_channel_success, write_channel = writer_connect(tprint("%-%", IPC_CHANNEL_NAME_TO_META, server.args.channel_id));

                // if !write_channel_success {
                //     log_error("Could not open write channel to metaprogram.");
                //     return -1;
                // }

                // Send all (modified) files to the metaprogram
                // @Stability: This only works because the metaprogram doesn’t send anything while
                // it waits for files. If this ever changes, we need to move the sending to a separate thread
                // or we might deadlock.

                // { 
                //     lock(*server.modified_files_lock);
                //     defer unlock(*server.modified_files_lock);

                //     for server.modified_files {
                //         message: Modified_File;
                //         message.path = it_index;
                //         message.content = it;
                //         send_to_metaprogram(*write_channel, .MODIFIED_FILE, *message);
                //     }

                //     send_to_metaprogram(*write_channel, .DONE, null);
                // }

            case .MODULE_IMPORT;
                module := deserialize(body_bytes, Module);
                array_add(*workspace.work_program.imported_modules, module);

            case .FILE;
                file := deserialize(body_bytes, Source_File);
                // create_file(file.path, read_entire_file(file.path));
                array_add(*workspace.work_program.imported_files, <<file);

            case .STRUCT; add_to_program(workspace, body_bytes, Struct);
            case .PROCEDURE; add_to_program(workspace, body_bytes, Procedure);
            case .TYPE_INSTANTIATION; add_to_program(workspace, body_bytes, Type_Instantiation);
            case .EXPRESSION; add_to_program(workspace, body_bytes, Expression);
            case .ENUM; add_to_program(workspace, body_bytes, Enum);
            case .BLOCK; add_to_program(workspace, body_bytes, Block);
        }
    }

    return 0;
}

add_to_program :: (workspace: *Project_Workspace, bytes: []u8, $type: Type) {
    data := deserialize(bytes, type);

    #if type == Block {
        array_add(*workspace.work_program.code_blocks, data);
        table_set(*workspace.work_program.code_blocks_by_serial, data.serial, data);
    } else {
        table_set(*workspace.work_program.declarations_by_serial, data.serial, data);
        table_add(*workspace.work_program.declarations_by_name, data.name, data);
    }
}

send_to_metaprogram :: (channel: *Write_Channel, command: Server_To_Metaprogram_Protocol_Tag, data: *$T) {
    assert(channel != null);

    data_bytes: [] u8;
    if data data_bytes = serialize(data);

    while true {
        message_success, message := writer_reserve_message(channel, JAILS_HEADER_SIZE + data_bytes.count);
        if !message_success {
            sleep_milliseconds(1);
            continue;
        }

        message.user_write_pointer[0] = cast(u8) command;
        checksum: u8;

        for byte, index: data_bytes {
            message.user_write_pointer[JAILS_HEADER_SIZE + index] = byte;
            checksum ^= byte;
        }

        message.user_write_pointer[1] = checksum;

        writer_commit_message(channel, message);
        break;
    }
}
