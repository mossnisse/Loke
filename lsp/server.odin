// Protocol state, message dispatch, and open documents. Everything here runs
// on one thread; `main.odin` feeds it messages and calls `run_pending_work`
// between them.
package lsp

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"
import "core:time"

import lokec "../src"

SERVER_NAME :: "loke-lsp"

// JSON-RPC and LSP error codes.
PARSE_ERROR            :: -32700
INVALID_REQUEST        :: -32600
METHOD_NOT_FOUND       :: -32601
SERVER_NOT_INITIALIZED :: -32002
REQUEST_CANCELLED      :: -32800

// TextDocumentSyncKind.Full: every change carries the whole text.
SYNC_FULL :: 1

Phase :: enum { Uninitialized, Running, Shutdown }

Server :: struct {
	// Receives each framed outgoing message whole.
	write:      proc(data: rawptr, message: string),
	write_data: rawptr,
	phase:      Phase,
	exited:     bool,
	exit_code:  int,
	// Negotiated client capabilities.
	utf8_positions, related_information, watch_files: bool,
	markdown_hover, hierarchical_symbols: bool,
	symbol_kinds: bit_set[0 ..< 64], // `SymbolKind` values the client shows
	completion_kinds: bit_set[0 ..< 64], // `CompletionItemKind` values it shows
	markdown_completion, label_offsets, prepare_rename: bool,
	config:       lokec.Compilation_Config,
	config_arena: virtual.Arena,
	documents:    map[string]^Document, // by path key
	roots:        map[string]^Root,     // by path key
	published:    map[string]Published, // by path key
	scans:        map[string]map[string]bool, // in `scan_arena`
	scan_arena:   virtual.Arena,
	last_edit:    time.Tick,
	layout_dirty, publish_due: bool,
	// Requests waiting for their document's root to be checked, in arrival order.
	pending:      [dynamic]Pending_Request,
	// Counts document opens and edits, so a request can tell its text changed.
	revision:     int,
}

// An open `.loke` document. Its text is an overlay in every root's session.
Document :: struct {
	uri, path, key, text: string,
	version:  i64,
	revision: int,
	root:     ^Root,
}

// What the client last received for a file.
Published :: struct { uri, params: string }

init_server :: proc(s: ^Server, write: proc(data: rawptr, message: string), write_data: rawptr) {
	s.write, s.write_data = write, write_data
	s.config = lokec.DEFAULT_COMPILATION_CONFIG
}

destroy_server :: proc(s: ^Server) {
	for request in s.pending { destroy_request(request) }
	delete(s.pending)
	for _, root in s.roots { destroy_root(root) }
	delete(s.roots)
	for _, doc in s.documents { destroy_document(doc) }
	delete(s.documents)
	for key, published in s.published {
		delete(key)
		delete(published.uri)
		delete(published.params)
	}
	delete(s.published)
	clear_directory_scans(s)
	virtual.arena_destroy(&s.config_arena)
	s^ = {}
}

// Handles one batch of message bodies in order. A `$/cancelRequest` cancels a
// request anywhere in its batch; a request already answered is unaffected.
handle_messages :: proc(s: ^Server, bodies: []string) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	messages := make([dynamic]json.Value, allocator)
	cancelled := make(map[string]bool, allocator)
	for body in bodies {
		// Unparsable bodies stay nil, so their errors keep their place in order.
		value, err := json.parse_string(body, parse_integers = true, allocator = allocator)
		if err != nil { value = nil }
		if method, _ := member_string(value, "method"); method == "$/cancelRequest" {
			cancelled[id_key(member(member(value, "params"), "id"))] = true
		}
		append(&messages, value)
	}
	for message in messages {
		if message == nil {
			send_error(s, nil, PARSE_ERROR, "the message is not valid JSON")
		} else {
			dispatch(s, message, cancelled)
		}
		if s.exited { return }
	}
}

@(private = "file")
dispatch :: proc(s: ^Server, message: json.Value, cancelled: map[string]bool) {
	object, is_object := message.(json.Object)
	if !is_object {
		send_error(s, nil, INVALID_REQUEST, "a message is a JSON object")
		return
	}
	method, has_method := object["method"].(json.String)
	id, has_id := object["id"]
	params := object["params"]
	switch {
	case !has_method:
		// A response to one of our requests; none needs an answer.
	case has_id && cancelled[id_key(id)]:
		send_error(s, id, REQUEST_CANCELLED, "the request was cancelled")
	case has_id:
		handle_request(s, id, method, params)
	case:
		handle_notification(s, method, params)
	}
}

