package lsp

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
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
	lokec.remove_tree(h.root)
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
	if h.root != "" { lokec.remove_tree(h.root) }
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
		capabilities := member(member(replies[0], "result"), "capabilities")
		testing.expect(t, member_bool(capabilities, "documentFormattingProvider"))
		commands := member_array(member(capabilities, "executeCommandProvider"), "commands")
		testing.expect(t, len(commands) == 1 && commands[0].(json.String) == DOCUMENTATION_COMMAND)
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

	// A response is ignored; an object that is neither it nor a request is not.
	handle_messages(s, {
		`{"jsonrpc":"2.0","id":"loke-lsp-watch","result":null}`,
		`{"jsonrpc":"2.0","id":77,"method":123}`,
		`{}`,
	})
	replies = take(&h)
	if testing.expect_value(t, len(replies), 2) {
		id, _ := member_int(replies[0], "id")
		_, null_id := member(replies[1], "id").(json.Null)
		testing.expect(t, error_code(replies[0]) == INVALID_REQUEST && id == 77)
		testing.expect(t, error_code(replies[1]) == INVALID_REQUEST && null_id)
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

	// The same text checks nothing again; its diagnostics take the new version.
	change(&h, "main.loke", broken, 2)
	for _, root in h.s.roots { testing.expect(t, !root.dirty, "an unchanged text dirties no root") }
	settle(&h)
	published = publications(take(&h))
	if testing.expect_value(t, len(published), 1) {
		testing.expect(t, published[0].version == 2 && len(published[0].diagnostics) == 1)
	}

	change(&h, "main.loke", fixed, 3)
	settle(&h)
	published = publications(take(&h))
	if testing.expect_value(t, len(published), 1) {
		testing.expect(t, published[0].version == 3 && len(published[0].diagnostics) == 0)
	}

	// Nothing changed for the client, so nothing more is sent.
	change(&h, "main.loke", fixed, 4)
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
		// Without the application open, the library is checked alone again and
		// cannot find `util:`.
		change(&h, "lib/lib.loke", lib_text, 3)
		close(&h, "app/main.loke")
		settle(&h)
		published = publications(take(&h))
		testing.expect(t, len(published) == 1 && published[0].version == 3 && len(published[0].diagnostics) > 0)
		if root := only_root(&h); root != nil {
			testing.expect_value(t, root.key, lokec.dir_key(lokec.canonical_dir(lokec.join_path({h.root, "lib"}, context.temp_allocator))))
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

// Two programs report one error in a package they share, each with a note at
// a different declaration; the client gets both notes.
@(test)
distinct_notes_are_published_from_every_program :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "distinct-notes", `{"capabilities":{"textDocument":{"publishDiagnostics":{"relatedInformation":true}}}}`) { finish(&h); return }
	defer finish(&h)
	shared := "package shared;\nimport util \"util:\";\n@(public) run :: proc() { util.hidden(); }\n"
	app := "package main;\nimport shared \"shared:\";\nmain :: proc() { shared.run(); }\n"
	write_file(&h, "shared/shared.loke", shared)
	for name in ([]string{"A", "B"}) {
		write_file(&h, fmt.tprintf("util%s/util.loke", name), "package util;\nhidden :: proc() {}\n")
		write_file(&h, fmt.tprintf("app%s/loke.project", name), fmt.tprintf("require shared ../shared\nrequire util ../util%s\n", name))
		write_file(&h, fmt.tprintf("app%s/main.loke", name), app)
		open(&h, fmt.tprintf("app%s/main.loke", name), app)
	}
	open(&h, "shared/shared.loke", shared)
	settle(&h)
	notes := make([dynamic]string, context.temp_allocator)
	for p in publications(take(&h)) {
		if p.uri != uri_of(&h, "shared/shared.loke") { continue }
		for d in p.diagnostics {
			for related in member_array(d, "relatedInformation") {
				uri, _ := member_string(member(related, "location"), "uri")
				append(&notes, uri)
			}
		}
	}
	slice.sort(notes[:])
	testing.expectf(t, len(notes) == 2 && notes[0] == uri_of(&h, "utilA/util.loke") && notes[1] == uri_of(&h, "utilB/util.loke"), "%v", notes)
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
// `extra` adds members to its parameters, starting with a comma.
@(private = "file")
ask :: proc(h: ^Harness, method, relative: string, position: Position, extra := "") -> json.Value {
	request(h, "70", method, fmt.tprintf(
		`{{"textDocument":{{"uri":%s}},"position":{{"line":%d,"character":%d}}%s}}`,
		quoted(uri_of(h, relative)), position.line, position.character, extra,
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
		// A client that does not list the kinds it supports gets only kinds 1-18.
		params := `{"capabilities":{"textDocument":{"documentSymbol":{"hierarchicalDocumentSymbolSupport":true,"symbolKind":{"valueSet":[5,8,10,12,13,14,22,23]}}}}}` if hierarchical else `{"capabilities":{}}`
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
			testing.expect_value(t, strings.to_string(b), "LIMIT/14 counter/13 Color/10 Red/14<Color> Green/14<Color> Point/5 x/8<Point> y/8<Point> length/12 main/12")
		}
		finish(&h)
	}
}

@(private = "file")
outline :: proc(h: ^Harness, text: string) -> string {
	open(h, "main.loke", text)
	request(h, "9", "textDocument/documentSymbol", fmt.tprintf(`{{"textDocument":{{"uri":%s}}}}`, quoted(uri_of(h, "main.loke"))))
	settle(h)
	b := strings.builder_make(context.temp_allocator)
	for message in take(h) {
		if id, _ := member_int(message, "id"); id == 9 {
			symbols, _ := member(message, "result").(json.Array)
			describe_symbols(&b, symbols)
		}
	}
	close(h, "main.loke")
	settle(h)
	take(h)
	return strings.to_string(b)
}

// Bindings that no declaration statement introduces still belong to the
// procedure or record they are written in.
@(test)
outline_parents_follow_where_bindings_are_written :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "symbols-nesting", `{"capabilities":{"textDocument":{"documentSymbol":{"hierarchicalDocumentSymbolSupport":true}}}}`) { finish(&h); return }
	defer finish(&h)
	testing.expect_value(t, outline(&h, "package main;\nmain :: proc() { foreach (i in 0 ..< 3) { _ = i; } }\n"), "main/12")
	capture := "package main;\nmain :: proc() { x := 1; f := proc() -> int capture(x) { return x; }; _ = f(); }\n"
	testing.expect_value(t, outline(&h, capture), "main/12")
	// The record a capture literal generates is not a written binding.
	open(&h, "main.loke", capture)
	reply := ask(&h, "textDocument/hover", "main.loke", position_of(t, capture, "proc() -> int"))
	testing.expectf(t, !strings.contains(hover_value(reply), "capture(x)"), "hover: %q", hover_value(reply))
	close(&h, "main.loke")
	settle(&h)
	take(&h)
	testing.expect_value(t, outline(&h, "package main;\nBox :: struct($T: type) { value: T }\nmain :: proc() { _ = Box(int){}; }\n"), "Box/5(value/8) main/12")
	testing.expect_value(t, outline(&h, "package main;\nBox :: struct($T: type) { value: T, count: int }\nmain :: proc() { _ = Box(int){}; _ = Box(f64){}; }\n"), "Box/5(value/8 count/8) main/12")
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

// A completion reply's labels, keywords left out, each with its kind when
// `kinds` is set.
@(private = "file")
completion_labels :: proc(reply: json.Value, kinds := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	for item in member_array(member(reply, "result"), "items") {
		kind, _ := member_int(item, "kind")
		if kind == i64(Completion_Kind.Keyword) { continue }
		label, _ := member_string(item, "label")
		if strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
		strings.write_string(&b, label)
		if kinds { fmt.sbprintf(&b, "/%d", kind) }
	}
	return strings.to_string(b)
}

@(private = "file")
completion_item :: proc(reply: json.Value, label: string) -> json.Value {
	for item in member_array(member(reply, "result"), "items") {
		if name, _ := member_string(item, "label"); name == label { return item }
	}
	return nil
}

