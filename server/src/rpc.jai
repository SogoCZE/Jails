#import "String";

read_from_stdin :: (buffer: *u8, bytes_to_read: u32) -> u32 {
    readed: u32;

    #if OS == .WINDOWS {
        win32 :: #import "Windows";
        handle := win32.GetStdHandle(win32.STD_INPUT_HANDLE);
    } else {
        posix :: #import "POSIX";
    }

    while bytes_to_read > readed  {
        #if OS != .WINDOWS { // Linux, MacOS 
            readed += xx posix.read(posix.STDIN_FILENO, buffer+readed, bytes_to_read-readed);
        } else { // Windows
            win32.ReadFile(handle, buffer+readed, bytes_to_read-readed, xx *readed);
        }
    }

    return readed; 
}

read_line_from_stdin :: (buffer: []u8) -> u32 {
    total_read: u32;

    while read_from_stdin(buffer.data + total_read, 1) {
        total_read += 1;
        if buffer[total_read - 1] == #char "\n" {
            break;
        } 
    }

    return total_read;
}

parse_header :: (header : string) -> s32, success: bool {
    split_header := split(header, ": ");
    if split_header[0] != "Content-Length" {
        log_error("Expected length message, got:\n%\n", header);
        return 0, false;
    }

    nb_bytes, success := parse_int(*split_header[1], s32);
    return nb_bytes, success;
}

get_message :: () -> string, bool {
    buffer: [0xFFFF]u8;     

    header_bytes := read_line_from_stdin(buffer);
    header := to_string(buffer.data, header_bytes);

    body_size, success := parse_header(header);
    if !success {
        return "", false;
    }

    body_buffer: []u8 = ---;
    body_buffer.data = talloc(body_size);
    body_buffer.count = body_size;
    
    read_from_stdin(buffer.data + header.count, 2); // @todo: this is somewhat weird
    if buffer[header.count+1] != #char "\n" {
        body_buffer[0] = buffer[header.count];
        body_buffer[1] = buffer[header.count+1];
        log("\n\n------------------ FAIL!!!!!\n\n");
    }

    body_read := read_from_stdin(body_buffer.data, xx body_buffer.count);

    if body_read != xx body_size {
        log_error("Expected % bytes, got %.\n", body_size, body_read);
        return "", false;
    }

    body := to_string(body_buffer.data, body_buffer.count);

    return body, true;        
}

send_message :: (data: $T) {
    body := json_write_string(data);
    print("Content-Length: %\r\n\r\n%", body.count, body);
}