// `-doc`: the root package's public API as Markdown, from its checked public
// declarations and the comments written directly above them.
package lokec

import "core:fmt"
import "core:strings"

// Every public declaration, in file and source order: its signature, then its
// doc comment. A procedure is shown without its body and a struct with only
// its public fields; everything else is shown as written.
document_package :: proc(c: ^Compiler, id: Package_Id) -> string {
	pkg := package_of(c, id)
	b := strings.builder_make()
	fmt.sbprintfln(&b, "# package %s", identifier_text(c, pkg.name))
	for file in pkg.files {
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				document_decl(c, &b, v, "")
			case ^Item_Foreign_Block:
				for member in v.members {
					if d, is_decl := member.(^Decl); is_decl {
						document_decl(c, &b, d, "")
					}
				}
			case ^Item_Impl:
				owner := source_text(c, v.type)
				for member in v.members {
					if d, is_decl := member.(^Decl); is_decl {
						document_decl(c, &b, d, owner)
					}
				}
			}
		}
	}
	return strings.to_string(b)
}

@(private = "file")
document_decl :: proc(c: ^Compiler, b: ^strings.Builder, d: ^Decl, owner: string) {
	if len(d.names) == 0 || len(d.symbols) == 0 {
		return
	}
	if symbol := symbol_of(c, d.symbols[0]); symbol == nil || !symbol.public {
		return
	}
	text := c.sources[d.span.file].text
	start := d.names[0].span.lo
	for attribute in d.attributes {
		start = min(start, attribute.span.lo)
	}

	name := d.names[0].text
	if owner != "" {
		name = fmt.aprintf("%s.%s", owner, name)
	}
	fmt.sbprintfln(b, "\n## %s\n\n```odin", name)
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
				signature = public_struct(c, text[d.names[0].span.lo:v.span.hi], v)
			}
		}
	}
	fmt.sbprintfln(b, "%s\n```", strings.trim_right(signature, ";"))
	if doc := doc_comment(c, Span{file = d.span.file, lo = start}); doc != "" {
		fmt.sbprintfln(b, "\n%s", doc)
	}
}

// `Name :: struct { ... }` with only its public fields, one to a line.
@(private = "file")
public_struct :: proc(c: ^Compiler, written: string, record: ^Type_Record) -> string {
	b := strings.builder_make()
	open := strings.index_byte(written, '{')
	fmt.sbprintln(&b, strings.trim_space(written[:open + 1]))
	text := c.sources[record.span.file].text
	hidden := false
	for field in record.fields {
		if len(field.symbols) == 0 {
			continue
		}
		if symbol := symbol_of(c, field.symbols[0]); symbol != nil && symbol.public {
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

// The comments directly above `at`, one to a line with no blank line between
// them or below the last, and none sharing its line with code. Their markers
// are removed.
doc_comment :: proc(c: ^Compiler, at: Span) -> string {
	source := &c.sources[at.file]
	text := source.text
	first := len(source.comments)
	for index := len(source.comments) - 1; index >= 0; index -= 1 {
		comment := source.comments[index]
		if comment.hi > at.lo {
			continue
		}
		below := at.lo if first == len(source.comments) else source.comments[first].lo
		gap := text[comment.hi:below]
		line_start := strings.last_index_byte(text[:comment.lo], '\n') + 1
		if strings.count(gap, "\n") != 1 || strings.trim_space(gap) != "" ||
		   strings.trim_space(text[line_start:comment.lo]) != "" {
			break
		}
		first = index
	}
	lines := make([dynamic]string)
	for comment in source.comments[first:] {
		if comment.hi > at.lo {
			break
		}
		written := text[comment.lo:comment.hi]
		if strings.has_prefix(written, "//") {
			written = written[2:]
			append(&lines, strings.has_prefix(written, " ") ? written[1:] : written)
		} else {
			append(&lines, strings.trim_space(written[2:len(written) - 2]))
		}
	}
	return strings.join(lines[:], "\n")
}

@(private = "file")
source_text :: proc(c: ^Compiler, e: Expr) -> string {
	span := expr_span(e)
	return c.sources[span.file].text[span.lo:span.hi]
}
