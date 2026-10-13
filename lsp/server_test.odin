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
		`{"jsonrpc":"2.0","id":3,"method":"loke/unsupported","params":{}}`,
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

// open-questions.md finding: a commented-out `main` made a package's files
// separate roots, so `helper` was unknown.
@(test)
commented_entries_do_not_split_a_package :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "commented") { finish(&h); return }
	defer finish(&h)
	main_text := "package main;\nmain :: proc() { _ = helper(); }\n"
	write_file(&h, "main.loke", main_text)
	write_file(&h, "helper.loke", "package main;\n/*\nmain :: proc() {}\n*/\nhelper :: proc() -> int { return 1; }\n")
	write_file(&h, "usage.loke", "package main;\nusage :: `\nmain :: proc() {}\n`;\n")
	open(&h, "main.loke", main_text)
	settle(&h)
	testing.expect_value(t, len(publications(take(&h))), 0)
	testing.expect_value(t, len(h.s.roots), 1)
}

// open-questions.md finding: opening an imported library gave it a root of
// its own, without the collections its application's manifest supplies.
@(test)
opened_imports_keep_their_application :: proc(t: ^testing.T) {
	main_text := "package main;\nimport lib \"lib:\";\nmain :: proc() { _ = lib.value(); }\n"
	lib_text := "package lib;\nimport util \"util:\";\n@(public) value :: proc() -> int { return util.value(); }\n"
	broken_lib := "package lib;\nimport util \"util:\";\n@(public) value :: proc() -> int { return util.missing(); }\n"
	for library_first in ([]bool{false, true}) {
		h: Harness
		if !start(&h, t, library_first ? "library-first" : "application-first") { finish(&h); continue }
		write_file(&h, "app/loke.project", "require lib ../lib\nrequire util ../util\n")
		write_file(&h, "app/main.loke", main_text)
		write_file(&h, "lib/lib.loke", lib_text)
		write_file(&h, "util/util.loke", "package util;\n@(public) value :: proc() -> int { return 1; }\n")
		if library_first {
			// Alone, the library cannot find `util:`, as `lokec lib -doc` cannot.
			open(&h, "lib/lib.loke", lib_text)
			settle(&h)
			published := publications(take(&h))
			testing.expect(t, len(published) == 1 && len(published[0].diagnostics) > 0)
			// Once the application loads it, those errors go away.
			open(&h, "app/main.loke", main_text)
			settle(&h)
			published = publications(take(&h))
			if testing.expect_value(t, len(published), 1) {
				testing.expect_value(t, published[0].uri, uri_of(&h, "lib/lib.loke"))
				testing.expect_value(t, len(published[0].diagnostics), 0)
			}
		} else {
			open(&h, "app/main.loke", main_text)
			settle(&h)
			testing.expect_value(t, len(publications(take(&h))), 0)
			open(&h, "lib/lib.loke", lib_text)
			settle(&h)
			testing.expect_value(t, len(publications(take(&h))), 0)
		}
		testing.expect_value(t, len(h.s.roots), 1)

		// A real error in the library is still reported, in the application's context.
		change(&h, "lib/lib.loke", broken_lib, 2)
		settle(&h)
		published := publications(take(&h))
		if testing.expect_value(t, len(published), 1) {
			testing.expect(t, published[0].version == 2 && len(published[0].diagnostics) == 1)
		}
		close(&h, "lib/lib.loke")
		settle(&h)
		published = publications(take(&h))
		testing.expect(t, len(published) == 1 && len(published[0].diagnostics) == 0)
		finish(&h)
	}
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

// The position of `needle` in `text`, `offset` bytes in. The texts are ASCII,
// so bytes and UTF-16 units agree.
@(private = "file")
position_of :: proc(t: ^testing.T, text, needle: string, offset := 0) -> Position {
	index := strings.index(text, needle)
	testing.expectf(t, index >= 0, "missing %q", needle)
	index = max(index, 0) + offset
	line_start := strings.last_index_byte(text[:index], '\n') + 1
	return Position{strings.count(text[:index], "\n"), index - line_start}
}

// Sends a position request and returns its reply once every check has run.
@(private = "file")
ask :: proc(h: ^Harness, method, relative: string, position: Position) -> json.Value {
	request(h, "70", method, fmt.tprintf(
		`{{"textDocument":{{"uri":%s}},"position":{{"line":%d,"character":%d}}}}`,
		quoted(uri_of(h, relative)), position.line, position.character,
	))
	settle(h)
	for message in take(h) {
		if id, _ := member_int(message, "id"); id == 70 { return message }
	}
	testing.expect(h.t, false, "the request was not answered")
	return nil
}

@(private = "file")
is_null_result :: proc(reply: json.Value) -> bool {
	_, null_result := member(reply, "result").(json.Null)
	return null_result && member(reply, "error") == nil
}

@(private = "file")
hover_value :: proc(reply: json.Value) -> string {
	value, _ := member_string(member(member(reply, "result"), "contents"), "value")
	return value
}

@(private = "file")
expect_definition :: proc(t: ^testing.T, reply: json.Value, uri: string, at: Position, loc := #caller_location) {
	result := member(reply, "result")
	got, _ := member_string(result, "uri")
	testing.expect_value(t, got, uri, loc = loc)
	testing.expect_value(t, start_of(result), at, loc = loc)
}

@(test)
hover_shows_declarations_and_comments :: proc(t: ^testing.T) {
	text := "package main;\n// Adds two numbers.\n// Never overflows here.\nadd :: proc(a: int, b: int) -> int { return a + b; }\nPoint :: struct { x: int, y: int }\nmain :: proc() {\n\ttotal := add(1, 2);\n\tp := Point{x = total, y = 0};\n\t_ = p.x;\n}\n"
	for markdown in ([]bool{true, false}) {
		h: Harness
		params := `{"capabilities":{"textDocument":{"hover":{"contentFormat":["markdown","plaintext"]}}}}` if markdown else `{"capabilities":{}}`
		if !start(&h, t, markdown ? "hover-markdown" : "hover-plain", params) { finish(&h); continue }
		open(&h, "main.loke", text)
		reply := ask(&h, "textDocument/hover", "main.loke", position_of(t, text, "add(1"))
		kind, _ := member_string(member(member(reply, "result"), "contents"), "kind")
		value := hover_value(reply)
		SIGNATURE :: "add :: proc(a: int, b: int) -> int"
		testing.expect_value(t, kind, markdown ? "markdown" : "plaintext")
		if markdown {
			testing.expect_value(t, value, "```loke\n" + SIGNATURE + "\n```\n\nAdds two numbers.\nNever overflows here.")
		} else {
			testing.expect_value(t, value, SIGNATURE + "\n\nAdds two numbers.\nNever overflows here.")
		}
		testing.expect_value(t, start_of(member(reply, "result")), position_of(t, text, "add(1"))
		finish(&h)
	}

	h: Harness
	if !start(&h, t, "hover") { finish(&h); return }
	defer finish(&h)
	open(&h, "main.loke", text)
	testing.expect_value(t, hover_value(ask(&h, "textDocument/hover", "main.loke", position_of(t, text, "total,"))), "total: int")
	// A cursor just past a name still means that name.
	testing.expect_value(t, hover_value(ask(&h, "textDocument/hover", "main.loke", position_of(t, text, "total :=", len("total")))), "total: int")
	testing.expect_value(t, hover_value(ask(&h, "textDocument/hover", "main.loke", position_of(t, text, "x;"))), "x: int")
	testing.expect_value(t, hover_value(ask(&h, "textDocument/hover", "main.loke", position_of(t, text, "Point{"))), "Point :: struct { x: int, y: int }")
	// Keywords, punctuation, and comments name no binding.
	testing.expect(t, is_null_result(ask(&h, "textDocument/hover", "main.loke", position_of(t, text, "return"))))
	testing.expect(t, is_null_result(ask(&h, "textDocument/hover", "main.loke", position_of(t, text, "Never"))))
}

@(test)
definitions_follow_unsaved_text_across_packages :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "definition") { finish(&h); return }
	defer finish(&h)
	library := "package shapes;\n@(public) area :: proc(side: int) -> int { return side * side; }\n"
	write_file(&h, "app/shapes/shapes.loke", library)
	text := "package main;\nimport \"shapes\";\nmain :: proc() {\n\tside := 3;\n\t_ = shapes.area(side);\n}\n"
	write_file(&h, "app/main.loke", text)
	open(&h, "app/main.loke", text)
	// Into a package that is not open, read from disk.
	reply := ask(&h, "textDocument/definition", "app/main.loke", position_of(t, text, "area(side"))
	expect_definition(t, reply, uri_of(&h, "app/shapes/shapes.loke"), position_of(t, library, "area ::"))
	reply = ask(&h, "textDocument/definition", "app/main.loke", position_of(t, text, "side);"))
	expect_definition(t, reply, uri_of(&h, "app/main.loke"), position_of(t, text, "side :="))

	// Unsaved text in both documents decides where the definitions are.
	edited := "package main;\nimport \"shapes\";\nhelper :: proc() -> int { return 2; }\nmain :: proc() {\n\tside := helper();\n\t_ = shapes.area(side);\n}\n"
	change(&h, "app/main.loke", edited, 2)
	reply = ask(&h, "textDocument/definition", "app/main.loke", position_of(t, edited, "helper()"))
	expect_definition(t, reply, uri_of(&h, "app/main.loke"), position_of(t, edited, "helper ::"))
	moved := "package shapes;\n\n// Moved down.\n@(public) area :: proc(side: int) -> int { return side * side; }\n"
	open(&h, "app/shapes/shapes.loke", moved)
	reply = ask(&h, "textDocument/definition", "app/main.loke", position_of(t, edited, "area(side"))
	expect_definition(t, reply, uri_of(&h, "app/shapes/shapes.loke"), position_of(t, moved, "area ::"))
	// From inside the opened library, which its importer checks.
	reply = ask(&h, "textDocument/definition", "app/shapes/shapes.loke", position_of(t, moved, "side * side"))
	expect_definition(t, reply, uri_of(&h, "app/shapes/shapes.loke"), position_of(t, moved, "side: int"))
}

