// Tady je implementace od https://github.com/osor-io/osor_serialization.
// Moje původní verze nevyužívala Code Generation tolik a dělala nějaké věci runtime
// A zatím neřešila Array atd, nicméně ještě nevím jak je na tom performance u tohoto atd.
// Teoreticky obojí má něco do sebe, ale moje verze byla možná trochu více clear - možná se
// k ní časem vrátíme a dokončíme jí ale zatím bude bohatě stačit tato verze od cápka.

// Dole je moje testovací implementace.

// - Trochu mě štve, že to generuje kód jako string i když by mohlo přes #Code přímo jako AST.

#import "Basic";
#import "Hash_Table";
#import "Compiler";

serialize :: (input : *$T, allocator: Allocator = context.allocator) -> []u8 #must {
    ALIGNED_INPUT_SIZE :: #run align_for_serialization(size_of(T));

    dynamic_memory_required := cast(s64) handle_dynamic_memory(input, null, .COUNT);

    // print("dynamic_memory_required = %, ALIGNED_INPUT_SIZE = %\n", dynamic_memory_required, ALIGNED_INPUT_SIZE);

    buffer: []u8;
    buffer.count = ALIGNED_INPUT_SIZE + dynamic_memory_required;
    buffer.data  = alloc(buffer.count, allocator);
    memset(buffer.data, 0, buffer.count);

    dynamic_memory: []u8;
    dynamic_memory.count = dynamic_memory_required;
    dynamic_memory.data  = buffer.data + ALIGNED_INPUT_SIZE;

    output := cast(*T)buffer.data;
    memcpy(output, input, size_of(type_of(<<input)));

    dynamic_memory_pointer := handle_dynamic_memory(output, dynamic_memory.data, .COPY_AND_ENCODE);
    assert(dynamic_memory_pointer == dynamic_memory.data + dynamic_memory.count);

    return buffer;
}

deserialize :: (bytes: []u8, $Output_Type: Type) -> *Output_Type {
    info := type_info(Output_Type);
    result := cast(*Output_Type) bytes.data;
    inline decode_dynamic_memory(result);
    return result;
}

cleanup_for_serialization :: (element : *$T) {
    #if #run same_polymorph_source(T, Table(int, int)) {
        table := element;
        DEFAULT_VALUE :: table.Entry.{};

        for * table.entries {
            if it.hash > FIRST_VALID_HASH continue;
            memcpy(it, *DEFAULT_VALUE, size_of(type_of(DEFAULT_VALUE)));
        }
    }

    same_polymorph_source :: ($a : Type, $b : Type) -> bool {
        info_a := type_info(a);
        info_b := type_info(b);

        if info_a.polymorph_source_struct then info_a = info_a.polymorph_source_struct;
        if info_b.polymorph_source_struct then info_b = info_b.polymorph_source_struct;

        return info_a == info_b;
    }

}

#scope_file

Handle_Dynamic_Memory_Mode :: enum {
    COUNT;
    COPY_AND_ENCODE;
}

