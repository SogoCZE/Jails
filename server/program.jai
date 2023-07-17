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
    resolved_identifiers: Table(*Node, []*Declaration);
    linked_files: []*Program_File; // @TODO: this is probably stupid name for this!
}

init_file :: (using file: Program_File) {
    init(*declarations);
    init(*resolved_identifiers);
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
    file, ok := table_find(*server.files, path);
    if !ok return null;
    return file;
}

normalize_path :: (path: string) -> string {
    normalized_path := decode_url(path);

    #if OS == .WINDOWS {
        normalized_path = replace(normalized_path, "file:///", "");
        path_overwrite_separators(normalized_path, #char "/");
    } else {
        normalized_path = replace(normalized_path, "file://", "");
    }

    return normalized_path;
}

path_to_lsp_path :: (path: string) -> string {
    #if OS == .WINDOWS {
        return join("file:///", path);
    } else {
        return join("file://", path);
    }
}

parse_file :: (path: string, force := false) {
    file, ok := table_find(*server.files, path);
    if !force && ok {
        log("Skipping % because it already exists", path);
        return;
    }

    log("Parse file: %", path);

    content := cast(string) get_memory_file(path);
    if content.count == 0 {
        exists: bool;

        content, exists = read_entire_file(path);
        if !exists {
            log_error("File % does not exists!", path);
            return;
        }

    }

    if ok {
        reset_file(file); // clear old data
    } else {
        file = New(Program_File);
        file.path = path;
        init_file(file);
        table_add(*server.files, path, file);
    }

    path_without_filename := trim_right(path_strip_filename(path), "/");

    parser: Parser(Node_Visit_Data);
    parser.user_data.file = file;
    parser.user_data.path_without_filename = normalize_path(path_without_filename);
    parser.node_visit = node_visit;
    parser.lexer = *create_lexer(content, path);

    while !end(parser.lexer) {
        parse(*parser, null);
    }

    file.linked_files = get_file_links(file);
    resolve_identifiers(file);

    // log("Parsed: % (nodes: %, declarations: %, pointer: %)", path, file.nodes.count, file.declarations.count, file);
}

Node_Visit_Data :: struct {
    file: *Program_File;
    path_without_filename: string;
}

node_visit :: (node: *Node, data: Node_Visit_Data) {
    if !node return;

    file := data.file;

    if node.kind == .COMPOUND_DECLARATION {
        compound_declaration := cast(*Compound_Declaration) node;
        for member: compound_declaration.members {
            if member.kind != .COMPOUND_DECLARATION_ITEM continue;
            item := cast(*Compound_Declaration_Item) member;
            if item.item_kind != .DECLARATION || item.expression.kind != .IDENTIFIER continue;
            decl_ident := cast(*Identifier) item.expression;

            // @TODO: is this ok? Do we really wan't to create "virtual" decl here?
            decl := New(Declaration);
            decl.parent = decl_ident.parent;
            decl.location = decl_ident.location;
            decl.name = decl_ident.name;

            table_add(*file.declarations, decl.name, decl);        
        }
    }

    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        table_add(*file.declarations, decl.name, decl);        
    }

    array_add(*file.nodes, node);

    if node.kind == .DIRECTIVE_IMPORT {

        get_module_entry :: (module: string) -> string {
            uri := join(module, "/module.jai");
            if file_exists(uri) return uri;

            uri = join(module, ".jai");
            if file_exists(uri) return uri;

            return "";
        }

        get_module :: (module_name: string) -> string {
            for local_modules_folder: server.local_modules {
                absolute_path: string;
                if starts_with(local_modules_folder, "/") {
                    absolute_path = local_modules_folder;
                } else {
                    absolute_path = join(server.project_root, local_modules_folder, separator="/");
                }

                entry := get_module_entry(join(absolute_path, module_name, separator="/"));
                if entry.count > 0 return entry;
            }

            jai_modules := join(server.args.jai_path, "/modules");

            entry := get_module_entry(join(jai_modules, module_name, separator="/"));
            if entry.count > 0 return entry;

            return "";
        }

        _import := cast(*Directive_Import) node;
        path: string;

        if _import.import_kind == {
            case .MODULE;
                path = get_module(_import.module);
                if path.count == 0 return;
            case .FILE;
                path = sprint("%/%", data.path_without_filename, _import.module); 
            case .DIR;
                relative_path := sprint("%/%", data.path_without_filename, _import.module); 
                path = get_module_entry(relative_path);
                if path.count == 0 return;
            case .STRING;
                return;
                // @TODO: Do we wanna parse the string here?
        }

        module_import: Module_Import;
        module_import.root = path;
        module_import.module = _import.module;

        array_add(*data.file.imports, module_import);

        parse_file(path); // @TODO: Run this in another thread?
    }

    if node.kind == .DIRECTIVE_LOAD {
        _load := cast(*Directive_Load) node;

        load_relative_path := join(data.path_without_filename, _load.file, separator="/");
        array_add(*data.file.loads, _load);
        parse_file(load_relative_path); // @TODO: Run this in another thread?
    }
}

