// Driver: CLI, presentation, exit codes. Compilation lives in session.odin.
//
// Exit codes: 0 success, 1 a user error (diagnostics or a bad command line),
// 2 an internal or toolchain failure.
package lokec

import "core:fmt"
import "core:mem"
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
    -keep-temps   keep the generated .ll, and any object assembled from a .asm
                  import, after linking
    -parse-only   stop after lexing and parsing (file inputs only)
    -dump-ast     print a deterministic syntax tree and stop after parsing
                  (file inputs only)
    -dump-tokens  print each token's byte span and kind and stop after lexing
                  (file inputs only)
    -check-layout compare every folded size/alignment/offset with LLVM's own
    -doc          print the root package's public API as Markdown and stop
    -fmt          rewrite the input file, or a directory's .loke files, in
                  the canonical layout, and stop
    -fmt-check    list the files -fmt would change, exit 1 if there are any,
                  and stop
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
    -g            emit debug information, at any -opt level: an executable
                  gets a .pdb beside it
    -debug        set LOKE_DEBUG to true
    -build-mode=exe|obj
                  build an executable, or a relocatable object (default: exe)
    -log-level=debug|info|warning|error|off
                  the compiled LOKE_LOG_LEVEL; core:log suppresses every call
                  below it (default: debug)
`

Options :: struct {
	help:       bool,
	version:    bool,
	print_toolchain: bool,
	input:      string,
	output:     string,
	emit_ll:    bool,
	keep_temps: bool,
	parse_only: bool,
	dump_ast:   bool,
	dump_tokens: bool,
	check_layout: bool,
	doc:        bool,
	fmt:        bool,
	fmt_check:  bool,
	defines:    [dynamic]string,
	collections: [dynamic]string,
	copy_cost:         u64,
	copy_cost_enabled: bool,
	runtime_dir: string,
	panic_unwind: bool,
	opt_mode:   Opt_Mode,
	build_mode: Build_Mode,
	debug_info: bool,
	debug:      bool,
	log_level:  Log_Level,
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

// Exit status: 0 success, 1 source or configuration diagnostics, 2 invalid
// command-line usage or a backend/toolchain failure.
@(private = "file")
run :: proc() -> int {
	opts, args_ok := parse_args(os.args[1:])
	defer {
		delete(opts.defines)
		delete(opts.collections)
	}
	if opts.help {
		fmt.print(USAGE)
		return 0
	}
	if opts.version {
		fmt.printfln("lokec %s", LOKE_VERSION_STRING)
		return 0
	}
	if !args_ok {
		fmt.eprint(USAGE)
		return 2
	}
	if opts.print_toolchain {
		return print_toolchain()
	}

	s: Compilation_Session
	defer destroy_session(&s)
	c := &s.compiler
	if !init_session(&s, Compilation_Config{
		defines = opts.defines[:], collections = opts.collections[:],
		copy_cost = opts.copy_cost, copy_cost_enabled = opts.copy_cost_enabled,
		panic_unwind = opts.panic_unwind, opt_mode = opts.opt_mode,
		build_mode = opts.build_mode, debug_info = opts.debug_info,
		debug = opts.debug, log_level = opts.log_level,
	}) {
		report(c)
		return 1
	}
	if opts.fmt || opts.fmt_check {
		status := format_files(c, opts.input, opts.fmt_check)
		report(c)
		return status
	}
	if opts.parse_only || opts.dump_ast || opts.dump_tokens {
		if is_directory(opts.input) {
			mode := opts.dump_tokens ? "-dump-tokens" : opts.dump_ast ? "-dump-ast" : "-parse-only"
			fmt.eprintfln("error: %s needs a file input", mode)
			return 2
		}
		file, loaded := load_source(c, opts.input)
		if !loaded {
			report(c)
			return 1
		}
		tokens := lex(c, file)
		defer delete(tokens)
		if opts.dump_tokens {
			for token in tokens {
				fmt.printfln("%d %d %v", token.lo, token.hi, token.kind)
			}
			report(c)
			return c.error_count > 0 ? 1 : 0
		}
		ast := parse(c, file, tokens)
		defer destroy_ast(&ast)
		if opts.dump_ast {
			dump := ast_dump(&ast)
			defer delete(dump)
			fmt.print(dump)
		}
		if c.error_count > 0 {
			report(c)
			return 1
		}
		return 0
	}

	if !check_session(&s, opts.input, opts.doc) {
		report(c)
		return 1
	}
	if opts.doc {
		page := document_project(c, c.root_package)
		defer delete(page)
		fmt.print(page)
		report(c) // warnings
		return 0
	}

	emission := Emission_Options{
		output = opts.output, emit_ll = opts.emit_ll,
		keep_temps = opts.keep_temps, runtime_dir = opts.runtime_dir,
	}
	if opts.check_layout {
		code := check_layout_agreement(c, emission)
		report(c) // the disagreements themselves are diagnostics
		return code
	}

	code := emit_session(&s, emission)
	report(c) // warnings may have been produced with no error
	return code
}

@(private = "file")
parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts.copy_cost, opts.copy_cost_enabled = DEFAULT_COMPILATION_CONFIG.copy_cost, DEFAULT_COMPILATION_CONFIG.copy_cost_enabled
	opts.panic_unwind = DEFAULT_COMPILATION_CONFIG.panic_unwind
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
		case arg == "-dump-tokens":
			opts.dump_tokens = true
		case arg == "-check-layout":
			opts.check_layout = true
		case arg == "-doc":
			opts.doc = true
		case arg == "-fmt":
			opts.fmt = true
		case arg == "-fmt-check":
			opts.fmt_check = true
		case arg == "-g":
			opts.debug_info = true
		case arg == "-debug":
			opts.debug = true
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

	if opts.print_toolchain {
		return opts, true
	}
	if opts.input == "" {
		return opts, false
	}
	if opts.output == "" {
		opts.output = default_output_path(opts.input, opts.build_mode)
		if opts.output == "" {
			fmt.eprintln("error: a root directory input needs -o")
			return opts, false
		}
	}
	return opts, true
}

// Directories keep their final component; files shed their extension.
default_output_path :: proc(input: string, mode: Build_Mode) -> string {
	stem := input
	if info, err := os.stat(input, context.temp_allocator); err == nil && info.is_dir {
		trimmed := strings.trim_right(input, "/\\")
		volume := filepath.volume_name(input)
		if (trimmed == "" && input != "") ||
		   (trimmed == volume && (len(input) > len(volume) || len(volume) > 2)) {
			return ""
		}
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
	return strings.concatenate({stem, mode == .Obj ? ".obj" : ".exe"}, context.temp_allocator)
}