@(test)
unresolved_names_have_no_semantic_result :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "unresolved") { finish(&h); return }
	defer finish(&h)
	text := "package main;\nimport \"nowhere\";\nmain :: proc() {\n\tnowhere.run();\n\tunknown();\n}\n"
	open(&h, "main.loke", text)
	for needle in ([]string{"run()", "nowhere.run", "unknown()"}) {
		at := position_of(t, text, needle)
		testing.expectf(t, is_null_result(ask(&h, "textDocument/definition", "main.loke", at)), "definition of %q", needle)
		testing.expectf(t, is_null_result(ask(&h, "textDocument/hover", "main.loke", at)), "hover of %q", needle)
	}

	// A syntax error elsewhere in the file leaves recorded bindings usable.
	broken := "package main;\ntwice :: proc(n: int) -> int { return n * 2; }\nmain :: proc() {\n\tvalue := twice(1);\n\t_ = value;\n\tbroken := twice(;\n}\n"
	change(&h, "main.loke", broken, 2)
	reply := ask(&h, "textDocument/definition", "main.loke", position_of(t, broken, "twice(1"))
	expect_definition(t, reply, uri_of(&h, "main.loke"), position_of(t, broken, "twice ::"))

	// After the edit is repaired, everything resolves again.
	fixed := "package main;\ntwice :: proc(n: int) -> int { return n * 2; }\nmain :: proc() {\n\tvalue := twice(1);\n\t_ = value;\n}\n"
	change(&h, "main.loke", fixed, 3)
	reply = ask(&h, "textDocument/definition", "main.loke", position_of(t, fixed, "value;"))
	expect_definition(t, reply, uri_of(&h, "main.loke"), position_of(t, fixed, "value :="))
	testing.expect_value(t, hover_value(ask(&h, "textDocument/hover", "main.loke", position_of(t, fixed, "twice(1"))), "twice :: proc(n: int) -> int")
}

