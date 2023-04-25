#program_export
library_init :: (p: *Jails_Plugin, import_path: [] string) #c_call {
    ctx: Context;
    push_context ctx {
        set_allocators(*p.pool);
        push_allocator(pool_allocator_proc, *p.pool);
        init(p, import_path);
    }
}

#program_export
library_deinit :: (p: *Jails_Plugin) #c_call {
    ctx: Context;
    push_context ctx {
        {
            push_allocator(pool_allocator_proc, *p.pool);
            deinit(p);
        }
        release(*p.pool);
    }
}


#program_export
library_handle_message :: (p: *Jails_Plugin, message: *Message) #c_call {
    ctx: Context;
    push_context ctx {
        push_allocator(pool_allocator_proc, *p.pool);
        handle_message(p, message);
    }
}

init :: (p: *Jails_Plugin, import_path: [] string) {
    init(*p.declarations_by_type_info_struct);
    init(*p.procedure_header_to_declaration);

    send_to_server(p, .INITIALIZATION, *Initialization.{
        import_path=import_path
    });

    // Read all (modified) files from the server
    // p.modified_files = receive_modified_files(p);
    // log("Received % modified files", p.modified_files.count);
}

deinit :: (p: *Jails_Plugin) {
    deinit(*p.declarations_by_type_info_struct);
    deinit(*p.procedure_header_to_declaration);
}

receive_modified_files :: (p: *Jails_Plugin) -> [] Modified_File {
    files: [..] Modified_File;
    received_all_files := false;
    while !received_all_files {
        message_success, fatal_error, message := reader_poll_for_message(*p.read_channel);
        if fatal_error {
            log_error("Fatal error");
            exit(1);
        }

        if !message_success {
            sleep_milliseconds(1);
            continue;
        }

        defer reader_done_with_message(*message);

        success, workspace_index, command, body_bytes := decode_mesage_header(message, Server_To_Metaprogram_Protocol_Tag);
        if !success exit(1);

        {
            push_allocator(pool_allocator_proc, *p.pool);

            if command == {
                case .MODIFIED_FILE;
                    body_copy := array_copy(body_bytes);
                    file := deserialize(body_copy, Modified_File);
                    log("Got file %. Pretending to use this for something…", file.path);
                    array_add(*files, file);
                case .DONE;
                    received_all_files = true;
            }
        }
    }

    return files;
}

compiler_location_to_our_location :: (using location: Code_Node.Location) -> Declaration.Location {
    filename: string;
    if enclosing_load filename = enclosing_load.fully_pathed_filename;

    // DANGER!
    return .{
        filename,
        l0,
        c0,
        l1,
        c1
    };
}

map_to_declaration :: (p: *Jails_Plugin, code_declarations: []*Code_Declaration) -> []s64 {
    type_instantiations := NewArray(code_declarations.count, s64);

    for code_declarations type_instantiations[it_index] = process_declaration(p, it);

    return type_instantiations;
}

process_number :: (type: *Type_Info) -> Base_Type {
    if type.type == {
        case .INTEGER;
            info_integer := cast(*Type_Info_Integer) type;
            if info_integer.signed {
                if info_integer.runtime_size == {
                    case 8; return .S64;
                    case 4; return .S32;
                    case 2; return .S16;
                    case; return .S8;
                }
            } else {
                if info_integer.runtime_size == {
                    case 8; return .U64;
                    case 4; return .U32;
                    case 2; return .U16;
                    case; return .U8;
                }
            }
        case .FLOAT;
            if type.runtime_size == {
                case 8; return .FLOAT64;
                case; return .FLOAT32;
            }
        case; return .S64;
    }
}

