handle_goto_enum_literal :: (request: LSP_Request_Message_Definition, file: *Program_File, ident: *Identifier) -> bool {
    // Check if this identifier is part of an enum literal (parent is UNARY_OPERATION with DOT)
    if !ident.parent || ident.parent.kind != .UNARY_OPERATION {
        return false;
    }

    unary_op := cast(*Unary_Operation) ident.parent;
    if unary_op.operation != .DOT {
        return false;
    }

    if !unary_op.parent {
        return false;
    }

    // Check what context the enum literal is in
    parent_node := unary_op.parent;
    original_parent_node := parent_node;
    enum_type: *Node;

    // For enum_flags with OR/AND operations in .PROCEDURE_CALL arguments, traverse up to find the actual context
    while parent_node && parent_node.kind == .BINARY_OPERATION {
        binary_op := cast(*Binary_Operation) parent_node;
        if binary_op.operation == .PIPE || binary_op.operation == .BITWISE_AND {
            parent_node = binary_op.parent;
        } else {
            break;
        }
    }

    if parent_node && parent_node.kind != .PROCEDURE_CALL {
        parent_node = original_parent_node;
    }

    if !parent_node {
        return false;
    }

    if parent_node.kind == .PROCEDURE_CALL {
        // For procedure arguments:
        // - SDL_CreateGPUDevice(.SPIRV | .MSL | .DXIL, ...)
        proc_call := cast(*Procedure_Call) parent_node;

        if proc_call.procedure && proc_call.procedure.kind == .IDENTIFIER {
            proc_ident := cast(*Identifier) proc_call.procedure;

            // Find which argument contains our enum literal (might be nested in OR or AND operations if it's an enum_flag)
            arg_index := -1;
            for arg, index: proc_call.arguments {
                // Check if our unary_op is somewhere within this argument
                if is_parent_of(arg, unary_op) {
                    arg_index = index;
                    break;
                }
            }

            if arg_index >= 0 {
                // Get the procedure declaration
                proc_decls := get_identifier_decl(proc_ident);

                if proc_decls.count > 0 {
                    proc_decl := proc_decls[0];

                    if proc_decl.expression && proc_decl.expression.kind == .PROCEDURE {
                        procedure := cast(*Procedure) proc_decl.expression;

                        // Get the type of the corresponding parameter
                        if arg_index < procedure.arguments.count {
                            param := procedure.arguments[arg_index];
                            unwrapped := unwrap_polymorphic_constant(param);

                            if unwrapped && unwrapped.kind == .DECLARATION {
                                param_decl := cast(*Declaration) unwrapped;
                                if param_decl.type_inst {
                                    enum_type = get_node_type(param_decl.type_inst);
                                }
                            }
                        }
                    }
                }
            }
        }

    } else if parent_node.kind == .DECLARATION {
        // For struct field defaults: se: Some_Enum = .A
        decl := cast(*Declaration) parent_node;

        if decl.type_inst {
            enum_type = get_node_type(decl.type_inst);
        }

    } else if parent_node.kind == .BINARY_OPERATION {
        binary_op := cast(*Binary_Operation) parent_node;

        // Special case: Check if this comparison is part of a member access chain
        if binary_op.parent && binary_op.parent.kind == .BINARY_OPERATION {
            parent_op := cast(*Binary_Operation) binary_op.parent;

            if parent_op.operation == .DOT {
                comparison_left := binary_op.left;
                if comparison_left && comparison_left.kind == .IDENTIFIER {
                    operation_ident := cast(*Identifier) comparison_left;
                    left_type := get_node_type(parent_op.left);

                    if left_type {
                        decl := get_member_in(left_type, operation_ident);
                        if decl {
                            enum_type = get_node_type(decl);
                        }
                    }
                }
            }
        }

        // If not found yet, handle normal cases
        if !enum_type {
            if binary_op.operation == .ASSIGN {
                // For: se = .B or flags = .SPIRV | .MSL
                // Also handles: ident.parent.kind = .UNARY_OPERATION

                if binary_op.left && binary_op.left.kind == .BINARY_OPERATION {
                    // Left side is a member access chain
                    member_access := cast(*Binary_Operation) binary_op.left;
                    if member_access.operation == .DOT {
                        // Get the type of the entire member access chain
                        enum_type = get_node_type(member_access);
                    }
                } else if binary_op.left && binary_op.left.kind == .IDENTIFIER {
                    // Left side is a simple identifier
                    left_ident := cast(*Identifier) binary_op.left;
                    decls := get_identifier_decl(left_ident);

                    if decls.count > 0 {
                        decl := decls[0];
                        if decl.expression && decl.expression.kind == .BINARY_OPERATION {
                            member_access := cast(*Binary_Operation) decl.expression;
                            if member_access.operation == .DOT && member_access.left {
                                enum_type = get_node_type(member_access.left);
                            }
                        }
                        if !enum_type && decl.type_inst {
                            enum_type = get_node_type(decl.type_inst);
                        }
                    }
                }
            } else if binary_op.operation == .IS_EQUAL    || binary_op.operation == .IS_NOT_EQUAL ||
                      binary_op.operation == .LOGICAL_AND || binary_op.operation == .LOGICAL_OR   ||
                      binary_op.operation == .PIPE        || binary_op.operation == .BITWISE_AND {
                other_side: *Node;
                if binary_op.left == unary_op {
                    other_side = binary_op.right;
                } else {
                    other_side = binary_op.left;
                }

                // Handle member access chains
                if other_side && other_side.kind == .BINARY_OPERATION {
                    member_chain := cast(*Binary_Operation) other_side;
                    if member_chain.operation == .DOT {
                        enum_type = get_node_type(other_side);
                    }
                } else if other_side && other_side.kind == .IDENTIFIER {
                    other_ident := cast(*Identifier) other_side;
                    decls := get_identifier_decl(other_ident);

                    if decls.count > 0 {
                        decl := decls[0];
                        if decl.expression && decl.expression.kind == .BINARY_OPERATION {
                            member_access := cast(*Binary_Operation) decl.expression;
                            if member_access.operation == .DOT && member_access.left {
                                enum_type = get_node_type(member_access.left);
                            }
                        }
                        if !enum_type && decl.type_inst {
                            enum_type = get_node_type(decl.type_inst);
                        }
                    }
                }

                if !enum_type {
                    enum_type = get_node_type(other_side);
                }
            }
        }
    }

    if !enum_type {
        log("Couldn't determine enum literal type");
        return false;
    }

    if enum_type.kind != .ENUM {
        return false;
    }

    _enum := cast(*Enum) enum_type;
    if !_enum.block {
        return false;
    }

    for member: _enum.block.members {
        if member.kind == .IDENTIFIER {
            member_ident := cast(*Identifier) member;
            if member_ident.name == ident.name {
                lsp_respond(request.id, node_location_to_lsp_location(member_ident.location));
                return true;
            }
        } else if member.kind == .DECLARATION {
            member_decl := cast(*Declaration) member;
            if member_decl.name == ident.name {
                lsp_respond(request.id, node_location_to_lsp_location(member_decl.location));
                return true;
            }
        }
    }

    return false;
}

