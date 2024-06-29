

handle_completitions :: (request: LSP_Request_Message_Completion) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    _exit :: () #expand {
        `lsp_respond(request.id, null);
        `return;
    }

    file := get_file(file_path);
    if !file {
        _exit();
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);
    cursor_block := cast(*Block) get_node_by_location(file, cursor_location, .BLOCK);
    cursor_node := get_node_by_location(file, cursor_location);

    // We don't wanna to give completions inside strings and comments...
    if cursor_node && (cursor_node.kind == Node.Kind.LITERAL || cursor_node.kind == Node.Kind.COMMENT) _exit();

    decls: []*Declaration;
    defer array_free(decls);

    // Binary OP
    if cursor_node && cursor_node.kind == .BINARY_OPERATION {
        decls = get_dot_path_members(file, xx cursor_node);
        if decls.count > 0 {
            send_completions_decls(request, decls);
            return;
        }
    }

    if cursor_node && cursor_node.parent && cursor_node.parent.kind == .BINARY_OPERATION {
        decls = get_dot_path_members(file, xx cursor_node.parent);
        if decls.count > 0 {
            send_completions_decls(request, decls);
            return;
        }
    }


    if cursor_block log("Block: %", cursor_block.*);

    // General
    decls = get_declarations(file, cursor_block, *cursor_location);

    send_completions_decls(request, decls);
}


// @TODO: maybe move this to program?
get_dot_path_members :: (file: *Program_File, binary_op: *Binary_Operation) -> []*Declaration {
    members: [..]*Declaration;

    if binary_op.operation != .DOT return members;

    if !binary_op.left return members;

    decl := goto_dot_path_member(file, binary_op, xx binary_op.left);
    if !decl return members;

    decl_type := get_node_type(file, decl);
    if !decl_type return members;

    block := get_block_of(decl_type);
    if !block return members;

    for member: block.members {
        if member.kind != .DECLARATION continue;
        array_add(*members, xx member);
    }

    return members;
}

send_completions_decls :: (request: LSP_Request_Message_Completion, decls: []*Declaration) {
    completions: [..]LSP_Completion_Item;
    defer array_free(completions);

    for decl: decls {
        if !decl.expression && !decl.type_inst continue;

        kind: LSP_Completion_Item.Kind;
        preview_node: *Node;
        insert_text: string;

        if decl.expression {
            preview_node = decl.expression;
        } else {
            preview_node = decl.type_inst;
        }

        if preview_node.kind == {
            case .PROCEDURE;
                kind = .Function;
                insert_text = sprint("%($0)", decl.name);

            case .STRUCT;
                kind = .Struct;
                insert_text = decl.name;

            case .ENUM;
                kind = .Enum;
                insert_text = decl.name;

            case;
                kind = .Variable;
                insert_text = decl.name;
        }

        lsp_loc := node_location_to_lsp_location(decl.location);

        procedure_header_builder: String_Builder;
        init_string_builder(*procedure_header_builder);
        ast_print(*procedure_header_builder, preview_node); // @Memory @TODO: we need to free this afterwards!!
        procedure_header_preview := builder_to_string(*procedure_header_builder);

        array_add(*completions, .{
            label=decl.name,
            kind=xx kind,
            insertText=insert_text,
            insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
            labelDetails = .{ description=procedure_header_preview }
        });
    }

    lsp_respond(request.id, completions);
}