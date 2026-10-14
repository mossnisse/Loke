// Formatting and generated documentation, from the same procedures as
// `lokec -fmt` and `lokec -doc`, applied to the editor's unsaved text.
package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import lokec "../src"

INVALID_PARAMS :: -32602

// The `workspace/executeCommand` command whose result is the Markdown page
// `lokec -doc` prints for a document's root.
DOCUMENTATION_COMMAND :: "loke.documentation"

// `textDocument/formatting`: the document's text as `lokec -fmt` would write
// it. Formatting reads only that text, so it is answered at once. The
// client's tab and spacing options are ignored: the layout is canonical
// (comments.md "Formatting").
format_document :: proc(s: ^Server, id: json.Value, params: json.Value) {
	doc := find_document(s, member(params, "textDocument"))
	if doc == nil {
		send_result(s, id, "null")
		return
	}
	scratch: lokec.Compiler
	defer lokec.destroy_compilation(&scratch)
	formatted, ok := lokec.format_text(&scratch, doc.path, doc.text)
	if !ok {
		send_error(s, id, REQUEST_FAILED, fmt.tprintf("the document cannot be formatted: %s", first_error(&scratch)))
		return
	}
	defer delete(formatted)
	send_result(s, id, formatting_edits(s, doc.text, formatted))
}

// What `-fmt` would report first, with its line.
@(private = "file")
first_error :: proc(c: ^lokec.Compiler) -> string {
	for d in c.diagnostics {
		if d.severity != .Error { continue }
		if d.span.file == lokec.NO_FILE || int(d.span.file) >= len(c.sources) { return d.message }
		line, _ := lokec.line_col(&c.sources[d.span.file], d.span.lo)
		return fmt.tprintf("line %d: %s", line, d.message)
	}
	return "it does not parse"
}

// `TextEdit[]`: none for text already formatted, otherwise one edit replacing
// the lines from the first that changes to the last, so the editor keeps its
// cursor and folds elsewhere. The formatter changes whitespace only and keeps
// every line break, so few lines usually differ.
@(private = "file")
formatting_edits :: proc(s: ^Server, text, formatted: string) -> string {
	if text == formatted { return "[]" }
	prefix := 0
	for prefix < len(text) && prefix < len(formatted) && text[prefix] == formatted[prefix] { prefix += 1 }
	prefix = strings.last_index_byte(text[:prefix], '\n') + 1
	suffix := 0
	for suffix < len(text) - prefix && suffix < len(formatted) - prefix &&
	    text[len(text) - 1 - suffix] == formatted[len(formatted) - 1 - suffix] {
		suffix += 1
	}
	// Both ends of the range start a line, so neither splits a `\r\n`.
	if end := len(text) - suffix; end > prefix && text[end - 1] != '\n' {
		next := strings.index_byte(text[end:], '\n')
		suffix = next < 0 ? 0 : suffix - next - 1
	}
	starts := make([dynamic]u32, context.temp_allocator)
	append(&starts, 0)
	for index in 0 ..< len(text) { if text[index] == '\n' { append(&starts, u32(index + 1)) } }
	range := Range{
		start = offset_to_position(text, starts[:], u32(prefix), s.utf8_positions),
		end = offset_to_position(text, starts[:], u32(len(text) - suffix), s.utf8_positions),
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `[{"range":`)
	write_range(&b, range)
	strings.write_string(&b, `,"newText":`)
	write_json_string(&b, formatted[prefix:len(formatted) - suffix])
	strings.write_string(&b, "}]")
	return strings.to_string(b)
}

// `workspace/executeCommand`. The documentation command takes the URI of an
// open document and waits for its root to be checked, like a position request.
execute_command :: proc(s: ^Server, id: json.Value, params: json.Value) {
	command, _ := member_string(params, "command")
	arguments := member_array(params, "arguments")
	if command != DOCUMENTATION_COMMAND {
		send_error(s, id, INVALID_PARAMS, fmt.tprintf("unknown command `%s`", command))
		return
	}
	uri: json.String
	is_uri := false
	if len(arguments) == 1 { uri, is_uri = arguments[0].(json.String) }
	if !is_uri {
		send_error(s, id, INVALID_PARAMS, "`loke.documentation` takes one argument, a document URI")
		return
	}
	queue_document_request(s, id, .Documentation, document_at(s, string(uri)), nil)
}

// The page `lokec -doc` prints for the root, or why it would fail. A library
// root was checked exactly as `lokec -doc` checks it, so its snapshot is used;
// a program is checked again in documentation mode, in a session of its own,
// so the root's reusable packages stay as they are.
documentation :: proc(s: ^Server, root: ^Root) -> (page: string, failure: string) {
	FAILED :: "the program has errors, so `lokec -doc` would print no documentation"
	if root.library {
		if root.session.compiler.error_count > 0 { return "", FAILED }
		return temporary_page(&root.session.compiler), ""
	}
	session: lokec.Compilation_Session
	defer lokec.destroy_session(&session)
	if !lokec.init_session(&session, s.config) { return "", FAILED }
	for _, doc in s.documents { lokec.set_session_overlay(&session, doc.path, doc.text) }
	if !lokec.check_session(&session, root.path, documentation = true) { return "", FAILED }
	return temporary_page(&session.compiler), ""
}

// `document_project` allocates as it goes, as a command that prints once and
// exits may, so everything it allocates lives only as long as the request.
@(private = "file")
temporary_page :: proc(c: ^lokec.Compiler) -> string {
	context.allocator = context.temp_allocator
	return lokec.document_project(c, c.root_package)
}
