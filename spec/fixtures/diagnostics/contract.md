# Structured Lua diagnostics, version 1

A trace is `{schemaVersion:1, captureKind:'exception'|'callsite', status:'complete'|'partial'|'failed', frames?:Frame[], reasons?:string[]}`. Arrays are omitted when empty (Lua encoders disagree about empty tables). Frames are innermost first. Reasons are unique machine codes. Unknown optional fields are omitted.

Frame: `{kind:'lua'|'native'|'main'|'tail'|'unknown', source?:{kind:'file'|'chunk'|'template',name:string}, line?:number, definitionLine?:number, functionName?:string, nameOrigin?:'registered'|'debug'|'inferred', role?:'driver'|'sdk'|'runtime', locals?:Local[]}`. Positive line numbers only. Native frames have no source. Collector internals and native error/assert at the throw boundary are omitted; useful SDK boundary frames remain.

Local: `{name:string, value:Value}`. Value is a tagged union:

* nil: `{type:'nil'}`
* boolean: `{type:'boolean',value:boolean}`
* number: `{type:'number',value:number|'nan'|'positive_infinity'|'negative_infinity'}`
* string: `{type:'string',value:string,encoding?:'hex',originalBytes?:number,truncated?:true,reason?:string}`. Invalid UTF-8/binary strings encode as hex. originalBytes is raw byte length, before capture truncation.
* table: `{type:'table',id:number,knownName?:string,entries?:{key:Value,value:Value}[],truncated?:true,reason?:string}`. IDs scoped to trace. Repeated identity values (tables, functions, userdata, threads, cdata): `{type:'reference',ref:number}`. Omission count is deliberately not computed by traversing an exhausted table.
* function: `{type:'function',id:number,functionName?:string,source?:Source,definitionLine?:number}`
* userdata/thread/cdata: `{type:'userdata'|'thread'|'cdata',id:number}`. No address strings or metamethod execution.
* unknown/omitted: `{type:'unavailable',reason:string}`.

Limits: 512 raw bytes/string; table depth 3; 20 entries/table; 64 frames; 64 locals/frame; 1024 value nodes/trace; 8192 captured string bytes/trace. Strings and metadata are charged against the same string budget. Reasons: string_limit, string_budget, depth_limit, entry_limit, node_limit, frame_limit, local_limit, capture_failed, payload_limit, unsupported_type. Truncation changes trace status to partial. UTF-8 prefixes end on complete characters. Raw inspection must not invoke user metamethods. Aggregate encoded trace budget is 256 KiB; collector must stop collection before exceeding it using conservative accounting (JSON escaping and metadata included).

Error envelope retains its existing value/type/event/correlation fields. No client fingerprint. Both ingestion transports compute fingerprint from type and first 3 relevant frames (exclude sdk role, native and tail frames), using canonical tuples [source.kind,source.name,line,definitionLine,functionName]. Ignore locals, runtime IDs and display. Fallback: normalized error message (digit runs replaced by N). One server implementation. UI has no legacy format support and generates all presentation from fields.
