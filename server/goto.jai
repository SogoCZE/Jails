
// This handles clicking on import or load.
handle_import_or_load :: (workspace: *Project_Workspace, request: LSP_Request_Message_Definition, line: string, module: bool, pos: LSP_Position) {
    start_of_path := find_index_from_left(line, "\"");
    end_of_path := find_index_from_right(line, "\"");

    path := slice(line, start_of_path + 1, end_of_path - start_of_path - 1);

    uri: string;
    if module {
        find_module_in_path :: (modules_path: string, path: string) -> bool, string {
            uri := tprint("%/%/module.jai", modules_path, path);
            if !file_exists(uri) {
                uri = tprint("%/%.jai", modules_path, path);
            }
            return file_exists(uri), uri;
        }

        modules_path := workspace.import_path[1]; 
        ok: bool;
        ok, uri = find_module_in_path(modules_path, path);
        if !ok {
            ok, uri = find_module_in_path(workspace.local_modules_directory, path);
        }
        uri = tprint("file://%", uri);
    } else {
        current_file := path_strip_filename(request.params.textDocument.uri);
        uri = tprint("%/%", current_file, path); 
    }

    range: LSP_Range;
    range.start.line = pos.line;
    range.start.character = xx (start_of_path+1);
    range.end.line = pos.line;
    range.end.character = xx end_of_path;

    lsp_respond(request.id, LSP_Location_Link.{
        targetUri=uri,
        originSelectionRange=range,
    });
}

// @TODO: Consider using a compiler for goto resolution based on a clicked symbol (index all symbols - procedure calls, expressions, type instantiation...)
handle_goto :: (request: LSP_Request_Message_Definition) {
    file := request.params.textDocument.uri;
    file_without_uri_prefix := replace(file, "file://", "");

    workspace := find_workspace_by_path(file_without_uri_prefix);
    if !workspace {
        log("Cant find workspace for %", file_without_uri_prefix);
        lsp_respond(request.id, null);
        return;
    }

    line := find_line_in_modified_file(file, request.params.position);

    if contains(line, "#import") {
        handle_import_or_load(workspace, request, line, true, request.params.position);
        return;
    }
    
    if contains(line, "#load") {
        handle_import_or_load(workspace, request, line, false, request.params.position);
        return;
    }

    path := get_cursor_context(file, request.params.position);
    if path.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    base_symbol := path[0];
    base_symbol_block := find_block(workspace, xx (request.params.position.line+1), xx (request.params.position.character+1), file_without_uri_prefix);

    locations: [..]LSP_Location;
    defer array_free(locations);

    declarations := find_declarations(workspace, base_symbol, file_without_uri_prefix, base_symbol_block);
    defer array_free(declarations);

    log("Clicked on % (%)", path, declarations.count);

    // Struct or Enum members
    if path.count > 1 {

        for decl: declarations {
            current_declaration := decl;

            for part: path {
                if it_index == 0 continue; // skip the first one...

                member_decl: *Declaration;

                if current_declaration.kind == {
                    case .ENUM; #through;
                    case .STRUCT; member_decl = find_struct_or_enum_member(workspace, current_declaration, part);

                    case .EXPRESSION;
                        type := get_type_declaration(workspace, (cast(*Expression) current_declaration).type);
                        if !type break;
                        member_decl = find_struct_or_enum_member(workspace, type, part);

                    case .TYPE_INSTANTIATION;
                        type := get_type_declaration(workspace, (cast(*Type_Instantiation) current_declaration).type);
                        if !type break;
                        member_decl = find_struct_or_enum_member(workspace, type, part);
                }

                if !member_decl break;

                current_declaration = member_decl;
            }

            array_add(*locations, declaration_to_lsp_location(current_declaration));
        }

    } else {
        for declarations array_add(*locations, declaration_to_lsp_location(it));
    }

    lsp_respond(request.id, locations);
}
