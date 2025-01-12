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
    // resolved_identifiers: Table(*Identifier, []*Declaration);
    linked_files: []Linked_File; // @TODO: this is probably stupid name for this!

    ast_pool: Pool;
    analysis_pool: Pool;
}

Linked_File :: struct {
    from_import: bool;
    file: *Program_File;
}

empty_identifier := Identifier.{
    name = "",
};

s64_node := Identifier.{
    name = "s64",
};

void_star_node := Identifier.{
    name = "*void",
};

unknown_identifier_node := Identifier.{
    name = "---",
};

array_count_declaration := Declaration.{
    name = "count",
    type_inst = xx *s64_node
};

init_file :: (using file: Program_File) {
    init(*declarations);
    // init(*resolved_identifiers);
}

deinit_file :: (using file: Program_File) {
    deinit(*declarations);
    array_free(nodes);
    array_free(loads);
    array_free(imports);
    release(*file.ast_pool);
    release(*file.analysis_pool);
}

reset_file :: (using file: Program_File) {
    table_reset(*declarations);
    array_reset(*nodes);
    array_reset(*loads);
    array_reset(*imports);
    release(*file.ast_pool);
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

pool_alloc :: (pool: *Pool) -> Allocator {
    return .{pool_allocator_proc, pool};
}

parse_file :: (path: string, force := false) {
    // Reset back to default allocator, we dont want to use pool from "parent" file...
    context.allocator = context.default_allocator;

    file, ok := table_find(*server.files, path);
    if !force && ok {
        // log("Skipping % because it already exists", path);
        return;
    }

    // log("Parse file: %", path);

    content := cast(string) get_memory_file(path);
    content_from_disc: bool;

    if content.count == 0 {
        exists: bool;

        content, exists = read_entire_file(path, log_errors=false);
        if !exists {
            // log_error("File % does not exists!", path);
            return;
        }

        content_from_disc = true;
    }

    if ok {
        reset_file(file); // clear old data
    } else {
        file = New(Program_File);
        file.path = copy_string(path);
        set_allocators(*file.ast_pool, context.default_allocator);
        set_allocators(*file.analysis_pool, context.default_allocator);
        init_file(file);
        table_add(*server.files, file.path, file);
    }

    path_without_filename := trim_right(path_strip_filename(file.path), "/");

    {
        _pool := pool_alloc(*file.ast_pool);

        push_allocator(_pool);

        parser: Parser(Node_Visit_Data);
        parser.user_data.allocator = _pool;
        parser.user_data.file = file;
        parser.user_data.path_without_filename = normalize_path(path_without_filename);
        parser.node_visit = node_visit;
        parser.lexer = *create_lexer(content, file.path);

        while !end(parser.lexer) {
            parse(*parser, null);
        }

    }

    if content_from_disc free(content);
    // log("Parsed: % (nodes: %, declarations: %, pointer: %)", path, file.nodes.count, file.declarations.count, file);

    array_add_if_unique(*server.files_to_be_analyzed, file);

    // We must revalidate all files that are using this file in some way.
    files_avaiable_from_this_file := get_files_that_are_avaiable_from(file,, temp);
    for file_that_load_this_file: files_avaiable_from_this_file {
        // if array_find(server.files_to_be_analyzed, file_that_load_this_file) {
        //     continue;
        // }

        array_add_if_unique(*server.files_to_be_analyzed, file_that_load_this_file);
    }
}

analyze_files :: () {
    for file: server.files_to_be_analyzed {
        // table_reset(*file.resolved_identifiers);
        // array_reset(*file.unresolved_identifiers);
        release(*file.analysis_pool);
    }

    preload_file: *Program_File;
    runtime_support_file: *Program_File;

    for file: server.files {
        if !runtime_support_file && contains(file.path, "Runtime_Support.jai") {
            runtime_support_file = file;
        }

        if !preload_file && contains(file.path, "Preload.jai") {
            preload_file = file;
        }
    }

    for file: server.files_to_be_analyzed {
        linked_files := get_file_links(file,, pool_alloc(*file.analysis_pool));

        if file != preload_file && preload_file {
            array_add(*linked_files, .{ file=preload_file, from_import=true });
        }

        if file != runtime_support_file && runtime_support_file {
            array_add(*linked_files, .{ file=runtime_support_file, from_import=true });
        }

        file.linked_files = linked_files;
    }

    // for file: server.files_to_be_analyzed {
    //     resolve_identifiers(file, global_only=true,, pool_alloc(*file.analysis_pool));
    // }

    array_reset(*server.files_to_be_analyzed);
}

Node_Visit_Data :: struct {
    file: *Program_File;
    allocator: Allocator;
    path_without_filename: string;
}

node_visit :: (node: *Node, data: Node_Visit_Data) {
    if !node return;

    push_allocator(data.allocator);

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
        _import := cast(*Directive_Import) node;

        path := get_module_import_path(_import, data.path_without_filename);

        module_import: Module_Import;
        module_import.root = path;
        module_import.module = _import.module;

        if !_import.parent || _import.parent.kind != .DECLARATION {
            array_add(*data.file.imports, module_import);
        }

        parse_file(path); // @TODO: Run this in another thread?
    }

    if node.kind == .DIRECTIVE_LOAD {
        _load := cast(*Directive_Load) node;

        load_relative_path := join(data.path_without_filename, _load.file, separator="/");
        array_add(*data.file.loads, _load);
        parse_file(load_relative_path); // @TODO: Run this in another thread?
    }
}

