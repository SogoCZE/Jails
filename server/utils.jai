log_node :: (node: *Node, indent: s32 = 0) {

    if !node {
        return;
    }

    sb : String_Builder;

    for 0..indent-1 {
        append(*sb, "____");
    }

    if node.kind == {
        case .IDENTIFIER;
            ident := cast(*Identifier)node;
            log("%IDENT: %\n", builder_to_string(*sb), ident.name);
        case .BINARY_OPERATION;
            binary_op := cast(*Binary_Operation)node;
            log("%BINARY OP: %\n", builder_to_string(*sb), binary_op.operation);
            log_node(binary_op.left, indent + 1);
            log_node(binary_op.right, indent + 1);
        case .BLOCK;
            block := cast(*Block)node;
            log("%BLOCK\n", builder_to_string(*sb));

            for m: block.members {
                log_node(m, indent + 1);
            }
        case .DECLARATION;
            decl := cast(*Declaration)node;
            log("%DECL %\n", builder_to_string(*sb), decl.name, decl.type_inst);

            log_node(decl.type_inst, indent + 1);
            log("%EXPR\n", builder_to_string(*sb));
            log_node(decl.expression, indent + 1);
        case .ARRAY_TYPE;
            array_type := cast(*Array_Type)node;

            log("%ARRAY_TYPE\n", builder_to_string(*sb));
            log_node(array_type.element_type, indent + 1);
        case .ARRAY_SUBSCRIPT;
            array_sub := cast(*Array_Subscript)node;

            log("%ARRAY_SUB\n", builder_to_string(*sb));
            log_node(array_sub.expression, indent + 1);
        case;
            log("%Unhandled: %\n", builder_to_string(*sb), node.kind);
    }
}

log_node_v2 :: (node: *Node) {
    if !node {
        log("null");
        return;
    }

    builder: String_Builder;
    ast_print(*builder, node);
    log(builder_to_string(*builder));
}