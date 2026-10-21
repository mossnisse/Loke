// The built language server, spoken to over real pipes as an editor would.
// The protocol's cases are covered in-process by lsp/server_test.odin; these
// check the process around them: framing on stdio, the checking thread, and
// exit status.
package tests

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"

LOKE_LSP_DEFAULT :: "loke-lsp.exe"

@(private = "file")
lsp_path :: proc() -> string {
	if configured := os.get_env("LOKE_LSP", context.temp_allocator); configured != "" {
		return launch_path(configured)
	}
	return launch_path(LOKE_LSP_DEFAULT)
}

// As for `lokec.exe`: the server compiles in all of `src`, so a compiler edit
// makes it stale as well as its own.
@(test)
lsp_binary_is_current :: proc(t: ^testing.T) {
	if os.get_env("LOKE_LSP", context.temp_allocator) != "" {
		return
	}
	server := lsp_path()
	info, err := os.stat(server, context.temp_allocator)
	if !testing.expectf(t, err == nil, "cannot stat %s; build it with `odin build lsp -out:loke-lsp.exe` or set LOKE_LSP=<path>", server) {
		return
	}
	built := time.time_to_unix_nano(info.modification_time)
	sources := make([dynamic]string, context.temp_allocator)
	collect_odin_files("src", &sources)
	collect_odin_files("lsp", &sources)
	for source in sources {
		source_info, source_err := os.stat(source, context.temp_allocator)
		if source_err == nil && time.time_to_unix_nano(source_info.modification_time) > built {
			testing.expectf(t, false, "%s is older than %s; rebuild it or set LOKE_LSP=<path>", server, source)
			return
		}
	}
}

@(private = "file")
Lsp_Process :: struct {
	t:       ^testing.T,
	process: os.Process,
	input:   ^os.File, // the server's stdin
	output:  ^os.File, // the server's stdout
	pending: [dynamic]byte,
}

@(private = "file")
lsp_start :: proc(p: ^Lsp_Process, t: ^testing.T) -> bool {
	p.t = t
	stdin_r, stdin_w, in_err := os.pipe()
	if !testing.expect(t, in_err == nil) { return false }
	stdout_r, stdout_w, out_err := os.pipe()
	if !testing.expect(t, out_err == nil) {
		os.close(stdin_r)
		os.close(stdin_w)
		return false
	}
	// Pipes are created inheritable. A server holding a copy of its own stdin's
	// write end would never see the input end.
	win32.SetHandleInformation(win32.HANDLE(os.fd(stdin_w)), win32.HANDLE_FLAG_INHERIT, 0)
	win32.SetHandleInformation(win32.HANDLE(os.fd(stdout_r)), win32.HANDLE_FLAG_INHERIT, 0)
	process, err := os.process_start(os.Process_Desc{command = {lsp_path()}, stdin = stdin_r, stdout = stdout_w})
	// The child has its own copies of these ends.
	os.close(stdin_r)
	os.close(stdout_w)
	if !testing.expectf(t, err == nil, "cannot start %s: %v", lsp_path(), err) {
		os.close(stdin_w)
		os.close(stdout_r)
		return false
	}
	p.process, p.input, p.output = process, stdin_w, stdout_r
	return true
}

// Waits for the exit status, killing a server that does not stop. Input stays
// open while it waits unless `end_input`, so a server that ignores `exit`
// cannot pass by stopping at the end of its input instead.
@(private = "file")
lsp_finish :: proc(p: ^Lsp_Process, end_input := false) -> (exit_code: int, exited: bool) {
	if end_input && p.input != nil {
		os.close(p.input)
		p.input = nil
	}
	state, err := os.process_wait(p.process, 30 * time.Second)
	if err != nil || !state.exited {
		_ = os.process_kill(p.process)
		_, _ = os.process_wait(p.process)
	}
	if p.input != nil { os.close(p.input) }
	os.close(p.output)
	delete(p.pending)
	return state.exit_code, err == nil && state.exited
}

@(private = "file")
lsp_send :: proc(p: ^Lsp_Process, body: string) {
	framed := fmt.tprintf("Content-Length: %d\r\n\r\n%s", len(body), body)
	_, err := os.write(p.input, transmute([]byte)framed)
	testing.expect(p.t, err == nil)
}

