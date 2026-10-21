// `-doc`: the public API of the root package, and of each package of the
// project it imports, as Markdown, from their checked public declarations and
// their doc comments (design.md "Doc comments").
package lokec

import "core:fmt"
import "core:strings"

// The root package's page, then one for each project package, in the order
// they were loaded. A project package is one whose key names no collection.
document_project :: proc(c: ^Compiler, root: Package_Id) -> string {
	b := strings.builder_make()
	document_package(c, &b, root)
	for &pkg in c.packages[1:] {
		if pkg.id != root && !strings.contains_rune(pkg.key, ':') {
			strings.write_byte(&b, '\n')
			document_package(c, &b, pkg.id)
		}
	}
	return strings.to_string(b)
}

// The doc comments of each file's package clause, a paragraph per file, then
// every public declaration, in file and source order: its signature, then its
// doc comment. A procedure is shown without its body and a struct with only
// its public fields and their comments; everything else is shown as written.
@(private = "file")
document_package :: proc(c: ^Compiler, b: ^strings.Builder, id: Package_Id) {
	pkg := package_of(c, id)
	if pkg.key == "" || strings.contains_rune(pkg.key, ':') {
		fmt.sbprintfln(b, "# package %s", identifier_text(c, pkg.name))
	} else {
		fmt.sbprintfln(b, "# package %s (`./%s`)", identifier_text(c, pkg.name), pkg.key)
	}
	for file in pkg.files {
		// The clause's span is its name's.
		text := c.sources[file.file].text
		keyword := u32(strings.last_index(text[:file.package_span.lo], "package"))
		start := written_start(text, keyword, file.attributes)
		if doc := doc_comment(c, Span{file = file.file, lo = start}); doc != "" {
			fmt.sbprintfln(b, "\n%s", doc)
		}
	}
	for file in pkg.files {
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				document_decl(c, b, file, v, "")
			case ^Item_Foreign_Block:
				for member in v.members {
					if d, is_decl := member.(^Decl); is_decl {
						document_decl(c, b, file, d, "")
					}
				}
			case ^Item_Impl:
				owner := source_text(c, v.type)
				for member in v.members {
					if d, is_decl := member.(^Decl); is_decl {
						document_decl(c, b, file, d, owner)
					}
				}
			}
		}
	}
}

@(private = "file")
document_decl :: proc(c: ^Compiler, b: ^strings.Builder, file: ^File, d: ^Decl, owner: string) {
	if len(d.names) == 0 {
		return
	}
	if len(d.symbols) == 0 {
		// A generic `impl`'s members are checked per instance.
		if owner == "" || !written_is_public(d.attributes, file.attributes) {
			return
		}
	} else if symbol := symbol_of(c, d.symbols[0]); symbol == nil || !symbol.public || symbol.is_test {
		// design.md "Test procedures": no importer can call a test.
		return
	}
	text := c.sources[d.span.file].text
	start := written_start(text, d.names[0].span.lo, d.attributes)

	name := d.names[0].text
	if owner != "" {
		name = fmt.aprintf("%s.%s", owner, name)
	}
	fmt.sbprintfln(b, "\n## %s\n\n```loke", name)
	// `@(public)` and `@(private)` decide whether the page shows it at all.
	for attribute in d.attributes {
		spelled := text[attribute.span.lo:attribute.span.hi]
		if spelled != "public" && spelled != "private" {
			fmt.sbprintfln(b, "@(%s)", spelled)
		}
	}
	signature := text[d.names[0].span.lo:d.span.hi]
	if len(d.values) == 1 {
		#partial switch v in d.values[0] {
		case ^Expr_Proc:
			if v.body != nil {
				signature = strings.trim_space(text[d.names[0].span.lo:v.body.span.lo])
			}
		case ^Type_Record:
			if v.kind == .Struct {
				signature = public_struct(c, file, text[d.names[0].span.lo:v.span.hi], v)
			}
		}
	}
	fmt.sbprintfln(b, "%s\n```", strings.trim_right(signature, ";"))
	if doc := doc_comment(c, Span{file = d.span.file, lo = start}); doc != "" {
		fmt.sbprintfln(b, "\n%s", doc)
	}
}

// Where something written at `lo` starts, counting its attributes: each one's
// span is its name's, after the `@(`.
@(private)
written_start :: proc(text: string, lo: u32, attributes: []Attribute) -> u32 {
	start := lo
	for attribute in attributes {
		start = min(start, u32(strings.last_index_byte(text[:attribute.span.lo], '@')))
	}
	return start
}

