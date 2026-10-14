// Requests about a document, answered from the snapshot of the check that read
// its current text: hover, go-to-definition, and document symbols here,
// completion and signature help in `editing.odin`, references and rename in
// `rename.odin`, and generated documentation in `tools.odin`. A request waits
// until its document's root has been checked since the last edit, and one that
// reads every program waits for every root;
// a result the compiler did not record is answered as `null`, never guessed
// from the text.
package lsp

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

import lokec "../src"

// The document changed after the request arrived, so its position may no
// longer mean what the client meant.
CONTENT_MODIFIED :: -32801

// Long type declarations are cut to this many lines in a hover.
HOVER_LINES :: 24

Request_Kind :: enum {
	Hover, Definition, Document_Symbol, Completion, Signature_Help,
	References, Prepare_Rename, Rename, Documentation,
}

Pending_Request :: struct {
	id:       json.Value, // an owned copy
	kind:     Request_Kind,
	key:      string,     // the document's path key
	revision: int,        // the document's text when the request arrived
	position: Position,
	include_declaration: bool,   // for references
	new_name: string,            // for rename; owned
}

// Requests that read every program the server checks, not only the
// document's own.
@(private = "file")
reads_every_root :: proc(kind: Request_Kind) -> bool {
	return kind == .References || kind == .Rename
}

queue_request :: proc(s: ^Server, id: json.Value, kind: Request_Kind, params: json.Value) {
	queue_document_request(s, id, kind, find_document(s, member(params, "textDocument")), params)
}

queue_document_request :: proc(s: ^Server, id: json.Value, kind: Request_Kind, doc: ^Document, params: json.Value) {
	if doc == nil {
		// Only open documents have a checked text the client agrees on.
		send_result(s, id, "null")
		return
	}
	request := Pending_Request{kind = kind, key = strings.clone(doc.key), revision = doc.revision}
	request.id = id
	if text, is_text := id.(json.String); is_text { request.id = json.String(strings.clone(text)) }
	if kind != .Document_Symbol && kind != .Documentation { request.position = json_position(member(params, "position")) }
	request.include_declaration = member_bool(member(params, "context"), "includeDeclaration")
	if name, named := member_string(params, "newName"); named { request.new_name = strings.clone(name) }
	append(&s.pending, request)
}

// A `$/cancelRequest` for a request still waiting for its check.
cancel_request :: proc(s: ^Server, id: json.Value) {
	key := id_key(id)
	for request, index in s.pending {
		if id_key(request.id) != key { continue }
		send_error(s, request.id, REQUEST_CANCELLED, "the request was cancelled")
		destroy_request(request)
		ordered_remove(&s.pending, index)
		return
	}
}

// At `shutdown`, nothing still waiting will be checked.
cancel_all_requests :: proc(s: ^Server) {
	for request in s.pending {
		send_error(s, request.id, REQUEST_CANCELLED, "the server is shutting down")
		destroy_request(request)
	}
	clear(&s.pending)
}

destroy_request :: proc(request: Pending_Request) {
	if text, is_text := request.id.(json.String); is_text { delete(text) }
	delete(request.key)
	delete(request.new_name)
}

// The dirty root a waiting request needs, checked before any other.
requested_root :: proc(s: ^Server) -> ^Root {
	for request in s.pending {
		if doc := s.documents[request.key]; doc != nil && doc.revision == request.revision && doc.root != nil && doc.root.dirty {
			return doc.root
		}
	}
	return nil
}

// Answers every waiting request whose document's root is checked, and every
// request whose document changed or closed since it arrived.
answer_requests :: proc(s: ^Server) {
	if s.layout_dirty { return }
	for index := 0; index < len(s.pending); {
		request := s.pending[index]
		doc := s.documents[request.key]
		switch {
		case doc == nil || doc.revision != request.revision:
			send_error(s, request.id, CONTENT_MODIFIED, "the document changed before the request was answered")
		case doc.root == nil || doc.root.dirty || (reads_every_root(request.kind) && any_root_dirty(s)):
			index += 1
			continue
		case:
			answer(s, request, doc)
		}
		destroy_request(request)
		ordered_remove(&s.pending, index)
	}
}

@(private = "file")
any_root_dirty :: proc(s: ^Server) -> bool {
	for _, root in s.roots { if root.dirty { return true } }
	return false
}

