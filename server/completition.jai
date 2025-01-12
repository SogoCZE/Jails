

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

    if cursor_node && cursor_node.kind == .DIRECTIVE_IMPORT {
        handle_completitions_import(request, xx cursor_node);
        return;
    }

    if cursor_node && cursor_node.kind == .DIRECTIVE_LOAD {
        handle_completitions_load(request, file, xx cursor_node);
        return;
    }

    decls: []*Declaration;
    defer array_free(decls);

    if handle_dot_completitions(request, cursor_node) {
        return;
    }

    if handle_assignment_completitions(request, cursor_node) {
        return;
    }

    // Binary OP
    // if cursor_node && cursor_node.kind == .BINARY_OPERATION {
    //     op := cast(*Binary_Operation) cursor_node;

    //     decls = get_dot_path_members(cast(*Binary_Operation) cursor_node);
    //     if decls.count > 0 {
    //         send_completions_decls(request, decls);
    //         return;
    //     }
    // }

    // if cursor_node && cursor_node.parent && cursor_node.parent.kind == .BINARY_OPERATION {
    //     decls = get_dot_path_members(cast(*Binary_Operation) cursor_node.parent);
    //     if decls.count > 0 {
    //         send_completions_decls(request, decls);
    //         return;
    //     }
    // }

    // if cursor_block log("Block: %", cursor_block.*);

    // General
    decls = get_declarations(file, cursor_block, *cursor_location);

    send_completions_decls(request, decls);
}

handle_completitions_load :: (request: LSP_Request_Message_Completion, file: *Program_File, directive_load: *Directive_Load) {
    completions: [..]LSP_Completion_Item;
    current_file_dir := path_strip_filename(file.path);

    visit_file :: (info: *File_Visit_Info, completions: *[..]LSP_Completion_Item) {
        if !info.is_directory && !contains(info.short_name, ".jai") return;

        array_add(completions, .{
            label=info.short_name,
            kind=xx (ifx info.is_directory then LSP_Completion_Item.Kind.Folder else LSP_Completion_Item.Kind.File),
            insertText=info.short_name,
            insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
            labelDetails = .{ description=info.full_name }
        });
    }

    path_to_visit := current_file_dir;
    if contains(directive_load.file, "/") {
        path_to_visit = sprint("%/%", path_to_visit, directive_load.file);
    }

    is_dir, ok := is_directory(path_to_visit);
    if !is_dir || !ok {
        lsp_respond(request.id, null);
        return;
    }

    visit_files(path_to_visit, false, *completions, visit_file, true, true);

    lsp_respond(request.id, completions);
}

handle_completitions_import :: (request: LSP_Request_Message_Completion, directive_import: *Directive_Import) {
    completions: [..]LSP_Completion_Item;

    modules_dir := sprint("%/modules", server.args.jai_path);

    visit_modules :: (info: *File_Visit_Info, completions: *[..]LSP_Completion_Item) {
        if !info.is_directory && !contains(info.short_name, ".jai") return;

        module_name := info.short_name;
        if !info.is_directory {
            module_name = replace(info.short_name, ".jai", "");
        } else {
            if !file_exists(sprint("%/module.jai", info.full_name)) return;
        }

        array_add(completions, .{
            label=module_name,
            kind=xx LSP_Completion_Item.Kind.Module,
            insertText=info.short_name,
            insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
            labelDetails = .{ description=info.full_name }
        });
    }

    // Compiler modules
    visit_files(modules_dir, false, *completions, visit_modules, true, true);

    // Local modules
    for local_module: server.local_modules {
        local_modules_dir := sprint("%/%", server.project_root, local_module);
        visit_files(local_modules_dir, false, *completions, visit_modules, true, true);
    }

    lsp_respond(request.id, completions);
}

handle_dot_completitions :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    if !cursor_node {
        return false;
    }

    op: *Binary_Operation;
    if cursor_node.kind == .BINARY_OPERATION {
        op = cast(*Binary_Operation, cursor_node);
    } else if cursor_node.parent && cursor_node.parent.kind == .BINARY_OPERATION {
        op = cast(*Binary_Operation, cursor_node.parent);
    } else {
        return false;
    }

    if op.operation != .DOT {
        return false;
    }

    path := get_dot_path(op, null);

    type := get_path_type(path);
    if !type {
        // log_error("type is invalid! (null)");
        return false;
    }

    // log("type kind: %", type.kind);
    // log_node(type);

    return handle_completitions_for_node(request, type);
}

