// Reading doc comments, and warning about one that documents nothing (design.md
// "Doc comments").
package lokec

import "core:strings"

// design.md "Doc comments": the text of the doc comments in the block directly
// above `at`, in order, one line of text to a line.
doc_comment :: proc(c: ^Compiler, at: Span) -> string {
	source := &c.sources[at.file]
	first, last := comment_block(source, at.lo)
	lines := make([dynamic]string)
	defer delete(lines)
	for comment in source.comments[first:last] {
		written := source.text[comment.lo:comment.hi]
		if !is_doc_comment(written) {
			continue
		}
		if strings.has_prefix(written, "///") {
			written = written[3:]
			append(&lines, strings.has_prefix(written, " ") ? written[1:] : written)
		} else {
			block_doc_lines(&lines, written)
		}
	}
	return strings.join(lines[:], "\n")
}

// `///` but not `////`, or `/**` but not `/***` or the empty `/**/`.
is_doc_comment :: proc(written: string) -> bool {
	if strings.has_prefix(written, "/**") {
		return !strings.has_prefix(written, "/***") && written != "/**/"
	}
	return strings.has_prefix(written, "///") && !strings.has_prefix(written, "////")
}

// design.md "Doc comments": a block doc comment's lines.
@(private = "file")
block_doc_lines :: proc(lines: ^[dynamic]string, written: string) {
	body := strings.trim_suffix(written[len("/**"):], "*/")
	text := strings.split_lines(body, context.temp_allocator)
	for &line in text {
		line = strings.trim_right_space(line)
	}
	// The text after `/**` is not indented like the lines below it.
	text[0] = strings.trim_left(text[0], " \t")
	margin, found := "", false
	for line in text[1:] {
		if line == "" {
			continue
		}
		indent := line[:len(line) - len(strings.trim_left(line, " \t"))]
		if !found {
			margin, found = indent, true
		} else {
			shared := 0
			for shared < min(len(margin), len(indent)) && margin[shared] == indent[shared] {
				shared += 1
			}
			margin = margin[:shared]
		}
	}
	for &line in text[1:] {
		if line != "" {
			line = line[len(margin):]
		}
	}
	start, end := 0, len(text)
	for start < end && text[start] == "" {
		start += 1
	}
	for end > start && text[end - 1] == "" {
		end -= 1
	}
	append(lines, ..text[start:end])
}

// The index in `source.comments`, which are in source order, of the first
// comment ending after `lo`.
first_comment_after :: proc(source: ^Source, lo: u32) -> int {
	low, high := 0, len(source.comments)
	for low < high {
		middle := (low + high) / 2
		if source.comments[middle].hi > lo {
			high = middle
		} else {
			low = middle + 1
		}
	}
	return low
}

// The comments directly above `lo`, as a range of `source.comments`: each on a
// line of its own, with no blank line between them or below the last.
@(private = "file")
comment_block :: proc(source: ^Source, lo: u32) -> (first, last: int) {
	text := source.text
	last = first_comment_after(source, lo)
	first = last
	for index := last - 1; index >= 0; index -= 1 {
		comment := source.comments[index]
		below := lo if first == last else source.comments[first].lo
		gap := text[comment.hi:below]
		line_start := strings.last_index_byte(text[:comment.lo], '\n') + 1
		if strings.count(gap, "\n") != 1 || strings.trim_space(gap) != "" ||
		   strings.trim_space(text[line_start:comment.lo]) != "" {
			break
		}
		first = index
	}
	return first, last
}

// design.md "Doc comments": a doc comment in no documented item's block is
// reported. Every `when` branch counts, taken or not, so the report does not
// depend on the target.
check_doc_comments :: proc(c: ^Compiler, file: ^File) {
	source := &c.sources[file.file]
	found := false
	for comment in source.comments {
		if is_doc_comment(source.text[comment.lo:comment.hi]) {
			found = true
			break
		}
	}
	if !found {
		return
	}
	documented := make([]bool, len(source.comments), context.temp_allocator)
	for lo in documentable_items(file, context.temp_allocator) {
		first, last := comment_block(source, lo)
		for index in first ..< last {
			documented[index] = true
		}
	}
	for comment, index in source.comments {
		if !documented[index] && is_doc_comment(source.text[comment.lo:comment.hi]) {
			warnf(
				c, comment, "L0260",
				"this doc comment documents nothing: it must be directly above a declaration, field, variant, member, or `package` clause, with no blank line between",
			)
		}
	}
}

