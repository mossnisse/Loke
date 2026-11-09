// Driver: CLI, presentation, exit codes. Compilation lives in session.odin.
package lokec

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"

USAGE :: `lokec - the Loke compiler

An input is a .loke file or a directory; a directory compiles every .loke file
directly in it as one package. A tree, a directory followed by /..., tests
each package in it and below it as a root of its own.

usage:
    lokec <file.loke | directory | directory/...> [options]

options:
    -h, --help    print this message and stop
    -version      print the compiler version and stop
    -print-toolchain
                  print the clang, MSVC toolset, and flags a link would use
                  here, and whether one could run at all, then stop
    -o <path>     output path (default: input name with .exe, .obj or .test.exe
                  by build mode); with a tree, the directory that takes the
                  place of the one holding it
    -test         build the root package's @(test) procedures into a test
                  executable, run each in its own process, and report them;
                  with a tree, do so for each package that declares a test
    -emit-ll      write the LLVM IR next to the output and stop
    -keep-temps   keep the generated .ll, and any object assembled from a .asm
                  import, after linking
    -parse-only   stop after lexing and parsing (file inputs only)
    -dump-ast     print a deterministic syntax tree and stop after parsing
                  (file inputs only)
    -dump-tokens  print each token's byte span and kind and stop after lexing
                  (file inputs only)
    -check-layout compare every folded size/alignment/offset with LLVM's own
    -doc          print the root package's public API as Markdown and stop
    -api          write api.loki, the interface file, in the directory of the
                  root package and of each project package, and stop
    -api-check    list the interface files -api would change, exit 1 if there
                  are any, and stop
    -fmt          rewrite the input file, or a directory's .loke files, in
                  the canonical layout, and stop
    -fmt-check    list the files -fmt would change, exit 1 if there are any,
                  and stop
    -migrate      rewrite spellings an earlier release accepted in the input
                  file, or a directory's .loke files, and stop
    -migrate-check
                  list the files -migrate would change, exit 1 if there are
                  any, and stop
    -collection name=path
    -collection:name=path
                  register an import-path prefix; base: and core: are seeded
                  from the directories beside the compiler, and an explicit
                  entry replaces one of those
    -define:NAME=VALUE
                  set a project-wide build_config value: true, false, an integer,
                  or a string
    -copy-cost=N  warn at a copy that may allocate, and at one duplicating N
                  or more inline bytes (default 512; "off" disables both)
    -runtime=<dir>
                  the seed runtime's C sources; defaults to the runtime
                  directory beside the compiler
    -panic=unwind|abort
                  whether a panic runs each active frame's registered cleanup
                  before the program stops (default: unwind)
    -opt=none|minimal|size|speed|aggressive
                  optimization level, mapped to clang -O0/-O1/-Os/-O2/-O3
                  (default: none)
    -cpu=x86-64|x86-64-v2|x86-64-v3
                  the instruction set the build may use; an executable checks
                  at startup that the processor has it (default: x86-64)
    -g            emit debug information, at any -opt level: an executable
                  gets a .pdb beside it
    -debug        set LOKE_DEBUG to true
    -build-mode=exe|obj|test
                  build an executable, a relocatable object, or a test
                  executable that -test would run (default: exe)
    -log-level=debug|info|warning|error|off
                  the compiled LOKE_LOG_LEVEL; core:log suppresses every call
                  below it (default: debug)
`

// What a run does, at most one. `.Build` is the default and has no flag.
@(private = "file")
Action :: enum {
	Build,
	Help,
	Version,
	Print_Toolchain,
	Parse_Only,
	Dump_Ast,
	Dump_Tokens,
	Check_Layout,
	Doc,
	Api,
	Api_Check,
	Fmt,
	Fmt_Check,
	Migrate,
	Migrate_Check,
}

@(private = "file")
ACTION_FLAGS := [Action]string {
	.Build           = "",
	.Help            = "",
	.Version         = "",
	.Print_Toolchain = "-print-toolchain",
	.Parse_Only      = "-parse-only",
	.Dump_Ast        = "-dump-ast",
	.Dump_Tokens     = "-dump-tokens",
	.Check_Layout    = "-check-layout",
	.Doc             = "-doc",
	.Api             = "-api",
	.Api_Check       = "-api-check",
	.Fmt             = "-fmt",
	.Fmt_Check       = "-fmt-check",
	.Migrate         = "-migrate",
	.Migrate_Check   = "-migrate-check",
}

@(private = "file")
Options :: struct {
	action:      Action,
	input:       string,
	tree:        string,
	run_tests:   bool,
	defines:     [dynamic]string,
	collections: [dynamic]string,
	config:      Compilation_Config,
	emission:    Emission_Options,
}

// `-define:LOKE_TRACK_MEMORY=true` reports every allocation `run` did not free,
// and every bad free, on stderr.
LOKE_TRACK_MEMORY :: #config(LOKE_TRACK_MEMORY, false)
_ :: mem

