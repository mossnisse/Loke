// Parser (compiler-plan B4): recursive descent over grammar.md.
//
// M1 slice 1 covers the whole expression and type grammar. Declarations,
// statements and top-level items keep their M0 shape until slices 2-4; the
// constructs those still owe are named rather than met with "unexpected token".
//
// Two invariants this file exists to keep:
//   * A node's span ends at the last token actually *consumed*, never at the
//     token an `expect` tripped over.
//   * Nothing recurses without a depth guard. Recursive descent plus a fuzzer
//     that duplicates `(` is a stack overflow otherwise.
package lokec

import "core:mem"

// The limit is on *node* nesting, not just parser recursion, because every
// later phase walks the tree recursively — a flat parse of `1 + 1 + 1 + ...`
// still builds a left spine one node deep per term.
//
// ponytail: 128 is what the checker and the AST dump can walk on a default 1 MB
// stack, measured — their frames are fat with format-call temporaries. Split
// those two switches into per-family helpers if a real program ever needs more.
MAX_NEST :: 128

@(private = "file")
Parser :: struct {
	c:              ^Compiler,
	file:           u32,
	tokens:         []Token,
	index:          int,
	last:           Token, // last token consumed; every node's span ends here
	depth:          int,
	depth_reported: bool,
	// Set for the top level of a `where` expression, where the next `{` opens
	// the declaration's body rather than a composite literal.
	no_composite:   bool,
	// Set for a constant's value, where a written type *is* the value:
	// `My_Int :: int` and `Meters :: distinct int` are type aliases
	// (design.md "Advanced types"). One `parse_postfix` consumes it, so it does
	// not leak into the operands of a larger expression.
	type_value:     bool,
	// Panic mode: set when a construct is abandoned, cleared at the next
	// statement or item. Stops one failure from reporting once per stack frame.
	suppress:       bool,
	allocator:      mem.Allocator,
}

parse :: proc(c: ^Compiler, file: u32, tokens: []Token) -> File {
	result := File {
		file = file,
	}
	mem.dynamic_arena_init(&result.arena)
	allocator := mem.dynamic_arena_allocator(&result.arena)
	p := Parser {
		c         = c,
		file      = file,
		tokens    = tokens,
		allocator = allocator,
	}
	parse_package_clause(&p, &result)
	result.items = parse_items(&p, stop_at_rbrace = false)
	return result
}

// `Top_Level_Item*`, shared by the file and by a `Top_Level_Block`.
@(private = "file")
parse_items :: proc(p: ^Parser, stop_at_rbrace: bool) -> []Item {
	items := make([dynamic]Item, 0, 0, p.allocator)
	for !at(p, .EOF) {
		if stop_at_rbrace && at(p, .Rbrace) {
			break
		}
		before := p.index
		if item, ok := parse_top_level_item(p); ok {
			append(&items, item)
		}
		if p.index == before {
			// Recovery made no progress; force it so this cannot spin.
			advance(p)
		}
	}
	return items[:]
}

@(private = "file")
ast_new :: proc(p: ^Parser, $T: typeid) -> ^T {
	return new(T, p.allocator)
}

// Builds a node spanning `lo` through the last consumed token. Call it *after*
// the children are parsed; that is what makes the span rule hold on the
// recovery path too.
@(private = "file")
new_expr :: proc(p: ^Parser, $T: typeid, lo: u32) -> ^T {
	n := new(T, p.allocator)
	n.span = Span {
		file = p.file,
		lo   = lo,
		hi   = max(p.last.hi, lo),
	}
	return n
}

@(private = "file")
error_item :: proc(p: ^Parser, span: Span) -> Item {
	item := ast_new(p, Item_Error)
	item.span = span
	item.has_error = true
	return item
}

@(private = "file")
error_stmt :: proc(p: ^Parser, span: Span) -> Stmt {
	stmt := ast_new(p, Stmt_Error)
	stmt.span = span
	stmt.has_error = true
	return stmt
}

// The statement mirror of `new_expr`: spans end at the last consumed token.
@(private = "file")
new_stmt :: proc(p: ^Parser, $T: typeid, start: Token) -> ^T {
	n := new(T, p.allocator)
	n.span = span_to_here(p, start)
	return n
}

@(private = "file")
error_expr :: proc(p: ^Parser, span: Span) -> Expr {
	expr := ast_new(p, Expr_Error)
	expr.span = span
	expr.has_error = true
	return expr
}

@(private = "file")
current :: proc(p: ^Parser) -> Token {
	return p.tokens[min(p.index, len(p.tokens) - 1)]
}

@(private = "file")
peek_token :: proc(p: ^Parser, offset: int) -> Token {
	return p.tokens[min(p.index + offset, len(p.tokens) - 1)]
}

@(private = "file")
at :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	return current(p).kind == kind
}

@(private = "file")
advance :: proc(p: ^Parser) -> Token {
	t := current(p)
	if p.index < len(p.tokens) - 1 {
		p.index += 1
	}
	p.last = t
	return t
}

@(private = "file")
allow :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	if at(p, kind) {
		advance(p)
		return true
	}
	return false
}

@(private = "file")
span_of :: proc(p: ^Parser, t: Token) -> Span {
	return Span{file = p.file, lo = t.lo, hi = t.hi}
}

// A span from `start` through whatever was last consumed.
@(private = "file")
span_to_here :: proc(p: ^Parser, start: Token) -> Span {
	return Span{file = p.file, lo = start.lo, hi = max(p.last.hi, start.hi)}
}

@(private = "file")
text_of :: proc(p: ^Parser, t: Token) -> string {
	return p.c.sources[p.file].text[t.lo:t.hi]
}

// The lexer hands back contextual keywords as ordinary identifiers, so the
// parser matches them on text plus position.
@(private = "file")
is_contextual :: proc(p: ^Parser, word: string) -> bool {
	return at(p, .Ident) && text_of(p, current(p)) == word
}

@(private = "file")
name_of :: proc(p: ^Parser, t: Token) -> Name {
	text := text_of(p, t)
	return Name{text = text, span = span_of(p, t), id = intern_identifier(p.c, text)}
}

// Every parser diagnostic goes through here so panic mode can silence the
// unwind without silencing the phase.
@(private = "file")
parse_error :: proc(
	p: ^Parser,
	span: Span,
	code: string,
	label: string,
	format: string,
	args: ..any,
) {
	if p.suppress {
		return
	}
	error_labelf(p.c, span, code, label, format, ..args)
}

// A member name: a field, an enum member, or the name after `.`. design.md
// spells one of them `type` — `field.type` on a reflection descriptor, and
// `Member_Info.type` in the runtime metadata — and a name in this position can
// never start a type expression, so the keyword is accepted here and nowhere
// else.
@(private = "file")
expect_member_name :: proc(p: ^Parser, code: string, what: string) -> (Token, bool) {
	if at(p, .Type) {
		return advance(p), true
	}
	return expect(p, .Ident, code, what)
}

expect :: proc(p: ^Parser, kind: Token_Kind, code: string, what: string) -> (Token, bool) {
	if at(p, kind) {
		return advance(p), true
	}
	t := current(p)
	parse_error(p, span_of(p, t), code, fmt_found(p, t), "expected %s", what)
	return t, false // NOT consumed: never use this token to end a span
}

@(private = "file")
fmt_found :: proc(p: ^Parser, t: Token) -> string {
	if t.kind == .EOF {
		return "end of file"
	}
	// `error_labelf` clones the label into diagnostic-owned storage. Build this
	// transient spelling in the temporary arena so there is no second owner to
	// release after the call.
	return concat_temp("found `", text_of(p, t), "`")
}

@(private = "file")
concat_temp :: proc(parts: ..string) -> string {
	total := 0
	for s in parts {
		total += len(s)
	}
	buf := make([]u8, total, context.temp_allocator)
	i := 0
	for s in parts {
		copy(buf[i:], s)
		i += len(s)
	}
	return string(buf)
}

// One diagnostic per file, then panic mode: the 256 frames unwinding behind
// this would otherwise each report their own missing delimiter.
@(private = "file")
depth_exceeded :: proc(p: ^Parser) -> Expr {
	t := current(p)
	if !p.depth_reported {
		p.depth_reported = true
		errorf(
			p.c,
			span_of(p, t),
			"L0222",
			"expression nests more than %d levels deep",
			MAX_NEST,
		)
	}
	p.suppress = true
	return error_expr(p, span_of(p, t))
}

@(private = "file")
sync_to_item :: proc(p: ^Parser) {
	sync_to_boundary(p, .Item, true)
}

// A `,` and the list's own closing delimiter bound one element, so a malformed
// element is resynchronised here instead of abandoning the list. Breaking out
// early leaves the close for an enclosing construct to trip over, which is how
// one bad element used to swallow the enclosing block's `}`. Returns true when a
// `,` was consumed and another element follows.
@(private = "file")
resync_list :: proc(p: ^Parser, close: Token_Kind) -> bool {
	paren, bracket, brace := 0, 0, 0
	for !at(p, .EOF) {
		kind := current(p).kind
		if paren == 0 && bracket == 0 && brace == 0 {
			if kind == close || kind == .Semicolon || kind == .Rbrace {
				return false // the close, or a boundary an enclosing construct owns
			}
			if kind == .Comma {
				advance(p)
				return true
			}
		}
		#partial switch kind {
		case .Lparen:
			paren += 1
		case .Rparen:
			if paren == 0 {
				return false
			}
			paren -= 1
		case .Lbracket:
			bracket += 1
		case .Rbracket:
			if bracket == 0 {
				return false
			}
			bracket -= 1
		case .Lbrace:
			brace += 1
		case .Rbrace:
			brace -= 1
		}
		advance(p)
	}
	return false
}

@(private = "file")
sync_to_statement :: proc(p: ^Parser, stop_after_brace := false) {
	sync_to_boundary(p, .Statement, stop_after_brace)
}

@(private = "file")
Sync_Context :: enum {
	Item,
	Statement,
}

// Recovery observes delimiter nesting. A semicolon inside a for header or a
// closing brace inside a composite literal is not a boundary for the outer
// construct. An unmatched `}` is left for the enclosing block parser.
@(private = "file")
sync_to_boundary :: proc(p: ^Parser, mode: Sync_Context, stop_after_brace: bool) {
	paren_depth, bracket_depth, brace_depth := 0, 0, 0
	consumed := false
	for !at(p, .EOF) {
		t := current(p)
		at_outer := paren_depth == 0 && bracket_depth == 0 && brace_depth == 0
		if at_outer {
			if t.kind == .Semicolon {
				advance(p)
				return
			}
			if t.kind == .Rbrace {
				return
			}
			if mode == .Item && consumed {
				#partial switch t.kind {
				case .Import, .Foreign, .Impl, .When, .Package:
					return
				}
			}
		}

		#partial switch t.kind {
		case .Lparen:
			paren_depth += 1
		case .Rparen:
			paren_depth = max(paren_depth - 1, 0)
		case .Lbracket:
			bracket_depth += 1
		case .Rbracket:
			bracket_depth = max(bracket_depth - 1, 0)
		case .Lbrace:
			brace_depth += 1
		case .Rbrace:
			if brace_depth > 0 {
				brace_depth -= 1
			}
		}
		advance(p)
		consumed = true
		if stop_after_brace &&
		   t.kind == .Rbrace &&
		   paren_depth == 0 &&
		   bracket_depth == 0 &&
		   brace_depth == 0 {
			return
		}
	}
}