get_module_import_path :: (_import: *Directive_Import, current_path: string) -> string {

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
            if is_absolute_path(local_modules_folder) {
                absolute_path = local_modules_folder;
            } else {
                absolute_path = join(server.project_root, local_modules_folder, separator="/");
            }

            absolute_path = normalize_path(absolute_path);

            entry := get_module_entry(join(absolute_path, module_name, separator="/"));
            if entry.count > 0 return entry;
        }

        jai_modules := join(server.args.jai_path, "/modules");

        entry := get_module_entry(join(jai_modules, module_name, separator="/"));
        if entry.count > 0 return entry;

        return "";
    }

    path: string;

    if _import.import_kind == {
        case .MODULE;
            path = get_module(_import.module);
            if path.count == 0 return "";
        case .FILE;
            path = sprint("%/%", current_path, _import.module);
        case .DIR;
            relative_path := sprint("%/%", current_path, _import.module);
            path = get_module_entry(relative_path);
            if path.count == 0 return "";
        case .STRING;
            return "";
            // @TODO: Do we wanna parse the string here?
    }

    return path;
}

// resolve_identifiers :: (file: *Program_File) {
//     for node: file.nodes {
//         if node.kind != .IDENTIFIER {
//             continue;
//         }

//         ident := cast(*Identifier) node;

//         // log("Resolving '%' ident at %:%:%", ident.name, ident.location.file, ident.location.l0, ident.location.c0);

//         // log("Ident: %", ident.name);
//         block := get_node_nearest_block(ident);
//         decls := get_declarations(file, block, *ident.location, ident.name);
//         if decls.count == 0 {
//             // array_add(*file.unresolved_identifiers, ident);
//             continue;
//         }

//         table_add(*file.resolved_identifiers, ident, decls);
//     }
// }

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

get_file_links :: (file: *Program_File) -> [..]Linked_File {
    linked_files: [..]Linked_File;

    files_that_load_this_file := get_files_that_load(file);
    defer array_free(files_that_load_this_file);

    for server.files {
        // This ensure we take into account only files that are being loaded or imported...
        from_import: bool;

        if file.path != it.path {
            is_avaiable_from_one_of_the_parents: bool;

            for file_that_load_this_file: files_that_load_this_file {
                already_checked: [..]string;
                defer array_free(already_checked);

                if file_that_load_this_file.path == it.path {
                    is_avaiable_from_one_of_the_parents = true;
                    break;
                }

                avaiable, from_import= := is_avaiable_from(file_that_load_this_file, it.path, *already_checked);
                if !avaiable continue;

                is_avaiable_from_one_of_the_parents = true;
                break;
            }

            already_checked: [..]string;
            defer array_free(already_checked);

            if !is_avaiable_from_one_of_the_parents {
                avaiable, from_import= := is_avaiable_from(file, it.path, *already_checked);
                if !avaiable continue;
            }
        }

        array_add(*linked_files, .{ file=it, from_import=from_import });
    }

    return linked_files;
}

should_add_decl :: (linked_file: Linked_File, file: *Program_File, from_block: *Block, from_loc: *Node.Location, decl: *Declaration) -> bool {
    decl_block := get_node_nearest_block(decl);
    global := is_global(decl, file, linked_file.file, linked_file.from_import);

    if !global {
        if !from_block || !decl_block return false;

        if decl.const {
            if !is_child_of_block(decl_block, from_block, true) return false;
        } else {
            if !is_child_of_block(decl_block, from_block) return false;
            if from_loc && from_loc.l0 < decl.location.l0 return false;
        }
    }

    return true;
}