handle_dynamic_memory :: (element: *$T, dynamic_memory_pointer: *u8, $mode: Handle_Dynamic_Memory_Mode, $allow_pointer := true) -> next_dynamic_memory_pointer: *u8 #must {
    #insert #run () -> string {
        quick_string_builder();
        p("// Handling dynamic memory for serializing %\n", T);
        info := cast(*Type_Info)type_info(T);

        if #complete info.type == {
            case .STRING;
                #if mode == .COPY_AND_ENCODE {
                    a(#string DONE
                        memcpy(dynamic_memory_pointer, element.data, element.count);            // copy original data
                        element.data = xx (cast(u64)dynamic_memory_pointer - cast(u64)element); // make pointer, point to the dynamic buffer (encoded)
                    DONE);
                }

                a(#string DONE
                    dynamic_memory_pointer = align_for_serialization(dynamic_memory_pointer + element.count); // commit the dynamic allocation
                DONE);

            case .ARRAY;
                array_info   := cast(*Type_Info_Array)info;
                element_size := array_info.element_type.runtime_size;

                if #complete array_info.array_type == {
                    case .RESIZABLE;
                        #if mode == .COPY_AND_ENCODE {
                            a(#string DONE
                                element.allocated = element.count;
                                element.allocator = Serialized_Data_Allocator;
                            DONE);
                        }
                        #through;

                    case .VIEW;
                        a(#string DONE
                            array_data_size := element.count * size_of(type_of(<<element.data));
                        DONE);

                        #if mode == .COPY_AND_ENCODE {
                            a(#string DONE
                                memcpy(dynamic_memory_pointer, element.data, array_data_size);           // copy original array elements
                                element.data = xx (cast(u64)dynamic_memory_pointer - cast(u64)element);  // encode the data pointer
                                data_start := cast(type_of(element.data)) dynamic_memory_pointer;        // get a pointer to the data to iterate
                            DONE);
                        } else {
                            a(#string DONE
                                data_start := element.data; // if we're not copying we just iterate throught the original data
                            DONE);
                        }

                        a(#string DONE
                            dynamic_memory_pointer = align_for_serialization(dynamic_memory_pointer + array_data_size); // commit the dynamic allocation
                            for 0..element.count-1 {
                                dynamic_memory_pointer = handle_dynamic_memory(data_start + it, dynamic_memory_pointer, mode);
                            }
                        DONE);

                    case .FIXED;
                        a(#string DONE
                            for 0..element.count-1 {
                                dynamic_memory_pointer = handle_dynamic_memory(element.data + it, dynamic_memory_pointer, mode);
                            }
                        DONE);
                }

            case .STRUCT;
            struct_info := cast(*Type_Info_Struct)info;
            #if mode == .COUNT {
                a(#string DONE
                cleanup_for_serialization(element);
                DONE);
            }

            replace, replacement_type := do_serialization_replacement(struct_info);
            if replace {
                p(#string DONE
                    replaced_element := serialization_replacement(element);
                    #assert(size_of(T) == size_of(*%1));
                DONE, replacement_type);

                #if mode == .COUNT {
                    p(#string DONE
                        pointer_to_replaced_element := *replaced_element;
                        dynamic_memory_pointer = handle_dynamic_memory(*pointer_to_replaced_element, dynamic_memory_pointer, mode, allow_pointer = true);
                    DONE);
                } else {
                    p(#string DONE
                        <<(cast(**%1)element) = *replaced_element;
                        dynamic_memory_pointer = handle_dynamic_memory(cast(**%1)element, dynamic_memory_pointer, mode, allow_pointer = true);
                    DONE, replacement_type);
                }

            } else {
                for member : struct_info.members {
                    if !(member.flags & .CONSTANT) {
                        p(#string DONE
                        dynamic_memory_pointer = handle_dynamic_memory(cast(*type_of(T.%1))((cast(*u8)element) + %2),
                                                                       dynamic_memory_pointer,
                                                                       mode);
                        DONE, member.name, member.offset_in_bytes);
                    }
                }
            }

            case .PROCEDURE;
                if info != type_info(Allocator_Proc) {
                    compiler_report(tprint("Only Allocator procedures can be in serialized structs, and this is a %", get_type_name(info)));
                }

            case .POINTER;
                #if allow_pointer {
                    a(#string DONE
                    process_pointer :: (element: *$T, dynamic_memory_pointer: *u8) {
                        if !<<element return;
                        element_size := size_of(type_of(<<(<<element)));
                    DONE);

                    #if mode == .COPY_AND_ENCODE {
                        a(#string DONE
                            memcpy(dynamic_memory_pointer, <<element, element_size);                      // copy original data
                            <<(cast(*u64)element) = (cast(u64)dynamic_memory_pointer - cast(u64)element); // make pointer, point to the dynamic buffer (encoded)
                            element_data := cast(type_of(<<element)) dynamic_memory_pointer;
                        DONE);
                    } else {
                        a(#string DONE
                            element_data := <<element;
                        DONE);
                    }

                    a(#string DONE
                        dynamic_memory_pointer = align_for_serialization(dynamic_memory_pointer + element_size); // commit the dynamic allocation
                        dynamic_memory_pointer = handle_dynamic_memory(element_data, dynamic_memory_pointer, mode);
                    }

                    process_pointer(element, dynamic_memory_pointer);
                    DONE);
                } else {
                    a(#string DONE
                    if <<element != null {
                        log_error("We only allow null-pointers to be serialized, and % wasn't!", T);
                        assert(false);
                    }
                    DONE);
                }

            case .VARIANT;
                variant_info := cast(*Type_Info_Variant)info;
                p(#string DONE
                    dynamic_memory_pointer = handle_dynamic_memory(cast(*%1)element, dynamic_memory_pointer, mode, allow_pointer);
                DONE, get_type_name(variant_info.variant_of));

            case .INTEGER;
            case .FLOAT;
            case .BOOL;
            case .VOID;
            case .POLYMORPHIC_VARIABLE;
            case .ENUM;
            // Nothing to do for these, they will just be memcpy-ed

            case .TYPE;         #through;
            case .CODE;         #through;
            case .OVERLOAD_SET; #through;
            case .ANY;
                compiler_report(tprint("Type % cannot be serialized cause it's a %", T, info.type));
        }

        return builder_to_string(b);
    }();

    return dynamic_memory_pointer;
}

