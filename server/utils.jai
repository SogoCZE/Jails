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

array_reverse :: (array: []$T) {
    n := array.count;
    i := 0;
    while i < n / 2 {
        j := n - 1 - i;
        tmp := array[i];
        array[i] = array[j];
        array[j] = tmp;
        i += 1;
    }
}

log_path :: (path: []*Node) {
    for path log("[%]: %", it_index, to_string(it));
}

operator == :: (a: Node.Location, b: Node.Location) -> bool {
    return a.l0 == b.l0 && a.l1 == b.l1 && a.c0 == b.c0 && a.c1 == b.c1;
}
