package lokec

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// The body of the file's `main :: proc() { ... }`.
@(private = "file")
main_body :: proc(f: ^File) -> ^Block {
	for item in f.items {
		if d, ok := item.(^Decl); ok {
			if literal := decl_proc(d); literal != nil {
				return literal.body
			}
		}
	}
	return nil
}

// The single-package half of `compile_program`, for packages these tests load
// by hand — none uses `when`, so no discovery round is needed.
// design.md "Typed fallibility": the bootstrap instantiates
// `Result(Unit, Allocator_Error)`, so a test counting generic instances counts
// this one too.
BOOTSTRAP_INSTANCES :: 1

check_one_package :: proc(c: ^Compiler, pkg_id: Package_Id) {
	k := Checker{c = c}
	ensure_runtime_bootstrap(&k)
	rebuild_active_items(c, package_of(c, pkg_id))
	prepare_package(&k, pkg_id)
	check_package_bodies(&k, pkg_id)
}

// One parsed, registered, checked single-file program. The `File` lives in the
// caller's frame because `add_package_file` stores a pointer to it, so this is
// filled in place rather than returned — which is what collapses the three
// `defer`s every such test used to spell out into one.
Checked :: struct {
	c:      Compiler,
	f:      File,
	tokens: []Token,
	pkg:    Package_Id,
}

check_source :: proc(p: ^Checked, source: string, name := "") {
	p.c = test_compiler(source)
	p.tokens = lex(&p.c, 0)
	p.f = parse(&p.c, 0, p.tokens)
	p.pkg = new_package(&p.c, name != "" ? name : p.f.package_name)
	add_package_file(&p.c, p.pkg, &p.f)
	check_one_package(&p.c, p.pkg)
}

destroy_checked :: proc(p: ^Checked) {
	destroy_ast(&p.f)
	delete(p.tokens)
	destroy_compilation(&p.c)
}

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
deep_type_graphs_have_no_arbitrary_cutoff :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	deep := TYPE_I32
	for _ in 0 ..< 96 {
		deep = new_type(&c, Type_Info{kind = .Distinct, element = deep})
	}
	testing.expect(t, type_underlying(&c, deep) == TYPE_I32, "a valid distinct chain was truncated")
}

@(private = "file")
deep_typeid_pair :: proc(reverse: bool) -> (u64, u64) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	left, right := TYPE_I32, TYPE_I64
	for _ in 0 ..< 96 {
		left = new_type(&c, Type_Info{kind = .Pointer, element = left})
		right = new_type(&c, Type_Info{kind = .Pointer, element = right})
	}
	if reverse {
		request_typeid(&c, right)
		request_typeid(&c, left)
	} else {
		request_typeid(&c, left)
		request_typeid(&c, right)
	}
	freeze_typeids(&c)
	return typeid_value(&c, left), typeid_value(&c, right)
}

@(test)
deep_typeids_are_request_order_independent :: proc(t: ^testing.T) {
	left_first, right_first := deep_typeid_pair(false)
	left_reverse, right_reverse := deep_typeid_pair(true)
	testing.expect(t, left_first != right_first, "different deep type graphs received one identity")
	testing.expect(t, left_first == left_reverse, "deep left typeid depends on request order")
	testing.expect(t, right_first == right_reverse, "deep right typeid depends on request order")
}

@(test)
generic_probes_do_not_commit_bodies :: proc(t: ^testing.T) {
	source := `package main;
identity :: proc(value: $T) -> typeid { return typeid_of(T); }
Probe :: interface($T: type) { (value: T) identity(value) -> typeid; }
known :: proc($T: type) -> bool { return typeid_of(T) == typeid_of(T); }
bounded :: proc(value: $T) -> int where known(T) { return 1; }
main :: proc() {
    static_assert(Probe(i8));
    static_assert(Probe(int));
    assert(identity(1) != nil);
    assert(bounded(true) == 1);
}`
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, source)
	if !testing.expectf(t, p.c.error_count == 0, "probe checking produced %d errors", p.c.error_count) {
		report(&p.c)
		return
	}
	freeze_typeids(&p.c)
	testing.expect(t, typeid_value(&p.c, TYPE_I8) == 0, "a hypothetical call registered its unexecuted body")
	testing.expect(t, typeid_value(&p.c, TYPE_INT) != 0, "a real call lost the probed body's dependencies")
	testing.expect(t, typeid_value(&p.c, TYPE_BOOL) != 0, "an executed generic bound lost its dependencies")
}

