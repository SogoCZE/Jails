handle_goto_load :: (request: LSP_Request_Message_Definition, file: *Program_File, _load: *Directive_Load) {
    file_path_without_filename := trim_right(path_strip_filename(file.path), "/");
    load_absolute_path := join(file_path_without_filename, _load.file, separator="/");

    lsp_location: LSP_Location_Link;
    lsp_location.originSelectionRange = .{
        start=.{line=xx _load.location.l0, character=xx(_load.location.c1 - _load.file.count-1)},
        end=.{line=xx _load.location.l0, character=xx(_load.location.c1-1)}
    };
    lsp_location.targetUri = path_to_lsp_path(load_absolute_path);

    lsp_respond(request.id, lsp_location);
}

handle_goto_import :: (request: LSP_Request_Message_Definition, file: *Program_File, _import: *Directive_Import) {
    push_allocator(temp);

    file_path_without_filename := trim_right(path_strip_filename(file.path), "/");
    module_absolute_path := get_module_import_path(_import, file_path_without_filename);

    lsp_location: LSP_Location_Link;
    lsp_location.originSelectionRange = .{
        start=.{line=xx _import.location.l0, character=xx(_import.location.c1 - _import.module.count-1)},
        end=.{line=xx _import.location.l0, character=xx(_import.location.c1-1)}
    };
    lsp_location.targetUri = path_to_lsp_path(module_absolute_path);

    lsp_respond(request.id, lsp_location);
}

handle_goto_dot :: (request: LSP_Request_Message_Definition, ident: *Identifier) -> bool {
    if !ident || !ident.parent return false;

    leaf_node: *Node;
    op: *Binary_Operation;

    if ident.parent.kind == {
        case .BINARY_OPERATION;
            op = cast(*Binary_Operation) ident.parent;
            leaf_node = ident;

        case .ARRAY_SUBSCRIPT;
            array_subscript := cast(*Array_Subscript) ident.parent;
            if array_subscript.parent && array_subscript.parent.kind == .BINARY_OPERATION {
                op = cast(*Binary_Operation) array_subscript.parent;
                leaf_node = array_subscript;
            }

        case .PROCEDURE_CALL;
            proc_call := cast(*Procedure_Call) ident.parent;
            if proc_call.parent && proc_call.parent.kind == .BINARY_OPERATION {
                op = cast(*Binary_Operation) proc_call.parent;
                leaf_node = proc_call;
            }

        // @TODO: anything else?
    }

    if !op return false;

    path := get_dot_path(op, leaf_node);
    if path.count < 2 {
        return false;
    }

    path = array_view(path, 0, path.count-1);

    type := get_path_type(path);
    if !type {
        return false;
    }

    decl := get_member_in(type, ident);
    if !decl {
        return false;
    }

    lsp_respond(request.id, node_location_to_lsp_location(decl.location));

    return true;
}

handle_goto_assignment :: (request: LSP_Request_Message_Definition, ident: *Identifier) -> bool {
    if !ident.parent || ident.parent.kind != .UNARY_OPERATION {
        return false;
    }

    unary_op := cast(*Unary_Operation, ident.parent);
    if unary_op.operation != .DOT {
        return false;
    }

    if !unary_op.parent || unary_op.parent.kind != .BINARY_OPERATION  {
        return false;
    }

    binary_op_type := get_node_type(unary_op.parent, true);
    if !binary_op_type {
        return false;
    }

    decl := get_member_in(binary_op_type, ident);
    if !decl {
        return false;
    }

    lsp_respond(request.id, node_location_to_lsp_location(decl.location));

    return true;
}

handle_goto :: (request: LSP_Request_Message_Definition) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

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

    log("Clicked node: %", node.kind);

    if node.kind == .DIRECTIVE_LOAD {
        handle_goto_load(request, file, xx node);
        return;
    }

    if node.kind == .DIRECTIVE_IMPORT {
        handle_goto_import(request, file, xx node);
        return;
    }

    if node.kind != .IDENTIFIER {
        lsp_respond(request.id, null);
        return;
    }

    ident := cast(*Identifier) node;
    log("Ident: %", ident.name);

    if handle_goto_assignment(request, ident) {
        return;
    }

    if handle_goto_dot(request, ident) {
        return;
    }


    decls := get_identifier_decl(ident);
    if decls.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    locations := NewArray(decls.count, LSP_Location);
    defer array_free(locations);

    for decls locations[it_index] = node_location_to_lsp_location(it.location);

    lsp_respond(request.id, locations);
}