// design.md "Doc comments": where each item of `file` a doc comment can document
// starts, in no particular order. Every `when` branch counts, taken or not, and
// a procedure's body holds none.
documentable_items :: proc(file: ^File, allocator := context.allocator) -> []u32 {
	starts := make([dynamic]u32, allocator)
	if file.package_name != "" {
		append(&starts, file.package_lo)
	}
	for item in file.items {
		walk_documented_item(&starts, item)
	}
	return starts[:]
}

@(private = "file")
walk_documented_item :: proc(starts: ^[dynamic]u32, item: Item) {
	#partial switch v in item {
	case ^Decl:
		append(starts, v.span.lo)
		walk_documented_type(starts, v.declared_type)
		for value in v.values {
			walk_documented_type(starts, value)
		}
	case ^Item_Impl:
		walk_documented_type(starts, v.type)
		for member in v.members {
			walk_documented_item(starts, member)
		}
	case ^Item_Foreign_Block:
		for member in v.members {
			walk_documented_item(starts, member)
		}
	case ^Item_Block:
		for member in v.items {
			walk_documented_item(starts, member)
		}
	case ^Item_When:
		walk_documented_type(starts, v.cond)
		walk_documented_item(starts, v.then)
		walk_documented_item(starts, v.otherwise)
	case ^Item_Static_Assert:
		walk_documented_type(starts, v.call)
	}
}

// The members of each type written in `e`, wherever it is written, but for a
// procedure's body.
@(private = "file")
walk_documented_type :: proc(starts: ^[dynamic]u32, e: Expr) {
	#partial switch v in e {
	case ^Type_Record:
		walk_documented_generics(starts, v.generic_params, v.where_clauses)
		walk_documented_fields(starts, v.fields)
		walk_documented_variants(starts, v.variants)
	case ^Type_Anon_Record:
		walk_documented_fields(starts, v.fields)
	case ^Type_Anon_Union:
		walk_documented_variants(starts, v.variants)
	case ^Type_Enum:
		walk_documented_type(starts, v.backing)
		for field in v.fields {
			append(starts, field.span.lo)
			walk_documented_type(starts, field.value)
		}
	case ^Type_Interface:
		walk_documented_generics(starts, v.generic_params, v.where_clauses)
		for requirement in v.requirements {
			append(starts, requirement.span.lo)
			for group in requirement.bindings {
				walk_documented_type(starts, group.type)
			}
			walk_documented_type(starts, requirement.expr)
			walk_documented_type(starts, requirement.result)
			walk_documented_type(starts, requirement.slot_type)
		}
	case ^Expr_Proc:
		walk_documented_type(starts, v.signature)
		walk_documented_exprs(starts, v.where_clauses)
	case:
		// Anywhere else a type may be written: an element type, a parameter's
		// type or default, an array's length, or a call's arguments, as in
		// `Box((x: int))`.
		expr_children(e, starts, proc(data: rawptr, child: Expr) -> bool {
			walk_documented_type((^[dynamic]u32)(data), child)
			return false
		})
	}
}

@(private = "file")
walk_documented_generics :: proc(starts: ^[dynamic]u32, parameters: []Generic_Param, clauses: []Expr) {
	for parameter in parameters {
		walk_documented_type(starts, parameter.type)
	}
	walk_documented_exprs(starts, clauses)
}

@(private = "file")
walk_documented_exprs :: proc(starts: ^[dynamic]u32, exprs: []Expr) {
	for e in exprs {
		walk_documented_type(starts, e)
	}
}

@(private = "file")
walk_documented_fields :: proc(starts: ^[dynamic]u32, fields: []Field) {
	for field in fields {
		append(starts, field.span.lo)
		walk_documented_type(starts, field.type)
	}
}

@(private = "file")
walk_documented_variants :: proc(starts: ^[dynamic]u32, variants: []Variant) {
	for variant in variants {
		append(starts, variant.span.lo)
		walk_documented_type(starts, variant.type)
	}
}