process_type_instantiation :: (p: *Jails_Plugin, base: Declaration, code_type_inst: *Code_Type_Instantiation) -> ID {
    type_inst: Type_Instantiation;
    type_inst.base = base;
    type_inst.kind = .TYPE_INSTANTIATION;

    defer send_to_server(p, .TYPE_INSTANTIATION, *type_inst);

    // persons: []Person; | groups_of_persons: [][]Person;
    if code_type_inst.array_element_type {
        new_type_array: Type_Array;
        new_type_array.serial = code_type_inst.array_element_type.serial;

        type_inst.serial_to = new_type_array.serial;
        type_inst.type_kind = .ARRAY;

        if code_type_inst.inst_flags & .ARRAY_VIEW {
            new_type_array.type = .ARRAY_VIEW;
        } else if code_type_inst.inst_flags & .RESIZABLE {
            new_type_array.type = .RESIZABLE;
        } else {
            new_type_array.type = .STATIC;
            dimension := cast(*Code_Literal) code_type_inst.array_dimension;
            new_type_array.size = dimension._s64;

            #if DEBUG then print("array size = %\n", new_type_array.size);
        }

        new_type_array.type_inst = process_type_instantiation(p, *Declaration.{serial = code_type_inst.array_element_type.serial}, code_type_inst.array_element_type);

        send_to_server(p, .TYPE_ARRAY, *new_type_array);

        return type_inst.serial;
    }

    // Jirka: Person;
    if code_type_inst.type_valued_expression {
        if code_type_inst.type_valued_expression.kind == {
            case .IDENT;
                ident_expression := cast(*Code_Ident) code_type_inst.type_valued_expression;

                if ident_expression.resolved_declaration && ident_expression.resolved_declaration.expression && ident_expression.resolved_declaration.expression.location.enclosing_load {
                    type_inst.type_kind = .SERIAL;
                    type_inst.serial_to = ident_expression.resolved_declaration.serial;
                    #if DEBUG then print("type_inst.serial_to = %\n", type_inst.serial_to);
                    return type_inst.serial;
                }
            // Jirka: Person(true);
            case .PROCEDURE_CALL;
                procedure_call_expression := cast(*Code_Procedure_Call) code_type_inst.type_valued_expression;

                if procedure_call_expression.procedure_expression.kind == .IDENT {
                    ident_expression := cast(*Code_Ident) procedure_call_expression.procedure_expression;

                    struct_result := cast(*Type_Info_Struct) code_type_inst.result;

                    #if DEBUG then print("getting serial from struct by pointer %\n", struct_result);
                    // Getting struct-serial by it's defined_type pointer
                    decl, ok := table_find(*p.declarations_by_type_info_struct, struct_result);
                    if !ok {
                        #if DEBUG print("Pointer not found!\n");
                    } else {
                        type_inst.type_kind = .POINTER;
                        type_inst.serial_to = decl.serial;
                    }

                    #if DEBUG then print("type_inst.serial_to = % \n", type_inst.serial_to);
                    return type_inst.serial;
                }
        }
    }

    // age: *int;
    if code_type_inst.pointer_to {
        pointed_type_instantiation := process_type_instantiation(p, *Declaration.{serial = code_type_inst.pointer_to.serial}, code_type_inst.pointer_to);
        type_inst.type_kind = .POINTER;
        type_inst.serial_to = pointed_type_instantiation;
        #if DEBUG then print("type_inst.pointer_to = %\n", pointed_type_instantiation);

        return type_inst.serial;
    }

    //  age: int; | persons: []Person;
    if code_type_inst.result {
        type_inst.type_kind = .BASE;

        if code_type_inst.result.type == {
            case .INTEGER; #through;
            case .FLOAT;
                type_inst.base_type = process_number(code_type_inst.result);
            case .BOOL;
                type_inst.base_type = .BOOL;
            case .STRING;
                type_inst.base_type = .STRING;
        }
    }

    #if DEBUG then print("type_inst.type = %\n", type_inst.type);
    return type_inst.serial;
}