@(test)
requests_wait_for_the_current_text :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "waiting") { finish(&h); return }
	defer finish(&h)
	text := "package main;\nmain :: proc() { x := 1; _ = x; }\n"
	hover_at := fmt.tprintf(`{{"textDocument":{{"uri":%s}},"position":{{"line":1,"character":17}}}}`, quoted(uri_of(&h, "main.loke")))

	// A document the client has not opened has no text to answer from.
	request(&h, "1", "textDocument/hover", fmt.tprintf(`{{"textDocument":{{"uri":%s}},"position":{{"line":0,"character":0}}}}`, quoted(uri_of(&h, "other.loke"))))
	replies := take(&h)
	testing.expect(t, len(replies) == 1 && is_null_result(replies[0]))

	// Requests wait for the check; one whose document changes meanwhile is
	// answered as modified, and one cancelled later is answered as cancelled.
	open(&h, "main.loke", text)
	request(&h, "2", "textDocument/hover", hover_at)
	request(&h, "3", "textDocument/hover", hover_at)
	testing.expect_value(t, len(take(&h)), 0)
	notify(&h, "$/cancelRequest", `{"id":3}`)
	replies = take(&h)
	testing.expect(t, len(replies) == 1 && error_code(replies[0]) == REQUEST_CANCELLED)
	change(&h, "main.loke", "package main;\nmain :: proc() { y := 1; _ = y; }\n", 2)
	settle(&h)
	replies = take(&h)
	modified := false
	for reply in replies {
		if id, _ := member_int(reply, "id"); id == 2 { modified = error_code(reply) == CONTENT_MODIFIED }
	}
	testing.expect(t, modified, "a request older than the text it was asked about must not be answered from it")

	request(&h, "4", "textDocument/hover", hover_at)
	settle(&h)
	replies = take(&h)
	testing.expect(t, len(replies) == 1 && hover_value(replies[0]) == "y: int")

	// Shutdown answers whatever is still waiting.
	change(&h, "main.loke", text, 3)
	request(&h, "5", "textDocument/definition", hover_at)
	request(&h, "6", "shutdown", "null")
	replies = take(&h)
	if testing.expect_value(t, len(replies), 2) {
		testing.expect_value(t, error_code(replies[0]), REQUEST_CANCELLED)
		testing.expect(t, is_null_result(replies[1]))
	}
}