main :: proc() {
	when LOKE_TRACK_MEMORY {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
	}
	code := run()
	when LOKE_TRACK_MEMORY {
		free_all(context.temp_allocator)
		for _, leak in track.allocation_map {
			fmt.eprintfln("leak %v bytes @ %v", leak.size, leak.location)
		}
		for bad in track.bad_free_array {
			fmt.eprintfln("bad free %p @ %v", bad.memory, bad.location)
		}
	}
	os.exit(code)
}

// Exit status: 0 success, 1 source or configuration diagnostics or a failing
// test, 2 invalid command-line usage or a backend/toolchain failure.
@(private = "file")
run :: proc() -> int {
	opts, args_ok := parse_args(os.args[1:])
	defer {
		delete(opts.defines)
		delete(opts.collections)
	}
	if !args_ok {
		fmt.eprint(USAGE)
		return 2
	}
	#partial switch opts.action {
	case .Help:
		fmt.print(USAGE)
		return 0
	case .Version:
		fmt.printfln("lokec %s", VERSION_WITH_REVISION)
		return 0
	case .Print_Toolchain:
		return print_toolchain(opts.config.cpu)
	}

	opts.config.defines, opts.config.collections = opts.defines[:], opts.collections[:]
	if opts.tree != "" {
		return test_tree(opts.tree, opts.config, opts.emission, opts.run_tests && !opts.emission.emit_ll)
	}
	s: Compilation_Session
	defer destroy_session(&s)
	c := &s.compiler
	if !init_session(&s, opts.config) {
		report(c)
		return 1
	}
	code := run_action(&s, &opts)
	report(c)
	if code == 0 && opts.action == .Build && opts.run_tests && !opts.emission.emit_ll {
		code, _, _ = run_tests(c, opts.emission.output)
	}
	return code
}

// The caller reports what `c` collected, warnings included.
@(private = "file")
run_action :: proc(s: ^Compilation_Session, opts: ^Options) -> int {
	c := &s.compiler
	#partial switch opts.action {
	case .Fmt, .Fmt_Check:
		return format_files(c, opts.input, opts.action == .Fmt_Check)
	case .Migrate, .Migrate_Check:
		return migrate_files(c, opts.input, opts.action == .Migrate_Check)
	case .Parse_Only, .Dump_Ast, .Dump_Tokens:
		return run_syntax_stage(c, opts)
	case .Api, .Api_Check:
		if !os.is_dir(opts.input) {
			fmt.eprintfln("error: %s needs a directory input", ACTION_FLAGS[opts.action])
			return 2
		}
	}

	if !check_session(s, opts.input, opts.action == .Doc || opts.action == .Api || opts.action == .Api_Check) {
		return 1
	}
	#partial switch opts.action {
	case .Api, .Api_Check:
		return write_interfaces(c, c.root_package, opts.action == .Api_Check)
	case .Doc:
		page := document_project(c, c.root_package)
		defer delete(page)
		fmt.print(page)
		return 0
	}

	if opts.emission.output == "" {
		opts.emission.output = default_output_path(opts.input, opts.config.build_mode)
		if opts.emission.output == "" {
			fmt.eprintln("error: a root directory input needs -o")
			return 2
		}
	}
	if opts.action == .Check_Layout {
		return check_layout_agreement(c, opts.emission)
	}
	return emit_session(s, opts.emission)
}

@(private = "file")
run_syntax_stage :: proc(c: ^Compiler, opts: ^Options) -> int {
	if os.is_dir(opts.input) {
		fmt.eprintfln("error: %s needs a file input", ACTION_FLAGS[opts.action])
		return 2
	}
	file, loaded := load_source(c, opts.input)
	if !loaded {
		return 1
	}
	tokens := lex(c, file)
	defer delete(tokens)
	if opts.action == .Dump_Tokens {
		for token in tokens {
			fmt.printfln("%d %d %v", token.lo, token.hi, token.kind)
		}
		return c.error_count > 0 ? 1 : 0
	}
	ast := parse(c, file, tokens)
	defer destroy_ast(&ast)
	if opts.action == .Dump_Ast {
		dump := ast_dump(&ast)
		defer delete(dump)
		fmt.print(dump)
	}
	return c.error_count > 0 ? 1 : 0
}

// The index of `value` in `names`, or false after saying what `flag` takes.
@(private = "file")
choice :: proc(flag, value: string, names: ..string) -> (int, bool) {
	for name, index in names {
		if name == value {
			return index, true
		}
	}
	fmt.eprintf("error: %s needs ", flag)
	for name, index in names {
		last := index == len(names) - 1
		fmt.eprintf("%s`%s`%s", last ? "or " : "", name, last ? "\n" : len(names) == 2 ? " " : ", ")
	}
	return 0, false
}