@(test)
completion_offers_members_and_names_in_scope :: proc(t: ^testing.T) {
	main_text := "package main;\nimport \"lib\";\nColor :: enum { Red, Green }\nPoint :: struct { x, y: int }\nimpl Point {\n\tlength :: proc(self) -> int { return self.x + self.y; }\n}\n// Adds two numbers.\nadd :: proc(a, b: int) -> int { return a + b; }\nmain :: proc() {\n\tp := Point{1, 2};\n\tc := Color.Red;\n\t// p.\n\t_ = \"p.\";\n\t{\n\t\tinner := add(p.x, lib.twice(1));\n\t\t_ = inner;\n\t}\n\tlater := c;\n\tp.\n}\n"
	lib_text := "package lib;\n@(public) twice :: proc(n: int) -> int { return n * 2; }\nhidden :: proc() {}\n"
	for listed in ([]bool{false, true}) {
		h: Harness
		params := `{"capabilities":{"textDocument":{"completion":{"completionItem":{"documentationFormat":["markdown"]},"completionItemKind":{"valueSet":[2,3,5,6,7,9,13,14,20,21,22]}}}}}` if listed else `{"capabilities":{}}`
		if !start(&h, t, listed ? "completion-kinds" : "completion", params) { finish(&h); continue }
		write_file(&h, "lib/lib.loke", lib_text)
		open(&h, "main.loke", main_text)
		// The unfinished `p.` on the last line still knows what `p` is.
		reply := ask(&h, "textDocument/completion", "main.loke", position_of(t, main_text, "p.\n}", 2))
		testing.expect_value(t, completion_labels(reply, kinds = true), "length/2 x/5 y/5")
		reply = ask(&h, "textDocument/completion", "main.loke", position_of(t, main_text, "lib.twice", 4))
		testing.expect_value(t, completion_labels(reply), "twice")
		reply = ask(&h, "textDocument/completion", "main.loke", position_of(t, main_text, "Color.Red;", 6))
		testing.expect_value(t, completion_labels(reply, kinds = true), listed ? "Green/20 Red/20" : "Green/12 Red/12")

		// Names in scope, innermost first; not a later local, nor a field.
		reply = ask(&h, "textDocument/completion", "main.loke", position_of(t, main_text, "_ = inner", 4))
		labels := strings.split(completion_labels(reply, kinds = true), " ", context.temp_allocator)
		testing.expectf(t, len(labels) > 6 && labels[0] == "inner/6" && labels[1] == "c/6" && labels[2] == "p/6", "names: %v", labels)
		testing.expect(t, slice.contains(labels, listed ? "Point/22" : "Point/7") && slice.contains(labels, "lib/9") && slice.contains(labels, "add/3") && slice.contains(labels, "int/7"))
		testing.expect(t, !slice.contains(labels, "later/6") && !slice.contains(labels, "x/5") && !slice.contains(labels, "twice/3"))
		keyword, _ := member_int(completion_item(reply, "foreach"), "kind")
		testing.expect_value(t, keyword, i64(Completion_Kind.Keyword))
		add_item := completion_item(reply, "add")
		detail, _ := member_string(add_item, "detail")
		testing.expect_value(t, detail, "proc(a, b: int) -> int")
		documentation, _ := member_string(add_item, "documentation")
		if listed { documentation, _ = member_string(member(add_item, "documentation"), "value") }
		testing.expect_value(t, documentation, "Adds two numbers.")

		// Nothing inside a comment or a string.
		reply = ask(&h, "textDocument/completion", "main.loke", position_of(t, main_text, "// p.", 5))
		testing.expect(t, len(member_array(member(reply, "result"), "items")) == 0)
		reply = ask(&h, "textDocument/completion", "main.loke", position_of(t, main_text, "\"p.\"", 3))
		testing.expect(t, len(member_array(member(reply, "result"), "items")) == 0)
		finish(&h)
	}
}

// "label;label @signature/parameter", or "null".
@(private = "file")
signature_summary :: proc(reply: json.Value) -> string {
	result := member(reply, "result")
	if _, is_null := result.(json.Null); is_null || result == nil { return "null" }
	b := strings.builder_make(context.temp_allocator)
	for signature, index in member_array(result, "signatures") {
		if index > 0 { strings.write_byte(&b, ';') }
		label, _ := member_string(signature, "label")
		strings.write_string(&b, label)
	}
	active_signature, _ := member_int(result, "activeSignature")
	active_parameter, _ := member_int(result, "activeParameter")
	fmt.sbprintf(&b, " @%d/%d", active_signature, active_parameter)
	return strings.to_string(b)
}

@(test)
signature_help_follows_the_argument_being_written :: proc(t: ^testing.T) {
	text := "package main;\nPoint :: struct { x, y: int }\nimpl Point {\n\tscale :: proc(self, factor: int) -> Point { return {self.x * factor, self.y * factor}; }\n}\n// Adds two numbers.\nadd :: proc(a, b: int) -> int { return a + b; }\nplain :: proc(value: int) -> int { return value; }\nfloating :: proc(value: f64) -> f64 { return value; }\npick :: proc{plain, floating};\nmain :: proc() {\n\tp := Point{1, 2};\n\t_ = p.scale(2);\n\t_ = pick(1);\n\t_ = add(plain(1), 2);\n\t_ = add(b = 2, a = 1);\n\tif (add(1, 2) > 0) {}\n\tadd(1, \n}\n"
	for offsets in ([]bool{true, false}) {
		h: Harness
		params := `{"capabilities":{"textDocument":{"signatureHelp":{"signatureInformation":{"parameterInformation":{"labelOffsetSupport":true}}}}}}` if offsets else `{"capabilities":{}}`
		if !start(&h, t, offsets ? "signatures-offsets" : "signatures", params) { finish(&h); continue }
		open(&h, "main.loke", text)
		// The unfinished call on the last line is still a call to `add`.
		reply := ask(&h, "textDocument/signatureHelp", "main.loke", position_of(t, text, "add(1, \n", 7))
		testing.expect_value(t, signature_summary(reply), "add :: proc(a, b: int) -> int @0/1")
		signature := member_array(member(reply, "result"), "signatures")[0]
		documentation, _ := member_string(signature, "documentation")
		testing.expect_value(t, documentation, "Adds two numbers.")
		first := member_array(signature, "parameters")[0]
		if offsets {
			bounds := member_array(first, "label")
			testing.expect(t, len(bounds) == 2 && bounds[0].(json.Integer) == 12 && bounds[1].(json.Integer) == 13)
		} else {
			label, _ := member_string(first, "label")
			testing.expect_value(t, label, "a")
		}
		// A method call supplies `self` before the parentheses.
		reply = ask(&h, "textDocument/signatureHelp", "main.loke", position_of(t, text, "scale(2", 6))
		testing.expect_value(t, signature_summary(reply), "scale :: proc(self, factor: int) -> Point @0/1")
		reply = ask(&h, "textDocument/signatureHelp", "main.loke", position_of(t, text, "pick(1", 5))
		testing.expect_value(t, signature_summary(reply), "plain :: proc(value: int) -> int @0/0")
		// The innermost open call is the one shown.
		reply = ask(&h, "textDocument/signatureHelp", "main.loke", position_of(t, text, "plain(1), 2", 6))
		testing.expect_value(t, signature_summary(reply), "plain :: proc(value: int) -> int @0/0")
		reply = ask(&h, "textDocument/signatureHelp", "main.loke", position_of(t, text, "plain(1), 2", 10))
		testing.expect_value(t, signature_summary(reply), "add :: proc(a, b: int) -> int @0/1")
		reply = ask(&h, "textDocument/signatureHelp", "main.loke", position_of(t, text, "b = 2, a", 4))
		testing.expect_value(t, signature_summary(reply), "add :: proc(a, b: int) -> int @0/1")
		// Neither a statement's parentheses nor a literal's braces are a call.
		reply = ask(&h, "textDocument/signatureHelp", "main.loke", position_of(t, text, "if (add", 4))
		testing.expect_value(t, signature_summary(reply), "null")
		reply = ask(&h, "textDocument/signatureHelp", "main.loke", position_of(t, text, "Point{1, 2}", 8))
		testing.expect_value(t, signature_summary(reply), "null")
		finish(&h)
	}
}

