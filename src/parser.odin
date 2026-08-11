// Parser (compiler-plan B4): recursive descent over the M0 subset.
//
// Constructs outside the subset are *recognised and named*, not met with
// "unexpected token" — that difference is most of what makes a prototype
// usable. A parse error never aborts the file; recovery synchronises on `;`,
// `}` and the tokens that can start a top-level item.
package lokec

import "core:mem"

@(private = "file")
Parser :: struct {
	c:      ^Compiler,
	file:   u32,
	tokens: []Token,
	index:  int,
	allocator: mem.Allocator,
}

parse :: proc(c: ^Compiler, file: u32, tokens: []Token) -> File {
	result := File {
		file = file,
	}
	mem.dynamic_arena_init(&result.arena)
	allocator := mem.dynamic_arena_allocator(&result.arena)
	p := Parser {
		c      = c,
		file   = file,
		tokens = tokens,
		allocator = allocator,
	}
	parse_package_clause(&p, &result)

	items := make([dynamic]Item, 0, 0, allocator)
	for !at(&p, .EOF) {
		before := p.index
		if item, ok := parse_top_level_item(&p); ok {
			append(&items, item)
		}
		if p.index == before {
			// Recovery made no progress; force it so this cannot spin.
			advance(&p)
		}
	}
	result.items = items[:]
	return result
}

@(private = "file")
ast_new :: proc(p: ^Parser, $T: typeid) -> ^T {
	return new(T, p.allocator)
}

@(private = "file")
error_item :: proc(p: ^Parser, span: Span) -> Item {
	item := ast_new(p, Item_Error)
	item.span = span
	return item
}

@(private = "file")
error_stmt :: proc(p: ^Parser, span: Span) -> Stmt {
	stmt := ast_new(p, Stmt_Error)
	stmt.span = span
	return stmt
}

@(private = "file")
error_expr :: proc(p: ^Parser, span: Span) -> Expr {
	expr := ast_new(p, Expr_Error)
	expr.span = span
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

@(private = "file")
span_between :: proc(p: ^Parser, from: Token, to: Token) -> Span {
	return Span{file = p.file, lo = from.lo, hi = to.hi}
}

@(private = "file")
text_of :: proc(p: ^Parser, t: Token) -> string {
	return p.c.sources[p.file].text[t.lo:t.hi]
}

// `found` renders the offending token for an "expected X" message.
@(private = "file")
found :: proc(p: ^Parser, t: Token) -> string {
	if t.kind == .EOF {
		return "end of file"
	}
	return text_of(p, t)
}

@(private = "file")
expect :: proc(p: ^Parser, kind: Token_Kind, code: string, what: string) -> (Token, bool) {
	if at(p, kind) {
		return advance(p), true
	}
	t := current(p)
	error_labelf(
		p.c,
		span_of(p, t),
		code,
		fmt_found(p, t),
		"expected %s",
		what,
	)
	return t, false
}

@(private = "file")
fmt_found :: proc(p: ^Parser, t: Token) -> string {
	if t.kind == .EOF {
		return "end of file"
	}
	return concat("found `", text_of(p, t), "`")
}

@(private = "file")
concat :: proc(parts: ..string) -> string {
	total := 0
	for s in parts {
		total += len(s)
	}
	buf := make([]u8, total)
	i := 0
	for s in parts {
		copy(buf[i:], s)
		i += len(s)
	}
	return string(buf)
}

// A construct the grammar has but M0 does not. Naming it beats a parse cascade.
@(private = "file")
unsupported :: proc(p: ^Parser, t: Token, what: string) {
	errorf(
		p.c,
		span_of(p, t),
		"L0201",
		"%s: not supported yet in this milestone (M0)",
		what,
	)
}

@(private = "file")
sync_to_item :: proc(p: ^Parser) {
	sync_to_boundary(p, .Item, true)
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
				case .Import, .Foreign, .Impl, .Extend, .When, .Package:
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
		if stop_after_brace && t.kind == .Rbrace && paren_depth == 0 && bracket_depth == 0 && brace_depth == 0 {
			return
		}
	}
}

