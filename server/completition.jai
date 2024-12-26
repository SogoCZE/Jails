

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

    add_enum_member_dot := true;

    // Unary OP
    if cursor_node && cursor_node.kind == .UNARY_OPERATION {
        uop := cast(*Unary_Operation)cursor_node;

        if uop.operation == .DOT && uop.parent && uop.parent.kind == .BINARY_OPERATION {
            bop := cast(*Binary_Operation)uop.parent;

            if bop.operation == .ASSING || bop.operation == .IS_EQUAL || bop.operation == .IS_NOT_EQUAL {
                cursor_node = bop;
                add_enum_member_dot = false;
            }
        }
    }

    // Binary OP
    if cursor_node && cursor_node.kind == .BINARY_OPERATION {
        binary_op := cast(*Binary_Operation)cursor_node;

        if binary_op.operation == {
            case .DOT;
                decls = complete_dot(file, cursor_node);

                if decls.count > 0 {
                    send_completions_decls(request, decls);
                } else {
                    log("Could not complete '.'\n");

                    //log("Here's the cursor block:\n");
                    //log_node(cursor_block);

                    log("And here's the cursor node\n");
                    log_node(cursor_node);
                }

                // If we fail to complete a . we return nothing
                send_completions_decls(request, decls);
                return;
            case .IS_EQUAL; #through;
            case .ASSING;
                decls = complete_assign_equal(binary_op);

                if decls.count > 0 {
                    send_completions_decls(request, decls, add_enum_member_dot);
                } else {
                    log("Could not complete '='\n");

                    //log("Here's the cursor block:\n");
                    //log_node(cursor_block);

                    log("And here's the cursor node\n");
                    log_node(cursor_node);
                }

                // If we fail to complete a . we return nothing
                send_completions_decls(request, decls);
                return;
            case;
                log("Don't know what to do with Binary_Operation %\n", binary_op.operation);
                return;
        }
    }

    // General
    log("General non dot cursor node\n");
    log_node(cursor_node);

    decls = get_global_declarations(file, cursor_node);

    log("Filtering % decls\n", decls.count);

    if decls.count < 10 {
        for d: decls {
            log("%: %\n", it_index, d.name);
        }

    }

    // Filter declarations
    if cursor_node && cursor_node.kind == .IDENTIFIER {
        ident := cast(*Identifier) cursor_node;
        count:=0;

        for d: decls {
            if begins_with(d.name, ident.name) {
                decls[count]=d;
                count+=1;
            }
        }

        decls.count=count;
    }

    log("Sending % declarations to complete non dot\n", decls.count);

    if decls.count < 20 {
        for d: decls {
            log("%: %\n", it_index, d.name);
        }
    }

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

// @TODO: maybe move this to program?
// get_dot_path_members :: (file: *Program_File, binary_op: *Binary_Operation) -> []*Declaration {
//     members: [..]*Declaration;

//     if binary_op.operation != .DOT return members;

//     if !binary_op.left return members;

//     decl := goto_dot_path_member(file, binary_op, xx binary_op.left);
//     if !decl return members;

//     decl_type := get_node_type(file, decl);
//     if !decl_type return members;

//     block := get_block_of(decl_type);
//     if !block return members;

//     for member: block.members {
//         if member.kind != .DECLARATION continue;
//         array_add(*members, xx member);
//     }

//     return members;
// }

send_completions_decls :: (request: LSP_Request_Message_Completion, decls: []*Declaration, add_enum_member_dot: bool = false) {
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
                insert_text = tprint("%($0)", decl.name);

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

        if decls.count == 1 && preview_node.kind == .ENUM {
            _enum := cast(*Enum)preview_node;

            if _enum.block {
                for m: _enum.block.members {
                    if m.kind ==  {
                        case .IDENTIFIER;
                            ident := cast(*Identifier)m;

                            array_add(*completions, .{
                                label=ident.name,
                                kind=xx kind,
                                insertText= ifx add_enum_member_dot then tprint(".%", ident.name) else ident.name,
                                insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
                                labelDetails = .{ description=procedure_header_preview }
                            });
                        case .DECLARATION;
                            dd := cast(*Declaration)m;

                            array_add(*completions, .{
                                label=dd.name,
                                kind=xx kind,
                                insertText= ifx add_enum_member_dot then tprint(".%", dd.name) else dd.name,
                                insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
                                labelDetails = .{ description=procedure_header_preview }
                            });
                    }
                }
            }
        } else {
            array_add(*completions, .{
                label=decl.name,
                kind=xx kind,
                insertText=insert_text,
                insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
                labelDetails = .{ description=procedure_header_preview }
            });
        }

    }

    lsp_respond(request.id, completions);
}

