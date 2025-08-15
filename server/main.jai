VERSION :: "1.0.0";

MEMORY_DEBUG :: false;

Args :: struct {
    verbose: bool;
    profile: bool;
    jai_path: string;
}

User_Options :: struct {
    auto_insert_parentheses: bool;
}

Project_Config :: struct {
    local_modules: []string;
    roots: []string;
    build_root: string;
    intermediate_path: string;
    user_options: User_Options;
    jai_path: string;

    project_root: string;
    config_loaded: bool;
    config_file_hash: u64;

    files: Table(string, *Program_File);
    files_to_be_analyzed: [..]*Program_File;

    // Per-project allocator for all project-owned data
    allocator: Allocator;
    pool: Pool;
}

init_project_config :: (project: *Project_Config) {
    project.* = .{};
    set_allocators(*project.pool, context.default_allocator);
    project.allocator = .{pool_allocator_proc, *project.pool};

    init(*project.files,, project.allocator);
    project.files_to_be_analyzed.allocator = project.allocator;
}

Server :: struct {
    quit := false;

    verbose: bool;
    profile: bool;

    // Start of active project fields
    local_modules: []string;
    roots: []string;
    build_root: string;
    intermediate_path: string;
    user_options: User_Options;
    project_root: string;
    jai_path: string;
    files: Table(string, *Program_File);
    files_to_be_analyzed: [..]*Program_File;
    // End of active project fields

    workspace_folders: [..]string;
    projects: Table(string, Project_Config); // project_root -> config

    memory_files_lock: Mutex;
    memory_files: Table(string, [..]u8); // @todo: This is probably dumb - store files as array of lines instead (is this good idea?) // @ToDo: Keep track of a modified flag per file

    previously_errored_file: string;

    diagnostics_metaprogram_path: string;
}

server: Server;

switch_to_project :: (project: *Project_Config) #expand {
    if !project return;

    server.local_modules = project.local_modules;
    server.roots = project.roots;
    server.build_root = project.build_root;
    server.intermediate_path = project.intermediate_path;
    server.user_options = project.user_options;
    server.project_root = project.project_root;
    server.jai_path = project.jai_path;
    server.files = project.files;
    server.files_to_be_analyzed = project.files_to_be_analyzed;

    `defer {
        project.local_modules = server.local_modules;
        project.roots = server.roots;
        project.build_root = server.build_root;
        project.intermediate_path = server.intermediate_path;
        project.user_options = server.user_options;
        project.project_root = server.project_root;
        project.jai_path = server.jai_path;
        project.files = server.files;
        project.files_to_be_analyzed = server.files_to_be_analyzed;
    }
}

// TODO: initialize_project is being called wrong, in general the initialization
// message is not being handled correctly. Scan_workspace_for_configs is probably
// the function that should initialize them all.

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

        raw_path = replace(raw_path, tprint("%: ", executable_name), "");
        raw_path = trim(raw_path);

        BUFFER_SIZE :: 4096;
        buf: [BUFFER_SIZE] u8;

        length := readlink(to_c_string(raw_path), buf.data, BUFFER_SIZE);
        if length > 0 {
            resolved_path := to_string(buf.data);
            if begins_with(resolved_path, "/") {
                raw_path = resolved_path;
            }
        }
    }

    if raw_path.count == 0 {
        #if OS == .MACOS || OS == .LINUX {
            if executable_name == "jai" return "";
            return find_jai_path("jai");
        }

        return "";
    }

    path := split(raw_path, "/");

    pop(*path); // jai.exe or jai
    pop(*path); // bin

    return join(..path, separator="/");
}

as :: (using u: *Tagged_Union, $T: Type) -> T {
    assert(tag == T, "Expected %, got %", T, tag);
    return (cast(*T) u.bytes.data).*;
}

dedup_locations :: (locsPtr: *[..]Generic_Location) {
    locs := locsPtr.*;
    defer locsPtr.* = locs;

    inner :: (a: $T) #expand {
        while `j < locs.count {
            assert(locs[`j].tag == T);
            b_loc := as(*locs[`j], T);
            if a == b_loc {
                array_unordered_remove_by_index(*locs, `j);
                continue;
            }
            `j += 1;
        }
    }

    i := 0;
    while i < locs.count {
        j := i + 1;
        if locs[i].tag == {
            case LSP_Location;
                inner(as(*locs[i], LSP_Location));
            case LSP_Location_Link;
                inner(as(*locs[i], LSP_Location_Link));
            case;
                assert(false, "Expected LSP_Location or LSP_Location_Link, got %", locs[i].tag);
        }
        i += 1;
    }
}

