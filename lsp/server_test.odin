package lsp

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import lokec "../src"

// A server driven in-process: messages go in as bodies, and everything it
// writes is collected and parsed back. Checking runs only when a test asks,
// so the interleaving of edits and checks is the test's to choose.
@(private = "file")
Harness :: struct {
	t:      ^testing.T,
	s:      Server,
	out:    [dynamic]byte,
	arena:  virtual.Arena, // parsed output
	root:   string,
}

@(private = "file")
start :: proc(h: ^Harness, t: ^testing.T, name: string, initialize_params := "") -> bool {
	h.t = t
	h.root = lokec.canonical_dir(fmt.tprintf("tests/tmp/lsp-%d-%s", os.get_pid(), name))
	os.remove_all(h.root)
	if !testing.expect(t, os.make_directory_all(h.root) == nil) { return false }
	init_server(&h.s, proc(data: rawptr, message: string) {
		append((^[dynamic]byte)(data), ..transmute([]byte)message)
	}, &h.out)
	params := initialize_params
	if params == "" { params = fmt.tprintf(`{{"rootUri":%s,"capabilities":{{}}}}`, quoted(path_to_uri(h.root, context.temp_allocator))) }
	request(h, "1", "initialize", params)
	notify(h, "initialized", "{}")
	replies := take(h)
	return testing.expect(t, len(replies) == 1 && member(replies[0], "result") != nil)
}

@(private = "file")
finish :: proc(h: ^Harness) {
	destroy_server(&h.s)
	delete(h.out)
	virtual.arena_destroy(&h.arena)
	if h.root != "" { os.remove_all(h.root) }
}

@(private = "file")
write_file :: proc(h: ^Harness, relative, text: string) -> string {
	path := lokec.join_path({h.root, relative}, context.temp_allocator)
	_ = os.make_directory_all(lokec.path_dir(path, context.temp_allocator))
	testing.expect(h.t, os.write_entire_file(path, transmute([]byte)text) == nil)
	return lokec.canonical_dir(path)
}

@(private = "file")
uri_of :: proc(h: ^Harness, relative: string) -> string {
	return path_to_uri(lokec.canonical_dir(lokec.join_path({h.root, relative}, context.temp_allocator)), context.temp_allocator)
}

@(private = "file")
quoted :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_json_string(&b, text)
	return strings.to_string(b)
}

@(private = "file")
request :: proc(h: ^Harness, id, method, params: string) {
	handle_messages(&h.s, {fmt.tprintf(`{{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}}`, id, method, params)})
}

@(private = "file")
notify :: proc(h: ^Harness, method, params: string) {
	handle_messages(&h.s, {fmt.tprintf(`{{"jsonrpc":"2.0","method":"%s","params":%s}}`, method, params)})
}

@(private = "file")
open :: proc(h: ^Harness, relative, text: string, version := 1) {
	notify(h, "textDocument/didOpen", fmt.tprintf(
		`{{"textDocument":{{"uri":%s,"languageId":"loke","version":%d,"text":%s}}}}`,
		quoted(uri_of(h, relative)), version, quoted(text),
	))
}

@(private = "file")
change :: proc(h: ^Harness, relative, text: string, version: int) {
	notify(h, "textDocument/didChange", fmt.tprintf(
		`{{"textDocument":{{"uri":%s,"version":%d}},"contentChanges":[{{"text":%s}}]}}`,
		quoted(uri_of(h, relative)), version, quoted(text),
	))
}

@(private = "file")
close :: proc(h: ^Harness, relative: string) {
	notify(h, "textDocument/didClose", fmt.tprintf(`{{"textDocument":{{"uri":%s}}}}`, quoted(uri_of(h, relative))))
}

// Runs every pending check and publication.
@(private = "file")
settle :: proc(h: ^Harness) {
	for run_pending_work(&h.s) {}
}