// The LSP signature-help contract counts label offsets in UTF-16 units under
// any position encoding, and a parameter's place is its name, not a type
// spelled the same way.
@(test)
signature_labels_count_utf16_at_parameter_names :: proc(t: ^testing.T) {
	text := "package main;\nPoint :: struct { x: int }\nf :: proc(a: string = \"é\", b: int = 0) {}\ng :: proc(a: Point, Point: int) {}\nmain :: proc() {\n\tf();\n\tg(Point{1}, 2);\n}\n"
	h: Harness
	if !start(&h, t, "signature-labels", `{"capabilities":{"general":{"positionEncodings":["utf-8"]},"textDocument":{"signatureHelp":{"signatureInformation":{"parameterInformation":{"labelOffsetSupport":true}}}}}}`) { finish(&h); return }
	defer finish(&h)
	open(&h, "main.loke", text)
	Case :: struct { needle: string, at, parameter, lo, hi: int }
	for c in ([]Case{{"f();", 2, 1, 27, 28}, {"g(Point{1}", 2, 1, 20, 25}}) {
		reply := ask(&h, "textDocument/signatureHelp", "main.loke", position_of(t, text, c.needle, c.at))
		signatures := member_array(member(reply, "result"), "signatures")
		if !testing.expectf(t, len(signatures) == 1, "%s: %v", c.needle, reply) { continue }
		parameters := member_array(signatures[0], "parameters")
		if !testing.expect(t, len(parameters) > c.parameter) { continue }
		bounds := member_array(parameters[c.parameter], "label")
		testing.expectf(t, len(bounds) == 2 && bounds[0].(json.Integer) == i64(c.lo) && bounds[1].(json.Integer) == i64(c.hi), "%s: %v", c.needle, bounds)
	}
}

// Two programs that share a library through their manifests.
@(private = "file")
shared_library :: proc(h: ^Harness, app, lib: string) {
	for name in ([]string{"app1", "app2"}) {
		write_file(h, fmt.tprintf("%s/loke.project", name), "require lib ../lib\n")
		write_file(h, fmt.tprintf("%s/main.loke", name), app)
		open(h, fmt.tprintf("%s/main.loke", name), app)
	}
	write_file(h, "lib/lib.loke", lib)
	open(h, "lib/lib.loke", lib)
	settle(h)
	take(h)
}

// "file:line" for each location, relative to the harness root.
@(private = "file")
describe_locations :: proc(h: ^Harness, reply: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	prefix := path_to_uri(h.root, context.temp_allocator)
	result, _ := member(reply, "result").(json.Array)
	for location, index in result {
		if index > 0 { strings.write_byte(&b, ' ') }
		uri, _ := member_string(location, "uri")
		fmt.sbprintf(&b, "%s:%d", strings.trim_prefix(uri, fmt.tprintf("%s/", prefix)), start_of(location).line + 1)
	}
	return strings.to_string(b)
}

@(test)
references_follow_one_binding_across_programs :: proc(t: ^testing.T) {
	app := "package main;\nimport lib \"lib:\";\nmain :: proc() {\n\tvalue := lib.twice(1);\n\t{\n\t\tvalue := 2;\n\t\t_ = value;\n\t}\n\t_ = lib.twice(value);\n}\n"
	lib_text := "package lib;\n@(public) twice :: proc(n: int) -> int { return n * 2; }\n"
	h: Harness
	if !start(&h, t, "references") { finish(&h); return }
	defer finish(&h)
	shared_library(&h, app, lib_text)
	testing.expect_value(t, len(h.s.roots), 2)
	// The shadowing inner `value` is another binding.
	reply := ask(&h, "textDocument/references", "app1/main.loke", position_of(t, app, "value := lib"), `,"context":{"includeDeclaration":true}`)
	testing.expect_value(t, describe_locations(&h, reply), "app1/main.loke:4 app1/main.loke:9")
	reply = ask(&h, "textDocument/references", "app1/main.loke", position_of(t, app, "value);"), `,"context":{"includeDeclaration":false}`)
	testing.expect_value(t, describe_locations(&h, reply), "app1/main.loke:9")
	// Both programs' uses of the library's procedure.
	reply = ask(&h, "textDocument/references", "lib/lib.loke", position_of(t, lib_text, "twice ::"), `,"context":{"includeDeclaration":true}`)
	testing.expect_value(t, describe_locations(&h, reply), "app1/main.loke:4 app1/main.loke:9 app2/main.loke:4 app2/main.loke:9 lib/lib.loke:2")
	reply = ask(&h, "textDocument/references", "app2/main.loke", position_of(t, app, "{\n"), `,"context":{"includeDeclaration":true}`)
	testing.expect(t, is_null_result(reply), "no binding, no references")
}

// "file:count" for each file a rename edits, or the refusal's message.
@(private = "file")
describe_rename :: proc(h: ^Harness, reply: json.Value) -> string {
	if message, failed := member_string(member(reply, "error"), "message"); failed { return message }
	changes, _ := member(member(reply, "result"), "changes").(json.Object)
	prefix := fmt.tprintf("%s/", path_to_uri(h.root, context.temp_allocator))
	files := make([dynamic]string, context.temp_allocator)
	for uri, edits in changes {
		append(&files, fmt.tprintf("%s:%d", strings.trim_prefix(uri, prefix), len(edits.(json.Array))))
	}
	slice.sort(files[:])
	return strings.join(files[:], " ", context.temp_allocator)
}

@(private = "file")
rename_to :: proc(h: ^Harness, relative, text, needle, name: string) -> string {
	return describe_rename(h, ask(h, "textDocument/rename", relative, position_of(h.t, text, needle), fmt.tprintf(`,"newName":%s`, quoted(name))))
}

@(test)
rename_changes_every_use_or_refuses :: proc(t: ^testing.T) {
	app := "package main;\nimport lib \"lib:\";\nPoint :: struct { x, y: int }\nscaled :: proc(p: Point, factor: int) -> Point { return Point{x = p.x * factor, y = p.y * factor}; }\nmain :: proc() {\n\tvalue := lib.twice(1);\n\t{\n\t\tother := 2;\n\t\t_ = other;\n\t\textra := 3;\n\t\t_ = extra;\n\t}\n\tp := scaled(Point{1, 2}, factor = value);\n\t_ = lib.twice(p.x);\n}\n"
	lib_text := "package lib;\n@(public) twice :: proc(n: int) -> int { return n * 2; }\n@(public) thrice :: proc(n: int) -> int { lib := n * 3; return lib; }\n"
	h: Harness
	if !start(&h, t, "rename", `{"capabilities":{"textDocument":{"rename":{"prepareSupport":true}}}}`) { finish(&h); return }
	defer finish(&h)
	shared_library(&h, app, lib_text)

	// Every program that loads the library, and the library itself.
	testing.expect_value(t, rename_to(&h, "app1/main.loke", app, "twice(1)", "double"), "app1/main.loke:2 app2/main.loke:2 lib/lib.loke:1")
	// A parameter with its named argument; a field with its literal key.
	testing.expect_value(t, rename_to(&h, "app1/main.loke", app, "factor: int", "scale"), "app1/main.loke:4")
	reply := ask(&h, "textDocument/rename", "app1/main.loke", position_of(t, app, "factor: int"), `,"newName":"scale"`)
	scaled_app, _ := strings.replace_all(app, "factor", "scale", context.temp_allocator)
	testing.expect_value(t, apply_edits(app, member_array(member(member(reply, "result"), "changes"), uri_of(&h, "app1/main.loke"))), scaled_app)
	testing.expect_value(t, rename_to(&h, "app1/main.loke", app, "x, y", "z"), "app1/main.loke:4")
	testing.expect_value(t, rename_to(&h, "app1/main.loke", app, "value := lib", "value"), "")
	testing.expect_value(t, rename_to(&h, "app1/main.loke", app, "Point ::", "Spot"), "app1/main.loke:5")
	// The package clause and the import alias spelled `lib` name packages.
	testing.expect_value(t, rename_to(&h, "lib/lib.loke", lib_text, "lib := n", "tripled"), "lib/lib.loke:2")

	refusals := []struct { needle, name, message: string } {
		{"other := 2", "value", "`value` already names"},
		{"other := 2", "extra", "in the same scope"},
		// The inner `other` would shadow the renamed outer local.
		{"value := lib", "other", "a local cannot shadow another"},
		{"value := lib", "p", "in the same scope"},
		{"value := lib", "int", "the predeclared `int`"},
		{"scaled ::", "main", "`main` already names"},
		{"twice(1)", "thrice", "`thrice` already names"},
		{"x, y", "y", "`Point` already has a member `y`."},
		{"value := lib", "1x", "`1x` is not a name."},
		{"value := lib", "proc", "`proc` is not a name."},
		{"value := lib", "_", "`_` is not a name."},
	}
	for refusal in refusals {
		got := rename_to(&h, "app1/main.loke", app, refusal.needle, refusal.name)
		testing.expectf(t, strings.contains(got, refusal.message), "renaming at %q to %q: %s", refusal.needle, refusal.name, got)
	}
	reply = ask(&h, "textDocument/prepareRename", "app1/main.loke", position_of(t, app, "value := lib"))
	placeholder, _ := member_string(member(reply, "result"), "placeholder")
	testing.expect(t, placeholder == "value" && start_of(member(reply, "result")) == position_of(t, app, "value := lib"))
	reply = ask(&h, "textDocument/prepareRename", "app1/main.loke", position_of(t, app, "int) -> Point"))
	message, _ := member_string(member(reply, "error"), "message")
	testing.expect_value(t, message, "`int` has no written declaration to rename.")

	// Code the compiler did not check could use the name either way.
	inactive := "package lib;\n@(public) twice :: proc(n: int) -> int { return n * 2; }\n@(public) thrice :: proc(n: int) -> int { lib := n * 3; return lib; }\nwhen (false) { extra :: proc() -> int { return twice(2); } }\n"
	change(&h, "lib/lib.loke", inactive, 2)
	got := rename_to(&h, "app1/main.loke", app, "twice(1)", "double")
	testing.expectf(t, strings.has_prefix(got, "`twice` at ") && strings.contains(got, "has no binding the compiler recorded"), "%s", got)
	change(&h, "lib/lib.loke", lib_text, 3)
	// Every program that reads the binding must check first.
	broken := "package main;\nimport lib \"lib:\";\nmain :: proc() { _ = lib.twice(\"text\"); }\n"
	change(&h, "app2/main.loke", broken, 2)
	got = rename_to(&h, "app1/main.loke", app, "twice(1)", "double")
	testing.expectf(t, strings.has_prefix(got, "Rename needs every program that loads the binding to check without errors first"), "%s", got)
	// A program that does not read it does not matter.
	testing.expect_value(t, rename_to(&h, "app1/main.loke", app, "value := lib", "total"), "app1/main.loke:2")
}

