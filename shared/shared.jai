#import "Hash_Table";

IPC_CHANNEL_NAME_FROM_META :: "jls_channel_from_meta";
IPC_CHANNEL_NAME_TO_META   :: "jls_channel_to_meta";

CHANNEL_DATA_BYTES :: 64 * 1024 * 1024; // 64 MB @ToDo: what if we run out of space?
HEADER_SIZE :: 2;  // 1 byte for message-or-done, 1 byte for the checksum.

Protocol_Tag :: enum u8 {  // Is there a message here, or are we done?
    // UNINITIALIZED :: 0;
    DONE                :: 0;

    MESSAGE_START;

    INITIALIZATION;
    MODULE_IMPORT;
    FILE;

    BLOCK;
    ENUM;
    STRUCT;
    PROCEDURE;
    TYPE_INSTANTIATION;
    EXPRESSION;
    IF_STATEMENT;
    FOR_STATEMENT;
    WHILE_STATEMENT;
    TYPE_ARRAY;

    MESSAGE_END;
}

Server_To_Metaprogram_Protocol_Tag :: enum u8 {
    DONE          :: 0;
    MODIFIED_FILE :: 1;
}

Modified_File :: struct {
    path:    string;
    content: [] u8;
}


ID :: s64;

Our_Declaration_Flags :: enum_flags u32 {
    IS_IMPORTED;
    SCOPE_FILE;
    IS_GLOBAL;
};

Source_File :: struct {
    path: string;
    project: bool;
}

Module :: struct {
    name: string;
    path: string;
}

Initialization :: struct {
    import_path: []string;
}

// Struktury
Declaration :: struct {
    Location :: struct {
        file: string;
        l0, c0, l1, c1: s32;
    }

    flags: Our_Declaration_Flags;

    kind: Protocol_Tag;
    name: string;
    serial: ID;
    location: Location;
}


Base_Type :: enum {
    UNINITIALIZED;
    ANY;
    STRING;
    BOOL;
    FLOAT64;
    FLOAT32;
    S64;
    S32;
    S16;
    S8;
    U64;
    U32;
    U16;
    U8;
}

Type_Array :: struct {
    #as using base: Declaration;
    base.kind = .TYPE_ARRAY;

    type_inst: ID;
    size := -1;

    type: enum u8 {
        RESIZABLE;
        STATIC;
        ARRAY_VIEW;
    }
}

// {}
Block :: struct {
    #as using base: Declaration;
    base.kind = .BLOCK;

    declarations: []ID;
    members: []ID;
}

// main :: () {}
Procedure :: struct {
    #as using base: Declaration;
    base.kind = .PROCEDURE;

    arguments: []ID;
    returns: []ID;
    body: ID;
}

// @ToDo: this is probably dumb... We could do this better.
Base_Type_Or_Serial_To :: struct {
    type_kind: enum {
        BASE;
        SERIAL;
        POINTER;
        ARRAY;
    }

    base_type: Base_Type;
    serial_to: ID; // age: Person;
}

// age: int;
Type_Instantiation :: struct {
    #as using base: Declaration;
    base.kind = .TYPE_INSTANTIATION;

    using type: Base_Type_Or_Serial_To;
}

// age := 10;
Expression :: struct {
    #as using base: Declaration;
    base.kind = .EXPRESSION;

    using type: Base_Type_Or_Serial_To;
}

// Person :: { name: string; age: int };
Struct :: struct {
    #as using base: Declaration;
    base.kind = .STRUCT;

    arguments: ID = 0;
    block: ID = 0;
}

// Gender :: enum { MALE; FEMALE; };
Enum :: struct {
    #as using base: Declaration;
    base.kind = .ENUM;

    type: Base_Type;
    block: ID;
}

// while x < 7 {}
While_statement :: struct {
    #as using base: Declaration;
    base.kind = .WHILE_STATEMENT;

    condition: ID = 0;
    block: ID;
}

// for 1..7 {}
For_Statement :: struct {
    #as using base: Declaration;
    base.kind = .FOR_STATEMENT;

    iterator: ID = 0;
    block: ID;
}

// if true then ... else ...
If_Statement :: struct {
    #as using base: Declaration;
    base.kind = .IF_STATEMENT;

    then_blocks: []ID;
    else_block: ID = 0;
    is_directive_static := false;
}

decode_command :: (message: Read_Message, $T: Type) -> bool, T, [] u8 {
    command := cast(T) message.user_read_pointer[0];

    valid_messages := type_info(T).values;
    if !array_find(valid_messages, cast(s64) command) {
        log_error("Got an invalid command on a data message: %", command);
        return false, command, .[];
    }

    stored_checksum := message.user_read_pointer[1];

    data_bytes := message.user_read_bytes - HEADER_SIZE;

    my_checksum: u8;
    for 0..data_bytes-1 {
        my_checksum ^= message.user_read_pointer[it + HEADER_SIZE];
    }

    if my_checksum != stored_checksum {
        log_error("Checksum mismatch in message %: Wanted %, got %. Quitting.\n", command, stored_checksum, my_checksum);
        return false, command, .[];
    }

    body_bytes: [] u8 = ---;
    body_bytes.data = message.user_read_pointer + HEADER_SIZE;
    body_bytes.count = message.user_read_bytes - HEADER_SIZE;

    return true, command, body_bytes;
}

// OLD --------

// Procedure_Call :: struct {
//     #as using base: Node;
//     base.kind = .PROCEDURE_CALL;

//     arguments: []Node;
// }

// Indent :: struct {
//     #as using base: Node;
//     base.kind = .INDENT;

//     serial_to: s64;
// }

// Literal :: struct {
//     #as using base: Node;
//     base.kind = .LITERAL;

//     value_type: type_of(Code_Literal.value_type);
// }

// Declaration :: struct {
//     #as using base: Node;
//     base.kind = .DECLARATION;

//     type_inst: *Node;  // In     name : A = B;     this is A.
//     expression: *Node; // In     name : A = B;     this is B.
// }

// file, line, column;

// lines := find_in_table(*project.nodes_by_location, file);

// for node: lines[line] {
//     if node.location.c0 >= column && node.location.c1 <= column {

//     }
// }
