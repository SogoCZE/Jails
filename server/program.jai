Module_Import :: struct {
    module: string;
    root: string;
}

Program_File :: struct {
    path: string;
    imports: [..]Module_Import;
    loads: [..]*Directive_Load;
    nodes: [..]*Node;
    declarations: Table(string, *Declaration);
}

init_file :: (using file: Program_File) {
    init(*declarations);
}

deinit_file :: (using file: Program_File) {
    deinit(*declarations);
    array_free(nodes);
}

reset_file :: (using file: Program_File) {
    table_reset(*declarations);
    array_reset(*nodes);
    array_reset(*loads);
    array_reset(*imports);
}

get_file :: (path: string) -> *Program_File {
    return table_find_pointer(*server.files, path);
}

parse_file :: ( path: string, force := false) {
    file_exists := table_contains(*server.files, path);
    if !force && file_exists {
        log("Skipping % because it already exists", path);
        return;
    }

    content := cast(string) get_memory_file(path);
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

    file: *Program_File;
    if file_exists {
        file = table_find_pointer(*server.files, path);
        reset_file(file); // Clear old results
    } else {
        file = table_add(*server.files, path, .{path=path});
    }

    path_without_filename := trim_right(path_strip_filename(path), "/");

    parser: Parser(Node_Visit_Data);
    parser.user_data.file = file;
    parser.user_data.path_without_filename = path_without_filename;
    parser.node_visit = node_visit;
    parser.lexer = *create_lexer(content, path);

    while !end(parser.lexer) {
        parse(*parser, null);
    }

    log("Parsed: %", path);
}

Node_Visit_Data :: struct {
    file: *Program_File;
    path_without_filename: string;
}

node_visit :: (node: *Node, data: Node_Visit_Data) {
    if !node return;

    file := data.file;
    
    get_module_entry :: (root: string) -> string {
        uri := sprint("%/module.jai", root);
        if !file_exists(uri) uri = sprint("%.jai", root);
        return uri;
    }
    
    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        table_add(*file.declarations, decl.name, decl);        
    }

    array_add(*file.nodes, node);

    if node.kind == .DIRECTIVE_IMPORT {
        _import := cast(*Directive_Import) node;

        path: string;

        if _import.import_kind == {
            case .MODULE;
                module_path := sprint("%/modules/%", server.args.jai_path, _import.module);
                path = sprint("file://%", get_module_entry(module_path));
            case .FILE;
                path = sprint("%/%", data.path_without_filename, _import.module); 
            case .DIR;
                path = sprint("%/%", data.path_without_filename, get_module_entry(_import.module)); 
            case .STRING;
                return;
                // @TODO: Do we wanna parse the string here?
        }

        module_import: Module_Import;
        module_import.module = _import.module;
        module_import.root = path;

        array_add(*data.file.imports, module_import);

        parse_file(path); // @TODO: Run this in another thread?
    }

    if node.kind == .DIRECTIVE_LOAD {
        _load := cast(*Directive_Load) node;
        load_relative_path := sprint("%/%", data.path_without_filename, _load.file);
        array_add(*data.file.loads, _load);
        parse_file(load_relative_path); // @TODO: Run this in another thread?
    }
}

get_node_by_location :: ( file: *Program_File, location: Node.Location) -> *Node {
    nearest_node: *Node;

    for node: file.nodes {

        if !node {
            log("Null node in file: % \nNodes: %\n---", file.path, file.nodes);
            continue;
        }

        if !contains(node.location, location) continue;

        // If we are not smaller than so far nearest node we skip.
        if nearest_node && !contains(nearest_node.location, node.location) continue;

        nearest_node = node;
    }


    return nearest_node;
}

