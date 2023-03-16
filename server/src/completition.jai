handle_completitions :: (request: LSP_Request_Message_Completion) {
    file_without_uri_prefix := replace(request.params.textDocument.uri, "file://", "");

    cursor_pos := request.params.position;

    for block: program_cache.code_blocks {
        if block.location.file != file_without_uri_prefix continue;
        
        if block.location.l0 > xx cursor_pos.line continue;
        if block.location.l1 < xx cursor_pos.line continue;

        if block.location.l0 == xx cursor_pos.line && block.location.c0 > xx cursor_pos.character continue;
        if block.location.l1 == xx cursor_pos.line && block.location.c1 < xx cursor_pos.character continue;

        log("Block Serial: % (loc: %)", block.serial, block.location);
    }

    completions: [..]LSP_Completion_Item;

    for decl: program_cache.declarations_by_name {
        if !(decl.flags & .IS_GLOBAL) continue;
        if decl.kind != .PROCEDURE continue;

        if decl.flags & .SCOPE_FILE && file_without_uri_prefix != decl.location.file continue;
        if !path_in_imported_modules_or_files(decl.location.file) continue;

        procedure := cast(*Procedure) decl;

        lsp_location := declaration_to_lsp_location(decl);

        peeked_procedure := find_range_in_file(decl.location.file, lsp_location.range);

        array_add(*completions, .{
            label=procedure.name,
            kind=xx LSP_Completion_Item.Kind.Function,
            insertText=tprint("%()", decl.name),
            labelDetails = .{ description=peeked_procedure }
        });
    }

    lsp_respond(request.id, completions);
    array_free(completions);
}