dedup_workspace_symbols :: (symbolsPtr: *[..]LSP_Workspace_Symbol) {
    symbols := symbolsPtr.*;
    defer symbolsPtr.* = symbols;

    i := 0;
    while i < symbols.count {
        j := i + 1;
        while j < symbols.count {
            if symbols[i].name == symbols[j].name &&
               symbols[i].kind == symbols[j].kind &&
               symbols[i].location == symbols[j].location
            {
                array_unordered_remove_by_index(*symbols, j);
                continue;
            }
            j += 1;
        }
        i += 1;
    }
}

scan_workspace_for_configs :: (workspace_root: string) -> bool {
    found := false;

    visitor :: (info: *File_Visit_Info, found_ptr: *bool) {
        if info.is_directory  return;
        if info.short_name != "jails.json"  return;

        found_ptr.* = true;
        project_dir := path_strip_filename(info.full_name);
        initialize_project(project_dir);
    }

    visit_files(workspace_root, true, *found, visitor, true, false);

    return found;
}

load_config_for_project :: (project_root: string) -> *Project_Config {
    push_allocator(temp);
    auto_release_temp();

    project := table_find_pointer(*server.projects, project_root);

    config_path := join(project_root, "/jails.json");
    config_exists := file_exists(config_path);
    current_hash: u64 = 0;

    if config_exists {
        config_content := read_entire_file(config_path);
        current_hash = native_XXH64(config_content.data, xx config_content.count, 0);
    }

    // Check if we need to reload config
    if project && project.config_loaded {
        if current_hash != project.config_file_hash {
            log("Config file changed for project %, reloading...", project_root);
            release(*project.pool);
            init_project_config(project);
            project.config_loaded = false;
            project.config_file_hash = current_hash;
        } else {
            return project; // No changes, return existing config
        }
    }

    if !project {
        project = table_add(*server.projects, copy_string(project_root,, server.projects.allocator), .{});
        log("Adding new project: %", project_root);
        init_project_config(project);
        project.project_root = copy_string(project_root,, project.allocator);
    }

    if !config_exists {
        // Set defaults for projects without config
        project.config_loaded = true;
        project.local_modules = .["modules"];
        project.user_options.auto_insert_parentheses = true;
        return project;
    }

    config_content := read_entire_file(config_path);

    Config :: struct {
        local_modules: []string;
        roots: []string;
        build_root: string;
        jai_path: string;
        intermediate_path: string;
        auto_insert_parentheses := true;
    }

    ok, config := json_parse_string(config_content, Config);
    if !ok {
        log("Failed to parse config file at %!", config_path);
        project.config_loaded = true;
        return project;
    }
    log("Loaded config file @ %", config_path);

    // Use project allocator for all project-owned data
    push_allocator(project.allocator);

    // Copy local_modules array to project allocator
    local_modules: [..]string;
    for config.local_modules {
        array_add_if_unique(*local_modules, copy_string(it));
    }
    // Include default modules path
    array_add_if_unique(*local_modules, "modules");
    project.local_modules = local_modules;

    // Copy roots array to project allocator
    project.roots = NewArray(config.roots.count, string);
    for i: 0..config.roots.count-1 {
        project.roots[i] = copy_string(config.roots[i]);
    }

    project.build_root = copy_string(config.build_root);
    project.intermediate_path = copy_string(config.intermediate_path);

    project.user_options.auto_insert_parentheses = config.auto_insert_parentheses;
    project.config_loaded = true;

    if config.jai_path.count > 0 {
        project.jai_path = copy_string(config.jai_path);
    }

    return project;
}

