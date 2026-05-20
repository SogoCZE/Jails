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
    if !ident return false;

    decls, matched := resolve_dot_member(ident);
    if !matched return false;

    if decls.count == 0 {
        lsp_respond(request.id, null);
        return true;
    }

    lsp_respond(request.id, node_location_to_lsp_location(decls[0].location));
    return true;
}

handle_goto_procedure_named_argument :: (request: LSP_Request_Message_Definition, file: *Program_File, ident: *Identifier) -> bool {
    decls, matched := resolve_procedure_named_argument(ident);
    if !matched || decls.count == 0 return false;

    lsp_respond(request.id, node_location_to_lsp_location(decls[0].location));
    return true;
}

handle_goto_struct_literal :: (request: LSP_Request_Message_Definition, file: *Program_File, ident: *Identifier) -> bool {
    decls, matched := resolve_struct_literal_field(ident);
    if !matched || decls.count == 0 return false;

    lsp_respond(request.id, node_location_to_lsp_location(decls[0].location));
    return true;
}

handle_goto_assignment :: (request: LSP_Request_Message_Definition, ident: *Identifier) -> bool {
    decls, matched := resolve_assignment_field(ident);
    if !matched || decls.count == 0 return false;

    lsp_respond(request.id, node_location_to_lsp_location(decls[0].location));
    return true;
}

handle_procedure_call_goto :: (request: LSP_Request_Message_Definition, ident: *Identifier) -> bool {
    decls, matched := resolve_procedure_call_best(ident);
    if !matched || decls.count == 0 return false;

    proc_decl := decls[0];
    type := get_node_type(proc_decl, stop_at_procedure=true);
    if !type || type.kind != .PROCEDURE return false;
    procedure := cast(*Procedure) type;
    if !procedure.parent return false;

    lsp_respond(request.id, node_location_to_lsp_location(procedure.parent.location));
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

    // log("Clicked node: %", cursor_node.kind);

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