@(private = "file")
handle_request :: proc(s: ^Server, id: json.Value, method: string, params: json.Value) {
	switch {
	case method == "initialize" && s.phase == .Uninitialized:
		initialize(s, id, params)
	case method == "initialize":
		send_error(s, id, INVALID_REQUEST, "initialize was already received")
	case s.phase == .Uninitialized:
		send_error(s, id, SERVER_NOT_INITIALIZED, "the server is not initialized")
	case s.phase == .Shutdown:
		send_error(s, id, INVALID_REQUEST, "the server is shutting down")
	case method == "shutdown":
		// Pending checks are dropped: nothing published now would be read.
		s.phase = .Shutdown
		cancel_all_requests(s)
		send_result(s, id, "null")
	case method == "textDocument/hover":
		queue_request(s, id, .Hover, params)
	case method == "textDocument/definition":
		queue_request(s, id, .Definition, params)
	case method == "textDocument/documentSymbol":
		queue_request(s, id, .Document_Symbol, params)
	case method == "textDocument/completion":
		queue_request(s, id, .Completion, params)
	case method == "textDocument/signatureHelp":
		queue_request(s, id, .Signature_Help, params)
	case method == "textDocument/references":
		queue_request(s, id, .References, params)
	case method == "textDocument/prepareRename":
		queue_request(s, id, .Prepare_Rename, params)
	case method == "textDocument/rename":
		queue_request(s, id, .Rename, params)
	case:
		send_error(s, id, METHOD_NOT_FOUND, fmt.tprintf("unsupported request `%s`", method))
	}
}

@(private = "file")
handle_notification :: proc(s: ^Server, method: string, params: json.Value) {
	if method == "exit" {
		s.exited, s.exit_code = true, s.phase == .Shutdown ? 0 : 1
		return
	}
	// Before `initialize` and after `shutdown`, notifications are dropped.
	if s.phase != .Running { return }
	switch method {
	case "$/cancelRequest":
		cancel_request(s, member(params, "id"))
	case "initialized":
		if s.watch_files { register_watchers(s) }
	case "textDocument/didOpen":
		did_open(s, params)
	case "textDocument/didChange":
		did_change(s, params)
	case "textDocument/didClose":
		did_close(s, params)
	case "textDocument/didSave":
		did_save(s, params)
	case "workspace/didChangeWatchedFiles":
		// Disk changed under the sessions: new or deleted files, manifests,
		// imports. Every root rebuilds (compiler-architecture.md
		// "Invalidation rules").
		for _, root in s.roots { lokec.invalidate_session(&root.session) }
		documents_changed(s, rescan = true)
	}
}