decode_dynamic_memory :: (element : *$T) {
    #insert #run () -> string {
        quick_string_builder();
        p("// Decoding dynamic memory for deserializing %\n", T);
        info := cast(*Type_Info)type_info(T);

        if info.type == {
            case .STRING;
                a(#string DONE
                    element.data = cast(*u8)(cast(u64)element + cast(u64)element.data);
                DONE);

            case .ARRAY;
                array_info   := cast(*Type_Info_Array)info;
                element_type := array_info.element_type;
                do_decode    := !(element_type.type == .INTEGER || element_type.type == .FLOAT || element_type.type == .BOOL);

                if #complete array_info.array_type == {
                    case .RESIZABLE;
                        a(#string DONE
                            element.allocated = element.count;
                            element.allocator = Serialized_Data_Allocator;
                        DONE);
                        #through;


                    case .VIEW;
                        a(#string DONE
                            element.data = xx (cast(u64)element + cast(u64)element.data);
                        DONE);
                        #through;


                    case .FIXED;
                        if do_decode {
                            a(#string DONE
                                for 0..element.count-1 {
                                    inline decode_dynamic_memory(element.data + it);
                                }
                            DONE);
                        }
                }

            case .STRUCT;
                struct_info := cast(*Type_Info_Struct) info;
                replace, replacement_type := do_serialization_replacement(struct_info);
                if replace {
                    p(#string DONE
                        #assert(size_of(T) == size_of(*%1));
                        pointer_to_replaced_element : **%1 = cast(**%1)element;
                        inline decode_dynamic_memory(pointer_to_replaced_element);
                        <<element = deserialization_replacement(<<pointer_to_replaced_element);
                    DONE, replacement_type);
                }

                for member : struct_info.members {
                    if !(member.flags & .CONSTANT) {
                        p(#string DONE
                            inline decode_dynamic_memory(cast(*type_of(T.%1))((cast(*u8)element) + %2));
                        DONE, member.name, member.offset_in_bytes);
                    }
                }

            case .PROCEDURE;
                if info == type_info(Allocator_Proc) {
                    // @@NOTE: We could catch Allocator structs on the .STRUCT codepath
                    // instead, but just in case someone does an allocator procedure by itself
                    // maybe this is better and simpler.
                    p(#string DONE
                    <<element = Serialized_Data_Allocator.proc;
                    DONE);
                }

            case .POINTER;
                a(#string DONE
                offset := <<(cast(*u64)element);
                if offset > 0 {
                    <<element = cast(T)(cast(u64)element + <<(cast(*u64)element));
                    inline decode_dynamic_memory(<<element);
                }
                DONE);

            case .VARIANT;
                variant_info := cast(*Type_Info_Variant)info;
                p(#string DONE
                decode_dynamic_memory(cast(*%1)element);
                DONE, get_type_name(variant_info.variant_of));
        }

        return builder_to_string(b);
    }();
}

Serialized_Data_Allocator :: Allocator.{
    proc = (mode: Allocator_Mode, size: s64, old_size: s64, old_memory_pointer: *void, allocator_data: *void) -> *void {
        log_error("Can't allocate data on a serialized data structure!");
        assert(false);
        return null;
    },
    data = null,
};

do_serialization_replacement :: (struct_info : *Type_Info_Struct) -> bool, Type {
    for member : struct_info.members {
        if member.name == "SERIALIZATION_REPLACEMENT" {
            assert((member.flags & .CONSTANT) != 0);
            assert(member.type == type_info(Type));
            type : *Type = cast(*Type)(struct_info.constant_storage.data + member.offset_into_constant_storage);
            return true, <<type;
        }
    }

    return false, void;
}

align_for_serialization :: (value : $T) -> T {
    return (value + 15) & (~15);
}