// `Attribute_Group+`. The groups are flattened: which attribute is valid where
// is a semantic rule (grammar.md "Attributes"), and nothing downstream needs to
// know which `@(...)` an attribute came from.
@(private = "file")
parse_attributes :: proc(p: ^Parser) -> []Attribute {
	if !at(p, .At) {
		return nil
	}

	list := make([dynamic]Attribute, 0, 0, p.allocator)
	for at(p, .At) {
		advance(p)
		expect(p, .Lparen, "L0249", "`(` to open the attribute group")
		if at(p, .Rparen) {
			parse_error(
				p,
				span_of(p, current(p)),
				"L0249",
				"attribute group is empty",
				"expected an attribute",
			)
		}
		for !at(p, .Rparen) && !at(p, .EOF) {
			start := current(p)
			attribute: Attribute

			path := make([dynamic]Name, 0, 0, p.allocator)
			for {
				name, ok := expect(p, .Ident, "L0249", "an attribute name")
				if !ok {
					break
				}
				append(&path, name_of(p, name))
				if !allow(p, .Period) {
					break
				}
			}
			attribute.path = path[:]
			if allow(p, .Assign) {
				attribute.value = parse_expr(p)
			}
			attribute.span = span_to_here(p, start)
			append(&list, attribute)

			if !allow(p, .Comma) {
				break
			}
			if at(p, .Rparen) {
				parse_error(
					p,
					span_of(p, current(p)),
					"L0249",
					"trailing comma",
					"an attribute group cannot end with a comma",
				)
				break
			}
		}
		expect(p, .Rparen, "L0249", "`)` to close the attribute group")
	}
	return list[:]
}

@(private = "file")
parse_package_clause :: proc(p: ^Parser, f: ^File) {
	f.attributes = parse_attributes(p)

	if _, ok := expect(p, .Package, "L0202", "a `package` clause"); !ok {
		return
	}
	name, name_ok := expect(p, .Ident, "L0203", "a package name")
	if name_ok {
		f.package_name = text_of(p, name)
		f.package_span = span_of(p, name)
	}
	expect(p, .Semicolon, "L0204", "`;` after the package clause")
}

@(private = "file")
parse_top_level_item :: proc(p: ^Parser) -> (Item, bool) {
	p.suppress = false
	if allow(p, .Semicolon) {
		return nil, false // empty item
	}

	start := current(p)
	attributes := parse_attributes(p)

	t := current(p)
	#partial switch t.kind {
	case .Import:
		return parse_import(p, attributes, start), true
	case .Foreign:
		return parse_foreign(p, attributes, start), true
	case .Impl:
		return parse_impl(p, attributes, start), true
	case .When:
		return parse_top_level_when(p, attributes, start), true
	case .Error:
		advance(p)
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	case .Package:
		errorf(p.c, span_of(p, t), "L0205", "a file has exactly one `package` clause, at the top")
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	}

	// design.md: `static_assert` is available at file scope so a type author can
	// require an interface beside the type. It is the ordinary predeclared
	// built-in recognized contextually here, not a new keyword or directive, and
	// no other expression statement is admitted at item position.
	if is_contextual(p, "static_assert") && peek_token(p, 1).kind == .Lparen {
		return parse_top_level_static_assert(p, attributes, start), true
	}

	if !starts_declaration(p) {
		parse_error(p, span_of(p, t), "L0206", fmt_found(p, t), "expected a declaration")
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	}
	decl, ok := parse_declaration(p, attributes, start)
	if !ok {
		return error_item(p, span_of(p, t)), true
	}
	return decl, true
}

// `Top_Level_Static_Assert`. The call is parsed as an ordinary expression so
// that its callee, arity, and condition are the checker's business, exactly as
// in statement position.
@(private = "file")
parse_top_level_static_assert :: proc(p: ^Parser, attributes: []Attribute, start: Token) -> Item {
	item := ast_new(p, Item_Static_Assert)
	item.attributes = attributes
	item.call = parse_expr(p)
	// `static_assert` is contextual only for this one exact call form. Parsing an
	// expression first gives its arguments the ordinary expression grammar, but
	// no selector, second call, operator, range, or conditional may wrap it and
	// become a different kind of file-scope expression statement.
	call, is_call := item.call.(^Expr_Call)
	exact_call := false
	if is_call {
		if ident, is_ident := call.callee.(^Expr_Ident); is_ident {
			exact_call = ident.name == "static_assert"
		}
	}
	if !exact_call && !expr_has_error(item.call) {
		parse_error(
			p,
			expr_span(item.call),
			"L0250",
			"invalid file-scope assertion",
			"a file-scope assertion is exactly `static_assert(...);`",
		)
	}
	_, terminated := expect(p, .Semicolon, "L0250", "`;` after the assertion")
	item.has_error = item.call == nil || !exact_call || !terminated
	item.span = span_to_here(p, start)
	return item
}

// `Import_Decl`
@(private = "file")
parse_import :: proc(p: ^Parser, attributes: []Attribute, start: Token) -> Item {
	advance(p) // `import`

	item := ast_new(p, Item_Import)
	item.attributes = attributes
	if at(p, .Ident) {
		item.alias = name_of(p, advance(p))
	}
	path, has_path := expect(p, .String, "L0250", "the import path, as a string literal")
	if has_path {
		item.path = text_of(p, path)
	}
	_, terminated := expect(p, .Semicolon, "L0250", "`;` after the import")

	item.has_error = !has_path || !terminated
	item.span = span_to_here(p, start)
	return item
}

// `Foreign_Import_Decl` and `Foreign_Block`, told apart by the token after
// `foreign`.
@(private = "file")
parse_foreign :: proc(p: ^Parser, attributes: []Attribute, start: Token) -> Item {
	advance(p) // `foreign`

	if allow(p, .Import) {
		item := ast_new(p, Item_Foreign_Import)
		item.attributes = attributes
		name, has_name := expect(p, .Ident, "L0250", "a name for the foreign library")
		if has_name {
			item.name = name_of(p, name)
		}
		path, has_path := expect(p, .String, "L0250", "the library path, as a string literal")
		if has_path {
			// The token text keeps its quotes; a library path has no escapes worth
			// decoding, so slicing them off is the whole unquote (m7-plan step 4).
			raw := text_of(p, path)
			item.path = len(raw) >= 2 ? raw[1:len(raw) - 1] : raw
		}
		_, terminated := expect(p, .Semicolon, "L0250", "`;` after the foreign import")

		item.has_error = !has_name || !has_path || !terminated
		item.span = span_to_here(p, start)
		return item
	}

	item := ast_new(p, Item_Foreign_Block)
	item.attributes = attributes
	name, has_name := expect(p, .Ident, "L0251", "the foreign library's name")
	if has_name {
		item.library = name_of(p, name)
	}
	_, opened := expect(p, .Lbrace, "L0251", "`{` to open the foreign block")
	item.members = parse_member_list(p, .Foreign)
	_, closed := expect(p, .Rbrace, "L0251", "`}` to close the foreign block")

	item.has_error = !has_name || !opened || !closed
	item.span = span_to_here(p, start)
	return item
}

// `Impl_Block`. Whether the block is inherent or an extension is not written:
// `declare_impl_block` derives it from the subject's declaring package.
@(private = "file")
parse_impl :: proc(p: ^Parser, attributes: []Attribute, start: Token) -> Item {
	advance(p) // `impl`

	item := ast_new(p, Item_Impl)
	item.attributes = attributes
	item.type = parse_type(p)
	_, opened := expect(p, .Lbrace, "L0252", "`{` to open the block")
	item.members = parse_member_list(p, .Impl)
	_, closed := expect(p, .Rbrace, "L0252", "`}` to close the block")

	item.has_error = !opened || !closed || expr_has_error(item.type)
	item.span = span_to_here(p, start)
	return item
}

@(private = "file")
Member_Context :: enum {
	Foreign,
	Impl,
}

// `Foreign_Decl` and `Impl_Member` are both declarations, `;`, and — inside an
// `impl` or `extend` — a delegation. grammar.md spells `Foreign_Decl` with an
// unconditional trailing `;`, which would contradict the brace-bodied constant
// rule; parsing it as an ordinary declaration keeps one rule instead. "A
// foreign procedure has no body" becomes a semantic check, since valid code
// cannot tell the difference.
@(private = "file")
parse_member_list :: proc(p: ^Parser, kind: Member_Context) -> []Item {
	members := make([dynamic]Item, 0, 0, p.allocator)
	for !at(p, .Rbrace) && !at(p, .EOF) {
		before := p.index
		if allow(p, .Semicolon) {
			continue // empty member
		}

		start := current(p)
		attributes := parse_attributes(p)

		switch {
		// `delegate` is the contextual keyword only when followed by `(`; otherwise
		// it is an ordinary identifier that may begin a declaration.
		case kind == .Impl && is_contextual(p, "delegate") && peek_token(p, 1).kind == .Lparen:
			append(&members, parse_delegate(p, start))
		case starts_declaration(p):
			if d, ok := parse_declaration(p, attributes, start); ok {
				append(&members, d)
			} else {
				append(&members, error_item(p, span_to_here(p, start)))
			}
		case:
			t := current(p)
			parse_error(p, span_of(p, t), "L0206", fmt_found(p, t), "expected a declaration")
			sync_to_statement(p, true)
			append(&members, error_item(p, span_of(p, t)))
		}

		if p.index == before {
			advance(p)
		}
	}
	return members[:]
}

@(private = "file")
parse_delegate :: proc(p: ^Parser, start: Token) -> Item {
	advance(p) // `delegate`

	item := ast_new(p, Item_Delegate)
	_, opened := expect(p, .Lparen, "L0243", "`(` before the delegated operators")
	symbols := make([dynamic]string, 0, 0, p.allocator)
	for !at(p, .Rparen) && !at(p, .EOF) {
		symbol, _ := parse_operator_symbol(p)
		append(&symbols, symbol)
		if !allow(p, .Comma) {
			break
		}
	}
	_, closed := expect(p, .Rparen, "L0243", "`)` after the delegated operators")
	_, terminated := expect(p, .Semicolon, "L0243", "`;` after the delegation")

	item.symbols = symbols[:]
	item.has_error = !opened || !closed || !terminated
	item.span = span_to_here(p, start)
	return item
}

// `Top_Level_When`, whose branches are blocks of top-level items.
@(private = "file")
parse_top_level_when :: proc(p: ^Parser, attributes: []Attribute, start: Token) -> Item {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > MAX_NEST {
		depth_exceeded(p)
		t := current(p)
		sync_to_item(p)
		return error_item(p, span_of(p, t))
	}

	advance(p) // `when`

	item := ast_new(p, Item_When)
	item.attributes = attributes
	opened := open_header(p, "`(` to open the `when` header")
	item.cond = parse_expr(p)
	closed := close_header(p, opened, "`)` to close the `when` header")

	then_start := current(p)
	item.then = parse_top_level_block(p, parse_attributes(p), then_start)

	if allow(p, .Else) {
		else_start := current(p)
		else_attributes := parse_attributes(p)
		if at(p, .When) {
			item.otherwise = parse_top_level_when(p, else_attributes, else_start)
		} else {
			item.otherwise = parse_top_level_block(p, else_attributes, else_start)
		}
	}

	item.has_error = !opened || !closed || expr_has_error(item.cond)
	item.span = span_to_here(p, start)
	return item
}

@(private = "file")
parse_top_level_block :: proc(
	p: ^Parser,
	attributes: []Attribute,
	start: Token,
) -> ^Item_Block {
	block := ast_new(p, Item_Block)
	block.attributes = attributes
	_, opened := expect(p, .Lbrace, "L0252", "`{` to open the block")
	block.items = parse_items(p, stop_at_rbrace = true)
	_, closed := expect(p, .Rbrace, "L0252", "`}` to close the block")

	block.has_error = !opened || !closed
	block.span = span_to_here(p, start)
	return block
}

// grammar.md's bounded scan: a comma-separated identifier list followed by `:`
// is a declaration. Everything else at this position is a statement.
@(private = "file")
starts_declaration :: proc(p: ^Parser) -> bool {
	return scans_name_list_colon(p, 0)
}

// `Ident ("," Ident)* ":"` from `offset`. The bounded scan a declaration, a
// result item, and an anonymous record field group all ask for.
scans_name_list_colon :: proc(p: ^Parser, offset: int) -> bool {
	offset := offset
	for {
		if peek_token(p, offset).kind != .Ident {
			return false
		}
		offset += 1
		#partial switch peek_token(p, offset).kind {
		case .Comma:
			offset += 1
		case .Colon:
			return true
		case:
			return false
		}
	}
}

