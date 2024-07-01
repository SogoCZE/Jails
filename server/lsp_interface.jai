
/*
    --- Base Protocol JSON Structures ---
*/

LSP_Message :: struct {
    jsonrpc: string = "2.0";
}

LSP_Client_Message :: struct(T: Type) {
    using base: LSP_Message;
    method: string;
    params: T;
}

LSP_Response_Message :: struct {
    using base: LSP_Message;
    id: u32;
}

LSP_Request_Message :: struct {
    using base: LSP_Message;
    id: u32;
    method: string;
}

LSP_Response_Error :: struct (Data_Type: Type) {
    code: LSP_Error_Codes;
    message: string;
    data: Data_Type;
}

LSP_Error_Codes :: enum s32 {
    PARSE_ERROR                         :: -32700;
    INVALID_REQUEST                     :: -32600;
    METHOD_NOT_FOUND                    :: -32601;
    INVALID_PARAMS                      :: -32602;
    INTERNAL_ERROR                      :: -32603;
    JSON_RPC_RESERVED_ERROR_RANGE_START :: -32099;
    SERVER_NOT_INITIALIZED              :: -32002;
    UNKNOWN_ERROR_CODE                  :: -32001;
    JSON_RPC_RESERVED_ERROR_RANGE_END   :: -32000;

    LSP_RESERVED_ERROR_RANGE_START      :: -32899;
    REQUEST_FAILED                      :: -32803;
    SERVER_CANCELLED                    :: -32802;
    CONTENT_MODIFIED                    :: -32801;
    REQUEST_CANCELLED                   :: -32800;
    LSP_RESERVED_ERROR_RANGE_END        :: -32800;
}

LSP_Notification_Message :: struct {
    using base: LSP_Message;
}

LSP_Cancel_Params :: struct {
    id: u32;
}

LSP_Progress_Params :: struct (Value_Type: Type) {
    token: union {
        u: u32;
        s: string;
    }
    value: Value_Type;
}

LSP_Hover_Params :: struct {
    textDocument: string;
    position: LSP_Position;
}

LSP_Hover_Result :: struct {
    value: string;
}

LSP_Regular_Expressions_Client_Capabilites :: struct {
    engine: string;
    version: *string;
}

LSP_Log_Message :: struct {
    using notif: LSP_Notification_Message;
    method: string = "window/logMessage";
    params: struct {
        type: u32;
        message: string;
    };
}

LSP_Position :: struct {
    line: u32;
    character: u32;
}

LSP_Range :: struct {
    start: LSP_Position;
    end: LSP_Position;
}

LSP_Text_Document_Position :: struct {
    textDocument: LSP_Text_Document_Identifier;
    position: LSP_Position;
}

LSP_Request_Message_Document_Symbol :: struct {
    using request: LSP_Request_Message;
    params: struct {
        textDocument: LSP_Text_Document_Identifier;
    }
}

LSP_Did_Open_Text_Document :: struct {
    using request: LSP_Request_Message;
    params: struct {
        textDocument: struct {
            uri: string;
            languageID: string;
            version: u32;
            text: string;
        }
    }
}

LSP_Did_Save_Text_Document :: LSP_Did_Open_Text_Document;

LSP_Did_Close_Text_Document :: struct {
    using request: LSP_Request_Message;
    params: struct {
        textDocument: struct {
            uri: string;
        }
    }
}

LSP_Content_Change :: struct {
    range: LSP_Range;
    text: string;
}

LSP_Did_Change_Text_Document :: struct {
    using request: LSP_Request_Message;
    params: struct {
        textDocument: struct {
            uri: string;
            version: u32;
        }

        contentChanges: [] LSP_Content_Change;
    }
}

LSP_Text_Document_Identifier :: struct {
    uri: string;
}

LSP_Versioned_Text_Document_Identifier :: struct {
    using base: LSP_Text_Document_Identifier;
    version: int;
}

