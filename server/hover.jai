handle_hover :: (request: LSP_Request_Message_Hover) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    cursor_block := cast(*Block) get_node_by_location(file, cursor_location, .BLOCK);
    cursor_node := get_node_by_location(file, cursor_location);

    if !cursor_node {
        lsp_respond(request.id, null);
        return;
    }

    if cursor_node.kind != .IDENTIFIER {
        lsp_respond(request.id, null);
        return;
    }

    ident := cast(*Identifier) cursor_node;

    builder: String_Builder;

    if ident.parent && ident.parent.kind == .BINARY_OPERATION {
        result := goto_dot_path_member(file, xx ident.parent, ident);
        if result {
            ast_print(*builder, result);
            lsp_respond(request.id, LSP_Hover.{ contents=builder_to_string(*builder) });
            return;
        }
    }

    type := get_node_type(file, ident);
    if !type {
        lsp_respond(request.id, null);
        return;
    }


    ast_print(*builder, type);
    lsp_respond(request.id, LSP_Hover.{ contents=builder_to_string(*builder) });
}