quick_string_builder :: () #expand {
    `_builder : String_Builder;
    _builder.allocator = __temporary_allocator;
    `defer reset(*_builder);

    `b := *_builder;

    `p :: (format_string : string, args: ..Any) #expand {
        print_to_builder(*_builder, format_string, ..args);
    } @PrintLike

    `a :: (the_string : string) #expand {
        append(*_builder, the_string);
    }
}



get_type_name :: (info : *Type_Info) -> string {
    builder : String_Builder;
    free_buffers(*builder);
    get_type_name_internal(*builder, info);

    get_type_name_internal :: (builder : *String_Builder, info : *Type_Info) {
        if info.type == .PROCEDURE {
            info_proc := cast(*Type_Info_Procedure)(info);
            append(builder, "(");
            for info_proc.argument_types {
                if it_index != 0 then append(builder, ", ");
                get_type_name_internal(builder, it);
            }

            append(builder, ")");
            if info_proc.return_types {
                append(builder, " -> (");
                for info_proc.return_types {
                    if it_index != 0 then append(builder, ", ");
                    get_type_name_internal(builder, it);
                }
                append(builder, ")");
            }
        } else {
            print_type_to_builder(builder, info);
        }
    }

    return builder_to_string(*builder, allocator = temporary_allocator);
}




// Tady je moje testovací implementace:

// size_of_bytes :: (data: *void, type: *Type_Info) -> s64 {
//     total_size: s64;

//     if type.type == {
//         case .STRUCT;
//             struct_info := cast(*Type_Info_Struct) type;
//             for member: struct_info.members {
//                 total_size += size_of_bytes(data + member.offset_in_bytes, member.type);
//             }
//         case .STRING;
//             total_size += size_of(s64); // count

//             string_value := cast(*string) data;
//             total_size += string_value.count;
//         case .ARRAY;
//             assert(true, "zatím nepodporujeme array");
//             // array_info := cast(*Type_Info_Array) type.type;
//             // return size_of_bytes()
//         case;
//             total_size += type.runtime_size;
//     }

//     return total_size;
// }

// // Serializace

// to_bytes_helper :: (data: *void, type: *Type_Info, offset: s64, buffer: []u8) {
//     if type.type == {
//         case .STRUCT;
//             struct_info := cast(*Type_Info_Struct) type;

//             for member: struct_info.members {
//                 to_bytes_helper(data + member.offset_in_bytes, member.type, offset, buffer);
//                 offset += size_of_bytes(data + member.offset_in_bytes, member.type); // real size
//             }
//         case .STRING;
//             string_value := cast(*string) data;
//             count_size := size_of(type_of(string_value.count));

//             << cast(*s64) (buffer.data + offset) = string_value.count;
//             memcpy(buffer.data + count_size + offset, string_value.data, string_value.count);
//         case .ARRAY;
//             assert(true, "zatím nepodporujeme array");
//             // array_info := cast(*Type_Info_Array) type.type;
//             // return size_of_bytes()
//         case;
//             memcpy(buffer.data + offset, data, type.runtime_size);
//     }
// }

// to_bytes :: (value: *$T) -> []u8 {
//     info := type_info(T);
//     data := cast(*void) value;

//     total_size := size_of_bytes(data, info);
//     bytes := NewArray(total_size, u8);

//     to_bytes_helper(data, info, 0, bytes);

//     log("Total size: % == %", total_size, bytes.count);

//     return bytes;
// }

// // Deserilizace

// from_bytes_helper :: (buffer: []u8, offset: s64, data: *void, info: *Type_Info) -> s64 {
//     if info.type == {
//         case .STRUCT;
//             struct_info := cast(*Type_Info_Struct) info;
//             real_size: s64;

//             for member: struct_info.members {
//                 real_size += from_bytes_helper(buffer, offset + real_size, data + member.offset_in_bytes, member.type);
//             }

//             return real_size;
//         case .STRING;
//             string_value := cast(*string) data;
//             count_size := size_of(type_of(string_value.count));

//             string_value.count = << cast(*s64) (buffer.data + offset);
//             string_value.data = buffer.data + offset + count_size;

//             return count_size + string_value.count;
//         case .ARRAY;
//             assert(true, "zatím nepodporujeme array");
//             // array_info := cast(*Type_Info_Array) type.type;
//             // return size_of_bytes()
//             return 0;
//         case;
//             memcpy(data, buffer.data + offset, info.runtime_size);
//             return info.runtime_size;
//     }

//     return 0;
// }

// from_bytes :: (bytes: []u8, $T: Type) -> T {
//     result: T;

//     info := type_info(T);
//     readed := from_bytes_helper(bytes, 0, *result, info);

//     return result;
// }