LSP_Optinal_Versioned_Text_Document_Identifier :: struct {
    using base: LSP_Text_Document_Identifier;
    version: *int;
}

LSP_Text_Document_Position_Params :: struct {
    textDocument: LSP_Text_Document_Identifier;
    position: LSP_Position;
}

LSP_Document_Filter :: struct {
    language: *string;
    scheme: *string;
    pattern: *string;
}

LSP_Document_Selector :: []LSP_Document_Filter;

/* TextEdit & AnnotatedTextEdit */

LSP_Text_Edit :: struct {
    range: LSP_Range;
    newText: string;
}

LSP_Change_Annotation :: struct {
    label: string;
    needsConfrirmation: *bool;
    description: *string;
}

LSP_Annotation_Text_Edit :: struct {
    using base: LSP_Text_Edit;
    annotationID: string;
}

LSP_Text_Document_Edit :: struct {
    textDocument: LSP_Optinal_Versioned_Text_Document_Identifier;
    edits: [] union {
        textEdit: LSP_Text_Edit;
        annotatedTextEdit: LSP_Annotation_Text_Edit;
    };
}


/* Location */

LSP_Location :: struct {
    uri: string;
    range: LSP_Range;
}

LSP_Location_Link :: struct {
    originSelectionRange: LSP_Range;
    targetUri: string;
    targetRange: LSP_Range;
    targetSelectionRange: LSP_Range;
}

/* Diagnostic */

LSP_Publish_Diagnostics :: struct {
    uri: string;
    diagnostics: []LSP_Diagnostic;
}

LSP_Diagnostic :: struct {
    range: LSP_Range;
    serverity: s64; // *LSP_Diagnostic_Severity;
    // code: *string; // @NOTE: potentionaly int
    // codeDescription: LSP_Code_Description;
    // source: *string;
    message: string;
    // tags: *[]LSP_Diagnostic_Tag; //
    // relatedInformation: *[]LSP_Diagnostic_Related_Information;
    // data: *Any;
}

LSP_Diagnostic_Severity :: enum {
    ERROR;
    WARNING;
    INFORMATION;
    HINT;
}

LSP_Diagnostic_Tag :: enum {
    UNNECESARY;
    DEPRECATED;
}

LSP_Diagnostic_Related_Information :: struct {
    location: LSP_Location;
    message: string;
}

LSP_Code_Description :: struct {
    href: string;
}


/* Command */

LSP_Command :: struct {
    title: string;
    command: string;
    arguments: *[]Any;
}

/* Markup Content */


/* --- @todo: FIX ---
LSP_Markup_Kind :: enum {
    PLAIN_TEXT; @JsonName(plaintext)
    MARKDOWN; @JsonName(markdown)
}

LSP_Markup_Content :: struct {
    kind: LSP_Markup_Kind;
    value: string;
}

LSP_Markdown_Client_Capabilities :: struct {
    parser: string;
    version: *string;
    allowedTags: *[]string;
}
*/


/* File Resource changes*/

LSP_Create_File_Options :: struct {
    overwrite: *bool;
    ignoreIfExists: *bool;
}

LSP_Create_File :: struct {
    kind: string = "create";
    uri: string;
    options: *LSP_Create_File_Options;
    annotationID: *string;
}

LSP_Rename_File_Options :: struct {
    overwrite: *bool;
    ignoreIfExists: *bool;
}

LSP_Rename_File :: struct {
    kind: string = "rename";
    oldUri: string;
    newUri: string;
    options: *LSP_Rename_File_Options;
    annotationID: *string;
}

LSP_Delete_File_Options :: struct {
    recursive: *bool;
    ignoreIfExists: *bool;
}

LSP_Delete_File :: struct {
    kind: string = "delete";
    uri: string;
    options: *LSP_Delete_File_Options;
    annotationID: *string;
}




/* Workspace Edit */