@(test)
foreign_abi_walk_defers_by_value_cycles_to_size_check :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	record := new_type(&c, Type_Info{kind = .Struct})
	field := new_symbol(&c, Symbol{kind = .Var, type = record})
	fields := make([]Symbol_Id, 1, c.semantic_allocator)
	fields[0] = field
	type_of(&c, record).fields = fields
	safe, _ := foreign_abi_safe(&c, record)
	testing.expect(t, safe, "ABI traversal diagnosed or recursed before finite-size checking")
}

@(private = "file")
append_test_source :: proc(c: ^Compiler, path, text: string) -> u32 {
	starts := make([dynamic]u32)
	append(&starts, 0)
	for ch, i in text {
		if ch == '\n' {
			append(&starts, u32(i + 1))
		}
	}
	index := u32(len(c.sources))
	append(&c.sources, Source{path = path, text = text, line_starts = starts[:]})
	return index
}

@(test)
semantic_ids_survive_phases :: proc(t: ^testing.T) {
	text := `package main;

N :: 3;
main :: proc() {
	x := N + 1;
	sink(x);
}
sink :: proc(value: int) {}`
	c := test_compiler(text)
	defer destroy_compilation(&c)
	f := parse(&c, 0, lex(&c, 0))
	defer destroy_ast(&f)
	pkg_id := new_package(&c, f.package_name)
	add_package_file(&c, pkg_id, &f)
	check_one_package(&c, pkg_id)
	validate_executable(&c, pkg_id)
	if !testing.expectf(t, c.error_count == 0, "semantic phases produced %d diagnostics", c.error_count) {
		return
	}

	n_decl := f.items[0].(^Decl)
	main_decl := f.items[1].(^Decl)
	body := decl_proc(main_decl).body
	local := body.stmts[0].(^Decl)
	call_stmt := body.stmts[1].(^Stmt_Expr)
	call := call_stmt.exprs[0].(^Expr_Call)
	argument := call.args[0].value.(^Expr_Ident)
	initializer := local.values[0].(^Expr_Binary)
	n_use := initializer.lhs.(^Expr_Ident)

	testing.expect(t, n_decl.symbols[0] != INVALID_SYMBOL, "top-level declaration has no stable symbol")
	testing.expect(t, main_decl.symbols[0] != INVALID_SYMBOL, "procedure has no stable symbol")
	testing.expect(t, local.symbols[0] != INVALID_SYMBOL, "local declaration has no stable symbol")
	testing.expect(t, n_use.symbol == n_decl.symbols[0], "top-level use did not retain its binding ID")
	testing.expect(t, argument.symbol == local.symbols[0], "local use did not retain its binding ID")
	testing.expect(t, call.resolution.kind == .Call, "call was not classified during resolution")
	testing.expect(t, call.resolution.chosen_overload != INVALID_SYMBOL, "direct call has no selected target")
	main_symbol := symbol_of(&c, main_decl.symbols[0])
	testing.expect(t, main_symbol != nil && main_symbol.proc_type != INVALID_TYPE, "procedure signature has no canonical type")
}

@(test)
package_collection_crosses_file_boundaries :: proc(t: ^testing.T) {
	first_text := `package main;
main :: proc() { sink(N); }
sink :: proc(value: int) {}`
	second_text := `package main;
N :: 7;`
	c := test_compiler(first_text)
	defer destroy_compilation(&c)
	second_index := append_test_source(&c, "second.loke", second_text)
	first := parse(&c, 0, lex(&c, 0))
	defer destroy_ast(&first)
	second := parse(&c, second_index, lex(&c, second_index))
	defer destroy_ast(&second)
	pkg_id := new_package(&c, "main")
	add_package_file(&c, pkg_id, &first)
	add_package_file(&c, pkg_id, &second)
	check_one_package(&c, pkg_id)
	validate_executable(&c, pkg_id)
	if !testing.expectf(t, c.error_count == 0, "multi-file package produced %d diagnostics", c.error_count) {
		return
	}
	main_decl := first.items[0].(^Decl)
	testing.expect(t, c.entry_point == main_decl.symbols[0], "executable validation did not record the entry point")
	call_stmt := decl_proc(main_decl).body.stmts[0].(^Stmt_Expr)
	call := call_stmt.exprs[0].(^Expr_Call)
	n_use := call.args[0].value.(^Expr_Ident)
	n_decl := second.items[0].(^Decl)
	testing.expect(t, n_use.symbol == n_decl.symbols[0], "cross-file name did not bind to the package symbol")
}