process_struct_declaration :: (p: *Jails_Plugin, declaration: Declaration, code_struct: *Code_Struct) -> ID {
    _struct: Struct;
    _struct.base = declaration;
    _struct.kind = .STRUCT;

    if code_struct.arguments_block {
        #if DEBUG then print("Setting struct to pointer %\n", code_struct.defined_type);
        // Setting serial of struct to defined_type pointer, so we can link afterwards
        // table_set(*declarations_by_type_info_struct, code_struct.defined_type, *_struct);

        _struct.arguments = process_code_block(p, code_struct.arguments_block, declaration.serial, true);
    }

    code_struct.block.serial = _struct.serial;
    _struct.block = process_code_block(p, code_struct.block, declaration.serial,);

    send_to_server(p, .STRUCT, *_struct);

    return _struct.serial;
}

process_declaration :: (p: *Jails_Plugin, decl: *Code_Declaration) -> ID {
    declaration: Declaration;
    declaration.name = decl.name;
    declaration.serial = decl.serial;

    declaration_flags: Our_Declaration_Flags;

    if decl.flags & .IS_GLOBAL   declaration_flags |= .IS_GLOBAL;
    if decl.flags & .SCOPE_FILE  declaration_flags |= .SCOPE_FILE;
    if decl.flags & .IS_IMPORTED declaration_flags |= .IS_IMPORTED;

    declaration.flags = declaration_flags;

    declaration.location = compiler_location_to_our_location(decl.location);

    #if DEBUG {
        print("declaration name =  %\n", declaration.name);
        print("declaration serial =  %\n", declaration.serial);
        print("declaration location =  %\n", declaration.location);
        print("declaration flags =  %\n", declaration.flags);
    }

    if decl.type_inst {
        return process_type_instantiation(p, declaration, decl.type_inst);
    }

    if decl.expression {
        #if DEBUG then print("decl.expression.kind = %\n", decl.expression.kind);

        if decl.expression.kind == {
            // main :: () {};
            case .PROCEDURE_HEADER;
                code_procedure_header := cast(*Code_Procedure_Header) decl.expression;

                _procedure: Procedure;
                _procedure.base = declaration;
                _procedure.kind = .PROCEDURE;
                _procedure.body = code_procedure_header.serial;
                _procedure.arguments = map_to_declaration(p, code_procedure_header.arguments);
                _procedure.returns = map_to_declaration(p, code_procedure_header.returns);

                table_set(*p.procedure_header_to_declaration, code_procedure_header.serial, declaration.serial);

                send_to_server(p, .PROCEDURE, *_procedure);

                return _procedure.serial;

            // Person :: struct { name: string; };
            case .STRUCT;
                return process_struct_declaration(p, declaration, xx decl.expression);

            // FOOD :: enum { APPLE :: 1; };
            case .ENUM;
                code_enum := cast(*Code_Enum) decl.expression;

                _enum: Enum;
                _enum.base = declaration;
                _enum.kind = .ENUM;

                // Can be null for polymorphic types (eg. an enum’s internal_type if the enum is declared inside a polymorphic struct)
                if code_enum.internal_type_inst {
                    _enum.type = process_number(code_enum.internal_type_inst.result);
                } else if code_enum.internal_type {
                    _enum.type = process_number(code_enum.internal_type);
                }

                code_enum.block.serial = _enum.serial;
                _enum.block = process_code_block(p, code_enum.block, declaration.serial);

                send_to_server(p, .ENUM, *_enum);

                return _enum.serial;

            // number := 10; | Jirka := Person.{ name = "Jirka" }; | name := "Jirka"; | numbers := int.[1, 3, 5, 7, 9];
            case .LITERAL;
                code_literal := cast(*Code_Literal) decl.expression;
                _expression: Expression;
                _expression.base = declaration;
                _expression.kind = .EXPRESSION;

                if code_literal.value_type == {
                    case .ARRAY;
                        code_type_inst := cast(*Code_Type_Instantiation) code_literal.array_literal_info.element_type;
                        array_element_type: Type_Array;
                        array_element_type.type = .STATIC;
                        array_element_type.size = code_literal.array_literal_info.array_members.count;
                        #if DEBUG then print("array size = %\n", array_element_type.size);

                        array_element_type.type_inst = process_type_instantiation(p, declaration, code_type_inst);

                        array_element_type.serial = code_literal.serial;

                        _expression.type_kind = .ARRAY;
                        _expression.serial_to = code_literal.serial;

                        send_to_server(p, .TYPE_ARRAY, *array_element_type);

                        #if DEBUG then print("_expression.array_element_type = %\n", _expression.array_element_type);
                    case .STRUCT;
                        code_type_inst := cast(*Code_Type_Instantiation) code_literal.struct_literal_info.type_expression;

                        if code_type_inst {
                            identExpression := cast(*Code_Ident) code_type_inst.type_valued_expression;

                            if identExpression.resolved_declaration {
                                _expression.type_kind = .SERIAL;
                                _expression.serial_to = identExpression.resolved_declaration.serial;
                            }
                        }

                        #if DEBUG then print("_expression.serial_to = % \n", _expression.serial_to);
                    case .STRING;
                        _expression.base_type = .STRING;
                        #if DEBUG then print("_expression.type = string\n");
                    case .NUMBER;
                        _expression.base_type = process_number(code_literal.type);
                        #if DEBUG then print("_expression.type = %\n", _expression.type);

                    case .TRUE; #through;
                    case .FALSE;
                        _expression.base_type = .BOOL;
                        #if DEBUG then print("_expression.type = bool\n");
                }

                send_to_server(p, .EXPRESSION, *_expression);

                return _expression.serial;

            // apple := FOOD.Apple;
            case .BINARY_OPERATOR;
                code_binary_operator := cast(*Code_Binary_Operator) decl.expression;

                _expression: Expression;
                _expression.base = declaration;
                _expression.kind = .EXPRESSION;

                if code_binary_operator.right.kind == .IDENT {
                    ident := cast(*Code_Ident) code_binary_operator.right;

                    if ident.resolved_declaration {
                        _expression.serial_to = ident.resolved_declaration.serial;
                        #if DEBUG then print("_expression.serial_to = %\n", _expression.serial_to);
                    } else {
                        // @todo -- .data anything else ?
                        if ident.name == "count" {
                            _expression.base_type = .U64;
                        }
                    }
                }

                send_to_server(p, .EXPRESSION, *_expression);

                return _expression.serial;

            // number := number2;
            case .IDENT;
                code_ident:= cast(*Code_Ident) decl.expression;

                _expression: Expression;
                _expression.base = declaration;
                _expression.kind = .EXPRESSION;

                if code_ident.resolved_declaration {
                    _expression.serial_to = code_ident.resolved_declaration.serial;
                    #if DEBUG then print("_expression.serial_to = %\n", _expression.serial_to);
                }

                send_to_server(p, .EXPRESSION, *_expression);

                return _expression.serial;

            case;
                _expression: Expression;
                _expression.base = declaration;
                _expression.kind = .EXPRESSION;

                send_to_server(p, .EXPRESSION, *_expression);
        }
    }

    return declaration.serial;
}

