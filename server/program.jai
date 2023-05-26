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
    nodes: [..]*Node;
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
}

deinit_program :: (using program: Program) {
    deinit(*declarations);
}

reset_program :: (using program: Program) {
    table_reset(*declarations);
    array_reset(*nodes);
}

parse_file :: (workspace: *Project_Workspace, path: string) {

    content := cast(string) get_modified_file(path);
    if content.count == 0 {
        exists: bool;
        content, exists = read_entire_file(path);
        if !exists {
            log_error("File % does not exists!", path);
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

    nodes: [..]*Node;

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
    
    log("Node: %", node.kind);
    array_add(*data.program.nodes, node);

    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        table_add(*data.program.declarations, decl.name, decl);        
    }

    // Import and Load!
}

contains :: (a: Node.Location, b: Node.Location) -> bool {
    if a.l0 > b.l0 return false;
    if a.l1 < b.l1 return false;

    if a.l0 == b.l0 && a.c0 > b.c0 return false;
    if a.l1 == b.l1 && a.c1 < b.c1 return false;

    return true;
}

get_node_by_location :: (workspace: *Project_Workspace, location: Node.Location) -> *Node {
    nearest_node: *Node;

    for node: workspace.program.nodes {
        log("Node % -> % == %", node.kind, node.location, location);

        if !contains(node.location, location) continue;

        // If we are not smaller than so far nearest node we skip.
        if nearest_node && !contains(nearest_node.location, node.location) continue;

        nearest_node = node;
    }
    
    return nearest_node;
}

lsp_location_to_node_location :: (location: LSP_Position) -> Node.Location {
    node_location: Node.Location;
    node_location.l0 = location.line;    
    node_location.c0 = location.character;    
    node_location.l1 = location.line;    
    node_location.c1 = location.character;    
    return node_location;
}