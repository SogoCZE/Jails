decl_name_range :: (decl: *Declaration) -> Node.Location {
    name_length := decl.name.count;
    if decl.backticked name_length += 2;

    loc := decl.location;
    loc.l1 = loc.l0;
    loc.c1 = loc.c0 + name_length;
    return loc;
}

rename_new_json_object :: () -> *JSON_Object {
    return New(JSON_Object);
}

rename_json_number :: (n: int) -> JSON_Value {
    return .{type=.NUMBER, number=cast(float64) n};
}

rename_json_string :: (s: string) -> JSON_Value {
    return .{type=.STRING, str=s};
}

rename_json_object :: (obj: *JSON_Object) -> JSON_Value {
    return .{type=.OBJECT, object=obj};
}

rename_json_array :: (arr: []JSON_Value) -> JSON_Value {
    return .{type=.ARRAY, array=arr};
}

rename_position_to_json :: (line: int, character: int) -> JSON_Value {
    obj := rename_new_json_object();
    table_set(obj, "line", rename_json_number(line));
    table_set(obj, "character", rename_json_number(character));
    return rename_json_object(obj);
}

rename_range_to_json :: (loc: Node.Location) -> JSON_Value {
    obj := rename_new_json_object();
    table_set(obj, "start", rename_position_to_json(loc.l0, loc.c0));
    table_set(obj, "end", rename_position_to_json(loc.l1, loc.c1));
    return rename_json_object(obj);
}

rename_text_edit_to_json :: (loc: Node.Location, new_text: string) -> JSON_Value {
    obj := rename_new_json_object();
    table_set(obj, "range", rename_range_to_json(loc));
    table_set(obj, "newText", rename_json_string(new_text));
    return rename_json_object(obj);
}

Rename_Edit :: struct {
    location: Node.Location;
}

handle_rename :: (request: LSP_Request_Message_Rename) {
    push_allocator(temp);

    new_name := trim(request.params.newName);
    if new_name.count == 0 {
        lsp_respond_with_error(request.id, .INVALID_PARAMS, "newName cannot be empty", "");
        return;
    }

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        log_error("File does not exist or has not been parsed yet! (%)", file_path);
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    cursor_node := get_node_by_location(file, cursor_location);
    if !cursor_node {
        lsp_respond(request.id, null);
        return;
    }

    target_name: string;
    target_decls: [..]*Declaration;

    if cursor_node.kind == {
        case .IDENTIFIER;
            ident := cast(*Identifier) cursor_node;
            target_name = ident.name;
            decls := resolve_identifier_for_rename(ident);
            for decls array_add(*target_decls, it);

        case .DECLARATION;
            decl := cast(*Declaration) cursor_node;
            if decl.name.count == 0 {
                lsp_respond(request.id, null);
                return;
            }
            target_name = decl.name;
            array_add(*target_decls, decl);

        case;
            lsp_respond(request.id, null);
            return;
    }

    if target_name.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    Edits_Per_File :: struct {
        path: string;
        locations: [..]Node.Location;
    }

    add_location :: (per_file: *Edits_Per_File, loc: Node.Location) {
        for per_file.locations {
            if it.l0 == loc.l0 && it.c0 == loc.c0 && it.l1 == loc.l1 && it.c1 == loc.c1 && it.file == loc.file {
                return;
            }
        }
        array_add(*per_file.locations, loc);
    }

    files_table: Table(string, *Edits_Per_File);

    get_or_make :: (table: *Table(string, *Edits_Per_File), path: string) -> *Edits_Per_File {
        ok, existing := table_find(table, path);
        if ok return existing;

        entry := New(Edits_Per_File);
        entry.path = path;
        table_add(table, path, entry);
        return entry;
    }

    for target_decl: target_decls {
        loc := decl_name_range(target_decl);
        if loc.file.count == 0 continue;
        entry := get_or_make(*files_table, loc.file);
        add_location(entry, loc);
    }

    // @SPEED: walks every identifier in every parsed file and re-resolves each one.
    for file_iter: server.files {
        for node: file_iter.nodes {
            if node.kind != .IDENTIFIER continue;

            ident := cast(*Identifier) node;
            if ident.name != target_name continue;

            if ident.location.file.count == 0 continue;

            decls := resolve_identifier_for_rename(ident);

            matches: bool;
            for decl: decls {
                for target: target_decls {
                    if decl == target {
                        matches = true;
                        break decl;
                    }
                }
            }

            if !matches continue;

            entry := get_or_make(*files_table, ident.location.file);
            add_location(entry, ident.location);
        }
    }

    changes_obj := rename_new_json_object();

    for entry: files_table {
        if entry.locations.count == 0 continue;

        edits_arr := NewArray(entry.locations.count, JSON_Value);
        for entry.locations {
            edits_arr[it_index] = rename_text_edit_to_json(it, new_name);
        }

        table_set(changes_obj, path_to_lsp_path(entry.path), rename_json_array(edits_arr));
    }

    result: LSP_Rename_Result;
    result.changes = rename_json_object(changes_obj);

    lsp_respond(request.id, result);
}
