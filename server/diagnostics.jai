// This file contains code for running compiler for getting errors and warning.

DIAGNOSTICS_TIMEOUT_MS :: 30_000;

Diagnostics :: struct {
    thread: Thread;
    wake: Semaphore;

    lock: Mutex;
    pending: bool;
    quit: bool;

    previously_errored_file: string;
}

diagnostics: Diagnostics;

init_diagnostics :: () {
    init(*diagnostics.lock);
    init(*diagnostics.wake);
}

start_diagnostics_thread :: () {
    thread_init(*diagnostics.thread, diagnostics_thread_proc);
    thread_start(*diagnostics.thread);
}

stop_diagnostics_thread :: () {
    lock(*diagnostics.lock);
    diagnostics.quit = true;
    unlock(*diagnostics.lock);

    signal(*diagnostics.wake);
}

run_diagnostics :: () {
    if server.build_root.count == 0 return;

    lock(*diagnostics.lock);
    diagnostics.pending = true;
    unlock(*diagnostics.lock);

    signal(*diagnostics.wake);
}

#scope_file

diagnostics_thread_proc :: (thread: *Thread) -> s64 {
    while true {
        wait_for(*diagnostics.wake);

        lock(*diagnostics.lock);
        pending := diagnostics.pending;
        quit    := diagnostics.quit;
        diagnostics.pending = false;
        unlock(*diagnostics.lock);

        if quit break;
        if !pending continue;

        run_diagnostics_now();

        reset_temporary_storage();
    }

    return 0;
}

resolve_jai_executable :: () -> string, bool {
    if server.args.jai_path.count == 0 {
        return DEFAULT_JAI_EXE_NAME, true;
    }

    candidates: [3]string;
    candidates[0] = server.args.jai_exe_name;
    candidates[1] = DEFAULT_JAI_EXE_NAME;
    candidates[2] = "jai";

    for candidate: candidates {
        if candidate.count == 0 continue;

        path := join(server.args.jai_path, "bin", candidate, separator="/",, temp);
        if file_exists(path) return path, true;
    }

    return "", false;
}

reset_diagnostics :: () {
    if diagnostics.previously_errored_file {
        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = diagnostics.previously_errored_file,
                diagnostics = LSP_Diagnostic.[]
            }
        });
    }
}

// Currently, parse only the first error (maybe parsing multiple errors is not that useful because Jai mostly report one error at a time)
// @TODO: Make it work with multiple errors
// @todo: add support for warnings
run_diagnostics_now :: () {
    if server.build_root.count == 0 return;
    build_root_absolute := join(server.project_root, server.build_root, separator="/");
    defer free(build_root_absolute);

    log("Running diagnostics %", build_root_absolute);

    command: [..] string;
    defer array_free(command);

    jai_exe_path, found := resolve_jai_executable();
    if !found {
        log_error("Diagnostics: could not find the Jai compiler executable in '%/bin' (tried '%', '%' and 'jai').", server.args.jai_path, server.args.jai_exe_name, DEFAULT_JAI_EXE_NAME);
        return;
    }

    array_add(*command, jai_exe_path);
    array_add(*command, build_root_absolute, "-quiet", "-no_color");

    // Use fast x64 backend on supported CPUs.
    if CPU == .X64 {
        array_add(*command, "-x64");
    }

    for local_module_folder: server.local_modules {
        array_add(*command, "-import_dir", local_module_folder);
    }

    array_add(*command, "+jails_diagnostics");

    if server.intermediate_path.count > 0 {
        joined := join(server.project_root, server.intermediate_path, separator="/",, temp);
        normalised := normalize_path(joined,, temp);
        array_add(*command, "-intermediate_path", normalised);
    }

    array_add(*command, "---", "import_dir", server.diagnostics_metaprogram_path);

    reset_diagnostics();

    result, _, error, timeout_reached := run_command(..command, working_directory=server.project_root, capture_and_return_output=true, timeout_ms=DIAGNOSTICS_TIMEOUT_MS);
    if timeout_reached {
        log_error("Diagnostics: the compiler did not finish within % ms, skipping diagnostics for this run.", DIAGNOSTICS_TIMEOUT_MS);
        return;
    }

    if result.type == .FAILED_TO_LAUNCH {
        log_error("Diagnostics: failed to launch the compiler (%).", command[0]);
        return;
    }

    if result.exit_code == 0 {
        return;
    }

    lines := split(error, "\n");
    defer array_free(lines);

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
        file = replace(file, "//", "/",, temp);
        if !ok continue;

        line_and_character := split(location, ",");
        if line_and_character.count < 2 continue;

        line, l_ok := parse_int(*line_and_character[0], u32);
        if !l_ok continue;

        character, c_ok := parse_int(*line_and_character[1], u32);
        if !c_ok continue;

        diagnostic.message = message;
        diagnostic.severity = xx LSP_Diagnostic_Severity.ERROR;

        diagnostic.range.start.line = line-1;
        diagnostic.range.start.character = character-1;
    }

    if file.count == 0 {
        log_error("Diagnostics: the compiler failed without a locatable error:\n%", error);
        return;
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

    diagnostics_to_publish: [1]LSP_Diagnostic;
    diagnostics_to_publish[0] = diagnostic;

    file = path_to_lsp_path(normalize_path(file,, temp)); // split_from_right and slice don't allocate memory so copy the file in case the string with compiler output is freed

    lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
        method="textDocument/publishDiagnostics",
        params = .{
            uri = file,
            diagnostics = diagnostics_to_publish
        }
    });

    if file != diagnostics.previously_errored_file {
        free(diagnostics.previously_errored_file);
    }

    diagnostics.previously_errored_file = file;
}