// A flag naming a member of `E` in lower case, so the spellings the flag
// accepts follow the enum.
@(private = "file")
enum_choice :: proc($E: typeid, flag, value: string) -> (E, bool) where intrinsics.type_is_enum(E) {
	names := reflect.enum_field_names(E)
	lowered := make([]string, len(names), context.temp_allocator)
	for name, index in names {
		lowered[index] = strings.to_lower(name, context.temp_allocator)
	}
	index, ok := choice(flag, value, ..lowered)
	return E(index), ok
}

@(private = "file")
parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts.config = DEFAULT_COMPILATION_CONFIG
	build_mode_written := false
	next_arg: for i := 0; i < len(args); i += 1 {
		arg := args[i]
		for flag, action in ACTION_FLAGS {
			if flag != "" && flag == arg {
				if opts.action != .Build && opts.action != action {
					fmt.eprintfln("error: %s and %s cannot be combined", ACTION_FLAGS[opts.action], flag)
					return opts, false
				}
				opts.action = action
				continue next_arg
			}
		}
		switch {
		case arg == "-h", arg == "-help", arg == "--help":
			opts.action = .Help
			return opts, true
		case arg == "-version", arg == "--version":
			opts.action = .Version
			return opts, true
		case arg == "-o":
			i += 1
			if i >= len(args) {
				fmt.eprintln("error: -o needs a path")
				return opts, false
			}
			opts.emission.output = args[i]
		case arg == "-emit-ll":     opts.emission.emit_ll = true
		case arg == "-keep-temps":  opts.emission.keep_temps = true
		case arg == "-test":        opts.run_tests = true
		case arg == "-g":           opts.config.debug_info = true
		case arg == "-debug":       opts.config.debug = true
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
			opts.config.panic_unwind = (choice("-panic", arg[len("-panic="):], "unwind", "abort") or_return) == 0
		case strings.has_prefix(arg, "-opt="):
			opts.config.opt_mode = enum_choice(Opt_Mode, "-opt", arg[len("-opt="):]) or_return
		case strings.has_prefix(arg, "-cpu="):
			cpu, known := parse_cpu_level(arg[len("-cpu="):])
			if !known {
				fmt.eprintln("error: -cpu needs `x86-64`, `x86-64-v2`, or `x86-64-v3`")
				return opts, false
			}
			opts.config.cpu = cpu
		case strings.has_prefix(arg, "-log-level="):
			opts.config.log_level = enum_choice(Log_Level, "-log-level", arg[len("-log-level="):]) or_return
		case strings.has_prefix(arg, "-build-mode="):
			opts.config.build_mode = enum_choice(Build_Mode, "-build-mode", arg[len("-build-mode="):]) or_return
			build_mode_written = true
		case strings.has_prefix(arg, "-runtime="):
			opts.emission.runtime_dir = arg[len("-runtime="):]
			if opts.emission.runtime_dir == "" {
				fmt.eprintln("error: -runtime needs a directory")
				return opts, false
			}
		case strings.has_prefix(arg, "-copy-cost="):
			text := arg[len("-copy-cost="):]
			if text == "off" {
				opts.config.copy_cost_enabled = false
				continue
			}
			value, parsed := strconv.parse_u64(text)
			if !parsed {
				fmt.eprintln("error: -copy-cost needs a byte count or `off`")
				return opts, false
			}
			opts.config.copy_cost_threshold, opts.config.copy_cost_enabled = value, true
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

	if opts.run_tests {
		if build_mode_written && opts.config.build_mode != .Test {
			fmt.eprintln("error: -test builds a test executable, so it takes no other -build-mode")
			return opts, false
		}
		opts.config.build_mode = .Test
	}
	if root, is_tree := tree_root(opts.input); is_tree {
		if opts.action != .Build || opts.config.build_mode != .Test {
			fmt.eprintfln("error: a tree input `%s` needs -test or -build-mode=test", opts.input)
			return opts, false
		}
		opts.tree = root
	}
	return opts, opts.action == .Print_Toolchain || opts.input != ""
}

// Directories keep their final component; files shed their extension. `.`, `..`
// and a bare volume name no component until resolved, and a root has none.
default_output_path :: proc(input: string, mode: Build_Mode) -> string {
	stem := strings.trim_suffix(input, filepath.ext(input))
	if os.is_dir(input) {
		stem = strings.trim_right(input, "/\\")
		base := filepath.base(stem)
		if stem == "" || base == "." || base == ".." || stem == filepath.volume_name(input) {
			absolute, err := filepath.abs(input, context.temp_allocator)
			if err != nil {
				return ""
			}
			stem = strings.trim_right(absolute, "/\\")
		}
		if stem == "" || stem == filepath.volume_name(stem) {
			return ""
		}
	}
	extension := ".exe"
	#partial switch mode {
	case .Obj:  extension = ".obj"
	case .Test: extension = ".test.exe"
	}
	return strings.concatenate({stem, extension}, context.temp_allocator)
}