// Everything written since the last call, parsed.
@(private = "file")
take :: proc(h: ^Harness) -> []json.Value {
	Cursor :: struct { data: []byte }
	cursor := Cursor{h.out[:]}
	reader := Message_Reader{read = proc(data: rawptr, buffer: []byte) -> int {
		cursor := (^Cursor)(data)
		n := copy(buffer, cursor.data)
		cursor.data = cursor.data[n:]
		return n
	}, data = &cursor}
	defer destroy_reader(&reader)
	allocator := virtual.arena_allocator(&h.arena)
	messages := make([dynamic]json.Value, allocator)
	for {
		body, ok := read_message(&reader, allocator)
		if !ok { break }
		value, err := json.parse_string(body, parse_integers = true, allocator = allocator)
		testing.expect(h.t, err == nil)
		append(&messages, value)
	}
	clear(&h.out)
	return messages[:]
}

// The publications in `messages`, as (uri, params) pairs in order.
@(private = "file")
Publication :: struct { uri: string, version: i64, versioned: bool, diagnostics: json.Array }

@(private = "file")
publications :: proc(messages: []json.Value) -> []Publication {
	out := make([dynamic]Publication, context.temp_allocator)
	for message in messages {
		if method, _ := member_string(message, "method"); method != "textDocument/publishDiagnostics" { continue }
		params := member(message, "params")
		uri, _ := member_string(params, "uri")
		version, versioned := member_int(params, "version")
		append(&out, Publication{uri, version, versioned, member_array(params, "diagnostics")})
	}
	return out[:]
}

@(private = "file")
codes :: proc(diagnostics: json.Array) -> string {
	b := strings.builder_make(context.temp_allocator)
	for d, index in diagnostics {
		if index > 0 { strings.write_byte(&b, ' ') }
		code, _ := member_string(d, "code")
		strings.write_string(&b, code)
	}
	return strings.to_string(b)
}

@(private = "file")
start_of :: proc(d: json.Value) -> Position {
	start := member(member(d, "range"), "start")
	line, _ := member_int(start, "line")
	character, _ := member_int(start, "character")
	return Position{int(line), int(character)}
}

@(private = "file")
error_code :: proc(message: json.Value) -> i64 {
	code, _ := member_int(member(message, "error"), "code")
	return code
}

@(test)
lifecycle_requests_follow_the_protocol :: proc(t: ^testing.T) {
	h := Harness{t = t}
	init_server(&h.s, proc(data: rawptr, message: string) {
		append((^[dynamic]byte)(data), ..transmute([]byte)message)
	}, &h.out)
	defer finish(&h)
	s := &h.s

	handle_messages(s, {`{"jsonrpc":"2.0","id":1,"method":"shutdown"}`, `{"jsonrpc":"2.0","method":"initialized","params":{}}`})
	replies := take(&h)
	testing.expect(t, len(replies) == 1 && error_code(replies[0]) == SERVER_NOT_INITIALIZED)

	handle_messages(s, {`{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8","utf-16"]}}}}`})
	replies = take(&h)
	if testing.expect(t, len(replies) == 1) {
		id, _ := member_string(replies[0], "id")
		encoding, _ := member_string(member(member(replies[0], "result"), "capabilities"), "positionEncoding")
		testing.expect_value(t, id, "init")
		testing.expect_value(t, encoding, "utf-8")
	}

	handle_messages(s, {
		`{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}`,
		`{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{}}`,
		`{"jsonrpc":"2.0","id":4,"method":"textDocument/hover","params":{}}`,
		`{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":4}}`,
		`not json`,
	})
	replies = take(&h)
	if testing.expect_value(t, len(replies), 4) {
		testing.expect_value(t, error_code(replies[0]), INVALID_REQUEST)
		testing.expect_value(t, error_code(replies[1]), METHOD_NOT_FOUND)
		testing.expect_value(t, error_code(replies[2]), REQUEST_CANCELLED)
		testing.expect_value(t, error_code(replies[3]), PARSE_ERROR)
	}

	handle_messages(s, {`{"jsonrpc":"2.0","id":5,"method":"shutdown"}`, `{"jsonrpc":"2.0","id":6,"method":"shutdown"}`})
	replies = take(&h)
	if testing.expect_value(t, len(replies), 2) {
		_, null_result := member(replies[0], "result").(json.Null)
		testing.expect(t, null_result && member(replies[0], "error") == nil)
		testing.expect_value(t, error_code(replies[1]), INVALID_REQUEST)
	}
	testing.expect(t, !s.exited)
	handle_messages(s, {`{"jsonrpc":"2.0","method":"exit"}`})
	testing.expect(t, s.exited && s.exit_code == 0)
}

