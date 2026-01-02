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

    if !op {
        return false;
    }

    path := get_dot_path(op, leaf_node);
    if path.count < 2 {
        return false;
    }

    path = array_view(path, 0, path.count-1);

    type := get_path_type(path);
    if !type {
        lsp_respond(request.id, null);
        return true;
    }

    decl := get_member_in(type, ident);
    if !decl {
        lsp_respond(request.id, null);
        return true;
    }

    lsp_respond(request.id, node_location_to_lsp_location(decl.location));
    return true;
}

handle_goto_procedure_named_argument :: (request: LSP_Request_Message_Definition, file: *Program_File, ident: *Identifier) -> bool {
    if !ident.parent || ident.parent.kind != .BINARY_OPERATION {
        return false;
    }

    binary_op := cast(*Binary_Operation) ident.parent;

    // We only want to resolve this if its the left side.
    if binary_op.right == ident {
        return false;
    }

    if !binary_op.parent || binary_op.parent.kind != .PROCEDURE_CALL {
        return false;
    }

    procedure_call := cast(*Procedure_Call) binary_op.parent;

    if !procedure_call.procedure {
        return false;
    }

    // We need to resolve the calle procedure.
    decls := get_identifier_decls(cast(*Identifier) procedure_call.procedure);
    if decls.count == 0 {
        return false;
    }

    procedure_decl := decls[0]; // TODO: here we need to resolve procedure overloading in the future.
    if !procedure_decl.expression {
        return false;
    }

    procedure := cast(*Procedure) procedure_decl.expression;

    for arg: procedure.arguments {
        unwrapped_arg := unwrap_polymorphic_constant(arg);

        // It should always be decl??
        if unwrapped_arg.kind != .DECLARATION {
            log("arg.kind: %", arg.kind);
            continue;
        }

        arg_decl := cast(*Declaration) unwrapped_arg;

        if arg_decl.name == ident.name {
            lsp_respond(request.id, node_location_to_lsp_location(arg_decl.location));
            return true;
        }
    }

    return false;
}

handle_goto_struct_literal :: (request: LSP_Request_Message_Definition, file: *Program_File, ident: *Identifier) -> bool {
    if !ident.parent || ident.parent.kind != .BINARY_OPERATION {
        return false;
    }

    binary_op := cast(*Binary_Operation) ident.parent;

    // We only want to resolve this if its the left side.
    if binary_op.right == ident {
        return false;
    }

    if !binary_op.parent || binary_op.parent.kind != .LITERAL {
        return false;
    }

    literal := cast(*Literal) binary_op.parent;

    // TODO: Infer the type for .{} structs literals...
    if literal.value_type != .STRUCT || !literal.struct_literal_info.type || literal.struct_literal_info.type.kind != .IDENTIFIER {
        return false;
    }

    // We need to resolve struct literal type.
    decls := get_identifier_decls(cast(*Identifier) literal.struct_literal_info.type);
    if decls.count == 0 {
        return false;
    }

    struct_decl := decls[0];
    if !struct_decl.expression {
        return false;
    }


    _struct := cast(*Struct) struct_decl.expression;

    decl := get_member_in(_struct, ident);
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

handle_procedure_call_goto :: (request: LSP_Request_Message_Definition, ident: *Identifier) -> bool {
    if !ident.parent || ident.parent.kind != .PROCEDURE_CALL {
        return false;
    }

    proc_call := cast(*Procedure_Call) ident.parent;

    decls := get_identifier_decls(ident);
    if decls.count == 0 {
        return false;
    }

    procedures: [..]*Procedure;
    for proc_decl: decls {
        type := get_node_type(proc_decl, stop_at_procedure=true);
        if type.kind != .PROCEDURE {
            remove proc_decl;
            continue;
        }

        array_add(*procedures, cast(*Procedure) type);
    }

    if procedures.count == 0 {
        return false;
    }

    best_override_index := get_best_overload_for_procedure_call(procedures, proc_call);

    if !procedures[best_override_index].parent {
        return false;
    }

    lsp_respond(request.id, node_location_to_lsp_location(procedures[best_override_index].parent.location));
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

    cursor_node := get_node_by_location(file, cursor_location);
    if !cursor_node {
        lsp_respond(request.id, null);
        return;
    }

    log("Clicked node: %", cursor_node.kind);

    if cursor_node.kind == .DIRECTIVE_LOAD {
        handle_goto_load(request, file, xx cursor_node);
        return;
    }

    if cursor_node.kind == .DIRECTIVE_IMPORT {
        handle_goto_import(request, file, xx cursor_node);
        return;
    }

    if cursor_node.kind != .IDENTIFIER {
        lsp_respond(request.id, null);
        return;
    }

    ident := cast(*Identifier) cursor_node;

    if handle_goto_procedure_named_argument(request, file, ident) {
        return;
    }

    if handle_goto_struct_literal(request, file, ident) {
        return;
    }

    if handle_goto_assignment(request, ident) {
        return;
    }

    if handle_goto_dot(request, ident) {
        return;
    }

    if handle_procedure_call_goto(request, ident) {
        return;
    }

    decls := get_identifier_decls(ident);
    if decls.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    locations := NewArray(decls.count, LSP_Location);
    defer array_free(locations);

    for decls locations[it_index] = node_location_to_lsp_location(it.location);

    lsp_respond(request.id, locations);
}
