handle_goto_load :: (request: LSP_Request_Message_Definition, file: *Program_File, _load: *Directive_Load) {
    file_path_without_filename := trim_right(path_strip_filename(file.path), "/");
    load_absolute_path := join(file_path_without_filename, _load.file, separator="/");

    lsp_location: LSP_Location_Link;
    lsp_location.originSelectionRange = .{
        start=.{line=xx _load.location.l0, character=xx(_load.location.c1 - _load.file.count-1)},
        end=.{line=xx _load.location.l0, character=xx(_load.location.c1-1)}
    };
    lsp_location.targetUri = path_to_lsp_path(load_absolute_path);

    lsp_respond(request.id, lsp_location);
}

handle_goto_import :: (request: LSP_Request_Message_Definition, file: *Program_File, _import: *Directive_Import) {
    push_allocator(temp);

    file_path_without_filename := trim_right(path_strip_filename(file.path), "/");
    module_absolute_path := get_module_import_path(_import, file_path_without_filename);

    lsp_location: LSP_Location_Link;
    lsp_location.originSelectionRange = .{
        start=.{line=xx _import.location.l0, character=xx(_import.location.c1 - _import.module.count-1)},
        end=.{line=xx _import.location.l0, character=xx(_import.location.c1-1)}
    };
    lsp_location.targetUri = path_to_lsp_path(module_absolute_path);

    lsp_respond(request.id, lsp_location);
}

handle_goto :: (request: LSP_Request_Message_Definition) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        log_error("File does not exists or has not been parser yet! (%)", file_path);
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);

    node := get_node_by_location(file, cursor_location);
    if !node {
        lsp_respond(request.id, null);
        return;
    }

    log("Clicked node: %", node.kind);

    if node.kind == .DIRECTIVE_LOAD {
        handle_goto_load(request, file, xx node);
        return;
    }

    if node.kind == .DIRECTIVE_IMPORT {
        handle_goto_import(request, file, xx node);
        return;
    }

    if node.kind != .IDENTIFIER {
        lsp_respond(request.id, null);
        return;
    }

    ident := cast(*Identifier) node;
    log("Ident: %", ident.name);

    if ident.parent && ident.parent.kind == .BINARY_OPERATION {
        binary_op := cast(*Binary_Operation) ident.parent;

        // @TODO: make this more robust!
        // --------
        // This is for cases like entity.name = "Foo";
        if binary_op.operation != .DOT && binary_op.parent && binary_op.parent.kind == .BINARY_OPERATION {
            binary_op = xx binary_op.parent;
        }

        result := goto_dot_path_member(file, binary_op, ident);
        if result {
            lsp_respond(request.id, node_location_to_lsp_location(result.location));
            return;
        }
    }


    decls := get_identifier_decl(file, ident);
    if decls.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    locations := NewArray(decls.count, LSP_Location);
    defer array_free(locations);

    for decls locations[it_index] = node_location_to_lsp_location(it.location);

    lsp_respond(request.id, locations);
}

// @TODO: maybe move this to program?
goto_dot_path_member :: (file: *Program_File, binary_op: *Binary_Operation, ident: *Identifier) -> *Declaration {
    if binary_op.operation != .DOT return null;

    root_op := get_root_of_dot_path(binary_op);
    if !root_op return null;

    result := get_dot_path_result(file, root_op, ident);
    if !result return null;

    return result;
}