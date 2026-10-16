// Document identity and positions. The compiler names files by path and
// locates text by byte offset; the protocol uses `file:` URIs and line/character
// positions counted in the negotiated encoding.
package lsp

import "core:strings"
import "core:unicode/utf8"

import lokec "../src"

Position :: struct { line, character: int }
Range :: struct { start, end: Position }

// A local path for a `file:` URI, `/`-separated, or false for another scheme.
// `file:///c%3A/x` and `file:///C:/x` give the same drive path; an authority
// other than `localhost` is a UNC host.
uri_to_path :: proc(uri: string, allocator := context.allocator) -> (string, bool) {
	SCHEME :: "file://"
	if len(uri) < len(SCHEME) || !strings.equal_fold(uri[:len(SCHEME)], SCHEME) { return "", false }
	rest := uri[len(SCHEME):]
	slash := strings.index_byte(rest, '/')
	if slash < 0 { return "", false }
	authority, encoded := rest[:slash], rest[slash:]
	decoded, ok := percent_decode(encoded, context.temp_allocator)
	if !ok { return "", false }
	switch {
	case authority != "" && !strings.equal_fold(authority, "localhost"):
		host, host_ok := percent_decode(authority, context.temp_allocator)
		if !host_ok { return "", false }
		return strings.concatenate({"//", host, decoded}, allocator), true
	case len(decoded) >= 3 && decoded[0] == '/' && is_letter(decoded[1]) && decoded[2] == ':':
		decoded = decoded[1:]
	}
	return strings.clone(decoded, allocator), true
}

// The `file:` URI for an absolute path, either separator. Only unreserved
// characters, `/`, and a drive's `:` are left unescaped.
path_to_uri :: proc(path: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	slashed, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	if strings.has_prefix(slashed, "//") {
		strings.write_string(&b, "file:")
	} else {
		strings.write_string(&b, "file:///")
	}
	for i in 0 ..< len(slashed) {
		ch := slashed[i]
		drive_colon := ch == ':' && i == 1 && is_letter(slashed[0])
		if is_unreserved(ch) || ch == '/' || drive_colon {
			strings.write_byte(&b, ch)
		} else {
			hex := "0123456789ABCDEF"
			strings.write_byte(&b, '%')
			strings.write_byte(&b, hex[ch >> 4])
			strings.write_byte(&b, hex[ch & 15])
		}
	}
	return strings.to_string(b)
}

// The identity the compiler gives a path: absolute, cleaned, `/`-separated,
// compared case-insensitively.
path_key :: proc(path: string, allocator := context.allocator) -> string {
	return lokec.dir_key(lokec.canonical_dir(path), allocator)
}

// `offset` as a position in `text`, whose lines begin at `line_starts`. UTF-16
// positions count a supplementary-plane character as two units and each byte
// that is not UTF-8 as one, as the replacement character it decodes to. A
// newline ends a line, as the compiler counts lines; an offset at the newline
// of a `\r\n` is the end of its line, before the `\r`, since the protocol has
// no position between them.
offset_to_position :: proc(text: string, line_starts: []u32, offset: u32, utf8_units: bool) -> Position {
	offset := min(int(offset), len(text))
	line := 0
	for lo, hi := 0, len(line_starts); lo < hi; {
		mid := (lo + hi) / 2
		if int(line_starts[mid]) <= offset { line, lo = mid, mid + 1 } else { hi = mid }
	}
	start := len(line_starts) > 0 ? min(int(line_starts[line]), offset) : 0
	if offset > start && offset < len(text) && text[offset] == '\n' && text[offset - 1] == '\r' { offset -= 1 }
	return Position{line, utf8_units ? offset - start : utf16_length(text[start:offset])}
}

// The byte offset of `position` in `text`, clamped to the end of its line or
// of the text. Used for incremental edits, so lines are found by scanning.
position_to_offset :: proc(text: string, position: Position, utf8_units: bool) -> int {
	offset := 0
	for _ in 0 ..< position.line {
		next := strings.index_byte(text[offset:], '\n')
		if next < 0 { return len(text) }
		offset += next + 1
	}
	line_end := strings.index_byte(text[offset:], '\n')
	line := text[offset:] if line_end < 0 else text[offset:offset + line_end]
	// A `\r\n` ends the line before its `\r`.
	if line_end >= 0 { line = strings.trim_suffix(line, "\r") }
	if utf8_units { return offset + clamp(position.character, 0, len(line)) }
	units := 0
	for i := 0; i < len(line); {
		r, width := utf8.decode_rune_in_string(line[i:])
		units += r >= 0x10000 ? 2 : 1
		if units > position.character { return offset + i }
		i += max(width, 1)
	}
	return offset + len(line)
}

utf16_length :: proc(text: string) -> int {
	units := 0
	for i := 0; i < len(text); {
		r, width := utf8.decode_rune_in_string(text[i:])
		units += r >= 0x10000 ? 2 : 1
		i += max(width, 1)
	}
	return units
}

@(private = "file")
percent_decode :: proc(text: string, allocator := context.allocator) -> (string, bool) {
	b := strings.builder_make(allocator)
	for i := 0; i < len(text); i += 1 {
		if text[i] != '%' {
			strings.write_byte(&b, text[i])
			continue
		}
		if i + 2 >= len(text) { return "", false }
		hi, lo := hex_value(text[i + 1]), hex_value(text[i + 2])
		if hi < 0 || lo < 0 { return "", false }
		strings.write_byte(&b, u8(hi << 4 | lo))
		i += 2
	}
	return strings.to_string(b), true
}

@(private = "file")
hex_value :: proc(ch: u8) -> int {
	switch ch {
	case '0' ..= '9': return int(ch - '0')
	case 'a' ..= 'f': return int(ch - 'a' + 10)
	case 'A' ..= 'F': return int(ch - 'A' + 10)
	}
	return -1
}

@(private = "file")
is_letter :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

@(private = "file")
is_unreserved :: proc(ch: u8) -> bool {
	return is_letter(ch) || (ch >= '0' && ch <= '9') || ch == '-' || ch == '.' || ch == '_' || ch == '~'
}