resolve_identifiers :: (file: *Program_File) {
    log("Resolving identifiers for file: %", file.path);

    for node: file.nodes {
        if node.kind == .IDENTIFIER {
            ident := cast(*Identifier) node;
            // log("Ident: %", ident.name);

            block := get_node_nearest_block(ident);
            decls := get_declarations(file, ident.name, block, *ident.location);
            if decls.count < 1 {
                // log_error("Did not find any decl for '%'!", ident.name);
                continue;
            }

            table_add(*file.resolved_identifiers, ident, decls);
        }

    }

    log("Resolved identifiers for: %", file.path);
}

get_node_by_location :: (file: *Program_File, location: Node.Location, filter: Node.Kind = .UNINITIALIZATED) -> *Node {
    nearest_node: *Node;

    for node: file.nodes {
        if filter != .UNINITIALIZATED && node.kind != filter continue;
        if !contains(node.location, location) continue;

        // If we are not smaller than so far nearest node we skip.
        if nearest_node && !contains(nearest_node.location, node.location) continue;

        nearest_node = node;
    }


    return nearest_node;
}

get_file_links :: (file: *Program_File) -> []*Program_File {
    files: [..]*Program_File;
    
    files_that_load_this_file := get_files_that_load(file);
    defer array_free(files_that_load_this_file);

    for server.files {
        // This ensure we take into account only files that are being loaded or imported...
        if file.path != it.path {

            is_avaiable_from_one_of_the_parents: bool;

            for file_that_load_this_file: files_that_load_this_file {
                already_checked: [..]string;
                defer array_free(already_checked);
    
                if file_that_load_this_file.path == it.path {
                    is_avaiable_from_one_of_the_parents = true;
                    break;    
                }

                if !is_avaiable_from(file_that_load_this_file, it.path, *already_checked) continue;
    
                is_avaiable_from_one_of_the_parents = true;
                break;
            }
    
            already_checked: [..]string;
            defer array_free(already_checked);
    
            if !is_avaiable_from_one_of_the_parents && !is_avaiable_from(file, it.path, *already_checked) continue;
        } 

        array_add(*files, it);
    }

    return files;
}

get_declarations :: (file: *Program_File, name: string, from_block: *Block = null, from_loc: *Node.Location = null) -> []*Declaration {
    decls: [..]*Declaration;
    
    // Procedure or Struct params
    if from_block && from_block.parent {
        
        if from_block.parent.kind == {

            case .PROCEDURE;
                proc := cast(*Procedure) from_block.parent;
        
                for arg: proc.arguments {
                    if arg.kind != .DECLARATION continue;
                    decl := cast(*Declaration) arg;
                    if decl.name == name array_add(*decls, decl);   
                }  

            case .STRUCT;
                _struct := cast(*Struct) from_block.parent;

                for arg: _struct.polymorphic_arguments {
                    if arg.kind != .DECLARATION continue;
                    decl := cast(*Declaration) arg;
                    if decl.name == name array_add(*decls, decl);   
                }  
            
        }

    }

    for linked_file: file.linked_files {
        unfiltered_decls := table_find_multiple(*linked_file.declarations, name);       

        for decl: unfiltered_decls {
            decl_block := get_node_nearest_block(decl);
            global := is_global(decl);

            if !global {
                if decl.const {
                    if !is_child_of_block(decl_block, from_block) continue;
                } else {
                    // log("Scopes, % ?? %", decl_block, from_block);
                    if decl_block != from_block continue;
                    if from_loc && from_loc.l0 < decl.location.l0 continue;
                }
            }

            array_add(*decls, decl);   
        }
    }

    return decls;
}

