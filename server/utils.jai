log_node :: (node: *Node, prefix: string = "") {
    log("%'%'", prefix, to_debug_string(node));
}

to_string :: (node: *Node) -> string {
     if !node {
        return "null";
    }

    builder: String_Builder;
    ast_print(*builder, node);
    return builder_to_string(*builder);
}

to_debug_string :: (node: *Node) -> string {
    if !node {
        return "null";
    }

    if node.kind == {
        case .IDENTIFIER;
            return tprint("IDENTIFIER (%)", cast(*Identifier, node).name);
        case;
            return tprint("%", node.kind);
    }
}