// A parenthesised type is a record iff its first group is labelled. `(T)` in
// expression position stays grouping, so this looks one field group past the
// `(` and no further.
starts_anon_record_type :: proc(p: ^Parser) -> bool {
	return at(p, .Lparen) && scans_name_list_colon(p, 1)
}

@(private = "file")
parse_declaration :: proc(p: ^Parser, attributes: []Attribute, start: Token) -> (^Decl, bool) {
	d := ast_new(p, Decl)
	d.attributes = attributes

	names := make([dynamic]Name, 0, 0, p.allocator)
	for {
		name, ok := expect(p, .Ident, "L0207", "a name")
		if !ok {
			sync_to_item(p)
			return nil, false
		}
		append(&names, name_of(p, name))
		if !allow(p, .Comma) {
			break
		}
	}
	d.names = names[:]

	if _, ok := expect(p, .Colon, "L0208", "`:` after the declared names"); !ok {
		sync_to_item(p)
		return nil, false
	}

	// `::` and `:=` are token pairs, so the second `:` or the `=` is simply the
	// next token here.
	switch {
	case allow(p, .Colon):
		return finish_constant(p, d, start)
	case allow(p, .Assign):
		// `x := e;`
		return finish_variable(p, d, start)
	}

	// `Declared_Type = Storage_Modifiers Type ("via" Unary_Expression)?`, and
	// the modifiers are also legal with the type left inferred.
	parse_storage_modifiers(p, d)
	if allow(p, .Assign) {
		return finish_variable(p, d, start)
	}

	d.declared_type = parse_type(p)
	if expr_has_error(d.declared_type) {
		sync_to_item(p)
		return nil, false
	}
	if at(p, .Via) {
		advance(p)
		d.via = parse_unary(p) // grammar.md: exactly one unary expression
	}

	switch {
	case allow(p, .Colon):
		return finish_constant(p, d, start)
	case allow(p, .Assign):
		return finish_variable(p, d, start)
	}

	// `x: int;` — the zero value.
	expect(p, .Semicolon, "L0209", "`;` after the declaration")
	d.kind = .Var
	d.span = span_to_here(p, start)
	return d, true
}

// grammar.md: after the first `:`, `static` and `thread_local` are storage
// modifiers only when followed by another modifier, a type-start token, or `=`.
// Otherwise they are ordinary type names. Duration is the only axis, so the
// loop runs at most twice — once for the modifier, once to reject a repeat.
@(private = "file")
parse_storage_modifiers :: proc(p: ^Parser, d: ^Decl) {
	for at(p, .Ident) {
		duration := Duration.None
		switch text_of(p, current(p)) {
		case "static":
			duration = .Static
		case "thread_local":
			duration = .Thread_Local
		case:
			return
		}

		next := peek_token(p, 1).kind
		if next != .Assign && next != .Ident && !starts_type(next) {
			return // a type named `static`, not a modifier
		}

		word := advance(p)
		if d.duration != .None {
			parse_error(
				p,
				span_of(p, word),
				"L0232",
				"already given",
				"repeated storage modifier",
			)
		} else {
			d.duration = duration
		}
	}
}

// `Constant_Decl`, after its second `:`.
@(private = "file")
finish_constant :: proc(p: ^Parser, d: ^Decl, start: Token) -> (^Decl, bool) {
	d.kind = .Const

	// `Constant_Decl` binds one name and has no `Storage_Modifiers` or `via`.
	if len(d.names) > 1 {
		parse_error(
			p,
			d.names[1].span,
			"L0233",
			"only the first name is bound",
			"a constant declares exactly one name",
		)
	}
	if d.duration != .None || d.via != nil {
		parse_error(
			p,
			span_of(p, start),
			"L0234",
			"not allowed on a constant",
			"storage modifiers and `via` belong to variables",
		)
	}

	value := parse_constant_value(p)
	values := make([]Expr, 1, p.allocator)
	values[0] = value
	d.values = values

	// A malformed value is not also asked for its `;` — that second diagnostic
	// describes nothing new. Resynchronise and keep the node instead.
	if expr_has_error(value) {
		sync_to_item(p)
		d.has_error = true
		d.span = span_to_here(p, start)
		return d, true
	}

	// A brace-bodied value ends at its own `}`; everything else needs `;`.
	terminated := true
	if !ends_with_brace(value) {
		_, terminated = expect(p, .Semicolon, "L0209", "`;` after the declaration")
	}
	d.span = span_to_here(p, start)
	d.has_error = !terminated
	return d, true
}

// `Variable_Initializer_List`, after the `=`.
@(private = "file")
finish_variable :: proc(p: ^Parser, d: ^Decl, start: Token) -> (^Decl, bool) {
	d.kind = .Var

	values := make([dynamic]Expr, 0, 0, p.allocator)
	invalid := false
	for {
		if at(p, .Uninit) {
			marker := advance(p)
			// `---` is not an expression, so the inferred `x := ...` spelling
			// cannot use it.
			if d.declared_type == nil {
				parse_error(
					p,
					span_of(p, marker),
					"L0235",
					"no declared type",
					"`---` needs a written type, as in `x: T = ---;`",
				)
				invalid = true
			}
			append(&values, nil)
		} else {
			value := parse_expr(p)
			invalid = expr_has_error(value) || invalid
			append(&values, value)
		}
		if !allow(p, .Comma) {
			break
		}
	}
	d.values = values[:]
	if invalid {
		// As above: a malformed initialiser is not also asked for its `;`.
		sync_to_statement(p)
		d.has_error = true
		d.span = span_to_here(p, start)
		return d, true
	}

	_, terminated := expect(p, .Semicolon, "L0209", "`;` after the declaration")
	d.span = span_to_here(p, start)
	d.has_error = !terminated
	return d, true
}

// `Constant_Initializer`.
@(private = "file")
parse_constant_value :: proc(p: ^Parser) -> Expr {
	#partial switch current(p).kind {
	case .Struct, .Union, .Enum, .Interface, .Proc, .Move_Only:
		return parse_type(p) // the braced forms all live in the type grammar
	case .Operator:
		return parse_operator(p)
	case .Hook:
		return parse_hook(p)
	}
	// Sets `type_value` (see the field doc) so `My_Int :: int` parses as a value.
	p.type_value = true
	defer p.type_value = false
	return parse_expr(p)
}

// grammar.md's brace-bodied constant rule: a value terminated by its own outer
// `}` is not followed by `;`. A trailing composite literal is not one of them.
@(private = "file")
ends_with_brace :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Type_Record, ^Type_Enum, ^Type_Interface, ^Expr_Proc_Group:
		return true
	case ^Expr_Proc:
		return v.body != nil
	case ^Expr_Operator:
		return ends_with_brace(v.value)
	}
	return false
}

@(private = "file")
parse_block :: proc(p: ^Parser) -> (^Block, bool) {
	start := current(p)
	attributes := parse_attributes(p)
	_, ok := expect(p, .Lbrace, "L0213", "`{` to open a block")
	if !ok {
		return nil, false
	}

	stmts := make([dynamic]Stmt, 0, 0, p.allocator)
	for !at(p, .EOF) && !at(p, .Rbrace) {
		before := p.index
		if s, got := parse_statement(p); got {
			append(&stmts, s)
		}
		if p.index == before {
			advance(p)
		}
	}
	_, closed := expect(p, .Rbrace, "L0214", "`}` to close the block")

	b := ast_new(p, Block)
	b.span = span_to_here(p, start)
	b.attributes = attributes
	b.stmts = stmts[:]
	b.has_error = !closed
	return b, true
}

@(private = "file")
parse_statement :: proc(p: ^Parser) -> (Stmt, bool) {
	p.suppress = false
	p.depth += 1
	defer p.depth -= 1
	if p.depth > MAX_NEST {
		depth_exceeded(p)
		return error_stmt(p, span_of(p, current(p))), true
	}

	start := current(p)
	attributes := parse_attributes(p)

	t := current(p)
	if len(attributes) > 0 {
		// grammar.md attaches statement attributes to a block, `when`, either
		// switch, a declaration, or a simple statement — and nowhere else.
		#partial switch t.kind {
		case .If, .For, .Foreach, .Defer, .Return, .Break, .Continue:
			parse_error(
				p,
				attributes[0].span,
				"L0249",
				"not attachable here",
				"attributes attach to a block, `when`, `switch`, a declaration or a simple statement",
			)
		}
	}

	#partial switch t.kind {
	case .Semicolon:
		advance(p)
		return nil, false // empty statement
	case .Lbrace:
		// `{` at statement position opens a block, which is why a composite
		// literal with no type cannot begin an expression statement.
		if b, ok := parse_block(p); ok {
			return with_attributes(b, attributes), true
		}
		return nil, false
	case .If:
		return with_attributes(parse_if(p), attributes), true
	case .For:
		return with_attributes(parse_for(p), attributes), true
	case .Foreach:
		return with_attributes(parse_foreach(p), attributes), true
	case .Switch:
		return with_attributes(parse_switch(p), attributes), true
	case .When:
		return with_attributes(parse_when(p), attributes), true
	case .Defer:
		return with_attributes(parse_defer(p), attributes), true
	case .Return:
		return with_attributes(parse_return(p), attributes), true
	case .Break, .Continue:
		return with_attributes(parse_branch(p), attributes), true
	case .Error:
		advance(p)
		sync_to_statement(p)
		return error_stmt(p, span_of(p, t)), true
	}

	if starts_declaration(p) {
		if d, ok := parse_declaration(p, attributes, start); ok {
			return d, true
		}
		return error_stmt(p, span_of(p, t)), true
	}

	simple := parse_simple_statement(p)
	if stmt_has_error(simple) || at(p, .Error) {
		sync_to_statement(p)
		return error_stmt(p, stmt_span(simple)), true
	}
	expect(p, .Semicolon, "L0216", "`;` after the statement")
	stmt_base(simple).span = span_to_here(p, start)
	return with_attributes(simple, attributes), true
}

// Attributes precede their statement, so they also extend its span.
@(private = "file")
with_attributes :: proc(s: Stmt, attributes: []Attribute) -> Stmt {
	base := stmt_base(s)
	if base == nil || len(attributes) == 0 {
		return s
	}
	base.attributes = attributes
	base.span.lo = attributes[0].span.lo
	return s
}

// `Simple_Statement = Assignment | Expression_List`, with no trailing `;` —
// the header forms need it without one.
@(private = "file")
parse_simple_statement :: proc(p: ^Parser) -> Stmt {
	start := current(p)
	lhs := parse_expression_list(p)

	if at(p, .Assign) || is_compound_assign(current(p).kind) {
		op := advance(p)
		// `Expression_List "=" Expression_List`, but the compound form takes
		// exactly one expression on each side.
		rhs: []Expr
		if op.kind == .Assign {
			rhs = parse_expression_list(p)
		} else {
			single := make([]Expr, 1, p.allocator)
			single[0] = parse_expr(p)
			rhs = single
		}

		s := new_stmt(p, Stmt_Assign, start)
		s.op = op.kind
		s.op_span = span_of(p, op)
		s.lhs = lhs
		s.rhs = rhs
		for e in lhs {
			s.has_error = s.has_error || expr_has_error(e)
		}
		for e in rhs {
			s.has_error = s.has_error || expr_has_error(e)
		}
		return s
	}

	s := new_stmt(p, Stmt_Expr, start)
	s.exprs = lhs
	for e in lhs {
		s.has_error = s.has_error || expr_has_error(e)
	}
	return s
}

@(private = "file")
parse_expression_list :: proc(p: ^Parser) -> []Expr {
	exprs := make([dynamic]Expr, 0, 0, p.allocator)
	for {
		append(&exprs, parse_expr(p))
		if !allow(p, .Comma) {
			break
		}
	}
	return exprs[:]
}

