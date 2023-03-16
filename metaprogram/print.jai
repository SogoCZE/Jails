/*
    name :: expression;
    name: type_inst = expression;
*/

print_with_tabs :: (prefix_tabs: int, format: string, args: ..Any) {
    for 1..prefix_tabs print("  ");
    print(format, ..args);
}

process_code_block_print :: (block: *Code_Block, nest_level: int) {
    // for member: block.members {
    //     if member.kind != .DECLARATION continue;
    //     deep_print_decl(xx member, nest_level+1);
    // }

    for statement: block.statements {
        if statement.kind == .DECLARATION {
            deep_print_decl(xx statement, nest_level);
            continue;
        }

        print_with_tabs(nest_level, "statement %\n", statement.kind);
    }
}

deep_print_decl :: (decl: *Code_Declaration, nest_level := 0) {
    if decl.expression == null && decl.type_inst == null return; // Toto by se nemělo stát!

    if decl.expression == null {
        print_with_tabs(nest_level, "%: %\n", decl.name, type_to_string(decl.type_inst.result));
        return;
    }

    file_loc := tprint("%:%,% (%,%)", decl.location.enclosing_load.fully_pathed_filename, decl.location.l0, decl.location.c0, decl.location.l1, decl.location.c1);

    if decl.expression.kind == {
        case .STRUCT;
            _struct := cast(*Code_Struct) decl.expression;
            print_with_tabs(nest_level, "% :: struct (%) {\n", decl.name, file_loc);
            process_code_block_print(_struct.block, nest_level+1);
            print_with_tabs(nest_level, "}\n"); 

        case .ENUM;
            _enum := cast(*Code_Enum) decl.expression;
            print_with_tabs(nest_level, "% :: enum {\n", decl.name);
            process_code_block_print(_enum.block, nest_level+1);
            print_with_tabs(nest_level, "}\n"); 

        case .PROCEDURE_HEADER;
            // Toto musíme jet přes PROCEDURE_BODY protože zde se stává, že header ješte nemá body.

        case .LITERAL;
            literal := cast(*Code_Literal) decl.expression;

            if decl.flags & .IS_CONSTANT {
                print_with_tabs(nest_level, "% :: %\n", decl.name, enum_value_to_name(literal.value_type));
                return;
            } 

            print_with_tabs(nest_level, "% := %\n", decl.name, enum_value_to_name(literal.value_type));

        case;
            print_with_tabs(nest_level, "% :: Unknown %\n", decl.name, decl.expression.kind);
    }

}

print_typechecked :: (tc: *Message_Typechecked) {
    for body: tc.procedure_bodies {
        filename := get_filename(body.expression);
        if !contains(filename, FOR_FILE) continue;

        proc_header := body.expression.header;  

        print_with_tabs(0, "% :: (", proc_header.name);

        for argument: proc_header.arguments {
            deep_print_decl(argument);
        }

        print(") ");

        if proc_header.returns.count > 0 {
            print("-> ");

            for _return: proc_header.returns {
                deep_print_decl(_return);
            }   
        }

        print("{\n");

        process_code_block_print(body.expression.block, 1);
        print_with_tabs(0, "}\n"); 
    }

    for tc.all {
        if it.expression.kind != .DECLARATION continue;

        decl := cast(*Code_Declaration) it.expression;

        filename := get_filename(decl);

        if !contains(filename, FOR_FILE) continue; // Aby to bralo věci jen z mainu pro zatím..

        // if decl.node_flags & .CREATED_BY_DESUGARING  continue; // co to je?

        deep_print_decl(decl);
    }
}