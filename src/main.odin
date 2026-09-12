// Driver: CLI, pipeline, exit codes.
//
// Exit codes: 0 success, 1 a user error (diagnostics or a bad command line),
// 2 an internal or toolchain failure.
package lokec

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

USAGE :: `lokec - the Loke compiler

An input is a .loke file or a directory; a directory compiles every .loke file
directly in it as one package.

usage:
    lokec <file.loke | directory> [options]

options:
    -h, --help    print this message and stop
    -version      print the compiler version and stop
    -print-toolchain
                  print the clang, MSVC toolset, and flags a link would use
                  here, and whether one could run at all, then stop
    -o <path>     output executable (default: input name with .exe)
    -emit-ll      write the LLVM IR next to the output and stop
    -keep-temps   keep the generated .ll after linking
    -parse-only   stop after lexing and parsing
    -dump-ast     print a deterministic syntax tree and stop after parsing
    -check-layout compare every folded size/alignment/offset with LLVM's own
    -collection name=path
    -collection:name=path
                  register an import-path prefix; base: and core: are seeded
                  from the directories beside the compiler, and an explicit
                  entry replaces one of those
    -define:NAME=VALUE
                  set a project-wide build_config value: true, false, an integer,
                  or a string
    -copy-cost=N  warn at a copy site duplicating N or more inline bytes, or
                  whose lifecycle clone may allocate (default 512; "off"
                  disables it)
    -runtime=<dir>
                  the seed runtime's C sources; defaults to the runtime
                  directory beside the compiler
    -panic=unwind|abort
                  whether a panic runs each active frame's registered cleanup
                  before the program stops (default: unwind)
    -opt=none|minimal|size|speed|aggressive
                  optimization level, mapped to clang -O0/-O1/-Os/-O2/-O3
                  (default: none)
    -build-mode=exe|obj
                  build an executable, or a relocatable object (default: exe)
    -log-level=debug|info|warning|error|off
                  the compiled LOKE_LOG_LEVEL; core:log suppresses every call
                  below it (default: debug)
`

Options :: struct {
	// `-h`/`--help`, `-version`, and `-print-toolchain` stop before anything is
	// compiled.
	help:       bool,
	version:    bool,
	print_toolchain: bool,
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
	// `-runtime=<dir>`, replacing the directory bundled beside the compiler.
	runtime_dir: string,
	// `-panic=unwind|abort`, the whole program's panic strategy.
	panic_unwind: bool,
	// `-opt=none|minimal|size|speed|aggressive` and `-build-mode=exe|obj`
	//.
	opt_mode:   Opt_Mode,
	build_mode: Build_Mode,
	// `-log-level=<level>`, the compiled `LOKE_LOG_LEVEL`.
	log_level:  Log_Level,
}

// design.md "Panic strategy": `unwind` is the default on hosted targets, and
// Windows x64 is the only v1 target.
DEFAULT_PANIC_UNWIND :: true

main :: proc() {
	os.exit(run())
}

@(private = "file")
run :: proc() -> int {
	opts, args_ok := parse_args(os.args[1:])
	// Asking for help is a successful run, so the text goes to stdout; a usage
	// error prints the same text on stderr and fails.
	if opts.help {
		fmt.print(USAGE)
		return 0
	}
	if opts.version {
		fmt.printfln("lokec %s", LOKE_VERSION_STRING)
		return 0
	}
	// Reports the host, so it needs no input and must not require one.
	if opts.print_toolchain {
		return print_toolchain()
	}
	if !args_ok {
		fmt.eprint(USAGE)
		return 1
	}

	c: Compiler
	defer destroy_compilation(&c)
	c.copy_cost_threshold, c.copy_cost_enabled = opts.copy_cost, opts.copy_cost_enabled
	c.panic_unwind = opts.panic_unwind
	c.opt_mode, c.build_mode = opts.opt_mode, opts.build_mode
	c.log_level = opts.log_level
	// Configuration is project-wide and immutable, and must be in place before
	// the first condition is evaluated.
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
		// An object build accepts any root package: its foreign
		// host owns process entry, so `main` is neither required nor emitted.
		if opts.build_mode == .Exe {
			validate_executable(&c, package_id)
		}
		check_exports(&c)
	}
	if c.error_count > 0 {
		report(&c)
		return 1
	}

	finalize_semantics(&c)
	if c.error_count > 0 {
		report(&c)
		return 1
	}

	if opts.check_layout {
		code := check_layout_agreement(&c, opts)
		report(&c) // the disagreements themselves are diagnostics
		return code
	}

	code := emit_package(&c, opts)
	report(&c) // warnings may have been produced with no error
	return code
}

