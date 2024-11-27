init_memory_files :: () {
    init(*server.memory_files_lock);
    init(*server.memory_files);
}

deinit_memory_files :: () {
    destroy(*server.memory_files_lock);
    deinit(*server.memory_files);
}

create_memory_file :: (file_path: string, content: string) {
    content_dynamic: [..]u8;

    array_copy(*content_dynamic, cast([]u8) content);
    // free(content);

    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);
    table_set(*server.memory_files, copy_string(file_path), content_dynamic);
}

edit_memory_file :: (file_path: string, changes: []LSP_Content_Change) {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    content := table_find_pointer(*server.memory_files, file_path);
    if !content {
        log_error("File is not in the cache %", file_path);
        return;
    }

    for change: changes {
        from := change.range.start;
        to := change.range.end;
        apply_change(content, from, to, change.text);
    }
}

remove_memory_file :: (file_path: string) {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    content, ok := table_find(*server.memory_files, file_path);
    if !ok return;
    array_free(content);

    found := table_remove(*server.memory_files, file_path);
    if !found {
        log_error("Tried to remove file % but it was not in the server.memory_files table!", file_path);
    }
}

find_range_in_memory_file :: (file: string, range: LSP_Range) -> string {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    content, ok := table_find(*server.memory_files, file);
    if !ok {
        return "";
    }

    current_line: int;
    start_index: int = -1;
    end_index: int = -1;

    // We get index of starting and ending byte of the range.
    for char: content {
        if current_line == range.start.line && start_index == -1 {
            start_index = it_index + range.start.character;
        }

        if current_line == range.end.line && end_index == -1 {
            end_index = it_index + range.end.character;
        }

        if char == #char "\n" {
            current_line += 1;
        }

        if start_index > -1 && end_index > -1 {
            break;
        }
    }

    return to_string(*content[start_index], end_index-start_index);
}

find_line_in_memory_file :: (file: string, position: LSP_Position) -> string {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);
    content, ok := table_find(*server.memory_files, file);
    if !ok {
        return "";
    }

    final_line: int;
    start_index: int = -1;
    end_index := content.count;

    // @SPEED: This searching could be probably done faster if we had server.memory_files stored as array of lines instead of file content.
    for char: content {
        if char == #char "\n" {
            final_line += 1;
        }

        if final_line == position.line {
            start_index = it_index;

            if final_line != 0 {
                start_index += 1;
            }

            break;
        }
    }

    for index: start_index..content.count-1 {
        char := content[index];
        if char == #char "\n" {
            end_index = index;
            break;
        }
    }

    return to_string(*content[start_index], end_index-start_index);
}

get_memory_file :: (name: string) -> []u8 {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    content, ok := table_find(*server.memory_files, name);
    if !ok {
        return .[];
    }

    return content;
}

find_word_in_memory_file :: (file: string, position: LSP_Position, with_start_separator := false, with_end_separator := false) -> string {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);
    content, ok := table_find(*server.memory_files, file);
    if !ok {
        return "";
    }

    final_line: int;
    pointer_index: int = -1;

    // @SPEED: This searching could be probably done faster if we had server.memory_files stored as array of lines instead of file content.
    for char: content {
        if char == #char "\n" {
            final_line += 1;
        }

        if final_line == position.line {
            pointer_index = it_index + position.character;
            break;
        }
    }

    if pointer_index == -1 {
        return "";
    }

    // Word search
    start_index := 0;
    end_index := content.count;

    is_seperation :: (char: u8) -> bool {
        return is_any(char, " \n\t;*.[](){}=:#\",!+-/");
    }

    // Start search
    for #v2 < index: 0..pointer_index {
        char := content[index];
        if is_seperation(char) {
            start_index = index;
            if !with_start_separator {
                start_index += 1;
            }

            break;
        }
    }

    // End search
    for index: pointer_index..content.count-1 {
        char := content[index];
        if is_seperation(char) {
            end_index = index;
            if !with_end_separator {
                end_index += 1;
            }

            break;
        }
    }

    return to_string(*content[start_index], end_index-start_index);
}

#scope_file

DEBUG_AC :: false;

// @todo:
// - unicode support
// Mutates in memory file
apply_change :: (content: *[..]u8, from: LSP_Position, to: LSP_Position, text: string) {
    current_line: int;
    current_char: int;
    start_index: int = -1;
    end_index: int = -1;

    curr: int;

    // We get index of starting and ending byte of the range.
    for char: content.* {

        if is_utf_cont(char) {
            curr += 1;
            continue;
        }

        if current_line == from.line && from.character == current_char {
            start_index = curr;
        }

        if current_line == to.line && to.character == current_char {
            end_index = curr;
        }

        if start_index > -1 && end_index > -1 {
            break;
        }

        curr += 1;
        current_char += 1;

        if char == #char "\n" {
            current_line += 1;
            current_char = 0;
        }
    }

    if start_index < 0 {
        start_index = content.count;
    }

    if end_index < 0 {
        end_index = content.count;
    }

    #if DEBUG_AC {
        log("from: %, to: % (reached line %)", from.line, to.line, current_line);

        log("- START (%)", start_index);

        builder: String_Builder;

        for start_index..end_index {
            char := (content.*)[it];
            print_to_builder(*builder, "%", to_string(*char, 1));
        }

        log("%", builder_to_string(*builder));

        log("- END (%) [%]", end_index, end_index-start_index);
    }

    assert(content.count >= start_index && content.count >= end_index);

    // Inserting only
    if start_index == end_index {
        for i: 0..text.count-1 {
            char := text[i];
            array_insert_at(content, char, start_index+i);
            #if DEBUG_AC log("inserting % at %", to_string(*char, 1), start_index + i);
        }
        return;
    }

    // Replace or delete
    text_index := 0;
    removed := 0;
    for start_index..end_index-1 {

        // When we are left with unprocessed range after insertion we delete it
        if text_index > text.count-1 {
            array_ordered_remove_by_index(content, it-removed);
            #if DEBUG_AC log("removing %", it-removed);
            removed += 1;
            continue;
        }

        (content.*)[it-removed] = text[text_index];
        text_index += 1;
    }

    // Insertion of leftovers (range is smaller than inserted content)
    if text_index < text.count {
        for index: 0..text.count - 1 - text_index {
            char := text[text_index + index];
            array_insert_at(content, char, end_index + index);

            #if DEBUG_AC log("inserting % at %", to_string(*char, 1), end_index + index);
        }
    }

}