@(test)
exit_without_shutdown_is_an_error_exit :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "exit") { finish(&h); return }
	defer finish(&h)
	notify(&h, "exit", "{}")
	testing.expect(t, h.s.exited && h.s.exit_code == 1)
}

@(test)
diagnostics_follow_document_versions :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "versions") { finish(&h); return }
	defer finish(&h)
	broken := "package main;\nmain :: proc() {\n\tx: int = \"text\";\n}\n"
	fixed := "package main;\nmain :: proc() {\n\tx: int = 1;\n\t_ = x;\n}\n"
	open(&h, "main.loke", broken, 1)
	settle(&h)
	published := publications(take(&h))
	if testing.expect_value(t, len(published), 1) {
		p := published[0]
		testing.expect_value(t, p.uri, uri_of(&h, "main.loke"))
		testing.expect(t, p.versioned && p.version == 1)
		testing.expect_value(t, len(p.diagnostics), 1)
		testing.expect_value(t, start_of(p.diagnostics[0]).line, 2)
		source, _ := member_string(p.diagnostics[0], "source")
		testing.expect_value(t, source, "lokec")
		agrees_with_lokec(t, h.root, "main.loke", broken, codes(p.diagnostics))
	}

	change(&h, "main.loke", fixed, 2)
	settle(&h)
	published = publications(take(&h))
	if testing.expect_value(t, len(published), 1) {
		testing.expect(t, published[0].version == 2 && len(published[0].diagnostics) == 0)
	}

	// Nothing changed for the client, so nothing more is sent.
	change(&h, "main.loke", fixed, 3)
	settle(&h)
	testing.expect_value(t, len(publications(take(&h))), 0)
	close(&h, "main.loke")
	settle(&h)
	testing.expect_value(t, len(publications(take(&h))), 0)
}

// A fresh `lokec`-equivalent batch check of the same inputs reports the same
// diagnostic codes.
@(private = "file")
agrees_with_lokec :: proc(t: ^testing.T, root, relative, text, published_codes: string) {
	s: lokec.Compilation_Session
	defer lokec.destroy_session(&s)
	testing.expect(t, lokec.init_session(&s))
	path := lokec.join_path({root, relative}, context.temp_allocator)
	testing.expect(t, lokec.set_session_overlay(&s, path, text))
	lokec.check_session(&s, root)
	snapshot, _ := lokec.session_snapshot(&s)
	diagnostics, _ := lokec.query_diagnostics(&s, snapshot)
	b := strings.builder_make(context.temp_allocator)
	for d, index in diagnostics {
		if index > 0 { strings.write_byte(&b, ' ') }
		strings.write_string(&b, d.code)
	}
	testing.expect_value(t, published_codes, strings.to_string(b))
}

@(test)
superseded_results_are_not_published :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "superseded") { finish(&h); return }
	defer finish(&h)
	open(&h, "main.loke", "package main;\nmain :: proc() { x: int = \"a\"; }\n", 1)
	// The check of version 1 finishes, then version 2 arrives before publishing.
	testing.expect(t, run_pending_work(&h.s))
	change(&h, "main.loke", "package main;\n\nmain :: proc() { y: bool = 1; }\n", 2)
	settle(&h)
	published := publications(take(&h))
	if testing.expect_value(t, len(published), 1) {
		testing.expect_value(t, published[0].version, 2)
		if testing.expect_value(t, len(published[0].diagnostics), 1) {
			testing.expect_value(t, start_of(published[0].diagnostics[0]).line, 2)
		}
	}
}

