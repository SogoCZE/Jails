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

parse_file :: (workspace: *Project_Workspace, path: string, force := false) {
    if !force && table_contains(*workspace.program.files, path) {
        log("Skipping % because it already exists", path);
        return;
    }

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
    parser.user_data.workspace = workspace;
    parser.user_data.path_without_filename = path_without_filename;
    parser.node_visit = node_visit;
    parser.lexer = *create_lexer(content, path);

    // @TODO: We need to free old nodes from the memory!
    // reset_program(workspace.program);

    // table_set()

    nodes: [..]*Node;
    table_set(*workspace.program.files, path, nodes);

    while !end(parser.lexer) {
        parse(*parser, null);
    }

    log("[%]: Parsing done!", path);
}

Node_Visit_Data :: struct {
    workspace: *Project_Workspace;
    path_without_filename: string;
}

node_visit :: (node: *Node, data: Node_Visit_Data) {
    if !node return;
    
    get_module_entry :: (root: string) -> string {
        uri := tprint("%/module.jai", root);
        if !file_exists(uri) uri = tprint("%.jai", root);
        return uri;
    }
    
    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        table_add(*data.workspace.program.declarations, decl.name, decl);        
    }

    nodes := table_find_pointer(*data.workspace.program.files, node.location.file);
    if !nodes return;

    array_add(nodes, node);

    if node.kind == .DIRECTIVE_IMPORT {
        _import := cast(*Directive_Import) node;

        path: string;

        if _import.import_kind == {
            case .MODULE;
                module_path := tprint("%/modules/%", server.args.jai_path, _import.module);
                path = get_module_entry(module_path);
            case .FILE;
                path = tprint("%/%", data.path_without_filename, _import.module); 
            case .DIR;
                path = tprint("%/%", data.path_without_filename, get_module_entry(_import.module)); 
            case .STRING;
                // @TODO: Do we wanna parse the string here?
        }

        parse_file(data.workspace, path); // @TODO: Run this in another thread?
    }

    if node.kind == .DIRECTIVE_LOAD {
        _load := cast(*Directive_Load) node;
        load_relative_path := tprint("%/%", data.path_without_filename, _load.file);
        parse_file(data.workspace, load_relative_path); // @TODO: Run this in another thread?
    }
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
    // if !from_scope return unfiltered_decls;

    decls: [..]*Declaration;

    // if from_scope && from_scope.parent {
        
    //     if from_scope.parent.kind == {

    //         case .PROCEDURE;
    //             proc := cast(*Procedure) from_scope.parent;
        
    //             for arg: proc.arguments {
    //                 if arg.kind != .DECLARATION continue;
    //                 decl := cast(*Declaration) arg;
    //                 if decl.name == name array_add(*decls, decl);   
    //             }  

    //         case .STRUCT;
    //             _struct := cast(*Struct) from_scope.parent;

    //             for arg: _struct.polymorphic_arguments {
    //                 if arg.kind != .DECLARATION continue;
    //                 decl := cast(*Declaration) arg;
    //                 if decl.name == name array_add(*decls, decl);   
    //             }  
            
    //     }

    // }

    for decl: unfiltered_decls {
        decl_scope := get_node_nearest_block(decl);

        // @TODO: #scope_export, #scope_file, #scope_module ...

        if decl.const {
            if !is_child_of_block(decl_scope, from_scope) continue;
        } else {
            log("Scopes, % ?? %", decl_scope, from_scope);
            if decl_scope && decl_scope != from_scope {
                continue;
            }
        }

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
            block := cast(*Block) current_node; 
            current_block = xx block;  

            if !block.parent break;

            if block.parent.kind == {
                case .PROCEDURE; break;
                case .STRUCT; break;
                case .UNION; break;
                case .ENUM; break;
            }

        }
    }

    return current_block;
}

is_child_of_block :: (block: *Block, node: *Node) -> bool {
    if !block || !node return false;

    current_node := node;

    log("Last %", current_node.*);

    if current_node == block return true;

    while current_node.parent {
        current_node = current_node.parent;
        if current_node == block return true;
    }

    return false;
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

get_path_of_binary_operation :: (root: *Node) -> []*Node, *Binary_Operation {
    path: [..]*Node;
    if !root.parent || root.parent.kind != .BINARY_OPERATION return path, null;

    op := cast(*Binary_Operation) root.parent;

    if op.right == root array_add(*path, root);
    array_add(*path, op.left);

    while op.parent && op.parent.kind == .BINARY_OPERATION {
        parent_binary_op := cast(*Binary_Operation) op.parent;
        array_add(*path, parent_binary_op.left);
        op = parent_binary_op; 
    }

    array_reverse(path);

    return path, op;
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
get_decl_type_ident :: (workspace: *Project_Workspace, decl: *Declaration) -> *Identifier {

    // @TODO: Path... decl: Entity.Stats;
    if decl.type_inst && decl.type_inst.kind == .IDENTIFIER {
        return xx decl.type_inst;
    }

    if decl.expression && decl.expression.kind == .IDENTIFIER {
        return xx decl.expression;
    }

    return null;
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

get_struct_literal_type :: (workspace: *Project_Workspace, literal: *Literal, from_scope: *Block = null) -> *Node {
    if literal.value_type != .STRUCT return null;
    
    if literal.struct_literal_info.type {
        if literal.struct_literal_info.type.kind != .IDENTIFIER return null; // @TODO: Entity.Stats.{speed=20};
        literal_type_ident := cast(*Identifier) literal.struct_literal_info.type;
        return literal_type_ident;
    }

    // If the struct is infer we need to find type from decl
    if !literal.parent || literal.parent.kind != .BINARY_OPERATION return null;
    binary_op := cast(*Binary_Operation) literal.parent;

    if binary_op.operation != .ASSING return null;

    
    if binary_op.left.kind == .IDENTIFIER {
        decl := get_declaration(workspace, (cast(*Identifier)binary_op.left).name, from_scope);
        if !decl return null;
        return get_decl_type_ident(workspace, decl);
    }

    return null;
}
