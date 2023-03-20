Line :: struct {
    declarations: []Declaration;
}

Program :: struct {
    import_path: []string;
    entry: string;
    working_directory: string;

    files: [..]Source_File;
    modules: [..]Module;

    code_blocks: [..]Block;

    declarations: [..]Declaration;
    declarations_by_serial: Table(ID, *Declaration);
    declarations_by_name: Table(string, *Declaration);
    // declarations_by_location: Table(string, []Line); // Declarations by location
}

program_cache: Program;

init_cache :: () {
    init(*program_cache.declarations_by_serial);
    init(*program_cache.declarations_by_name);
    // init(*program_cache.declarations_by_location);
}

deinit_cache :: () {
    deinit(*program_cache.declarations_by_serial);
    deinit(*program_cache.declarations_by_name);
    // deinit(*program_cache.declarations_by_location);
}

run_metaprogram_analysis :: () -> success: bool, error: string {
    // @Stability @Incomplete: This modifies structs also modified by the cache thread!!
    // So this needs to take a lock or something!
    if program_cache.declarations_by_serial.count > 0 {
        table_reset(*program_cache.declarations_by_serial);
        table_reset(*program_cache.declarations_by_name);
    }

    start := current_time_consensus();
    result: Process_Result;
    output: string;
    error: string;
    if args.profile {
        result, output, error = run_command("jai",
            tprint("%/modules/Default_Metaprogram.jai", args.jai_path), // Tell the Default_Metaprogram (Inception level 0) to compile the Default_Metaprogram (Inception level 1)...
            "-quiet", "-no_color", "-no_cwd", // (+ some basic args for Inception level 0)
            "-plug", "tracy", "-modules", "-import_dir", METAPROGRAM_MODULES_PATH, // ... but use the tracy module to instrument Inception level 1
            "-", program_cache.entry, "-plug", "jails", // ... and tell Inception
            // level 1 to compile the actual entry point while using our JAILS metaprogram which will be instrumented by tracy
            "---", "import_dir", METAPROGRAM_MODULES_PATH, // ... and this here tells the compiler the import dir for Inception level 0
            working_directory=program_cache.working_directory, capture_and_return_output=true
        );
    } else {
        result, output, error = run_command("jai",
            program_cache.entry, "-quiet", "-no_color", "-plug", "jails",
            "---", "import_dir", METAPROGRAM_MODULES_PATH,
            working_directory=program_cache.working_directory, capture_and_return_output=true);
    }
    
    if result.exit_code != 0 {
        log_error("Could not run jai compiler: %\nError: %\nOutput: %", result, error, output);
        return false, error;
    }

    end := current_time_consensus();
    duration_ms := to_milliseconds(end - start);

    last_change_time = APOLLO_TIME_INVALID;

    // @Stability @Incomplete: This reads structs also modified by the cache thread!!
    // It needs to wait for a signal from the cache thread that all messages have been received!?
    log("Cache refreshed in %ms! Nodes: %", duration_ms, program_cache.declarations_by_name.count);

    if args.verbose {
        log("Compiler stdout: %", output);
        log_error("Compiler stderr: %", error);
    }

    return true, "";
}

read_shared_memory :: (channel: Read_Channel) {
    messages_read := 0;
    write_channel: Write_Channel;
    while !quit {
        message_success, fatal_error, message := reader_poll_for_message(*channel);

        if fatal_error {
            log_error("Fatal error");
            return;
        }

        if !message_success {
            sleep_milliseconds(1);
            continue;
        }

        defer {
            reader_done_with_message(*message);
            messages_read += 1;
        }

        bytes := message.user_read_bytes;
        if bytes < JAILS_HEADER_SIZE {
            log_error("Got a message that is too short (% bytes)! Quitting.", bytes);
            return;
        }

        success, command, body_bytes := decode_command(message, Protocol_Tag);
        if !success return;

        if command == {
            case .INITIALIZATION;
                initialization := deserialize(body_bytes, Initialization);
                program_cache.import_path = initialization.import_path;
                write_channel_success: bool;
                write_channel_success, write_channel = writer_connect(IPC_CHANNEL_NAME_TO_META);
                if !write_channel_success {
                    log_error("Could not open write channel to metaprogram.");
                    return;
                }

                // Send all (modified) files to the metaprogram
                // @Stability: This only works because the metaprogram doesn’t send anything while
                // it waits for files. If this ever changes, we need to move the sending to a separate thread
                // or we might deadlock.
                {
                    lock(*file_lock);
                    defer unlock(*file_lock);
                    for files {
                        message: Modified_File;
                        message.path = it_index;
                        message.content = it;
                        send_to_metaprogram(*write_channel, .MODIFIED_FILE, *message);
                    }
                    send_to_metaprogram(*write_channel, .DONE, null);
                }

            case .MODULE_IMPORT;
                module := deserialize(body_bytes, Module);
                array_add(*program_cache.modules, module);

            case .FILE;
                file := deserialize(body_bytes, Source_File);
                // create_file(file.path, read_entire_file(file.path));
                array_add(*program_cache.files, <<file);

            case .STRUCT; add_to_cache(body_bytes, Struct);
            case .PROCEDURE; add_to_cache(body_bytes, Procedure);
            case .TYPE_INSTANTIATION; add_to_cache(body_bytes, Type_Instantiation);
            case .EXPRESSION; add_to_cache(body_bytes, Expression);
            case .ENUM; add_to_cache(body_bytes, Enum);
            case .BLOCK; add_to_cache(body_bytes, Block);
        }
    }

}

add_to_cache :: (bytes: []u8, $type: Type) {
    data := deserialize(bytes, type);

    table_set(*program_cache.declarations_by_serial, data.serial, data);
    table_add(*program_cache.declarations_by_name, data.name, data);
    #if type == Block array_add(*program_cache.code_blocks, data);
}

path_in_imported_modules_or_files :: (path: string) -> bool {
    for module: program_cache.modules {
        if contains(path, tprint("/modules/%", module.name)) return true;
    }


    for file: program_cache.files {
        if contains(path, file.path) && file.project return true;
    }

    return false;
}

listen_to_metaprogram :: (thread: *Thread) -> s64 {
    #if OS != .WINDOWS {
        POSIX :: #import "POSIX";
        POSIX.shm_unlink(IPC_CHANNEL_NAME_FROM_META);
    }

    // log("Listening to metaprogram!");

    success, channel := reader_create_channel(IPC_CHANNEL_NAME_FROM_META, CHANNEL_DATA_BYTES);
    if !success {
        // log_error("Exiting due to channel creation failure.\n");
        return -1;
    }

    defer reader_release_channel(*channel);

    read_shared_memory(channel);

    return 0;
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