@(test)
nominal_shells_precede_recursive_field_resolution :: proc(t: ^testing.T) {
	text := `package main;
Node :: struct { next: ^Node, other: ^Node, value: int }
main :: proc() { }`
	c := test_compiler(text)
	defer destroy_compilation(&c)
	f := parse(&c, 0, lex(&c, 0))
	defer destroy_ast(&f)
	pkg_id := new_package(&c, "main")
	add_package_file(&c, pkg_id, &f)
	check_one_package(&c, pkg_id)

	// M2 compiles a pointer-recursive struct, so this now checks clean; the
	// semantic foundation underneath it is the same one M1 established.
	testing.expectf(t, c.error_count == 0, "expected no diagnostics, got %d", c.error_count)
	node_decl := f.items[0].(^Decl)
	node_symbol := symbol_of(&c, node_decl.symbols[0])
	record := node_decl.values[0].(^Type_Record)
	testing.expect(t, node_symbol != nil && node_symbol.kind == .Type, "record has no nominal symbol")
	testing.expect(t, record.denoted_type == node_symbol.type, "record shell and syntax disagree")
	first_field := symbol_of(&c, record.fields[0].symbols[0])
	second_field := symbol_of(&c, record.fields[1].symbols[0])
	testing.expect(t, first_field != nil && first_field.type != INVALID_TYPE, "recursive field type was not resolved")
	testing.expect(t, second_field != nil && second_field.type == first_field.type, "equal pointer types were not interned")
}

@(test)
library_check_is_separate_from_executable_validation :: proc(t: ^testing.T) {
	text := `package utility;
helper :: proc() { }`
	c := test_compiler(text)
	defer destroy_compilation(&c)
	f := parse(&c, 0, lex(&c, 0))
	defer destroy_ast(&f)
	pkg_id := new_package(&c, "utility")
	add_package_file(&c, pkg_id, &f)
	check_one_package(&c, pkg_id)
	testing.expectf(t, c.error_count == 0, "library package was treated as an executable")
	validate_executable(&c, pkg_id)
	testing.expectf(t, c.error_count == 2, "executable validation did not enforce package name and entry point")
	testing.expect(t, c.entry_point == INVALID_SYMBOL, "failed validation recorded an entry point")
}

@(test)
default_output_keeps_a_dotted_directory_name :: proc(t: ^testing.T) {
	actual := default_output_path("tests/pkg/mangle/a.b", .Obj)
	testing.expectf(
		t,
		actual == "tests/pkg/mangle/a.b.obj" || actual == `tests\pkg\mangle\a.b.obj`,
		"dotted directory defaulted to %q",
		actual,
	)
}