LSP_Workspace_Edit :: struct {
    changes: *JSON_Object; // 🛑 optional { [uri: DocumentUri]: []TextEdit; };
    documentChandes: *JSON_Object; // 🛑 optional []TextDocument | [](TextDocumentEdit | CreateFile | RenameFile | DeleteFile)
    // changeAnnotations: *Hash_Table(string, []LSP_Change_Annotation); // 🛑
}

LSP_Workspace_Edit_Client_Capabilites :: struct {
    documentChandes: *bool;
    resourcesOperatins: *[]LSP_Resource_Operation_Kind;
    failureHandling: *LSP_Failure_Handling_Kind;
    normalizesLineEndings: *bool;
    changeAnnotationsSupport: struct {
        groupsOnLabel: *bool;
    }
}

LSP_Resource_Operation_Kind :: enum {
    CREATE;
    RENAME;
    DELETE;
}

LSP_Failure_Handling_Kind :: enum {
    ABORT;
    TRANSACTION;
    UNDO;
    TEXT_ONLY_TRANSACTIONAL; // 🛑 textOnlyTransactional
}


/* Work Done Progress */

LSP_Work_Done_Progess_Begin :: struct {
    kind: string = "begin";
    title: string;
    cancellable: *bool;
    message: *string;
    precentage: *u8;
}

LSP_Work_Done_Progress_Report :: struct {
    kind: string = "report";
    cancellable: *bool;
    message: *string;
    precentage: *u8;
}

LSP_Work_Done_Progress_Done :: struct {
    kind: string = "end";
    message: *string;
}

LSP_Work_Done_Progess_Params :: struct {
    workDoneToken: string; // 🛑 integer | string;
}

LSP_Work_Done_Progress_Options :: struct {
    workDoneProgress: *bool;
}

LSP_Partial_Result_Params :: struct {
    partialResultToken: string; // 🛑 integer | string;
}


/* Server Lifecycle */
// 📌

LSP_Document_Symbol :: struct {

    Kind :: enum s64 {
        FILE :: 1;
	    MODULE :: 2;
	    NAMESPACE :: 3;
	    PACKAGE :: 4;
	    CLASS :: 5;
	    METHOD :: 6;
	    PROPERTY :: 7;
	    FIELD :: 8;
	    CONSTRUCTOR :: 9;
	    ENUM :: 10;
	    INTERFACE :: 11;
	    FUNCTION :: 12;
	    VARIABLE :: 13;
	    CONSTANT :: 14;
	    STRING :: 15;
	    NUMBER :: 16;
	    BOOLEAN :: 17;
	    ARRAY :: 18;
	    OBJECT :: 19;
	    KEY :: 20;
	    NULL :: 21;
	    ENUMMEMBER :: 22;
	    STRUCT :: 23;
	    EVENT :: 24;
	    OPERATOR :: 25;
	    TYPEPARAMETER :: 26;
    }

    name: string;
    kind: s64;
    range: LSP_Range;
    selectionRange: LSP_Range;
    children: []LSP_Document_Symbol;
}

LSP_Symbol_Kind :: enum s64 {
    FILE :: 1;
    MODULE :: 2;
    NAMESPACE :: 3;
    PACKAGE :: 4;
    CLASS :: 5;
    METHOD :: 6;
    PROPERTY :: 7;
    FIELD :: 8;
    CONSTRUCTOR :: 9;
    ENUM :: 10;
    INTERFACE :: 11;
    FUNCTION :: 12;
    VARIABLE :: 13;
    CONSTANT :: 14;
    STRING :: 15;
    NUMBER :: 16;
    BOOLEAN :: 17;
    ARRAY :: 18;
    OBJECT :: 19;
    KEY :: 20;
    NULL :: 21;
    ENUMMEMBER :: 22;
    STRUCT :: 23;
    EVENT :: 24;
    OPERATOR :: 25;
    TYPEPARAMETER :: 26;
}

Workspace_Folder :: struct {
    uri: string;
    name: string;
}

LSP_Request_Message_Initialize :: struct {
    using request: LSP_Request_Message;
    params: struct {
        clientInfo: struct {
            name: string;
            version: string;
        };

        rootPath: *string;
        rootUri: *string;
        workspaceFolders: *[]Workspace_Folder;
    }
}

