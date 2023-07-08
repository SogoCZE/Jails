// This file contains procedures to turn parser nodes into string.
// This is useful when we need to provide "peek" of code to the editor.
// Also we could probably use this for formatter?

render :: (builder: *String_Builder, node: *Node) {
    if node.kind == {
        case .IDENTIFIER;                   render_identifier(builder, xx node);
        case .DECLARATION;                  render_declaration(builder, xx node);
        case .UNARY_OPERATION;              render_unary_operation(builder, xx node);
        case .BINARY_OPERATION;             render_binary_operation(builder, xx node);
        case .RETURN_VALUE;                 render_return_value(builder, xx node);
        case .POLYMORPHIC_CONSTANT;         render_polymorphic_constant(builder, xx node);
        case .USING;                        render_using(builder, xx node);
        case;                               append(builder, sprint("%", node.kind));
    }
}

render_identifier :: (builder: *String_Builder, ident: *Identifier) {
    if ident.backticked append(builder, #char "`"); 
    append(builder, ident.name); 
}

render_polymorphic_constant :: (builder: *String_Builder, poly_const: *Polymorphic_Constant) {
    append(builder, #char "$"); 
    if poly_const.maybe_constant append(builder, #char "$"); 
    
    if poly_const.expression {
        render(builder, poly_const.expression);
    }

    if poly_const.restriction {
        append(builder, #char "/");
        if poly_const.restrictions_interface append(builder, "interface ");
        render(builder, poly_const.restriction);
    }

}

render_unary_operation :: (builder: *String_Builder, unary_op: *Unary_Operation) {
    if unary_op.operation == .POINTER {
        append(builder, #char "*");
    } else {
        append(builder, sprint("%", unary_op.operation));
    }

    render(builder, unary_op.expression);
}

render_binary_operation :: (builder: *String_Builder, binary_op: *Binary_Operation) {
    if binary_op.left {
        render(builder, binary_op.left);
    }
    
    if binary_op.operation == {
        case .DOT;                                      append(builder, #char ".");
        case .RANGE;                                    append(builder, "..");

        case .ADDITION;                                 append(builder, #char "+");
        case .SUBTRACTION;                              append(builder, #char "-");
        case .MULTIPLICATION;                           append(builder, #char "*");
        case .DIVISION;                                 append(builder, #char "/");
        case .MODULO;                                   append(builder, #char "%");
        case .LESS;                                     append(builder, #char ">");
        case .GREATER;                                  append(builder, #char "<");
        case .ASSING;                                   append(builder, #char "=");
        case .BITWISE;                                  append(builder, #char "%");
        case .PIPE;                                     append(builder, #char "|");
        case .COMPLEMENT;                               append(builder, #char "~");
        
        case .BITWISE_EQUAL;                            append(builder, "&=");
        case .PIPE_EQUAL;                               append(builder, "|=");
        case .GREATER_EQUAL;                            append(builder, ">=");
        case .LESS_EQUAL;                               append(builder, "<=");
        case .PLUS_EQUAL;                               append(builder, "+=");
        case .MINUS_EQUAL;                              append(builder, "-=");
        case .MOD_EQUAL;                                append(builder, "%=");
        case .DIV_EQUAL;                                append(builder, "/=");
        case .TIMES_EQUAL;                              append(builder, "*=");
        case .LOGICAL_AND;                              append(builder, "&&");
        case .LOGICAL_AND_ASSIGNMENT;                   append(builder, "&&=");
        case .LOGICAL_OR;                               append(builder, "||");
        case .LOGICAL_OR_ASSIGNMENT;                    append(builder, "||=");
        case .IS_EQUAL;                                 append(builder, "==");
        case .IS_NOT_EQUAL;                             append(builder, "!=");
        case .LEFT_SHIFT;                               append(builder, "<<");
        case .RIGHT_SHIFT;                              append(builder, ">>");
        case .LEFT_SHIFT_ASSIGNMENT;                    append(builder, "<<= ");
        case .RIGHT_SHIFT_ASSIGNMENT;                   append(builder, ">>=");
        case .UNSIGNED_RIGHT_SHIFT;                     append(builder, ">>>");
        case .UNSIGNED_LEFT_SHIFT;                      append(builder, "<<<");
        case .UNSIGNED_RIGHT_SHIFT_ASSIGNMENT;          append(builder, ">>>=");
        case .UNSIGNED_LEFT_SHIFT_ASSIGNMENT;           append(builder, "<<<=");
        
        case .ARRAY_SUBSCRIPT;                          append(builder, "[]");
        case .ARRAY_SUBSCRIPT_ASSIGNMENT;               append(builder, "[]=");
    }

    if binary_op.right {
        render(builder, binary_op.right);
    }
}

render_declaration :: (builder: *String_Builder, decl: *Declaration) {
    append(builder, decl.name);

    if decl.type_inst {
        append(builder, ": ");
        render(builder, decl.type_inst);
    }

}

render_using :: (builder: *String_Builder, _using: *Using) {
    append(builder, "using");

    if _using.filter_type != .NONE {
        append(builder, #char ",");

        if _using.filter_expression {
            append(builder, #char " ");
            render(builder, _using.filter_expression);
        } else {
            append(builder, #char "(");
            for filter: _using.filters render(builder, filter);
            append(builder, #char ")");
        }
        
    }

    append(builder, #char " ");
    render(builder, _using.expression);
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