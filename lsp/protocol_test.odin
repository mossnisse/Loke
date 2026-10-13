package lsp

import "core:strings"
import "core:testing"

@(private = "file")
Chunks :: struct { parts: []string }

// Hands out one part per read, so messages arrive split at awkward places.
@(private = "file")
chunked_reader :: proc(chunks: ^Chunks) -> Message_Reader {
	return Message_Reader{read = proc(data: rawptr, buffer: []byte) -> int {
		chunks := (^Chunks)(data)
		if len(chunks.parts) == 0 { return 0 }
		n := copy(buffer, chunks.parts[0])
		chunks.parts[0] = chunks.parts[0][n:]
		if chunks.parts[0] == "" { chunks.parts = chunks.parts[1:] }
		return n
	}, data = chunks}
}

@(test)
framing_survives_split_reads :: proc(t: ^testing.T) {
	parts := []string{"Content-Len", "gth: 2\r\n", "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{", "}content-length:3\r\n\r\n[1]"}
	chunks := Chunks{parts}
	reader := chunked_reader(&chunks)
	defer destroy_reader(&reader)
	first, ok := read_message(&reader)
	defer delete(first)
	testing.expect(t, ok && first == "{}")
	second, ok2 := read_message(&reader)
	defer delete(second)
	testing.expect(t, ok2 && second == "[1]")
	_, more := read_message(&reader)
	testing.expect(t, !more)
}

@(test)
framing_rejects_truncated_and_headerless_input :: proc(t: ^testing.T) {
	for input in ([]string{"Content-Length: 10\r\n\r\n{}", "Content-Type: x\r\n\r\n{}", "Content-Length: 2\r\n"}) {
		chunks := Chunks{[]string{input}}
		reader := chunked_reader(&chunks)
		_, ok := read_message(&reader)
		testing.expectf(t, !ok, "accepted %q", input)
		destroy_reader(&reader)
	}
}

@(test)
json_strings_are_escaped_and_valid :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_json_string(&b, "a\"b\\c\n\t\x01é\xff")
	testing.expect_value(t, strings.to_string(b), `"a\"b\\c\n\t\u0001é\ufffd"`)
}

@(test)
file_uris_and_paths_round_trip :: proc(t: ^testing.T) {
	Case :: struct { uri, path: string }
	for c in ([]Case{
		{"file:///c%3A/code/loke/main.loke", "c:/code/loke/main.loke"},
		{"file:///C:/My%20Files/%23x.loke", "C:/My Files/#x.loke"},
		{"file://server/share/a.loke", "//server/share/a.loke"},
		{"file://localhost/C:/a.loke", "C:/a.loke"},
	}) {
		path, ok := uri_to_path(c.uri)
		defer delete(path)
		testing.expectf(t, ok && path == c.path, "%s gave %q", c.uri, path)
	}
	for bad in ([]string{"untitled:Untitled-1", "file:///c%3", "file:///c%zz/a.loke"}) {
		_, ok := uri_to_path(bad)
		testing.expectf(t, !ok, "accepted %s", bad)
	}
	uri := path_to_uri(`C:\My Files\#x.loke`)
	defer delete(uri)
	testing.expect_value(t, uri, "file:///C:/My%20Files/%23x.loke")
	unc := path_to_uri("//server/share/a.loke")
	defer delete(unc)
	testing.expect_value(t, unc, "file://server/share/a.loke")
}

@(test)
positions_count_bytes_or_utf16_units :: proc(t: ^testing.T) {
	text := "ab\n\U0001F600é = 1\nlast"
	line_starts := []u32{0, 3, u32(strings.index(text, "last"))}
	offset := u32(strings.index(text, "="))
	testing.expect_value(t, offset_to_position(text, line_starts, offset, true), Position{1, 7})
	testing.expect_value(t, offset_to_position(text, line_starts, offset, false), Position{1, 4})
	testing.expect_value(t, offset_to_position(text, line_starts, 0, false), Position{0, 0})
	testing.expect_value(t, offset_to_position(text, line_starts, u32(len(text) + 5), false), Position{2, 4})

	testing.expect_value(t, position_to_offset(text, Position{1, 4}, false), int(offset))
	testing.expect_value(t, position_to_offset(text, Position{1, 7}, true), int(offset))
	// Inside a surrogate pair, and past the end of a line, clamp.
	testing.expect_value(t, position_to_offset(text, Position{1, 1}, false), 3)
	testing.expect_value(t, position_to_offset(text, Position{0, 99}, false), 2)
	testing.expect_value(t, position_to_offset(text, Position{9, 0}, false), len(text))
}

@(test)
entry_declarations_are_found_by_token :: proc(t: ^testing.T) {
	Case :: struct { text: string, declares: bool }
	for c in ([]Case{
		{"package main;\nmain :: proc() {}\n", true},
		{"package main;\r\n  main\t: : proc() -> i32 { return 0; }", true},
		{"package main;\n@(private) main :: proc() {}\n", true},
		{"package main;\nmain_loop :: proc() {}\n", false},
		{"package main;\n// main :: proc() {}\n", false},
		{"package main;\n/*\nmain :: proc() {}\n*/\nhelper :: proc() {}\n", false},
		{"package main;\nusage :: `\nmain :: proc() {}\n`;\n", false},
		{"package main;\ntext :: \"main :: proc() {}\";\n", false},
		{"package main;\nPoint :: struct { main: int }\nf :: proc() { main := 1; _ = main; }\n", false},
		{"package main;\nf(main = 1);\nx := \"unterminated\n", false},
	}) {
		testing.expectf(t, declares_entry(c.text) == c.declares, "declares_entry(%q) should be %v", c.text, c.declares)
	}
}