get_declarations_from_parent :: (decls: *[..]*Declaration, from_block: *Block, name := "") {
    parent_type := get_node_nearest_parent(from_block, kind => kind == .PROCEDURE || kind == .STRUCT || kind == .UNION || kind == .FOR);
    if !parent_type return;

    if parent_type.kind == {

        case .PROCEDURE;
            proc := cast(*Procedure) parent_type;

            for arg: proc.arguments {
                if arg.kind != .DECLARATION continue;
                decl := cast(*Declaration) arg;

                if name.count == 0 || decl.name == name array_add(decls, decl);
            }

        case .STRUCT;
            _struct := cast(*Struct) parent_type;

            for arg: _struct.polymorphic_arguments {
                if arg.kind != .DECLARATION continue;
                decl := cast(*Declaration) arg;

                if name.count == 0 || decl.name == name array_add(decls, decl);
            }

        case .UNION;
            _union := cast(*Union) parent_type;

            for arg: _union.polymorphic_arguments {
                if arg.kind != .DECLARATION continue;
                decl := cast(*Declaration) arg;

                if name.count == 0 || decl.name == name array_add(decls, decl);
            }

        case .FOR;
            _for := cast(*For) parent_type;

            iterator_type := get_node_type(_for.iterator, false);
            if !iterator_type {
                return;
            }

            element_type: *Node;

            if iterator_type.kind == {
                case .ARRAY_TYPE;
                    array_type := cast(*Array_Type) iterator_type;
                    if !array_type.element_type {
                        return;
                    }

                    element_type = array_type.element_type;

                case .LITERAL;
                    literal := cast(*Literal) iterator_type;
                    if literal.value_type != .ARRAY {
                        return;
                    }

                    element_type = literal.array_literal_info.element_type;
            }

            if !element_type {
                element_type = *unknown_identifier_node;
            }

            it_declaration := New(Declaration);
            it_declaration.name = "it";
            it_declaration.location = _for.iterator.location;

            if _for.value && _for.value.kind == .IDENTIFIER {
                value_identifier := cast(*Identifier) _for.value;
                it_declaration.name = value_identifier.name;
                it_declaration.location = value_identifier.location;
            }

            it_index_decl := New(Declaration);
            it_index_decl.name = "it_index";
            it_index_decl.location = _for.iterator.location;
            it_index_decl.type_inst = *s64_node;

            if _for.index && _for.index.kind == .IDENTIFIER {
                index_identifier := cast(*Identifier) _for.index;
                it_index_decl.name = index_identifier.name;
                it_index_decl.location = index_identifier.location;
            }

            if _for.by_pointer {
                pointer_wrapper := New(Unary_Operation);
                pointer_wrapper.operation = .POINTER;
                pointer_wrapper.expression = element_type;
                it_declaration.type_inst = pointer_wrapper;
            } else {
                it_declaration.type_inst = element_type;
            }

            if name.count == 0 || it_declaration.name == name array_add(decls, it_declaration);
            if name.count == 0 || it_index_decl.name == name array_add(decls, it_index_decl);
    }
}

get_declarations :: (file: *Program_File, from_block: *Block = null, from_loc: *Node.Location = null, name := "", only_loaded := false) -> []*Declaration {
    decls: [..]*Declaration;

    if from_block {
        get_declarations_from_parent(*decls, from_block, name);
    }

    for linked_file: file.linked_files {

        if only_loaded && linked_file.from_import {
            continue;
        }

        if name.count > 0 {
            for decl: table_find_multiple(*linked_file.file.declarations, name) {
                if should_add_decl(linked_file, file, from_block, from_loc, decl) array_add(*decls, decl);
            }
        } else {
            for decl: linked_file.file.declarations {
                if should_add_decl(linked_file, file, from_block, from_loc, decl) array_add(*decls, decl);
            }
        }

    }

    return decls;
}

get_node_nearest_parent :: (node: *Node, predicate: (Node.Kind) -> bool, limit := 15) -> *Node {
    current: *Node = node;
    i: int;

    while true {
        if predicate(current.kind) return current;

        if i >= limit break;
        i += 1;
        if !current.parent break;

        current = current.parent;
    }

    return null;
}