// The next message, or false once `timeout` passes, however much incomplete
// output arrives meanwhile, or the output ends.
@(private = "file")
lsp_receive :: proc(p: ^Lsp_Process, timeout: time.Duration = 60 * time.Second) -> (json.Value, bool) {
	start := time.tick_now()
	for {
		text := string(p.pending[:])
		if header_end := strings.index(text, "\r\n\r\n"); header_end >= 0 {
			colon := strings.index_byte(text[:header_end], ':')
			length, _ := strconv.parse_int(strings.trim_space(text[colon + 1:header_end]))
			if len(text) - header_end - 4 >= length {
				body := text[header_end + 4:header_end + 4 + length]
				value, err := json.parse_string(body, parse_integers = true, allocator = context.temp_allocator)
				remove_range(&p.pending, 0, header_end + 4 + length)
				return value, testing.expect(p.t, err == nil)
			}
		}
		if time.tick_since(start) > timeout { return nil, false }
		has_data, err := os.pipe_has_data(p.output)
		if err != nil { return nil, false }
		if !has_data {
			time.sleep(time.Millisecond)
			continue
		}
		chunk: [4096]byte
		n, read_err := os.read(p.output, chunk[:])
		if read_err != nil { return nil, false }
		append(&p.pending, ..chunk[:n])
	}
}

@(private = "file")
json_quoted :: proc(text: string) -> string {
	data, _ := json.marshal(text, allocator = context.temp_allocator)
	return string(data)
}

@(test)
lsp_publishes_diagnostics_and_exits_cleanly :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/lsp-process-%d", TMP, os.get_pid())
	remove_tree(root)
	if !testing.expect(t, os.make_directory_all(root) == nil) { return }
	defer remove_tree(root)
	absolute := os.get_absolute_path(root, context.temp_allocator) or_else root
	path, _ := strings.replace_all(join_path({absolute, "main.loke"}, context.temp_allocator), "\\", "/", context.temp_allocator)
	uri := fmt.tprintf("file:///%s", path)

	p: Lsp_Process
	if !lsp_start(&p, t) { return }
	lsp_send(&p, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}`)
	reply, ok := lsp_receive(&p)
	capabilities := json_member(json_member(reply, "result"), "capabilities")
	hovers, _ := json_member(capabilities, "hoverProvider").(json.Boolean)
	references, _ := json_member(capabilities, "referencesProvider").(json.Boolean)
	renames, _ := json_member(capabilities, "renameProvider").(json.Boolean)
	triggers, _ := json_member(json_member(capabilities, "completionProvider"), "triggerCharacters").(json.Array)
	testing.expect(t, ok && bool(hovers) && bool(references) && bool(renames) && json_member(capabilities, "signatureHelpProvider") != nil)
	testing.expect(t, len(triggers) == 1 && triggers[0].(json.String) == ".")
	lsp_send(&p, `{"jsonrpc":"2.0","method":"initialized","params":{}}`)
	text := "package main;\nmain :: proc() { x: int = \"text\"; }\n"
	lsp_send(&p, fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":%s,"languageId":"loke","version":4,"text":%s}}}}}}`,
		json_quoted(uri), json_quoted(text),
	))
	published, received := lsp_receive(&p)
	if testing.expect(t, received) {
		params := json_member(published, "params")
		method, _ := json_member(published, "method").(json.String)
		published_uri, _ := json_member(params, "uri").(json.String)
		version, _ := json_member(params, "version").(json.Integer)
		diagnostics, _ := json_member(params, "diagnostics").(json.Array)
		testing.expect_value(t, method, "textDocument/publishDiagnostics")
		testing.expect_value(t, published_uri, uri)
		testing.expect_value(t, version, 4)
		if testing.expect_value(t, len(diagnostics), 1) {
			code, _ := json_member(diagnostics[0], "code").(json.String)
			testing.expect_value(t, code, "L0310")
		}
	}
	// The binding at `x`, from the same check.
	lsp_send(&p, fmt.tprintf(
		`{{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{{"textDocument":{{"uri":%s}},"position":{{"line":1,"character":17}}}}}}`,
		json_quoted(uri),
	))
	reply, ok = lsp_receive(&p)
	value, _ := json_member(json_member(json_member(reply, "result"), "contents"), "value").(json.String)
	testing.expect(t, ok && value == "x: int")
	// What may be written there: `main` is in scope.
	lsp_send(&p, fmt.tprintf(
		`{{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{{"textDocument":{{"uri":%s}},"position":{{"line":1,"character":17}}}}}}`,
		json_quoted(uri),
	))
	reply, ok = lsp_receive(&p)
	items, _ := json_member(json_member(reply, "result"), "items").(json.Array)
	offered := false
	for item in items {
		label, _ := json_member(item, "label").(json.String)
		offered ||= label == "main"
	}
	testing.expect(t, ok && offered)
	lsp_send(&p, `{"jsonrpc":"2.0","id":4,"method":"shutdown"}`)
	reply, ok = lsp_receive(&p)
	id, _ := json_member(reply, "id").(json.Integer)
	testing.expect(t, ok && id == 4)
	lsp_send(&p, `{"jsonrpc":"2.0","method":"exit"}`)
	code, exited := lsp_finish(&p)
	testing.expect(t, exited && code == 0)
}

