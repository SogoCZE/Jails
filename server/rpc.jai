#import "String";

MAX_MESSAGE_BODY_SIZE :: 256 * 1024 * 1024;
MAX_HEADER_LINE_SIZE :: 8 * 1024;

read_from_stdin :: (buffer: *u8, bytes_to_read: u64) -> u64 {
    readed: u64;
    read_this_time: s64;

    #if OS == .WINDOWS {
        win32 :: #import "Windows";
        handle := win32.GetStdHandle(win32.STD_INPUT_HANDLE);
    } else {
        posix :: #import "POSIX";
    }

    while bytes_to_read > readed  {
        #if OS != .WINDOWS { // Linux, MacOS
            read_this_time = posix.read(posix.STDIN_FILENO, buffer+readed, bytes_to_read-readed);
            if read_this_time < 0 {
                err := posix.errno();
                if err == posix.EINTR {
                    continue;
                }

                if err == posix.EAGAIN {
                    // stdin is non-blocking and has no data yet. Do not busy-spin at 100% CPU.
                    sleep_milliseconds(1);
                    continue;
                }

                log_error("Reading the stdin failed with errno: %", err);
                return readed;
            } else if read_this_time == 0 {
                return readed; // EOF
            } else {
                readed += xx read_this_time;
            }
        } else { // Windows
            read_this_time = 0;
            ok := win32.ReadFile(handle, buffer+readed, xx (bytes_to_read-readed), xx *read_this_time);

            if !ok || read_this_time == 0 return readed;

            readed += xx read_this_time;
        }
    }

    return readed;
}

read_line_from_stdin :: (buffer: []u8) -> count: u64, ok: bool {
    total_read: u64;

    while true {
        if total_read >= xx buffer.count {
            scratch: u8;
            while read_from_stdin(*scratch, 1) == 1 {
                if scratch == #char "\n" break;
            }
            log_error("Header line exceeded % bytes, discarding it.", buffer.count);
            return total_read, false;
        }

        if read_from_stdin(buffer.data + total_read, 1) != 1 {
            return total_read, false;
        }

        total_read += 1;
        if buffer[total_read - 1] == #char "\n" {
            return total_read, true;
        }
    }

    return total_read, true;
}

parse_header_line :: (line: string) -> name: string, value: string, ok: bool {
    colon := find_index_from_left(line, #char ":");
    if colon < 0 return "", "", false;

    name  := trim(slice(line, 0, colon));
    value := trim(slice(line, colon + 1, line.count - colon - 1));

    return name, value, true;
}

// Returns (body, success, closed). `closed` is true when stdin hit EOF, i.e. the client went away.
read_message_from_stdin :: () -> string, bool, bool {
    buffer: [MAX_HEADER_LINE_SIZE]u8;

    body_size: s64 = -1;
    header_count := 0;

    while true {
        line_bytes, line_ok := read_line_from_stdin(buffer);

        if line_bytes == 0 && !line_ok {
            if header_count == 0 {
                log_error("The input channel was closed!");
                return "", false, true;
            }

            log_error("Unexpected end of input while reading headers.");
            return "", false, true;
        }

        if !line_ok {
            return "", false, false;
        }

        line := trim_right(to_string(buffer.data, xx line_bytes), "\r\n");

        if line.count == 0 {
            if header_count == 0 {
                continue;
            }

            break;
        }

        header_count += 1;

        name, value, ok := parse_header_line(line);
        if !ok {
            log_error("Malformed header line:\n%\n", line);
            return "", false, false;
        }

        if name == "Content-Length" {
            remainder := value;
            parsed, parsed_ok := parse_int(*remainder, s64);
            if !parsed_ok || remainder.count > 0 || parsed < 0 {
                log_error("Invalid Content-Length value: '%'", value);
                return "", false, false;
            }

            body_size = parsed;
        }
    }

    if body_size < 0 {
        log_error("Message headers did not contain a Content-Length.");
        return "", false, false;
    }

    if body_size > MAX_MESSAGE_BODY_SIZE {
        log_error("Message body of % bytes exceeds the maximum of % bytes, dropping the connection.", body_size, MAX_MESSAGE_BODY_SIZE);
        return "", false, true;
    }

    body_buffer: []u8 = ---;
    body_buffer.data = talloc(body_size);
    body_buffer.count = body_size;

    if body_size == 0 {
        return "", true, false;
    }

    body_read := read_from_stdin(body_buffer.data, xx body_buffer.count);

    if body_read != xx body_size {
        log_error("Expected % bytes, got %! Input closed.", body_size, body_read);
        return "", false, true;
    }

    body := to_string(body_buffer.data, body_buffer.count);

    return body, true, false;
}