@(private = "file")
parse_package_clause :: proc(p: ^Parser, f: ^File) {
	// Attributes on the package clause are grammatical but semantic in M0.
	if at(p, .At) {
		unsupported(p, current(p), "attributes")
		sync_to_item(p)
	}

	keyword, ok := expect(p, .Package, "L0202", "a `package` clause")
	if !ok {
		return
	}
	name, name_ok := expect(p, .Ident, "L0203", "a package name")
	if name_ok {
		f.package_name = text_of(p, name)
		f.package_span = span_of(p, name)
	}
	expect(p, .Semicolon, "L0204", "`;` after the package clause")
	_ = keyword
}

@(private = "file")
parse_top_level_item :: proc(p: ^Parser) -> (Item, bool) {
	if allow(p, .Semicolon) {
		return nil, false // empty item
	}

	t := current(p)
	#partial switch t.kind {
	case .Import:
		unsupported(p, t, "`import`")
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	case .Foreign:
		unsupported(p, t, "`foreign`")
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	case .Impl, .Extend:
		unsupported(p, t, "`impl` and `extend` blocks")
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	case .When:
		unsupported(p, t, "file-scope `when`")
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	case .At:
		unsupported(p, t, "attributes")
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	case .Error:
		advance(p)
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	case .Package:
		errorf(p.c, span_of(p, t), "L0205", "a file has exactly one `package` clause, at the top")
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	}

	if !starts_declaration(p) {
		error_labelf(
			p.c,
			span_of(p, t),
			"L0206",
			fmt_found(p, t),
			"expected a declaration",
		)
		sync_to_item(p)
		return error_item(p, span_of(p, t)), true
	}
	decl, ok := parse_declaration(p)
	if !ok {
		return error_item(p, span_of(p, t)), true
	}
	return decl, true
}

// grammar.md's bounded scan: a comma-separated identifier list followed by `:`
// is a declaration. Everything else at this position is a statement.
@(private = "file")
starts_declaration :: proc(p: ^Parser) -> bool {
	offset := 0
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

@(private = "file")
parse_declaration :: proc(p: ^Parser) -> (^Decl, bool) {
	start := current(p)
	d := ast_new(p, Decl)

	names := make([dynamic]Name, 0, 0, p.allocator)
	for {
		name, ok := expect(p, .Ident, "L0207", "a name")
		if !ok {
			sync_to_item(p)
			return nil, false
		}
		append(&names, Name{text = text_of(p, name), span = span_of(p, name)})
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
	is_const := false
	switch {
	case allow(p, .Colon):
		is_const = true
	case allow(p, .Assign):
	// inferred-type variable, `x := e`
	case:
		if !parse_type_name(p, d) {
			sync_to_item(p)
			return nil, false
		}
		switch {
		case allow(p, .Colon):
			is_const = true
		case allow(p, .Assign):
		case:
			// `x: int;` — the zero value.
			end, _ := expect(p, .Semicolon, "L0209", "`;` after the declaration")
			d.kind = .Var
			d.span = span_between(p, start, end)
			return d, true
		}
	}
	d.kind = is_const ? .Const : .Var

	// A procedure definition is the one brace-bodied constant M0 accepts, and it
	// is not followed by `;`.
	if is_const && at(p, .Proc) {
		body, ok := parse_proc_definition(p)
		if !ok {
			sync_to_item(p)
			return nil, false
		}
		d.body = body
		d.span = Span{file = p.file, lo = start.lo, hi = body.span.hi}
		return d, true
	}
	if is_const {
		#partial switch current(p).kind {
		case .Struct, .Enum, .Union, .Interface:
			unsupported(p, current(p), "type definitions")
			sync_to_item(p)
			return nil, false
		case .Operator:
			unsupported(p, current(p), "operator declarations")
			sync_to_item(p)
			return nil, false
		}
	}

	values := make([dynamic]Expr, 0, 0, p.allocator)
	invalid_value := false
	for {
		if at(p, .Uninit) {
			unsupported(p, current(p), "the uninitialised-storage marker `---`")
			advance(p)
			append(&values, nil)
		} else {
			value := parse_expr(p)
			invalid_value = expr_has_error(value) || invalid_value
			append(&values, value)
		}
		if !allow(p, .Comma) {
			break
		}
	}
	d.values = values[:]
	if invalid_value {
		sync_to_statement(p)
		return nil, false
	}

	end, _ := expect(p, .Semicolon, "L0209", "`;` after the declaration")
	d.span = span_between(p, start, end)
	return d, true
}

// M0 types are named types only; the syntactically distinctive forms are
// recognised so they get a real message.
@(private = "file")
parse_type_name :: proc(p: ^Parser, d: ^Decl) -> bool {
	t := current(p)
	#partial switch t.kind {
	case .Ident:
		advance(p)
		type_name := ast_new(p, Type_Name)
		type_name.name = text_of(p, t)
		type_name.span = span_of(p, t)
		d.declared_type = type_name
		return true
	case .Caret, .Lbracket, .Map, .Distinct, .Dyn, .Proc, .Struct, .Enum, .Union, .Type, .Dollar:
		unsupported(p, t, "this type form")
		return false
	}
	error_labelf(p.c, span_of(p, t), "L0210", fmt_found(p, t), "expected a type")
	return false
}