get_declarations :: (file: *Program_File, name: string, from_scope: *Block = null) -> []*Declaration {
    unfiltered_decls: [..]*Declaration;

    for server.files {
        // This ensure we take intro account only files that are being loaded or imported...
        if file.path != it.path && !is_avaiable_from(file, it.path) continue;

        decls := table_find_multiple(*it.declarations, name);
        for decl: decls {
            array_add(*unfiltered_decls, decl);
        }
    }

    decls: [..]*Declaration;

    // Procedure or Struct params
    if from_scope && from_scope.parent {
        
        if from_scope.parent.kind == {

            case .PROCEDURE;
                proc := cast(*Procedure) from_scope.parent;
        
                for arg: proc.arguments {
                    if arg.kind != .DECLARATION continue;
                    decl := cast(*Declaration) arg;
                    if decl.name == name array_add(*decls, decl);   
                }  

            case .STRUCT;
                _struct := cast(*Struct) from_scope.parent;

                for arg: _struct.polymorphic_arguments {
                    if arg.kind != .DECLARATION continue;
                    decl := cast(*Declaration) arg;
                    if decl.name == name array_add(*decls, decl);   
                }  
            
        }

    }

    for decl: unfiltered_decls {
        decl_scope := get_node_nearest_block(decl);
        global := is_global(decl);

        if !global {
            if decl.const {
                if !is_child_of_block(decl_scope, from_scope) continue;
            } else {
                log("Scopes, % ?? %", decl_scope, from_scope);
                if decl_scope != from_scope continue;
            }
        }

        array_add(*decls, decl);   
    }

    return decls;
}

is_global :: (node: *Node) -> bool {
    if !node.parent return true;
    // @TODO: #scope_export, #scope_file, #scope_module ...

    return false;
}

is_avaiable_from :: (file: *Program_File, path: string) -> bool {
    loaded: bool;

    for file.imports {
        log("Import (%) root: %", it.module, it.root);
    }

    for file.loads {
        load_path := trim_right(path_strip_filename(file.path), "/");
        load_relative_path := sprint("%/%", load_path, it.file);

        if load_relative_path == path {
            loaded = true;
            break;
        }

        next_file := get_file(load_relative_path);
        if next_file && is_avaiable_from(next_file, path) {
            loaded = true;
            break;
        }
    }

    return loaded;
}

get_declaration :: (file: *Program_File, name: string, from_scope: *Block = null) -> *Declaration {
    decls := get_declarations(file, name, from_scope);
    if decls.count == 0 return null;
    return decls[0];
}

get_node_nearest_block :: (node: *Node, dd := true) -> *Block {
    current_node := node;
    current_block: *Block;

    while current_node.parent {
        current_node = current_node.parent;

        if current_node.kind == .PROCEDURE || current_node.kind == .STRUCT break;

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
resolve_struct_member_by_path :: (file: *Program_File, path: []*Node, from_scope: *Block = null) -> *Declaration {
    curr_decl: *Declaration;

    base := path[0];
    if base.kind != .IDENTIFIER return null;
    
    base_ident := cast(*Identifier) base; 

    curr_decl = get_declaration(file, base_ident.name, from_scope); // @TODO: Handle more of them
    curr_block: *Block;

    for part: path {
        if it_index == 0 continue; // Skip the base
        if part.kind != .IDENTIFIER break;

        part_ident := cast(*Identifier) part;
        decl_type := get_decl_type(file, curr_decl, curr_block);
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
get_decl_type_ident :: (decl: *Declaration) -> *Identifier {

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
get_decl_type :: (file: *Program_File, decl: *Declaration, from_scope: *Block = null) -> *Node {
    if decl.type_inst {

        if decl.type_inst.kind == {

            case .IDENTIFIER;
                ident := cast(*Identifier) decl.type_inst;
                type_inst_decl := get_declaration(file, ident.name, from_scope);
                if !type_inst_decl return null;

                return get_decl_type(file, type_inst_decl);

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

                decl := get_declaration(file, ident.name, from_scope);
                if !decl return null;

                return get_decl_type(file, decl);
            }


    }

    return null;
}

get_struct_literal_type :: (file: *Program_File, literal: *Literal, from_scope: *Block = null) -> *Node {
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
        decl := get_declaration(file, (cast(*Identifier)binary_op.left).name, from_scope);
        if !decl return null;
        return get_decl_type_ident(decl);
    }

    return null;
}
