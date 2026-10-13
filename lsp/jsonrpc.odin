// JSON-RPC 2.0 over the Language Server Protocol's base protocol: each message
// is a `Content-Length` header block followed by that many bytes of JSON.
package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Bytes come from `read`, which returns 0 at the end of input. Stdin in the
// server, a byte buffer in the tests.
Message_Reader :: struct {
	read:   proc(data: rawptr, buffer: []byte) -> int,
	data:   rawptr,
	buffer: [dynamic]byte,
}

destroy_reader :: proc(r: ^Message_Reader) {
	delete(r.buffer)
}

// The next message body, owned by the caller. False at the end of input, and
// for a header block without a usable `Content-Length`: the framing is lost and
// nothing after it can be found again.
read_message :: proc(r: ^Message_Reader, allocator := context.allocator) -> (body: string, ok: bool) {
	header_end := -1
	for {
		header_end = strings.index(string(r.buffer[:]), "\r\n\r\n")
		if header_end >= 0 { break }
		fill(r) or_return
	}
	length := -1
	headers := string(r.buffer[:header_end])
	for line in strings.split_lines_iterator(&headers) {
		colon := strings.index_byte(line, ':')
		if colon < 0 { continue }
		if strings.equal_fold(strings.trim_space(line[:colon]), "Content-Length") {
			value, parsed := strconv.parse_int(strings.trim_space(line[colon + 1:]), 10)
			if parsed && value >= 0 { length = value }
		}
	}
	if length < 0 { return "", false }
	start := header_end + 4
	for len(r.buffer) - start < length {
		fill(r) or_return
	}
	body = strings.clone(string(r.buffer[start:start + length]), allocator)
	remove_range(&r.buffer, 0, start + length)
	return body, true
}

@(private = "file")
fill :: proc(r: ^Message_Reader) -> bool {
	chunk: [4096]byte
	n := r.read(r.data, chunk[:])
	if n <= 0 { return false }
	append(&r.buffer, ..chunk[:n])
	return true
}

// The framed message, as one write so a reader never sees half of one.
frame_message :: proc(body: string, allocator := context.allocator) -> string {
	return fmt.aprintf("Content-Length: %d\r\n\r\n%s", len(body), body, allocator = allocator)
}

// JSON text for `s`. Bytes that are not UTF-8 become U+FFFD, since a message
// must be valid JSON whatever a source file holds.
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); {
		r, width := utf8.decode_rune_in_string(s[i:])
		switch {
		case r == utf8.RUNE_ERROR && width <= 1:
			strings.write_string(b, `\ufffd`)
		case r == '"':
			strings.write_string(b, `\"`)
		case r == '\\':
			strings.write_string(b, `\\`)
		case r == '\n':
			strings.write_string(b, `\n`)
		case r == '\r':
			strings.write_string(b, `\r`)
		case r == '\t':
			strings.write_string(b, `\t`)
		case r < 0x20:
			fmt.sbprintf(b, `\u%04x`, int(r))
		case:
			strings.write_string(b, s[i:i + width])
		}
		i += max(width, 1)
	}
	strings.write_byte(b, '"')
}

// A request ID echoed back: an integer, a string, or null.
write_json_id :: proc(b: ^strings.Builder, id: json.Value) {
	#partial switch v in id {
	case json.Integer:
		fmt.sbprintf(b, "%d", v)
	case json.Float:
		fmt.sbprintf(b, "%v", v)
	case json.String:
		write_json_string(b, v)
	case:
		strings.write_string(b, "null")
	}
}

// Field access on parsed JSON that tolerates absent or mistyped members, so a
// malformed message is ignored rather than trusted.
member :: proc(value: json.Value, name: string) -> json.Value {
	if object, is_object := value.(json.Object); is_object {
		return object[name]
	}
	return nil
}

member_string :: proc(value: json.Value, name: string) -> (string, bool) {
	text, ok := member(value, name).(json.String)
	return text, ok
}

member_int :: proc(value: json.Value, name: string) -> (i64, bool) {
	#partial switch v in member(value, name) {
	case json.Integer:
		return v, true
	case json.Float:
		return i64(v), true
	}
	return 0, false
}

member_bool :: proc(value: json.Value, name: string) -> bool {
	flag, _ := member(value, name).(json.Boolean)
	return flag
}

member_array :: proc(value: json.Value, name: string) -> json.Array {
	array, _ := member(value, name).(json.Array)
	return array
}