@(private = "file")
parse_proc_definition :: proc(p: ^Parser) -> (^Block, bool) {
	advance(p) // `proc`

	if at(p, .String) {
		unsupported(p, current(p), "an explicit calling convention")
		advance(p)
	}
	if _, ok := expect(p, .Lparen, "L0211", "`(` to open the parameter list"); !ok {
		return nil, false
	}
	if !at(p, .Rparen) {
		unsupported(p, current(p), "procedure parameters")
		for !at(p, .EOF) && !at(p, .Rparen) {
			advance(p)
		}
	}
	if _, ok := expect(p, .Rparen, "L0212", "`)` to close the parameter list"); !ok {
		return nil, false
	}
	if at(p, .Arrow) {
		unsupported(p, current(p), "procedure results")
		advance(p)
		for !at(p, .EOF) && !at(p, .Lbrace) {
			advance(p)
		}
	}
	if at(p, .Where) {
		unsupported(p, current(p), "`where` clauses")
		for !at(p, .EOF) && !at(p, .Lbrace) {
			advance(p)
		}
	}
	if at(p, .Uninit) {
		unsupported(p, current(p), "a bodiless procedure declaration")
		advance(p)
		return nil, false
	}
	return parse_block(p)
}

@(private = "file")
parse_block :: proc(p: ^Parser) -> (^Block, bool) {
	open, ok := expect(p, .Lbrace, "L0213", "`{` to open a block")
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
	close, _ := expect(p, .Rbrace, "L0214", "`}` to close the block")

	b := ast_new(p, Block)
	b.span = span_between(p, open, close)
	b.stmts = stmts[:]
	return b, true
}