// A control-flow header's subject is an `Expression`; an assignment or a list
// in that position is a syntax error.
@(private = "file")
expr_of_simple :: proc(p: ^Parser, s: Stmt) -> Expr {
	if simple, ok := s.(^Stmt_Expr); ok && len(simple.exprs) == 1 {
		return simple.exprs[0]
	}
	parse_error(
		p,
		stmt_span(s),
		"L0246",
		"not an expression",
		"a control-flow header takes one expression",
	)
	return error_expr(p, stmt_span(s))
}

// `(` opens every control-flow header. Without it the header expression abuts
// the body brace exactly as a `where` clause does, so the same flag stops
// `switch value { ... }` from taking the body for a composite literal — which
// swallows the enclosing block's `}` and spills recovery out to file scope.
@(private = "file")
open_header :: proc(p: ^Parser, message: string) -> bool {
	if _, ok := expect(p, .Lparen, "L0245", message); ok {
		return true
	}
	p.no_composite = true
	return false
}

// One missing parenthesis is one diagnostic: with no `(` consumed there is no
// `)` to ask for.
@(private = "file")
close_header :: proc(p: ^Parser, opened: bool, message: string) -> bool {
	p.no_composite = false
	if !opened {
		return false
	}
	_, ok := expect(p, .Rparen, "L0245", message)
	return ok
}

@(private = "file")
parse_if :: proc(p: ^Parser) -> Stmt {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > MAX_NEST {
		depth_exceeded(p)
		t := current(p)
		sync_to_statement(p, true)
		return error_stmt(p, span_of(p, t))
	}

	start := advance(p) // `if`
	opened := open_header(p, "`(` to open the `if` header")

	// `Init_Statement?` then the condition. A `Variable_Decl` carries its own
	// `;`; a `Simple_Statement` is the init only when a `;` follows it.
	init: Stmt
	cond: Expr
	if starts_declaration(p) {
		if d, ok := parse_declaration(p, nil, current(p)); ok {
			init = d
		}
	} else {
		first := parse_simple_statement(p)
		if allow(p, .Semicolon) {
			init = first
		} else {
			cond = expr_of_simple(p, first)
		}
	}
	if cond == nil {
		cond = parse_expr(p)
	}
	closed := close_header(p, opened, "`)` to close the `if` header")

	then, body_ok := parse_block(p)
	otherwise: Stmt
	if allow(p, .Else) {
		if at(p, .If) {
			otherwise = parse_if(p)
		} else if block, ok := parse_block(p); ok {
			otherwise = block
		}
	}

	s := new_stmt(p, Stmt_If, start)
	s.init = init
	s.cond = cond
	s.then = then
	s.otherwise = otherwise
	s.has_error = !opened || !closed || !body_ok || expr_has_error(cond)
	return s
}

@(private = "file")
parse_when :: proc(p: ^Parser) -> Stmt {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > MAX_NEST {
		depth_exceeded(p)
		t := current(p)
		sync_to_statement(p, true)
		return error_stmt(p, span_of(p, t))
	}

	start := advance(p) // `when`
	opened := open_header(p, "`(` to open the `when` header")
	cond := parse_expr(p)
	closed := close_header(p, opened, "`)` to close the `when` header")

	then, body_ok := parse_block(p)
	otherwise: Stmt
	if allow(p, .Else) {
		else_attributes := parse_attributes(p)
		if at(p, .When) {
			otherwise = with_attributes(parse_when(p), else_attributes)
		} else if block, ok := parse_block(p); ok {
			otherwise = with_attributes(block, else_attributes)
		}
	}

	s := new_stmt(p, Stmt_When, start)
	s.cond = cond
	s.then = then
	s.otherwise = otherwise
	s.has_error = !opened || !closed || !body_ok || expr_has_error(cond)
	return s
}

// `For_Header` is either the three-part form or a bare condition; the first `;`
// tells them apart.
@(private = "file")
parse_for :: proc(p: ^Parser) -> Stmt {
	start := advance(p) // `for`
	opened := open_header(p, "`(` to open the `for` header")

	init: Stmt
	cond: Expr
	post: Stmt
	condition_only := false

	switch {
	case allow(p, .Semicolon):
	// `for (; cond; post)` — an empty init
	case starts_declaration(p):
		if d, ok := parse_declaration(p, nil, current(p)); ok {
			init = d
		}
	case at(p, .Rparen):
		t := current(p)
		parse_error(p, span_of(p, t), "L0245", fmt_found(p, t), "a `for` header cannot be empty; `for (;;)` loops forever")
	case:
		first := parse_simple_statement(p)
		if allow(p, .Semicolon) {
			init = first
		} else {
			condition_only = true
			cond = expr_of_simple(p, first)
		}
	}

	if !condition_only {
		if !at(p, .Semicolon) {
			cond = parse_expr(p)
		}
		expect(p, .Semicolon, "L0245", "`;` after the loop condition")
		if !at(p, .Rparen) {
			post = parse_simple_statement(p)
		}
	}
	closed := close_header(p, opened, "`)` to close the `for` header")

	body, body_ok := parse_block(p)

	s := new_stmt(p, Stmt_For, start)
	s.init = init
	s.cond = cond
	s.post = post
	s.body = body
	s.condition_only = condition_only
	s.has_error = !opened || !closed || !body_ok || expr_has_error(cond)
	return s
}

@(private = "file")
parse_foreach :: proc(p: ^Parser) -> Stmt {
	start := advance(p) // `foreach`
	opened := open_header(p, "`(` to open the `foreach` header")

	bindings := make([dynamic]Foreach_Binding, 0, 0, p.allocator)
	bad_bindings := false
	for {
		binding: Foreach_Binding
		binding.is_static = allow(p, .Dollar)
		binding.is_ref = allow(p, .Amp)
		name, ok := expect(p, .Ident, "L0247", "a binding name")
		if ok {
			binding.name = name_of(p, name)
		} else {
			bad_bindings = true
		}
		append(&bindings, binding)
		if !allow(p, .Comma) {
			break
		}
	}
	// A binding list has any length: it names the fields of the element the
	// iterable yields, so its arity is a property of that element's type
	// (design.md "Element bindings") rather than a syntactic limit.

	_, has_in := expect(p, .In, "L0247", "`in` and the iterable")
	iterable := parse_expr(p)
	closed := close_header(p, opened, "`)` to close the `foreach` header")

	body, body_ok := parse_block(p)

	s := new_stmt(p, Stmt_Foreach, start)
	s.bindings = bindings[:]
	s.iterable = iterable
	s.body = body
	s.has_error =
		!opened || !closed || !has_in || !body_ok || bad_bindings || expr_has_error(iterable)
	return s
}

@(private = "file")
parse_defer :: proc(p: ^Parser) -> Stmt {
	start := advance(p) // `defer`
	inner, got := parse_statement(p)

	s := new_stmt(p, Stmt_Defer, start)
	if got {
		s.stmt = inner
	}
	s.has_error = got && stmt_has_error(inner)
	return s
}

@(private = "file")
parse_return :: proc(p: ^Parser) -> Stmt {
	start := advance(p) // `return`

	bad := false
	value: Return_Value
	has_value := false
	// A missing `;` is one diagnostic, so a `}` here means "no value"; asking for
	// an expression first would describe the same typo twice.
	if !at(p, .Semicolon) && !at(p, .Rbrace) {
		value_start := current(p)
		value.is_inout = allow(p, .Inout)
		value.expr = parse_expr(p)
		value.span = span_to_here(p, value_start)
		bad = expr_has_error(value.expr)
		has_value = true
		// design.md: a procedure returns at most one value. A record result is
		// written as one record value, not as a comma-separated list.
		if at(p, .Comma) {
			parse_error(
				p, span_of(p, current(p)), "L0215", "found `,`",
				"a `return` carries at most one value; write a record literal to return several",
			)
			bad = true
			for allow(p, .Comma) {
				parse_expr(p)
			}
		}
	}
	_, terminated := expect(p, .Semicolon, "L0215", "`;` after `return`")

	s := new_stmt(p, Stmt_Return, start)
	if has_value {
		s.value = new(Return_Value, p.allocator)
		s.value^ = value
	}
	s.has_error = bad || !terminated
	return s
}

@(private = "file")
parse_branch :: proc(p: ^Parser) -> Stmt {
	keyword := advance(p) // `break` or `continue`
	_, terminated := expect(p, .Semicolon, "L0215", "`;` after the branch")

	s := new_stmt(p, Stmt_Branch, keyword)
	s.kind = keyword.kind
	s.has_error = !terminated
	return s
}

// `switch (name in expr)` is a type switch, and the decision point is *after*
// the optional `Init_Statement` — a position only reached once that statement
// is parsed. A value switch over membership is written `switch ((x in y))`.
@(private = "file")
parse_switch :: proc(p: ^Parser) -> Stmt {
	start := advance(p) // `switch`
	opened := open_header(p, "`(` to open the `switch` header")

	init: Stmt
	subject: Expr
	kind := Switch_Kind.Value
	binding: Name

	if starts_declaration(p) {
		if d, ok := parse_declaration(p, nil, current(p)); ok {
			init = d
		}
	} else if !at_type_switch_binding(p) {
		first := parse_simple_statement(p)
		if allow(p, .Semicolon) {
			init = first
		} else {
			subject = expr_of_simple(p, first)
		}
	}

	if subject == nil {
		if at_type_switch_binding(p) {
			kind = .Type
			binding = name_of(p, advance(p))
			advance(p) // `in`
		}
		subject = parse_expr(p)
	}
	closed := close_header(p, opened, "`)` to close the `switch` header")

	_, body_opened := expect(p, .Lbrace, "L0248", "`{` to open the switch body")
	cases := make([dynamic]Switch_Case, 0, 0, p.allocator)
	for at(p, .Case) {
		append(&cases, parse_switch_case(p, kind))
	}
	_, body_closed := expect(p, .Rbrace, "L0248", "`}` to close the switch body")

	s := new_stmt(p, Stmt_Switch, start)
	s.kind = kind
	s.init = init
	s.binding = binding
	s.subject = subject
	s.cases = cases[:]
	s.has_error =
		!opened || !closed || !body_opened || !body_closed || expr_has_error(subject)
	return s
}

@(private = "file")
at_type_switch_binding :: proc(p: ^Parser) -> bool {
	return at(p, .Ident) && peek_token(p, 1).kind == .In
}

// `Value_Case` and `Type_Case`: a list, or nothing for the default case. The
// statements run to the next `case` or the body's `}`.
@(private = "file")
parse_switch_case :: proc(p: ^Parser, kind: Switch_Kind) -> Switch_Case {
	start := advance(p) // `case`

	entry: Switch_Case
	values := make([dynamic]Expr, 0, 0, p.allocator)
	if !at(p, .Colon) {
		for {
			// A type-switch case is a type for an `any_view` subject and the
			// implicit selector `.name` for a union variant. Both are parsed here;
			// the checker settles which one the subject calls for.
			append(&values, kind == .Type && !at(p, .Period) ? parse_type(p) : parse_expr(p))
			if !allow(p, .Comma) {
				break
			}
		}
	}
	entry.values = values[:]
	expect(p, .Colon, "L0248", "`:` after the case")

	stmts := make([dynamic]Stmt, 0, 0, p.allocator)
	for !at(p, .Case) && !at(p, .Rbrace) && !at(p, .EOF) {
		before := p.index
		if s, got := parse_statement(p); got {
			append(&stmts, s)
		}
		if p.index == before {
			advance(p)
		}
	}
	entry.stmts = stmts[:]
	entry.span = span_to_here(p, start)
	return entry
}

@(private = "file")
is_compound_assign :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Plus_Eq,
	     .Minus_Eq,
	     .Star_Eq,
	     .Slash_Eq,
	     .Percent_Eq,
	     .Pipe_Eq,
	     .Tilde_Eq,
	     .Amp_Eq,
	     .Amp_Tilde_Eq,
	     .Shl_Eq,
	     .Shr_Eq:
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Expressions. Levels are grammar.md's; level 1 binds loosest.
// ---------------------------------------------------------------------------

