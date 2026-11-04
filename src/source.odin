// Source manager and diagnostics engine.
//
// Every later phase reports through here; every AST node carries a Span back
// to it. Diagnostics accumulate — nothing in the compiler aborts on the first
// error.
package lokec

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
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
NO_SPAN :: Span{file = NO_FILE}

// A map key for a place in the source; spans that start together share it.
span_key :: proc(span: Span) -> u64 {
	return u64(span.file) << 32 | u64(span.lo)
}

Source :: struct {
	path:        string,
	text:        string,
	// Non-empty only for process-allocated text. Incremental source text lives in
	// the checkpointed arena; tests may register string literals directly.
	owned_text:  []u8,
	line_starts: []u32, // byte offset of the first character of each line
	// Every comment, in source order, as the lexer last found them: a `//`
	// comment without its line ending, a block comment through its `*/`. The
	// token stream leaves them out; the formatter, the documentation
	// generator, and hover read them here, by span.
	comments:    [dynamic]Span,
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
	notes:    [dynamic]Note,
}

// Loads a file and registers it, reporting the failure itself.
load_source :: proc(c: ^Compiler, path: string) -> (index: u32, ok: bool) {
	if overlays := compiler_overlays(c); len(overlays) > 0 {
		if overlay, found := overlays[dir_key(canonical_dir(path))]; found {
			return add_loaded_source(c, path, transmute([]u8)strings.clone(overlay.text))
		}
	}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		errorf(c, NO_SPAN, "L0001", "cannot read file `%s`", path)
		return 0, false
	}
	return add_loaded_source(c, path, data)
}

