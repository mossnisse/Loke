// Driver: CLI, pipeline, exit codes (compiler-plan B1).
//
// Exit codes: 0 success, 1 user diagnostics, 2 internal or toolchain failure.
package lokec

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

USAGE :: `lokec - the Loke compiler (milestone M5b)

All of the language's syntax lexes and parses, so -parse-only and -dump-ast
accept any valid program.

Building an executable covers the static core: every scalar type, struct, enum,
fixed array, pointer, distinct type, procedure type and type alias; every
built-in operator and conversion; assignment, if, for, switch, break, continue,
defer and return; and procedures with value and inout parameters, defaults,
named arguments, multiple results and procedure values.

M3 adds the compile-time engine and packages: an ordinary procedure may be
evaluated to supply a constant, an array length or an enum value; assert and
panic work in either phase; size_of, align_of, offset_of and len fold to int;
compile-time strings, #assert and #config are available; when selects source at
file and procedure scope; and a directory is a package, with imports, an acyclic
import graph, and @(public) visibility.

M4a makes user types as capable as built-in ones at concrete types: procedure
groups and one overload-resolution engine; impl and extend blocks with the three
receiver forms, associated constants and types; init construction, conversion
and @(implicit) from untyped constants; user operators, indexing, slicing and
delegate on distinct types; and unions with type assertions, type switches,
or_else and or_return.

M4b makes those abstractions generic and erasable: $ type and value parameters,
inference, structural specialization, generic records and impl blocks, where
clauses, and monomorphization; interface declarations with slot, expression and
validity requirements, composition and associated types; compile-time reflection
with fields_of, enum_values_of, type_of, typeid_of and static foreach; runtime
foreach over ranges, fixed arrays and the iter/next protocol; and the erased
views typeid, any_view and dyn Interface with witness dispatch.

M5a adds managed values: one package/public rule for reflection, field reads and
writes, offset_of and aggregate construction alike; slices with both
capabilities, literals, reslicing, bounds and iteration, and one read-only
materialization per constant a runtime index or slice needs storage for; fixed
try_clone and drop hooks with generated recursive clones; ownership dataflow that
drops every managed local exactly once on fallthrough, return, break and
continue, in one reverse order with defer; move, exchange, manual, static and
thread_local; Allocator and Allocator_Error with new, new_clone and free over the
C runtime; and copy-cost warnings at the four copy sites.

Evaluation is bounded at 1000000 steps, 256 frames and 64 MiB of scratch memory.
Generic instantiation is bounded at 64 deep and 4096 instances.

M5b adds the two provenance analyses. Root provenance follows every borrow
carrier - pointers, slices, any_view, dyn and parameter access - from its
creation to the last use of any copy, enforces compatible access and mutable
exclusivity over normalized projection paths, and rejects a borrow that outlives
its root or escapes its procedure. Result-provenance summaries carry the answer
across direct calls, packages and generic instances, and settle to a fixed point
independent of source order. Region provenance gives allocator values a region
identity, verifies @(allocator_reset) transitively and through procedure types,
and activates free_all once nothing survives the reset.

Runtime string and string_view, dynamic arrays, maps, multi-pointers, via
allocator policies, and #location/#caller_location parse and report one
diagnostic. Storing a borrow in a global, a record field or callback state,
raw and unknown pointers, and cross-thread transfer are the documented v1 trust
boundaries and are not checked.

An input is a .loke file or a directory; a directory compiles every .loke file
directly in it as one package.

usage:
    lokec <file.loke | directory> [options]

options:
    -o <path>     output executable (default: input name with .exe)
    -emit-ll      write the LLVM IR next to the output and stop
    -keep-temps   keep the generated .ll after linking
    -parse-only   stop after lexing and parsing
    -dump-ast     print a deterministic syntax tree and stop after parsing
    -check-layout compare every folded size/alignment/offset with LLVM's own
    -collection name=path
                  register an import-path prefix; there is no built-in core:
    -define:NAME=VALUE
                  set a project-wide #config value: true, false, an integer,
                  or a string
    -copy-cost=N  warn at a copy site duplicating N or more inline bytes, or
                  whose lifecycle clone may allocate (default 512; "off"
                  disables it)
`

Options :: struct {
	input:      string,
	output:     string,
	emit_ll:    bool,
	keep_temps: bool,
	parse_only: bool,
	dump_ast:   bool,
	check_layout: bool,
	// `-define:NAME=VALUE`, in the order written, so a duplicate can name both.
	defines:    [dynamic]string,
	// `-collection name=path`, repeatable.
	collections: [dynamic]string,
	// `-copy-cost=N` in bytes, or disabled.
	copy_cost:         u64,
	copy_cost_enabled: bool,
}

main :: proc() {
	os.exit(run())
}

