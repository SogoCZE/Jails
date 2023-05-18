handle_completitions :: (request: LSP_Request_Message_Completion) {
    file_without_uri_prefix := replace(request.params.textDocument.uri, "file://", "");

    workspace := find_workspace_by_path(file_without_uri_prefix);
    if !workspace {
        log("Cant find workspace for %", file_without_uri_prefix);
        lsp_respond(request.id, null);
        return;
    }

    //refresh_program_if_needed(workspace);

    cursor_pos := request.params.position;
    cursor_block := find_block(workspace, xx (cursor_pos.line+1), xx (cursor_pos.character+1), file_without_uri_prefix);

    // TODO(BenJ) this actually finds the context "under" (past!) the cursor. We
    // specifically want the thing _before_ the cursor
    path := get_cursor_context(file_without_uri_prefix, cursor_pos);

    completions: [..]LSP_Completion_Item;
    defer array_free(completions);

    if path.count > 1 {
      // Looks like a struct or enum member. Find the decl for the penultimate
      // thing, and offer its members as suggestions.
      // So if we have [a, b, c, d], we want to inspect the members of c.
      // We might find multiple decls for c (apparently) so we just add all of
      // them TODO(BenJ) this will duplicate probably if it's even possible.
      decls := find_declarations(workspace, path[ 0 ], file_without_uri_prefix, cursor_block );
      if decls.count < 1 {
        log( "No declaration for base member %", path[ 0 ] );
      } else {
        for decl : decls {
          current_decl := decl;
          for part: array_view( path, 1, path.count-2 ) {
            member_decl : *Declaration;
            if current_decl.kind == {
              case .ENUM; #through;
              case .STRUCT; member_decl = find_struct_or_enum_member(workspace, current_decl, part);
              case .EXPRESSION;
                  type := get_type_declaration(workspace, (cast(*Expression) current_decl).type);
                  if !type break;
                  member_decl = find_struct_or_enum_member(workspace, type, part);

              case .TYPE_INSTANTIATION;
                  type := get_type_declaration(workspace, (cast(*Type_Instantiation) current_decl).type);
                  if !type break;
                  member_decl = find_struct_or_enum_member(workspace, type, part);
            }
            if !member_decl break;
            current_decl = member_decl;
          }

          // Whatever we found, resolve its type to either a struct or a union
          if current_decl.kind == {
            case .EXPRESSION;
              current_decl = get_type_declaration(workspace, (cast(*Expression) current_decl).type);
            case .TYPE_INSTANTIATION;
              current_decl = get_type_declaration(workspace, (cast(*Type_Instantiation) current_decl).type);
          }

          if !current_decl {
            break;
          }

          block: *Block;

          // now actually find the block with the struc/union decl in it
          if current_decl.kind == {
            case .ENUM; block = get_block(workspace, cast(*Enum) current_decl);
            case .STRUCT; block = get_block(workspace, cast(*Struct) current_decl);
          }

          if !block break;

          for get_block_declarations(workspace, block) {
            array_add(*completions, .{
                label=it.name,
                kind=xx LSP_Completion_Item.Kind.Field,
                insertText=it.name,
                labelDetails = .{ description=it.name }
            });
          }
        }
      }
    } else {

      for decl: workspace.program.declarations_by_name {
          if decl.kind != .PROCEDURE continue;

          if decl.flags & .SCOPE_FILE && file_without_uri_prefix != decl.location.file continue;
          if !path_in_imported_modules_or_files(workspace, decl.location.file) continue;

          if !(decl.flags & .IS_GLOBAL) {
              decl_block := find_block(workspace, decl.location.l0, decl.location.c0, decl.location.file);
              if !decl_block || !cursor_block || decl_block.serial != cursor_block.serial continue;
          }

          procedure := cast(*Procedure) decl;

          lsp_location := declaration_to_lsp_location(decl);

          // @TODO: fix this (does not currently work for not opened files)
          peeked_procedure := find_range_in_modified_file(decl.location.file, lsp_location.range);

          array_add(*completions, .{
              label=procedure.name,
              kind=xx LSP_Completion_Item.Kind.Function,
              insertText=decl.name,
              labelDetails = .{ description=peeked_procedure }
          });
      }
    }

    lsp_respond(request.id, completions);
}