initialize_project :: (project_root: string) {
    // Load or reload project configuration
    project := load_config_for_project(project_root);

    // Make this project the active one for legacy single-project code paths
    switch_to_project(project);

    if project.build_root.count == 0 {
        project.build_root = find_entry_file(project_root);
    }

    if project.roots.count == 0 {
        project.roots = .[find_entry_file(project_root)];
    }

    log("Project % - local_modules: %", project_root, project.local_modules);
    log("Project % - roots: %", project_root, project.roots);
    log("Project % - intermediate_path: %", project_root, project.intermediate_path);

    parse_file(tprint("%/modules/Runtime_Support.jai", project.jai_path), true);
    parse_file(tprint("%/modules/Preload.jai", project.jai_path), true);

    for root: project.roots {
        absolute_path: string;
        if starts_with(root, "/") {
            absolute_path = root;
        } else {
            // TODO: need much better path handling
            ends_with_slash := project_root[project_root.count-1] == "/";
            absolute_path = join(project_root, root, separator=ifx ends_with_slash then "" else "/",, temp);
        }

        absolute_path = normalize_path(absolute_path,, temp);
        parse_file(absolute_path, true);
    }

    analyze_files();
}

struct_printer_with_table_support :: (builder: *String_Builder, any: Any, struct_printer_data: *void) -> bool {
    if any.type.type == .STRUCT {
        ti := cast(*Type_Info_Struct) any.type;
        // Silly hack to get the polymorphic source struct of all `Table`s, because
        // type_info(Table) complains about the type not being concrete.
        table_type_info := type_info(Table(u8, u8)).polymorph_source_struct;
        if ti.polymorph_source_struct == table_type_info {
            entries_offset := -1;
            entries_stride := -1;
            hash_offset := -1;
            key_offset := -1;
            value_offset := -1;
            key_type_info: *Type_Info;
            value_type_info: *Type_Info;
            for member: ti.members {
                if member.name == "entries" {
                    entries_offset = member.offset_in_bytes;
                    arr_type_info := cast(*Type_Info_Array) member.type;
                    table_entry_type_info := cast(*Type_Info_Struct) arr_type_info.element_type;
                    entries_stride = table_entry_type_info.runtime_size;
                    for table_entry_member: table_entry_type_info.members {
                        if table_entry_member.name == "hash" {
                            hash_offset = table_entry_member.offset_in_bytes;
                            // Probably ok to assume u32, but best to check!
                            assert(table_entry_member.type.type == .INTEGER);
                            assert((cast(*Type_Info_Integer) table_entry_member.type).runtime_size == 4);
                        }
                        if table_entry_member.name == "key" {
                            key_offset = table_entry_member.offset_in_bytes;
                            key_type_info = table_entry_member.type;
                        }
                        if table_entry_member.name == "value" {
                            value_offset = table_entry_member.offset_in_bytes;
                            value_type_info = table_entry_member.type;
                        }
                    }
                }
            }
            assert(entries_offset != -1);
            assert(entries_stride != -1);
            assert(hash_offset != -1);
            assert(key_offset != -1);
            assert(value_offset != -1);

            print_to_builder(builder, "[");
            entries_raw := (cast(*[]u8) (any.value_pointer + entries_offset)).*;
            need_separator := false;
            for i: 0..entries_raw.count-1 {
                entry_ptr := entries_raw.data + i * entries_stride;
                hash := (cast(*u32) (entry_ptr + hash_offset)).*;
                // skip unused entries, see for_expansion in Hash_Table.jai
                if hash < FIRST_VALID_HASH {
                    continue;
                }
                if need_separator {
                    print_to_builder(builder, ", ");
                }
                need_separator = true;
                key_ptr := entry_ptr + key_offset;
                value_ptr := entry_ptr + value_offset;
                key_any := Any.{type=key_type_info, value_pointer=key_ptr};
                value_any := Any.{type=value_type_info, value_pointer=value_ptr};
                print_to_builder(builder, "% : %", key_any, value_any);
            }
            print_to_builder(builder, "]");
            return true;
        }
    }

    // If it wasn't a table, but the parent struct printer is set, defer to it.
    parent_print_style := cast(*Print_Style) struct_printer_data;
    if parent_print_style && parent_print_style.struct_printer {
        return parent_print_style.struct_printer(builder, any, parent_print_style.struct_printer_data);
    }
    // Otherwise, give up
    return false;
}