@(test)
rename_leaves_the_bundled_library_alone :: proc(t: ^testing.T) {
	text := "package main;\nimport \"core:fmt\";\nmain :: proc() { fmt.println(1); }\n"
	h: Harness
	if !start(&h, t, "rename-bundled") { finish(&h); return }
	defer finish(&h)
	open(&h, "main.loke", text)
	reply := ask(&h, "textDocument/rename", "main.loke", position_of(t, text, "println"), `,"newName":"say"`)
	message, _ := member_string(member(reply, "error"), "message")
	testing.expect_value(t, message, "`println` belongs to the library bundled with the compiler.")
}

// known-gaps.md findings: renames the language's own rules make unsafe.
@(test)
rename_follows_lookup_rules_from_review :: proc(t: ^testing.T) {
	Case :: struct { name, text, needle, new_name, expected: string }
	cases := []Case {
		// A promoted field loses to an outer one of the same name.
		{"promoted", "package main;\nInner :: struct { old: int }\nOuter :: struct { using inner: Inner, next: int }\nmain :: proc() { outer := Outer{Inner{1}, 2}; _ = outer.old; }\n", "old: int", "next", "would select the existing member `next`"},
		{"promoted-free", "package main;\nInner :: struct { old: int }\nOuter :: struct { using inner: Inner, next: int }\nmain :: proc() { outer := Outer{Inner{1}, 2}; _ = outer.old; }\n", "old: int", "renamed", "main.loke:2"},
		// Parentheses around the operand do not hide what it selects.
		{"promoted-paren", "package main;\nInner :: struct { old: int }\nOuter :: struct { using inner: Inner, next: int }\nmain :: proc() { outer := Outer{Inner{1}, 2}; _ = (outer).old; }\n", "old: int", "next", "would select the existing member `next`"},
		{"promoted-paren-free", "package main;\nInner :: struct { old: int }\nOuter :: struct { using inner: Inner, next: int }\nmain :: proc() { outer := Outer{Inner{1}, 2}; _ = ((outer)).old; }\n", "old: int", "renamed", "main.loke:2"},
		// A use of the new name could reach the renamed field once renamed.
		{"promoted-new", "package main;\nA :: struct { old: int }\nB :: struct { next: int }\nOuter :: struct { using a: A, using b: B }\nmain :: proc() { o := Outer{A{1}, B{2}}; _ = o.next; }\n", "old: int", "next", "could select the renamed `old`"},
		{"promoted-new-nearer", "package main;\nA :: struct { old: int }\nOuter :: struct { using a: A, next: int }\nmain :: proc() { o := Outer{A{1}, 2}; _ = o.next; _ = o.a.old; }\n", "old: int", "next", "main.loke:2"},
		// Two `using` branches are ambiguous whatever their depths, in either order.
		{"promoted-new-deeper-first", "package main;\nA :: struct { old: int }\nLeft :: struct { using a: A }\nB :: struct { next: int }\nOuter :: struct { using left: Left, using b: B }\nmain :: proc() { o := Outer{Left{A{1}}, B{2}}; _ = o.next; }\n", "old: int", "next", "could select the renamed `old`"},
		{"promoted-new-deeper-last", "package main;\nA :: struct { old: int }\nLeft :: struct { using a: A }\nB :: struct { next: int }\nOuter :: struct { using b: B, using left: Left }\nmain :: proc() { o := Outer{B{2}, Left{A{1}}}; _ = o.next; }\n", "old: int", "next", "could select the renamed `old`"},
		// Only a field declared on the same branch hides the renamed one.
		{"promoted-new-hidden", "package main;\nA :: struct { old: int }\nLeft :: struct { using a: A, next: int }\nOuter :: struct { using left: Left }\nmain :: proc() { o := Outer{Left{A{1}, 2}}; _ = o.next; _ = o.a.old; }\n", "old: int", "next", "main.loke:2"},
		// Through a pointer, and a distinct one.
		{"promoted-new-pointer", "package main;\nA :: struct { old: int }\nB :: struct { next: int }\nOuter :: struct { using a: A, using b: B }\nmain :: proc() { o := Outer{A{1}, B{2}}; p := &o; _ = p.next; }\n", "old: int", "next", "could select the renamed `old`"},
		{"promoted-new-distinct", "package main;\nA :: struct { old: int }\nB :: struct { next: int }\nOuter :: struct { using a: A, using b: B }\nP :: distinct ^Outer;\nmain :: proc() { o := Outer{A{1}, B{2}}; p := P(&o); _ = p.next; }\n", "old: int", "next", "could select the renamed `old`"},
		// A selector in a generic is checked in each instance.
		{"generic", "package main;\nInner :: struct { old: int }\nread :: proc(value: $T) -> int { return value.old; }\nmain :: proc() { _ = read(Inner{1}); }\n", "old: int", "renamed", "main.loke:2"},
		{"generic-agree", "package main;\nInner :: struct { old: int }\nread :: proc(value: $T, extra: $U) -> int { return value.old; }\nmain :: proc() { _ = read(Inner{1}, 1); _ = read(Inner{2}, true); }\n", "old: int", "renamed", "main.loke:2"},
		{"generic-differ", "package main;\nInner :: struct { old: int }\nOther :: struct { old: int }\nread :: proc(value: $T) -> int { return value.old; }\nmain :: proc() { _ = read(Inner{1}); _ = read(Other{2}); }\n", "old: int", "renamed", "rename cannot"},
		// A pointer's own method is found before its referent's.
		{"pointer-method", "package main;\nItem :: struct { n: int }\nimpl Item { old :: proc(self) -> int { return self.n; } }\nimpl ^Item { other :: proc(self) -> int { return self.n + 10; } }\nmain :: proc() { item := Item{1}; p := &item; assert(p.old() == 1); _ = p.other(); }\n", "old ::", "other", "would select the existing member `other`"},
		{"pointer-method-free", "package main;\nItem :: struct { n: int }\nimpl Item { old :: proc(self) -> int { return self.n; } }\nimpl ^Item { other :: proc(self) -> int { return self.n + 10; } }\nmain :: proc() { item := Item{1}; p := &item; assert(p.old() == 1); _ = p.other(); }\n", "old ::", "fresh", "main.loke:2"},
		// A named argument names the callee's parameter, not a caller's local.
		{"label", "package main;\nf :: proc(old: int) {}\nmain :: proc() { next := 1; f(old = next); }\n", "old: int", "next", "main.loke:2"},
		// A local cannot shadow an outer local, even one not used there.
		{"shadow", "package main;\nmain :: proc() {\n\told := 1;\n\t{ next := 2; _ = next; }\n\t_ = old;\n}\n", "old := 1", "next", "a local cannot shadow another"},
		// A selected `when` branch opens no scope.
		{"when", "package main;\nmain :: proc() {\n\twhen (true) { old := 1; _ = old; }\n\tnext := 2; _ = next;\n}\n", "old := 1", "next", "in the same scope"},
		// A public extension is also one of its package's names.
		{"extension", "package main;\nplain :: proc() -> int { return 2; }\nimpl int { @(public) old :: proc(self) -> int { return self; } }\nmain :: proc() { _ = plain(); _ = (1).old(); }\n", "old ::", "plain", "`plain` already names"},
		{"extension-free", "package main;\nplain :: proc() -> int { return 2; }\nimpl int { @(public) old :: proc(self) -> int { return self; } }\nmain :: proc() { _ = plain(); _ = (1).old(); }\n", "old ::", "fresh", "main.loke:2"},
		// `self` makes a method; `call` is used by `p()`.
		{"self", "package main;\nPoint :: struct { x: int }\nimpl Point { read :: proc(self) -> int { return self.x; } }\nmain :: proc() { p := Point{1}; _ = p.read(); }\n", "self) -> int", "receiver", "`self` marks a method's receiver"},
		{"call", "package main;\nPoint :: struct { x: int }\nimpl Point { call :: proc(self) -> int { return self.x; } }\nmain :: proc() { p := Point{1}; _ = p(); }\n", "call ::", "invoke", "`call` is a member name the compiler or an interface looks up by name"},
		{"to-call", "package main;\nPoint :: struct { x: int }\nimpl Point { read :: proc(self) -> int { return self.x; } }\nmain :: proc() { p := Point{1}; _ = p.read(); }\n", "read ::", "call", "`call` is a member name"},
		// grammar.md "Keywords": a member may be renamed to or from a reserved
		// word, which still marks a keyword wherever no member is named.
		{"to-keyword", "package main;\nKind :: enum { old, other }\nmain :: proc() { k := Kind.old; switch (k) { case .old: default: } }\n", "old, other", "default", "main.loke:3"},
		{"from-keyword", "package main;\nKind :: enum { default, other }\nmain :: proc() { k := Kind.default; switch (k) { case .default: default: } }\n", "default, other", "plain", "main.loke:3"},
		{"keyword-local", "package main;\nmain :: proc() { old := 1; _ = old; }\n", "old := 1", "map", "`map` is not a name."},
		// `[dynamic]` is always the dynamic array.
		{"dynamic-length", "package main;\nN :: 2;\nmain :: proc() { a: [N]int = {}; _ = a; }\n", "N ::", "dynamic", "would be a dynamic array"},
	}
	h: Harness
	if !start(&h, t, "rename-rules") { finish(&h); return }
	defer finish(&h)
	for c in cases {
		relative := fmt.tprintf("%s/main.loke", c.name)
		open(&h, relative, c.text)
		reply := ask(&h, "textDocument/rename", relative, position_of(t, c.text, c.needle), fmt.tprintf(`,"newName":%s`, quoted(c.new_name)))
		got := describe_rename(&h, reply)
		testing.expectf(t, strings.contains(got, c.expected), "%s: %s", c.name, got)
		if member(reply, "result") != nil { renamed_uses_bind_to_declaration(&h, relative, c.text, c.needle, reply) }
		close(&h, relative)
		settle(&h)
		take(&h)
	}
}