@(private = "file")
parse_statement :: proc(p: ^Parser) -> (Stmt, bool) {
	t := current(p)
	#partial switch t.kind {
	case .Semicolon:
		advance(p)
		return nil, false // empty statement
	case .Lbrace:
		if b, ok := parse_block(p); ok {
			return b, true
		}
		return nil, false
	case .Return:
		advance(p)
		if !at(p, .Semicolon) {
			unsupported(p, current(p), "returning a value")
			sync_to_statement(p)
			return error_stmt(p, span_of(p, t)), true
		}
		end, _ := expect(p, .Semicolon, "L0215", "`;` after `return`")
		s := ast_new(p, Stmt_Return)
		s.span = span_between(p, t, end)
		return s, true
	case .If, .For, .Foreach, .Switch, .When, .Defer, .Break, .Continue:
		unsupported(p, t, concat("`", text_of(p, t), "`"))
		sync_to_statement(p, true)
		return error_stmt(p, span_of(p, t)), true
	case .At:
		unsupported(p, t, "attributes")
		sync_to_statement(p, true)
		return error_stmt(p, span_of(p, t)), true
	case .Error:
		advance(p)
		sync_to_statement(p)
		return error_stmt(p, span_of(p, t)), true
	}

	if starts_declaration(p) {
		if d, ok := parse_declaration(p); ok {
			return d, true
		}
		return error_stmt(p, span_of(p, t)), true
	}

	expr := parse_expr(p)
	if expr_has_error(expr) || at(p, .Error) {
		sync_to_statement(p)
		return error_stmt(p, expr_span(expr)), true
	}
	if at(p, .Assign) || is_compound_assign(current(p).kind) {
		unsupported(p, current(p), "assignment")
		sync_to_statement(p)
		return error_stmt(p, expr_span(expr)), true
	}
	end, _ := expect(p, .Semicolon, "L0216", "`;` after the statement")

	s := ast_new(p, Stmt_Expr)
	s.span = Span{file = p.file, lo = expr_span(expr).lo, hi = end.hi}
	s.expr = expr
	return s, true
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

// Expression levels 6 and 7 of grammar.md. Levels 1-5 exist in the grammar but
// need types M0 does not have, so their operators are diagnosed by name.
@(private = "file")
parse_expr :: proc(p: ^Parser) -> Expr {
	e := parse_level_6(p)

	#partial switch current(p).kind {
	case .Or_Else, .If, .Range_Incl, .Range_Excl, .Or_Or, .And_And,
	     .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq, .In:
		unsupported(p, current(p), concat("the `", text_of(p, current(p)), "` operator"))
		advance(p)
		parse_level_6(p) // consume the right-hand side so recovery lands sensibly
	}
	return e
}

@(private = "file")
parse_level_6 :: proc(p: ^Parser) -> Expr {
	lhs := parse_level_7(p)
	for {
		#partial switch current(p).kind {
		case .Plus, .Minus, .Pipe, .Tilde:
			op := advance(p)
			rhs := parse_level_7(p)
			lhs = make_binary(p, op, lhs, rhs)
		case:
			return lhs
		}
	}
}

@(private = "file")
parse_level_7 :: proc(p: ^Parser) -> Expr {
	lhs := parse_unary(p)
	for {
		#partial switch current(p).kind {
		case .Star, .Slash, .Percent, .Amp, .Amp_Tilde, .Shl, .Shr:
			op := advance(p)
			rhs := parse_unary(p)
			lhs = make_binary(p, op, lhs, rhs)
		case:
			return lhs
		}
	}
}

@(private = "file")
make_binary :: proc(p: ^Parser, op: Token, lhs: Expr, rhs: Expr) -> Expr {
	e := ast_new(p, Expr_Binary)
	e.op = op.kind
	e.op_span = span_of(p, op)
	e.lhs = lhs
	e.rhs = rhs
	e.span = Span{file = p.file, lo = expr_span(lhs).lo, hi = expr_span(rhs).hi}
	return e
}

@(private = "file")
parse_unary :: proc(p: ^Parser) -> Expr {
	t := current(p)
	#partial switch t.kind {
	case .Plus, .Minus:
		advance(p)
		operand := parse_unary(p)
		e := ast_new(p, Expr_Unary)
		e.op = t.kind
		e.op_span = span_of(p, t)
		e.operand = operand
		e.span = Span{file = p.file, lo = t.lo, hi = expr_span(operand).hi}
		return e
	case .Not, .Tilde, .Amp:
		unsupported(p, t, concat("unary `", text_of(p, t), "`"))
		advance(p)
		return parse_unary(p)
	}
	return parse_postfix(p)
}

