// The syntax corpora. These run in-process rather than through the CLI because
// spans and token streams are what they assert, and neither is visible from
// stdout.
//
//   tests/syntax/*.loke             valid syntax: no diagnostics, dumpable
//   tests/syntax/ambiguity/*.loke   exact dump goldens: the resolved rules, and
//                                   the expression, declaration, statement and
//                                   item forms
//   tests/syntax/*.loke, mutated    the fuzzer's input corpus
//
// tests/syntax_err/ is checked by the CLI harness in tests/corpus_test.odin,
// which already compares diagnostics against `.expected` files.
package lokec

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
syntax_corpus_parses :: proc(t: ^testing.T) {
	paths := corpus(t, "tests/syntax/*.loke")
	for path in paths {
		data, readable := os.read_entire_file(path)
		if !testing.expectf(t, readable, "%s: cannot read", path) {
			continue
		}
		text := string(data)

		c := test_compiler(text)
		defer destroy_compilation(&c)
		tokens := lex(&c, 0)
		f := parse(&c, 0, tokens)
		defer destroy_ast(&f)

		// Zero diagnostics also asserts "the parser consumed through EOF":
		// anything left over is reported as a stray item.
		testing.expectf(
			t,
			c.error_count == 0,
			"%s: %d diagnostics, first: %s",
			path,
			c.error_count,
			c.error_count > 0 ? c.diagnostics[0].message : "",
		)
		testing.expectf(t, tokens[len(tokens) - 1].kind == .EOF, "%s: no EOF token", path)

		// ponytail: spans are checked on top-level items, not every node — the only
		// exhaustive walk is `ast_dump`, and a second one for tests would need
		// updating with every new node. Running the dump covers every node's
		// *existence*; widen this if a span bug ever gets past it.
		previous: u32 = 0
		for item in f.items {
			span := item_span(item)
			testing.expectf(
				t,
				span.lo <= span.hi && int(span.hi) <= len(text),
				"%s: item span %d..%d is outside the file",
				path,
				span.lo,
				span.hi,
			)
			testing.expectf(t, span.lo >= previous, "%s: item spans are out of order", path)
			previous = span.lo
		}
		testing.expectf(t, len(ast_dump(&f)) > 0, "%s: the dump did not complete", path)
	}
}

// Shape is the assertion for the resolved ambiguities and the parser's form
// coverage, so these are exact.
@(test)
ambiguity_goldens :: proc(t: ^testing.T) {
	paths := corpus(t, "tests/syntax/ambiguity/*.loke")
	for path in paths {
		data, readable := os.read_entire_file(path)
		expected, has_expected := os.read_entire_file(
			strings.concatenate({strings.trim_suffix(path, ".loke"), ".expected"}),
		)
		if !testing.expectf(t, readable && has_expected, "%s: missing source or golden", path) {
			continue
		}

		c := test_compiler(string(data))
		defer destroy_compilation(&c)
		tokens := lex(&c, 0)
		f := parse(&c, 0, tokens)
		defer destroy_ast(&f)

		testing.expectf(t, c.error_count == 0, "%s: an ambiguity fixture must be valid", path)
		dump := ast_dump(&f)
		want := strings.replace_all(string(expected), "\r\n", "\n") or_else string(expected)
		testing.expectf(t, dump == want, "%s: dump changed:\n%s", path, dump)
	}
}

// Deterministic mutation fuzzing. Whatever the token stream looks like, the
// parser must terminate, keep every diagnostic span inside the file, and leave
// a tree the dump can walk. The seed is printed on failure, so the run is
// reproducible from it.
@(test)
mutation_fuzzing :: proc(t: ^testing.T) {
	ITERATIONS :: 200

	paths := corpus(t, "tests/syntax/*.loke")
	state: u64 = 0x9e3779b97f4a7c15
	for path in paths {
		data, readable := os.read_entire_file(path)
		if !readable {
			continue
		}
		text := string(data)

		source := test_compiler(text)
		defer destroy_compilation(&source)
		base := lex(&source, 0)
		if len(base) < 3 {
			continue
		}

		for iteration := 0; iteration < ITERATIONS; iteration += 1 {
			seed := state
			mutated := mutate(base, &state)

			c := test_compiler(text)
			defer destroy_compilation(&c)
			f := parse(&c, 0, mutated)

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
			testing.expectf(
				t,
				len(ast_dump(&f)) > 0,
				"seed %d, %s: the dump did not complete",
				seed,
				path,
			)

			destroy_ast(&f)
			delete(mutated)
		}
	}
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

// The kinds a token is rewritten to. Delimiters and separators break the
// parser's structure; the rest keep a substitution from always being a
// delimiter. `EOF` truncates the stream mid-construct.
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

// Deletion, duplication and substitution at up to three positions, which
// together cover delimiter imbalance in both directions.
@(private = "file")
mutate :: proc(base: []Token, state: ^u64) -> []Token {
	last := len(base) - 1 // the trailing EOF is never touched
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
