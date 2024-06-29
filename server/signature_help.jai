handle_signature_help :: (request: LSP_Request_Message_Signature_Help) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    cursor_block := cast(*Block) get_node_by_location(file, cursor_location, .BLOCK);
    cursor_node := get_node_by_location(file, cursor_location);

    proc_call := cast(*Procedure_Call) get_node_nearest_parent(cursor_node, kind => kind == .PROCEDURE_CALL);
    if !proc_call {
        lsp_respond(request.id, null);
        return;
    }

    proc_call_ident := cast(*Identifier) proc_call.procedure;

    decls := get_declarations(file, cursor_block, *cursor_location, proc_call_ident.name);
    if decls.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    proc_decl := decls[0];
    if !proc_decl.expression || proc_decl.expression.kind != .PROCEDURE {
        lsp_respond(request.id, null);
        return;
    }

    procedure := cast(*Procedure) proc_decl.expression;

    builder: String_Builder;
    ast_print(*builder, proc_decl);

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

    signature_help: LSP_Signature_Help;
    signature_help.activeSignature = 0;
    signature_help.signatures = .[signature_help_info];

    lsp_respond(request.id, signature_help);
}