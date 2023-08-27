#import "String";

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
              // probably EAGAIN or EINTR?
              err := posix.errno();
              if err != posix.EINTR && err != posix.EAGAIN {
                  log_error("Reading the stdin failed with errno: %", posix.errno());
                  return readed;
              } else {
                  // we should retry
              }
            } else if read_this_time == 0 {
              // probably closed (EOF)
              return readed;
            } else {
              readed += xx read_this_time;
            }
        } else { // Windows
            read_this_time = 0;
            ok := win32.ReadFile(handle, buffer+readed, xx (bytes_to_read-readed), xx *read_this_time);
            if ok && read_this_time == 0 return readed; // EOF
            readed += xx read_this_time;
        }
    }

    return readed;
}

read_line_from_stdin :: (buffer: []u8) -> u64 {
    total_read: u64;

    while read_from_stdin(buffer.data + total_read, 1) {
        total_read += 1;
        if buffer[total_read - 1] == #char "\n" {
            break;
        } 
    }

    return total_read;
}

parse_header :: (header : string) -> s64, success: bool {
    split_header := split(header, ": ");
    if split_header[0] != "Content-Length" {
        log_error("Expected length message, got:\n%\n", header);
        return 0, false;
    }

    nb_bytes, success := parse_int(*split_header[1], s64);
    return nb_bytes, success;
}

read_message_from_stdin :: () -> string, bool {
    buffer: [0xFFFF]u8;

    header_bytes := read_line_from_stdin(buffer);
    if header_bytes <= 0 {
      log_error("The input channel was closed!");
      return "", false;
    }
    header := to_string(buffer.data, xx header_bytes);

    body_size, success := parse_header(header);
    if !success {
        log_error("Couldnt parse header!");
        return "", false;
    }

    body_buffer: []u8 = ---;
    body_buffer.data = talloc(body_size);
    body_buffer.count = body_size;

    if read_from_stdin(buffer.data + header.count, 2) < 2 {
      log_error("Couldn't read CRLF!");
      return "", false;
    } // @todo: this is somewhat weird

    if buffer[header.count+1] != #char "\n" {
        body_buffer[0] = buffer[header.count];
        body_buffer[1] = buffer[header.count+1];
        log("\n\n------------------ FAIL!!!!!\n\n");
    }

    body_read := read_from_stdin(body_buffer.data, xx body_buffer.count);

    if body_read != xx body_size {
        log_error("Expected % bytes, got %!", body_size, body_read);
        return "", false;
    }

    body := to_string(body_buffer.data, body_buffer.count);

    return body, true;        
}

send_message :: (data: $T) {
    body := json_write_string(data);
    print("Content-Length: %\r\n\r\n%", body.count, body);
}