handle_goto_load :: (request: LSP_Request_Message_Definition, file: *Program_File, _load: *Directive_Load) {
    file_path_without_filename := trim_right(path_strip_filename(file.path), "/");
    load_absolute_path := join(file_path_without_filename, _load.file, separator="/");

    lsp_location: LSP_Location_Link;
    lsp_location.originSelectionRange = .{
        start=.{line=xx _load.location.l0, character=xx(_load.location.c1 - _load.file.count-1)},
        end=.{line=xx _load.location.l0, character=xx(_load.location.c1-1)}
    };
    lsp_location.targetUri = path_to_lsp_path(load_absolute_path);

    lsp_respond(request.id, lsp_location);
}

handle_goto_import :: (request: LSP_Request_Message_Definition, file: *Program_File, _import: *Directive_Import) {
    push_allocator(temp);

    file_path_without_filename := trim_right(path_strip_filename(file.path), "/");
    module_absolute_path := get_module_import_path(_import, file_path_without_filename);

    lsp_location: LSP_Location_Link;
    lsp_location.originSelectionRange = .{
        start=.{line=xx _import.location.l0, character=xx(_import.location.c1 - _import.module.count-1)},
        end=.{line=xx _import.location.l0, character=xx(_import.location.c1-1)}
    };
    lsp_location.targetUri = path_to_lsp_path(module_absolute_path);

    lsp_respond(request.id, lsp_location);
}

handle_goto_dot :: (request: LSP_Request_Message_Definition, ident: *Identifier) -> bool {
    if !ident || !ident.parent return false;

    leaf_node: *Node;
    op: *Binary_Operation;

    if ident.parent.kind == {
        case .BINARY_OPERATION;
            op = cast(*Binary_Operation) ident.parent;
            leaf_node = ident;

        case .ARRAY_SUBSCRIPT;
            array_subscript := cast(*Array_Subscript) ident.parent;
            if array_subscript.parent && array_subscript.parent.kind == .BINARY_OPERATION {
                op = cast(*Binary_Operation) array_subscript.parent;
                leaf_node = array_subscript;
            }

        case .PROCEDURE_CALL;
            proc_call := cast(*Procedure_Call) ident.parent;
            if proc_call.parent && proc_call.parent.kind == .BINARY_OPERATION {
                op = cast(*Binary_Operation) proc_call.parent;
                leaf_node = proc_call;
            }

        // @TODO: anything else?
    }

    if !op return false;

    path := get_dot_path(op, leaf_node);
    if path.count < 2 {
        return false;
    }

    path = array_view(path, 0, path.count-1);

    type := get_path_type(path);
    if !type {
        return false;
    }

    decl := get_member_in(type, ident);
    if !decl {
        return false;
    }

    lsp_respond(request.id, node_location_to_lsp_location(decl.location));

    return true;
}

