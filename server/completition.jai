handle_completitions :: (request: LSP_Request_Message_Completion) {
    file_without_uri_prefix := replace(request.params.textDocument.uri, "file://", "");

    workspace := find_workspace_by_path(file_without_uri_prefix);
    if !workspace {
        log("Cant find workspace for %", file_without_uri_prefix);
        lsp_respond(request.id, null);
        return;
    }

    // cursor_pos := request.params.position;
    // cursor_block := find_block(workspace, xx (cursor_pos.line+1), xx (cursor_pos.character+1), file_without_uri_prefix);

    // completions: [..]LSP_Completion_Item;

    // for decl: workspace.program.declarations_by_name {
    //     if decl.kind != .PROCEDURE continue;

    //     if decl.flags & .SCOPE_FILE && file_without_uri_prefix != decl.location.file continue;
    //     if !path_in_imported_modules_or_files(workspace, decl.location.file) continue;

    //     if !(decl.flags & .IS_GLOBAL) {
    //         decl_block := find_block(workspace, decl.location.l0, decl.location.c0, decl.location.file);
    //         if !decl_block || !cursor_block || decl_block.serial != cursor_block.serial continue;
    //     }

    //     procedure := cast(*Procedure) decl;

    //     lsp_location := declaration_to_lsp_location(decl);

    //     // @TODO: fix this (does not currently work for not opened files)
    //     peeked_procedure := find_range_in_modified_file(decl.location.file, lsp_location.range);

    //     array_add(*completions, .{
    //         label=procedure.name,
    //         kind=xx LSP_Completion_Item.Kind.Function,
    //         insertText=tprint("%()", decl.name),
    //         labelDetails = .{ description=peeked_procedure }
    //     });
    // }

    // lsp_respond(request.id, completions);
    // array_free(completions);
}
