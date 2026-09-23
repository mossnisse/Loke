// The syntax corpora, run in-process because spans and token streams are what
// they assert, and neither is visible from stdout.
//
//   tests/syntax/*.loke             valid syntax: no diagnostics, dumpable
//   tests/syntax/ambiguity/*.loke   exact dump goldens for the resolved rules
//                                   and every expression, declaration,
//                                   statement and item form
//   tests/syntax/*.loke, mutated    the fuzzer's input corpus
package lokec

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
syntax_corpus_parses :: proc(t: ^testing.T) {
	paths := corpus(t, "tests/syntax/*.loke")
	defer delete_corpus(paths)
	for path in paths {
		data, readable := os.read_entire_file(path)
		defer delete(data)
		if !testing.expectf(t, readable, "%s: cannot read", path) {
			continue
		}
		p: Checked
		parse_source(&p, string(data))
		defer destroy_checked(&p)

		// Zero diagnostics also means the parser consumed through EOF: anything
		// left over is reported as a stray item.
		expect_no_diagnostics(t, &p.c, path)
		testing.expectf(t, p.tokens[len(p.tokens) - 1].kind == .EOF, "%s: no EOF token", path)

		// ponytail: spans are checked on top-level items only; walk every node if
		// a span bug ever gets past the dump.
		previous: u32 = 0
		for item in p.f.items {
			span := item_span(item)
			testing.expectf(
				t,
				span.lo <= span.hi && int(span.hi) <= len(data),
				"%s: item span %d..%d is outside the file",
				path,
				span.lo,
				span.hi,
			)
			testing.expectf(t, span.lo >= previous, "%s: item spans are out of order", path)
			previous = span.lo
		}
		dump := ast_dump(&p.f)
		defer delete(dump)
		testing.expectf(t, len(dump) > 0, "%s: the dump did not complete", path)
	}
}

@(test)
ambiguity_goldens :: proc(t: ^testing.T) {
	paths := corpus(t, "tests/syntax/ambiguity/*.loke")
	defer delete_corpus(paths)
	for path in paths {
		data, readable := os.read_entire_file(path)
		defer delete(data)
		golden := strings.concatenate({strings.trim_suffix(path, ".loke"), ".expected"})
		defer delete(golden)
		expected, has_expected := os.read_entire_file(golden)
		defer delete(expected)
		if !testing.expectf(t, readable && has_expected, "%s: missing source or golden", path) {
			continue
		}
		p: Checked
		parse_source(&p, string(data))
		defer destroy_checked(&p)

		expect_no_diagnostics(t, &p.c, path)
		dump := ast_dump(&p.f)
		defer delete(dump)
		want, _ := strings.replace_all(string(expected), "\r\n", "\n", context.temp_allocator)
		testing.expectf(t, dump == want, "%s: dump changed:\n%s", path, dump)
	}
}

// A list grown past 64 KiB keeps every element. The syntax arena was once a
// `mem.Dynamic_Arena`, which refuses an allocation over its block size; `append`
// dropped the error, so this literal came out `[1016]int` and the body lost
// every statement after its 4096th, all without a diagnostic.
@(test)
long_lists_keep_every_element :: proc(t: ^testing.T) {
	COUNT :: 5000
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "package main;\nmain :: proc() {\n\txs := [?]int{")
	for i in 0 ..< COUNT {
		strings.write_int(&b, i)
		strings.write_string(&b, ", ")
	}
	strings.write_string(&b, "};\n")
	for _ in 0 ..< COUNT {
		strings.write_string(&b, "\txs[0] += 1;\n")
	}
	strings.write_string(&b, "}\n")

	p: Checked
	parse_source(&p, strings.to_string(b))
	defer destroy_checked(&p)
	expect_no_diagnostics(t, &p.c, "long lists")
	main_decl, is_decl := p.f.items[0].(^Decl)
	if !testing.expect(t, is_decl && decl_proc(main_decl) != nil) {
		return
	}
	body := decl_proc(main_decl).body
	testing.expect_value(t, len(body.stmts), COUNT + 1)
	xs, is_xs := body.stmts[0].(^Decl)
	if !testing.expect(t, is_xs && len(xs.values) == 1) {
		return
	}
	literal, is_literal := xs.values[0].(^Expr_Composite)
	testing.expect(t, is_literal && len(literal.elements) == COUNT)
}