// @TODO: this is copypasta of the procedure get_declarations - we need to split it more and reuse it. 
// Here we dont want to find specific decl by name but filter all avaiable decls in provided context.
get_all_declarations :: (file: *Program_File, from_block: *Block = null, from_loc: *Node.Location = null) -> []*Declaration {
    decls: [..]*Declaration;

    // Procedure or Struct params
    if from_block && from_block.parent {
        
        if from_block.parent.kind == {

            case .PROCEDURE;
                proc := cast(*Procedure) from_block.parent;
        
                for arg: proc.arguments {
                    if arg.kind != .DECLARATION continue;
                    decl := cast(*Declaration) arg;
                    array_add(*decls, decl);   
                }  

            case .STRUCT;
                _struct := cast(*Struct) from_block.parent;

                for arg: _struct.polymorphic_arguments {
                    if arg.kind != .DECLARATION continue;
                    decl := cast(*Declaration) arg;
                    array_add(*decls, decl);   
                }  
            
        }

    }

    for linked_file: file.linked_files {
        
        for decl: linked_file.declarations {
            decl_block := get_node_nearest_block(decl);
            global := is_global(decl);

            if !global {
                if decl.const {
                    if !is_child_of_block(decl_block, from_block) continue;
                } else {
                    // log("Scopes, % ?? %", decl_block, from_block);
                    if decl_block != from_block continue;
                    if from_loc && from_loc.l0 < decl.location.l0 continue;
                }
            }

            array_add(*decls, decl);   
        }

    }

    return decls;
}

is_global :: (node: *Node) -> bool {
    if !node.parent return true;

    // @TODO: #scope_file, #scope_module ...
    if node.parent.kind == .DIRECTIVE_SCOPE {
        directive_scope := cast(*Directive_Scope) node.parent;
        if directive_scope.scope_kind == .EXPORT return true;
    } 
    return false;
}

get_files_that_load :: (target_file: *Program_File) -> []*Program_File {
    files: [..]*Program_File;

    for file: server.files {
        already_checked: [..]string;
        defer array_free(already_checked);
        if !is_avaiable_from(file, target_file.path, *already_checked, true) continue;
        array_add(*files, file);
    }

    return files;
}

is_avaiable_from :: (file: *Program_File, path: string, already_checked: *[..]string, $loads_only := false) -> bool {
    loaded: bool;

    if !loads_only {
        for file.imports {
            if array_find(already_checked.*, it.root) continue;
            array_add(already_checked, it.root);

            if it.root == path {
                loaded = true;
                break;
            }

            next_file := get_file(it.root);
            if next_file && is_avaiable_from(next_file, path, already_checked) {
                loaded = true;
                break;
            }

        }
    }

    
    for file.loads {
        load_path := trim_right(path_strip_filename(file.path), "/");
        load_relative_path := join(load_path, "/", it.file);
        defer free(load_relative_path);

        if array_find(already_checked.*, load_relative_path) continue;
        array_add(already_checked, load_relative_path);

        if load_relative_path == path {
            loaded = true;
            break;
        }

        next_file := get_file(load_relative_path);
        if next_file && is_avaiable_from(next_file, path, already_checked) {
            loaded = true;
            break;
        }
    }

    return loaded;
}

get_declaration :: (file: *Program_File, name: string, from_block: *Block = null) -> *Declaration {
    decls := get_declarations(file, name, from_block);
    if decls.count == 0 return null;
    return decls[0];
}

get_node_nearest_block :: (node: *Node) -> *Block {
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

    // log("Last %", current_node.*);

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
    lsp_location.uri = path_to_lsp_path(location.file);
    lsp_location.range.start.line = xx location.l0;
    lsp_location.range.start.character = xx location.c0;
    lsp_location.range.end.line = xx location.l1;
    lsp_location.range.end.character = xx location.c1;
    return lsp_location;
}

get_identifier_decl :: (__file: *Program_File, ident: *Identifier) -> []*Declaration {
    for file: server.files {
        decls, ok := table_find(*file.resolved_identifiers, ident);
        if !ok continue;
        return decls;
    }

    return .[];
}