// Level 1: `or_else` and the conditional, both right-associative, so
// `a if c else b if d else e` groups as `a if c else (b if d else e)`.
@(private = "file")
parse_expr :: proc(p: ^Parser) -> Expr {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > MAX_NEST {
		return depth_exceeded(p)
	}

	lo := current(p).lo
	lhs := parse_level_2(p)

	#partial switch current(p).kind {
	case .Or_Else:
		advance(p)
		fallback := parse_expr(p)
		e := new_expr(p, Expr_Or_Else, lo)
		e.value = lhs
		e.fallback = fallback
		e.has_error = expr_has_error(lhs) || expr_has_error(fallback)
		return e
	case .If:
		advance(p)
		cond := parse_level_2(p)
		_, has_else := expect(p, .Else, "L0221", "`else` to complete the conditional expression")
		otherwise: Expr
		if has_else {
			otherwise = parse_expr(p)
		}
		e := new_expr(p, Expr_Cond, lo)
		e.then = lhs
		e.cond = cond
		e.otherwise = otherwise
		e.has_error =
			!has_else ||
			expr_has_error(lhs) ||
			expr_has_error(cond) ||
			expr_has_error(otherwise)
		return e
	}
	return lhs
}

// Level 2: ranges, non-associative — a range takes exactly two endpoints.
@(private = "file")
parse_level_2 :: proc(p: ^Parser) -> Expr {
	lo := current(p).lo
	lhs := parse_binary(p, 3)
	if !is_range_op(current(p).kind) {
		return lhs
	}

	op := advance(p)
	rhs := parse_binary(p, 3)
	e := new_expr(p, Expr_Range, lo)
	e.op = op.kind
	e.op_span = span_of(p, op)
	e.lo = lhs
	e.hi = rhs
	e.has_error = expr_has_error(lhs) || expr_has_error(rhs)

	reported := false
	for is_range_op(current(p).kind) {
		extra := advance(p)
		if !reported {
			reported = true
			parse_error(
				p,
				span_of(p, extra),
				"L0223",
				"a range has two endpoints",
				"`%s` cannot chain; parenthesise to nest a range",
				text_of(p, extra),
			)
		}
		parse_binary(p, 3) // consume the operand so recovery lands past it
		e.has_error = true
		e.span = Span{file = p.file, lo = lo, hi = p.last.hi}
	}
	return e
}

@(private = "file")
is_range_op :: proc(kind: Token_Kind) -> bool {
	return kind == .Range_Incl || kind == .Range_Excl
}

// Levels 3-7, all left-associative. 0 means "not a binary operator", which is
// what stops the climb.
@(private = "file")
binary_level :: proc(kind: Token_Kind) -> int {
	#partial switch kind {
	case .Or_Or:
		return 3
	case .And_And:
		return 4
	case .Eq_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq, .In:
		return 5
	case .Plus, .Minus, .Pipe, .Tilde:
		return 6
	case .Star, .Slash, .Percent, .Amp, .Amp_Tilde, .Shl, .Shr:
		return 7
	}
	return 0
}

// The operator loop is iterative but its tree is not: each turn wraps the
// left-hand side one node deeper. That spine counts against the same budget, so
// a 10,000-term chain cannot outrun the walkers that recurse over it later.
@(private = "file")
parse_binary :: proc(p: ^Parser, min_level: int) -> Expr {
	lo := current(p).lo
	lhs := parse_unary(p)

	spine := 0
	defer p.depth -= spine

	for {
		level := binary_level(current(p).kind)
		if level < min_level {
			return lhs
		}
		if p.suppress {
			return lhs
		}
		if p.depth > MAX_NEST {
			return depth_exceeded(p)
		}
		spine += 1
		p.depth += 1

		op := advance(p)
		// level+1 on the right is what makes these left-associative.
		rhs := parse_binary(p, level + 1)
		e := new_expr(p, Expr_Binary, lo)
		e.op = op.kind
		e.op_span = span_of(p, op)
		e.lhs = lhs
		e.rhs = rhs
		e.has_error = expr_has_error(lhs) || expr_has_error(rhs)
		lhs = e
	}
}

@(private = "file")
parse_unary :: proc(p: ^Parser) -> Expr {
	t := current(p)
	#partial switch t.kind {
	case .Plus, .Minus, .Not, .Tilde, .Amp:
		p.depth += 1
		defer p.depth -= 1
		if p.depth > MAX_NEST {
			return depth_exceeded(p)
		}
		advance(p)
		// `&mut place` only: `mut` after any other unary operator is not a form,
		// and `mut` in the binary `&` position falls through to "expected a type".
		mutable := t.kind == .Amp && allow(p, .Mut)
		operand := parse_unary(p)
		e := new_expr(p, Expr_Unary, t.lo)
		e.op = t.kind
		e.op_span = span_of(p, t)
		e.mutable = mutable
		e.operand = operand
		e.has_error = expr_has_error(operand)
		return e
	}
	return parse_postfix(p)
}

@(private = "file")
parse_postfix :: proc(p: ^Parser) -> Expr {
	lo := current(p).lo
	started_as_type := starts_type(current(p).kind) && !p.type_value
	p.type_value = false
	e := parse_primary(p)
	direct_type_is_expression := false
	if _, ok := e.(^Expr_Proc); ok {
		direct_type_is_expression = true
	}

	// Suffixes nest the same way an operator chain does, and panic mode must
	// stop building rather than pile more nodes onto a failed expression.
	spine := 0
	defer p.depth -= spine

	for {
		if p.suppress {
			return e
		}
		if p.depth > MAX_NEST {
			depth_exceeded(p)
			return e
		}
		spine += 1
		p.depth += 1

		t := current(p)
		#partial switch t.kind {
		case .Period:
			advance(p)
			if allow(p, .Lparen) {
				target := parse_type(p)
				_, closed := expect(p, .Rparen, "L0224", "`)` to close the checked extraction")
				a := new_expr(p, Expr_Checked_Extract, lo)
				a.operand = e
				a.target = target
				a.has_error = !closed || expr_has_error(e) || expr_has_error(target)
				e = a
				continue
			}
			name, ok := expect_member_name(p, "L0225", "a name after `.`")
			s := new_expr(p, Expr_Selector, lo)
			s.operand = e
			if ok {
				s.name = name_of(p, name)
			}
			s.has_error = !ok || expr_has_error(e)
			e = s

		case .Lparen:
			args, args_ok := parse_argument_list(p)
			c := new_expr(p, Expr_Call, lo)
			c.callee = e
			c.args = args
			c.has_error = !args_ok || expr_has_error(e)
			for arg in args {
				c.has_error = c.has_error || expr_has_error(arg.value)
			}
			e = c

		case .Lbracket:
			e = parse_index_or_slice(p, e, lo)

		case .Caret, .Or_Return:
			advance(p)
			n := new_expr(p, Expr_Postfix, lo)
			n.op = t.kind
			n.op_span = span_of(p, t)
			n.operand = e
			n.has_error = expr_has_error(e)
			e = n

		case .Lbrace:
			// `Composite_Type "{"` — only the forms grammar.md lists as a
			// composite type take a brace, so `f(x){...}` is not a literal.
			// Inside a `where` clause this brace opens the body instead.
			if p.no_composite || !is_composite_type(e) {
				return finish_postfix(p, e, started_as_type, direct_type_is_expression)
			}
			e = parse_composite_body(p, e, lo)
			direct_type_is_expression = true

		case:
			return finish_postfix(p, e, started_as_type, direct_type_is_expression)
		}
	}
}

@(private = "file")
finish_postfix :: proc(
	p: ^Parser,
	e: Expr,
	started_as_type: bool,
	direct_type_is_expression: bool,
) -> Expr {
	if started_as_type && !direct_type_is_expression && !expr_has_error(e) {
		parse_error(
			p,
			expr_span(e),
			"L0220",
			"a type is not an expression",
			"parenthesise a type used as a conversion, or pass it as an argument",
		)
		expr_base(e).has_error = true
	}
	return e
}

// `Index_Or_Slice`: `[a]`, the user-defined comma form `[a, b]`, or a slice
// with either endpoint omitted.
@(private = "file")
parse_index_or_slice :: proc(p: ^Parser, operand: Expr, lo: u32) -> Expr {
	advance(p) // `[`
	// Brackets bound the expression, so a `where` clause's restriction lifts.
	outer := p.no_composite
	p.no_composite = false
	defer p.no_composite = outer

	low: Expr
	if !at(p, .Colon) {
		low = parse_expr(p)
	}

	if allow(p, .Colon) {
		high: Expr
		if !at(p, .Rbracket) {
			high = parse_expr(p)
		}
		_, closed := expect(p, .Rbracket, "L0226", "`]` to close the slice")
		s := new_expr(p, Expr_Slice, lo)
		s.operand = operand
		s.lo = low
		s.hi = high
		s.has_error =
			!closed || expr_has_error(operand) || expr_has_error(low) || expr_has_error(high)
		return s
	}

	indices := make([dynamic]Expr, 0, 0, p.allocator)
	append(&indices, low)
	for allow(p, .Comma) {
		if at(p, .Rbracket) {
			break
		}
		append(&indices, parse_expr(p))
	}
	_, closed := expect(p, .Rbracket, "L0226", "`]` to close the index")

	n := new_expr(p, Expr_Index, lo)
	n.operand = operand
	n.indices = indices[:]
	n.has_error = !closed || expr_has_error(operand)
	for index in indices {
		n.has_error = n.has_error || expr_has_error(index)
	}
	return n
}

@(private = "file")
is_composite_type :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Ident, ^Expr_Selector, ^Type_Slice, ^Type_Array, ^Type_Dynamic_Array, ^Type_Map:
		return true
	case ^Expr_Call:
		// `Matrix(f32, 4){...}`: a generic application, not a call result.
		if _, is_ident := v.callee.(^Expr_Ident); is_ident {
			return true
		}
		if _, is_selector := v.callee.(^Expr_Selector); is_selector {
			return true
		}
	}
	return false
}

@(private = "file")
parse_composite_body :: proc(p: ^Parser, type_expr: Expr, lo: u32) -> Expr {
	advance(p) // `{`

	elements := make([dynamic]Element, 0, 0, p.allocator)
	malformed := false
	for !at(p, .Rbrace) && !at(p, .EOF) {
		start := current(p)
		el: Element
		first := parse_expr(p)
		if allow(p, .Assign) {
			el.key = first
			el.value = parse_expr(p)
		} else {
			el.value = first
		}
		el.span = span_to_here(p, start)
		append(&elements, el)

		if !allow(p, .Comma) {
			if at(p, .Rbrace) {
				break
			}
			if expr_has_error(el.key) || expr_has_error(el.value) {
				malformed = true
				if !resync_list(p, .Rbrace) {
					break
				}
				continue
			}
			if at(p, .Semicolon) || at(p, .Rparen) || at(p, .Rbracket) {
				break // an enclosing boundary; the missing `}` is the useful error
			}
			parse_error(
				p,
				span_of(p, current(p)),
				"L0253",
				fmt_found(p, current(p)),
				"expected `,` or `}` after the composite element",
			)
			malformed = true
			if !resync_list(p, .Rbrace) {
				break
			}
		}
	}
	_, closed := expect(p, .Rbrace, "L0227", "`}` to close the composite literal")

	c := new_expr(p, Expr_Composite, lo)
	c.type_expr = type_expr
	c.elements = elements[:]
	c.has_error = malformed || !closed || expr_has_error(type_expr)
	for element in elements {
		c.has_error = c.has_error || expr_has_error(element.key) || expr_has_error(element.value)
	}
	return c
}