// After a rename's edits are applied, the text checks and every renamed name
// still names the renamed declaration, so no use was captured.
@(private = "file")
renamed_uses_bind_to_declaration :: proc(h: ^Harness, relative, text, needle: string, reply: json.Value, loc := #caller_location) {
	t := h.t
	edits := member_array(member(member(reply, "result"), "changes"), uri_of(h, relative))
	renamed := apply_edits(text, edits)
	declaration := position_of(t, text, needle)
	// Where each edit starts in the renamed text, and which is the declaration.
	starts := make([dynamic]Position, context.temp_allocator)
	declared := Position{-1, -1}
	delta := 0
	for edit in edits {
		range := member(edit, "range")
		lo := position_to_offset(text, json_position(member(range, "start")), false)
		hi := position_to_offset(text, json_position(member(range, "end")), false)
		new_text, _ := member_string(edit, "newText")
		at := lo + delta
		position := Position{strings.count(renamed[:at], "\n"), at - (strings.last_index_byte(renamed[:at], '\n') + 1)}
		if json_position(member(range, "start")) == declaration { declared = position }
		append(&starts, position)
		delta += len(new_text) - (hi - lo)
	}
	change(h, relative, renamed, 2)
	settle(h)
	for p in publications(take(h)) {
		testing.expectf(t, len(p.diagnostics) == 0, "%s renamed: %v", relative, p.diagnostics, loc = loc)
	}
	testing.expectf(t, declared.line >= 0, "%s: no edit at the declaration", relative, loc = loc)
	for start in starts {
		expect_definition(t, ask(h, "textDocument/definition", relative, start), uri_of(h, relative), declared, loc = loc)
	}
}

// known-gaps.md findings: a selected `when` branch's declarations stay in
// scope after it, and a nested block comment holds the cursor to its end.
@(test)
completion_follows_scopes_and_comments_from_review :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "completion-rules") { finish(&h); return }
	defer finish(&h)
	text := "package main;\nmain :: proc() {\n\twhen (true) { old := 1; _ = old; }\n\t_ = old;\n\t/* outer /* inner */ still here */\n}\n"
	open(&h, "main.loke", text)
	reply := ask(&h, "textDocument/completion", "main.loke", position_of(t, text, "old;\n\t/*", 2))
	testing.expect(t, strings.has_prefix(completion_labels(reply), "old main"), completion_labels(reply))
	reply = ask(&h, "textDocument/completion", "main.loke", position_of(t, text, "still here", 3))
	testing.expect(t, len(member_array(member(reply, "result"), "items")) == 0, "inside the outer comment")
	reply = ask(&h, "textDocument/signatureHelp", "main.loke", position_of(t, text, "still here", 3))
	testing.expect(t, is_null_result(reply))
}

// A literal the lexer rejects, unterminated or with an invalid escape, still
// holds the cursor; one that is closed ends where it closes.
@(test)
completion_stays_in_rejected_literals :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "completion-literals") { finish(&h); return }
	defer finish(&h)
	Case :: struct { name, tail, needle: string, at: int, inside: bool }
	cases := []Case {
		{"string", "main :: proc() { f(\"abc", "\"abc", 3, true},
		{"raw", "main :: proc() { f(`abc", "`abc", 3, true},
		{"rune", "main :: proc() { r := 'a", "'a", 2, true},
		{"escape", "main :: proc() { f(\"a\\qb\"); }\n", "\\qb", 2, true},
		{"after-escape", "main :: proc() { f(\"a\\qb\"); }\n", "); }", 2, false},
	}
	for c in cases {
		relative := fmt.tprintf("%s.loke", c.name)
		text := fmt.tprintf("package main;\nf :: proc(s: string) {{}}\n%s", c.tail)
		open(&h, relative, text)
		reply := ask(&h, "textDocument/completion", relative, position_of(t, text, c.needle, c.at))
		items := len(member_array(member(reply, "result"), "items"))
		testing.expectf(t, (items == 0) == c.inside, "%s: %d items", c.name, items)
		if c.inside {
			reply = ask(&h, "textDocument/signatureHelp", relative, position_of(t, text, c.needle, c.at))
			testing.expectf(t, is_null_result(reply), "%s: signature help inside the literal", c.name)
		}
		close(&h, relative)
		settle(&h)
		take(&h)
	}
}