// Whatever the token stream looks like, the parser must terminate, keep every
// diagnostic span inside the file, and leave a tree the dump can walk.
@(test)
mutation_fuzzing :: proc(t: ^testing.T) {
	ITERATIONS :: 200

	paths := corpus(t, "tests/syntax/*.loke")
	defer delete_corpus(paths)
	state: u64 = 0x9e3779b97f4a7c15
	for path in paths {
		data, readable := os.read_entire_file(path)
		defer delete(data)
		if !testing.expectf(t, readable, "%s: cannot read", path) {
			continue
		}
		text := string(data)
		source := test_compiler(text)
		defer destroy_compilation(&source)
		base := lex(&source, 0)
		defer delete(base)
		if len(base) < 2 {
			continue // nothing but the EOF to mutate
		}

		for _ in 0 ..< ITERATIONS {
			seed := state
			mutated := mutate(base, &state)
			defer delete(mutated)
			c := test_compiler(text)
			defer destroy_compilation(&c)
			f := parse(&c, 0, mutated)
			defer destroy_ast(&f)

			for diagnostic in c.diagnostics {
				span := diagnostic.span
				testing.expectf(
					t,
					span.lo <= span.hi && int(span.hi) <= len(text),
					"seed %d, %s: diagnostic span %d..%d is outside the file",
					seed,
					path,
					span.lo,
					span.hi,
				)
			}
			dump := ast_dump(&f)
			defer delete(dump)
			testing.expectf(t, len(dump) > 0, "seed %d, %s: the dump did not complete", seed, path)
		}
	}
}

@(private = "file")
expect_no_diagnostics :: proc(t: ^testing.T, c: ^Compiler, path: string) {
	testing.expectf(
		t,
		c.error_count == 0,
		"%s: %d diagnostics, first: %s",
		path,
		c.error_count,
		c.error_count > 0 ? c.diagnostics[0].message : "",
	)
}

@(private = "file")
corpus :: proc(t: ^testing.T, pattern: string) -> []string {
	paths, _ := filepath.glob(pattern)
	testing.expectf(
		t,
		len(paths) > 0,
		"no files match %s; run `odin test src` from the repository root",
		pattern,
	)
	return paths
}

@(private = "file")
delete_corpus :: proc(paths: []string) {
	for path in paths {
		delete(path)
	}
	delete(paths)
}

// Delimiters and separators break the parser's structure; the rest keep a
// substitution from always being a delimiter, and `EOF` truncates mid-construct.
@(private = "file")
MUTATION_KINDS :: [?]Token_Kind {
	.Lbrace,
	.Rbrace,
	.Lparen,
	.Rparen,
	.Lbracket,
	.Rbracket,
	.Semicolon,
	.Comma,
	.Colon,
	.Ident,
	.Int,
	.Proc,
	.EOF,
}

// Deletion, duplication or substitution at up to three positions, which together
// cover delimiter imbalance in both directions. The trailing EOF is never touched.
@(private = "file")
mutate :: proc(base: []Token, state: ^u64) -> []Token {
	last := len(base) - 1
	out := make([dynamic]Token, 0, len(base) + 4)

	edits := 1 + int(next_random(state) % 3)
	targets: [3]int
	for i in 0 ..< edits {
		targets[i] = int(next_random(state) % u64(last))
	}

	for token, i in base[:last] {
		hit := false
		for target in targets[:edits] {
			hit = hit || target == i
		}
		if !hit {
			append(&out, token)
			continue
		}
		switch next_random(state) % 3 {
		case 0: // delete
		case 1: // duplicate
			append(&out, token)
			append(&out, token)
		case: // substitute
			kinds := MUTATION_KINDS
			substituted := token
			substituted.kind = kinds[next_random(state) % len(kinds)]
			append(&out, substituted)
		}
	}
	append(&out, base[last])
	return out[:]
}

@(private = "file")
next_random :: proc(state: ^u64) -> u64 {
	x := state^
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	state^ = x
	return x
}
