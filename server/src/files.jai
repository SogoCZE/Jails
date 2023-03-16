// @ToDo: Give these more distinguished names! (modified_files?)
file_lock: Mutex;
files: Table(string, [..]u8); // Tohle je asi hodně hloupé. - převést na array řádků (to je asi fajn idea)
// @ToDo: Keep track of a modified flag per file

init_files :: () {
    init(*file_lock);
    init(*files);
}

deinit_files :: () {
    destroy(*file_lock);
    deinit(*files);
}

create_file :: (file_path: string, content: string) {
    content_dynamic: [..]u8;

    array_copy(*content_dynamic, cast([]u8) content);
    free(content);

    lock(*file_lock);
    defer unlock(*file_lock);
    table_set(*files, file_path, content_dynamic);
    // dump_files();
}

edit_file :: (file_path: string, changes: []LSP_Content_Change) {
    lock(*file_lock);
    defer unlock(*file_lock);

    content := table_find_pointer(*files, file_path);
    if !content {
        log_error("File is not in the cache %", file_path);
        return;
    }

    for change: changes {
        from := change.range.start;
        to := change.range.end;
        apply_change(content, from, to, xx change.text);
    }

    // dump_files();
}

remove_file :: (file_path: string) {
    lock(*file_lock);
    defer unlock(*file_lock);
    found := table_remove(*files, file_path);
    if !found {
        log_error("Tried to remove file % but it was not in the modified files table!", file_path);
    }
}

find_range_in_file :: (file: string, range: LSP_Range) -> string {
    lock(*file_lock);
    defer unlock(*file_lock);
    content, ok := table_find(*files, file);
    if !ok {
        return "";
    }

    current_line: int;
    start_index: int = -1;
    end_index: int = -1;

    // Najdeme index bytu pro začátek i konec range.
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

find_line_in_file :: (file: string, position: LSP_Position) -> string {
    lock(*file_lock);
    defer unlock(*file_lock);
    content, ok := table_find(*files, file);
    if !ok {
        return "";
    }

    final_line: int;
    start_index: int = -1;
    end_index := content.count;

    // @SPEED: Tady toto hledání by se dalo urychlit kdybychom měli soubor rozdělaná na array řádků.
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

find_word_in_file :: (file: string, position: LSP_Position) -> string {
    lock(*file_lock);
    defer unlock(*file_lock);
    content, ok := table_find(*files, file);
    if !ok {
        return "";
    }

    final_line: int;
    pointer_index: int = -1;

    // @SPEED: Tady toto hledání by se dalo urychlit kdybychom měli soubor rozdělaná na array řádků.
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

    // Hledání slova
    start_index := 0;
    end_index := content.count;

    is_seperation :: (char: u8) -> bool {
        return is_any(char, " \n\t;*.[](){}=:#\",!");
    }

    // Hledání začátku
    for < index: pointer_index..0 {
        char := content[index];
        if is_seperation(char) {
            start_index = index+1;
            break;
        }
    }

    // Hledání konce
    for index: pointer_index..content.count-1 {
        char := content[index];
        if is_seperation(char) {
            end_index = index;
            break;
        }
    }


    return to_string(*content[start_index], end_index-start_index);
}

#scope_file

DEBUG_AC :: false;

// TODO:
// - unicode
// - {}, "", () jak vscode vloží automaticky uzavěrky těchto znaků tak to blbne občas.
// - pořádně otestovat různé případy...
// tahle funkce upraví soubor dle zadaných parametrů (from, to, text)
apply_change :: (content: *[..]u8, from: LSP_Position, to: LSP_Position, text: []u8) {
    current_line: int;
    start_index: int = -1;
    end_index: int = -1;

    // Najdeme index bytu pro začátek i konec range.
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

    // Debug - až si budeme jistí, že to funguje neomylně tak to odebrat.
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

    assert(content.count >= start_index && content.count >= end_index);

    // Pokud jenom vkládáme
    if start_index == end_index {
        for char: text {
            array_insert_at(content, char, start_index + it_index);
            #if DEBUG_AC log("inserting % at %", to_string(*char, 1), start_index + it_index);
        }
        return;
    }

    // Nahrazení nebo mazání (nahrazení range za vložený text)
    text_index := 0;
    removed := 0;
    for start_index..end_index-1 {
        // Když už jsme vložily všechen text a zbývá nám range tak mažeme.
        if text_index > text.count-1 {
            array_ordered_remove_by_index(content, it-removed);
            #if DEBUG_AC log("removing %", it-removed);
            removed += 1;
            continue;
        }

        (<<content)[it-removed] = text[text_index];
        text_index += 1;
    }

    // Vložení zbytků po nahrazování (range je menší než vložený text)
    if text_index < text.count-1 {
        for index: 0..text.count - 1 - text_index {
            char := text[text_index + index];
            array_insert_at(content, char, end_index + index);

            #if DEBUG_AC log("inserting % at %", to_string(*char, 1), end_index + index);
        }
    }

}

dump_files :: () {
    lock(*file_lock);
    defer unlock(*file_lock);
    for content, file: files {
        just_filename := path_filename(file);
        write_entire_file(tprint("/Users/patriksmely/Documents/Projekty/jai_lsp_meta/server/bin/files_dump/%", just_filename), cast(string) content);
    }
}

#import "Thread";
