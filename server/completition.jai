

handle_completitions :: (request: LSP_Request_Message_Completion) {
    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        log_error("File does not exists or has not been parser yet! (%)", file_path);
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    block := cast(*Block) get_node_by_location(file, cursor_location, .BLOCK);

    if block {
        log("Block: %", block.*);
    }

    decls := get_all_declarations(file, block, *cursor_location);
    defer array_free(decls);

    completions: [..]LSP_Completion_Item;
    defer array_free(completions);

    for decl: decls {
        if !decl.expression || decl.expression.kind != .PROCEDURE continue;

        lsp_loc := node_location_to_lsp_location(decl.location);

        procedure_header_builder: String_Builder;
        init_string_builder(*procedure_header_builder);        
        ast_print_procedure_header(*procedure_header_builder, xx decl.expression); // @Memory @TODO: we need to free this afterwards!!
        procedure_header_preview := builder_to_string(*procedure_header_builder);

        array_add(*completions, .{
            label=decl.name,
            kind=xx LSP_Completion_Item.Kind.Function,
            insertText=tprint("%()", decl.name),
            labelDetails = .{ description=procedure_header_preview }
        });
    }

    lsp_respond(request.id, completions);
}

