// This file contains procedures to turn parser nodes into string.
// This is useful when we need to provide "peek" of code to the editor.

render :: (builder: *String_Builder, node: *Node) {
    if node.kind == {
        case .IDENTIFIER; render_identifier(builder, xx node);
        case .DECLARATION; render_declaration(builder, xx node);
        case .UNARY_OPERATION; render_unary_operation(builder, xx node);
        case .RETURN_VALUE; render_return_value(builder, xx node);
        case; append(builder, sprint("%", node.kind));
    }
}

render_identifier :: (builder: *String_Builder, ident: *Identifier) {
    if ident.backticked append(builder, #char "`"); 
    append(builder, ident.name); 
}

render_unary_operation :: (builder: *String_Builder, unary_op: *Unary_Operation) {
    if unary_op.operation == .POINTER {
        append(builder, #char "*");
    } else {
        append(builder, sprint("%", unary_op.operation));
    }

    render(builder, unary_op.expression);
}

render_declaration :: (builder: *String_Builder, decl: *Declaration) {
    append(builder, decl.name);

    if decl.type_inst {
        append(builder, ": ");
        render(builder, decl.type_inst);
    }

}

render_return_value :: (builder: *String_Builder, return_val: *Return_Value) {
    if return_val.must append(builder, "#must");
    render(builder, return_val.expression);
}

render_procedure_header :: (builder: *String_Builder, proc: *Procedure) {
    append(builder, #char "(");

    for arg: proc.arguments {
        render(builder, arg);
        if it_index != proc.arguments.count-1 {
            append(builder, ", ");
        }
    }

    append(builder, #char ")");

    if proc.returns.count > 0 {
        append(builder, " -> ");

        for _return: proc.returns {
            render(builder, _return);
            if it_index != proc.returns.count-1 {
                append(builder, ", ");
            }
        }
    }
}