// @TODO: Maybe refactor this to be more useful?
get_node_type :: (file: *Program_File, root: *Node) -> *Node {
    current_node: *Node = root;

    while true {

        if current_node.kind == .IDENTIFIER {
            ident_decls := get_identifier_decl(file, xx current_node);
            log("ident_decls = % for %", ident_decls, (cast(*Identifier) current_node).name);
            if ident_decls.count == 0 return null;
            current_node = ident_decls[0];
            continue;
        }

        if current_node.kind == .DECLARATION {
            decl := cast(*Declaration) current_node;

            if decl.expression {

                if decl.expression.kind == .STRUCT || decl.expression.kind == .ENUM || decl.expression.kind == .UNION {
                    return decl.expression;
                }

                if decl.expression.kind == .PROCEDURE {
                    proc := cast(*Procedure) decl.expression;
                    if proc.returns.count > 0 {
                        current_node = proc.returns[0];
                        continue;
                    }
                }

            }

            if decl.type_inst  {
                current_node = decl.type_inst;
                continue;
            }

            if decl.expression {
                current_node = decl.expression;
                continue;
            }

        }

        if current_node.kind == .RETURN_VALUE {
            return_value := cast(*Return_Value) current_node;
            current_node = return_value.expression;
            continue;
        }
        
        if current_node.kind == .BINARY_OPERATION {
            current_node = get_dot_path_result(file, xx current_node);
            continue;
        }

        if current_node.kind == .PROCEDURE_CALL {
            proc_call := cast(*Procedure_Call) current_node;
            current_node = proc_call.procedure;
            continue;
        }

        if current_node.kind == .UNARY_OPERATION {
            current_node = unwrap_pointer(xx current_node);
            continue;
        }

        if current_node.kind == .CAST {
            _cast := cast(*Cast) current_node;
            current_node = _cast.cast_expression;
            continue;
        }

        break;
    }   

    return null;
}

unwrap_pointer :: (unary_op: *Unary_Operation) -> *Node {
    if unary_op.operation != .POINTER return unary_op;

    // nested pointers
    if unary_op.expression.kind == .UNARY_OPERATION {
        return unwrap_pointer(xx unary_op.expression);
    }   

    return unary_op.expression;
}

get_block_of :: (node: *Node) -> *Block {
    if node.kind == {
        case .STRUCT; return (cast(*Struct) node).block;
        case .ENUM;   return (cast(*Enum) node).block;
        case .UNION;  return (cast(*Union) node).block;
    }

    return null;
}

get_member_in :: (parent: *Node, ident: *Identifier) -> *Declaration {
    block := get_block_of(parent);
    if !block return null;
    return get_block_member(block, ident);
}

get_root_of_dot_path :: (op: *Binary_Operation) -> *Binary_Operation {
    current := op;
    
    while current.parent && current.parent.kind == .BINARY_OPERATION {
        parent := cast(*Binary_Operation) current.parent;
        if parent.operation != .DOT break;
        current = parent;
    }

    return current;
}

get_block_member :: (block: *Block, ident: *Identifier) -> *Declaration {
    for member: block.members {
        if member.kind != .DECLARATION continue;
        decl := cast(*Declaration) member;
        if decl.name == ident.name return xx member;
    }

    return null;
}

get_dot_path_result :: (file: *Program_File, op: *Binary_Operation, target: *Identifier = null) -> *Declaration {
    decl: *Declaration;
    current_op := op;

    if current_op.left.kind != .IDENTIFIER return null;


    current_type := get_node_type(file, current_op.left); // STRUCT, ENUM, UNION ...
    log("current_op.left = %, current_type = %", (cast(*Identifier) current_op.left).name, current_type);
    if !current_type return null;

    if current_op.left == target {
        decls := get_identifier_decl(file, xx current_op.left);
        if decls.count == 0 return null;
        return decls[0];
    }

    while true {
        if current_op.operation != .DOT break;
        if !current_op.right break;
        
        ident: *Identifier;
        end := false;

        if current_op.right.kind == {
    
            case .IDENTIFIER;
                ident = xx current_op.right;
                end = true;

            case .BINARY_OPERATION;
                current_op = cast(*Binary_Operation) current_op.right;
                ident = cast(*Identifier) current_op.left;

            case; break;

        } 

        if ident == target {
            end = true;
        }

        member := get_member_in(current_type, ident);        
        if !member break;
        decl = member;

        if end break;

        current_type = get_node_type(file, decl);
    }

    return decl;
}