// `Argument_List`, also used for `Type_Arguments` — the two are the same token
// shape, and a named argument in a generic application is M2's to reject.
@(private = "file")
parse_argument_list :: proc(p: ^Parser) -> ([]Argument, bool) {
	advance(p) // `(`
	outer := p.no_composite
	p.no_composite = false
	defer p.no_composite = outer

	args := make([dynamic]Argument, 0, 0, p.allocator)
	malformed := false
	for !at(p, .Rparen) && !at(p, .EOF) {
		arg := parse_argument(p)
		append(&args, arg)
		if !allow(p, .Comma) {
			if at(p, .Rparen) {
				break
			}
			if expr_has_error(arg.value) {
				malformed = true
				if !resync_list(p, .Rparen) {
					break
				}
				continue
			}
			if at(p, .Semicolon) || at(p, .Rbrace) || at(p, .Rbracket) {
				break // an enclosing boundary; the missing `)` is the useful error
			}
			parse_error(
				p,
				span_of(p, current(p)),
				"L0253",
				fmt_found(p, current(p)),
				"expected `,` or `)` after the argument",
			)
			malformed = true
			if !resync_list(p, .Rparen) {
				break
			}
		}
	}
	_, closed := expect(p, .Rparen, "L0217", "`)` to close the argument list")
	return args[:], closed && !malformed
}

@(private = "file")
parse_argument :: proc(p: ^Parser) -> Argument {
	start := current(p)
	a: Argument

	// `name = value`. `=` and `==` are distinct tokens, so one token of
	// lookahead settles it.
	if at(p, .Ident) && peek_token(p, 1).kind == .Assign {
		a.name = name_of(p, advance(p))
		advance(p) // `=`
	}

	#partial switch current(p).kind {
	case .Inout:
		advance(p)
		a.mode = .Inout
	case .Range:
		// `..expr` spreads a variadic; the grammar does not let it be named.
		if a.name.text == "" {
			advance(p)
			a.mode = .Spread
		}
	}

	if a.mode == .Inout || a.mode == .Spread {
		a.value = parse_expr(p)
	} else {
		a.value = parse_argument_value(p)
	}
	a.span = span_to_here(p, start)
	return a
}

// `Argument_Value = Expression | Type`. A distinctive type prefix commits to
// `Type`, except when the parse turns out to be a proc literal or a composite
// type followed by its literal body — both get reparsed through the ordinary
// precedence parser so suffixes and operators remain available.
@(private = "file")
parse_argument_value :: proc(p: ^Parser) -> Expr {
	if !starts_type(current(p).kind) {
		return parse_expr(p)
	}

	index := p.index
	last := p.last
	suppress := p.suppress
	depth_reported := p.depth_reported
	diagnostic_count := len(p.c.diagnostics)
	error_count := p.c.error_count

	candidate := parse_type(p)
	_, proc_literal := candidate.(^Expr_Proc)
	composite_literal := at(p, .Lbrace) && is_composite_type(candidate) && !p.no_composite
	if !proc_literal && !composite_literal {
		if _, proc_group := candidate.(^Expr_Proc_Group); proc_group && !expr_has_error(candidate) {
			parse_error(
				p,
				expr_span(candidate),
				"L0220",
				"a procedure group is not an argument value",
				"procedure groups are only constant declaration bodies",
			)
			expr_base(candidate).has_error = true
		}
		return candidate
	}

	// The speculative type parse was diagnostic-free on these valid shapes.
	// Restore parser state and discard any defensive diagnostics before parsing
	// the complete expression, including its suffixes and binary operators.
	p.index = index
	p.last = last
	p.suppress = suppress
	p.depth_reported = depth_reported
	truncate_diagnostics(p.c, diagnostic_count)
	p.c.error_count = error_count
	return parse_expr(p)
}

@(private = "file")
parse_primary :: proc(p: ^Parser) -> Expr {
	t := current(p)

	if starts_type(t.kind) {
		return parse_type(p)
	}

	#partial switch t.kind {
	case .Int, .Float, .String, .Raw_String, .Rune:
		advance(p)
		e := new_expr(p, Expr_Literal, t.lo)
		e.kind = literal_kind(t.kind)
		e.text = text_of(p, t)
		return e

	case .Ident:
		advance(p)
		e := new_expr(p, Expr_Ident, t.lo)
		e.name = text_of(p, t)
		e.name_id = intern_identifier(p.c, e.name)
		return e

	case .Period:
		// The implicit selector `.Member`; its operand comes from context.
		advance(p)
		name, ok := expect(p, .Ident, "L0225", "a name after `.`")
		e := new_expr(p, Expr_Selector, t.lo)
		if ok {
			e.name = name_of(p, name)
		}
		e.has_error = !ok
		return e

	case .Move:
		advance(p)
		_, opened := expect(p, .Lparen, "L0228", "`(` after `move`")
		value: Expr
		if opened {
			value = parse_expr(p)
			expect(p, .Rparen, "L0228", "`)` to close `move`")
		}
		e := new_expr(p, Expr_Move, t.lo)
		e.value = value
		e.has_error = !opened || expr_has_error(value)
		return e

	case .Lbrace:
		// A composite literal taking its type from context.
		if p.no_composite {
			parse_error(p, span_of(p, t), "L0220", fmt_found(p, t), "expected an expression")
			return error_expr(p, span_of(p, t))
		}
		return parse_composite_body(p, nil, t.lo)

	case .Lparen:
		// A labelled group is a type, not a parenthesised expression. Test before
		// consuming the opener so `parse_type` sees the whole spelling; that also
		// covers the constant path `Entry :: (key: string_view, value: int);`.
		if starts_anon_record_type(p) {
			return parse_type(p)
		}
		advance(p)
		outer := p.no_composite
		p.no_composite = false
		inner: Expr
		if starts_type(current(p).kind) {
			inner = parse_type(p)
		} else {
			inner = parse_expr(p)
		}
		expect(p, .Rparen, "L0219", "`)` to close the parenthesised expression")
		p.no_composite = outer
		return inner

	case .Error:
		// The lexer already reported this one.
		advance(p)
		return error_expr(p, span_of(p, t))
	}

	parse_error(p, span_of(p, t), "L0220", fmt_found(p, t), "expected an expression")
	if t.kind != .EOF &&
	   t.kind != .Semicolon &&
	   t.kind != .Rparen &&
	   t.kind != .Rbracket &&
	   t.kind != .Rbrace {
		advance(p)
	}
	return error_expr(p, span_of(p, t))
}

@(private = "file")
literal_kind :: proc(kind: Token_Kind) -> Literal_Kind {
	#partial switch kind {
	case .Float:
		return .Float
	case .String:
		return .String
	case .Raw_String:
		return .Raw_String
	case .Rune:
		return .Rune
	}
	return .Int
}

// ---------------------------------------------------------------------------
// Types. `parse_type` is a restricted entry point into the expression node
// domain: the distinctive forms are handled here and everything else must be a
// type name, so `x: 1 + 2;` is still a parse error.
// ---------------------------------------------------------------------------

@(private = "file")
starts_type :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Caret, .Lbracket, .Map, .Distinct, .Dyn, .Type, .Dollar, .Move_Only:
		return true
	case .Proc, .Struct, .Enum, .Union, .Interface:
		// Parsed in slice 2; recognised here so they get a real message.
		return true
	}
	return false
}

parse_type :: proc(p: ^Parser) -> Expr {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > MAX_NEST {
		return depth_exceeded(p)
	}

	t := current(p)
	lo := t.lo
	#partial switch t.kind {
	case .Caret:
		advance(p)
		mutable := allow(p, .Mut)
		elem := parse_type(p)
		n := new_expr(p, Type_Pointer, lo)
		n.mutable = mutable
		n.elem = elem
		n.has_error = expr_has_error(elem)
		return n

	case .Lbracket:
		return parse_bracket_type(p)

	case .Map:
		advance(p)
		_, opened := expect(p, .Lbracket, "L0229", "`[` after `map`")
		key: Expr
		if opened {
			key = parse_type(p)
			expect(p, .Rbracket, "L0229", "`]` after the map key type")
		}
		value := parse_type(p)
		n := new_expr(p, Type_Map, lo)
		n.key = key
		n.value = value
		n.has_error = !opened || expr_has_error(key) || expr_has_error(value)
		return n

	case .Distinct:
		advance(p)
		elem := parse_type(p)
		n := new_expr(p, Type_Distinct, lo)
		n.elem = elem
		n.has_error = expr_has_error(elem)
		return n

	case .Dyn:
		advance(p)
		mutable := allow(p, .Mut)
		iface := parse_type_name(p)
		n := new_expr(p, Type_Dyn, lo)
		n.mutable = mutable
		n.interface_expr = iface
		n.has_error = expr_has_error(iface)
		return n

	case .Type:
		advance(p)
		return new_expr(p, Type_Type, lo)

	case .Dollar:
		advance(p)
		name, ok := expect(p, .Ident, "L0230", "a name after `$`")
		constraint: Expr
		if allow(p, .Colon) {
			constraint = parse_type(p)
		}
		n := new_expr(p, Type_Poly, lo)
		if ok {
			n.name = name_of(p, name)
		}
		n.constraint = constraint
		n.has_error = !ok || expr_has_error(constraint)
		return n

	case .Proc:
		return parse_proc(p)

	case .Struct, .Union:
		return parse_record(p)

	case .Move_Only:
		keyword := advance(p)
		if !at(p, .Struct) {
			parse_error(p, span_of(p, current(p)), "L0210", fmt_found(p, current(p)), "`move_only` must be followed by `struct`")
			return error_expr(p, span_of(p, keyword))
		}
		record := parse_record(p)
		if value, ok := record.(^Type_Record); ok {
			value.move_only = true
			value.span.lo = keyword.lo
		}
		return record

	case .Enum:
		return parse_enum(p)

	case .Interface:
		return parse_interface(p)

	case .Lparen:
		return parse_anon_record_type(p)

	case .Ident:
		return parse_type_name(p)
	}

	parse_error(p, span_of(p, t), "L0210", fmt_found(p, t), "expected a type")
	return error_expr(p, span_of(p, t))
}

// `(name: Type, ...)`. Its own grammar rather than `parse_parameter_list`: an
// anonymous record field is a name list, a `:`, and a type, and nothing else.
// Every parameter-only spelling is a syntax error naming the declared struct
// that carries it.
@(private = "file")
parse_anon_record_type :: proc(p: ^Parser) -> Expr {
	open := advance(p) // `(`
	lo := open.lo
	fields := make([dynamic]Field, 0, 0, p.allocator)
	bad := false
	for !at(p, .Rparen) && !at(p, .EOF) {
		field, ok := parse_anon_record_field(p)
		bad = bad || !ok
		append(&fields, field)
		if !allow(p, .Comma) {
			break
		}
	}
	_, closed := expect(p, .Rparen, "L0254", "`)` to close the record type")
	n := new_expr(p, Type_Anon_Record, lo)
	n.fields = fields[:]
	n.span = span_to_here(p, open)
	n.has_error = bad || !closed
	if len(fields) == 0 && closed {
		parse_error(p, n.span, "L0254", "found `()`", "a record type has at least one named field")
		n.has_error = true
	}
	return n
}

@(private = "file")
parse_anon_record_field :: proc(p: ^Parser) -> (Field, bool) {
	start := current(p)
	field: Field
	if !scans_name_list_colon(p, 0) {
		parse_error(
			p, span_of(p, start), "L0254", fmt_found(p, start),
			"a record field is `name: Type`; every field of a record type is named",
		)
		// Consume to the next separator so one bad field does not cascade.
		for !at(p, .Comma) && !at(p, .Rparen) && !at(p, .EOF) {
			advance(p)
		}
		field.span = span_to_here(p, start)
		return field, false
	}
	names := make([dynamic]Name, 0, 0, p.allocator)
	for {
		name, ok := expect(p, .Ident, "L0254", "a record field name")
		if !ok {
			break
		}
		append(&names, name_of(p, name))
		if !allow(p, .Comma) {
			break
		}
	}
	field.names = names[:]
	expect(p, .Colon, "L0254", "`:` after the record field names")
	ok := true
	if what := anon_record_excluded_spelling(p); what != "" {
		parse_error(p, span_of(p, current(p)), "L0254", fmt_found(p, current(p)), what)
		advance(p) // the mode marker, so the type after it still parses
		ok = false
	}
	field.type = parse_type(p)
	if allow(p, .Assign) {
		parse_error(
			p, span_of(p, current(p)), "L0254", "found `=`",
			"a record type field has no default value; declare a `struct` for that",
		)
		parse_expr(p)
		ok = false
	}
	field.span = span_to_here(p, start)
	return field, ok && !expr_has_error(field.type)
}

