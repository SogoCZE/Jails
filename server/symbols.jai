expression_to_symbol_kind :: (expression: *Node) -> LSP_Symbol_Kind{
    if expression{
        if expression.kind == {
            case .STRUCT; return .STRUCT;
            case .ENUM; return .ENUM;
            case .PROCEDURE; return .FUNCTION;
            case .OPERATOR_OVERLOAD; return .OPERATOR;
            case .QUICK_LAMBDA; return .FUNCTION;
            case .POLYMORPHIC_CONSTANT; return .TYPEPARAMETER;
            case .DIRECTIVE_IMPORT; return .MODULE;
            case .DIRECTIVE_BAKE_ARGUMENTS; return .FUNCTION;
            case .DIRECTIVE_LIBRARY; return .PACKAGE;
            case .UNION; return .STRUCT;

            // with all of the following, I don't really know how to get enough information about them to confidently determine what they are. A type directive could declare a function type, or a struct type for example. A cast could literally yield anything. I'm sure you could look at the AST here in more detail, but I don't know my way well enough around this codebase to do that. So, as a kind-of-hacky-thing, I just return VARIABLE for all of them. The most important thing is that they show imo, not that the kind matches exactly (I think the kind is mostly for display anyway, not really that functional.)

            case .DIRECTIVE_TYPE; #through;
            case .CAST; #through;
            case .PROCEDURE_CALL; #through;
            case .IDENTIFIER; #through;
            case .BINARY_OPERATION; #through;
            case .LITERAL;
                return .VARIABLE;
            case;
                //log("Unhandled expression kind % at %:%:%.", expression.kind, expression.location.file, expression.location.l0 + 1, expression.location.c0 + 1);
                return 0;

            //There are other shortcomings here: I would like to return things like FIELD for struct-members, CONSTANT for constants, also use FILE vs just MODULE or PACKAGE, but for all of these I am not confident what the AST would look like. So I opted to not pretend I can return the maximum detail here and kept it simple instead.
        }
    }
    else{
        return .VARIABLE;
    }
}

handle_document_symbol :: (request: LSP_Request_Message_Document_Symbol) {
    //ZoneScoped();
    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        log_error("File does not exists or has not been parser yet! (%)", file_path);
        lsp_respond(request.id, null);
        return;
    }

    create_lsp_document_from_declaration :: (file: *Program_File, using declaration: *Declaration) -> LSP_Document_Symbol{
        //ZoneScoped();
        child_declarations, has_children := table_find(*file.declaration_hierarchy, declaration);
        child_lsp_document_symbols: [..]LSP_Document_Symbol;

        if has_children{
            for child_declarations{
                symbol := create_lsp_document_from_declaration(file, it);
                array_add(*child_lsp_document_symbols, symbol);
            }
        }

        result: LSP_Document_Symbol;

        result.name = name;
        result.kind = xx expression_to_symbol_kind(expression);
        result.range = .{.{xx location.l0, xx location.c0}, .{xx location.l1, xx location.c1}};
        result.selectionRange = result.range;
        result.children = child_lsp_document_symbols;

        return result;
    }

    if file.declaration_hierarchy.count > 0{
        lsp_symbols: [..]LSP_Document_Symbol;

        for table_find_pointer(*file.declaration_hierarchy, null).*{
            symbol := create_lsp_document_from_declaration(file, it);
            array_add(*lsp_symbols, symbol);
        }

        lsp_respond(request.id, lsp_symbols);
    }
}

generate_and_serialize_workspace_symbols_for_file :: (file: *Program_File){
    for file.serialized_workspace_symbols
        free(it);

    table_reset(*file.serialized_workspace_symbols);

    for declaration: file.declarations{
        symbol: LSP_Workspace_Symbol;
        symbol.name = declaration.name;
        symbol.location = node_location_to_lsp_location(declaration.location);
        symbol.kind = expression_to_symbol_kind(declaration.expression);

        //turns out, if we include all variable declarations (including all parameters and local variables of all functions), then I get like 80,000 symbols in the workspace of my game, and then vscode takes half a second just to process the result. We send it very quickly, because we cache the serialized json, but vscode can't keep up. So I skip it here.

        if symbol.kind == .VARIABLE
            continue;

        serialized_symbol := json_write_string(symbol);

        table_add(*file.serialized_workspace_symbols, declaration.name, serialized_symbol);
    }
}

MAX_NUMBER_OF_WORKSPACE_SYMBOLS_TO_RETURN_TO_PREVENT_VSCODE_FROM_BEING_SUPER_SLOW :: 1000;

handle_workspace_symbol :: (request: LSP_Request_Message_Workspace_Symbol) {
    //ZoneScoped();
    query_parts := split(request.params.query, cast(u8) #char " ");

    for query_parts
        if it.count == 0
            remove it;

    builder: String_Builder;
    append(*builder, "[");

    symbol_count := 0;

    for file: server.files{
        for serialized_symbol, symbol_name: file.serialized_workspace_symbols{
            if symbol_count == MAX_NUMBER_OF_WORKSPACE_SYMBOLS_TO_RETURN_TO_PREVENT_VSCODE_FROM_BEING_SUPER_SLOW
                break file;

            //the recommendation from visual studio code is that when searching for tokens, the LSP should be very lenient as to what it filters, so that vscode can then be flexible about ordering and interpreting your search terms. They explicitely say you shouldn't check if the query is a substring, because then you can't have stuff like having the query "abc" match "arrayBoundsCheck", which is apparently something that people want to do. I personally hate that for the query "read vessel", vscode doesn't treat "read" and "vessel" as two different search terms, and so won't show you "readVessel", and also that for "readvessel", "readVessel" would match, but not "vesselRead". Basically, I ideally want to type multiple search terms, and if they are in the name, I want that to match (like in sublime text). Vscode doesn't do that. Whatever.
            // What I decided to do here is the following: I'm interpreting each space-separated element of the query as its own search term. (vscode doesn't even seem to transmit stuff after the space to the LSP, so if that is a rule and not a bug (which I couldn't find out) this part isn't even relevant). For each search term, we follow the recommandation and consider it matched, if the characters of the search term appear in the symbol name in order, case insensitive.

            remaining_name_to_search := symbol_name;

            for part: query_parts {
                for 0..request.params.query.count - 1 {
                    search_character_as_string := slice(request.params.query, it, 1);
                    index := index_of_string_nocase(remaining_name_to_search, search_character_as_string);

                    if index == -1
                        continue serialized_symbol;
                    else
                        remaining_name_to_search = slice(remaining_name_to_search, index + 1, remaining_name_to_search.count - index - 1);
                }
            }

            if symbol_count > 0
                append(*builder, ",");

            append(*builder, serialized_symbol);
            symbol_count += 1;
        }
    }

    append(*builder, "]");
    json_serialized_symbol_list := builder_to_string(*builder);
    lsp_respond_with_already_json_serialized_result_data(request.id, json_serialized_symbol_list);
    free(json_serialized_symbol_list);
}
