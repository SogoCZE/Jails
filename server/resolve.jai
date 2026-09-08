resolve_procedure_named_argument :: (ident: *Identifier) -> []*Declaration, bool {
    decls: [..]*Declaration;

    if !ident.parent || ident.parent.kind != .BINARY_OPERATION return decls, false;

    binary_op := cast(*Binary_Operation) ident.parent;
    if binary_op.right == ident return decls, false;

    if !binary_op.parent || binary_op.parent.kind != .PROCEDURE_CALL return decls, false;

    procedure_call := cast(*Procedure_Call) binary_op.parent;
    if !procedure_call.procedure || procedure_call.procedure.kind != .IDENTIFIER return decls, true;

    proc_decls := get_identifier_decls(cast(*Identifier) procedure_call.procedure);

    for proc_decl: proc_decls {
        if !proc_decl.expression || proc_decl.expression.kind != .PROCEDURE continue;

        procedure := cast(*Procedure) proc_decl.expression;

        for arg: procedure.arguments {
            unwrapped_arg := unwrap_polymorphic_constant(arg);
            if unwrapped_arg.kind != .DECLARATION continue;

            arg_decl := cast(*Declaration) unwrapped_arg;
            if arg_decl.name == ident.name array_add(*decls, arg_decl);
        }
    }

    return decls, true;
}

resolve_struct_literal_field :: (ident: *Identifier) -> []*Declaration, bool {
    decls: [..]*Declaration;

    if !ident.parent || ident.parent.kind != .BINARY_OPERATION return decls, false;

    binary_op := cast(*Binary_Operation) ident.parent;
    if binary_op.right == ident return decls, false;

    if !binary_op.parent || binary_op.parent.kind != .LITERAL return decls, false;

    literal := cast(*Literal) binary_op.parent;
    // @TODO: Infer the type for .{} structs literals...
    if literal.value_type != .STRUCT || !literal.struct_literal_info.type || literal.struct_literal_info.type.kind != .IDENTIFIER {
        return decls, true;
    }

    type_decls := get_identifier_decls(cast(*Identifier) literal.struct_literal_info.type);
    if type_decls.count == 0 return decls, true;

    struct_decl := type_decls[0];
    if !struct_decl.expression return decls, true;

    _struct := cast(*Struct) struct_decl.expression;

    decl := get_member_in(_struct, ident);
    if decl array_add(*decls, decl);

    return decls, true;
}

resolve_assignment_field :: (ident: *Identifier) -> []*Declaration, bool {
    decls: [..]*Declaration;

    if !ident.parent || ident.parent.kind != .UNARY_OPERATION return decls, false;

    unary_op := cast(*Unary_Operation) ident.parent;
    if unary_op.operation != .DOT return decls, false;

    if !unary_op.parent || unary_op.parent.kind != .BINARY_OPERATION return decls, false;

    binary_op_type := get_node_type(unary_op.parent, true);
    if !binary_op_type return decls, true;

    decl := get_member_in(binary_op_type, ident);
    if decl array_add(*decls, decl);

    return decls, true;
}

resolve_dot_member :: (ident: *Identifier) -> []*Declaration, bool {
    decls: [..]*Declaration;

    if !ident.parent return decls, false;

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

    if !op return decls, false;
    if op.operation != .DOT return decls, false;

    path := get_dot_path(op, leaf_node);
    if path.count < 2 return decls, false;

    path = array_view(path, 0, path.count-1);

    type := get_path_type(path);
    // @TODO: polymorphic return types — `proc(T, ...).x` doesn't resolve when proc returns *T or T.
    if !type return decls, true;

    decl := get_member_in(type, ident);
    if decl array_add(*decls, decl);

    return decls, true;
}

resolve_procedure_call_best :: (ident: *Identifier) -> []*Declaration, bool {
    decls: [..]*Declaration;

    if !ident.parent || ident.parent.kind != .PROCEDURE_CALL return decls, false;
    proc_call := cast(*Procedure_Call) ident.parent;
    if proc_call.procedure != ident return decls, false;

    candidate_decls := get_identifier_decls(ident);
    if candidate_decls.count == 0 return decls, true;

    procedures: [..]*Procedure;
    procedure_decls: [..]*Declaration;

    for proc_decl: candidate_decls {
        type := get_node_type(proc_decl, stop_at_procedure=true);
        if !type || type.kind != .PROCEDURE continue;
        array_add(*procedures, cast(*Procedure) type);
        array_add(*procedure_decls, proc_decl);
    }

    if procedures.count == 0 return decls, true;

    best := get_best_overload_for_procedure_call(procedures, proc_call);
    array_add(*decls, procedure_decls[best]);

    return decls, true;
}

resolve_identifier_for_rename :: (ident: *Identifier) -> []*Declaration {
    decls, matched := resolve_procedure_named_argument(ident);
    if matched return decls;

    decls, matched = resolve_struct_literal_field(ident);
    if matched return decls;

    decls, matched = resolve_assignment_field(ident);
    if matched return decls;

    decls, matched = resolve_dot_member(ident);
    if matched return decls;

    return get_identifier_decls(ident);
}

resolve_identifier_for_hover :: (ident: *Identifier) -> []*Declaration {
    decls, matched := resolve_procedure_named_argument(ident);
    if matched return decls;

    decls, matched = resolve_struct_literal_field(ident);
    if matched return decls;

    decls, matched = resolve_assignment_field(ident);
    if matched return decls;

    decls, matched = resolve_dot_member(ident);
    if matched return decls;

    decls, matched = resolve_procedure_call_best(ident);
    if matched return decls;

    return get_identifier_decls(ident);
}