is_parent_of :: (parent: *Node, node: *Node, limit := 5) -> bool {
    if parent == node return true;

    current: *Node = node;
    i: int;

    while true {
        if current == parent return true;

        if i >= limit break;
        i += 1;
        if !current.parent break;

        current = current.parent;
    }

    return false;
}

is_global :: (node: *Node, from_file: *Program_File, it_file: *Program_File, from_import: bool) -> bool {
    if !node.parent return true;

    if node.parent.kind == .BLOCK {
        return is_global(node.parent, from_file, it_file, from_import);
    }

    // @TODO: Make this more robust!
    if node.parent.kind == .IF {
        _if := cast(*If) node.parent;
        if !_if.compile_time return false;
        return is_global(_if, from_file, it_file, from_import);
    }

    if node.parent.kind == .DIRECTIVE_SCOPE {
        directive_scope := cast(*Directive_Scope) node.parent;

        if directive_scope.scope_kind == .MODULE && !from_import return true;
        if directive_scope.scope_kind == .EXPORT return true;
        if directive_scope.scope_kind == .FILE && from_file == it_file return true;
    }

    return false;
}

get_files_that_are_avaiable_from :: (target_file: *Program_File) -> []*Program_File {
    files: [..]*Program_File;

    for file: server.files {
        already_checked: [..]string;
        defer array_free(already_checked);
        if !is_avaiable_from(file, target_file.path, *already_checked) continue;
        array_add(*files, file);
    }

    return files;
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

is_avaiable_from :: (file: *Program_File, path: string, already_checked: *[..]string, $loads_only := false) -> bool, bool {
    from_import: bool;
    loaded: bool;

    #if !loads_only {
        for file.imports {
            if array_find(already_checked.*, it.root) continue;
            array_add(already_checked, it.root);

            if it.root == path {
                from_import = true;
                loaded = true;
                break;
            }

            next_file := get_file(it.root);
            if next_file && is_avaiable_from(next_file, path, already_checked, true) {
                from_import = true;
                loaded = true;
                break;
            }

        }
    }

    for file.loads {
        load_path := trim_right(path_strip_filename(file.path), "/");
        load_relative_path := join(load_path, "/", it.file);
        // @TODO: free load_relative_path
        // defer free(load_relative_path);

        if array_find(already_checked.*, load_relative_path) continue;
        array_add(already_checked, load_relative_path);

        if load_relative_path == path {
            loaded = true;
            break;
        }

        next_file := get_file(load_relative_path);
        if next_file && is_avaiable_from(next_file, path, already_checked, loads_only) {
            loaded = true;
            break;
        }
    }

    return loaded, from_import;
}

get_node_nearest_block :: (node: *Node) -> *Block {
    current_node := node;

    while current_node.parent {
        current_node = current_node.parent;
        if current_node.kind == .BLOCK {
            return cast(*Block) current_node;
        }
    }

    return null;
}