// `Name :: struct { ... }` with only its public fields, one to a line, each
// after its doc comment.
@(private = "file")
public_struct :: proc(c: ^Compiler, file: ^File, written: string, record: ^Type_Record) -> string {
	b := strings.builder_make()
	open := strings.index_byte(written, '{')
	fmt.sbprintln(&b, strings.trim_space(written[:open + 1]))
	text := c.sources[record.span.file].text
	hidden := false
	for field in record.fields {
		public: bool
		if len(record.generic_params) > 0 {
			// A generic record's fields are checked per instance.
			public = written_is_public(field.attributes, file.attributes, file.package_name == "main")
		} else if len(field.symbols) == 0 {
			continue
		} else {
			symbol := symbol_of(c, field.symbols[0])
			public = symbol != nil && symbol.public
		}
		if public {
			if doc := doc_comment(c, field.span); doc != "" {
				for line in strings.split_lines(doc) {
					fmt.sbprintln(&b, strings.trim_right_space(fmt.tprintf("\t/// %s", line)))
				}
			}
			fmt.sbprintfln(&b, "\t%s,", strings.trim_right(text[field.span.lo:field.span.hi], ","))
		} else {
			hidden = true
		}
	}
	if hidden {
		fmt.sbprintln(&b, "\t// and fields private to the package")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// design.md "Doc comments": the doc comments in the block directly above `at`,
// one to a line, with their markers removed.
doc_comment :: proc(c: ^Compiler, at: Span) -> string {
	source := &c.sources[at.file]
	first, last := comment_block(source, at.lo)
	lines := make([dynamic]string)
	defer delete(lines)
	for comment in source.comments[first:last] {
		written := source.text[comment.lo:comment.hi]
		if is_doc_comment(written) {
			written = written[3:]
			append(&lines, strings.has_prefix(written, " ") ? written[1:] : written)
		}
	}
	return strings.join(lines[:], "\n")
}

@(private = "file")
is_doc_comment :: proc(written: string) -> bool {
	return strings.has_prefix(written, "///") && !strings.has_prefix(written, "////")
}

// The comments directly above `lo`, as a range of `source.comments`: each on a
// line of its own, with no blank line between them or below the last.
@(private = "file")
comment_block :: proc(source: ^Source, lo: u32) -> (first, last: int) {
	text := source.text
	// The comments are in source order, so the first one ending after `lo`
	// starts the search without visiting the later ones.
	low, high := 0, len(source.comments)
	for low < high {
		middle := (low + high) / 2
		if source.comments[middle].hi > lo {
			high = middle
		} else {
			low = middle + 1
		}
	}
	first = low
	for index := low - 1; index >= 0; index -= 1 {
		comment := source.comments[index]
		below := lo if first == low else source.comments[first].lo
		gap := text[comment.hi:below]
		line_start := strings.last_index_byte(text[:comment.lo], '\n') + 1
		if strings.count(gap, "\n") != 1 || strings.trim_space(gap) != "" ||
		   strings.trim_space(text[line_start:comment.lo]) != "" {
			break
		}
		first = index
	}
	return first, low
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
		// The clause's span is its name's.
		keyword := u32(strings.last_index(source.text[:file.package_span.lo], "package"))
		document_block(&w, written_start(source.text, keyword, file.attributes))
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
		if len(v.names) > 0 {
			document_block(w, written_start(w.source.text, min(v.span.lo, v.names[0].span.lo), v.attributes))
		}
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
		walk_documented_item(w, v.then)
		walk_documented_item(w, v.otherwise)
	}
}

// The members of a type written in a declaration, and of the types written in
// those members.
@(private = "file")
walk_documented_type :: proc(w: ^Doc_Walk, e: Expr) {
	#partial switch v in e {
	case ^Type_Record:
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
		for requirement in v.requirements {
			document_block(w, requirement.span.lo)
		}
	}
}

@(private = "file")
walk_documented_fields :: proc(w: ^Doc_Walk, fields: []Field) {
	for field in fields {
		document_block(w, written_start(w.source.text, field.span.lo, field.attributes))
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

@(private = "file")
source_text :: proc(c: ^Compiler, e: Expr) -> string {
	span := expr_span(e)
	return c.sources[span.file].text[span.lo:span.hi]
}
