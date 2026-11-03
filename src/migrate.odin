// `-migrate`: rewrites the spellings an earlier release accepted into the ones
// this release does, and touches nothing else, so a file keeps its layout.
//
// Today that is a record's attributes, which move to its declaration:
// `Name :: move_only struct @(packed) { }` becomes
// `@(move_only, packed) Name :: struct { }`. Both spellings parse to one tree, so
// a rewrite is checked rather than assumed: the result has none left, and its
// `-dump-ast` text is the input's (comments.md "Formatting").
package lokec

import "core:fmt"
import "core:slice"
import "core:strings"

// The exit status is `rewrite_files`', where a file also fails by not being
// rewritable.
migrate_files :: proc(c: ^Compiler, input: string, check: bool) -> int {
	return rewrite_files(c, input, check, migrate_source)
}

// The source of `file` with its earlier spellings rewritten, or false, with the
// diagnostics saying why, when it does not parse or cannot be rewritten.
@(private = "file")
migrate_source :: proc(c: ^Compiler, file: u32) -> (string, bool) {
	errors := c.error_count
	tokens := lex(c, file)
	defer delete(tokens)
	ast := parse(c, file, tokens, accept_earlier_spellings = true)
	defer destroy_ast(&ast)
	if c.error_count > errors {
		return "", false
	}
	text := c.sources[file].text
	if len(ast.earlier_spellings) == 0 {
		return strings.clone(text), true
	}

	edits := make([dynamic]Migrate_Edit, context.temp_allocator)
	for spelling in ast.earlier_spellings {
		migrate_spelling(c, file, spelling, &edits)
	}
	if c.error_count > errors {
		return "", false
	}
	migrated, applied := apply_edits(c, file, edits[:])
	if !applied {
		return "", false
	}

	before := ast_dump(&ast)
	defer delete(before)
	again, added := add_loaded_source(c, c.sources[file].path, transmute([]u8)strings.clone(migrated))
	same := false
	if added {
		again_tokens := lex(c, again)
		defer delete(again_tokens)
		again_ast := parse(c, again, again_tokens)
		defer destroy_ast(&again_ast)
		after := ast_dump(&again_ast)
		defer delete(after)
		same = c.error_count == errors && len(again_ast.earlier_spellings) == 0 && before == after
	}
	if !same {
		delete(migrated)
		errorf(c, Span{file = file}, "L0751", "internal migration error: the rewrite would change what this file means")
		return "", false
	}
	return migrated, true
}

// Replaces `text[lo:hi]`; an insertion has `lo == hi`.
@(private = "file")
Migrate_Edit :: struct {
	lo, hi: u32,
	text:   string,
}

// Two edits overlap only where a record is written inside another's attributes,
// which moving the outer ones would carry along unrewritten.
@(private = "file")
apply_edits :: proc(c: ^Compiler, file: u32, edits: []Migrate_Edit) -> (string, bool) {
	text := c.sources[file].text
	slice.sort_by(edits, proc(a, b: Migrate_Edit) -> bool { return a.lo < b.lo })
	out := strings.builder_make()
	at: u32 = 0
	for edit in edits {
		if edit.lo < at {
			strings.builder_destroy(&out)
			errorf(c, Span{file = file, lo = edit.lo, hi = edit.hi}, "L0752", "`-migrate` cannot move a record's attributes while a record is written inside them; move the outer ones by hand")
			return "", false
		}
		strings.write_string(&out, text[at:edit.lo])
		strings.write_string(&out, edit.text)
		at = edit.hi
	}
	strings.write_string(&out, text[at:])
	return strings.to_string(out), true
}

@(private = "file")
migrate_spelling :: proc(c: ^Compiler, file: u32, spelling: Earlier_Spelling, edits: ^[dynamic]Migrate_Edit) {
	text := c.sources[file].text
	has_keyword := spelling.keyword.hi > spelling.keyword.lo
	has_groups := spelling.groups.hi > spelling.groups.lo
	d := spelling.declaration
	if d == nil {
		errorf(
			c, has_keyword ? spelling.keyword : spelling.groups, "L0752",
			"`-migrate` moves a record's attributes to its declaration, and this record has none",
		)
		add_notef(c, no_span(), "declare the type, `Name :: struct {{ ... }}`, and write the attributes there")
		return
	}

	// The tree holds what is written on the declaration, then what moves.
	name := d.names[0].span.lo
	moved := make([dynamic]string, context.temp_allocator)
	last_written: Maybe(u32)
	for attribute in d.attributes {
		if attribute.span.lo < name {
			last_written = attribute.span.hi
		} else {
			append(&moved, text[attribute.span.lo:attribute.span.hi])
		}
	}

	// A block comment travels inside an attribute; any other comment has nowhere
	// to go, and a line comment would swallow what follows it.
	for comment in c.sources[file].comments {
		if !has_groups || comment.lo < spelling.groups.lo || comment.lo >= spelling.groups.hi {
			continue
		}
		inside := false
		for attribute in d.attributes {
			inside ||= attribute.span.lo <= comment.lo && comment.hi <= attribute.span.hi
		}
		if !inside || strings.has_prefix(text[comment.lo:comment.hi], "//") {
			errorf(c, comment, "L0752", "`-migrate` cannot carry this comment with the attributes around it; move them to the declaration by hand")
			return
		}
	}
	list := strings.join(moved[:], ", ", context.temp_allocator)

	// Into the declaration's last group, or a group of their own.
	if at, written := last_written.?; written {
		append(edits, Migrate_Edit{at, at, fmt.tprintf(", %s", list)})
	} else {
		append(edits, Migrate_Edit{name, name, fmt.tprintf("@(%s) ", list)})
	}

	if has_keyword {
		append(edits, removal(text, spelling.keyword))
	}
	if has_groups {
		append(edits, removal(text, spelling.groups))
	}
}

// Takes `span` out with the spaces after it, or, where it ended its line, with
// those before it instead, and with the line if nothing else was on it. A clean
// parse puts a token after `span` and `package` before it, so no scan here runs
// off the text, and the lexer makes every `\r` begin a `\r\n`.
@(private = "file")
removal :: proc(text: string, span: Span) -> Migrate_Edit {
	is_space :: proc(b: u8) -> bool { return b == ' ' || b == '\t' }
	is_word :: proc(b: u8) -> bool { return b == '_' || b >= 0x80 || (b >= '0' && b <= '9') || (b | 0x20 >= 'a' && b | 0x20 <= 'z') }
	lo, after := span.lo, span.hi
	for is_space(text[after]) {
		after += 1
	}
	if text[after] != '\n' && text[after] != '\r' {
		// `union@(zero=a)where` must not become one word.
		return Migrate_Edit{lo, after, is_word(text[lo - 1]) && is_word(text[after]) ? " " : ""}
	}
	for is_space(text[lo - 1]) {
		lo -= 1
	}
	if text[lo - 1] == '\n' {
		after += text[after] == '\r' ? 2 : 1
	}
	return Migrate_Edit{lo, after, ""}
}
