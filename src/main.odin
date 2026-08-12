// Driver: CLI, pipeline, exit codes (compiler-plan B1).
//
// Exit codes: 0 success, 1 user diagnostics, 2 internal or toolchain failure.
package lokec

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

USAGE :: `lokec - the Loke compiler (milestone M2)

All of the language's syntax lexes and parses, so -parse-only and -dump-ast
accept any valid program.

Building an executable covers the static core: every scalar type, struct, enum,
fixed array, pointer, distinct type, procedure type and type alias; every
built-in operator and conversion; assignment, if, for, switch, break, continue,
defer and return; and procedures with value and inout parameters, defaults,
named arguments, multiple results and procedure values.

Generics, interfaces, unions, string, slices, maps, impl/extend, foreach,
import and compile-time procedures parse and report L0350.

usage:
    lokec <file.loke> [options]

options:
    -o <path>     output executable (default: input name with .exe)
    -emit-ll      write the LLVM IR next to the output and stop
    -keep-temps   keep the generated .ll after linking
    -parse-only   stop after lexing and parsing
    -dump-ast     print a deterministic syntax tree and stop after parsing
`

Options :: struct {
	input:      string,
	output:     string,
	emit_ll:    bool,
	keep_temps: bool,
	parse_only: bool,
	dump_ast:   bool,
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
	file, loaded := load_source(&c, opts.input)
	if !loaded {
		report(&c)
		return 1
	}

	tokens := lex(&c, file)
	ast := parse(&c, file, tokens)
	defer destroy_ast(&ast)

	if opts.dump_ast {
		fmt.print(ast_dump(&ast))
	}

	if c.error_count > 0 {
		report(&c)
		return 1
	}
	if opts.parse_only || opts.dump_ast {
		return 0
	}

	package_id := new_package(&c, ast.package_name, filepath.dir(opts.input))
	add_package_file(&c, package_id, &ast)
	check_package(&c, package_id)
	validate_executable(&c, package_id)
	if c.error_count > 0 {
		report(&c)
		return 1
	}

	code := emit_package(&c, package_id, opts)
	report(&c) // warnings may have been produced with no error
	return code
}

@(private = "file")
parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
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
		stem := strings.trim_suffix(opts.input, filepath.ext(opts.input))
		opts.output = strings.concatenate({stem, ".exe"})
	}
	return opts, true
}
