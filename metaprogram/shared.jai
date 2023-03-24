DEBUG :: false;

Plugin :: Metaprogram_Plugin;

Jails_Plugin :: struct {
    #as using base: Plugin;
    should_run := true;
    channel_id: u64;
    write_channel: Write_Channel;
    read_channel: Read_Channel;
    modified_files: [] Modified_File; // @ToDo: Use this to intercept loads and replace files with the content from modified_files, if available
    start: Apollo_Time;
    pool: Pool;
    declarations_by_type_info_struct: Table(*Type_Info_Struct, *Struct); // Declarations by Type_Info_Struct pointer.
    procedure_header_to_declaration: Table(ID, ID); // Serial of Declaration by serial of procedure header.
    files: [..]string;
}

#import "Basic";
#import "String";
#import "Compiler";
#import "Pool";
#import "Shared_Memory_Channel";