process_code_if :: (p: *Jails_Plugin, if_statement: *Code_If, is_directive_static := false) -> ID {
    our_if_statement: If_Statement;
    our_if_statement.serial = if_statement.serial;

    if if_statement.is_switch_statement {
        then_blocks := NewArray(if_statement.then_block.statements.count, s64);
        for statement: if_statement.then_block.statements {
            code_case := cast(*Code_Case) statement;
            then_blocks[it_index] = process_code_block(p, xx code_case.then_block, our_if_statement.serial);
        }

        our_if_statement.then_blocks = then_blocks;
    } else {
        then_blocks: [1]s64;
        then_blocks[0] = process_code_block(p, xx if_statement.then_block, our_if_statement.serial);
        our_if_statement.then_blocks = then_blocks;
    }

    if if_statement.else_block then our_if_statement.else_block = process_code_block(p, xx if_statement.else_block, our_if_statement.serial);

    if is_directive_static then our_if_statement.is_directive_static = true;

    return our_if_statement.serial;
}

process_code_while :: (p: *Jails_Plugin, while_statement: *Code_While) -> ID {
    our_while_statement: While_statement;
    our_while_statement.serial = while_statement.serial;

    our_while_statement.block = process_code_block(p, while_statement.block, our_while_statement.serial);

    if while_statement.condition.kind == .DECLARATION {
        our_while_statement.condition = process_declaration(p, xx while_statement.condition);
        #if DEBUG then print("our_while_statement.condition = %\n", our_while_statement.condition);
    }

    return our_while_statement.serial;
}

