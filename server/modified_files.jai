init_modified_files :: () {
    init(*server.modified_files_lock);
    init(*server.modified_files);
}

deinit_modified_files :: () {
    destroy(*server.modified_files_lock);
    deinit(*server.modified_files);
}

create_modified_file :: (file_path: string, content: string) {
    file_without_uri_prefix := replace(file_path, "file://", "");
    content_dynamic: [..]u8;

    array_copy(*content_dynamic, cast([]u8) content);
    free(content);

    lock(*server.modified_files_lock);
    defer unlock(*server.modified_files_lock);
    table_set(*server.modified_files, file_without_uri_prefix, content_dynamic);
    // dump_server_modified_files();
}

edit_modified_file :: (file_path: string, changes: []LSP_Content_Change) {
    file_without_uri_prefix := replace(file_path, "file://", "");
    lock(*server.modified_files_lock);
    defer unlock(*server.modified_files_lock);

    content := table_find_pointer(*server.modified_files, file_without_uri_prefix);
    if !content {
        log_error("File is not in the cache %", file_without_uri_prefix);
        return;
    }

    for change: changes {
      if change.range {
          from := change.range.start;
          to := change.range.end;
          apply_change(content, from, to, xx change.text);
        } else {
          // full file
          apply_change_to_range(content, 0, content.count, xx change.text );
        }
    }
}

remove_modified_file :: (file_path: string) {
    file_without_uri_prefix := replace(file_path, "file://", "");
    lock(*server.modified_files_lock);
    defer unlock(*server.modified_files_lock);

    found := table_remove(*server.modified_files, file_without_uri_prefix);
    if !found {
        log_error("Tried to remove file % but it was not in the modified server.modified_files table!", file_without_uri_prefix);
    }
}

find_range_in_modified_file :: (file: string, range: LSP_Range) -> string {
    lock(*server.modified_files_lock);
    defer unlock(*server.modified_files_lock);

    content, ok := table_find(*server.modified_files, file);
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

find_line_in_modified_file :: (file: string, position: LSP_Position) -> string {
    lock(*server.modified_files_lock);
    defer unlock(*server.modified_files_lock);
    content, ok := table_find(*server.modified_files, file);
    if !ok {
        return "";
    }

    final_line: int;
    start_index: int = -1;
    end_index := content.count;

    // @SPEED: This searching could be probably done faster if we had server.modified_files stored as array of lines instead of file content. 
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

get_modified_file :: (name: string) -> []u8 {
    lock(*server.modified_files_lock);
    defer unlock(*server.modified_files_lock);

    content, ok := table_find(*server.modified_files, name);
    if !ok {
        return .[];
    }

    return content;
}

#scope_file

DEBUG_AC :: true;

// @todo:
// - unicode support
// - {}, "", () when the editor (for example vscode) auto-closes parentheses behaves badly.
// Mutates in memory file
apply_change :: (content: *[..]u8, from: LSP_Position, to: LSP_Position, text: []u8) {
    current_line: int;
    start_index: int = -1;
    end_index: int = -1;

    // We get index of starting and ending byte of the range.
    for char: <<content {
        if current_line == from.line && start_index == -1 {
            start_index = it_index + from.character;
        }

        if current_line == to.line && end_index == -1 {
            end_index = it_index + to.character;
        }

        if char == #char "\n" {
            current_line += 1;
        }

        if start_index > -1 && end_index > -1 {
            break;
        }
    }

    if start_index < 0 || end_index < 0 {
      log( "didn't find the requested range in the document: %:% -> %:%\n",
           from.line, from.character,
           to.line, to.character );
       return;
    }

    #if DEBUG_AC {
        log("from: %, to: % (reached line %)", from.line, to.line, current_line);

        log("- START (%)", start_index);

        builder: String_Builder;

        for start_index..end_index-1 {
            char := (<<content)[it];
            print_to_builder(*builder, "%", to_string(*char, 1));
        }

        log("%", builder_to_string(*builder));

        log("- END (%)", end_index);
    }
    apply_change_to_range(content, start_index, end_index, text );
}

apply_change_to_range :: (content: *[..]u8, start_index: int, end_index: int, text: []u8 ) {

    assert(content.count >= start_index && content.count >= end_index);

    // Inserting only
    if start_index == end_index {
        for char: text {
            array_insert_at(content, char, start_index + it_index);
            #if DEBUG_AC log("inserting % at %", to_string(*char, 1), start_index + it_index);
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

        (<<content)[it-removed] = text[text_index];
        text_index += 1;
    }

    // Insertion of leftovers (range is smaller than insrted content)
    if text_index < text.count-1 {
        for index: 0..text.count - 1 - text_index {
            char := text[text_index + index];
            array_insert_at(content, char, end_index + index);

            #if DEBUG_AC log("inserting % at %", to_string(*char, 1), end_index + index);
        }
    }

}

// dump_modified_files :: () {
//     lock(*server.modified_server.modified_files_lock);
//     defer unlock(*server.modified_server.modified_files_lock);

//     for content, file: server.modified_files {
//         just_filename := path_filename(file);
//         write_entire_file(tprint("%/server/bin/server.modified_files_dump/%", PROJECT_FOLDER_PATH, just_filename), cast(string) content);
//     }
// }

#import "Thread";