push_table_printer :: () #expand {
    original_print_style := context.print_style;
    context.print_style.struct_printer = struct_printer_with_table_support;
    context.print_style.struct_printer_data = *original_print_style;
    `defer context.print_style = original_print_style;
}

struct_printer_with_tagged_union_support :: (builder: *String_Builder, any: Any, struct_printer_data: *void) -> bool {
    if any.type.type == .STRUCT {
        ti := cast(*Type_Info_Struct) any.type;
        tagged_union_type_info := type_info(Tagged_Union()).polymorph_source_struct;
        if ti.polymorph_source_struct == tagged_union_type_info {
            tag_offset := -1;
            bytes_offset := -1;
            for member: ti.members {
                if member.name == "tag" {
                    tag_offset = member.offset_in_bytes;
                }
                if member.name == "bytes" {
                    bytes_offset = member.offset_in_bytes;
                }
            }
            assert(tag_offset != -1);
            assert(bytes_offset != -1);

            tag := (cast(*Type) (any.value_pointer + tag_offset)).*;
            value_any := Any.{type=cast(*Type_Info) tag, value_pointer=any.value_pointer + bytes_offset};

            print_to_builder(builder, "%", value_any);
            return true;
        }
    }
    return false;
}

push_tagged_union_printer :: () #expand {
    original_print_style := context.print_style;
    context.print_style.struct_printer = struct_printer_with_tagged_union_support;
    context.print_style.struct_printer_data = *original_print_style;
    `defer context.print_style = original_print_style;
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

// Hideous hack to get a JSON_Value from a typed value.
// The implementation goes round-trip through a string, which is ridicolous.
to_json_value :: (val: $T) -> JSON_Value {
    json_str := json_write_string(val, indent_char="");
    defer free(json_str);
    success, parsed := json_parse_string(json_str);
    assert(success, "Failed to round-trip JSON for type %", T);
    return parsed;
}