process_code_for :: (p: *Jails_Plugin, for_statement: *Code_For) -> ID {
    our_for_statement: For_Statement;
    our_for_statement.serial = for_statement.serial;

    our_for_statement.block = process_code_block(p, for_statement.block, our_for_statement.serial);

    if for_statement.ident_decl && for_statement.ident_decl.kind == .DECLARATION {
        iterator_declaration := cast(*Code_Declaration) for_statement.ident_decl;
        if iterator_declaration.name != "it" {
            our_for_statement.iterator = process_declaration(p, xx iterator_declaration);
            #if DEBUG then print("our_for_statement.iterator = %\n", our_for_statement.iterator);
        }
    }

    return our_for_statement.serial;
}

process_procedure_body :: (p: *Jails_Plugin, body: *Code_Procedure_Body) {
    body.block.serial = body.header.serial;

    procedure_decl_serial, ok := table_find(*p.procedure_header_to_declaration, body.header.serial);
    if !ok {
        // log_error("Cannot find procedure decl serial (%)", body.header.serial);
        return;
    }

    process_code_block(p, body.block, procedure_decl_serial);
}

process_code_block :: (p: *Jails_Plugin, block: *Code_Block, parent: ID, process_members := false) -> ID {
    our_block: Block;
    our_block.serial = block.serial;
    our_block.parent = parent;
    our_block.location = compiler_location_to_our_location(block.location);

    if block.statements {
        declarations_serials := NewArray(block.statements.count, s64);
        for statement: block.statements {
            #if DEBUG then print("statement.kind = %\n", statement.kind);

            if statement.kind == {
                case .DECLARATION;
                    code_declaration := cast(*Code_Declaration) statement;
                    if !code_declaration.expression || code_declaration.expression.kind != .PROCEDURE_HEADER {
                        declarations_serials[it_index] = process_declaration(p, xx statement);
                    } else {
                        declarations_serials[it_index] = statement.serial;
                    }

                case .BLOCK;
                    declarations_serials[it_index] = process_code_block(p, xx statement, block.serial);

                case .WHILE;
                    declarations_serials[it_index] = process_code_while(p, xx statement);

                case .FOR;
                    declarations_serials[it_index] = process_code_for(p, xx statement);

                case .DIRECTIVE_STATIC_IF;
                    declarations_serials[it_index] = process_code_if(p, xx statement, true);

                case .IF;
                    declarations_serials[it_index] = process_code_if(p, xx statement);
            }
        }

        our_block.declarations = declarations_serials;
    }

    if block.members && process_members {
        members_serials := NewArray(block.members.count, s64);
        for statement: block.members {
            if statement.kind == {
                case .DECLARATION; members_serials[it_index] = process_declaration(p, xx statement);
                case .BLOCK; members_serials[it_index] = process_code_block(p, xx statement, block.serial);
            }
        }

        our_block.members = members_serials;
    }

    send_to_server(p, .BLOCK, *our_block);

    return our_block.serial;
}

