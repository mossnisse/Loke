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

// Waits for the exit status, killing a server that does not stop.
@(private = "file")
lsp_finish :: proc(p: ^Lsp_Process) -> (exit_code: int, exited: bool) {
	if p.input != nil { os.close(p.input) }
	state, err := os.process_wait(p.process, 30 * time.Second)
	if err != nil || !state.exited {
		_ = os.process_kill(p.process)
		_, _ = os.process_wait(p.process)
	}
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

// The next message, or false once `deadline` passes or the output ends.
@(private = "file")
lsp_receive :: proc(p: ^Lsp_Process, deadline: time.Duration = 60 * time.Second) -> (json.Value, bool) {
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
		has_data, err := os.pipe_has_data(p.output)
		if err != nil { return nil, false }
		if !has_data {
			if time.tick_since(start) > deadline { return nil, false }
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
	os.remove_all(root)
	if !testing.expect(t, os.make_directory_all(root) == nil) { return }
	defer os.remove_all(root)
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
	os.remove_all(root)
	if !testing.expect(t, os.make_directory_all(root) == nil) { return }
	defer os.remove_all(root)
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
	for newest != LAST || hover == "" {
		message, received := lsp_receive(&p)
		if !testing.expect(t, received, "the server stopped before publishing the last version") { break }
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
	code, exited := lsp_finish(&p)
	testing.expect(t, exited && code == 1)
}

@(private = "file")
json_member :: proc(value: json.Value, name: string) -> json.Value {
	if object, is_object := value.(json.Object); is_object { return object[name] }
	return nil
}