// Edits sent faster than the server checks: whatever it publishes on the way,
// versions never go back, the last publication is the last text's, and a
// request sent after the edits is answered from that text.
@(test)
lsp_rapid_edits_end_with_the_final_text :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/lsp-rapid-%d", TMP, os.get_pid())
	remove_tree(root)
	if !testing.expect(t, os.make_directory_all(root) == nil) { return }
	defer remove_tree(root)
	absolute := os.get_absolute_path(root, context.temp_allocator) or_else root
	path, _ := strings.replace_all(join_path({absolute, "main.loke"}, context.temp_allocator), "\\", "/", context.temp_allocator)
	uri := fmt.tprintf("file:///%s", path)

	p: Lsp_Process
	if !lsp_start(&p, t) { return }
	lsp_send(&p, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}`)
	_, ok := lsp_receive(&p)
	testing.expect(t, ok)
	lsp_send(&p, `{"jsonrpc":"2.0","method":"initialized","params":{}}`)
	// Odd versions declare `x` as an `int` and assign it text; even ones are fine.
	text :: proc(version: int) -> string {
		if version % 2 == 1 { return fmt.tprintf("package main;\nmain :: proc() {{\n\tx: int = \"%d\";\n\t_ = x;\n}}\n", version) }
		return fmt.tprintf("package main;\nmain :: proc() {{\n\tx: bool = %d > 0;\n\t_ = x;\n}}\n", version)
	}
	LAST :: 21
	lsp_send(&p, fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":%s,"languageId":"loke","version":1,"text":%s}}}}}}`,
		json_quoted(uri), json_quoted(text(1)),
	))
	for version in 2 ..= LAST {
		lsp_send(&p, fmt.tprintf(
			`{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":%s,"version":%d}},"contentChanges":[{{"text":%s}}]}}}}`,
			json_quoted(uri), version, json_quoted(text(version)),
		))
	}
	lsp_send(&p, fmt.tprintf(
		`{{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{{"textDocument":{{"uri":%s}},"position":{{"line":2,"character":1}}}}}}`,
		json_quoted(uri),
	))
	newest: json.Integer
	last_codes := ""
	hover := ""
	// One deadline for both, however many older versions are published first.
	start := time.tick_now()
	for newest != LAST || hover == "" {
		remaining := 60 * time.Second - time.tick_since(start)
		message, received := lsp_receive(&p, max(remaining, 0))
		if !testing.expect(t, received, "the server did not publish the last version and answer the hover in time") { break }
		if id, has_id := json_member(message, "id").(json.Integer); has_id && id == 2 {
			hover, _ = json_member(json_member(json_member(message, "result"), "contents"), "value").(json.String)
			continue
		}
		params := json_member(message, "params")
		version, _ := json_member(params, "version").(json.Integer)
		testing.expectf(t, version >= newest, "version %d was published after %d", version, newest)
		newest = version
		diagnostics, _ := json_member(params, "diagnostics").(json.Array)
		last_codes = fmt.tprintf("%d", len(diagnostics))
		if len(diagnostics) > 0 {
			code, _ := json_member(diagnostics[0], "code").(json.String)
			last_codes = string(code)
		}
	}
	testing.expect_value(t, last_codes, "L0310")
	testing.expect_value(t, hover, "x: int")
	lsp_send(&p, `{"jsonrpc":"2.0","id":3,"method":"shutdown"}`)
	_, ok = lsp_receive(&p)
	lsp_send(&p, `{"jsonrpc":"2.0","method":"exit"}`)
	code, exited := lsp_finish(&p)
	testing.expect(t, ok && exited && code == 0)
}