LSP_Result_Initialize :: struct {
    capabilities: struct {
        // semanticTokensProvider := true;
        // documentSymbolProvider := true;

        definitionProvider := true;
        // hoverProvider := true;

        signatureHelpProvider: struct {
            triggerCharacters   := string.["("];
            retriggerCharacters := string.[","];
        }

        completionProvider: struct {
            triggerCharacters := string.[".", ":", "=", "\"", "#", "/"];
        };

        textDocumentSync: struct {
            openClose := true;
            save := true;
            change := 2;
        };
    };

    serverInfo: struct {
        name := "Jails";
        version := VERSION;
    };
}

LSP_Request_Message_Definition :: struct {
    using request: LSP_Request_Message;
    params: LSP_Text_Document_Position;
}

LSP_Request_Message_Hover :: struct {
    using request: LSP_Request_Message;
    params: LSP_Text_Document_Position;
}

LSP_Request_Message_Completion :: struct {
    using request: LSP_Request_Message;
    params: struct {
        using base: LSP_Text_Document_Position;
        _context: struct {
            triggerKind: enum {
                Invoked :: 1;
                TriggerCharacter :: 2;
                TriggerForIncompleteCompletions :: 3;
            }
            triggerCharacter: string;
        } @JsonName(context)
    }
}

LSP_Request_Message_Signature_Help :: struct {
    using request: LSP_Request_Message;
    params: struct {
        using base: LSP_Text_Document_Position;
        _context: struct {
            triggerKind: enum {
                Invoked :: 1;
                TriggerCharacter :: 2;
                ContentChange :: 3;
            }
            triggerCharacter: string;
            isRetrigger: bool;
            activeSignatureHelp: *LSP_Signature_Help;
        } @JsonName(context)
    }
}

LSP_Signature_Help :: struct {
    signatures: []LSP_Signature_Information;
    activeSignature: u32;
    activeParameter: u32;
}

LSP_Signature_Information :: struct {
    label: string;
    documentation: string;
    parameters: []LSP_Parameter_Information;
    activeParameter: u32;
}

LSP_Parameter_Information :: struct {
    label: string;
    documentation: string;
}

LSP_Completion_Item :: struct {
    label: string;
    detail: string;
    insertText: string;
    documentation: string;
    deprecated: bool;

    labelDetails: struct {
        detail: string;
        description: string;
    };

    Insert_Text_Format :: enum u8 {
        PLAIN_TEXT :: 1;
        SNIPPET :: 2;
    }

    insertTextFormat: u8 = xx Insert_Text_Format.PLAIN_TEXT;

    kind: u8;

    Kind :: enum u8 {
        Text :: 1;
        Method :: 2;
        Function :: 3;
        Constructor :: 4;
        Field :: 5;
        Variable :: 6;
        Class :: 7;
        Interface :: 8;
        Module :: 9;
        Property :: 10;
        Unit :: 11;
        Value :: 12;
        Enum :: 13;
        Keyword :: 14;
        Snippet :: 15;
        Color :: 16;
        File :: 17;
        Reference :: 18;
        Folder :: 19;
        EnumMember :: 20;
        Constant :: 21;
        Struct :: 22;
        Event :: 23;
        Operator :: 24;
        TypeParameter :: 25;
    };
}

LSP_Hover :: struct {
    contents: string;
    contentFormat:= "markdown";
}

LSP_Folding_Range_Client_Capabilities :: struct {
    dynamicRegistration: *bool;
    rangeLimit: *u32;
    lineFoldingOnly: *bool;
    foldingRangeKind: LSP_Folding_Range_Kind;
    foldingRange: struct{
        collapsedText: *bool;
    }
}

LSP_Folding_Range_Options :: struct {
    //using base: LSP_Work_Done_Progress_Options;
}