@(private = "file")
answer :: proc(s: ^Server, request: Pending_Request, doc: ^Document) {
	if request.kind == .Documentation {
		answer_documentation(s, request, doc)
		return
	}
	session := &doc.root.session
	snapshot, captured := lokec.session_snapshot(session)
	file, loaded := lokec.query_file(session, snapshot, doc.path)
	source, found := lokec.query_source(session, snapshot, file)
	// The root's program may not read this document at all, as when it is
	// excluded from its package; then nothing about it is known.
	if !captured || !loaded || !found || source.text != doc.text {
		send_result(s, request.id, "null")
		return
	}
	result := "null"
	switch request.kind {
	case .Hover:
		if at, ok := symbol_at(s, session, snapshot, file, doc.text, request.position); ok {
			result = hover(s, session, at)
		}
	case .Definition:
		if at, ok := symbol_at(s, session, snapshot, file, doc.text, request.position); ok {
			if location, defined := lokec.query_definition(session, at.symbol); defined {
				if path, range, placed := place(s, session, snapshot, location, context.temp_allocator); placed {
					b := strings.builder_make(context.temp_allocator)
					write_location(s, &b, path, range)
					result = strings.to_string(b)
				}
			}
		}
	case .Document_Symbol:
		result = document_symbols(s, session, snapshot, file, doc)
	case .Completion:
		result = completion(s, session, snapshot, file, doc.text, request.position)
	case .Signature_Help:
		result = signature_help(s, session, snapshot, file, doc.text, request.position)
	case .References:
		result = references(s, session, snapshot, file, doc.text, request.position, request.include_declaration)
	case .Prepare_Rename, .Rename:
		failure: string
		if request.kind == .Rename {
			result, failure = rename(s, session, snapshot, file, doc.text, request.position, request.new_name)
		} else {
			result, failure = prepare_rename(s, session, snapshot, file, doc.text, request.position)
		}
		if failure != "" {
			send_error(s, request.id, REQUEST_FAILED, failure)
			return
		}
	case .Documentation:
		// Answered before the snapshot is consulted.
	}
	send_result(s, request.id, result)
}

// The binding written at `position`, or just before it: a cursor placed at the
// end of a name still means that name.
symbol_at :: proc(s: ^Server, session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file: u32, text: string, position: Position) -> (lokec.Query_Position, bool) {
	offset := position_to_offset(text, position, s.utf8_positions)
	if at, found := lokec.query_at(session, snapshot, file, u32(offset)); found && at.symbol.id != lokec.INVALID_SYMBOL {
		return at, true
	}
	if offset > 0 && is_name_byte(text[offset - 1]) {
		if at, found := lokec.query_at(session, snapshot, file, u32(offset - 1)); found && at.symbol.id != lokec.INVALID_SYMBOL {
			return at, true
		}
	}
	return {}, false
}

