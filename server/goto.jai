
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
        path, binary_op := get_path_of_binary_operation(ident);

        if path.count > 1 && binary_op.operation == .DOT {
            current_base := cast(*Identifier) path[0];
            current_decl: *Declaration;

            i := 1;
            for i..path.count-1 {
                target := cast(*Identifier) path[i];
                
                current_decl = get_declaration_from_base(file, current_base, target);
                if !current_decl break;

                current_base = unwrap_identifier(current_decl);
                i += 1;
            }        

            if !current_decl {
                lsp_respond(request.id, null);
                return;
            }

            lsp_respond(request.id, node_location_to_lsp_location(current_decl.location));
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
