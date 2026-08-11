// Source manager and diagnostics engine (compiler-plan B2).
//
// Every later phase reports through here and every AST node carries a Span back
// to it. Diagnostics accumulate; nothing in the compiler aborts on the first
// error.
package lokec

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// A byte range in one loaded file. Line and column are derived at render time,
// so nothing upstream has to carry them.
Span :: struct {
	file: u32,
	lo:   u32,
	hi:   u32,
}

// Span for a diagnostic that belongs to no particular source location, such as
// a missing file on the command line.
NO_FILE :: max(u32)

no_span :: proc() -> Span {
	return Span{file = NO_FILE}
}

Source :: struct {
	path:        string,
	text:        string,
	line_starts: []u32, // byte offset of the first character of each line
}

Severity :: enum {
	Error,
	Warning,
}

Note :: struct {
	span:    Span, // NO_FILE for a note with no location
	message: string,
}

Diagnostic :: struct {
	severity: Severity,
	code:     string, // stable, e.g. "L0104"
	span:     Span,
	message:  string,
	label:    string, // short text printed after the caret; may be empty
	notes:    []Note,
}

// Compiler-wide state. Named `Compiler` rather than `Context` because `context`
// is an Odin keyword.
//
// Source buffers and diagnostics use the process allocator. Parsed syntax is
// owned separately by each File's arena; long-lived identifier/type interning
// arrives with the package and type-system work.
Compiler :: struct {
	sources:     [dynamic]Source,
	diagnostics: [dynamic]Diagnostic,
	error_count: int,
}

// Loads a file and registers it. Reports and returns false on failure, so the
// caller never has to invent its own error text.
load_source :: proc(c: ^Compiler, path: string) -> (index: u32, ok: bool) {
	data, read_ok := os.read_entire_file(path)
	if !read_ok {
		errorf(c, no_span(), "L0001", "cannot read file `%s`", path)
		return 0, false
	}

	text := string(data)
	// grammar.md: a source file is UTF-8 *without* a BOM.
	if strings.has_prefix(text, "\xef\xbb\xbf") {
		errorf(c, no_span(), "L0002", "`%s` starts with a UTF-8 byte order mark", path)
		return 0, false
	}

	starts := make([dynamic]u32)
	append(&starts, 0)
	for i := 0; i < len(text); i += 1 {
		if text[i] == '\n' {
			append(&starts, u32(i + 1))
		}
	}

	index = u32(len(c.sources))
	append(&c.sources, Source{path = path, text = text, line_starts = starts[:]})
	if valid, bad_offset := valid_utf8(text); !valid {
		errorf(
			c,
			Span{file = index, lo = bad_offset, hi = bad_offset + 1},
			"L0003",
			"source is not valid UTF-8",
		)
		return index, false
	}
	return index, true
}

valid_utf8 :: proc(text: string) -> (valid: bool, bad_offset: u32) {
	for i := 0; i < len(text); {
		r, width := utf8.decode_rune_in_string(text[i:])
		if r == utf8.RUNE_ERROR && width == 1 && text[i] >= utf8.RUNE_SELF {
			return false, u32(i)
		}
		i += width
	}
	return true, 0
}

// 1-based line and column of a byte offset. Column counts bytes, which is
// correct for Loke: everything outside strings, comments and rune literals is
// ASCII by definition.
line_col :: proc(src: ^Source, offset: u32) -> (line: int, col: int) {
	i, found := slice.binary_search(src.line_starts, offset)
	if !found {
		i -= 1
	}
	return i + 1, int(offset-src.line_starts[i]) + 1
}

line_text :: proc(src: ^Source, line: int) -> string {
	start := src.line_starts[line - 1]
	end := u32(len(src.text))
	if line < len(src.line_starts) {
		end = src.line_starts[line]
	}
	return strings.trim_right(src.text[start:end], "\r\n")
}

errorf :: proc(c: ^Compiler, span: Span, code: string, format: string, args: ..any) {
	append(
		&c.diagnostics,
		Diagnostic {
			severity = .Error,
			code = code,
			span = span,
			message = fmt.aprintf(format, ..args),
		},
	)
	c.error_count += 1
}

// Same as `errorf` but with a short label printed under the caret.
error_labelf :: proc(
	c: ^Compiler,
	span: Span,
	code: string,
	label: string,
	format: string,
	args: ..any,
) {
	errorf(c, span, code, format, ..args)
	c.diagnostics[len(c.diagnostics) - 1].label = label
}

// Renders every accumulated diagnostic to stderr, in source order per file.
report :: proc(c: ^Compiler) {
	for &d in c.diagnostics {
		render(c, &d)
	}
}

@(private = "file")
render :: proc(c: ^Compiler, d: ^Diagnostic) {
	severity := d.severity == .Error ? "error" : "warning"
	fmt.eprintf("%s[%s]: %s\n", severity, d.code, d.message)

	if d.span.file != NO_FILE {
		src := &c.sources[d.span.file]
		line, col := line_col(src, d.span.lo)
		text := line_text(src, line)
		gutter := len(fmt.tprintf("%d", line))

		// Carets never run past the end of the line: a span may cover a
		// multi-line construct, but the snippet shows only where it starts.
		width := max(int(d.span.hi) - int(d.span.lo), 1)
		width = min(width, max(len(text)-col+1, 1))

		// The caret line copies any tabs from the source prefix, so the marker
		// stays under the right column whatever the reader's tab width is.
		indent := strings.clone(text[:col - 1])
		for i in 0 ..< len(indent) {
			if indent[i] != '\t' {
				(transmute([]u8)indent)[i] = ' '
			}
		}

		fmt.eprintf("%*s--> %s:%d:%d\n", gutter, "", src.path, line, col)
		fmt.eprintf("%*s |\n", gutter + 1, "")
		fmt.eprintf("%d | %s\n", line, text)
		fmt.eprintf("%*s | %s%s", gutter + 1, "", indent, strings.repeat("^", width))
		if d.label != "" {
			fmt.eprintf(" %s", d.label)
		}
		fmt.eprintln()
	}

	for note in d.notes {
		fmt.eprintf("  = note: %s\n", note.message)
	}
	fmt.eprintln()
}