// A completion detail puts the signature on one line without touching its
// literals.
@(test)
completion_detail_keeps_literal_text :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "completion-detail") { finish(&h); return }
	defer finish(&h)
	text := "package main;\nf :: proc(value: string = \"a  b\",\n\tcount: int = 1,\n) {}\nmain :: proc() {\n\tf();\n}\n"
	open(&h, "main.loke", text)
	reply := ask(&h, "textDocument/completion", "main.loke", position_of(t, text, "f();"))
	detail := ""
	for item in member_array(member(reply, "result"), "items") {
		if label, _ := member_string(item, "label"); label == "f" { detail, _ = member_string(item, "detail") }
	}
	testing.expect_value(t, detail, "proc(value: string = \"a  b\", count: int = 1)")
}

// Unsaved text for `fresh_codes`, relative to the harness root.
@(private = "file")
Unsaved :: struct { relative, text: string }

// Each file's diagnostic codes, sorted, from a fresh batch check of `root`
// with `unsaved` as overlays: what `lokec` reports for the same inputs. Files
// without diagnostics are left out.
@(private = "file")
fresh_codes :: proc(h: ^Harness, root: string, unsaved: []Unsaved) -> map[string]string {
	s: lokec.Compilation_Session
	defer lokec.destroy_session(&s)
	testing.expect(h.t, lokec.init_session(&s))
	for file in unsaved {
		testing.expect(h.t, lokec.set_session_overlay(&s, lokec.join_path({h.root, file.relative}, context.temp_allocator), file.text))
	}
	lokec.check_session(&s, lokec.join_path({h.root, root}, context.temp_allocator))
	snapshot, _ := lokec.session_snapshot(&s)
	diagnostics, _ := lokec.query_diagnostics(&s, snapshot)
	lists := make(map[string][dynamic]string, context.temp_allocator)
	for d in diagnostics {
		source, found := lokec.query_source(&s, snapshot, d.location.span.file)
		if !testing.expect(h.t, found) { continue }
		uri := path_to_uri(lokec.canonical_dir(source.path), context.temp_allocator)
		if uri not_in lists { lists[uri] = make([dynamic]string, context.temp_allocator) }
		append(&lists[uri], strings.clone(d.code, context.temp_allocator))
	}
	out := make(map[string]string, context.temp_allocator)
	for uri, list in lists {
		slice.sort(list[:])
		out[uri] = strings.join(list[:], " ", context.temp_allocator)
	}
	return out
}

// What the client is showing: the latest publication for each URI, with its
// codes sorted. A publication emptying a file removes it.
@(private = "file")
record_publications :: proc(shown: ^map[string]string, messages: []json.Value) {
	for p in publications(messages) {
		list := strings.split(codes(p.diagnostics), " ", context.temp_allocator)
		slice.sort(list)
		if len(p.diagnostics) == 0 { delete_key(shown, p.uri) } else { shown[p.uri] = strings.join(list, " ", context.temp_allocator) }
	}
}

@(private = "file")
expect_shown :: proc(t: ^testing.T, shown, fresh: map[string]string, loc := #caller_location) {
	testing.expect_value(t, len(shown), len(fresh), loc = loc)
	for uri, list in fresh {
		testing.expectf(t, shown[uri] == list, "%s shows %q, but a fresh check reports %q", uri, shown[uri], list, loc = loc)
	}
}

@(private = "file")
only_root :: proc(h: ^Harness) -> ^Root {
	testing.expect_value(h.t, len(h.s.roots), 1)
	for _, root in h.s.roots { return root }
	return nil
}

// Edits that arrive faster than checks, across two packages and through broken
// text, end with what a fresh check of the final text reports, published once
// with the final versions. Checks reuse what the edits did not reach.
@(test)
rapid_edits_match_a_fresh_check :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "rapid") { finish(&h); return }
	defer finish(&h)
	main_text := "package main;\nimport \"core:fmt\";\nimport \"shapes\";\nmain :: proc() {\n\tfmt.println(shapes.area(shapes.Square{side = 2}), shapes.separator());\n}\n"
	shapes_text := "@(public) package shapes;\nimport \"core:path\";\nSquare :: struct { side: int }\narea :: proc(s: Square) -> int { return s.side * s.side; }\nseparator :: proc() -> rune { return path.separator(); }\n"
	write_file(&h, "app/main.loke", main_text)
	write_file(&h, "app/shapes/shapes.loke", shapes_text)
	open(&h, "app/main.loke", main_text)
	open(&h, "app/shapes/shapes.loke", shapes_text)
	settle(&h)
	shown := make(map[string]string, context.temp_allocator)
	record_publications(&shown, take(&h))
	testing.expect_value(t, len(shown), 0)

	replace :: proc(text, old, new: string) -> string {
		out, _ := strings.replace_all(text, old, new, context.temp_allocator)
		return out
	}
	Edit :: struct { relative, text: string }
	edits := [?]Edit{
		{"app/main.loke", replace(main_text, "Square{side = 2}", "Square{side = 2")},
		{"app/main.loke", replace(main_text, "Square{side = 2}", "Square{side = \"two\"}")},
		{"app/shapes/shapes.loke", replace(shapes_text, "area ::", "surface ::")},
		{"app/main.loke", replace(main_text, "shapes.area", "shapes.surface")},
		{"app/shapes/shapes.loke", replace(shapes_text, "s.side * s.side", "s.side * true")},
		{"app/main.loke", replace(main_text, "shapes.area", "shapes.")},
		{"app/main.loke", replace(main_text, "shapes.area", "shapes.surface")},
	}
	versions := [2]int{1, 1}
	for edit, index in edits {
		slot := 0 if edit.relative == "app/main.loke" else 1
		versions[slot] += 1
		change(&h, edit.relative, edit.text, versions[slot])
		// Now and then a check starts between two edits.
		if index % 3 == 1 { run_pending_work(&h.s) }
	}
	settle(&h)
	messages := take(&h)
	for p in publications(messages) {
		expected := versions[0] if p.uri == uri_of(&h, "app/main.loke") else versions[1]
		testing.expectf(t, p.versioned && p.version == i64(expected), "%s: published version %d, not %d", p.uri, p.version, expected)
	}
	record_publications(&shown, messages)
	final := []Unsaved{
		{"app/main.loke", replace(main_text, "shapes.area", "shapes.surface")},
		{"app/shapes/shapes.loke", replace(shapes_text, "s.side * s.side", "s.side * true")},
	}
	expect_shown(t, shown, fresh_codes(&h, "app", final))
	// `main` names a procedure the library no longer has, and the library has
	// its own error.
	testing.expect_value(t, len(shown), 2)

	// Repairing the library rechecks it; editing `main` alone reuses it.
	change(&h, "app/shapes/shapes.loke", replace(shapes_text, "area ::", "surface ::"), versions[1] + 1)
	settle(&h)
	record_publications(&shown, take(&h))
	testing.expect_value(t, len(shown), 0)
	root := only_root(&h)
	if root == nil { return }
	shapes := root.session.compiler.package_by_dir[lokec.dir_key(lokec.canonical_dir(lokec.join_path({h.root, "app", "shapes"}, context.temp_allocator)))]
	testing.expect(t, slice.contains(lokec.session_check_stats(&root.session).rechecked_packages, shapes))
	change(&h, "app/main.loke", replace(main_text, "shapes.area(shapes.Square{side = 2})", "shapes.surface(shapes.Square{side = 3})"), versions[0] + 1)
	settle(&h)
	record_publications(&shown, take(&h))
	testing.expect_value(t, len(shown), 0)
	stats := lokec.session_check_stats(&root.session)
	testing.expect(t, slice.contains(stats.reused_packages, shapes), "an edit to `main` rechecked the library")
	testing.expect_value(t, len(stats.rechecked_packages), 1)
}