@(private = "file")
initialize :: proc(s: ^Server, id: json.Value, params: json.Value) {
	capabilities := member(params, "capabilities")
	for encoding in member_array(member(capabilities, "general"), "positionEncodings") {
		if name, ok := encoding.(json.String); ok && name == "utf-8" { s.utf8_positions = true }
	}
	s.related_information = member_bool(member(member(capabilities, "textDocument"), "publishDiagnostics"), "relatedInformation")
	s.watch_files = member_bool(member(member(capabilities, "workspace"), "didChangeWatchedFiles"), "dynamicRegistration")
	for format in member_array(member(member(capabilities, "textDocument"), "hover"), "contentFormat") {
		if name, ok := format.(json.String); ok && name == "markdown" { s.markdown_hover = true }
	}
	symbols := member(member(capabilities, "textDocument"), "documentSymbol")
	s.hierarchical_symbols = member_bool(symbols, "hierarchicalDocumentSymbolSupport")
	// Without a list, a client is only known to show `File` through `Array`.
	s.symbol_kinds = {}
	for kind in 1 ..= 18 { s.symbol_kinds += {kind} }
	if kinds := member(symbols, "symbolKind"); member(kinds, "valueSet") != nil {
		s.symbol_kinds = {}
		for kind in member_array(kinds, "valueSet") {
			if value, ok := kind.(json.Integer); ok && value >= 0 && value < 64 { s.symbol_kinds += {int(value)} }
		}
	}
	completion := member(member(capabilities, "textDocument"), "completion")
	for format in member_array(member(completion, "completionItem"), "documentationFormat") {
		if name, ok := format.(json.String); ok && name == "markdown" { s.markdown_completion = true }
	}
	// Without a list, `Text` through `Reference`.
	s.completion_kinds = {}
	for kind in 1 ..= 18 { s.completion_kinds += {kind} }
	if kinds := member(completion, "completionItemKind"); member(kinds, "valueSet") != nil {
		s.completion_kinds = {}
		for kind in member_array(kinds, "valueSet") {
			if value, ok := kind.(json.Integer); ok && value >= 0 && value < 64 { s.completion_kinds += {int(value)} }
		}
	}
	signature := member(member(member(member(capabilities, "textDocument"), "signatureHelp"), "signatureInformation"), "parameterInformation")
	s.label_offsets = member_bool(signature, "labelOffsetSupport")
	s.prepare_rename = member_bool(member(member(capabilities, "textDocument"), "rename"), "prepareSupport")

	folder := ""
	if folders := member_array(params, "workspaceFolders"); len(folders) > 0 {
		if uri, ok := member_string(folders[0], "uri"); ok { folder, _ = uri_to_path(uri, context.temp_allocator) }
	} else if uri, ok := member_string(params, "rootUri"); ok {
		folder, _ = uri_to_path(uri, context.temp_allocator)
	} else if path, has_path := member_string(params, "rootPath"); has_path {
		folder = path
	}
	configure(s, member(params, "initializationOptions"), folder)
	s.phase = .Running

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b, `{{"capabilities":{{"positionEncoding":"%s","textDocumentSync":{{"openClose":true,"change":%d,"save":{{"includeText":false}}}},"hoverProvider":true,"definitionProvider":true,"documentSymbolProvider":true,"completionProvider":{{"triggerCharacters":["."]}},"signatureHelpProvider":{{"triggerCharacters":["(",","]}},"referencesProvider":true,"renameProvider":%s}},"serverInfo":{{"name":"%s","version":"%s"}}}}`,
		s.utf8_positions ? "utf-8" : "utf-16", SYNC_FULL, s.prepare_rename ? `{"prepareProvider":true}` : "true", SERVER_NAME, lokec.LOKE_VERSION_STRING,
	)
	send_result(s, id, strings.to_string(b))
}

// `initializationOptions` carry what `lokec` takes as `-collection` and
// `-define`; a relative collection path is relative to the first workspace
// folder. The configuration is fixed for the server's lifetime, as for a session.
@(private = "file")
configure :: proc(s: ^Server, options: json.Value, folder: string) {
	allocator := virtual.arena_allocator(&s.config_arena)
	defines := make([dynamic]string, allocator)
	for entry in member_array(options, "defines") {
		if text, ok := entry.(json.String); ok { append(&defines, strings.clone(text, allocator)) }
	}
	collections := make([dynamic]string, allocator)
	for entry in member_array(options, "collections") {
		text, ok := entry.(json.String)
		if !ok { continue }
		split := strings.index_byte(text, '=')
		if split > 0 && folder != "" && !filepath.is_abs(text[split + 1:]) && text[split + 1:] != "" {
			text = fmt.tprintf("%s=%s", text[:split], lokec.join_path({folder, text[split + 1:]}, context.temp_allocator))
		}
		append(&collections, strings.clone(text, allocator))
	}
	s.config.defines, s.config.collections = defines[:], collections[:]
}

@(private = "file")
register_watchers :: proc(s: ^Server) {
	send_request(
		s, `"loke-lsp-watch"`, "client/registerCapability",
		`{"registrations":[{"id":"loke-watched-files","method":"workspace/didChangeWatchedFiles","registerOptions":{"watchers":[{"globPattern":"**/*.loke"},{"globPattern":"**/loke.project"}]}}]}`,
	)
}

@(private = "file")
did_open :: proc(s: ^Server, params: json.Value) {
	item := member(params, "textDocument")
	uri, has_uri := member_string(item, "uri")
	text, has_text := member_string(item, "text")
	version, _ := member_int(item, "version")
	path, is_file := uri_to_path(uri, context.temp_allocator)
	// Only `.loke` sources can be overlays; a manifest is read from disk.
	if !has_uri || !has_text || !is_file || !strings.equal_fold(filepath.ext(path), ".loke") { return }
	key := path_key(path, context.temp_allocator)
	if previous := s.documents[key]; previous != nil {
		delete_key(&s.documents, key)
		destroy_document(previous)
	}
	doc := new(Document)
	doc.uri, doc.path = strings.clone(uri), strings.clone(lokec.canonical_dir(path))
	doc.key, doc.text, doc.version = strings.clone(key), strings.clone(text), version
	s.revision += 1
	doc.revision = s.revision
	s.documents[doc.key] = doc
	for _, root in s.roots { lokec.set_session_overlay(&root.session, doc.path, doc.text) }
	documents_changed(s, rescan = true)
}