is_name_byte :: proc(b: byte) -> bool {
	return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

// The binding's declaration as code, then the comments written above it.
@(private = "file")
hover :: proc(s: ^Server, session: ^lokec.Compilation_Session, at: lokec.Query_Position) -> string {
	symbol, found := lokec.query_symbol(session, at.symbol)
	if !found { return "null" }
	text := declaration_text(session, symbol)
	documentation, documented := lokec.query_documentation(session, at.symbol, context.temp_allocator)
	value: string
	if s.markdown_hover {
		value = fmt.tprintf("```loke\n%s\n```", text)
		if documented { value = fmt.tprintf("%s\n\n%s", value, documentation) }
	} else {
		value = text
		if documented { value = fmt.tprintf("%s\n\n%s", value, documentation) }
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"contents":{{"kind":"%s","value":`, s.markdown_hover ? "markdown" : "plaintext")
	write_json_string(&b, value)
	strings.write_string(&b, "}")
	snapshot := lokec.Compilation_Snapshot{at.location.snapshot}
	if _, range, placed := place(s, session, snapshot, at.location, context.temp_allocator); placed {
		strings.write_string(&b, `,"range":`)
		write_range(&b, range)
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// How a binding reads in a hover. A procedure shows its signature, a type or
// constant its declaration, and anything else its name and recorded type.
@(private = "file")
declaration_text :: proc(session: ^lokec.Compilation_Session, symbol: lokec.Query_Symbol) -> string {
	#partial switch symbol.kind {
	case .Proc, .Proc_Group:
		signatures, _ := lokec.query_signatures(session, symbol.handle)
		lines := make([dynamic]string, context.temp_allocator)
		for signature in signatures {
			name := symbol.name
			if member, found := lokec.query_symbol(session, signature.symbol); found { name = member.name }
			append(&lines, fmt.tprintf("%s :: %s", name, signature.text))
		}
		if len(lines) > 0 { return strings.join(lines[:], "\n", context.temp_allocator) }
	case .Type, .Const:
		if written, found := written_text(session, symbol.extent); found {
			lines := strings.split_lines(written, context.temp_allocator)
			if symbol.kind == .Type && len(lines) > HOVER_LINES {
				return fmt.tprintf("%s\n\t...", strings.join(lines[:HOVER_LINES], "\n", context.temp_allocator))
			}
			if symbol.kind == .Type || len(lines) == 1 { return written }
		}
	case .Package_Alias:
		return fmt.tprintf("package %s", symbol.name)
	}
	if type, found := lokec.query_type(session, symbol.type); found && type.name != "" && symbol.kind != .Type {
		return fmt.tprintf("%s: %s", symbol.name, type.name)
	}
	return symbol.name
}

// The source text of a location, without the `;` that ends a statement.
@(private = "file")
written_text :: proc(session: ^lokec.Compilation_Session, location: lokec.Query_Location) -> (string, bool) {
	span := location.span
	if span.file == lokec.NO_FILE { return "", false }
	source, found := lokec.query_source(session, lokec.Compilation_Snapshot{location.snapshot}, span.file)
	if !found || int(span.hi) > len(source.text) || span.lo >= span.hi { return "", false }
	return strings.trim_right(strings.trim_space(source.text[span.lo:span.hi]), ";"), true
}

// LSP `SymbolKind` values.
@(private = "file")
Lsp_Symbol_Kind :: enum {
	Class = 5, Field = 8, Enum = 10, Interface = 11, Function = 12, Variable = 13,
	Constant = 14, Enum_Member = 22, Struct = 23,
}

// The kind as the client can show it: the kinds after `Array` have an older
// equivalent for clients that do not list them.
@(private = "file")
client_kind :: proc(s: ^Server, kind: Lsp_Symbol_Kind) -> int {
	if int(kind) in s.symbol_kinds { return int(kind) }
	#partial switch kind {
	case .Struct:      return int(Lsp_Symbol_Kind.Class)
	case .Enum_Member: return int(Lsp_Symbol_Kind.Constant)
	}
	return int(kind)
}

@(private = "file")
Outline_Entry :: struct {
	symbol:   lokec.Query_Symbol,
	kind:     Lsp_Symbol_Kind,
	detail:   string,
	range, selection: Range,
	children: [dynamic]int,
	nested:   bool,
}

// The file's package-level declarations, with the fields of its records and the
// members of its enums inside them. Parameters and locals are left out.
@(private = "file")
document_symbols :: proc(s: ^Server, session: ^lokec.Compilation_Session, snapshot: lokec.Compilation_Snapshot, file: u32, doc: ^Document) -> string {
	handles, _ := lokec.query_symbols(session, snapshot, file)
	entries := make([dynamic]Outline_Entry, context.temp_allocator)
	slot_of := make(map[lokec.Symbol_Id]int, context.temp_allocator)
	for handle in handles {
		symbol, found := lokec.query_symbol(session, handle)
		if !found || symbol.extent.span.file != file || inside_procedure(session, symbol) { continue }
		kind, listed := outline_kind(session, symbol)
		if !listed { continue }
		_, range, _ := place(s, session, snapshot, symbol.extent, context.temp_allocator)
		_, selection, _ := place(s, session, snapshot, symbol.definition, context.temp_allocator)
		slot_of[handle.id] = len(entries)
		append(&entries, Outline_Entry{
			symbol = symbol, kind = kind, detail = symbol_detail(session, symbol),
			range = range, selection = selection, children = make([dynamic]int, context.temp_allocator),
		})
	}
	for &entry, index in entries {
		if parent, found := slot_of[entry.symbol.parent.id]; found && entry.symbol.parent.id != lokec.INVALID_SYMBOL {
			append(&entries[parent].children, index)
			entry.nested = true
		}
	}
	top := make([dynamic]int, context.temp_allocator)
	for entry, index in entries { if !entry.nested { append(&top, index) } }
	b := strings.builder_make(context.temp_allocator)
	if s.hierarchical_symbols {
		write_symbol_list(s, &b, entries[:], top[:])
	} else {
		strings.write_byte(&b, '[')
		first := true
		write_symbol_information(s, &b, entries[:], top[:], doc, "", &first)
		strings.write_byte(&b, ']')
	}
	return strings.to_string(b)
}

// Parameters, locals, and anything declared in a procedure body.
@(private = "file")
inside_procedure :: proc(session: ^lokec.Compilation_Session, symbol: lokec.Query_Symbol) -> bool {
	current := symbol
	for _ in 0 ..< 64 {
		if current.parent.id == lokec.INVALID_SYMBOL { return false }
		parent, found := lokec.query_symbol(session, current.parent)
		if !found { return false }
		if parent.kind == .Proc || parent.kind == .Proc_Group { return true }
		current = parent
	}
	return true
}

@(private = "file")
outline_kind :: proc(session: ^lokec.Compilation_Session, symbol: lokec.Query_Symbol) -> (Lsp_Symbol_Kind, bool) {
	#partial switch symbol.kind {
	case .Proc, .Proc_Group: return .Function, true
	case .Var:               return .Variable, true
	case .Const:             return .Constant, true
	case .Field:             return .Field, true
	case .Enum_Member:       return .Enum_Member, true
	case .Type:
		type, _ := lokec.query_type(session, symbol.type)
		#partial switch type.kind {
		case .Struct:    return .Struct, true
		case .Enum:      return .Enum, true
		case .Interface: return .Interface, true
		}
		return .Class, true
	}
	return {}, false
}


@(private = "file")
sort_by_position :: proc(entries: []Outline_Entry, slots: []int) {
	context.user_ptr = raw_data(entries)
	slice.sort_by(slots, proc(a, b: int) -> bool {
		entries := ([^]Outline_Entry)(context.user_ptr)
		x, y := entries[a].range.start, entries[b].range.start
		return x.line < y.line || (x.line == y.line && x.character < y.character)
	})
}

// `DocumentSymbol[]`.
@(private = "file")
write_symbol_list :: proc(s: ^Server, b: ^strings.Builder, entries: []Outline_Entry, slots: []int) {
	sort_by_position(entries, slots)
	strings.write_byte(b, '[')
	for slot, index in slots {
		entry := entries[slot]
		if index > 0 { strings.write_byte(b, ',') }
		strings.write_string(b, `{"name":`)
		write_json_string(b, entry.symbol.name)
		if entry.detail != "" {
			strings.write_string(b, `,"detail":`)
			write_json_string(b, entry.detail)
		}
		fmt.sbprintf(b, `,"kind":%d,"range":`, client_kind(s, entry.kind))
		write_range(b, entry.range)
		strings.write_string(b, `,"selectionRange":`)
		write_range(b, entry.selection)
		if len(entry.children) > 0 {
			strings.write_string(b, `,"children":`)
			write_symbol_list(s, b, entries, entry.children[:])
		}
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}

// `SymbolInformation[]`, for a client without hierarchical symbols: the same
// entries, each naming its container.
@(private = "file")
write_symbol_information :: proc(s: ^Server, b: ^strings.Builder, entries: []Outline_Entry, slots: []int, doc: ^Document, container: string, first: ^bool) {
	sort_by_position(entries, slots)
	for slot in slots {
		entry := entries[slot]
		if !first^ { strings.write_byte(b, ',') }
		first^ = false
		strings.write_string(b, `{"name":`)
		write_json_string(b, entry.symbol.name)
		fmt.sbprintf(b, `,"kind":%d,"location":`, client_kind(s, entry.kind))
		write_location(s, b, doc.path, entry.range)
		if container != "" {
			strings.write_string(b, `,"containerName":`)
			write_json_string(b, container)
		}
		strings.write_byte(b, '}')
		write_symbol_information(s, b, entries, entry.children[:], doc, entry.symbol.name, first)
	}
}

write_location :: proc(s: ^Server, b: ^strings.Builder, path: string, range: Range) {
	strings.write_string(b, `{"uri":`)
	write_json_string(b, uri_for(s, path_key(path, context.temp_allocator), path))
	strings.write_string(b, `,"range":`)
	write_range(b, range)
	strings.write_byte(b, '}')
}