handle_assignment_completitions :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    op: *Binary_Operation;
    if cursor_node.kind == .BINARY_OPERATION {
        op = cast(*Binary_Operation, cursor_node);
    } else if cursor_node.parent && cursor_node.parent.kind == .BINARY_OPERATION {
        op = cast(*Binary_Operation, cursor_node.parent);
    } else {
        return false;
    }

    if op.operation != .ASSING && op.operation != .IS_EQUAL {
        return false;
    }

    // @TODO: support more types!
    if cursor_node.kind != .UNARY_OPERATION {
        return false;
    }

    left_type := get_node_type(op.left, true);
    if !left_type {
        return false;
    }

    return handle_completitions_for_node(request, left_type);
}

handle_completitions_for_node :: (request: LSP_Request_Message_Completion, node: *Node) -> bool {
    // log("type kind: %", node.kind);
    // log_node(node);

    decls: [..]*Declaration;
    defer array_free(decls);

    // This is a macro so the declaration survive until parent scope.
    add_decls_for_string_or_array :: (decls: *[..]*Declaration, type_inst_expression: *Node) #expand {
        data_decl := Declaration.{
            name = "data",
            type_inst = *(Unary_Operation.{
                operation=.POINTER,
                expression=type_inst_expression
            }),
        };

        array_add(decls, *data_decl);
        array_add(decls, *array_count_declaration);
    }

    // @TODO: handle `using` modifiers like `except`, `only` and `map`.
    // @TODO: handle #as
    // @TODO: Maybe move this to program as global?
    add_all_fields_of :: (decls: *[..]*Declaration, node: *Node) {
        block := get_block_of(node);
        if !block {
            // log_error("block is not valid!");
            return;
        }

        for member: block.members {
            if !member continue;

            if member.kind == {
                case .IDENTIFIER;
                    ident := cast(*Identifier) member;

                    decl := New(Declaration); // @MEMORY: We should free this or it is temp?
                    decl.name = ident.name;
                    decl.expression = *empty_identifier;
                    decl.location = ident.location;
                    decl.const = true;

                    array_add(decls, decl);

                case .DECLARATION;
                    array_add(decls, cast(*Declaration, member));

                case .DIRECTIVE_AS; #through;
                case .USING;
                    used_expression := get_used_expression(member);
                    if !used_expression || used_expression.kind != .DECLARATION && used_expression.kind != .IDENTIFIER {
                        continue;
                    }

                    used_type := get_node_type(used_expression);
                    if !used_type {
                        continue;
                    }

                    if used_expression.kind == .DECLARATION {
                        array_add(decls, cast(*Declaration) used_expression); // Add using expression
                    }

                    add_all_fields_of(decls, used_type); // Add all fields includes with using
            }
        }
    }

    if node.kind == {
        case .UNION; #through;
        case .ENUM; #through;
        case .STRUCT;
            add_all_fields_of(*decls, node);

        case .ARRAY_TYPE;
            array_type := cast(*Array_Type, node);
            add_decls_for_string_or_array(*decls, array_type.element_type);

        case .IDENTIFIER;
            identifier := cast(*Identifier, node);

            if identifier.name == {
                case "string";
                    add_decls_for_string_or_array(*decls, *(Identifier.{
                        name = "u8",
                    }));
            }

        case .LITERAL;
            literal := cast(*Literal, node);

            if literal.value_type == {
                case .STRING;
                    add_decls_for_string_or_array(*decls, *(Identifier.{
                        name = "u8",
                    }));

                case .ARRAY;
                    array_literal_info := literal.values.array_literal_info;
                    if array_literal_info.element_type {
                        add_decls_for_string_or_array(*decls, array_literal_info.element_type);
                    }

            }

        case .DIRECTIVE_IMPORT;
            import := cast(*Directive_Import) node;

            module_file_path := get_module_import_path(import, node.location.file);
            module_file := get_file(module_file_path);

            if !module_file {
                return false;
            }

            for get_declarations(module_file, only_loaded=true) {
                array_add(*decls, it);
            }
    }

    if decls.count == 0 {
        return false;
    }

    send_completions_decls(request, decls);

    return true;
}

send_completions_decls :: (request: LSP_Request_Message_Completion, decls: []*Declaration) {
    completions: [..]LSP_Completion_Item;
    defer array_free(completions);

    for decl: decls {
        if !decl.expression && !decl.type_inst continue;

        kind: LSP_Completion_Item.Kind;
        preview_node: *Node;
        insert_text: string;
        deprecated: bool;

        if decl.expression {
            preview_node = decl.expression;
        } else {
            preview_node = decl.type_inst;
        }

        if preview_node.kind == {
            case .PROCEDURE;
                kind = .Function;
                procedure := cast(*Procedure) preview_node;
                deprecated = procedure.deprecated_note.count > 0;
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
            deprecated=deprecated,
            insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
            labelDetails = .{ description=procedure_header_preview }
        });
    }

    lsp_respond(request.id, completions);
}