LSP_Folding_Range_Registration_Options :: struct {
    //using textDocumentRegistrationOptions: LSP_Text_Document_Registration_Options;
    //using foldingRangeOptions: LSP_Folding_range_Options;
    //using staticRegistrationOptions: LSP_Static_Registration_Options;
}

LSP_Folding_Range_Params :: struct {
    //using workDoneProgressParams: LSP_Work_Done_Progress_Params;
    //using partialResultParams: LSP_Partial_Result_Params;
    //textDocument: LSP_Text_Document_Identifier;
}

LSP_Folding_Range_Kind :: enum {
    Comment;
    Imports;
    Region;
}

LSP_Folding_Range :: struct {
    startLine: u32;
    startCharacter: *u32;
    endLine: u32;
    endCharacter: *u32;
    kind: *LSP_Folding_Range_Kind;
    collapsedText: *string;
}

LSP_Selection_Range_Client_Capabilities :: struct {
    dynamicRegistration: *bool;
}

LSP_Selection_Range_Options :: struct {
    //using base: LSP_Work_Done_Progress_Options;
}

LSP_Selection_Range_Registration_Options :: struct {
    using selectionRangeOptions: LSP_Selection_Range_Options;
    //using textDocumentRegistrationOptions: LSP_Text_Document_Registration_Options;
    //using staticRegistrationOptions: LSP_Static_Registration_Options;
}

LSP_Selection_Range_Params :: struct {
    //using workDoneProgressParams: LSP_Work_Done_Progress_Params;
    //using partialResultParams: LSP_Partial_Result_Params;
    //textDocument: LSP_Text_Document_Identifier;
    positions: []LSP_Position;
}

LSP_Selection_Range :: struct {
    range: LSP_Range;
    parent: *LSP_Selection_Range;
}

LSP_Document_Symbol_Client_Capabilities :: struct {
    dynamicRegistration: *bool;
    symbolKind: struct {
        valueSet: *[]s64;
    }
    hierarchicalDocumentSymbolSupport: *bool;
    tagSupport: struct {
        valueSet: *[]s64;
    }
    labelSupport: *bool;
}

LSP_Document_Symbol_Options :: struct {
    //using workDoneProgressOptions: LSP_Work_Done_Progress_Options;
    label: *string;
}

LSP_Document_Symbol_Registration_Options :: struct {
    //using textDocumentRegistrationOptions: LSP_Text_Document_Registration_Options;
    //using documentSymbolOptions: LSP_Document_Symbol_Options;
}

LSP_Document_Symbol_Params :: struct {
    //using workDoneProgressParams: LSP_Work_Done_Progress_Params;
    //using partialResultParams: LSP_Partial_Result_Params;
    //textDocument: LSP_Text_Document_Identifier;
}

lsp_log :: (message : string, data : *void, info : Log_Info) {
    sent_log: LSP_Log_Message = .{};
    sent_log.params.message = message;

    if message.data[message.count - 1] == #char "\n" then sent_log.params.message.count -= 1;

    if info.common_flags == {
        case .ERROR;
            sent_log.params.type = 1;
        case .WARNING;
            sent_log.params.type = 2;
        case .VERBOSE_ONLY;
            sent_log.params.type = 4;
        case;
            sent_log.params.type = 3;
    }

    lsp_send(sent_log);
}

lsp_send :: (data: $T) {
    body := json_write_string(data);
    defer free(body);
    print("Content-Length: %\r\n\r\n%", body.count, body);
}

lsp_respond :: (id: u32, data: $T) {
    Full_Reply :: struct {
        using response: LSP_Response_Message;
        result: T;
    }

    lsp_send(Full_Reply.{
        response.id=id,
        result=data,
    });
}

lsp_respond_with_error :: (id: u32, code: LSP_Error_Codes, message: string, data: $T) {
    reply: struct {
        using response: LSP_Response_Message;
        error: LSP_Response_Error(T);
    };

    reply.id = id;
    reply.error = .{code, message, data};
    lsp_send(reply);
}