@(test)
unsaved_package_edits_reach_importers :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "packages") { finish(&h); return }
	defer finish(&h)
	write_file(&h, "app/main.loke", "package main;\nimport \"greet\";\nmain :: proc() { _ = greet.message(); }\n")
	greet := "package greet;\n@(public) message :: proc() -> string { return \"hi\"; }\n"
	write_file(&h, "app/greet/greet.loke", greet)
	open(&h, "app/main.loke", "package main;\nimport \"greet\";\nmain :: proc() { _ = greet.message(); }\n")
	open(&h, "app/greet/greet.loke", greet)
	settle(&h)
	// A library package is checked without an entry point: nothing to report.
	testing.expect_value(t, len(publications(take(&h))), 0)

	// The renamed procedure exists only in the editor, yet the importer sees it.
	change(&h, "app/greet/greet.loke", "package greet;\n@(public) greeting :: proc() -> string { return \"hi\"; }\n", 2)
	settle(&h)
	published := publications(take(&h))
	if testing.expect_value(t, len(published), 1) {
		testing.expect_value(t, published[0].uri, uri_of(&h, "app/main.loke"))
		testing.expect_value(t, len(published[0].diagnostics), 1)
	}

	// Closing discards the unsaved edit; the disk text is fine.
	close(&h, "app/greet/greet.loke")
	settle(&h)
	published = publications(take(&h))
	testing.expect(t, len(published) == 1 && len(published[0].diagnostics) == 0)
}

@(test)
errors_in_unopened_imports_are_published :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "watched") { finish(&h); return }
	defer finish(&h)
	write_file(&h, "app/main.loke", "package main;\nimport \"greet\";\nmain :: proc() { _ = greet.message(); }\n")
	write_file(&h, "app/greet/greet.loke", "package greet;\n@(public) message :: proc() -> string { return \"hi\"; }\n")
	open(&h, "app/main.loke", "package main;\nimport \"greet\";\nmain :: proc() { _ = greet.message(); }\n")
	settle(&h)
	testing.expect_value(t, len(publications(take(&h))), 0)

	// Disk changes reach the server only through the client's notification.
	write_file(&h, "app/greet/greet.loke", "package greet;\n@(public) message :: proc() -> string { return 1; }\n")
	notify(&h, "workspace/didChangeWatchedFiles", fmt.tprintf(`{{"changes":[{{"uri":%s,"type":2}}]}}`, quoted(uri_of(&h, "app/greet/greet.loke"))))
	settle(&h)
	published := publications(take(&h))
	if testing.expect_value(t, len(published), 1) {
		testing.expect_value(t, published[0].uri, uri_of(&h, "app/greet/greet.loke"))
		testing.expect(t, !published[0].versioned)
		testing.expect_value(t, len(published[0].diagnostics), 1)
	}

	// Opened under the client's spelling of the URI, the file's diagnostics
	// move there and the old URI is cleared.
	generated := uri_of(&h, "app/greet/greet.loke")
	drive := len("file:///")
	client_uri := strings.concatenate({generated[:drive + 1], "%3A", generated[drive + 2:]}, context.temp_allocator)
	notify(&h, "textDocument/didOpen", fmt.tprintf(
		`{{"textDocument":{{"uri":%s,"languageId":"loke","version":7,"text":%s}}}}`,
		quoted(client_uri), quoted("package greet;\n@(public) message :: proc() -> string { return 1; }\n"),
	))
	settle(&h)
	published = publications(take(&h))
	if testing.expect_value(t, len(published), 2) {
		testing.expect(t, published[0].uri == uri_of(&h, "app/greet/greet.loke") && len(published[0].diagnostics) == 0)
		testing.expect(t, published[1].uri == client_uri && published[1].version == 7 && len(published[1].diagnostics) == 1)
	}
}

@(test)
broken_edits_recover :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "recovery") { finish(&h); return }
	defer finish(&h)
	open(&h, "main.loke", "package main;\nimport \"missing\";\nmain :: proc() {}\n", 1)
	settle(&h)
	published := publications(take(&h))
	testing.expect(t, len(published) == 1 && len(published[0].diagnostics) > 0)

	change(&h, "main.loke", "package main;\nmain :: proc() {\n", 2)
	settle(&h)
	published = publications(take(&h))
	if testing.expect_value(t, len(published), 1) {
		testing.expect(t, published[0].version == 2 && len(published[0].diagnostics) > 0)
	}

	change(&h, "main.loke", "package main;\nmain :: proc() {}\n", 3)
	settle(&h)
	published = publications(take(&h))
	testing.expect(t, len(published) == 1 && published[0].version == 3 && len(published[0].diagnostics) == 0)
}

