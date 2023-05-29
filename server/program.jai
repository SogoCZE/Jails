Project_Workspace :: struct {
    index: u8;
    
    entry: string;
    working_directory: string;
    local_modules_directory: string;
    
    last_refresh_time: Apollo_Time = APOLLO_TIME_INVALID;

    previously_errored_file: string;

    program_a: Program;
    program_b: Program;

    work_program: *Program;
    program: *Program;   
}

Program :: struct {
    declarations: Table(string, *Declaration);
    files: Table(string, [..]*Node);
}

init_workspace :: (workspace: *Project_Workspace, entry: string, index: u8, local_modules_directory: string = "") {
    workspace.index = index;
    workspace.entry = entry;
    workspace.working_directory = path_strip_filename(entry);

    if local_modules_directory.count > 0 {
        workspace.local_modules_directory = local_modules_directory;
    } else {
        workspace.local_modules_directory = find_local_modules(workspace.working_directory);
    }

    init_program(workspace.program_a);
    init_program(workspace.program_b);

    workspace.work_program = *workspace.program_b;
    workspace.program      = *workspace.program_a;
}

deinit_workspace :: (workspace: *Project_Workspace) {
    deinit_program(*workspace.program_a);
    deinit_program(*workspace.program_b);
}

init_program :: (using program: Program) {
    init(*declarations);
    init(*files);
}

deinit_program :: (using program: Program) {
    deinit(*declarations);
    deinit(*files);
}

reset_program :: (using program: Program) {
    table_reset(*declarations);
    table_reset(*files);
}

parse_file :: (workspace: *Project_Workspace, path: string) {

    content := cast(string) get_modified_file(path);
    if content.count == 0 {
        exists: bool;
        path_without_file_prefix := replace(path, "file://", "");
        defer free(path_without_file_prefix);
        content, exists = read_entire_file(path_without_file_prefix);
        if !exists {
            log_error("File % does not exists!", path_without_file_prefix);
            return;
        }
    }

    log("[%]: Parsing started!", path);

    path_without_filename := trim_right(path_strip_filename(path), "/");

    parser: Parser(Node_Visit_Data);
    parser.user_data.program = workspace.program;
    parser.user_data.path_without_filename = path_without_filename;
    parser.node_visit = node_visit;
    parser.lexer = *create_lexer(content, path);

    // @TODO: We need to free old nodes from the memory!
    reset_program(workspace.program);

    nodes: [..]*Node;
    table_set(*workspace.program.files, path, nodes);

    while !end(parser.lexer) {
        parse(*parser, null);
    }

    log("[%]: Parsing done!", path);
}

Node_Visit_Data :: struct {
    program: *Program;
    path_without_filename: string;
}

node_visit :: (node: *Node, data: Node_Visit_Data) {
    if !node return;
    
    // log("Node: %", node.kind);

    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        table_add(*data.program.declarations, decl.name, decl);        
    }

    nodes := table_find_pointer(*data.program.files, node.location.file);
    if !nodes return;

    array_add(nodes, node);

    // Import and Load!
}

get_node_by_location :: (workspace: *Project_Workspace, location: Node.Location) -> *Node {
    nearest_node: *Node;

    nodes, ok := table_find(*workspace.program.files, location.file);
    if !ok return null;

    for node: nodes {
        if !contains(node.location, location) continue;

        // If we are not smaller than so far nearest node we skip.
        if nearest_node && !contains(nearest_node.location, node.location) continue;

        nearest_node = node;
    }
    
    return nearest_node;
}

get_declarations :: (workspace: *Project_Workspace, name: string, from_scope: *Block = null) -> []*Declaration {
    unfiltered_decls := table_find_multiple(*workspace.program.declarations, name);
    if !from_scope return unfiltered_decls;

    decls: [..]*Declaration;

    for decl: unfiltered_decls {
        if decl.parent && decl.parent != from_scope continue;
        array_add(*decls, decl);   
    }

    return decls;
}

get_node_nearest_block :: (node: *Node) -> *Block {
    current_node := node;
    current_block: *Block;

    while current_node.parent {
        current_node = current_node.parent;
        if current_node.kind == .BLOCK {
            current_block = xx current_node;  
        }
    }

    return current_block;
}

contains :: (a: Node.Location, b: Node.Location) -> bool {
    if a.l0 > b.l0 return false;
    if a.l1 < b.l1 return false;

    if a.l0 == b.l0 && a.c0 > b.c0 return false;
    if a.l1 == b.l1 && a.c1 < b.c1 return false;

    return true;
}

lsp_location_to_node_location :: (location: LSP_Position, file := "") -> Node.Location {
    node_location: Node.Location;
    node_location.file = file;
    node_location.l0 = location.line;    
    node_location.c0 = location.character;    
    node_location.l1 = location.line;    
    node_location.c1 = location.character;    
    return node_location;
}

node_location_to_lsp_location :: (location: Node.Location) -> LSP_Location {
    lsp_location: LSP_Location;
    lsp_location.uri = location.file;
    lsp_location.range.start.line = xx location.l0;
    lsp_location.range.start.character = xx location.c0;
    lsp_location.range.end.line = xx location.l1;
    lsp_location.range.end.character = xx location.c1;
    return lsp_location;
}

// @TODO: rename this to struct member something?
get_path_of_binary_operation :: (binary_op: *Binary_Operation) -> []*Node {
    path: [..]*Node;
    array_add(*path, binary_op.left);
    array_add(*path, binary_op.right);
    node := binary_op.left;

    while node.parent && node.parent.kind == .BINARY_OPERATION {
        parent_binary_op := cast(*Binary_Operation) node.parent;
        if !parent_binary_op.left || parent_binary_op.left == node break;
        array_add(*path, parent_binary_op.left);
        node = parent_binary_op.left; 
    }

    array_reserve(*path, path.count);

    return path;
}

resolve_struct_member_by_path :: (workspace: *Project_Workspace, path: []*Node) -> *Declaration {
    _struct: *Struct;

    base := path[0];

    // @TODO: Real path traverse!

    if base.kind == .IDENTIFIER {
        ident := cast(*Identifier) base;
        decl := get_declarations(workspace, ident.name)[0];

        decl_type := get_decl_type(workspace, decl);

        if decl_type.kind == .STRUCT {
            _struct := cast(*Struct) decl_type;
            if !_struct.block return null;

            for _struct.block.members {
                if it.kind != .DECLARATION continue; // Skip all

                member_decl := cast(*Declaration) it;
                final_ident := cast(*Identifier) path[1];

                if member_decl.name == final_ident.name {
                    return member_decl;
                }
            }

        }

    }
}

get_decl_type :: (workspace: *Project_Workspace, decl: *Declaration) -> *Node {
    if decl.type_inst {
        // @TODO
    }

    if !decl.expression return null;

    if decl.expression.kind == {
        
        case .STRUCT;
            return decl.expression;

        case .LITERAL;
            literal := cast(*Literal) decl.expression;

            if literal.value_type != .STRUCT return null;
            if !literal.struct_literal_info.type return null;

            if literal.struct_literal_info.type.kind == .IDENTIFIER {
                ident := cast(*Identifier) literal.struct_literal_info.type;

                decl := get_declarations(workspace, ident.name)[0];
                return get_decl_type(workspace, decl);
            }


    }

}