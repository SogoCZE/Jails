

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