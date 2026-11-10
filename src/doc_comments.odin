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
	written_lines := strings.split_lines(body, context.temp_allocator)
	for &line in written_lines {
		line = strings.trim_right_space(line)
	}
	margin, found := "", false
	for line in written_lines[1:] {
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
	// The text after `/**` is not indented like the lines below it.
	text := make([dynamic]string, context.temp_allocator)
	append(&text, strings.trim_left(written_lines[0], " \t"))
	for line in written_lines[1:] {
		append(&text, line == "" ? line : line[len(margin):])
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
	w := Doc_Walk{source = source, documented = make([]bool, len(source.comments), context.temp_allocator)}
	if file.package_name != "" {
		document_block(&w, file.package_lo)
	}
	for item in file.items {
		walk_documented_item(&w, item)
	}
	for comment, index in source.comments {
		if !w.documented[index] && is_doc_comment(source.text[comment.lo:comment.hi]) {
			warnf(
				c, comment, "L0260",
				"this doc comment documents nothing: it must be directly above a declaration, field, variant, member, or `package` clause, with no blank line between",
			)
		}
	}
}

@(private = "file")
Doc_Walk :: struct {
	source:     ^Source,
	documented: []bool, // per comment
}

@(private = "file")
document_block :: proc(w: ^Doc_Walk, lo: u32) {
	first, last := comment_block(w.source, lo)
	for index in first ..< last {
		w.documented[index] = true
	}
}

@(private = "file")
walk_documented_item :: proc(w: ^Doc_Walk, item: Item) {
	#partial switch v in item {
	case ^Decl:
		document_block(w, v.span.lo)
		walk_documented_type(w, v.declared_type)
		for value in v.values {
			walk_documented_type(w, value)
		}
	case ^Item_Impl:
		for member in v.members {
			walk_documented_item(w, member)
		}
	case ^Item_Foreign_Block:
		for member in v.members {
			walk_documented_item(w, member)
		}
	case ^Item_Block:
		for member in v.items {
			walk_documented_item(w, member)
		}
	case ^Item_When:
		walk_documented_type(w, v.cond)
		walk_documented_item(w, v.then)
		walk_documented_item(w, v.otherwise)
	}
}

// The members of each type written in `e`, wherever it is written, but for a
// procedure's body.
@(private = "file")
walk_documented_type :: proc(w: ^Doc_Walk, e: Expr) {
	#partial switch v in e {
	case ^Type_Record:
		walk_documented_generic_params(w, v.generic_params)
		walk_documented_fields(w, v.fields)
		walk_documented_variants(w, v.variants)
	case ^Type_Anon_Record:
		walk_documented_fields(w, v.fields)
	case ^Type_Anon_Union:
		walk_documented_variants(w, v.variants)
	case ^Type_Enum:
		for field in v.fields {
			document_block(w, field.span.lo)
		}
	case ^Type_Interface:
		walk_documented_generic_params(w, v.generic_params)
		for requirement in v.requirements {
			document_block(w, requirement.span.lo)
			for group in requirement.bindings {
				walk_documented_type(w, group.type)
			}
			walk_documented_type(w, requirement.result)
			walk_documented_type(w, requirement.slot_type)
		}
	case ^Expr_Proc:
		walk_documented_type(w, v.signature)
	case:
		// Anywhere else a type may be written: an element type, a parameter's
		// type or default, an array's length, or a call's arguments, as in
		// `Box((x: int))`.
		expr_children(e, w, proc(data: rawptr, child: Expr) -> bool {
			walk_documented_type((^Doc_Walk)(data), child)
			return false
		})
	}
}

@(private = "file")
walk_documented_generic_params :: proc(w: ^Doc_Walk, parameters: []Generic_Param) {
	for parameter in parameters {
		walk_documented_type(w, parameter.type)
	}
}

@(private = "file")
walk_documented_fields :: proc(w: ^Doc_Walk, fields: []Field) {
	for field in fields {
		document_block(w, field.span.lo)
		walk_documented_type(w, field.type)
	}
}

@(private = "file")
walk_documented_variants :: proc(w: ^Doc_Walk, variants: []Variant) {
	for variant in variants {
		document_block(w, variant.span.lo)
		walk_documented_type(w, variant.type)
	}
}
