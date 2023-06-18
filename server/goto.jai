
handle_goto :: (request: LSP_Request_Message_Definition) {
    file_path := request.params.textDocument.uri;
    file_path_without_uri_prefix := replace(file_path, "file://", "");

    file := get_file( file_path);

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);

    node := get_node_by_location(file, cursor_location);
    if !node {
        lsp_respond(request.id, null);
        return;
    }

    cursor_block := get_node_nearest_block(node);

    if node.kind != .IDENTIFIER {
        lsp_respond(request.id, null);
        return;
    }

    ident := cast(*Identifier) node;

    log("Clicked node: % (%)", node.kind, ident.name);

    decls := get_declarations(file, ident.name, cursor_block);

    locations: [..]LSP_Location;
    defer array_free(locations);

    for decls array_add(*locations, node_location_to_lsp_location(it.location));

    lsp_respond(request.id, locations);
}