@(test)
lexer_golden :: proc(t: ^testing.T) {
	text := `name 123 1.5 "text" ` + "`raw`" + ` 'x'
break case continue defer distinct dyn dynamic else enum for foreach foreign if impl import in inout interface map move mut operator or_else or_return package proc return struct switch type union via when where
static self slot using delegate thread_local manual
+ - * / % & &~ | ~ << >> && || ! == != < <= > >= = += -= *= /= %= |= ~= &= &~= <<= >>= : ; , . .. ..= ..< -> --- ? $ ^ @ ( ) [ ] { }
/* nested /* block */ comment */`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	expected := []Token_Kind {
		.Ident, .Int, .Float, .String, .Raw_String, .Rune,
		.Break, .Case, .Continue, .Defer, .Distinct, .Dyn, .Dynamic, .Else,
		.Enum, .For, .Foreach, .Foreign, .If, .Impl, .Import, .In,
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

// A malformed literal is one bad token, never a good token plus junk the parser
// then has to explain.
@(test)
lexer_rejects_malformed_literals :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		code: string,
	} {
		{"0b12", "L0113"}, // 2 is not a binary digit
		{"0o8", "L0113"},
		{"0xzz", "L0113"},
		{"0x", "L0110"}, // a prefix with nothing after it
		{"123abc", "L0113"},
		{"1_000u", "L0113"},
		{"1e", "L0112"},
		{"1.5e+", "L0112"},
		{`"\ud800"`, "L0114"}, // a surrogate half
		{`"\U00110000"`, "L0114"}, // past the last code point
		{`"\uZZZZ"`, "L0105"},
	}
	for test_case in cases {
		c := test_compiler(test_case.text)
		tokens := lex(&c, 0)
		testing.expectf(t, c.error_count == 1, "`%s`: expected one diagnostic, got %d", test_case.text, c.error_count)
		code := len(c.diagnostics) == 1 ? c.diagnostics[0].code : "<none>"
		testing.expectf(t, code == test_case.code, "`%s`: expected %s, got %s", test_case.text, test_case.code, code)
		testing.expectf(t, len(tokens) == 2 && tokens[0].kind == .Error, "`%s`: expected one error token, got %v", test_case.text, tokens)
		testing.expectf(t, int(tokens[0].hi) == len(test_case.text), "`%s`: the error token did not cover the literal", test_case.text)
	}

	// The valid neighbours of every rule above still lex.
	valid := test_compiler("0b101 0o777 0xff 1e9 1.5e+3 1_000 " + `"é\U0001f600\xff"`)
	tokens := lex(&valid, 0)
	testing.expectf(t, valid.error_count == 0, "valid literals produced %d diagnostics", valid.error_count)
	testing.expectf(t, len(tokens) == 8, "expected seven literals, got %d tokens", len(tokens) - 1)
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
import ;
main :: proc() {
	x := 1 + ;
	sink(2);
}`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)

	testing.expectf(t, c.error_count == 2, "expected two diagnostics, got %d", c.error_count)
	if !testing.expectf(t, len(f.items) == 2, "expected the import and main declaration, got %d items", len(f.items)) {
		return
	}
	_, first_is_import := f.items[0].(^Item_Import)
	_, second_is_decl := f.items[1].(^Decl)
	testing.expect(t, first_is_import, "the malformed import was not retained")
	testing.expect(t, item_base(f.items[0]).has_error, "the malformed import was not marked")
	if !testing.expect(t, second_is_decl, "recovery did not reach the following main declaration") {
		return
	}
	body := main_body(&f)
	if !testing.expectf(t, body != nil && len(body.stmts) == 2, "expected the declaration plus the following call") {
		return
	}
	broken, first_is_decl := body.stmts[0].(^Decl)
	_, second_is_expr := body.stmts[1].(^Stmt_Expr)
	testing.expect(t, first_is_decl, "the broken declaration was not retained")
	testing.expect(t, first_is_decl && broken.has_error, "the broken declaration was not marked")
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

// A node's span ends at the last token *consumed*, never at the one an
// `expect` tripped over — otherwise a declaration missing its `;` would claim
// the construct that follows it.
@(test)
spans_end_at_the_last_consumed_token :: proc(t: ^testing.T) {
	text := `package main;

main :: proc() {
	x := 1
	sink(2);
}
`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)

	testing.expectf(t, c.error_count == 1, "expected one diagnostic, got %d", c.error_count)
	body := main_body(&f)
	if !testing.expectf(
		t,
		body != nil && len(body.stmts) == 2,
		"expected the declaration and the following call",
	) {
		return
	}
	broken := body.stmts[0].(^Decl)
	testing.expectf(
		t,
		text[broken.span.lo:broken.span.hi] == "x := 1",
		"span reaches past the declaration: %q",
		text[broken.span.lo:broken.span.hi],
	)
}

// `Constant_Decl` binds one `Identifier` and has no `Storage_Modifiers` or
// `via`; `Variable_Decl` is the one that takes a list.
@(test)
constants_bind_one_plain_name :: proc(t: ^testing.T) {
	text := `package main;

A, B :: 1;
bad: static int : 2;
`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)

	if !testing.expectf(t, c.error_count == 2, "expected two diagnostics, got %d", c.error_count) {
		return
	}
	testing.expectf(t, c.diagnostics[0].code == "L0233", "unexpected code %s", c.diagnostics[0].code)
	testing.expectf(t, c.diagnostics[1].code == "L0234", "unexpected code %s", c.diagnostics[1].code)
}

// Level 2 is non-associative: a range takes exactly two endpoints.
@(test)
range_does_not_chain :: proc(t: ^testing.T) {
	text := `package main;

main :: proc() {
	x := 1 ..< 2 ..< 3;
	sink(4);
}
`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)

	if !testing.expectf(t, c.error_count == 1, "expected one diagnostic, got %d", c.error_count) {
		return
	}
	testing.expectf(t, c.diagnostics[0].code == "L0223", "unexpected code %s", c.diagnostics[0].code)

	body := main_body(&f)
	if !testing.expectf(
		t,
		body != nil && len(body.stmts) == 2,
		"recovery lost the statement after the bad range",
	) {
		return
	}
	_, sentinel_survived := body.stmts[1].(^Stmt_Expr)
	testing.expect(t, sentinel_survived, "the statement after the bad range did not survive recovery")
}

// Two shapes reach the same place: nested parentheses recurse in the parser;
// a long operator chain doesn't, but builds just as deep a tree for the dump
// and checker to walk. Both produce one diagnostic then panic mode — not one
// per frame unwound, and not a stack overflow later.
@(test)
parser_depth_is_bounded :: proc(t: ^testing.T) {
	sources := []string {
		strings.concatenate(
			{"package main;\n\nmain :: proc() {\n\tx := ", strings.repeat("(", 10_000), "1;\n}\n"},
		),
		strings.concatenate(
			{"package main;\n\nmain :: proc() {\n\tx := 1", strings.repeat(" + 1", 10_000), ";\n}\n"},
		),
		strings.concatenate(
			{"package main;\n\nmain :: proc() {\n\tx := ", strings.repeat("!", 10_000), "true;\n}\n"},
		),
	}

	for text in sources {
		c := test_compiler(text)
		tokens := lex(&c, 0)
		f := parse(&c, 0, tokens)
		defer destroy_ast(&f)

		if !testing.expectf(t, c.error_count == 1, "expected one diagnostic, got %d", c.error_count) {
			continue
		}
		testing.expectf(
			t,
			c.diagnostics[0].code == "L0222",
			"deep nesting was not reported as a nesting limit",
		)
		for token in tokens {
			testing.expectf(t, int(token.hi) <= len(text), "token extends beyond the source")
		}
		testing.expect(t, len(ast_dump(&f)) > 0, "a depth-limited tree did not dump")
	}
}

@(test)
bare_types_are_not_expressions :: proc(t: ^testing.T) {
	invalid_text := `package main;

Bad :: struct($T: type) where ^T { }

main :: proc() {
	a := ^int;
	b := type;
	c := proc();
	sink(1);
}
`
	invalid := test_compiler(invalid_text)
	invalid_tokens := lex(&invalid, 0)
	invalid_file := parse(&invalid, 0, invalid_tokens)
	defer destroy_ast(&invalid_file)

	if testing.expectf(t, invalid.error_count == 4, "expected four diagnostics, got %d", invalid.error_count) {
		for diagnostic in invalid.diagnostics {
			testing.expectf(t, diagnostic.code == "L0220", "unexpected code %s", diagnostic.code)
		}
	}
	body := main_body(&invalid_file)
	testing.expectf(
		t,
		body != nil && len(body.stmts) == 4,
		"recovery lost the statement after invalid type expressions",
	)

	valid_text := `package main;

main :: proc() {
	f(^int, []int, proc(), []int{1});
}
`
	valid := test_compiler(valid_text)
	valid_tokens := lex(&valid, 0)
	valid_file := parse(&valid, 0, valid_tokens)
	defer destroy_ast(&valid_file)
	testing.expectf(t, valid.error_count == 0, "type arguments produced %d diagnostics", valid.error_count)
}

@(test)
attributes_parse_on_referenced_blocks :: proc(t: ^testing.T) {
	text := `package main;

worker :: proc() @(cold) {
	if (ready) @(hot) { } else @(cold) { }
	for (ready) @(hot) { }
	when (ready) @(hot) { } else @(cold) when (other) @(hot) { } else @(cold) { }
}
`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)
	testing.expectf(t, c.error_count == 0, "attributed blocks produced %d diagnostics", c.error_count)
}

@(test)
missing_list_separators_are_diagnosed :: proc(t: ^testing.T) {
	text := `package main;

main :: proc() {
	a := f(1 2);
	b := Point{1 2};
	sink(3);
}
`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)

	if testing.expectf(t, c.error_count == 2, "expected two diagnostics, got %d", c.error_count) {
		for diagnostic in c.diagnostics {
			testing.expectf(t, diagnostic.code == "L0253", "unexpected code %s", diagnostic.code)
		}
	}
	body := main_body(&f)
	testing.expectf(
		t,
		body != nil && len(body.stmts) == 3,
		"recovery lost the statement after malformed lists",
	)
}

@(test)
attribute_groups_require_elements_and_no_trailing_comma :: proc(t: ^testing.T) {
	text := `package main;

main :: proc() {
	@() x := 1;
	@(cold,) y := 2;
	sink(3);
}
`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)

	if testing.expectf(t, c.error_count == 2, "expected two diagnostics, got %d", c.error_count) {
		for diagnostic in c.diagnostics {
			testing.expectf(t, diagnostic.code == "L0249", "unexpected code %s", diagnostic.code)
		}
	}
}

@(test)
where_recovery_does_not_consume_the_body :: proc(t: ^testing.T) {
	text := `package main;
Bad :: struct($T: type) where { }
sentinel :: proc() { }
`
	c := test_compiler(text)
	tokens := lex(&c, 0)
	f := parse(&c, 0, tokens)
	defer destroy_ast(&f)

	testing.expectf(t, c.error_count == 1, "expected one diagnostic, got %d", c.error_count)
	if !testing.expectf(t, len(f.items) == 2, "recovery lost the sentinel declaration") {
		return
	}
	sentinel, ok := f.items[1].(^Decl)
	testing.expect(t, ok, "the recovered sentinel is not a declaration")
	if ok && testing.expect(t, len(sentinel.names) == 1, "the sentinel declaration has no name") {
		testing.expectf(t, sentinel.names[0].text == "sentinel", "recovered %s instead of sentinel", sentinel.names[0].text)
	}
}

// Two properties the semantic arena must have, both of which a previous
// allocator broke silently: Odin's map panics unless its allocation is
// cache-line aligned, so the arena must honour the alignment an allocation
// asks for. And it must serve an allocation of *any* size: `mem.Dynamic_Arena`
// refused anything past its 64 KiB block with `.Invalid_Argument`, which
// `append` and `make` swallow — the symbol store crossing that threshold
// silently kept its old length while `new_symbol` kept handing out IDs for
// elements that were never stored.
@(test)
rejected_generic_candidates_are_negative_cached :: proc(t: ^testing.T) {
	text := `package main;
large :: proc(values: [$N]int) -> int where N > 5 { return N; }
small :: proc(values: [2]int) -> int { return 2; }
choose :: proc{large, small};
sink :: proc(value: int) {}
main :: proc() {
	sink(choose([2]int{}));
	sink(choose([2]int{}));
	sink(choose([6]int{1, 2, 3, 4, 5, 6}));
}`
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, text, "main")
	validate_executable(&p.c, p.pkg)

	testing.expectf(t, p.c.error_count == 0, "negative generic cache produced %d diagnostics", p.c.error_count)
	testing.expectf(
		t,
		p.c.instantiation_count == 2 + BOOTSTRAP_INSTANCES,
		"one rejected and one selected unique entry should consume the budget, found %d",
		p.c.instantiation_count,
	)
	testing.expectf(t, len(p.c.instances) == 2 + BOOTSTRAP_INSTANCES, "expected one rejected and one successful cache entry, found %d", len(p.c.instances))
}

@(test)
compilation_destruction_releases_owned_front_end_state :: proc(t: ^testing.T) {
	c: Compiler
	source, loaded := load_source(&c, "examples/hello.loke")
	if !testing.expect(t, loaded, "could not load the lifecycle fixture") {
		destroy_compilation(&c)
		return
	}
	tokens := lex(&c, source)
	file := new(File)
	file^ = parse(&c, source, tokens)
	delete(tokens)
	append(&c.parsed_files, file)
	errorf(&c, file.package_span, "L9999", "owned diagnostic")
	add_notef(&c, file.package_span, "owned note")
	testing.expect(t, len(c.parsed_files) == 1, "parsed file was not registered with the compilation")
	testing.expect(t, len(c.sources) == 1, "source buffer was not registered with the compilation")
	testing.expect(t, len(c.diagnostics) == 1, "diagnostic was not registered with the compilation")

	destroy_compilation(&c)
	testing.expect(t, !c.semantic_initialized, "semantic arena remained initialized")
	testing.expect(t, len(c.parsed_files) == 0, "parsed-file ownership survived destruction")
	testing.expect(t, len(c.sources) == 0, "source ownership survived destruction")
	testing.expect(t, len(c.diagnostics) == 0, "diagnostic ownership survived destruction")
	// Destruction is intentionally idempotent for early-return paths in callers.
	destroy_compilation(&c)
}

@(test)
semantic_arena_serves_maps_and_large_blocks :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)

	// Odd sizes, so a bump allocator that is not rounding is off the boundary by
	// the second allocation rather than by luck.
	for size in ([?]int{1, 17, 63, 65, 200}) {
		block, err := mem.alloc_bytes(size, runtime.MAP_CACHE_LINE_SIZE, c.semantic_allocator)
		testing.expectf(t, err == nil, "semantic arena refused %d bytes: %v", size, err)
		testing.expectf(
			t,
			uintptr(raw_data(block)) % runtime.MAP_CACHE_LINE_SIZE == 0,
			"a %d-byte allocation came back %d-aligned; maps on this arena will crash",
			size,
			uintptr(raw_data(block)) % runtime.MAP_CACHE_LINE_SIZE,
		)
	}

	// Well past any block size an arena is likely to be configured with.
	for size in ([?]int{64 * 1024, 1 << 20, 8 << 20}) {
		block, err := mem.alloc_bytes(size, allocator = c.semantic_allocator)
		testing.expectf(t, err == nil, "semantic arena refused a %d-byte block: %v", size, err)
		testing.expectf(t, len(block) == size, "semantic arena returned %d of %d bytes", len(block), size)
	}

	// The stores themselves: growth is what reallocates, so push well past the
	// initial capacity rather than trusting a single insert.
	for i in 0 ..< 4096 {
		intern_identifier(&c, fmt.tprintf("name%d", i))
	}
	testing.expect(t, len(c.identifier_names) == 4097, "identifier interning lost entries")
	for i in 0 ..< 4096 {
		id := new_symbol(&c, Symbol{name = intern_identifier(&c, fmt.tprintf("sym%d", i))})
		testing.expectf(t, symbol_of(&c, id) != nil, "symbol %d was given an ID it was never stored under", i)
	}
}

@(test)
ownership_worklist_converges_past_sixty_four_back_edges :: proc(t: ^testing.T) {
	b: strings.Builder
	strings.builder_init(&b)
	fmt.sbprintln(&b, "package main;")
	fmt.sbprintln(&b, "Box :: struct { value: int }")
	fmt.sbprintln(&b, "impl Box { release :: hook(drop) proc(self: inout Box) {} }")
	fmt.sbprintln(&b, "main :: proc() {")
	fmt.sbprintln(&b, "x := Box{1};")
	for _ in 0 ..< 70 {
		fmt.sbprintln(&b, "for (true) {")
	}
	fmt.sbprintln(&b, "y := move(x);")
	fmt.sbprintln(&b, "break;")
	for depth := 69; depth >= 0; depth -= 1 {
		fmt.sbprintln(&b, "}")
		if depth > 0 {
			fmt.sbprintln(&b, "break;")
		}
	}
	fmt.sbprintln(&b, "sink(x.value);")
	fmt.sbprintln(&b, "}")
	fmt.sbprintln(&b, "sink :: proc(value: int) {}")

	p: Checked
	defer destroy_checked(&p)
	check_source(&p, strings.to_string(b))

	found := false
	for diagnostic in p.c.diagnostics {
		if diagnostic.code == "L0500" {
			found = true
			break
		}
	}
	testing.expect(t, found, "deep ownership flow stopped before reporting the moved-value use")
}
