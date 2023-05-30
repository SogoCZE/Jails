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

get_declaration :: (workspace: *Project_Workspace, name: string, from_scope: *Block = null) -> *Declaration {
    decls := get_declarations(workspace, name, from_scope);
    if decls.count == 0 return null;
    return decls[0];
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

get_path_of_binary_operation :: (root: *Node) -> []*Node {
    path: [..]*Node;
    if !root.parent || root.parent.kind != .BINARY_OPERATION return path;

    op := cast(*Binary_Operation) root.parent;

    if op.right == root array_add(*path, root);
    array_add(*path, op.left);

    while op.parent && op.parent.kind == .BINARY_OPERATION {
        parent_binary_op := cast(*Binary_Operation) op.parent;
        array_add(*path, parent_binary_op.left);
        op = parent_binary_op; 
    }

    array_reverse(path);

    return path;
}

// @InComplete
resolve_struct_member_by_path :: (workspace: *Project_Workspace, path: []*Node, from_scope: *Block = null) -> *Declaration {
    curr_decl: *Declaration;

    base := path[0];
    if base.kind != .IDENTIFIER return null;
    
    base_ident := cast(*Identifier) base; 

    curr_decl = get_declaration(workspace, base_ident.name, from_scope); // @TODO: Handle more of them
    curr_block: *Block;

    for part: path {
        if it_index == 0 continue; // Skip the base
        if part.kind != .IDENTIFIER break;

        part_ident := cast(*Identifier) part;
        decl_type := get_decl_type(workspace, curr_decl, curr_block);
        if !decl_type break;

        if decl_type.kind == .STRUCT {
            _struct := cast(*Struct) decl_type;
            if !_struct.block return null;
            curr_block = _struct.block;

            for _struct.block.members {
                if it.kind != .DECLARATION continue; // Skip all

                member_decl := cast(*Declaration) it;

                if member_decl.name == part_ident.name {
                    curr_decl = member_decl;
                    break;
                }
            }

        }
    }

    return curr_decl;
}

// @InComplete
get_decl_type :: (workspace: *Project_Workspace, decl: *Declaration, from_scope: *Block = null) -> *Node {
    if decl.type_inst {

        if decl.type_inst.kind == {

            case .IDENTIFIER;
                ident := cast(*Identifier) decl.type_inst;
                type_inst_decl := get_declaration(workspace, ident.name, from_scope);
                if !type_inst_decl return null;

                return get_decl_type(workspace, type_inst_decl);

        }

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

                decl := get_declaration(workspace, ident.name, from_scope);
                if !decl return null;

                return get_decl_type(workspace, decl);
            }


    }

}