@(test)
document_symbols_outline_declarations :: proc(t: ^testing.T) {
	text := "package main;\nLIMIT :: 10;\ncounter: int;\nColor :: enum { Red, Green }\nPoint :: struct {\n\tx: int,\n\ty: int,\n}\nlength :: proc(p: Point) -> int {\n\ttotal := p.x + p.y;\n\tInner :: struct { z: int }\n\treturn total;\n}\nmain :: proc() { _ = length(Point{}); }\n"
	for hierarchical in ([]bool{true, false}) {
		h: Harness
		params := `{"capabilities":{"textDocument":{"documentSymbol":{"hierarchicalDocumentSymbolSupport":true}}}}` if hierarchical else `{"capabilities":{}}`
		if !start(&h, t, hierarchical ? "symbols-tree" : "symbols-flat", params) { finish(&h); continue }
		open(&h, "main.loke", text)
		request(&h, "9", "textDocument/documentSymbol", fmt.tprintf(`{{"textDocument":{{"uri":%s}}}}`, quoted(uri_of(&h, "main.loke"))))
		settle(&h)
		reply: json.Value
		for message in take(&h) { if id, _ := member_int(message, "id"); id == 9 { reply = message } }
		symbols, _ := member(reply, "result").(json.Array)
		b := strings.builder_make(context.temp_allocator)
		describe_symbols(&b, symbols)
		if hierarchical {
			testing.expect_value(t, strings.to_string(b), "LIMIT/14 counter/13 Color/10(Red/22 Green/22) Point/23(x/8 y/8) length/12 main/12")
			if len(symbols) == 6 {
				point := symbols[3]
				testing.expect_value(t, start_of(point), position_of(t, text, "Point ::"))
				end, _ := member_int(member(member(point, "range"), "end"), "line")
				testing.expect_value(t, int(end), position_of(t, text, "}\nlength").line)
				detail, _ := member_string(symbols[4], "detail")
				testing.expect_value(t, detail, "proc(p: Point) -> int")
			}
		} else {
			testing.expect_value(t, strings.to_string(b), "LIMIT/14 counter/13 Color/10 Red/22<Color> Green/22<Color> Point/23 x/8<Point> y/8<Point> length/12 main/12")
		}
		finish(&h)
	}
}

// `name/kind`, children in parentheses and a container in angle brackets.
@(private = "file")
describe_symbols :: proc(b: ^strings.Builder, symbols: json.Array) {
	for symbol, index in symbols {
		if index > 0 { strings.write_byte(b, ' ') }
		name, _ := member_string(symbol, "name")
		kind, _ := member_int(symbol, "kind")
		fmt.sbprintf(b, "%s/%d", name, kind)
		if container, found := member_string(symbol, "containerName"); found { fmt.sbprintf(b, "<%s>", container) }
		if children := member_array(symbol, "children"); len(children) > 0 {
			strings.write_byte(b, '(')
			describe_symbols(b, children)
			strings.write_byte(b, ')')
		}
	}
}