handle_request :: (request: LSP_Request_Message, raw_request: string) {

    if request.method == {
        case "shutdown";
            log("shutdown");
            server.quit = true;
            lsp_respond(request.id, null);
        case "initialize";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Initialize,, temp);
            if !success {
                log_error("Unable to parse initialize message");
                // @Incomplete: report error back!
                return;
            }

            log("initialize with workspace folders %", body.params.workspaceFolders);

            create_diagnostics_metaprogram();

            // Handle workspace folders (modern LSP approach)
            if body.params.workspaceFolders {
                log("Initializing with % workspace folders", body.params.workspaceFolders.count);
                for folder: body.params.workspaceFolders.* {
                    folder_path := normalize_path(folder.uri,, temp);
                    log("Adding workspace folder: % (%)", folder.name, folder_path);

                    array_add(*server.workspace_folders, copy_string(folder_path));

                    found := scan_workspace_for_configs(folder_path);
                    if !found {
                        initialize_project(folder_path);
                    }
                }
            } else if body.params.rootPath && body.params.rootPath.* {
                // Fallback for older LSP clients
                log("Initializing with legacy rootPath: %", body.params.rootPath.*);
                root_path := copy_string(body.params.rootPath.*); // Use default allocator for server-owned data
                array_add(*server.workspace_folders, root_path);
                found := scan_workspace_for_configs(root_path);
                if !found {
                    initialize_project(root_path);
                }
            } else {
                log("No workspace folders provided - LSP will wait for workspace/didChangeWorkspaceFolders");
            }

            // print files for each project
            for proj: server.projects {
                log("Project % - files: %", proj.project_root, proj.files.count);
            }

            to_send: LSP_Result_Initialize;
            log("Sending initialize response %", to_send);
            lsp_respond(body.id, to_send);

        case "textDocument/definition";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Definition,, temp);
            if !success {
                log_error("Unable to parse textDocument/definition message");
                return;
            }

            log("textDocument/definition for %", body.params.textDocument.uri);

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            // Collect results from every project that references this file
            results: [..]Generic_Location;
            for proj: server.projects {
                if table_contains(*proj.files, file_path) {
                    log("Found % in project %", file_path, proj.project_root);
                    switch_to_project(*proj);
                    for loc: calc_goto(file_path, body.params.position) {
                        array_add(*results, loc);
                    }
                }
            }

            log("Results: %", results);

            // Fallback: if no specific project, use the one discovered by ensure_project_for_file
            // if results.count == 0 {
            //     ensure_project_for_file(file_path);
            //     for loc: calc_goto(file_path, body.params.position) {
            //         array_add(*results, loc);
            //     }
            // }

            // De-duplicate identical locations
            dedup_locations(*results);

            log("De-duplicated results: %", results);

            jsa := NewArray(results.count, JSON_Value);
            for result: results {
                if result.tag == {
                    case LSP_Location;
                        jsa[it_index] = to_json_value(as(*result, LSP_Location));
                    case LSP_Location_Link;
                        jsa[it_index] = to_json_value(as(*result, LSP_Location_Link));
                    case;
                        assert(false, "Expected LSP_Location or LSP_Location_Link, got %", result.tag);
                }
            }
            jsa_json : JSON_Value;
            json_set(*jsa_json, jsa);

            lsp_respond(body.id, jsa_json);

        case "textDocument/didSave";
            success, body := json_parse_string(raw_request, LSP_Did_Save_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/divSave message");
                return;
            }

            log("textDocument/didSave for %", body.params.textDocument.uri);

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            for proj: server.projects {
                if table_contains(*proj.files, file_path) {
                    log("We found % in project %", file_path, proj.project_root);
                    switch_to_project(*proj);
                    parse_file(file_path, true);
                    analyze_files();
                    // TODO: accumulate & deduplicate diagnostics, don't just
                    // send them here
                    run_diagnostics();
                }
            }

        case "textDocument/didOpen";
            success, body := json_parse_string(raw_request, LSP_Did_Open_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/didOpen message");
                return;
            }

            log("textDocument/didOpen for %", body.params.textDocument.uri);

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            content := body.params.textDocument.text;
            create_memory_file(file_path, content);

            for proj: server.projects {
                if table_contains(*proj.files, file_path) {
                    log("We found % in project %", file_path, proj.project_root);
                    switch_to_project(*proj);
                    parse_file(file_path);
                    analyze_files();
                    // TODO: accumulate & deduplicate diagnostics, don't just
                    // send them here
                    run_diagnostics();
                }
            }

        case "textDocument/didChange";
            success, body := json_parse_string(raw_request, LSP_Did_Change_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/didChange message");
                return;
            }

            log("textDocument/didChange for %", body.params.textDocument.uri);

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            edit_memory_file(file_path, body.params.contentChanges);

            // TODO: does it actually make sense to parse & analyze here?
            // Need to understand if the memory file stuff is used by parsing
            // and analyzing code, because if not then a) wth is it for but
            // also b) this parse and analyze won't see the changes, and we'll
            // only handle them on save.
            for proj: server.projects {
                if table_contains(*proj.files, file_path) {
                    log("We found % in project %", file_path, proj.project_root);
                    switch_to_project(*proj);
                    parse_file(file_path, true);
                    analyze_files();
                }
            }

        case "textDocument/documentSymbol";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Document_Symbol);
            if !success {
                log_error("Unable to parse textDocument/documentSymbol message");
                return;
            }

            log("textDocument/documentSymbol for %", body.params.textDocument.uri);

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            for proj: server.projects {
                if table_contains(*proj.files, file_path) {
                    switch_to_project(*proj);
                    new_symbols := handle_document_symbol(body);
                    lsp_respond_array(body.id, new_symbols);
                    break; // b.c. doesn't really matter which project we use?
                }
            }

        case "workspace/symbol";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Workspace_Symbol);
            if !success {
                log_error("Unable to parse workspace/symbol message");
                return;
            }

            log("workspace/symbol for %", body.params.query);

            aggregated: [..]LSP_Workspace_Symbol;
            for proj: server.projects {
                switch_to_project(*proj);
                proj_symbols := handle_workspace_symbol(body);
                for sym: proj_symbols {
                    array_add(*aggregated, sym);
                }
            }

            dedup_workspace_symbols(*aggregated);

            lsp_respond_array(body.id, aggregated);

        case "textDocument/didClose";
            success, body := json_parse_string(raw_request, LSP_Did_Close_Text_Document,, temp);
            if !success {
                log_error("Unable to parse textDocument/dicClose message");
                return;
            }

            log("textDocument/didClose for %", body.params.textDocument.uri);

            file_path := normalize_path(body.params.textDocument.uri,, temp);
            remove_memory_file(file_path);

            log("closed %", file_path);

        case "textDocument/completion";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Completion,, temp);
            if !success {
                log_error("Unable to parse textDocument/completion message");
                return;
            }

            log("textDocument/completion for %", body.params.textDocument.uri);

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            // Aggregate from all projects referencing this file
            aggregated: [..]LSP_Completion_Item;
            for proj: server.projects {
                if table_contains(*proj.files, file_path) {
                    switch_to_project(*proj);
                    items := handle_completitions(body);
                    for item: items array_add(*aggregated, item);
                }
            }
            // Deduplicate by label/kind/insertText
            i := 0;
            while i < aggregated.count {
                j := i + 1;
                while j < aggregated.count {
                    if aggregated[i].label == aggregated[j].label &&
                       aggregated[i].kind == aggregated[j].kind &&
                       aggregated[i].insertText == aggregated[j].insertText
                    {
                        array_unordered_remove_by_index(*aggregated, j);
                        continue;
                    }
                    j += 1;
                }
                i += 1;
            }
            lsp_respond_array(body.id, aggregated);

        case "textDocument/signatureHelp";
            success, body := json_parse_string(raw_request, LSP_Request_Message_Signature_Help,, temp);
            if !success {
                log_error("Unable to parse textDocument/signatureHelp message");
                return;
            }

            log("textDocument/signatureHelp for %", body.params.textDocument.uri);

            file_path := normalize_path(body.params.textDocument.uri,, temp);

            // Aggregate signature help across all projects that reference this file
            aggregated_infos: [..]LSP_Signature_Information;
            have_active_param := false;
            active_param: u32 = 0;
            for proj: server.projects {
                if table_contains(*proj.files, file_path) {
                    switch_to_project(*proj);
                    ok, sh := handle_signature_help(body);
                    if !ok continue;

                    if !have_active_param {
                        active_param = sh.activeParameter;
                        have_active_param = true;
                    }

                    // Merge with simple de-duplication by label
                    for info: sh.signatures {
                        dup := false;
                        for existing: aggregated_infos {
                            if existing.label == info.label { dup = true; break; }
                        }
                        if !dup array_add(*aggregated_infos, info);
                    }
                }
            }

            if aggregated_infos.count == 0 {
                lsp_respond(body.id, null);
            } else {
                out: LSP_Signature_Help;
                out.activeSignature = 0;
                out.activeParameter = active_param;
                out.signatures = aggregated_infos;
                lsp_respond(body.id, out);
            }

        case "textDocument/hover";
            // TODO: Implement this
            // success, body := json_parse_string(raw_request, LSP_Request_Message_Hover,, temp);
            // if !success {
            //     log_error("Unable to parse textDocument/completion message");
            //     return;
            // }

            // handle_hover(body);

        case "workspace/didChangeWorkspaceFolders";
            success, body := json_parse_string(raw_request, LSP_Did_Change_Workspace_Folders,, temp);
            if !success {
                log_error("Unable to parse workspace/didChangeWorkspaceFolders message");
                return;
            }

            log("workspace/didChangeWorkspaceFolders for %", body.params.event);

            handle_workspace_folders_change(body);

        case;
            log_error("Unhandled method: %", request.method);
    }
}

