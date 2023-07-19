
handle_goto :: (request: LSP_Request_Message_Definition) {
    file_path := normalize_path(request.params.textDocument.uri);
    defer free(file_path);

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

    if node.kind != .IDENTIFIER {
        lsp_respond(request.id, null);
        return;
    }

    ident := cast(*Identifier) node;

    if ident.parent && ident.parent.kind == .BINARY_OPERATION {
        log("Got binary op!");
        
        result := goto_dot_path_member(file, xx ident.parent, ident);
        if result {
            lsp_respond(request.id, node_location_to_lsp_location(result.location));
            return;
        }
    }

    log("Clicked node: % (%)", node.kind, ident.name);

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