is_child_of_block :: (block: *Block, node: *Node, ignore_scoping := false) -> bool {
    if !block || !node return false;

    current_node := node;

    if current_node == block return true;

    while current_node.parent {
        current_node = current_node.parent;

        if !ignore_scoping && current_node.kind != .BLOCK && current_node.kind != .IF && current_node.kind != .CASE && current_node.kind != .FOR && current_node.kind != .WHILE {
            return false;
        }

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

is_after :: (a: Node.Location, b: Node.Location) -> bool {
    if b.l0 > a.l1 return true;
    if b.c0 > a.c1 return true;
    return false;
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

get_identifier_decl :: (ident: *Identifier) -> []*Declaration {
    // log("Resolving '%' ident at %:%:%", ident.name, ident.location.file, ident.location.l0, ident.location.c0);

    file := get_file(ident.location.file);

    // log("Ident: %", ident.name);
    block := get_node_nearest_block(ident);
    decls := get_declarations(file, block, *ident.location, ident.name);
    if decls.count == 0 {
        // array_add(*file.unresolved_identifiers, ident);
        return .[];
    }

    // for file: server.files {
    //     decls, ok := table_find(*file.resolved_identifiers, ident);
    //     if !ok continue;
    //     return decls;
    // }

    return decls;
}

get_node_type :: (root: *Node, solve_array := false) -> *Node {
    current_node: *Node = root;

    while true {
        if !current_node break;

        // log("Resolving type: % (%:%:%)", current_node.kind, current_node.location.file, current_node.location.l0, current_node.location.c0);

        if current_node.kind == .IDENTIFIER {
            ident := cast(*Identifier, current_node);
            ident_decls := get_identifier_decl(ident);

            if ident_decls.count == 0 {
                // log("Does not find anything for '%'...", ident.name);
                return current_node;
            }

            current_node = ident_decls[0];
            continue;
        }

        if current_node.kind == .STRUCT {
            return current_node;
        }

        if current_node.kind == .UNION {
            return current_node;
        }

        if current_node.kind == .ENUM {
            return current_node;
        }

        if current_node.kind == .DIRECTIVE_IMPORT {
            return current_node;
        }

        if current_node.kind == .ARRAY_TYPE {
            array_type := cast(*Array_Type, current_node);

            if solve_array {
                current_node = array_type.element_type;
                continue;
            } else {
                return array_type;
            }
        }

        if current_node.kind == .LITERAL {
            literal := cast(*Literal) current_node;

            if literal.value_type == {
                case .STRUCT;
                    struct_literal_info := literal.values.struct_literal_info;
                    if struct_literal_info.type {
                        current_node = struct_literal_info.type;
                        continue;
                    }

                case .ARRAY;
                    array_literal_info := literal.values.array_literal_info;

                    if solve_array && array_literal_info.element_type {
                        current_node = array_literal_info.element_type;
                        continue;
                    } else {
                        return current_node;
                    }

                case;
                    return current_node;
            }
        }

        if current_node.kind == .DECLARATION {
            decl := cast(*Declaration) current_node;

            if decl.type_inst {
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
            path := get_dot_path(cast(*Binary_Operation) current_node, null);
            current_node = get_path_type(path);
            continue;
        }

        if current_node.kind == .PROCEDURE_CALL {
            proc_call := cast(*Procedure_Call) current_node;
            current_node = proc_call.procedure;
            continue;
        }

        if current_node.kind == .PROCEDURE {
            proc := cast(*Procedure) current_node;

            if proc.returns.count > 0 {
                current_node = proc.returns[0].expression;
                continue;
            } else {
                continue;
            }
        }

        if current_node.kind == .UNARY_OPERATION {
            unary_op := cast(*Unary_Operation) current_node;
            if unary_op.operation == .POINTER {
                current_node = unwrap_pointer(xx current_node);
                continue;
            }

            break;
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
    if parent.kind == .DIRECTIVE_IMPORT {
        import := cast(*Directive_Import) parent;

        module_file_path := get_module_import_path(import, parent.location.file);
        module_file := get_file(module_file_path);

        if !module_file {
            return null;
        }

        decls := get_declarations(module_file, only_loaded=true, name=ident.name);
        if decls.count == 0 {
            return null;
        }

        return decls[0];
    }

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

get_block_member_type :: (block: *Block, ident: *Identifier, solve_array := false) -> *Node {
    decl := get_block_member(block, ident);
    if !decl return null;
    return get_node_type(decl, solve_array);
}

get_block_member :: (block: *Block, ident: *Identifier) -> *Declaration {
    for member: block.members {
        if member.kind == {
            case .IDENTIFIER;
                _ident := cast(*Identifier) member;
                if _ident.name == ident.name {
                    decl := New(Declaration); // @MEMORY: We should free this or it is temp?
                    decl.name = _ident.name;
                    decl.expression = *empty_identifier;
                    decl.location = _ident.location;
                    decl.const = true;

                    return decl;
                }
            case .DECLARATION;
                decl := cast(*Declaration) member;
                if decl.name == ident.name return xx member;

            case .DIRECTIVE_AS; #through;
            case .USING;
                used_expression := get_used_expression(member);
                if !used_expression || used_expression.kind != .DECLARATION && used_expression.kind != .IDENTIFIER {
                    continue;
                }

                used_type := get_node_type(used_expression);
                if used_type {
                    decl := get_member_in(used_type, ident);
                    if decl && decl.name == ident.name {
                        return decl;
                    }
                }

                if used_expression.kind == .DECLARATION {
                    used_decl := cast(*Declaration) used_expression;
                    if used_decl.name == ident.name {
                        return used_decl;
                    }
                }
        }
    }

    return null;
}

unwrap_as :: (node: *Node) -> *Node {
    if !node return null;

    if node.kind == .DIRECTIVE_AS {
        directive_as := cast(*Directive_As) node;

        if directive_as.expression && directive_as.expression.kind == .DIRECTIVE_AS {
            return unwrap_as(directive_as.expression);
        }

        return directive_as.expression;
    }

    return node;
}

// get type of `using`
get_used_expression :: (node: *Node) -> *Node {
    unwrapped_node := unwrap_as(node);

    if !unwrapped_node || unwrapped_node.kind != .USING return null;

    _using := cast(*Using) unwrapped_node;
    return unwrap_as(_using.expression);
}

get_used_type :: (node: *Node) -> *Node {
    used_expression := get_used_expression(node);
    if !used_expression return null;

    if used_expression.kind != .IDENTIFIER && used_expression.kind != .DECLARATION {
        return null;
    }

    return get_node_type(used_expression);
}

// Can return null as last node!
get_dot_path :: (root_binary_op: *Binary_Operation, from: *Node) -> []*Node {
    path: [..]*Node;

    if root_binary_op.operation != .DOT {
        return path;
    }

    if !from {
        // Append even null nodes so we know we have empty "." entry (monster.items[0].)
        array_add(*path, root_binary_op.right);
        array_add(*path, root_binary_op.left);
    } else {
        if root_binary_op.right == from {
            array_add(*path, root_binary_op.right);
            array_add(*path, root_binary_op.left); // this cannot be null?
        } else if root_binary_op.left == from {
            array_add(*path, root_binary_op.left);
        } else {
            assert(false, "left nor right is from"); // is this correct? Should we assert?
        }
    }

    current_op: *Binary_Operation = root_binary_op;
    while current_op.parent && current_op.parent.kind == .BINARY_OPERATION {
        current_op = cast(*Binary_Operation, current_op.parent);

        if current_op.operation != .DOT {
            break;
        }

        if current_op.left array_add(*path, current_op.left);
    }

    // @TODO: Can we reverse without making new array? This seems dumb!
    reversed_path: [..]*Node;
    index: int;
    for < node: path {
        if node && node.kind != .IDENTIFIER && node.kind != .ARRAY_SUBSCRIPT && node.kind != .PROCEDURE_CALL {
            return reversed_path;
        }

        array_add(*reversed_path, node);
    }

    return reversed_path;
}

get_path_type :: (path: []*Node) -> *Node {
    current_type: *Node;
    resolved_nodes: int;

    for node: path {
        if !node break;

        if node.kind == {
            case .PROCEDURE_CALL; #through;
            case .ARRAY_SUBSCRIPT; #through;
            case .IDENTIFIER;
                identifier: *Identifier;
                solve_array: bool;

                if node.kind == .IDENTIFIER {
                    identifier = cast(*Identifier) node;
                } else if node.kind == .ARRAY_SUBSCRIPT {
                    array_subscript := cast(*Array_Subscript, node);
                    if !array_subscript.expression || array_subscript.expression.kind != .IDENTIFIER {
                        return null;
                    }

                    identifier = cast(*Identifier) array_subscript.expression;
                    solve_array = true;
                } else if node.kind == .PROCEDURE_CALL {
                    proc_call := cast(*Procedure_Call) node;
                    if !proc_call.procedure || proc_call.procedure.kind != .IDENTIFIER {
                        return null;
                    }

                    identifier = cast(*Identifier) proc_call.procedure;
                }

                if !current_type {
                    current_type = get_node_type(identifier, solve_array);
                    if !current_type {
                        break;
                    }
                    resolved_nodes += 1;
                    continue;
                }

                if current_type.kind == .DIRECTIVE_IMPORT {
                    decl := get_member_in(current_type, identifier);
                    if !decl {
                        break;
                    }

                    current_type = get_node_type(decl, solve_array);
                    resolved_nodes += 1;
                    continue;
                }

                if current_type.kind == .STRUCT {
                    _struct := cast(*Struct, current_type);
                    if !_struct.block {
                        break;
                    }

                    type := get_block_member_type(_struct.block, identifier, solve_array);
                    if !type {
                        // log_error("Failed to get member type for %", identifier.name);
                        break;
                    }

                    current_type = type;
                    resolved_nodes += 1;
                    continue;
                }

            case .LITERAL;
                current_type = node;
                resolved_nodes += 1;

            case; // abort!
                return null;
        }
    }

    // We are unable to resolve whole path so the final type would be invalid.
    if path.count-1 > resolved_nodes  {
        return null;
    }

    return current_type;
}