handle_goto_procedure_named_argument :: (request: LSP_Request_Message_Definition, file: *Program_File, ident: *Identifier) -> bool {
    if !ident.parent || ident.parent.kind != .BINARY_OPERATION {
        return false;
    }

    binary_op := cast(*Binary_Operation) ident.parent;

    // We only want to resolve this if its the left side.
    if binary_op.right == ident {
        return false;
    }

    if !binary_op.parent || binary_op.parent.kind != .PROCEDURE_CALL {
        return false;
    }

    procedure_call := cast(*Procedure_Call) binary_op.parent;

    if !procedure_call.procedure {
        return false;
    }

    // We need to resolve the calle procedure.
    decls := get_identifier_decl(cast(*Identifier) procedure_call.procedure);
    if decls.count == 0 {
        return false;
    }


    procedure_decl := decls[0]; // TODO: here we need to resolve procedure overloading in the future.
    if !procedure_decl.expression {
        return false;
    }

    procedure := cast(*Procedure) procedure_decl.expression;

    for arg: procedure.arguments {
        unwrapped_arg := unwrap_polymorphic_constant(arg);

        // It should always be decl??
        if unwrapped_arg.kind != .DECLARATION {
            log("arg.kind: %", arg.kind);
            continue;
        }

        arg_decl := cast(*Declaration) unwrapped_arg;

        if arg_decl.name == ident.name {
            lsp_respond(request.id, node_location_to_lsp_location(arg_decl.location));
            return true;
        }
    }

    return false;
}

handle_goto_struct_literal :: (request: LSP_Request_Message_Definition, file: *Program_File, ident: *Identifier) -> bool {
    if !ident.parent || ident.parent.kind != .BINARY_OPERATION {
        return false;
    }

    binary_op := cast(*Binary_Operation) ident.parent;

    // We only want to resolve this if its the left side.
    if binary_op.right == ident {
        return false;
    }

    if !binary_op.parent || binary_op.parent.kind != .LITERAL {
        return false;
    }

    literal := cast(*Literal) binary_op.parent;

    // TODO: Infer the type for .{} structs literals...
    if literal.value_type != .STRUCT || !literal.struct_literal_info.type || literal.struct_literal_info.type.kind != .IDENTIFIER {
        return false;
    }

    // We need to resolve struct literal type.
    decls := get_identifier_decl(cast(*Identifier) literal.struct_literal_info.type);
    if decls.count == 0 {
        return false;
    }

    struct_decl := decls[0];
    if !struct_decl.expression {
        return false;
    }


    _struct := cast(*Struct) struct_decl.expression;

    decl := get_member_in(_struct, ident);
    if !decl {
        return false;
    }

    lsp_respond(request.id, node_location_to_lsp_location(decl.location));
    return true;
}

handle_goto_assignment :: (request: LSP_Request_Message_Definition, ident: *Identifier) -> bool {
    if !ident.parent || ident.parent.kind != .UNARY_OPERATION {
        return false;
    }

    unary_op := cast(*Unary_Operation, ident.parent);
    if unary_op.operation != .DOT {
        return false;
    }

    if !unary_op.parent || unary_op.parent.kind != .BINARY_OPERATION  {
        return false;
    }

    binary_op_type := get_node_type(unary_op.parent, true);
    if !binary_op_type {
        return false;
    }

    decl := get_member_in(binary_op_type, ident);
    if !decl {
        return false;
    }

    lsp_respond(request.id, node_location_to_lsp_location(decl.location));

    return true;
}

handle_goto :: (request: LSP_Request_Message_Definition) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        log_error("File does not exists or has not been parser yet! (%)", file_path);
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);

    node := get_node_by_location(file, cursor_location);
    if !node {
        lsp_respond(request.id, null);
        return;
    }

    log("Clicked node: %", node.kind);

    if node.kind == .DIRECTIVE_LOAD {
        handle_goto_load(request, file, xx node);
        return;
    }

    if node.kind == .DIRECTIVE_IMPORT {
        handle_goto_import(request, file, xx node);
        return;
    }

    if node.kind != .IDENTIFIER {
        lsp_respond(request.id, null);
        return;
    }

    ident := cast(*Identifier) node;

    if handle_goto_procedure_named_argument(request, file, ident) {
        return;
    }

    if handle_goto_struct_literal(request, file, ident) {
        return;
    }

    if handle_goto_assignment(request, ident) {
        return;
    }

    if handle_goto_dot(request, ident) {
        return;
    }

    if handle_goto_enum_literal(request, file, ident) {
        return;
    }

    decls := get_identifier_decl(ident);
    if decls.count == 0 {
        lsp_respond(request.id, null);
        return;
    }

    locations := NewArray(decls.count, LSP_Location);
    defer array_free(locations);

    for decls locations[it_index] = node_location_to_lsp_location(it.location);

    lsp_respond(request.id, locations);
}
