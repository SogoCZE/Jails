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

    declarations: [..]Declaration; // Array všech declarací
    declarations_by_serial: Table(ID, *Declaration); // Declarace dle serial
    declarations_by_name: Table(string, *Declaration); // Declarace dle jména @SPEED: Pointer vs 
    // declarations_by_location: Table(string, []Line); // Declarace dle lokace
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

run_metaprogram_analysis :: () {
    if program_cache.declarations_by_serial.count > 0 {
        table_reset(*program_cache.declarations_by_serial);
        table_reset(*program_cache.declarations_by_name);
    }

    result, output, error := run_command("jai", program_cache.entry, "-plug", "jai_lsp", "---", "import_dir", METAPROGRAM_PLUGIN_PATH, working_directory=program_cache.working_directory, capture_and_return_output=true);

    if error.count != 0 {
        log("Metaprogram run failed: '%'", error);
    }

    log("Cache refreshed! Nodes: %", program_cache.declarations_by_name.count);
}

read_shared_memory :: (channel: Read_Channel) {
    messages_read := 0;
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

        bytes := message.user_read_bytes;
        if bytes >= HEADER_SIZE {
            command := message.user_read_pointer[0];
            if command < cast(u8) Protocol_Tag.MESSAGE_START || command > cast(u8) Protocol_Tag.MESSAGE_END {
                log_error("Got an invalid command on a data message: %\n", command);
                return;
            }

            stored_checksum := message.user_read_pointer[1];
            
            data_bytes := message.user_read_bytes - HEADER_SIZE;

            my_checksum: u8;
            for 0..data_bytes-1 {
                my_checksum ^= message.user_read_pointer[it + HEADER_SIZE];
            }

            if my_checksum != stored_checksum {
                log_error("Checksum mismatch in message #%: Wanted %, got %. Quitting.\n", messages_read+1, stored_checksum, my_checksum);
                return;
            }
        } else if bytes == 1 {
            command := message.user_read_pointer[0];
            if command == cast(u8) Protocol_Tag.DONE {
                log("Received DONE; breaking from the loop.\n");
                break;
            }
        } else {
            log_error("Got a message that is too short! Quitting.\n");
            return;
        }

        command := cast(Protocol_Tag) message.user_read_pointer[0];

        body_bytes: []u8 = ---;
        body_bytes.data = message.user_read_pointer + HEADER_SIZE;
        body_bytes.count = message.user_read_bytes - HEADER_SIZE;

        if command == {
            case .INITIALIZATION; 
                initialization := deserialize(body_bytes, Initialization);
                program_cache.import_path = initialization.import_path;

            case .MODULE_IMPORT;
                module := deserialize(body_bytes, Module);
                array_add(*program_cache.modules, module);

            case .FILE;
                file := deserialize(body_bytes, Source_File);
                create_file(file.path, read_entire_file(file.path));
                array_add(*program_cache.files, <<file);

            case .STRUCT; add_to_cache(body_bytes, Struct);
            case .PROCEDURE; add_to_cache(body_bytes, Procedure);
            case .TYPE_INSTANTIATION; add_to_cache(body_bytes, Type_Instantiation);
            case .EXPRESSION; add_to_cache(body_bytes, Expression);
            case .ENUM; add_to_cache(body_bytes, Enum);
            case .BLOCK; add_to_cache(body_bytes, Block);
        }

        reader_done_with_message(*message);
        messages_read += 1;
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
        POSIX.shm_unlink("jlsp"); 
    }

    // log("Listening to metaprogram!");

    success, channel := reader_create_channel("jlsp", CHANNEL_DATA_BYTES);
    if !success {
        // log_error("Exiting due to channel creation failure.\n");
        return -1;
    }

    defer reader_release_channel(*channel);

    read_shared_memory(channel);

    return 0;
}