@(private = "file")
parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts.copy_cost, opts.copy_cost_enabled = 512, true
	opts.panic_unwind = DEFAULT_PANIC_UNWIND
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch {
		case arg == "-h", arg == "-help", arg == "--help":
			opts.help = true
			return opts, true
		case arg == "-version", arg == "--version":
			opts.version = true
			return opts, true
		case arg == "-o":
			i += 1
			if i >= len(args) {
				fmt.eprintln("error: -o needs a path")
				return opts, false
			}
			opts.output = args[i]
		case arg == "-print-toolchain":
			opts.print_toolchain = true
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
		case strings.has_prefix(arg, "-panic="):
			switch arg[len("-panic="):] {
			case "unwind":
				opts.panic_unwind = true
			case "abort":
				opts.panic_unwind = false
			case:
				fmt.eprintln("error: -panic needs `unwind` or `abort`")
				return opts, false
			}
		case strings.has_prefix(arg, "-opt="):
			switch arg[len("-opt="):] {
			case "none":       opts.opt_mode = .None
			case "minimal":    opts.opt_mode = .Minimal
			case "size":       opts.opt_mode = .Size
			case "speed":      opts.opt_mode = .Speed
			case "aggressive": opts.opt_mode = .Aggressive
			case:
				fmt.eprintln("error: -opt needs `none`, `minimal`, `size`, `speed`, or `aggressive`")
				return opts, false
			}
		case strings.has_prefix(arg, "-log-level="):
			switch arg[len("-log-level="):] {
			case "debug":   opts.log_level = .Debug
			case "info":    opts.log_level = .Info
			case "warning": opts.log_level = .Warning
			case "error":   opts.log_level = .Error
			case "off":     opts.log_level = .Off
			case:
				fmt.eprintln("error: -log-level needs `debug`, `info`, `warning`, `error`, or `off`")
				return opts, false
			}
		case strings.has_prefix(arg, "-build-mode="):
			switch arg[len("-build-mode="):] {
			case "exe": opts.build_mode = .Exe
			case "obj": opts.build_mode = .Obj
			case:
				fmt.eprintln("error: -build-mode needs `exe` or `obj`")
				return opts, false
			}
		case strings.has_prefix(arg, "-runtime="):
			opts.runtime_dir = arg[len("-runtime="):]
			if opts.runtime_dir == "" {
				fmt.eprintln("error: -runtime needs a directory")
				return opts, false
			}
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
		opts.output = default_output_path(opts.input, opts.build_mode)
	}
	return opts, true
}

// A directory keeps its complete final component, dots included; only a file
// sheds its extension. Either host separator is trimmed from a directory so
// `package\` and `package/` both produce the sibling `package.exe`.
//
// A directory ending in `.` or `..` is resolved first, because those spell no
// component of their own: `lokec .` names the directory it runs in and must not
// produce a file called `..exe`. Every other spelling is kept as written.
default_output_path :: proc(input: string, mode: Build_Mode) -> string {
	stem := input
	if info, err := os.stat(input, context.temp_allocator); err == nil && info.is_dir {
		trimmed := strings.trim_right(input, "/\\")
		if base := filepath.base(trimmed); base == "." || base == ".." {
			if absolute, ok := filepath.abs(trimmed, context.temp_allocator); ok {
				trimmed = filepath.clean(absolute, context.temp_allocator)
			}
		}
		if trimmed != "" {
			stem = trimmed
		}
	} else {
		stem = strings.trim_suffix(input, filepath.ext(input))
	}
	// An object build defaults to `.obj`, an executable to `.exe`.
	return strings.concatenate({stem, mode == .Obj ? ".obj" : ".exe"})
}

// `-define:NAME=VALUE`. The value is a boolean, an integer, or — failing both —
// a string, which is what `build_config` then requires its default to match.
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

// `-collection name=path`, over the `base:` and `core:` roots bundled beside the
// compiler.
//
// Seeds go in first, and an explicit entry replaces one outright, letting a
// project substitute its own standard tree. Duplicate *explicit* entries are
// still an error; replacing a seed is not. A seed names the bundled directory
// without checking that it is there: whether one is missing is a question for
// whoever loads a package under it, and `base:runtime` — which every program
// loads — is the one that always asks.
@(private = "file")
register_collections :: proc(c: ^Compiler, entries: []string) -> bool {
	init_semantic_stores(c)
	c.collections = make(map[string]string, len(entries) + 2, c.semantic_allocator)
	for name in ([]string{"base", "core"}) {
		if bundled := install_component(name); bundled != "" {
			// Cloned like an explicit entry, so the whole map has one owner and
			// the heap path `install_component` returns is not left behind.
			c.collections[name] = strings.clone(bundled, c.semantic_allocator)
			delete(bundled)
		}
	}

	explicit := make(map[string]bool, len(entries), context.temp_allocator)
	for entry in entries {
		split := strings.index_byte(entry, '=')
		if split <= 0 {
			errorf(c, no_span(), "L0333", "`-collection %s` needs the form name=path", entry)
			continue
		}
		name := entry[:split]
		if explicit[name] {
			errorf(c, no_span(), "L0333", "collection `%s` is registered more than once", name)
			continue
		}
		explicit[name] = true
		c.collections[name] = strings.clone(entry[split + 1:], c.semantic_allocator)
	}
	return c.error_count == 0
}