handle_workspace_folders_change :: (request: LSP_Did_Change_Workspace_Folders) {
    // Add new workspace folders
    for folder: request.params.event.added {
        folder_path := normalize_path(folder.uri,, temp);
        log("Adding workspace folder: %", folder_path);

        // Add to workspace folders if not already present
        found := false;
        for existing: server.workspace_folders {
            if existing == folder_path {
                found = true;
                break;
            }
        }

        if !found {
            // Use default allocator for server-owned workspace folders array
            array_add(*server.workspace_folders, copy_string(folder_path));

            found := scan_workspace_for_configs(folder_path);
            if !found {
                initialize_project(folder_path);
            }
        }
    }

    // Remove workspace folders
    for folder: request.params.event.removed {
        folder_path := normalize_path(folder.uri,, temp);
        log("Removing workspace folder: %", folder_path);

        // Remove from workspace folders
        i := server.workspace_folders.count - 1;
        while i >= 0 {
            if server.workspace_folders[i] == folder_path {
                free(server.workspace_folders[i]);
                array_ordered_remove_by_index(*server.workspace_folders, i);
                break;
            }
            i -= 1;
        }

        // Free project allocator before removing
        project := table_find_pointer(*server.projects, folder_path);
        if project {
            release(*project.pool);
        }

        // Remove project config (this also frees the key string)
        table_remove(*server.projects, folder_path);

        // Remove files belonging to this project
        files_to_remove: [..]*Program_File;
        for file: server.files {
            if begins_with(file.path, folder_path) {
                array_add(*files_to_remove, file);
            }
        }

        for file: files_to_remove {
            // Free the Program_File and its resources
            free(file.path);
            release(*file.ast_pool);
            release(*file.analysis_pool);
            free(file);
            table_remove(*server.files, file.path);
        }
    }

    analyze_files();
}

