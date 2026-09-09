init_memory_files :: () {
    init(*server.memory_files_lock);
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
        if !change.range {
            // Full document sync: the client sent the whole new text.
            replace_range(content, 0, content.count, change.text);
            continue;
        }

        apply_change(content, change.range.start, change.range.end, change.text);
    }
}

remove_memory_file :: (file_path: string) {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    ok, content := table_find(*server.memory_files, file_path);
    if !ok return;
    array_free(content);

    found := table_remove(*server.memory_files, file_path);
    if !found {
        log_error("Tried to remove file % but it was not in the server.memory_files table!", file_path);
    }
}

get_memory_file :: (name: string) -> []u8 {
    lock(*server.memory_files_lock);
    defer unlock(*server.memory_files_lock);

    ok, content := table_find(*server.memory_files, name);
    if !ok {
        return .[];
    }

    return content;
}

#scope_file

position_to_offset :: (content: []u8, position: LSP_Position) -> int {
    offset := 0;
    line := 0;

    while line < position.line && offset < content.count {
        if content[offset] == #char "\n" line += 1;
        offset += 1;
    }

    if line < position.line {
        return content.count; // The document has fewer lines than requested.
    }

    units: int;
    while offset < content.count && units < position.character {
        byte := content[offset];
        if byte == #char "\n" break;

        sequence_length := 1;
        if byte >= 0xF0 {
            sequence_length = 4;
        } else if byte >= 0xE0 {
            sequence_length = 3;
        } else if byte >= 0xC0 {
            sequence_length = 2;
        }

        units += ifx sequence_length == 4 then 2 else 1;
        offset += sequence_length;
    }

    if offset > content.count {
        offset = content.count;
    }

    return offset;
}

replace_range :: (content: *[..]u8, start: int, end: int, text: string) {
    if start < 0 || start > end || end > content.count {
        log_error("replace_range: invalid range [%, %) for a document of % bytes, ignoring the edit.", start, end, content.count);
        return;
    }

    old_count := content.count;
    removed   := end - start;
    tail      := old_count - end;
    new_count := old_count - removed + text.count;

    if new_count > content.allocated {
        array_reserve(content, new_count);
    }

    if tail > 0 && text.count != removed {
        source := content.data + end;
        dest   := content.data + start + text.count;

        if dest < source {
            for 0..tail-1 dest[it] = source[it];
        } else {
            for < 0..tail-1 dest[it] = source[it];
        }
    }

    if text.count > 0 {
        memcpy(content.data + start, text.data, text.count);
    }

    content.count = new_count;
}

apply_change :: (content: *[..]u8, from: LSP_Position, to: LSP_Position, text: string) {
    start_index := position_to_offset(content.*, from);
    end_index   := position_to_offset(content.*, to);

    if end_index < start_index {
        tmp := start_index;
        start_index = end_index;
        end_index = tmp;
    }

    replace_range(content, start_index, end_index, text);
}
