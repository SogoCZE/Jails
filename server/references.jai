// Given an identifier, find where it was originally declared.
//
// Two cases:
//   1. Plain identifier like `foo` — look outward from where it appears, through
//      the surrounding block, the file, and imports, until we find where `foo`
//      was declared.
//   2. Identifier after a dot like `thing.foo` — figure out what type `thing` is,
//      then look inside that type for a field or member called `foo`.
//
// For more complicated things on the left of the dot (like a function call
// result or an array element), we ask get_path_type to work out the type
// and do whatever it can.
resolve_ident_decls :: (ident: *Identifier) -> []*Declaration {
    if ident.parent && ident.parent.kind == .BINARY_OPERATION {
        bop := cast(*Binary_Operation) ident.parent;
        if bop.operation == .DOT && bop.right == ident {
            path := get_dot_path(bop, ident);
            if path.count >= 2 {
                base_path := array_view(path, 0, path.count-1);
                parent_type := get_path_type(base_path);
                if parent_type {
                    decl := get_member_in(parent_type, ident);
                    if decl {
                        out: [..]*Declaration;
                        array_add(*out, decl);
                        return out;
                    }
                }
            }

            return .[];
        }
    }

    return get_identifier_decls(ident);
}

// Resolve whatever the cursor is sitting on to its target declaration(s).
// Returns the name and decls, or ok=false if the cursor isn't on an identifier
// or a declaration's name.
cursor_target :: (file: *Program_File, cursor_location: Node.Location) -> name: string, decls: []*Declaration, ok: bool {
    cursor_node := get_node_by_location(file, cursor_location);
    if !cursor_node return "", .[], false;

    if cursor_node.kind == .IDENTIFIER {
        ident := cast(*Identifier) cursor_node;
        return ident.name, resolve_ident_decls(ident), true;
    }

    if cursor_node.kind == .DECLARATION {
        decl := cast(*Declaration) cursor_node;
        single: [..]*Declaration;
        array_add(*single, decl);
        return decl.name, single, true;
    }

    return "", .[], false;
}

decls_intersect :: (a: []*Declaration, b: []*Declaration) -> bool {
    for x: a for y: b if x == y return true;
    return false;
}

handle_references :: (request: LSP_Request_Message_References) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);
    file := get_file(file_path);
    if !file {
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    target_name, target_decls, ok := cursor_target(file, cursor_location);
    if !ok || target_decls.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    locations: [..]LSP_Location;
    defer array_free(locations);

    if request.params._context.includeDeclaration {
        for decl: target_decls {
            array_add(*locations, node_location_to_lsp_location(decl.location));
        }
    }

    for other_file: server.files {
        for node: other_file.nodes {
            if node.kind != .IDENTIFIER continue;

            other_ident := cast(*Identifier) node;
            if other_ident.name != target_name continue;

            other_decls := resolve_ident_decls(other_ident);
            if decls_intersect(target_decls, other_decls) {
                array_add(*locations, node_location_to_lsp_location(other_ident.location));
            }
        }
    }

    lsp_respond(request.id, locations);
}

handle_implementation :: (request: LSP_Request_Message_Implementation) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);
    file := get_file(file_path);
    if !file {
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    _, decls, ok := cursor_target(file, cursor_location);
    if !ok || decls.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    locations := NewArray(decls.count, LSP_Location);
    defer array_free(locations);

    for decls locations[it_index] = node_location_to_lsp_location(it.location);

    lsp_respond(request.id, locations);
}
