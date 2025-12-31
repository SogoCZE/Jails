handle_signature_help :: (request: LSP_Request_Message_Signature_Help) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        log("Not file!");
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    cursor_block := cast(*Block) get_node_by_location(file, cursor_location, .BLOCK);
    cursor_node := get_node_by_location(file, cursor_location);
    if !cursor_node {
        lsp_respond(request.id, null);
        return;
    }

    proc_call := cast(*Procedure_Call) get_node_nearest_parent(cursor_node, kind => kind == .PROCEDURE_CALL);
    if !proc_call {
        lsp_respond(request.id, null);
        return;
    }

    proc_call_ident := cast(*Identifier) proc_call.procedure;
    if !proc_call_ident {
        lsp_respond(request.id, null);
        return;
    }

    proc_decls: [..]*Declaration;

    if proc_call.parent && proc_call.parent.kind == .BINARY_OPERATION && proc_call.parent.(*Binary_Operation).operation == .DOT {
        path := get_dot_path(cast(*Binary_Operation) proc_call.parent, proc_call);
        if path.count <= 1 {
            lsp_respond(request.id, null);
            return;
        }
        path = array_view(path, 0, path.count-1);

        type := get_path_type(path);
        if !type {
            lsp_respond(request.id, null);
            return;
        }

        decls := get_members_in(type, proc_call_ident);
        array_add(*proc_decls, ..decls);
    } else {
        decls := get_declarations(file, cursor_block, *cursor_location, proc_call_ident.name);
        if decls.count == 0 {
            lsp_respond(request.id, null);
            return;
        }

        array_copy(*proc_decls, decls);
    }

    procedures: [..]*Procedure;
    for proc_decl: proc_decls {
        if !proc_decl {
            remove proc_decl;
            continue;
        }

        type := get_node_type(proc_decl, stop_at_procedure=true);
        if type.kind != .PROCEDURE {
            remove proc_decl;
            continue;
        }

        array_add(*procedures, cast(*Procedure) type);
    }

    if proc_decls.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    signatures: [..]LSP_Signature_Information;
    for proc_decl: proc_decls {
        array_add(*signatures, turn_procedure_into_signature_information(proc_decl, procedures[it_index], proc_call, cursor_location));
    }

    signature_help: LSP_Signature_Help;
    signature_help.activeSignature = cast(u32) get_best_overload_for_procedure_call(procedures, proc_call);
    signature_help.signatures = signatures;

    lsp_respond(request.id, signature_help);
}

turn_procedure_into_signature_information :: (proc_decl: *Declaration, procedure: *Procedure, proc_call: *Procedure_Call, cursor_location: Node.Location) -> LSP_Signature_Information {
    builder: String_Builder;
    print_to_builder(*builder, "% :: ", proc_decl.name);
    ast_print(*builder, procedure);

    signature_help_info: LSP_Signature_Information;
    signature_help_info.label = builder_to_string(*builder);

    signature_help_info.activeParameter = 0;
    if proc_call.arguments.count > 0 {
        signature_help_info.activeParameter = cast(u32) proc_call.arguments.count-1;
    }

    signature_help_info.parameters = NewArray(procedure.arguments.count, LSP_Parameter_Information);

    already_have_active_arg: bool;

    for arg: procedure.arguments {

        if it_index < proc_call.arguments.count {
            proc_call_arg := proc_call.arguments[it_index];

            if !is_after(proc_call_arg.location, cursor_location) && !already_have_active_arg {
                signature_help_info.activeParameter = xx it_index;
                already_have_active_arg = true;
            }

            if it_index == proc_call.arguments.count-1 && !already_have_active_arg && it_index != procedure.arguments.count-1 {
                signature_help_info.activeParameter = xx (it_index+1);
            }

        }

        reset(*builder);
        ast_print(*builder, arg);
        signature_help_info.parameters[it_index] = .{
            label=builder_to_string(*builder)
        };
    }

    return signature_help_info;
}