// Requests answered from incremental checks: one whose document changes while
// it waits is stale, a cancelled one is answered as cancelled, and the rest see
// unsaved edits in both packages, even while `main` does not parse.
@(test)
requests_follow_incremental_checks :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "incremental-requests") { finish(&h); return }
	defer finish(&h)
	main_text := "package main;\nimport \"shapes\";\nmain :: proc() {\n\t_ = shapes.area(shapes.Square{side = 2});\n}\n"
	shapes_text := "@(public) package shapes;\nSquare :: struct { side: int }\narea :: proc(s: Square) -> int { return s.side * s.side; }\n"
	write_file(&h, "app/main.loke", main_text)
	write_file(&h, "app/shapes/shapes.loke", shapes_text)
	open(&h, "app/main.loke", main_text)
	open(&h, "app/shapes/shapes.loke", shapes_text)
	settle(&h)
	take(&h)

	renamed := "@(public) package shapes;\nSquare :: struct { side: int }\n\n// The area.\nsurface :: proc(s: Square) -> int { return s.side * s.side; }\n"
	uses := "package main;\nimport \"shapes\";\nmain :: proc() {\n\t_ = shapes.surface(shapes.Square{side = 2});\n}\n"
	change(&h, "app/shapes/shapes.loke", renamed, 2)
	at_area := fmt.tprintf(`{{"textDocument":{{"uri":%s}},"position":{{"line":3,"character":14}}}}`, quoted(uri_of(&h, "app/main.loke")))
	request(&h, "10", "textDocument/hover", at_area)
	// The check starts; `main` changes before the answer.
	testing.expect(t, run_pending_work(&h.s))
	change(&h, "app/main.loke", uses, 2)
	settle(&h)
	modified := false
	for reply in take(&h) {
		if id, _ := member_int(reply, "id"); id == 10 { modified = error_code(reply) == CONTENT_MODIFIED }
	}
	testing.expect(t, modified, "the hover was answered from text the document no longer has")
	expect_definition(t, ask(&h, "textDocument/definition", "app/main.loke", position_of(t, uses, "surface")), uri_of(&h, "app/shapes/shapes.loke"), Position{4, 0})
	testing.expect_value(t, hover_value(ask(&h, "textDocument/hover", "app/main.loke", position_of(t, uses, "surface"))), "surface :: proc(s: Square) -> int\n\nThe area.")

	typing := "package main;\nimport \"shapes\";\nmain :: proc() {\n\t_ = shapes.\n}\n"
	change(&h, "app/main.loke", typing, 3)
	request(&h, "11", "textDocument/completion", fmt.tprintf(`{{"textDocument":{{"uri":%s}},"position":{{"line":3,"character":12}}}}`, quoted(uri_of(&h, "app/main.loke"))))
	notify(&h, "$/cancelRequest", `{"id":11}`)
	replies := take(&h)
	testing.expect(t, len(replies) == 1 && error_code(replies[0]) == REQUEST_CANCELLED)
	reply := ask(&h, "textDocument/completion", "app/main.loke", Position{3, 12})
	testing.expect_value(t, completion_labels(reply), "Square surface")
	root := only_root(&h)
	if root == nil { return }
	shapes := root.session.compiler.package_by_dir[lokec.dir_key(lokec.canonical_dir(lokec.join_path({h.root, "app", "shapes"}, context.temp_allocator)))]
	testing.expect(t, slice.contains(lokec.session_check_stats(&root.session).reused_packages, shapes), "a syntax error in `main` rechecked the library")
}

// Files created, changed, and deleted on disk reach every root through the
// client's notifications, and the results agree with a fresh check.
@(test)
workspace_changes_match_a_fresh_check :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "incremental-workspace") { finish(&h); return }
	defer finish(&h)
	main_text := "package main;\nimport \"shapes\";\nmain :: proc() {\n\t_ = shapes.area(2) + shapes.extra();\n}\n"
	write_file(&h, "app/main.loke", main_text)
	write_file(&h, "app/shapes/shapes.loke", "@(public) package shapes;\narea :: proc(side: int) -> int { return side * side; }\n")
	open(&h, "app/main.loke", main_text)
	settle(&h)
	shown := make(map[string]string, context.temp_allocator)
	record_publications(&shown, take(&h))
	unsaved := []Unsaved{{"app/main.loke", main_text}}
	expect_shown(t, shown, fresh_codes(&h, "app", unsaved))
	testing.expect_value(t, len(shown), 1)

	watched :: proc(h: ^Harness, relative: string, type: int) {
		notify(h, "workspace/didChangeWatchedFiles", fmt.tprintf(`{{"changes":[{{"uri":%s,"type":%d}}]}}`, quoted(uri_of(h, relative)), type))
	}
	steps := [?]struct { relative, text: string, type: int }{
		{"app/shapes/extra.loke", "@(public) package shapes;\nextra :: proc() -> int { return 1; }\n", 1},
		{"app/shapes/extra.loke", "@(public) package shapes;\nextra :: proc() -> bool { return true; }\n", 2},
		{"app/shapes/shapes.loke", "@(public) package shapes;\narea :: proc(side: int) -> bool { return side > 0; }\n", 2},
		{"app/shapes/extra.loke", "", 3},
		{"app/loke.project", "# a manifest now governs the program\n", 1},
	}
	for step in steps {
		path := lokec.join_path({h.root, step.relative}, context.temp_allocator)
		if step.type == 3 { testing.expect(t, os.remove(path) == nil) } else { write_file(&h, step.relative, step.text) }
		watched(&h, step.relative, step.type)
		settle(&h)
		record_publications(&shown, take(&h))
		expect_shown(t, shown, fresh_codes(&h, "app", unsaved))
	}
}

@(private = "file")
reply_to :: proc(h: ^Harness, messages: []json.Value, id: i64) -> json.Value {
	for message in messages {
		if got, _ := member_int(message, "id"); got == id && member(message, "method") == nil { return message }
	}
	testing.expectf(h.t, false, "request %d was not answered", id)
	return nil
}

// The text `lokec -fmt` writes for a file holding `text`.
@(private = "file")
lokec_fmt :: proc(h: ^Harness, text: string) -> string {
	path := write_file(h, "fmt/copy.loke", text)
	s: lokec.Compilation_Session
	defer lokec.destroy_session(&s)
	testing.expect(h.t, lokec.init_session(&s))
	testing.expect_value(h.t, lokec.format_files(&s.compiler, path, false), 0)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

// `text` with a `TextEdit[]` applied, its positions in UTF-16 units.
@(private = "file")
apply_edits :: proc(text: string, edits: json.Array) -> string {
	out := text
	#reverse for edit in edits {
		range := member(edit, "range")
		start := position_to_offset(out, json_position(member(range, "start")), false)
		end := position_to_offset(out, json_position(member(range, "end")), false)
		new_text, _ := member_string(edit, "newText")
		out = strings.concatenate({out[:start], new_text, out[end:]}, context.temp_allocator)
	}
	return out
}

// Formatting answers at once with edits that turn the unsaved text into what
// `lokec -fmt` writes, and nothing once applied; it refuses text `-fmt` refuses.
@(test)
formatting_matches_lokec_fmt :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "formatting") { finish(&h); return }
	defer finish(&h)
	write_file(&h, "main.loke", "package main;\nmain :: proc() {}\n")
	format :: proc(h: ^Harness, id: i64) -> json.Value {
		request(h, fmt.tprintf("%d", id), "textDocument/formatting", fmt.tprintf(
			`{{"textDocument":{{"uri":%s}},"options":{{"tabSize":4,"insertSpaces":true}}}}`, quoted(uri_of(h, "main.loke")),
		))
		// Nothing is checked first.
		return reply_to(h, take(h), id)
	}
	texts := []string{
		"package main;\n// \u00e9\nmain :: proc() {\nx := 1;\n      _ = x;\n\n\n\n}\n",
		"package main;\r\nmain :: proc() {\r\n\tx:=1;\r\n\t_ = x;\r\n}\r\n",
		// The last line is changed and has no line break.
		"package main;\nmain :: proc() {\n_ = \"é\";     }",
		"package main;\nmain :: proc() {}\n",
	}
	version := 1
	for text, index in texts {
		if index == 0 { open(&h, "main.loke", text) } else { change(&h, "main.loke", text, version) }
		version += 1
		reply := format(&h, 80)
		edits := member_array(reply, "result")
		expected := lokec_fmt(&h, text)
		testing.expectf(t, apply_edits(text, edits) == expected, "case %d: %q formats to %q", index, apply_edits(text, edits), expected)
		testing.expect_value(t, len(edits), 0 if text == expected else 1)
		for edit in edits {
			start, end := json_position(member(member(edit, "range"), "start")), json_position(member(member(edit, "range"), "end"))
			at_end := position_to_offset(text, end, false) == len(text)
			testing.expectf(t, start.character == 0 && (end.character == 0 || at_end), "case %d: the edit does not cover whole lines", index)
		}
		change(&h, "main.loke", expected, version)
		version += 1
		again := format(&h, 81)
		_, is_array := member(again, "result").(json.Array)
		testing.expectf(t, is_array && len(member_array(again, "result")) == 0, "case %d: formatting is not repeatable", index)
	}

	change(&h, "main.loke", "package main;\nmain :: proc() {\n\tx := ;\n}\n", version)
	refused := format(&h, 82)
	message, _ := member_string(member(refused, "error"), "message")
	testing.expect_value(t, error_code(refused), REQUEST_FAILED)
	testing.expectf(t, strings.contains(message, "line 3"), "the refusal does not say where: %q", message)
	change(&h, "main.loke", "\xef\xbb\xbfpackage main;\n", version + 1)
	testing.expect_value(t, error_code(format(&h, 83)), REQUEST_FAILED)
	request(&h, "84", "textDocument/formatting", fmt.tprintf(`{{"textDocument":{{"uri":%s}}}}`, quoted(uri_of(&h, "other.loke"))))
	testing.expect(t, is_null_result(reply_to(&h, take(&h), 84)))
}

