get_cursor_context :: (file: string, position: LSP_Position) -> []string {
    content := get_modified_file(file);

    final_line: int;
    pointer_index: int = -1;

    // @SPEED: This searching could be probably done faster if we had server.modified_files stored as array of lines instead of file content. 
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
        return .[];
    }

    // Word search
    start_index := 0;
    end_index := content.count;

    is_separator :: (char: u8) -> bool {
        return is_any(char, " \n\t;*.[](){}=:#\",!+-/");
    }


    // Start search
    for < index: pointer_index..0 {
        char := content[index];
        if is_separator(char) {

            // For struct members
            if char == #char "." {
                continue;
            }

            start_index = index+1;
            break;
        }
    }

    // End search
    for index: pointer_index..content.count-1 {
        char := content[index];
        if is_separator(char) {
            end_index = index;
            break;
        }
    }


    word_or_path := to_string(*content[start_index], end_index-start_index);

    path := split(word_or_path, ".");

    return path;
}