handle_message :: (p: *Jails_Plugin, message: *Message) {
    // Gathering of project files
    if message.kind == .FILE {
        file_message := cast(*Message_File) message;

        project := false;

        if file_message.enclosing_import && file_message.enclosing_import.module_type == .MAIN_PROGRAM {
            array_add(*p.files, file_message.fully_pathed_filename);
            project = true;
        }

        send_to_server(p, .FILE, *Source_File.{path=file_message.fully_pathed_filename, project=project});
    }

    if message.kind == .PHASE {
        phase_message := cast(*Message_Phase) message;
        if phase_message.phase != .TYPECHECKED_ALL_WE_CAN return;

        end := current_time_consensus();
        duration_ms := to_milliseconds(end - p.start);

        print("Done in %ms, TYPECHECKED_ALL_WE_CAN\n", duration_ms);

        return;
    }

    if message.kind == .COMPLETE return;
    if message.kind != .TYPECHECKED return;

    tc := cast(*Message_Typechecked) message;

    for tc.structs {
        if it.expression.serial == 0 continue;

        code_struct := cast(*Code_Struct) it.expression;

        // person_kind: Person(string);
        if code_struct.arguments_block && code_struct.defined_type && code_struct.defined_type.polymorph_source_struct {
            declaration: Declaration;
            declaration.name = code_struct.defined_type.name;
            declaration.serial = code_struct.serial;

            #if DEBUG then print("Getting location from struct by pointer %\n", code_struct.defined_type.polymorph_source_struct);
            // Getting struct-location by it's defined_type pointer
            decl, ok := table_find(*p.declarations_by_type_info_struct, code_struct.defined_type.polymorph_source_struct);
            if !ok {
                #if DEBUG then print("Pointer not found!\n");
            } else {
                declaration.location = decl.location;
            }

            #if DEBUG {
                print("declaration name =  %\n", declaration.name);
                print("declaration serial =  %\n", declaration.serial);
                print("declaration location =  %\n", declaration.location);
            }

            process_struct_declaration(p, declaration, code_struct);
        }
        #if DEBUG then print("\n");
    }

    for tc.procedure_headers {
        code_procedure_header := cast(*Code_Procedure_Header) it.expression;

        // if code_procedure_header.procedure_flags & .POLYMORPHIC {
        //     table_set(*p.procedure_header_to_declaration, code_procedure_header.serial, declaration.serial);
        // }

        if !code_procedure_header.polymorph_source_header continue; 
        // print("(%): polymorph_source_header: %\n", code_procedure_header.serial, code_procedure_header.polymorph_source_header);
    }

    for tc.all {
        // @note: compiler catching expression with serial 0 when
        // Person :: struct { name := "Jirka"; }


        if it.expression.serial == 0 continue;

        if it.expression.kind == {
            case .DECLARATION;
                process_declaration(p, xx it.expression);
            case .PROCEDURE_BODY;
                process_procedure_body(p, xx it.expression);
            case .DIRECTIVE_IMPORT;
                import := cast(*Code_Directive_Import) it.expression;

                if import.location.enclosing_load {

                    if array_find(p.files, import.location.enclosing_load.fully_pathed_filename) {
                        send_to_server(p, .MODULE_IMPORT, *Module.{ import.name, import.location.enclosing_load.fully_pathed_filename });
                    }

                }

        }
        #if DEBUG then print("\n");
    }
}

send_to_server :: (p: *Jails_Plugin, command: Protocol_Tag, data: *$T) {
    // assert(p.write_channel != null);

    data_bytes := serialize(data);

    while true {
        message_success, message := writer_reserve_message(*p.write_channel, JAILS_HEADER_SIZE + data_bytes.count);
        if !message_success {
            sleep_milliseconds(1);
            continue;
        }

        message.user_write_pointer[0] = p.jails_workspace;
        message.user_write_pointer[1] = cast(u8) command;
        #if ENABLE_CHECKSUM {
            checksum: u8;

            for byte, index: data_bytes {
                checksum ^= byte;
            }

            memcpy(*message.user_write_pointer[JAILS_HEADER_SIZE], data_bytes.data, data_bytes.count);
            message.user_write_pointer[1] = checksum;
        } else {
            memcpy(*message.user_write_pointer[JAILS_HEADER_SIZE], data_bytes.data, data_bytes.count);
        }

        writer_commit_message(*p.write_channel, message);
        break;
    }
}

#import "File";
#import "String";
#import "Reflection";
#import "System";

#load "../shared/binary_serialization.jai";
#load "../shared/shared.jai";
#load "shared.jai";