#if OS == .WINDOWS {
    jai_exe_name :: "jai.exe";
} else #if OS == .MACOS {
    jai_exe_name :: "jai-macos";
} else #if OS == .LINUX {
    jai_exe_name :: "jai-linux";
}

main :: () {
    context.logger = lsp_log;
    push_table_printer();
    push_tagged_union_printer();

    success, args := parse_arguments(Args);
    if !success {
        log_error("Could not parse arguments");
        exit(1);
    }
    log("Args are %", args);

    server.jai_path = args.jai_path;
    server.verbose = args.verbose;
    server.profile = args.profile;

    if server.jai_path.count == 0 {
        server.jai_path = find_jai_path(jai_exe_name);
        if !server.jai_path {
            log_error("Failed to resolve Jai path");
            // @TODO: Send this fatal error over LSP somehow?
        } else {
            log("Jai path: %", server.jai_path);
        }
    }

    init(*server.projects);
    defer deinit(*server.projects);

    server.workspace_folders.allocator = context.default_allocator;

    init_memory_files();
    defer deinit_memory_files();

    push_allocator(temp);

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

        reset_temporary_storage();
        #if MEMORY_DEBUG report_memory_leaks();
    }

    log("Shutdown");
    exit(0);
}

#import "Compiler";
#import "Basic"()(MEMORY_DEBUGGER=MEMORY_DEBUG);
#import "Print_Vars";
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
#import "xxHash";
#import "Tagged_Union";

#load "rpc.jai";
#load "lsp_interface.jai";
#load "program.jai";
#load "diagnostics.jai";
#load "memory_files.jai";

#load "completition.jai";
#load "goto.jai";
#load "signature_help.jai";
#load "hover.jai";
#load "symbols.jai";
#load "utils.jai";

#if OS == .WINDOWS {
    #import "Windows";
} else {
    #import "POSIX";
}

#import "Debug";