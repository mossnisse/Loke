package lokec

import "core:testing"

test_compiler :: proc(text: string) -> Compiler {
	c: Compiler
	starts := make([dynamic]u32)
	append(&starts, 0)
	for ch, i in text {
		if ch == '\n' {
			append(&starts, u32(i + 1))
		}
	}
	append(&c.sources, Source{path = "<test>", text = text, line_starts = starts[:]})
	return c
}

@(test)
lexer_golden :: proc(t: ^testing.T) {
	text := `name 123 1.5 "text" ` + "`raw`" + ` 'x' #assert
break case continue defer distinct dyn dynamic else enum extend for foreach foreign if impl import in inout interface map move mut operator or_else or_return package proc return struct switch type union via when where
static self slot using delegate thread_local manual
+ - * / % & &~ | ~ << >> && || ! == != < <= > >= = += -= *= /= %= |= ~= &= &~= <<= >>= : ; , . .. ..= ..< -> --- ? $ ^ @ ( ) [ ] { }
/* nested /* block */ comment */`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	expected := []Token_Kind {
		.Ident, .Int, .Float, .String, .Raw_String, .Rune, .Hash_Name,
		.Break, .Case, .Continue, .Defer, .Distinct, .Dyn, .Dynamic, .Else,
		.Enum, .Extend, .For, .Foreach, .Foreign, .If, .Impl, .Import, .In,
		.Inout, .Interface, .Map, .Move, .Mut, .Operator, .Or_Else, .Or_Return,
		.Package, .Proc, .Return, .Struct, .Switch, .Type, .Union, .Via, .When, .Where,
		.Ident, .Ident, .Ident, .Ident, .Ident, .Ident, .Ident,
		.Plus, .Minus, .Star, .Slash, .Percent, .Amp, .Amp_Tilde, .Pipe, .Tilde,
		.Shl, .Shr, .And_And, .Or_Or, .Not, .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq,
		.Gt, .Gt_Eq, .Assign, .Plus_Eq, .Minus_Eq, .Star_Eq, .Slash_Eq,
		.Percent_Eq, .Pipe_Eq, .Tilde_Eq, .Amp_Eq, .Amp_Tilde_Eq, .Shl_Eq,
		.Shr_Eq, .Colon, .Semicolon, .Comma, .Period, .Range, .Range_Incl,
		.Range_Excl, .Arrow, .Uninit, .Question, .Dollar, .Caret, .At, .Lparen,
		.Rparen, .Lbracket, .Rbracket, .Lbrace, .Rbrace, .EOF,
	}
	testing.expectf(t, c.error_count == 0, "valid golden input produced %d diagnostics", c.error_count)
	if !testing.expectf(t, len(tokens) == len(expected), "expected %d tokens, got %d", len(expected), len(tokens)) {
		return
	}
	for token, i in tokens {
		testing.expectf(t, token.kind == expected[i], "token %d: expected %v, got %v", i, expected[i], token.kind)
		testing.expectf(t, int(token.hi) <= len(text), "token %d extends beyond the source", i)
	}
}

@(test)
parser_ast_golden :: proc(t: ^testing.T) {
	text := `package main;

N :: 3;
main :: proc() {
	x := N + 1;
	print_int(x);
	return;
}`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	testing.expectf(t, c.error_count == 0, "golden AST input produced %d diagnostics", c.error_count)
	testing.expect(t, f.package_name == "main", "package name was not retained")
	if !testing.expectf(t, len(f.items) == 2, "expected 2 top-level items, got %d", len(f.items)) {
		return
	}
	main_decl, is_decl := f.items[1].(^Decl)
	if !testing.expect(t, is_decl, "main item is not a declaration") {
		return
	}
	testing.expect(t, main_decl.body != nil, "main procedure has no body")
	if main_decl.body == nil {
		return
	}
	testing.expectf(t, len(main_decl.body.stmts) == 3, "expected 3 statements, got %d", len(main_decl.body.stmts))
	_, first_is_decl := main_decl.body.stmts[0].(^Decl)
	_, second_is_call := main_decl.body.stmts[1].(^Stmt_Expr)
	_, third_is_return := main_decl.body.stmts[2].(^Stmt_Return)
	testing.expect(t, first_is_decl, "first statement is not a declaration")
	testing.expect(t, second_is_call, "second statement is not an expression statement")
	testing.expect(t, third_is_return, "third statement is not a return")
	testing.expect(t, main_decl.span.hi > main_decl.span.lo, "main declaration lost its span")

	expected_dump := `(file package="main"
  (const names=["N"]
    (int 3)
  )
  (const names=["main"]
    (block
      (var names=["x"]
        (binary Plus (ident "N") (int 1))
      )
      (call (ident "print_int") (ident "x"))
      (return)
    )
  )
)
`
	testing.expectf(t, ast_dump(&f) == expected_dump, "AST dump changed:\n%s", ast_dump(&f))
}

@(test)
malformed_escape_stays_in_bounds :: proc(t: ^testing.T) {
	text := `package main; main :: proc() { bad := "abc\`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	testing.expect(t, c.error_count > 0, "malformed escape produced no diagnostic")
	for token in tokens {
		testing.expectf(t, int(token.hi) <= len(text), "error token extends beyond source: %d > %d", token.hi, len(text))
	}
}

@(test)
parser_recovery_retains_nodes :: proc(t: ^testing.T) {
	text := `package main;
import "future";
main :: proc() {
	if (true; false) { print_int(1); }
	print_int(2);
}`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)

	testing.expect(t, c.error_count >= 2, "unsupported constructs produced too few diagnostics")
	if !testing.expectf(t, len(f.items) == 2, "expected an error item and main declaration, got %d items", len(f.items)) {
		return
	}
	_, first_is_error := f.items[0].(^Item_Error)
	main_decl, second_is_decl := f.items[1].(^Decl)
	testing.expect(t, first_is_error, "unsupported import was not retained as an error item")
	if !testing.expect(t, second_is_decl, "recovery did not reach the following main declaration") {
		return
	}
	if !testing.expectf(t, len(main_decl.body.stmts) == 2, "expected error statement plus following call, got %d", len(main_decl.body.stmts)) {
		return
	}
	_, first_is_stmt_error := main_decl.body.stmts[0].(^Stmt_Error)
	_, second_is_expr := main_decl.body.stmts[1].(^Stmt_Expr)
	testing.expect(t, first_is_stmt_error, "unsupported if was not retained as an error statement")
	testing.expect(t, second_is_expr, "delimiter-aware recovery lost the following statement")
}

@(test)
source_utf8_validation :: proc(t: ^testing.T) {
	invalid_bytes := []u8{0xf0, 0x28, 0x8c, 0x28}
	invalid := transmute(string)invalid_bytes
	valid, bad_offset := valid_utf8(invalid)
	testing.expect(t, !valid, "invalid UTF-8 was accepted")
	testing.expectf(t, bad_offset == 0, "expected the invalid sequence at byte 0, got %d", bad_offset)

	replacement_bytes := []u8{0xef, 0xbf, 0xbd}
	replacement_character := transmute(string)replacement_bytes
	valid, _ = valid_utf8(replacement_character)
	testing.expect(t, valid, "a valid encoded U+FFFD was rejected")
}