@(test)
separate_programs_in_one_directory_check_alone :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "programs") { finish(&h); return }
	defer finish(&h)
	write_file(&h, "a.loke", "package main;\nmain :: proc() {}\n")
	write_file(&h, "b.loke", "package main;\nmain :: proc() {}\n")
	open(&h, "a.loke", "package main;\nmain :: proc() { x: int = true; }\n")
	settle(&h)
	// Checked as one package, the two `main`s would collide.
	published := publications(take(&h))
	if testing.expect_value(t, len(published), 1) {
		testing.expect_value(t, published[0].uri, uri_of(&h, "a.loke"))
		testing.expect_value(t, len(published[0].diagnostics), 1)
	}
	testing.expect_value(t, len(h.s.roots), 1)
}

@(test)
files_of_one_package_check_together :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "package") { finish(&h); return }
	defer finish(&h)
	write_file(&h, "main.loke", "package main;\nmain :: proc() { _ = helper(); }\n")
	write_file(&h, "helper.loke", "package main;\nhelper :: proc() -> int { return 1; }\n")
	open(&h, "main.loke", "package main;\nmain :: proc() { _ = helper(); }\n")
	open(&h, "helper.loke", "package main;\nhelper :: proc() -> int { return 1; }\n")
	settle(&h)
	testing.expect_value(t, len(publications(take(&h))), 0)
	testing.expect_value(t, len(h.s.roots), 1)
}

@(test)
positions_use_the_negotiated_encoding :: proc(t: ^testing.T) {
	text := "package main;\nmain :: proc() { s := \"\U0001F600é\"; x: int = s; }\n"
	for utf8_units in ([]bool{false, true}) {
		h: Harness
		encodings := utf8_units ? `["utf-8"]` : `["utf-16"]`
		params := fmt.tprintf(`{{"capabilities":{{"general":{{"positionEncodings":%s}}}}}}`, encodings)
		if !start(&h, t, utf8_units ? "utf8" : "utf16", params) { finish(&h); continue }
		open(&h, "main.loke", text)
		settle(&h)
		published := publications(take(&h))
		if testing.expect_value(t, len(published), 1) && testing.expect_value(t, len(published[0].diagnostics), 1) {
			line := "main :: proc() { s := \"\U0001F600é\"; x: int = "
			// The emoji is 4 bytes and 2 UTF-16 units; é is 2 bytes and 1 unit.
			expected := utf8_units ? len(line) : len(line) - 3
			testing.expect_value(t, start_of(published[0].diagnostics[0]), Position{1, expected})
		}
		finish(&h)
	}
}

@(test)
configuration_errors_appear_on_open_documents :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "configuration", `{"capabilities":{},"initializationOptions":{"defines":["not a define"]}}`) { finish(&h); return }
	defer finish(&h)
	open(&h, "main.loke", "package main;\nmain :: proc() {}\n")
	settle(&h)
	published := publications(take(&h))
	if testing.expect_value(t, len(published), 1) {
		testing.expect_value(t, codes(published[0].diagnostics), "L0388")
		testing.expect_value(t, start_of(published[0].diagnostics[0]), Position{})
	}
}

@(test)
notes_become_related_information_when_supported :: proc(t: ^testing.T) {
	text := "package main;\nf :: proc() -> []int { a := [4]int{1, 2, 3, 4}; return a[:]; }\nmain :: proc() { _ = f(); }\n"
	for related in ([]bool{false, true}) {
		h: Harness
		params := fmt.tprintf(`{{"capabilities":{{"textDocument":{{"publishDiagnostics":{{"relatedInformation":%v}}}}}}}}`, related)
		if !start(&h, t, related ? "related" : "inline-notes", params) { finish(&h); continue }
		open(&h, "main.loke", text)
		settle(&h)
		published := publications(take(&h))
		if testing.expect_value(t, len(published), 1) && testing.expect(t, len(published[0].diagnostics) > 0) {
			d := published[0].diagnostics[0]
			message, _ := member_string(d, "message")
			has_related := len(member_array(d, "relatedInformation")) > 0
			testing.expectf(t, has_related == related, "relatedInformation present: %v", has_related)
			testing.expectf(t, strings.contains(message, "\nnote: ") == !related, "message: %q", message)
		}
		finish(&h)
	}
}