// What `lokec -doc` prints for `root` with `unsaved` as overlays.
@(private = "file")
fresh_documentation :: proc(h: ^Harness, root: string, unsaved: []Unsaved) -> string {
	s: lokec.Compilation_Session
	defer lokec.destroy_session(&s)
	testing.expect(h.t, lokec.init_session(&s))
	for file in unsaved {
		testing.expect(h.t, lokec.set_session_overlay(&s, lokec.join_path({h.root, file.relative}, context.temp_allocator), file.text))
	}
	if !testing.expect(h.t, lokec.check_session(&s, lokec.join_path({h.root, root}, context.temp_allocator), documentation = true)) { return "" }
	context.allocator = context.temp_allocator
	return lokec.document_project(&s.compiler, s.compiler.root_package)
}

@(private = "file")
request_documentation :: proc(h: ^Harness, id: i64, relative: string) {
	request(h, fmt.tprintf("%d", id), "workspace/executeCommand", fmt.tprintf(
		`{{"command":"loke.documentation","arguments":[%s]}}`, quoted(uri_of(h, relative)),
	))
}

@(private = "file")
documentation_page :: proc(h: ^Harness, relative: string) -> string {
	request_documentation(h, 90, relative)
	settle(h)
	reply := reply_to(h, take(h), 90)
	page, _ := member_string(reply, "result")
	return page
}

// The documentation command answers with the page `lokec -doc` prints for the
// document's root, from unsaved text, for a program and for a library across
// incremental checks; it waits for the check and refuses a program with errors.
@(test)
documentation_matches_lokec_doc :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "documentation") { finish(&h); return }
	defer finish(&h)
	main_text := "package main;\nimport \"shapes\";\nmain :: proc() {\n\t_ = shapes.area(shapes.Square{side = 2});\n}\n"
	shapes_text := "// Shapes to measure.\n@(public) package shapes;\n\n// A square.\nSquare :: struct { side: int }\n\n// Its area.\narea :: proc(s: Square) -> int { return s.side * s.side; }\n"
	write_file(&h, "app/main.loke", main_text)
	write_file(&h, "app/shapes/shapes.loke", shapes_text)
	open(&h, "app/main.loke", main_text)
	request_documentation(&h, 91, "app/main.loke")
	testing.expect_value(t, len(take(&h)), 0)
	settle(&h)
	page, _ := member_string(reply_to(&h, take(&h), 91), "result")
	testing.expect_value(t, page, fresh_documentation(&h, "app", {}))
	testing.expect(t, strings.contains(page, "# package shapes") && strings.contains(page, "Its area."))

	// An unsaved comment in an imported package, documented through the program.
	commented := strings.concatenate({shapes_text, "\n// A unit square.\nUNIT :: Square{side = 1};\n"}, context.temp_allocator)
	open(&h, "app/shapes/shapes.loke", commented)
	page = documentation_page(&h, "app/shapes/shapes.loke")
	testing.expect_value(t, page, fresh_documentation(&h, "app", {{"app/shapes/shapes.loke", commented}}))
	testing.expect(t, strings.contains(page, "A unit square."))

	// With the program closed, the library is its own root, checked again
	// after each edit.
	close(&h, "app/main.loke")
	edits := []string{
		strings.concatenate({commented, "\n// Twice the area.\ndouble :: proc(s: Square) -> int { return 2 * area(s); }\n"}, context.temp_allocator),
		strings.concatenate({commented, "\n// Thrice the area.\ntriple :: proc(s: Square) -> int { return 3 * area(s); }\n"}, context.temp_allocator),
		shapes_text,
	}
	for text, index in edits {
		change(&h, "app/shapes/shapes.loke", text, index + 2)
		page = documentation_page(&h, "app/shapes/shapes.loke")
		testing.expectf(t, page == fresh_documentation(&h, "app/shapes", {{"app/shapes/shapes.loke", text}}), "edit %d:\n%s", index, page)
	}
	root := only_root(&h)
	testing.expect(t, root != nil && root.library)

	change(&h, "app/shapes/shapes.loke", "@(public) package shapes;\nbroken :: proc() -> int { return \"text\"; }\n", 10)
	request_documentation(&h, 92, "app/shapes/shapes.loke")
	settle(&h)
	testing.expect_value(t, error_code(reply_to(&h, take(&h), 92)), REQUEST_FAILED)
	request_documentation(&h, 93, "app/shapes/shapes.loke")
	change(&h, "app/shapes/shapes.loke", shapes_text, 11)
	settle(&h)
	testing.expect_value(t, error_code(reply_to(&h, take(&h), 93)), CONTENT_MODIFIED)
	request_documentation(&h, 94, "app/main.loke")
	testing.expect(t, is_null_result(reply_to(&h, take(&h), 94)))
	// `lokec` rejects a `main` package without `main`, but `lokec -doc` still
	// documents it.
	tool := "package main;\nimport \"shapes\";\n\n// One square's area.\n@(public) unit_area :: proc() -> int { return shapes.area(shapes.Square{side = 1}); }\n"
	write_file(&h, "tool/shapes/shapes.loke", shapes_text)
	open(&h, "tool/main.loke", tool)
	page = documentation_page(&h, "tool/main.loke")
	testing.expect_value(t, page, fresh_documentation(&h, "tool", {{"tool/main.loke", tool}}))
	testing.expect(t, strings.contains(page, "One square's area."))
	request(&h, "95", "workspace/executeCommand", `{"command":"loke.unknown","arguments":[]}`)
	testing.expect_value(t, error_code(reply_to(&h, take(&h), 95)), INVALID_PARAMS)
	request(&h, "96", "workspace/executeCommand", `{"command":"loke.documentation","arguments":[]}`)
	testing.expect_value(t, error_code(reply_to(&h, take(&h), 96)), INVALID_PARAMS)
}

// The documentation command fails where `lokec -doc` fails before the document
// is loaded at all: a malformed manifest, and a byte order mark.
@(test)
documentation_fails_where_lokec_doc_fails :: proc(t: ^testing.T) {
	h: Harness
	if !start(&h, t, "documentation-failures") { finish(&h); return }
	defer finish(&h)
	library := "@(public) package library;\nanswer :: 1;\n"
	Case :: struct { relative, text, code: string }
	cases := []Case{
		{"manifest/lib.loke", library, "L0398"},
		{"bom/lib.loke", strings.concatenate({"\xef\xbb\xbf", library}, context.temp_allocator), "L0002"},
	}
	write_file(&h, "manifest/loke.project", "not_a_manifest_directive\n")
	for c, index in cases {
		write_file(&h, c.relative, c.text)
		open(&h, c.relative, c.text)
		request_documentation(&h, i64(100 + index), c.relative)
		settle(&h)
		reply := reply_to(&h, take(&h), i64(100 + index))
		message, _ := member_string(member(reply, "error"), "message")
		testing.expectf(t, error_code(reply) == REQUEST_FAILED && strings.contains(message, c.code), "%s: %v", c.relative, reply)

		s: lokec.Compilation_Session
		testing.expect(t, lokec.init_session(&s))
		dir := lokec.path_dir(lokec.join_path({h.root, c.relative}, context.temp_allocator), context.temp_allocator)
		testing.expectf(t, !lokec.check_session(&s, dir, documentation = true), "%s: `lokec -doc` succeeds", c.relative)
		lokec.destroy_session(&s)
		close(&h, c.relative)
		settle(&h)
		take(&h)
	}
}
