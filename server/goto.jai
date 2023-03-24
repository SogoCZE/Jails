
// This handles clicking on import or load.
handle_import_or_load :: (request: LSP_Request_Message_Definition, line: string, module: bool, pos: LSP_Position) {
    start_of_path := find_index_from_left(line, "\"");
    end_of_path := find_index_from_right(line, "\"");

    path := slice(line, start_of_path+1, end_of_path-start_of_path-1);

    uri: string;
    if module {
        modules_path := program_cache.import_path[1]; 
        uri = tprint("%/%/module.jai", modules_path, path);
        if !file_exists(uri) {
           uri = tprint("%/%.jai", modules_path, path);
        }
    } else {
        current_file := path_strip_filename(request.params.textDocument.uri);
        uri = tprint("%/%", current_file, path); 
    }

    #if OS == .WINDOWS {
        if module {
            // strip: C:/ 
            uri = slice(uri, 3, uri.count-1);
        }
    }

    if !module {
         uri = slice(uri, 7, uri.count-1);
    }

    range: LSP_Range;
    range.start.line = pos.line;
    range.start.character = xx (start_of_path+1);
    range.end.line = pos.line;
    range.end.character = xx end_of_path;

    lsp_respond(request.id, LSP_Location_Link.{
        targetUri=uri,
        originSelectionRange=range,
    });
}

// @todo: Consider using a compiler for goto resolution based on a clicked symbol (index all symbols - procedure calls, expressions, type instantiation...)
handle_goto :: (request: LSP_Request_Message_Definition) {
    file := request.params.textDocument.uri;
    file_without_uri_prefix := replace(file, "file://", "");

    line := find_line_in_file(file, request.params.position);

    if contains(line, "#import") {
        handle_import_or_load(request, line, true, request.params.position);
        return;
    }
    
    if contains(line, "#load") {
        handle_import_or_load(request, line, false, request.params.position);
        return;
    }

    word := find_word_in_file(file, request.params.position);
    word_block := find_block(xx (request.params.position.line+1), xx (request.params.position.character+1), file_without_uri_prefix);

    decls := table_find_multiple(*program_cache.declarations_by_name, word);
    if decls.count == 0 {
        log("Not found! (%) - Current cached nodes %.", word, program_cache.declarations_by_name.count);
        lsp_respond(request.id, null);
        return;
    }

    locations: [..]LSP_Location;

    // Scope related
    if word_block {
        for decl: decls {
            if decl.flags & .IS_GLOBAL continue;
            
            decl_block := find_block(decl.location.l0, decl.location.c0, decl.location.file);

            if !decl_block || decl_block.serial != word_block.serial continue;

            lsp_respond(request.id, declaration_to_lsp_location(decl));
            return;
        }

        // Look into arguments of procedure or struct
        word_block_parent, ok := table_find(*program_cache.declarations_by_serial, word_block.parent);
        if ok && word_block_parent.kind == .PROCEDURE {
            procedure := cast(*Procedure) word_block_parent;

            for argument_id: procedure.arguments {
                argument, ok := table_find(*program_cache.declarations_by_serial, argument_id);

                if argument.name == word {
                    lsp_respond(request.id, declaration_to_lsp_location(argument));
                    return;
                }
            }
        }
    }

    // Globals
    for decl: decls {
        if !(decl.flags & .IS_GLOBAL) continue;
        if decl.flags & .SCOPE_FILE && file_without_uri_prefix != decl.location.file continue;
        array_add(*locations, declaration_to_lsp_location(decl));
    }

    lsp_respond(request.id, locations);
    array_free(locations);
}