// Registers the bytes read for `path`, taking ownership of them, after grammar.md
// "Source encoding"; reports a violation itself.
add_loaded_source :: proc(c: ^Compiler, path: string, data: []u8) -> (index: u32, ok: bool) {
	init_semantic_stores(c)
	data := data
	text := string(data)
	if strings.has_prefix(text, "\xef\xbb\xbf") {
		errorf(c, NO_SPAN, "L0002", "`%s` starts with a UTF-8 byte order mark", path)
		delete(data)
		return 0, false
	}

	if c.package_cache != nil {
		// A checkpoint owns source bytes along with syntax and semantic state.
		text = strings.clone(text, c.semantic_allocator)
		delete(data)
		data = nil
	}
	index = add_source(c, path, text, data)
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

// A diagnostic names a file relative to the working directory when it lies
// under it, and with `/` however the loader reached it, so a directory's files
// read like a file given on the command line.
display_path :: proc(path: string) -> string {
	shown := path
	if filepath.is_abs(path) {
		cwd := os.get_working_directory(context.temp_allocator) or_else ""
		if relative, err := filepath.rel(cwd, path, context.temp_allocator); err == nil && !strings.has_prefix(relative, "..") {
			shown = relative
		}
	}
	slashed, _ := strings.replace_all(shown, "\\", "/", context.temp_allocator)
	return slashed
}

// Registers source text; `owned` is freed with the compilation.
add_source :: proc(c: ^Compiler, path, text: string, owned: []u8 = nil) -> u32 {
	append(&c.sources, make_source(c, path, text, owned))
	return u32(len(c.sources) - 1)
}

make_source :: proc(c: ^Compiler, path, text: string, owned: []u8 = nil) -> Source {
	context.allocator = c.semantic_allocator if c.package_cache != nil else context.allocator
	starts := make([dynamic]u32)
	append(&starts, 0)
	for i := 0; i < len(text); i += 1 {
		if text[i] == '\n' {
			append(&starts, u32(i + 1))
		}
	}
	return Source{path = path, text = text, owned_text = owned, line_starts = starts[:], comments = make([dynamic]Span)}
}

valid_utf8 :: proc(text: string) -> (valid: bool, bad_offset: u32) {
	for i := 0; i < len(text); {
		r, width := utf8.decode_rune_in_string(text[i:])
		if r == utf8.RUNE_ERROR && width == 1 {
			return false, u32(i)
		}
		i += width
	}
	return true, 0
}

// The 0-based line of a byte offset, given a file's non-empty `line_starts`.
line_of_offset :: proc(line_starts: []u32, offset: u32) -> int {
	i, found := slice.binary_search(line_starts, offset)
	return i if found else i - 1
}

// 1-based line and column of a byte offset. The column counts bytes; only
// `render`'s caret line needs characters.
line_col :: proc(src: ^Source, offset: u32) -> (line: int, col: int) {
	i := line_of_offset(src.line_starts, offset)
	return i + 1, int(offset-src.line_starts[i]) + 1
}

// The loaded file a span lies in, or nil for a span in none.
span_source :: proc(c: ^Compiler, span: Span) -> ^Source {
	return &c.sources[span.file] if int(span.file) < len(c.sources) else nil
}

// The source text a span covers, or empty for a span with none.
span_text :: proc(c: ^Compiler, span: Span) -> string {
	src := span_source(c, span)
	if src == nil {
		return ""
	}
	hi := min(int(span.hi), len(src.text))
	return int(span.lo) < hi ? src.text[span.lo:hi] : ""
}

// The source text of an expression, or empty for one with no source.
source_text :: proc(c: ^Compiler, e: Expr) -> string {
	return span_text(c, expr_span(e))
}

@(private = "file")
line_text :: proc(src: ^Source, line: int) -> string {
	start := src.line_starts[line - 1]
	end := u32(len(src.text))
	if line < len(src.line_starts) {
		end = src.line_starts[line]
	}
	return strings.trim_right(src.text[start:end], "\r\n")
}

// The length of `line` without a trailing `//` comment or the blanks before
// it. Quotes are skipped, so a `//` inside a string or rune literal stays code.
code_end :: proc(line: string) -> int {
	quote: u8 = 0
	for i := 0; i < len(line); i += 1 {
		ch := line[i]
		switch {
		case quote != 0 && ch == '\\' && quote != '`':
			i += 1
		case quote != 0:
			if ch == quote { quote = 0 }
		case ch == '"' || ch == '\'' || ch == '`':
			quote = ch
		case ch == '/' && i + 1 < len(line) && line[i + 1] == '/':
			return len(strings.trim_right_space(line[:i]))
		}
	}
	return len(line)
}

// Diagnostics are raised in every phase, including emission, whose context
// allocator is an arena. Pinning one allocator — the list's own — keeps a
// diagnostic from being freed with an allocator that did not hand it out.
diagnostic_allocator :: proc(c: ^Compiler) -> mem.Allocator {
	if c.diagnostics.allocator.procedure == nil {
		c.diagnostics.allocator = context.allocator
	}
	return c.diagnostics.allocator
}

@(private = "file")
append_diagnostic :: proc(
	c: ^Compiler,
	severity: Severity,
	span: Span,
	code: string,
	format: string,
	args: ..any,
) {
	context.allocator = diagnostic_allocator(c)
	append(
		&c.diagnostics,
		Diagnostic {
			severity = severity,
			code = code,
			span = span,
			message = fmt.aprintf(format, ..args),
		},
	)
}

errorf :: proc(c: ^Compiler, span: Span, code: string, format: string, args: ..any) {
	append_diagnostic(c, .Error, span, code, format, ..args)
	c.error_count += 1
}

// A diagnostic that does not fail the compilation.
warnf :: proc(c: ^Compiler, span: Span, code: string, format: string, args: ..any) {
	append_diagnostic(c, .Warning, span, code, format, ..args)
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
	// A label is either source-backed or a temporary, so clone it for one owner.
	c.diagnostics[len(c.diagnostics) - 1].label = strings.clone(label, diagnostic_allocator(c))
}

// Attaches a secondary location to the most recently emitted diagnostic.
add_notef :: proc(c: ^Compiler, span: Span, format: string, args: ..any) {
	if len(c.diagnostics) == 0 {
		return
	}
	context.allocator = diagnostic_allocator(c)
	diagnostic := &c.diagnostics[len(c.diagnostics) - 1]
	append(&diagnostic.notes, Note{span = span, message = fmt.aprintf(format, ..args)})
}

// Resizing the list alone would lose the owned strings and note arrays past the
// new length, so a dropped diagnostic is freed through here.
destroy_diagnostic :: proc(c: ^Compiler, d: ^Diagnostic) {
	context.allocator = diagnostic_allocator(c)
	delete(d.message)
	delete(d.label)
	for &note in d.notes {
		delete(note.message)
	}
	delete(d.notes)
	d^ = {}
}

// Undoes one report: its `error_count` and what it owns.
discard_diagnostic :: proc(c: ^Compiler, d: ^Diagnostic) {
	if d.severity == .Error {
		c.error_count -= 1
	}
	destroy_diagnostic(c, d)
}

// Rolls the list back to `length`, undoing the `error_count` the dropped errors
// raised: a speculative check that reports and then rolls back must leave the
// compilation exactly as it found it.
truncate_diagnostics :: proc(c: ^Compiler, length: int) {
	wanted := clamp(length, 0, len(c.diagnostics))
	for index := wanted; index < len(c.diagnostics); index += 1 {
		discard_diagnostic(c, &c.diagnostics[index])
	}
	shrink_diagnostics(c, wanted)
}

// Cuts the list to `length`, whose dropped entries the caller has disposed of. An
// instantiation stack is remembered by the length that attached it, so a rollback
// past that point must let the next diagnostic claim its own frames.
shrink_diagnostics :: proc(c: ^Compiler, length: int) {
	resize(&c.diagnostics, length)
	c.last_noted_diagnostic = min(c.last_noted_diagnostic, length)
}

// A hypothetical check (compiler-architecture.md "Checking and overload
// resolution"). `end_probe` fails if a probe grew the emission registries without
// a `begin_commit`.
Probe :: struct {
	diagnostics, depth, commits: int,
	registries:                  Emission_Registries,
}

// The sizes of the registries emission reads.
Emission_Registries :: struct {
	typeids, typeid_order, witnesses, witness_order: int,
	materialized, materialized_order:                int,
	instances, checked_bodies, static_locals:        int,
	synth_procs, spawn_tasks:                        int,
	format_requested, type_info_requested:           bool,
}

emission_registries :: proc(c: ^Compiler) -> Emission_Registries {
	r := Emission_Registries {
		typeids             = len(c.typeid_requested),
		typeid_order        = len(c.typeid_order),
		witnesses           = len(c.witnesses),
		witness_order       = len(c.witness_order),
		materialized        = len(c.materialized),
		materialized_order  = len(c.materialized_order),
		checked_bodies      = len(c.checked_bodies),
		static_locals       = len(c.static_locals),
		synth_procs         = len(c.synth_procs),
		spawn_tasks         = len(c.spawn_tasks),
		format_requested    = c.format_requested,
		type_info_requested = c.type_info_requested,
	}
	for pkg in c.packages { r.instances += len(pkg.instances) }
	return r
}

begin_probe :: proc(c: ^Compiler) -> Probe {
	c.speculation_depth += 1
	return Probe {
		diagnostics = len(c.diagnostics),
		depth       = c.speculation_depth,
		commits     = c.commits,
		registries  = emission_registries(c),
	}
}

end_probe :: proc(c: ^Compiler, probe: Probe, keep := false) {
	assert(c.speculation_depth == probe.depth, "a probe ended out of order")
	assert(c.commits != probe.commits || emission_registries(c) == probe.registries,
	       "a probe enrolled emission state without asking committing(c)")
	if !keep {
		truncate_diagnostics(c, probe.diagnostics)
	}
	c.speculation_depth -= 1
}

// Whether what the checker finds now belongs to the program, as it does outside
// every probe. Every such write asks this; nothing else reads `speculation_depth`.
committing :: proc(c: ^Compiler) -> bool {
	return c.speculation_depth == 0
}

// The one sanctioned commit from inside a probe: `ensure_proc_typed_for_eval`
// checks a body compile-time evaluation will execute, which is a real use.
begin_commit :: proc(c: ^Compiler) -> (saved: int) {
	saved = c.speculation_depth
	c.speculation_depth = 0
	c.commits += 1
	return
}

end_commit :: proc(c: ^Compiler, saved: int) {
	c.speculation_depth = saved
}

// Whether an error was reported since `mark`, a length of `c.diagnostics`.
// Diagnostics a nested check held aside belong to that check.
errors_since :: proc(c: ^Compiler, mark: int) -> bool {
	for d in c.diagnostics[clamp(mark, 0, len(c.diagnostics)):] {
		if d.severity == .Error { return true }
	}
	return false
}

// Moves every diagnostic past `length`, with its share of `error_count`, out of
// `truncate_diagnostics`' reach until `release_held_diagnostics`.
hold_diagnostics :: proc(c: ^Compiler, length: int) {
	wanted := clamp(length, 0, len(c.diagnostics))
	context.allocator = diagnostic_allocator(c)
	for index in wanted ..< len(c.diagnostics) {
		if c.diagnostics[index].severity == .Error {
			c.error_count -= 1
		}
		append(&c.held_diagnostics, c.diagnostics[index])
	}
	shrink_diagnostics(c, wanted)
}

release_held_diagnostics :: proc(c: ^Compiler) {
	context.allocator = diagnostic_allocator(c)
	for d in c.held_diagnostics {
		append(&c.diagnostics, d)
		if d.severity == .Error {
			c.error_count += 1
		}
	}
	clear(&c.held_diagnostics)
}

// Renders every accumulated diagnostic to stderr. The two provenance analyses
// run after the whole program is checked, so their diagnostics arrive last; a
// stable sort by position restores one reading order, and by everything
// `same_diagnostic` compares, so a repeat follows what it repeats.
report :: proc(c: ^Compiler) {
	release_held_diagnostics(c)
	slice.stable_sort_by(c.diagnostics[:], proc(a, b: Diagnostic) -> bool {
		switch {
		case a.span.file != b.span.file: return a.span.file < b.span.file
		case a.span.lo != b.span.lo:     return a.span.lo < b.span.lo
		case a.span.hi != b.span.hi:     return a.span.hi < b.span.hi
		case a.severity != b.severity:   return a.severity < b.severity
		case a.code != b.code:           return a.code < b.code
		case a.message != b.message:     return a.message < b.message
		}
		return a.label < b.label
	})
	previous: ^Diagnostic
	reported_notes: [dynamic]Note
	defer delete(reported_notes)
	for &d in c.diagnostics {
		// One mistake reported twice is one diagnostic: two blocks left open by the
		// same missing brace both run out of input at the same span. A repeated
		// generic error contributes its new context without repeating the cause.
		if previous != nil && same_diagnostic(previous^, d) {
			for note in d.notes {
				if !slice.contains(reported_notes[:], note) {
					render_note(c, note)
					append(&reported_notes, note)
				}
			}
			continue
		}
		if previous != nil { fmt.eprintln() }
		render(c, &d)
		previous = &d
		clear(&reported_notes)
		append(&reported_notes, ..d.notes[:])
	}
	if previous != nil { fmt.eprintln() }
}

@(private = "file")
same_diagnostic :: proc(a, b: Diagnostic) -> bool {
	return a.severity == b.severity &&
		a.code == b.code &&
		a.span == b.span &&
		a.label == b.label &&
		a.message == b.message
}

@(private = "file")
render :: proc(c: ^Compiler, d: ^Diagnostic) {
	severity := d.severity == .Error ? "error" : "warning"
	fmt.eprintf("%s[%s]: %s\n", severity, d.code, d.message)

	if src := span_source(c, d.span); src != nil {
		line, col := line_col(src, d.span.lo)
		text := line_text(src, line)
		gutter := len(fmt.tprintf("%d", line))

		// The snippet drops the line ending, so a span pointing into it lands past
		// the text; a multi-line span only marks where it starts. Both stay inside.
		// A trailing comment is not part of what it marks.
		col = min(col, len(text) + 1)
		width := max(int(d.span.hi) - int(d.span.lo), 1)
		width = min(width, max(code_end(text)-col+1, 1))
		carets := max(utf8.rune_count_in_string(text[col - 1:min(col - 1 + width, len(text))]), 1)

		// The caret line keeps the prefix's tabs, so the marker stays under the
		// right column whatever the reader's tab width is, and has one blank for
		// each other character, however many bytes it takes.
		indent := strings.builder_make(context.temp_allocator)
		for r in text[:col - 1] {
			strings.write_byte(&indent, r == '\t' ? '\t' : ' ')
		}

		fmt.eprintf("%*s--> %s:%d:%d\n", gutter, "", display_path(src.path), line, col)
		fmt.eprintf("%*s |\n", gutter + 1, "")
		// Diagnostics are text, so a line that is not valid UTF-8, which L0003
		// reports, shows each run of bad bytes as one U+FFFD rather than echoing it.
		fmt.eprintf("%d | %s\n", line, strings.to_valid_utf8(text, "�", context.temp_allocator))
		fmt.eprintf("%*s | %s%s", gutter + 1, "", strings.to_string(indent), strings.repeat("^", carets, context.temp_allocator))
		if d.label != "" {
			fmt.eprintf(" %s", d.label)
		}
		fmt.eprintln()
	}

	for note in d.notes {
		render_note(c, note)
	}
}

@(private = "file")
render_note :: proc(c: ^Compiler, note: Note) {
	if src := span_source(c, note.span); src != nil {
		line, col := line_col(src, note.span.lo)
		fmt.eprintf("  = note: %s:%d:%d: %s\n", display_path(src.path), line, col, note.message)
	} else {
		fmt.eprintf("  = note: %s\n", note.message)
	}
}
