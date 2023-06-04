
// This handles clicking on import or load.
handle_import_or_load :: (workspace: *Project_Workspace, request: LSP_Request_Message_Definition, line: string, module: bool, pos: LSP_Position) {
    // start_of_path := find_index_from_left(line, "\"");
    // end_of_path := find_index_from_right(line, "\"");

    // path := slice(line, start_of_path + 1, end_of_path - start_of_path - 1);

    // uri: string;
    // if module {
    //     find_module_in_path :: (modules_path: string, path: string) -> bool, string {
    //         uri := tprint("%/%/module.jai", modules_path, path);
    //         if !file_exists(uri) {
    //             uri = tprint("%/%.jai", modules_path, path);
    //         }
    //         return file_exists(uri), uri;
    //     }

    //     modules_path := workspace.import_path[1]; 
    //     ok: bool;
    //     ok, uri = find_module_in_path(modules_path, path);
    //     if !ok {
    //         ok, uri = find_module_in_path(workspace.local_modules_directory, path);
    //     }
    //     uri = tprint("file://%", uri);
    // } else {
    //     current_file := path_strip_filename(request.params.textDocument.uri);
    //     uri = tprint("%/%", current_file, path); 
    // }

    // range: LSP_Range;
    // range.start.line = pos.line;
    // range.start.character = xx (start_of_path+1);
    // range.end.line = pos.line;
    // range.end.character = xx end_of_path;

    // lsp_respond(request.id, LSP_Location_Link.{
    //     targetUri=uri,
    //     originSelectionRange=range,
    // });
}

handle_goto :: (request: LSP_Request_Message_Definition) {
    file := request.params.textDocument.uri;
    file_without_uri_prefix := replace(file, "file://", "");

    workspace := find_workspace_by_path(file_without_uri_prefix);
    if !workspace {
        log("Cant find workspace for %", file_without_uri_prefix);
        lsp_respond(request.id, null);
        return;
    }


    // line := find_line_in_modified_file(file, request.params.position);

    // if contains(line, "#import") {
    //     handle_import_or_load(workspace, request, line, true, request.params.position);
    //     return;
    // }
    
    // if contains(line, "#load") {
    //     handle_import_or_load(workspace, request, line, false, request.params.position);
    //     return;
    // }

    cursor_location := lsp_location_to_node_location(request.params.position, file);

    node := get_node_by_location(workspace, cursor_location);
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

    


    if node.parent && node.parent.kind == .BINARY_OPERATION {
        log("Parent of clicked %", node.parent.kind);

        // op := cast(*Binary_Operation) node.parent;

        // if op.parent && op.parent.kind == .LITERAL {
        //     decl := get_literal_member(workspace, xx op.parent, ident, cursor_block);
        //     if decl {
        //         lsp_respond(request.id, node_location_to_lsp_location(decl.location));
        //         return;
        //     }
        // } 

        path, root_binary_op := get_path_of_binary_operation(node);

        if root_binary_op.parent && root_binary_op.parent.kind == .LITERAL {
            new_path := NewArray(path.count+1, *Node);
            new_path[0] = get_struct_literal_type(workspace, xx root_binary_op.parent, cursor_block);

            if !new_path[0] {
                lsp_respond(request.id, null);
                return;
            }

            for 1..path.count {
                new_path[it] = path[it-1];
            }

            path = new_path;
        }

        if path[0] != node {
            member_decl := resolve_struct_member_by_path(workspace, path);
            lsp_respond(request.id, node_location_to_lsp_location(member_decl.location));
            return;
        }
        
    }


    decls := get_declarations(workspace, ident.name, cursor_block);

    locations: [..]LSP_Location;
    defer array_free(locations);

    for decls array_add(*locations, node_location_to_lsp_location(it.location));

    lsp_respond(request.id, locations);
}