@(test)
lsp_input_ending_without_shutdown_is_an_error_exit :: proc(t: ^testing.T) {
	p: Lsp_Process
	if !lsp_start(&p, t) { return }
	lsp_send(&p, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}`)
	_, ok := lsp_receive(&p)
	testing.expect(t, ok)
	code, exited := lsp_finish(&p, end_input = true)
	testing.expect(t, exited && code == 1)
}

@(private = "file")
json_member :: proc(value: json.Value, name: string) -> json.Value {
	if object, is_object := value.(json.Object); is_object { return object[name] }
	return nil
}

// The reply to request `id`, skipping the notifications sent before it.
@(private = "file")
lsp_reply :: proc(p: ^Lsp_Process, id: i64, timeout: time.Duration = 60 * time.Second) -> (reply: json.Value, ok: bool) {
	// One deadline for the reply, however many other messages come first.
	start := time.tick_now()
	for {
		remaining := timeout - time.tick_since(start)
		if remaining <= 0 { return nil, false }
		message := lsp_receive(p, remaining) or_return
		if got, has_id := json_member(message, "id").(json.Integer); has_id && got == id { return message, true }
	}
}

// Formatting and the documentation command answer what `lokec -fmt` and
// `lokec -api` write for the same text.
@(test)
lsp_formats_and_documents_like_lokec :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/lsp-tools-%d", TMP, os.get_pid())
	remove_tree(root)
	if !testing.expect(t, os.make_directory_all(fmt.tprintf("%s/shapes", root)) == nil) { return }
	os.make_directory_all(fmt.tprintf("%s/copy", root))
	defer remove_tree(root)
	text := "/// Shapes to measure.\n@(public) package shapes;\n\n/// A square.\nSquare :: struct {\nside: int,\n}\n\n/// Its area.\narea :: proc(s: Square) -> int {\n        return s.side*s.side;\n}\n"
	source := fmt.tprintf("%s/shapes/shapes.loke", root)
	copy := fmt.tprintf("%s/copy/shapes.loke", root)
	_ = os.write_entire_file(source, transmute([]byte)text)
	_ = os.write_entire_file(copy, transmute([]byte)text)
	formatted, _, fmt_stderr, fmt_err := exec(os.Process_Desc{command = []string{compiler_path(), copy, "-fmt"}}, context.allocator)
	if !testing.expectf(t, fmt_err == nil && formatted.exit_code == 0, "-fmt failed:\n%s", string(fmt_stderr)) { return }
	expected_text, _ := os.read_entire_file(copy, context.temp_allocator)
	documented, _, doc_stderr, doc_err := exec(os.Process_Desc{command = []string{compiler_path(), fmt.tprintf("%s/shapes", root), "-api"}}, context.allocator)
	if !testing.expectf(t, doc_err == nil && documented.exit_code == 0, "-api failed:\n%s", string(doc_stderr)) { return }
	page, _ := os.read_entire_file(fmt.tprintf("%s/shapes/api.loki", root), context.temp_allocator)
	absolute := os.get_absolute_path(source, context.temp_allocator) or_else source
	path, _ := strings.replace_all(absolute, "\\", "/", context.temp_allocator)
	uri := fmt.tprintf("file:///%s", path)

	p: Lsp_Process
	if !lsp_start(&p, t) { return }
	lsp_send(&p, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}`)
	reply, ok := lsp_reply(&p, 1)
	capabilities := json_member(json_member(reply, "result"), "capabilities")
	formats, _ := json_member(capabilities, "documentFormattingProvider").(json.Boolean)
	testing.expect(t, ok && bool(formats) && json_member(capabilities, "executeCommandProvider") != nil)
	lsp_send(&p, `{"jsonrpc":"2.0","method":"initialized","params":{}}`)
	lsp_send(&p, fmt.tprintf(
		`{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":%s,"languageId":"loke","version":1,"text":%s}}}}}}`,
		json_quoted(uri), json_quoted(text),
	))
	lsp_send(&p, fmt.tprintf(
		`{{"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{{"textDocument":{{"uri":%s}},"options":{{"tabSize":4,"insertSpaces":true}}}}}}`,
		json_quoted(uri),
	))
	reply, ok = lsp_reply(&p, 2)
	edits, _ := json_member(reply, "result").(json.Array)
	if testing.expect(t, ok && len(edits) == 1) {
		// The text is ASCII, so a character is a byte.
		lines := strings.split_after(text, "\n", context.temp_allocator)
		offset :: proc(lines: []string, position: json.Value) -> int {
			line, _ := json_member(position, "line").(json.Integer)
			character, _ := json_member(position, "character").(json.Integer)
			at := 0
			for index in 0 ..< int(line) { at += len(lines[index]) }
			return at + int(character)
		}
		range := json_member(edits[0], "range")
		start, end := offset(lines, json_member(range, "start")), offset(lines, json_member(range, "end"))
		new_text, _ := json_member(edits[0], "newText").(json.String)
		testing.expect_value(t, strings.concatenate({text[:start], string(new_text), text[end:]}, context.temp_allocator), string(expected_text))
	}
	lsp_send(&p, fmt.tprintf(
		`{{"jsonrpc":"2.0","id":3,"method":"workspace/executeCommand","params":{{"command":"loke.documentation","arguments":[%s]}}}}`,
		json_quoted(uri),
	))
	reply, ok = lsp_reply(&p, 3)
	result, _ := json_member(reply, "result").(json.String)
	testing.expect(t, ok)
	testing.expect_value(t, string(result), string(page))
	lsp_send(&p, `{"jsonrpc":"2.0","id":4,"method":"shutdown"}`)
	_, ok = lsp_reply(&p, 4)
	lsp_send(&p, `{"jsonrpc":"2.0","method":"exit"}`)
	code, exited := lsp_finish(&p)
	testing.expect(t, ok && exited && code == 0)
}
