

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

    if !cursor_node {
        return;
    }

    // We don't wanna to give completions inside strings and comments...
    if cursor_node.kind == Node.Kind.LITERAL || cursor_node.kind == Node.Kind.COMMENT _exit();

    if cursor_node.kind == .DIRECTIVE_IMPORT {
        handle_completitions_import(request, xx cursor_node);
        return;
    }

    if cursor_node.kind == .DIRECTIVE_LOAD {
        handle_completitions_load(request, file, xx cursor_node);
        return;
    }

    // if handle_completitions_procedure_call(request, file, cursor_node, *cursor_location) {
    //     return;
    // }

    decls: []*Declaration;
    defer array_free(decls);

    if handle_dot_completitions(request, cursor_node, cursor_location) {
        return;
    }

    if handle_assignment_completitions(request, cursor_node) {
        return;
    }

    // General
    decls = get_declarations(file, cursor_node, *cursor_location);

    send_completions_decls(request, decls, should_add_basic_keywords=true);
}

// handle_completitions_procedure_call :: (request: LSP_Request_Message_Completion, file: *Program_File, cursor_node: *Node, cursor_location: *Node.Location) -> bool {
//     proc_call := cast(*Procedure_Call) get_node_nearest_parent(cursor_node, kind => kind == .PROCEDURE_CALL);
//     if !proc_call {
//         return false;
//     }

//     if !proc_call.procedure || proc_call.procedure.kind != .IDENTIFIER {
//         return false;
//     }
//     procedure_ident := cast(*Identifier) proc_call.procedure;

//     decls := get_declarations(file, procedure_ident, cursor_location, procedure_ident.name);
//     if decls.count == 0 {
//         return false;
//     }

//     procedure_decl := decls[0];
//     if !procedure_decl.expression || procedure_decl.expression.kind != .PROCEDURE {
//         return false;
//     }

//     procedure := cast(*Procedure) procedure_decl.expression;

//     completions: [..]LSP_Completion_Item;

//     for arg: procedure.arguments {
//         if arg.kind != .DECLARATION && arg.kind != .POLYMORPHIC_CONSTANT {
//             continue;
//         }

//         unwrapped := unwrap_polymorphic_constant(arg);
//         if !unwrapped {
//             continue;
//         }

//         assert(unwrapped.kind == .DECLARATION);

//         decl := cast(*Declaration) unwrapped;

//         array_add(*completions, LSP_Completion_Item.{
//             label=decl.name,
//             insertText=tprint("%=$0", decl.name),
//             kind=xx LSP_Completion_Item.Kind.Property,
//             insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
//         });
//     }

//     lsp_respond(request.id, completions);
//     return true;
// }

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

    modules_dir := sprint("%/modules", server.jai_path);

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
            insertText=module_name,
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

handle_dot_completitions :: (request: LSP_Request_Message_Completion, cursor_node: *Node, cursor_location: Node.Location) -> bool {
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

    // @TODO: we need to check this!
    if op.operation != .DOT {
        if op.left && op.left.kind == .BINARY_OPERATION {
            op = cast(*Binary_Operation) op.left;
        }
    }

    path := get_dot_path(op, null);
    for path {
        if !it {
            remove it;
            continue;
        }

        // We dont want anything that is after the cursor.
        if it.location.l0 > cursor_location.l0 || it.location.l0 == cursor_location.l0 && it.location.c1 > cursor_location.c0 {
            remove it;
            continue;
        }
    }

    type := get_path_type(path);
    if !type {
        // log_error("type is invalid! (null)");
        return false;
    }

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

    if op.operation != .ASSIGN && op.operation != .IS_EQUAL && op.operation != .IS_NOT_EQUAL {
        return false;
    }

    // @TODO: support more types!
    if cursor_node.kind != .UNARY_OPERATION {
        return false;
    }

    left_type := get_node_type(op, true);
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

add_basic_keywords :: (completions: *[..]LSP_Completion_Item) {
    array_add(completions, .{label="string", insertText="string", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="bool", insertText="bool", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="int", insertText="int", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="s64", insertText="s64", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="s32", insertText="s32", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="s16", insertText="s16", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="s8", insertText="s8", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="u8", insertText="u8", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="u16", insertText="u16", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="u32", insertText="u32", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="u64", insertText="u64", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="float", insertText="float", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="float32", insertText="float32", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="float64", insertText="float64", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="Any", insertText="Any", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});

    array_add(completions, .{label="struct", insertText="struct", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="enum", insertText="enum", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="enum_flags", insertText="enum_flags", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});

    array_add(completions, .{label="return", insertText="return", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="break", insertText="break", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="case", insertText="case", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="remove", insertText="remove", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="continue", insertText="continue", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="if", insertText="if", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="else", insertText="else", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="for", insertText="for", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="then", insertText="then", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="using", insertText="using", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
}

send_completions_decls :: (request: LSP_Request_Message_Completion, decls: []*Declaration, should_add_basic_keywords := false) {
    completions: [..]LSP_Completion_Item;
    defer array_free(completions);

    if should_add_basic_keywords {
        add_basic_keywords(*completions);
    }

    ast_print_to_string :: (node: *Node) -> string {
        builder: String_Builder;
        ast_print(*builder, node); // @Memory @TODO: we need to free this afterwards!!
        return builder_to_string(*builder);
    }

    for decl: decls {
        if !decl.expression && !decl.type_inst continue;

        preview_node: *Node;
        if decl.expression {
            preview_node = decl.expression;
        } else {
            preview_node = decl.type_inst;
        }

        item: LSP_Completion_Item;
        item.label = decl.name;
        item.insertText = decl.name;
        item.insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET;
        item.labelDetails.description = "---";

        if preview_node.kind == {
            case .PROCEDURE;
                item.kind = xx LSP_Completion_Item.Kind.Function;
                procedure := cast(*Procedure) preview_node;
                item.deprecated = procedure.deprecated_note.count > 0;

                if server.user_options.auto_insert_parentheses {
                    item.insertText = sprint("%($0)", decl.name);
                } else {
                    item.insertText = decl.name;
                }

                item.labelDetails.description = ast_print_to_string(preview_node);

            case .STRUCT;
                item.kind = xx LSP_Completion_Item.Kind.Struct;
                item.labelDetails.description = "struct";

            case .ENUM;
                item.kind = xx LSP_Completion_Item.Kind.Enum;
                item.labelDetails.description = "enum";

            case;
                item.kind = xx LSP_Completion_Item.Kind.Variable;
                item.labelDetails.description = ast_print_to_string(preview_node);
        }

        array_add(*completions, item);
    }

    lsp_respond(request.id, completions);
}
