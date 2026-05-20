handle_hover :: (request: LSP_Request_Message_Hover) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);

    if inside_comment(cursor_location) {
        lsp_respond(request.id, null);
        return;
    }

    cursor_node := get_node_by_location(file, cursor_location);
    if !cursor_node {
        lsp_respond(request.id, null);
        return;
    }

    target_decl: *Declaration;

    if cursor_node.kind == {
        case .IDENTIFIER;
            ident := cast(*Identifier) cursor_node;
            decls := resolve_identifier_for_hover(ident);
            if decls.count > 0 target_decl = decls[0];

        case .DECLARATION;
            target_decl = cast(*Declaration) cursor_node;
    }

    if !target_decl {
        lsp_respond(request.id, null);
        return;
    }

    builder: String_Builder;
    append(*builder, "```jai\n");
    append_decl_for_hover(*builder, target_decl);
    append(*builder, "\n```");

    hover: LSP_Hover;
    hover.contents.value = builder_to_string(*builder);
    lsp_respond(request.id, hover);
}

append_decl_for_hover :: (builder: *String_Builder, decl: *Declaration) {
    expr := decl.expression;
    if expr && (expr.kind == .STRUCT || expr.kind == .ENUM || expr.kind == .UNION) {
        if decl.backticked append(builder, #char "`");
        append(builder, decl.name);
        append(builder, " :: ");

        if expr.kind == {
            case .STRUCT; append(builder, "struct");
            case .ENUM;   append(builder, "enum");
            case .UNION;  append(builder, "union");
        }

        block := get_block_of(expr);
        if block && block.members.count > 0 {
            append(builder, " {\n");
            for member: block.members {
                append(builder, "    ");
                ast_print(builder, member);
                append(builder, ";\n");
            }
            append(builder, "}");
        }

        return;
    }

    if expr && expr.kind == .DIRECTIVE_TYPE {
        directive_type := cast(*Directive_Type) expr;
        if decl.backticked append(builder, #char "`");
        append(builder, decl.name);
        append(builder, " :: #type");
        if directive_type.isa      append(builder, ",isa");
        if directive_type.distinct append(builder, ",distinct");
        if directive_type.expression {
            append(builder, " ");
            ast_print(builder, directive_type.expression);
        }
        return;
    }

    ast_print(builder, decl);
}

