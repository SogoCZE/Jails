Plugin :: Metaprogram_Plugin;

Jails_Diagnostics_Plugin :: struct {
    #as using base: Plugin;
}

get_plugin :: () -> *Plugin {
    p := New(Jails_Diagnostics_Plugin);

    p.before_intercept = before_intercept;
    p.shutdown = shutdown;

    return p;

}

before_intercept :: (_p: *Plugin, flags: *Intercept_Flags) {
    p := cast(*Jails_Diagnostics_Plugin) _p;
    options := get_build_options(p.workspace);
    options.output_type = .NO_OUTPUT;
    set_build_options(options, p.workspace);
}

shutdown :: (_p: *Plugin) {
    p := cast(*Jails_Diagnostics_Plugin) _p;
    free(p);
}

#import "Compiler";
#import "Basic";