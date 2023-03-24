get_plugin :: () -> *Plugin {
    p := New(Jails_Plugin);
    p.start = current_time_consensus();

    #if OS != .WINDOWS {
        POSIX :: #import "POSIX";
        POSIX.shm_unlink(IPC_CHANNEL_NAME_TO_META);
    }

    options := get_build_options();

    // @TODO: This is dangerous!
    last := options.compile_time_command_line[options.compile_time_command_line.count-1];

    success: bool;
    success, p.read_channel = reader_create_channel(join(IPC_CHANNEL_NAME_TO_META, last, separator="-"), CHANNEL_DATA_BYTES);
    if !success {
        log_error("Could not open read channel.");
        exit(1);
    }

    success, p.write_channel = writer_connect(join(IPC_CHANNEL_NAME_FROM_META, last, separator="-"));
    if !success {
        log_error("Could not open write channel.");
        exit(1);
    }



    p.message  = message;
    p.shutdown = shutdown;
    p.before_intercept = before_intercept;

    library_init(p, options.import_path);

    return p;
}

before_intercept :: (_p: *Plugin, flags: *Intercept_Flags) {
    p := cast(*Jails_Plugin) _p;
    options := get_build_options(p.workspace);
    options.output_type = .NO_OUTPUT;
    set_build_options(options, p.workspace);
}

message :: (_p: *Plugin, message: *Message) {
    p := cast(*Jails_Plugin) _p;
    library_handle_message(p, message);
}

shutdown :: (_p: *Plugin) {
    p := cast(*Jails_Plugin) _p;
    writer_disconnect(*p.write_channel);
    reader_release_channel(*p.read_channel);

    library_deinit(p);

    free(p);
}

library_init :: (p: *Jails_Plugin, import_path: [] string) #foreign Jails_Metaprogram_Library;
library_deinit :: (p: *Jails_Plugin) #foreign Jails_Metaprogram_Library;
library_handle_message :: (p: *Jails_Plugin, message: *Message) #foreign Jails_Metaprogram_Library;

Jails_Metaprogram_Library :: #library "jails_metaprogram_library";

#load "../shared/binary_serialization.jai";
#load "../shared/shared.jai";
#load "../metaprogram/shared.jai";