@(private = "file")
anon_record_excluded_spelling :: proc(p: ^Parser) -> string {
	#partial switch current(p).kind {
	case .Inout:
		return "a record type field has no `inout` mode; declare a `struct` for that"
	case .Move:
		return "a record type field has no `move` mode; declare a `struct` for that"
	case .Dollar:
		return "a record type field cannot be a `$` template name; declare a `struct` for that"
	case .Range:
		return "a record type field cannot be variadic; declare a `struct` for that"
	case .At:
		return "a record type field takes no attributes; declare a `struct` for that"
	}
	return ""
}

// Everything the grammar spells with a leading `[`.
@(private = "file")
parse_bracket_type :: proc(p: ^Parser) -> Expr {
	open := advance(p) // `[`
	lo := open.lo

	#partial switch current(p).kind {
	case .Caret:
		advance(p)
		expect(p, .Rbracket, "L0231", "`]` after `[^`")
		elem := parse_type(p)
		n := new_expr(p, Type_C_Pointer, lo)
		n.elem = elem
		n.has_error = expr_has_error(elem)
		return n

	case .Rbracket:
		advance(p)
		mutable := allow(p, .Mut)
		elem := parse_type(p)
		n := new_expr(p, Type_Slice, lo)
		n.mutable = mutable
		n.elem = elem
		n.has_error = expr_has_error(elem)
		return n

	case .Dynamic:
		advance(p)
		expect(p, .Rbracket, "L0231", "`]` after `[dynamic`")
		elem := parse_type(p)
		n := new_expr(p, Type_Dynamic_Array, lo)
		n.elem = elem
		n.has_error = expr_has_error(elem)
		return n

	case .Question:
		advance(p)
		expect(p, .Rbracket, "L0231", "`]` after `[?`")
		elem := parse_type(p)
		n := new_expr(p, Type_Array, lo)
		n.inferred = true
		n.elem = elem
		n.has_error = expr_has_error(elem)
		return n
	}

	// `[$N]E` binds the length as a generic parameter. `$Name` is a `Type` in
	// grammar.md, not an expression, so the array length position accepts it
	// directly rather than through the expression grammar.
	length: Expr
	if at(p, .Dollar) {
		length = parse_type(p)
	} else {
		length = parse_expr(p)
	}
	closed := true
	if _, ok := expect(p, .Rbracket, "L0231", "`]` after the array length"); !ok {
		closed = false
	}
	elem := parse_type(p)
	n := new_expr(p, Type_Array, lo)
	n.length = length
	n.elem = elem
	n.has_error = !closed || expr_has_error(length) || expr_has_error(elem)
	return n
}

// `Type_Name Type_Arguments?`: one optional selector — package-qualified or an
// associated type — and an optional generic application.
@(private = "file")
parse_type_name :: proc(p: ^Parser) -> Expr {
	start := current(p)
	name, ok := expect(p, .Ident, "L0210", "a type name")
	if !ok {
		return error_expr(p, span_of(p, start))
	}

	e: Expr
	id := new_expr(p, Expr_Ident, start.lo)
	id.name = text_of(p, name)
	id.name_id = intern_identifier(p.c, id.name)
	e = id

	if at(p, .Period) && peek_token(p, 1).kind == .Ident {
		advance(p)
		field := advance(p)
		s := new_expr(p, Expr_Selector, start.lo)
		s.operand = e
		s.name = name_of(p, field)
		e = s
	}

	if at(p, .Lparen) {
		if scans_name_list_colon(p, 1) {
			// `Foo(x: int)`: labelled fields after a type name. Say so here rather
			// than letting generic-argument recovery guess at it.
			parse_error(
				p, span_of(p, current(p)), "L0254", "found a labelled field list",
				"a record type is written on its own, `(x: int)`, not applied to a name",
			)
			parse_anon_record_type(p)
			return error_expr(p, span_to_here(p, start))
		}
		args, args_ok := parse_argument_list(p)
		c := new_expr(p, Expr_Call, start.lo)
		c.callee = e
		c.args = args
		c.has_error = !args_ok
		for arg in args {
			c.has_error = c.has_error || expr_has_error(arg.value)
		}
		e = c
	}
	return e
}

// ---------------------------------------------------------------------------
// Procedures, records and interfaces: the brace-bodied forms, all reached
// through `parse_type` so they work in every position the grammar allows.
// ---------------------------------------------------------------------------

// `proc` opens four productions: a group, a bare `Proc_Type`, a definition and
// a `---` declaration. The token after `proc`, and whether a body follows,
// separate them.
@(private = "file")
parse_proc :: proc(p: ^Parser) -> Expr {
	start := advance(p) // `proc`
	lo := start.lo

	if at(p, .Lbrace) {
		return parse_proc_group(p, lo)
	}

	convention := ""
	if at(p, .String) {
		// The token text includes its quotes; a calling convention is a bare word
		// with no escapes, so slicing them off is the whole unquote (m7-plan step 3).
		raw := text_of(p, advance(p))
		convention = len(raw) >= 2 ? raw[1:len(raw) - 1] : raw
	}

	params, params_ok := parse_parameter_list(p)
	result, result_ok := parse_results(p)
	bad := !params_ok || !result_ok

	signature := new_expr(p, Type_Proc, lo)
	signature.convention = convention
	signature.params = params
	signature.result = result
	signature.has_error = bad

	where_clauses := parse_where_clause(p)

	body: ^Block
	bodiless := false
	switch {
	case at(p, .Lbrace), at(p, .At):
		block, ok := parse_block(p)
		body = block
		bad = bad || !ok
	case at(p, .Uninit):
		advance(p)
		bodiless = true
	case len(where_clauses) > 0:
		t := current(p)
		parse_error(
			p,
			span_of(p, t),
			"L0236",
			fmt_found(p, t),
			"expected a procedure body or `---` after the `where` clause",
		)
		return error_expr(p, signature.span)
	case:
		return signature // a `Proc_Type`: a signature and nothing else
	}

	e := new_expr(p, Expr_Proc, lo)
	e.signature = signature
	e.where_clauses = where_clauses
	e.body = body
	e.bodiless = bodiless
	e.has_error = bad
	for clause in where_clauses {
		e.has_error = e.has_error || expr_has_error(clause)
	}
	return e
}

// `Proc_Group`: `proc { a, b }`
@(private = "file")
parse_proc_group :: proc(p: ^Parser, lo: u32) -> Expr {
	advance(p) // `{`

	names := make([dynamic]Name, 0, 0, p.allocator)
	for !at(p, .Rbrace) && !at(p, .EOF) {
		name, ok := expect(p, .Ident, "L0244", "a procedure name")
		if ok {
			append(&names, name_of(p, name))
		}
		if !allow(p, .Comma) {
			break
		}
	}
	_, closed := expect(p, .Rbrace, "L0244", "`}` to close the procedure group")

	e := new_expr(p, Expr_Proc_Group, lo)
	e.names = names[:]
	e.has_error = !closed
	return e
}

@(private = "file")
parse_parameter_list :: proc(p: ^Parser) -> ([]Parameter, bool) {
	if _, ok := expect(p, .Lparen, "L0211", "`(` to open the parameter list"); !ok {
		return nil, false
	}

	params := make([dynamic]Parameter, 0, 0, p.allocator)
	for !at(p, .Rparen) && !at(p, .EOF) {
		append(&params, parse_parameter(p))
		if !allow(p, .Comma) {
			break
		}
	}
	_, closed := expect(p, .Rparen, "L0212", "`)` to close the parameter list")
	return params[:], closed
}

// `Parameter`. A parameter with no type at all is the receiver `self`, whose
// type comes from the enclosing block.
@(private = "file")
parse_parameter :: proc(p: ^Parser) -> Parameter {
	start := current(p)

	param: Parameter
	param.attributes = parse_attributes(p)
	names := make([dynamic]Param_Name, 0, 0, p.allocator)
	for {
		entry: Param_Name
		entry.is_poly = allow(p, .Dollar)
		name, ok := expect(p, .Ident, "L0237", "a parameter name")
		if !ok {
			break
		}
		entry.name = name_of(p, name)
		append(&names, entry)
		if !allow(p, .Comma) {
			break
		}
	}
	param.names = names[:]

	if !allow(p, .Colon) {
		param.span = span_to_here(p, start)
		return param
	}

	#partial switch current(p).kind {
	case .Inout:
		advance(p)
		param.mode = .Inout
		param.type = parse_type(p)
	case .Move:
		advance(p)
		param.mode = .Move
		param.type = parse_type(p)
	case .Range:
		advance(p) // `..`
		param.mode = .Variadic
		param.type = parse_type(p)
	case .Assign:
		advance(p) // `x: = default`, an inferred-type default
		param.default = parse_expr(p)
	case:
		param.type = parse_type(p)
		if allow(p, .Assign) {
			param.default = parse_expr(p)
		}
	}
	param.span = span_to_here(p, start)
	return param
}

// `Results = Result_Type`. design.md: a procedure returns at most one value, so
// this is one type and never a list. A parenthesised labelled group is that one
// type — an anonymous record — and `parse_type` reads it; an unlabelled `(T, U)`
// is the deleted multi-result spelling and says so.
@(private = "file")
parse_results :: proc(p: ^Parser) -> (^Result, bool) {
	if !allow(p, .Arrow) {
		return nil, true
	}

	start := current(p)
	item := new(Result, p.allocator)
	if at(p, .Lparen) && !starts_anon_record_type(p) {
		parse_error(
			p, span_of(p, start), "L0238", "found an unlabelled `(`",
			"a procedure returns at most one value; write `(name: Type, ...)` to return a record",
		)
		// Consume the group so one deleted signature does not cascade.
		depth := 0
		for !at(p, .EOF) {
			if at(p, .Lparen) {
				depth += 1
			} else if at(p, .Rparen) {
				depth -= 1
				if depth == 0 {
					advance(p)
					break
				}
			}
			advance(p)
		}
		item.type = error_expr(p, span_to_here(p, start))
		item.span = span_to_here(p, start)
		return item, false
	}

	item.is_inout = allow(p, .Inout)
	item.type = parse_type(p)
	item.span = span_to_here(p, start)
	return item, !expr_has_error(item.type)
}

// `Where_Clause`. Its expressions may not have a composite literal at the top
// level: the `{` that follows opens the declaration's body. This is the only
// place in the grammar where an expression abuts a body brace.
@(private = "file")
parse_where_clause :: proc(p: ^Parser) -> []Expr {
	if !at(p, .Where) {
		return nil
	}
	advance(p)

	outer := p.no_composite
	p.no_composite = true
	defer p.no_composite = outer

	clauses := make([dynamic]Expr, 0, 0, p.allocator)
	for {
		append(&clauses, parse_expr(p))
		if !allow(p, .Comma) {
			break
		}
	}
	return clauses[:]
}

// `Generic_Parameters`: `($T, $U: type, $N: int)`. Commas separate names inside
// a group until its `:`, and groups from each other after the type.
@(private = "file")
parse_generic_params :: proc(p: ^Parser) -> []Generic_Param {
	if !at(p, .Lparen) {
		return nil
	}
	advance(p)

	params := make([dynamic]Generic_Param, 0, 0, p.allocator)
	for !at(p, .Rparen) && !at(p, .EOF) {
		start := current(p)
		group: Generic_Param

		names := make([dynamic]Name, 0, 0, p.allocator)
		for {
			expect(p, .Dollar, "L0240", "`$` before a generic parameter name")
			name, ok := expect(p, .Ident, "L0240", "a generic parameter name")
			if !ok {
				break
			}
			append(&names, name_of(p, name))
			if !allow(p, .Comma) {
				break
			}
		}
		group.names = names[:]
		expect(p, .Colon, "L0240", "`:` and the generic parameter's type")
		group.type = parse_type(p)
		group.span = span_to_here(p, start)
		append(&params, group)

		if !allow(p, .Comma) {
			break
		}
	}
	expect(p, .Rparen, "L0240", "`)` to close the generic parameters")
	return params[:]
}

