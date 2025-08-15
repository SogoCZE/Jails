handle_goto_load :: (file: *Program_File, _load: *Directive_Load) -> LSP_Location_Link {
    file_path_without_filename := trim_right(path_strip_filename(file.path), "/");
    load_absolute_path := join(file_path_without_filename, _load.file, separator="/");

    lsp_location: LSP_Location_Link;
    lsp_location.originSelectionRange = .{
        start=.{line=xx _load.location.l0, character=xx(_load.location.c1 - _load.file.count-1)},
        end=.{line=xx _load.location.l0, character=xx(_load.location.c1-1)}
    };
    lsp_location.targetUri = path_to_lsp_path(load_absolute_path);

    return lsp_location;
}

handle_goto_import :: (file: *Program_File, _import: *Directive_Import) -> LSP_Location_Link {
    file_path_without_filename := trim_right(path_strip_filename(file.path), "/");
    module_absolute_path := get_module_import_path(_import, file_path_without_filename);

    lsp_location: LSP_Location_Link;
    lsp_location.originSelectionRange = .{
        start=.{line=xx _import.location.l0, character=xx(_import.location.c1 - _import.module.count-1)},
        end=.{line=xx _import.location.l0, character=xx(_import.location.c1-1)}
    };
    lsp_location.targetUri = path_to_lsp_path(module_absolute_path);
    return lsp_location;
}

handle_goto_dot :: (ident: *Identifier) -> bool, LSP_Location {
    if !ident || !ident.parent {
        return false, .{};
    }

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

    if !op {
        return false, .{};
    }

    path := get_dot_path(op, leaf_node);
    if path.count < 2 {
        return false, .{};
    }

    path = array_view(path, 0, path.count-1);

    type := get_path_type(path);
    if !type {
        return false, .{};
    }

    decl := get_member_in(type, ident);
    if !decl {
        return false, .{};
    }

    return true, node_location_to_lsp_location(decl.location);
}

handle_goto_assignment :: (ident: *Identifier) -> bool, LSP_Location {
    if !ident.parent || ident.parent.kind != .UNARY_OPERATION {
        return false, .{};
    }

    unary_op := cast(*Unary_Operation, ident.parent);
    if unary_op.operation != .DOT {
        return false, .{};
    }

    if !unary_op.parent || unary_op.parent.kind != .BINARY_OPERATION  {
        return false, .{};
    }

    binary_op_type := get_node_type(unary_op.parent, true);
    if !binary_op_type {
        return false, .{};
    }

    decl := get_member_in(binary_op_type, ident);
    if !decl {
        return false, .{};
    }

    return true, node_location_to_lsp_location(decl.location);
}

calc_goto :: (file_path: string, position: LSP_Position) -> []Generic_Location {
    file := get_file(file_path);
    if !file {
        log_error("File does not exists or has not been parsed yet! (%)", file_path);
        return .[];
    }

    cursor_location := lsp_location_to_node_location(position, file_path);
    node := get_node_by_location(file, cursor_location);
    if !node {
        return .[];
    }

    log("Clicked node: %", node.kind);

    if node.kind == .DIRECTIVE_LOAD {
        return .[generic_location(handle_goto_load(file, xx node))];
    }

    if node.kind == .DIRECTIVE_IMPORT {
        return .[generic_location(handle_goto_import(file, xx node))];
    }

    if node.kind != .IDENTIFIER {
        return .[];
    }

    ident := cast(*Identifier) node;
    log("Ident: %", ident.name);

    ok, loc := handle_goto_assignment(ident);
    if ok {
        return .[generic_location(loc)];
    }

    ok, loc = handle_goto_dot(ident);
    if ok {
        return .[generic_location(loc)];
    }


    decls := get_identifier_decl(ident);
    if decls.count == 0 {
        return .[];
    }

    locations := NewArray(decls.count, Generic_Location);
    for decls {
        set(*locations[it_index], node_location_to_lsp_location(it.location));
    }
    return locations;
}
