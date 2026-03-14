Plugin :: Metaprogram_Plugin;

Jails_Diagnostics_Plugin :: struct {
    #as using base: Plugin;
    intermediate_path: string;
}

get_plugin :: () -> *Plugin {
    p := New(Jails_Diagnostics_Plugin);

    p.init = init;
    p.before_intercept = before_intercept;
    p.add_source = add_source;
    p.shutdown = shutdown;

    return p;
}

init :: (p: *Plugin, options: [] string) -> bool {
    my := cast(*Jails_Diagnostics_Plugin) p;

    cursor := 0;
    while cursor < options.count {
        s := options[cursor];
        if s == {
          case "-intermediate_path";
            if cursor >= options.count-1 {
                log_error("Jails_Diagnostics_Plugin: Missing argument to -intermediate_path.\n");
                return false;
            }

            my.intermediate_path = options[cursor+1];
            cursor += 2;
          case;
            log_error("Command line for plugin Jails_Diagnostics_Plugin: Unknown argument '%'\n", s);
            return false;
        }
    }

    return true;
}

add_source :: (_p: *Plugin) {
    p := cast(*Jails_Diagnostics_Plugin) _p;
    add_build_string("JAILS_DIAGNOSTICS_BUILD :: true;", p.workspace);
}

before_intercept :: (_p: *Plugin, flags: *Intercept_Flags) {
    p := cast(*Jails_Diagnostics_Plugin) _p;
    options := get_build_options(p.workspace);
    options.output_type = .NO_OUTPUT;

    if p.intermediate_path {
        options.intermediate_path = p.intermediate_path;
    }

    set_build_options(options, p.workspace);
}

shutdown :: (_p: *Plugin) {
    p := cast(*Jails_Diagnostics_Plugin) _p;
    free(p);
}

#import "Compiler";
#import "Basic";
#import "String";