// `Struct_Type` and `Union_Type`: one node, since they differ only in body.
@(private = "file")
parse_record :: proc(p: ^Parser) -> Expr {
	keyword := advance(p) // `struct` or `union`
	lo := keyword.lo

	generics := parse_generic_params(p)
	attributes := parse_attributes(p)
	where_clauses := parse_where_clause(p)

	_, opened := expect(p, .Lbrace, "L0239", "`{` to open the body")

	fields: []Field
	variants: []Variant
	if keyword.kind == .Union {
		list := make([dynamic]Variant, 0, 0, p.allocator)
		for !at(p, .Rbrace) && !at(p, .EOF) {
			start := current(p)
			entry: Variant
			name, named := expect(p, .Ident, "L0239", "a variant name")
			if !named {
				break
			}
			entry.name = name_of(p, name)
			expect(p, .Colon, "L0239", "`:` after the variant name")
			// A payloadless variant is written `name:` — nothing follows the colon
			// but the separator or the closing brace.
			if !at(p, .Comma) && !at(p, .Rbrace) && !at(p, .EOF) {
				entry.type = parse_type(p)
			}
			entry.span = span_to_here(p, start)
			append(&list, entry)
			if !allow(p, .Comma) {
				break
			}
		}
		variants = list[:]
	} else {
		fields = parse_field_list(p)
	}
	_, closed := expect(p, .Rbrace, "L0239", "`}` to close the body")

	e := new_expr(p, Type_Record, lo)
	e.kind = keyword.kind == .Union ? .Union : .Struct
	e.generic_params = generics
	e.attributes = attributes
	e.where_clauses = where_clauses
	e.fields = fields
	e.variants = variants
	e.has_error = !opened || !closed
	return e
}

// `Field_List`. `using` is contextual here: a field may also be named `using`.
@(private = "file")
parse_field_list :: proc(p: ^Parser) -> []Field {
	fields := make([dynamic]Field, 0, 0, p.allocator)
	for !at(p, .Rbrace) && !at(p, .EOF) {
		start := current(p)

		field: Field
		field.attributes = parse_attributes(p)
		if is_contextual(p, "using") && peek_token(p, 1).kind == .Ident {
			advance(p)
			field.is_using = true
		}

		names := make([dynamic]Name, 0, 0, p.allocator)
		for {
			name, ok := expect_member_name(p, "L0241", "a field name")
			if !ok {
				break
			}
			append(&names, name_of(p, name))
			if !allow(p, .Comma) {
				break
			}
		}
		field.names = names[:]
		expect(p, .Colon, "L0241", "`:` and the field's type")
		field.type = parse_type(p)
		field.span = span_to_here(p, start)
		append(&fields, field)

		if !allow(p, .Comma) {
			break
		}
	}
	return fields[:]
}

// `Enum_Type`. A backing type may precede the body; a `Type` never starts with
// `{`, so one token settles it.
@(private = "file")
parse_enum :: proc(p: ^Parser) -> Expr {
	keyword := advance(p) // `enum`
	lo := keyword.lo

	backing: Expr
	if !at(p, .Lbrace) {
		backing = parse_type(p)
	}
	_, opened := expect(p, .Lbrace, "L0239", "`{` to open the enum body")

	fields := make([dynamic]Enum_Field, 0, 0, p.allocator)
	for !at(p, .Rbrace) && !at(p, .EOF) {
		start := current(p)
		field: Enum_Field
		name, ok := expect_member_name(p, "L0241", "an enum member name")
		if ok {
			field.name = name_of(p, name)
		}
		if allow(p, .Assign) {
			field.value = parse_expr(p)
		}
		field.span = span_to_here(p, start)
		append(&fields, field)
		if !allow(p, .Comma) {
			break
		}
	}
	_, closed := expect(p, .Rbrace, "L0239", "`}` to close the enum body")

	e := new_expr(p, Type_Enum, lo)
	e.backing = backing
	e.fields = fields[:]
	e.has_error = !opened || !closed || expr_has_error(backing)
	return e
}

@(private = "file")
parse_interface :: proc(p: ^Parser) -> Expr {
	keyword := advance(p) // `interface`
	lo := keyword.lo

	if !at(p, .Lparen) {
		t := current(p)
		parse_error(
			p,
			span_of(p, t),
			"L0240",
			fmt_found(p, t),
			"an interface declares its generic parameters, as in `interface($Self: type)`",
		)
	}
	generics := parse_generic_params(p)
	_, opened := expect(p, .Lbrace, "L0239", "`{` to open the interface body")

	requirements := make([dynamic]Requirement, 0, 0, p.allocator)
	for !at(p, .Rbrace) && !at(p, .EOF) {
		before := p.index
		append(&requirements, parse_requirement(p))
		if p.index == before {
			advance(p) // requirements end in `;`, so force progress
		}
	}
	_, closed := expect(p, .Rbrace, "L0239", "`}` to close the interface body")

	e := new_expr(p, Type_Interface, lo)
	e.generic_params = generics
	e.requirements = requirements[:]
	e.has_error = !opened || !closed
	return e
}

// `Requirement`. `slot` is contextual: only with `Identifier`, `:`, `proc`
// behind it. An opening `(` begins `Bindings` only when an identifier then `,`
// or `:` follows — neither can appear that early in an expression, so the test
// is exact, which is what makes grammar.md's advice to "wrap the expression in
// a second pair of parentheses" actually work. Committing to bindings on any
// bare `(` would leave `((a + b).c() -> T;)` with no spelling at all.
@(private = "file")
parse_requirement :: proc(p: ^Parser) -> Requirement {
	start := current(p)
	requirement: Requirement

	if is_contextual(p, "slot") &&
	   peek_token(p, 1).kind == .Ident &&
	   peek_token(p, 2).kind == .Colon &&
	   peek_token(p, 3).kind == .Proc {
		advance(p) // `slot`
		requirement.kind = .Slot
		requirement.name = name_of(p, advance(p))
		advance(p) // `:`
		requirement.slot_type = parse_type(p)
		if _, ok := expect(p, .Semicolon, "L0242", "`;` after the requirement"); !ok {
			sync_to_statement(p) // to the next `;`, or the body's `}`
		}
		requirement.span = span_to_here(p, start)
		return requirement
	}

	if at(p, .Lparen) &&
	   peek_token(p, 1).kind == .Ident &&
	   (peek_token(p, 2).kind == .Comma || peek_token(p, 2).kind == .Colon) {
		requirement.bindings = parse_bindings(p)
	}
	requirement.expr = parse_expr(p)
	if allow(p, .Arrow) {
		requirement.result_inout = allow(p, .Inout)
		requirement.result = parse_type(p)
	}
	if _, ok := expect(p, .Semicolon, "L0242", "`;` after the requirement"); !ok {
		sync_to_statement(p) // to the next `;`, or the body's `}`
	}
	requirement.span = span_to_here(p, start)
	return requirement
}

// `Bindings`: `(a, b: T, c: inout U)`
@(private = "file")
parse_bindings :: proc(p: ^Parser) -> []Binding_Group {
	advance(p) // `(`

	groups := make([dynamic]Binding_Group, 0, 0, p.allocator)
	for !at(p, .Rparen) && !at(p, .EOF) {
		start := current(p)
		group: Binding_Group

		names := make([dynamic]Name, 0, 0, p.allocator)
		for {
			name, ok := expect(p, .Ident, "L0242", "a binding name")
			if !ok {
				break
			}
			append(&names, name_of(p, name))
			if !allow(p, .Comma) {
				break
			}
		}
		group.names = names[:]
		expect(p, .Colon, "L0242", "`:` and the binding's type")
		group.is_inout = allow(p, .Inout)
		group.type = parse_type(p)
		group.span = span_to_here(p, start)
		append(&groups, group)

		if !allow(p, .Comma) {
			break
		}
	}
	expect(p, .Rparen, "L0242", "`)` to close the bindings")
	return groups[:]
}

// `Operator_Decl`: `operator(+) proc ...`, definition or `---` declaration.
@(private = "file")
parse_operator :: proc(p: ^Parser) -> Expr {
	keyword := advance(p) // `operator`
	lo := keyword.lo

	_, opened := expect(p, .Lparen, "L0243", "`(` before the operator symbol")
	symbol, symbol_span := parse_operator_symbol(p)
	_, closed := expect(p, .Rparen, "L0243", "`)` after the operator symbol")

	value: Expr
	if at(p, .Proc) {
		value = parse_proc(p)
	} else {
		t := current(p)
		parse_error(
			p,
			span_of(p, t),
			"L0243",
			fmt_found(p, t),
			"expected a procedure or procedure group for this operator",
		)
		value = error_expr(p, span_of(p, t))
	}

	e := new_expr(p, Expr_Operator, lo)
	e.symbol = symbol
	e.symbol_span = symbol_span
	e.value = value
	e.has_error = !opened || !closed || expr_has_error(value)
	return e
}

// `hook(convert|copy|drop) proc ...`. Hooks deliberately accept one procedure,
// not a procedure group: conversion overloads are collected by role, while the
// two lifecycle roles are coherent singletons.
@(private = "file")
parse_hook :: proc(p: ^Parser) -> Expr {
	keyword := advance(p) // `hook`
	lo := keyword.lo
	_, opened := expect(p, .Lparen, "L0243", "`(` before the hook role")
	role_token, has_role := expect(p, .Ident, "L0243", "one of `convert`, `copy`, or `drop`")
	role := Hook_Kind.None
	role_text := ""
	role_span := span_of(p, role_token)
	if has_role {
		role_text = text_of(p, role_token)
		switch role_text {
		case "convert": role = .Convert
		case "copy":    role = .Copy
		case "drop":    role = .Drop
		case:
			parse_error(p, role_span, "L0243", role_text, "expected one of `convert`, `copy`, or `drop`")
		}
	}
	_, closed := expect(p, .Rparen, "L0243", "`)` after the hook role")

	value: Expr
	if at(p, .Proc) {
		value = parse_proc(p)
	} else {
		t := current(p)
		parse_error(p, span_of(p, t), "L0243", fmt_found(p, t), "expected a procedure for this hook")
		value = error_expr(p, span_of(p, t))
	}

	e := new_expr(p, Expr_Operator, lo)
	e.symbol = role_text
	e.symbol_span = role_span
	e.hook = role
	e.value = value
	e.has_error = !opened || !closed || role == .None || expr_has_error(value)
	return e
}

// `Operator_Symbol`. The index forms are several tokens, so the symbol is
// recorded as canonical text.
@(private = "file")
parse_operator_symbol :: proc(p: ^Parser) -> (string, Span) {
	start := current(p)
	if allow(p, .Lbracket) {
		if allow(p, .Colon) {
			expect(p, .Rbracket, "L0243", "`]` to close `[:]`")
			return "[:]", span_to_here(p, start)
		}
		expect(p, .Rbracket, "L0243", "`]` to close `[]`")
		if allow(p, .Assign) {
			return "[]=", span_to_here(p, start)
		}
		return "[]", span_to_here(p, start)
	}

	if is_operator_symbol(current(p).kind) {
		symbol := advance(p)
		return text_of(p, symbol), span_of(p, symbol)
	}

	parse_error(
		p,
		span_of(p, start),
		"L0243",
		fmt_found(p, start),
		"expected an operator symbol",
	)
	return "", span_of(p, start)
}

@(private = "file")
is_operator_symbol :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Plus, .Minus, .Star, .Slash, .Percent:
		return true
	case .Pipe, .Tilde, .Amp, .Amp_Tilde, .Shl, .Shr:
		return true
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq, .Not, .In:
		return true
	case .Plus_Eq, .Minus_Eq, .Star_Eq, .Slash_Eq, .Percent_Eq:
		return true
	case .Pipe_Eq, .Tilde_Eq, .Amp_Eq, .Amp_Tilde_Eq, .Shl_Eq, .Shr_Eq:
		return true
	}
	return false
}
