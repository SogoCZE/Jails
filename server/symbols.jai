// @TODO: We are currently do not use any caching for workspace or document (file) symbols which seems ok for now.
// But we should test it on large project to see if any caching is needed -> in theory we are only traversing AST
// And making symbols - which should be fast??? We are not resolving any identifiers (types etc).
// Potencial bottleneck can be a lot of small allocations - we can solve this with Pool allocator though.

// @TODO: We only include project files, is this ok?
// TypeScript Language Server does this (filtering node_modules etc)
// Go Server does include "compiler" packages
// We should make more reseach on this topic and ask people around what they think
// and how they use this feature...
MAX_NUMBER_OF_WORKSPACE_SYMBOLS_TO_RETURN_TO_PREVENT_VSCODE_FROM_BEING_SUPER_SLOW :: 1000;

handle_workspace_symbol :: (request: LSP_Request_Message_Workspace_Symbol) {
    push_allocator(temp);
    search_query := to_lower_copy(request.params.query);

    // @TODO: Do we want to return here if we got no search query?
    if !search_query {
        lsp_respond(request.id, null);
        return;
    }

    builder: String_Builder;
    append(*builder, "[");

    symbol_count := 0;
    for file: server.files {
        // Skip non workspace files
        if !begins_with(file.path, server.project_root) {
            continue;
        }

        if !server.user_options.use_symbols_from_local_modules {
            // Skip files from local modules (we only want workspace project files)
            for local_module_folder: server.local_modules {
                full_local_module_folder_path := tprint("%/%", server.project_root, local_module_folder);

                if begins_with(file.path, full_local_module_folder_path) {
                    continue file;
                }
            }
        }

        for serialized_symbol, symbol_name: file.serialized_workspace_symbols {
            if symbol_count == MAX_NUMBER_OF_WORKSPACE_SYMBOLS_TO_RETURN_TO_PREVENT_VSCODE_FROM_BEING_SUPER_SLOW {
                break file;
            }

            if !contains(to_lower_copy(symbol_name), search_query) {
                continue;
            }

            if symbol_count > 0 {
                append(*builder, ",");
            }

            append(*builder, serialized_symbol);
            symbol_count += 1;
        }
    }

    append(*builder, "]");
    json_serialized_symbol_list := builder_to_string(*builder);
    lsp_respond_with_already_json_serialized_result_data(request.id, json_serialized_symbol_list);
}

handle_document_symbol :: (request: LSP_Request_Message_Document_Symbol) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        log_error("File does not exists or has not been parser yet! (%)", file_path);
        lsp_respond(request.id, null);
        return;
    }

    lsp_respond(request.id, file.document_symbols);
}

cache_symbols_for_file :: (file: *Program_File) {
    push_allocator(pool_alloc(*file.analysis_pool));

    symbols: [..]LSP_Document_Symbol;
    load_symbols_from_file(file, *symbols);
    file.document_symbols = symbols;

    serialize_workspace_symbols :: (file: *Program_File, document_symbols: []LSP_Document_Symbol, name_prefix := "") {
        for document_symbol: document_symbols {
            workspace_symbol: LSP_Workspace_Symbol;
            workspace_symbol.name = join(name_prefix, document_symbol.name);
            workspace_symbol.kind = document_symbol.kind;
            workspace_symbol.location = .{path_to_lsp_path(file.path), document_symbol.range};

            serialized_symbol := json_write_string(workspace_symbol);
            table_add(*file.serialized_workspace_symbols, workspace_symbol.name, serialized_symbol);

            serialize_workspace_symbols(file, document_symbol.children, join(workspace_symbol.name, "."));
        }
    }

    serialize_workspace_symbols(file, file.document_symbols);
}

load_symbols_from_file :: (file: *Program_File, load_to: *[..]LSP_Document_Symbol) {
    for node: file.global_block.members {

        // scope directives (#scope_export, #scope_module, #scope_file)
        if node.kind == .DIRECTIVE_SCOPE {
            scope_directive := cast(*Directive_Scope) node;
            for member: scope_directive.members {
                symbol, ok := lsp_document_symbol_from_node(member, .VARIABLE);
                if !ok {
                    continue;
                }

                array_add(load_to, symbol);
            }

            continue;
        }

        symbol, ok := lsp_document_symbol_from_node(node, .VARIABLE);
        if !ok {
            continue;
        }

        array_add(load_to, symbol);
    }
}