@(private = "file")
parse_postfix :: proc(p: ^Parser) -> Expr {
	e := parse_primary(p)
	for {
		t := current(p)
		#partial switch t.kind {
		case .Lparen:
			advance(p)
			args := make([dynamic]Expr, 0, 0, p.allocator)
			if !at(p, .Rparen) {
				for {
					append(&args, parse_expr(p))
					if !allow(p, .Comma) {
						break
					}
					if at(p, .Rparen) {
						break // trailing comma
					}
				}
			}
			close, _ := expect(p, .Rparen, "L0217", "`)` to close the argument list")
			call := ast_new(p, Expr_Call)
			call.callee = e
			call.args = args[:]
			call.span = Span{file = p.file, lo = expr_span(e).lo, hi = close.hi}
			e = call
		case .Period, .Lbracket, .Caret, .Or_Return:
			unsupported(p, t, concat("the `", text_of(p, t), "` suffix"))
			advance(p)
			if t.kind == .Period && at(p, .Ident) {
				advance(p)
			}
		case:
			return e
		}
	}
}

@(private = "file")
parse_primary :: proc(p: ^Parser) -> Expr {
	t := current(p)
	#partial switch t.kind {
	case .Int:
		advance(p)
		e := ast_new(p, Expr_Int)
		e.span = span_of(p, t)
		value, ok := parse_int_text(text_of(p, t))
		if !ok {
			errorf(p.c, e.span, "L0218", "integer literal does not fit in `int`")
		}
		e.value = value
		return e

	case .Ident:
		advance(p)
		e := ast_new(p, Expr_Ident)
		e.span = span_of(p, t)
		e.name = text_of(p, t)
		return e

	case .Lparen:
		advance(p)
		inner := parse_expr(p)
		expect(p, .Rparen, "L0219", "`)` to close the parenthesised expression")
		return inner

	case .Float, .String, .Raw_String, .Rune:
		unsupported(p, t, "this literal kind")
		advance(p)
		return error_expr(p, span_of(p, t))

	case .Lbrace:
		unsupported(p, t, "composite literals")
		advance(p)
		return error_expr(p, span_of(p, t))

	case .Move, .Hash_Name, .Proc, .Dollar:
		unsupported(p, t, concat("`", text_of(p, t), "`"))
		advance(p)
		return error_expr(p, span_of(p, t))

	case .Error:
		advance(p)
		return error_expr(p, span_of(p, t))
	}

	error_labelf(p.c, span_of(p, t), "L0220", fmt_found(p, t), "expected an expression")
	if t.kind != .EOF && t.kind != .Semicolon && t.kind != .Rparen && t.kind != .Rbracket && t.kind != .Rbrace {
		advance(p)
	}
	return error_expr(p, span_of(p, t))
}

// Decodes an integer literal per grammar.md: decimal, or a `0b`/`0o`/`0x`
// prefix, with `_` allowed as a separator anywhere but the first character.
@(private = "file")
parse_int_text :: proc(text: string) -> (value: i64, ok: bool) {
	base := i64(10)
	digits := text
	if len(text) > 2 && text[0] == '0' {
		switch text[1] {
		case 'b':
			base, digits = 2, text[2:]
		case 'o':
			base, digits = 8, text[2:]
		case 'x':
			base, digits = 16, text[2:]
		}
	}

	for ch in transmute([]u8)digits {
		if ch == '_' {
			continue
		}
		digit: i64
		switch {
		case ch >= '0' && ch <= '9':
			digit = i64(ch - '0')
		case ch >= 'a' && ch <= 'f':
			digit = i64(ch-'a') + 10
		case ch >= 'A' && ch <= 'F':
			digit = i64(ch-'A') + 10
		}
		next := value*base + digit
		if next < value {
			return 0, false // overflowed i64
		}
		value = next
	}
	return value, true
}
