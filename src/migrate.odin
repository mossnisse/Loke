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
import "core:os"
import "core:slice"
import "core:strings"

// Rewrites every `.loke` file of `input`, a file or a directory's direct files,
// in place; with `check`, only lists the ones that would change. The exit status
// is 1 when a file does not parse, cannot be rewritten, or, with `check`, would
// change.
migrate_files :: proc(c: ^Compiler, input: string, check: bool) -> int {
	status := 0
	for path in input_sources(c, input) {
		file, loaded := load_source(c, path)
		if !loaded {
			status = 1
			continue
		}
		migrated, ok := migrate_source(c, file)
		if !ok {
			status = 1
			continue
		}
		defer delete(migrated)
		if migrated == c.sources[file].text {
			continue
		}
		if check {
			fmt.println(path)
			status = 1
		} else if os.write_entire_file(path, transmute([]u8)migrated) != nil {
			errorf(c, no_span(), "L0401", "cannot write `%s`", path)
			status = 1
		}
	}
	return status
}

// The source of `file` with its earlier spellings rewritten, or false, with the
// diagnostics saying why, when it does not parse or cannot be rewritten.
@(private = "file")
migrate_source :: proc(c: ^Compiler, file: u32) -> (string, bool) {
	errors := c.error_count
	tokens := lex(c, file)
	defer delete(tokens)
	ast := parse(c, file, tokens)
	defer destroy_ast(&ast)
	if c.error_count > errors {
		return "", false
	}
	text := c.sources[file].text
	if len(ast.earlier_spellings) == 0 {
		return strings.clone(text), true
	}

	edits := make([dynamic]Migrate_Edit, context.temp_allocator)
	spellings := slice.clone(ast.earlier_spellings, context.temp_allocator)
	slice.sort_by(spellings, proc(a, b: Earlier_Spelling) -> bool {
		// A probe the parser rolled back wrote its record again; one that reached
		// a declaration sorts first and answers for both.
		if spelling_start(a) != spelling_start(b) {
			return spelling_start(a) < spelling_start(b)
		}
		return a.declaration != nil && b.declaration == nil
	})
	last: u32 = 0
	for spelling in spellings {
		start := spelling_start(spelling)
		if start == last {
			continue
		}
		last = start
		migrate_spelling(c, file, tokens, spelling, &edits)
	}
	if c.error_count > errors {
		return "", false
	}
	migrated := apply_edits(text, edits[:])

	// The guarantee, checked rather than assumed: the same tree, with nothing
	// left to rewrite.
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

@(private = "file")
spelling_start :: proc(spelling: Earlier_Spelling) -> u32 {
	return spelling.keyword.hi > spelling.keyword.lo ? spelling.keyword.lo : spelling.groups.lo
}

// Replaces `text[lo:hi]`; an insertion has `lo == hi`.
@(private = "file")
Migrate_Edit :: struct {
	lo, hi: u32,
	text:   string,
}

@(private = "file")
apply_edits :: proc(text: string, edits: []Migrate_Edit) -> string {
	slice.sort_by(edits, proc(a, b: Migrate_Edit) -> bool { return a.lo < b.lo })
	out := strings.builder_make()
	at: u32 = 0
	for edit in edits {
		strings.write_string(&out, text[at:edit.lo])
		strings.write_string(&out, edit.text)
		at = edit.hi
	}
	strings.write_string(&out, text[at:])
	return strings.to_string(out)
}

// The first token at or after `offset`.
@(private = "file")
token_at :: proc(tokens: []Token, offset: u32) -> int {
	index, _ := slice.binary_search_by(tokens, offset, proc(t: Token, target: u32) -> slice.Ordering {
		return t.lo < target ? .Less : t.lo > target ? .Greater : .Equal
	})
	return index
}

@(private = "file")
migrate_spelling :: proc(c: ^Compiler, file: u32, tokens: []Token, spelling: Earlier_Spelling, edits: ^[dynamic]Migrate_Edit) {
	text := c.sources[file].text
	has_keyword := spelling.keyword.hi > spelling.keyword.lo
	has_groups := spelling.groups.hi > spelling.groups.lo
	where_written := has_keyword ? spelling.keyword : spelling.groups
	if spelling.declaration == nil {
		errorf(
			c, where_written, "L0752",
			"`-migrate` moves a record's attributes to its declaration, and this record has none",
		)
		add_notef(c, no_span(), "declare the type, `Name :: struct {{ ... }}`, and write the attributes there")
		return
	}

	// What moves, in the order the tree holds it.
	moved := make([dynamic]string, context.temp_allocator)
	if has_keyword {
		append(&moved, "move_only")
	}
	if has_groups {
		inners := make([dynamic]Span, context.temp_allocator)
		for index := token_at(tokens, spelling.groups.lo); index < len(tokens) && tokens[index].lo < spelling.groups.hi; {
			// `@` `(` ... `)`, whose parentheses may nest in a value.
			open := index + 1
			depth := 0
			close := open
			for ; close < len(tokens); close += 1 {
				#partial switch tokens[close].kind {
				case .Lparen: depth += 1
				case .Rparen: depth -= 1
				}
				if depth == 0 {
					break
				}
			}
			end := tokens[close - 1].kind == .Comma ? tokens[close - 1].lo : tokens[close].lo
			inner := Span{file = file, lo = tokens[open].hi, hi = end}
			append(&inners, inner)
			append(&moved, strings.trim_space(text[inner.lo:inner.hi]))
			index = close + 1
		}
		// A block comment travels inside a group; any other comment has nowhere
		// to go, and a line comment would swallow what follows it.
		for comment in c.sources[file].comments {
			if comment.lo < spelling.groups.lo || comment.lo >= spelling.groups.hi {
				continue
			}
			inside := false
			for inner in inners {
				inside ||= inner.lo <= comment.lo && comment.hi <= inner.hi
			}
			if !inside || strings.has_prefix(text[comment.lo:comment.hi], "//") {
				errorf(c, comment, "L0752", "`-migrate` cannot carry this comment with the attributes around it; move them to the declaration by hand")
				return
			}
		}
	}
	list := strings.join(moved[:], ", ", context.temp_allocator)

	// Into the declaration's last group, or a group of their own.
	d := spelling.declaration
	name := d.names[0].span.lo
	written := false
	for attribute in d.attributes {
		written ||= attribute.span.lo < name
	}
	if written {
		before_close := tokens[token_at(tokens, name) - 2]
		if before_close.kind == .Comma {
			append(edits, Migrate_Edit{before_close.hi, before_close.hi, fmt.tprintf(" %s", list)})
		} else {
			append(edits, Migrate_Edit{before_close.hi, before_close.hi, fmt.tprintf(", %s", list)})
		}
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
// those before it instead, and with the line if nothing else was on it.
@(private = "file")
removal :: proc(text: string, span: Span) -> Migrate_Edit {
	is_space :: proc(b: u8) -> bool { return b == ' ' || b == '\t' }
	lo, hi := span.lo, span.hi
	after := hi
	for int(after) < len(text) && is_space(text[after]) {
		after += 1
	}
	line_ends := int(after) == len(text) || text[after] == '\n' || text[after] == '\r'
	if !line_ends {
		return Migrate_Edit{lo, after, ""}
	}
	for lo > 0 && is_space(text[lo - 1]) {
		lo -= 1
	}
	if lo > 0 && text[lo - 1] == '\n' {
		if int(after) < len(text) && text[after] == '\r' {
			after += 1
		}
		if int(after) < len(text) && text[after] == '\n' {
			after += 1
		}
	}
	return Migrate_Edit{lo, after, ""}
}