@(private = "file")
did_change :: proc(s: ^Server, params: json.Value) {
	item := member(params, "textDocument")
	doc := find_document(s, item)
	if doc == nil { return }
	if version, ok := member_int(item, "version"); ok { doc.version = version }
	for change in member_array(params, "contentChanges") {
		text, has_text := member_string(change, "text")
		if !has_text { continue }
		range := member(change, "range")
		if range == nil {
			replace_text(doc, strings.clone(text))
			continue
		}
		// Full sync is what the server asks for; a client sending ranges anyway
		// still gets them applied.
		start := position_to_offset(doc.text, json_position(member(range, "start")), s.utf8_positions)
		end := max(start, position_to_offset(doc.text, json_position(member(range, "end")), s.utf8_positions))
		replace_text(doc, strings.concatenate({doc.text[:start], text, doc.text[end:]}))
	}
	s.revision += 1
	doc.revision = s.revision
	for _, root in s.roots { lokec.set_session_overlay(&root.session, doc.path, doc.text) }
	documents_changed(s, rescan = false)
}

@(private = "file")
did_close :: proc(s: ^Server, params: json.Value) {
	doc := find_document(s, member(params, "textDocument"))
	if doc == nil { return }
	for _, root in s.roots { lokec.remove_session_overlay(&root.session, doc.path) }
	delete_key(&s.documents, doc.key)
	destroy_document(doc)
	documents_changed(s, rescan = true)
}

// The overlay already holds the saved text. Only grouping into roots may
// change, since the file now exists on disk.
@(private = "file")
did_save :: proc(s: ^Server, params: json.Value) {
	if find_document(s, member(params, "textDocument")) == nil { return }
	clear_directory_scans(s)
	s.layout_dirty = true
}

// Any edit can change any root's program, so every root checks again.
@(private = "file")
documents_changed :: proc(s: ^Server, rescan: bool) {
	s.last_edit = time.tick_now()
	s.layout_dirty = true
	for _, root in s.roots { root.dirty = true }
	if rescan { clear_directory_scans(s) }
}

find_document :: proc(s: ^Server, item: json.Value) -> ^Document {
	uri, has_uri := member_string(item, "uri")
	if !has_uri { return nil }
	path, is_file := uri_to_path(uri, context.temp_allocator)
	if !is_file { return nil }
	return s.documents[path_key(path, context.temp_allocator)]
}

@(private = "file")
replace_text :: proc(doc: ^Document, text: string) {
	delete(doc.text)
	doc.text = text
}

@(private = "file")
destroy_document :: proc(doc: ^Document) {
	delete(doc.uri)
	delete(doc.path)
	delete(doc.key)
	delete(doc.text)
	free(doc)
}

json_position :: proc(value: json.Value) -> Position {
	line, _ := member_int(value, "line")
	character, _ := member_int(value, "character")
	return Position{int(line), int(character)}
}

// Request IDs compare by type and value: `1` and `"1"` are different requests.
id_key :: proc(id: json.Value) -> string {
	#partial switch v in id {
	case json.Integer: return fmt.tprintf("i%d", v)
	case json.String:  return fmt.tprintf("s%s", v)
	}
	return ""
}

send_result :: proc(s: ^Server, id: json.Value, result: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	write_json_id(&b, id)
	fmt.sbprintf(&b, `,"result":%s}`, result)
	send(s, strings.to_string(b))
}

send_error :: proc(s: ^Server, id: json.Value, code: int, message: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	write_json_id(&b, id)
	fmt.sbprintf(&b, `,"error":{{"code":%d,"message":`, code)
	write_json_string(&b, message)
	strings.write_string(&b, "}}")
	send(s, strings.to_string(b))
}

send_notification :: proc(s: ^Server, method: string, params: string) {
	send(s, fmt.tprintf(`{{"jsonrpc":"2.0","method":"%s","params":%s}}`, method, params))
}

// `id` is JSON text.
send_request :: proc(s: ^Server, id, method, params: string) {
	send(s, fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}}`, id, method, params))
}

@(private = "file")
send :: proc(s: ^Server, body: string) {
	s.write(s.write_data, frame_message(body, context.temp_allocator))
}