@(private = "file")
run :: proc() -> int {
	opts, args_ok := parse_args(os.args[1:])
	if !args_ok {
		fmt.eprint(USAGE)
		return 2
	}

	c: Compilation
	defer destroy_compilation(&c)
	c.copy_cost_threshold, c.copy_cost_enabled = opts.copy_cost, opts.copy_cost_enabled
	// Configuration is project-wide and immutable, and must be in place before
	// the first condition is evaluated (m3-plan decision "Configuration").
	if !seed_defines(&c, opts.defines[:]) {
		report(&c)
		return 1
	}
	if !register_collections(&c, opts.collections[:]) {
		report(&c)
		return 1
	}

	// The parse-only modes stop before discovery, so they still describe exactly
	// one file's syntax.
	if opts.parse_only || opts.dump_ast {
		file, loaded := load_source(&c, opts.input)
		if !loaded {
			report(&c)
			return 1
		}
		tokens := lex(&c, file)
		defer delete(tokens)
		ast := parse(&c, file, tokens)
		defer destroy_ast(&ast)
		if opts.dump_ast {
			fmt.print(ast_dump(&ast))
		}
		if c.error_count > 0 {
			report(&c)
			return 1
		}
		return 0
	}

	package_id, compiled := compile_program(&c, opts.input)
	if compiled {
		validate_executable(&c, package_id)
	}
	if c.error_count > 0 {
		report(&c)
		return 1
	}

	// Every requested concrete type gets its deterministic `typeid` before any
	// body is emitted, so traversal order cannot change an observable ID
	// (m4b-plan decision "`typeid`").
	freeze_typeids(&c)

	if opts.check_layout {
		return check_layout_agreement(&c, opts)
	}

	code := emit_package(&c, package_id, opts)
	report(&c) // warnings may have been produced with no error
	return code
}

@(private = "file")
parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts.copy_cost, opts.copy_cost_enabled = 512, true
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch {
		case arg == "-o":
			i += 1
			if i >= len(args) {
				fmt.eprintln("error: -o needs a path")
				return opts, false
			}
			opts.output = args[i]
		case arg == "-emit-ll":
			opts.emit_ll = true
		case arg == "-keep-temps":
			opts.keep_temps = true
		case arg == "-parse-only":
			opts.parse_only = true
		case arg == "-dump-ast":
			opts.dump_ast = true
		case arg == "-check-layout":
			opts.check_layout = true
		case arg == "-collection":
			i += 1
			if i >= len(args) {
				fmt.eprintln("error: -collection needs name=path")
				return opts, false
			}
			append(&opts.collections, args[i])
		case strings.has_prefix(arg, "-collection:"):
			append(&opts.collections, arg[len("-collection:"):])
		case strings.has_prefix(arg, "-define:"):
			append(&opts.defines, arg[len("-define:"):])
		case strings.has_prefix(arg, "-copy-cost="):
			text := arg[len("-copy-cost="):]
			if text == "off" {
				opts.copy_cost_enabled = false
				continue
			}
			value, parsed := strconv.parse_u64(text)
			if !parsed {
				fmt.eprintln("error: -copy-cost needs a byte count or `off`")
				return opts, false
			}
			opts.copy_cost, opts.copy_cost_enabled = value, true
		case strings.has_prefix(arg, "-"):
			fmt.eprintfln("error: unknown option `%s`", arg)
			return opts, false
		case opts.input != "":
			fmt.eprintln("error: more than one input file")
			return opts, false
		case:
			opts.input = arg
		}
	}

	if opts.input == "" {
		return opts, false
	}
	if opts.output == "" {
		// A directory input takes its own name; a file input drops its extension.
		stem := strings.trim_suffix(strings.trim_suffix(opts.input, "/"), filepath.ext(opts.input))
		opts.output = strings.concatenate({stem, ".exe"})
	}
	return opts, true
}

// `-define:NAME=VALUE`. The value is a boolean, an integer, or — failing both —
// a string, which is what `#config` then requires its default to match.
@(private = "file")
seed_defines :: proc(c: ^Compiler, defines: []string) -> bool {
	init_semantic_stores(c)
	c.defines = make(map[string]Const_Value, len(defines), c.semantic_allocator)
	for entry in defines {
		split := strings.index_byte(entry, '=')
		if split <= 0 {
			errorf(c, no_span(), "L0388", "`-define:%s` needs the form NAME=VALUE", entry)
			continue
		}
		name := entry[:split]
		text := entry[split + 1:]
		if !is_config_name(name) {
			errorf(c, no_span(), "L0388", "`%s` is not a valid configuration name", name)
			continue
		}
		if _, duplicate := c.defines[name]; duplicate {
			errorf(c, no_span(), "L0388", "`%s` is defined more than once", name)
			continue
		}
		switch text {
		case "true":
			c.defines[name] = bool_const(true)
		case "false":
			c.defines[name] = bool_const(false)
		case:
			if value, ok := bi_parse_int_literal(c, text); ok {
				c.defines[name] = integer_const(c, value)
			} else {
				c.defines[name] = Const_Value{kind = .String, text = text}
			}
		}
	}
	return c.error_count == 0
}

@(private = "file")
is_config_name :: proc(name: string) -> bool {
	for i in 0 ..< len(name) {
		ch := name[i]
		letter := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
		if !letter && !(i > 0 && ch >= '0' && ch <= '9') {
			return false
		}
	}
	return len(name) > 0
}

// `-collection name=path`. There is no implicit `core:` root: a prefix resolves
// only when the driver was given one.
@(private = "file")
register_collections :: proc(c: ^Compiler, entries: []string) -> bool {
	init_semantic_stores(c)
	c.collections = make(map[string]string, len(entries), c.semantic_allocator)
	for entry in entries {
		split := strings.index_byte(entry, '=')
		if split <= 0 {
			errorf(c, no_span(), "L0333", "`-collection %s` needs the form name=path", entry)
			continue
		}
		name := entry[:split]
		if _, duplicate := c.collections[name]; duplicate {
			errorf(c, no_span(), "L0333", "collection `%s` is registered more than once", name)
			continue
		}
		c.collections[name] = strings.clone(entry[split + 1:], c.semantic_allocator)
	}
	return c.error_count == 0
}
