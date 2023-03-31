Program :: struct {
    imported_modules: [..]Module;
    imported_files: [..]Source_File;

    declarations: [..]Declaration;
    declarations_by_serial: Table(ID, *Declaration);
    declarations_by_name: Table(string, *Declaration);

    code_blocks: [..]Block;
}

init_program :: (program: Program) {
    init(*program.declarations_by_serial);
    init(*program.declarations_by_name);
}

deinit_program :: (program: Program) {
    deinit(*program.declarations_by_serial);
    deinit(*program.declarations_by_name);
}

reset_program :: (program: Program) {
    table_reset(*program.declarations_by_name);
    table_reset(*program.declarations_by_serial);
    array_reset(*program.imported_modules);
    array_reset(*program.imported_files);
    array_reset(*program.code_blocks);
    array_reset(*program.declarations);
}

path_in_imported_modules_or_files :: (path: string) -> bool {
    for module: server.program.imported_modules {
        if contains(path, tprint("/modules/%", module.name)) return true;
    }

    for file: server.program.imported_files {
        if contains(path, file.path) && file.project return true;
    }

    return false;
}

// Find nearest block by line, char and file
// @todo: make this more robust and cleaver (this is initial experimental implementation)
find_block :: (line: s32, char: s32, file: string) -> *Block {
    nearest_block: *Block;

    is_in_range :: (loc: Declaration.Location, line: s32, char: s32) -> bool {
        if loc.l0 > line || loc.l1 < line return false;

        if loc.l0 == line && loc.c0 > char return false;
        if loc.l1 == line && loc.c1 < char return false;

        return true;
    }

    for * block: server.program.code_blocks {
        if block.serial == 0 continue;
        if block.location.file != file continue;

        // If the location is not present in the block we skip.
        if !is_in_range(block.location, line, char) continue;

        // Skip if, while, empty ... blocks
        parent, parent_exists := table_find(*server.program.declarations_by_serial, block.parent);
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

reset_diagnostics :: () {
    lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
        method="textDocument/publishDiagnostics",
        params = .{
            uri = server.previously_errored_file,
            diagnostics = LSP_Diagnostic.[]
        }
    });
}

// Currently, parse only the first error
send_compiler_errors_as_diagnostics :: (output: string) {
    lines := split(output, "\n");

    file: string;
    diagnostic: LSP_Diagnostic;

    // Get the first error
    for output_line: lines {
        if !contains(output_line, ": Error:") continue;

        parts := split(output_line, ":");
        if parts.count < 3 continue;

        file = parts[0];

        line_and_character := split(parts[1], ",");
        if line_and_character.count < 2 continue;

        line, l_ok := parse_int(*line_and_character[0], u32);
        if !l_ok continue;

        character, c_ok := parse_int(*line_and_character[1], u32);
        if !c_ok continue;

        builder: String_Builder;
        append(*builder, trim(parts[3]));
        if parts.count > 3 {
            for 4..parts.count-1 {
                append(*builder, ":");
                append(*builder, parts[it]);
            }
        }

        diagnostic.message = builder_to_string(*builder);
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

    server.previously_errored_file = file;
}

refresh_program :: (send_diagnostics := false) -> success: bool, error: string {
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
        if server.local_modules_directory {
            array_add(*command, "-import_dir", server.local_modules_directory);
        }
        array_add(*command, "-", server.entry, "-plug", "jails"); // ... and tell Inception level 1 to compile the actual entry point while using our JAILS metaprogram which will be instrumented by tracy
    } else {
        array_add(*command, server.entry, "-quiet", "-no_color", "-plug", "jails");
        if server.local_modules_directory {
            array_add(*command, "-import_dir", server.local_modules_directory);
        }
    }

    array_add(*command, "-", "-channel_id", tprint("%", server.args.channel_id)); // Add unique shared memory channel ID @TOOD: is there way how to more easily transform u64 to string? @TODO: test this with the tracy pipeline.
    array_add(*command, "---", "import_dir", METAPROGRAM_MODULES_PATH); // Import dir for the initial Default_Metaprogram so that it can find our plugins (tracy for Inception level 0 if we’re profiling or Jails if we’re not profiling).

    result, output, error = run_command(..command, working_directory=server.working_directory, capture_and_return_output=true);

    if send_diagnostics {
       reset_diagnostics();
    }

    if result.exit_code != 0 {
        log_error("Could not run jai compiler: %\nError: %\nOutput: %", result, error, output);

        if send_diagnostics {
            send_compiler_errors_as_diagnostics(error);
        }

        return false, error;
    }

    end := current_time_consensus();
    duration_ms := to_milliseconds(end - start);

    server.last_refresh_time = APOLLO_TIME_INVALID;
    // @Stability @Incomplete: This reads structs also modified by the cache thread!!
    // It needs to wait for a signal from the cache thread that all messages have been received!?
    log("Cache refreshed in %ms! Nodes: %", duration_ms, server.work_program.declarations_by_name.count);

    if server.args.verbose {
        log("Compiler stdout: %", output);
        log_error("Compiler stderr: %", error);
    }

    // Swap programs
    Swap(*server.program, *server.work_program);
    reset_program(server.work_program);

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

        success, command, body_bytes := decode_command(message, Protocol_Tag);
        if !success return -1;

        if command == {
            case .INITIALIZATION;
                initialization := deserialize(body_bytes, Initialization);
                server.import_path = initialization.import_path;

                write_channel_success: bool;
                write_channel_success, write_channel = writer_connect(tprint("%-%", IPC_CHANNEL_NAME_TO_META, server.args.channel_id));

                if !write_channel_success {
                    log_error("Could not open write channel to metaprogram.");
                    return -1;
                }

                // Send all (modified) files to the metaprogram
                // @Stability: This only works because the metaprogram doesn’t send anything while
                // it waits for files. If this ever changes, we need to move the sending to a separate thread
                // or we might deadlock.
                {
                    lock(*server.modified_files_lock);
                    defer unlock(*server.modified_files_lock);

                    for server.modified_files {
                        message: Modified_File;
                        message.path = it_index;
                        message.content = it;
                        send_to_metaprogram(*write_channel, .MODIFIED_FILE, *message);
                    }

                    send_to_metaprogram(*write_channel, .DONE, null);
                }

            case .MODULE_IMPORT;
                module := deserialize(body_bytes, Module);
                array_add(*server.work_program.imported_modules, module);

            case .FILE;
                file := deserialize(body_bytes, Source_File);
                // create_file(file.path, read_entire_file(file.path));
                array_add(*server.work_program.imported_files, <<file);

            case .STRUCT; add_to_program(body_bytes, Struct);
            case .PROCEDURE; add_to_program(body_bytes, Procedure);
            case .TYPE_INSTANTIATION; add_to_program(body_bytes, Type_Instantiation);
            case .EXPRESSION; add_to_program(body_bytes, Expression);
            case .ENUM; add_to_program(body_bytes, Enum);
            case .BLOCK; add_to_program(body_bytes, Block);
        }
    }

    return 0;
}

add_to_program :: (bytes: []u8, $type: Type) {
    data := deserialize(bytes, type);

    #if type == Block {
        array_add(*server.work_program.code_blocks, data);
        // table_set(*program_cache.declarations_by_serial, data.serial, data);
    } else {
        table_set(*server.work_program.declarations_by_serial, data.serial, data);
        table_add(*server.work_program.declarations_by_name, data.name, data);
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