node_kind_to_symbol_kind :: (expression: *Node, default: LSP_Symbol_Kind) -> LSP_Symbol_Kind {
    if !expression {
        return default;
    }

    if expression.kind == {
        case .STRUCT; return .STRUCT;
        case .UNION; return .STRUCT;
        case .ENUM; return .ENUM;
        case .PROCEDURE; return .FUNCTION;
        case .DIRECTIVE_IMPORT; return .MODULE;
        case .DIRECTIVE_LIBRARY; return .PACKAGE;
        case; return default;
    }
}

lsp_document_symbol_from_node :: (node: *Node, default_symbol_kind: LSP_Symbol_Kind) -> LSP_Document_Symbol, bool {
    symbol: LSP_Document_Symbol;

    children_to_symbols :: (node: *Node) -> []LSP_Document_Symbol {
        children: [..]LSP_Document_Symbol;
        if !node {
            return children;
        }

        block := get_block_of(node);
        if block {
            for member: block.members {
                child_symbol, ok := lsp_document_symbol_from_node(member, .FIELD);
                if !ok {
                    continue;
                }

                // Override for enum members
                if node.kind == .ENUM {
                    child_symbol.kind = cast(s64) LSP_Symbol_Kind.ENUM_MEMBER;
                }

                array_add(*children, child_symbol);
            }
        }

        return children;
    }

    ok := false;
    if node.kind == {
        case .DECLARATION;
            decl := cast(*Declaration) node;
            symbol.name = decl.name;
            symbol.kind = cast(s64) node_kind_to_symbol_kind(decl.expression, ifx decl.const then .CONSTANT else default_symbol_kind);

            if decl.type_inst {
                builder: String_Builder;
                ast_print(*builder, decl.type_inst);
                symbol.detail = builder_to_string(*builder);
            }

            if decl.expression && (decl.expression.kind == .PROCEDURE || decl.expression.kind == .LITERAL) {
                builder: String_Builder;
                ast_print(*builder, decl.expression);
                symbol.detail = builder_to_string(*builder);
            }

            if decl.expression && decl.expression.kind == .ENUM {
                _enum := cast(*Enum) decl.expression;
                builder: String_Builder;
                ast_print(*builder, _enum.type);
                symbol.detail = builder_to_string(*builder);
            }

            symbol.children = children_to_symbols(decl.expression);
            ok = true;

        case .IDENTIFIER;
            ident := cast(*Identifier) node;
            symbol.name = ident.name;
            symbol.kind = cast(s64) LSP_Symbol_Kind.VARIABLE;
            ok = true;

        case .DIRECTIVE_AS; #through;

        case .USING; return .{}, false;
        // case .USING;
        //     if !node.parent || node.parent.kind == .DIRECTIVE_SCOPE {
        //         return .{}, false; // @TODO: We do not support global using in symbols for now!
        //     }

        //     used_expression := get_used_expression(node);
        //     if !used_expression || used_expression.kind != .DECLARATION && used_expression.kind != .IDENTIFIER {
        //         return .{}, false;
        //     }

        //     symbol.detail = symbol.name;

        //     if used_expression.kind == .DECLARATION {
        //         used_decl := cast(*Declaration) used_expression;
        //         symbol.name = used_decl.name;
        //     }

        //     used_type := get_node_type(used_expression);
        //     if !used_type {
        //         return .{}, false;
        //     }

        //     if used_type.parent && used_type.parent != used_expression {
        //         symbol, ok = lsp_document_symbol_from_node(used_type.parent, .FIELD);
        //     } else {
        //         symbol, ok = lsp_document_symbol_from_node(used_type, .FIELD);
        //     }

        case .ENUM; #through;
        case .UNION; #through;
        case .STRUCT;
            _union := cast(*Union) node;

            if node.kind == {
                case .UNION;
                    symbol.name = "union";
                    symbol.kind = cast(s64) LSP_Symbol_Kind.STRUCT;
                case .STRUCT;
                    symbol.name = "struct";
                    symbol.kind = cast(s64) LSP_Symbol_Kind.STRUCT;
                case .ENUM;
                    symbol.name = "enum";
                    symbol.kind = cast(s64) LSP_Symbol_Kind.ENUM;
            }

            symbol.children = children_to_symbols(node);
            ok = true;
    }

    lsp_location := node_location_to_lsp_location(node.location);
    symbol.range = lsp_location.range;
    symbol.selectionRange = lsp_location.range;

    return symbol, ok;
}