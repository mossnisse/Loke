// Artifact writing, clang/NASM invocation, foreign link inputs, and host
// discovery.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "subprocess"

@(private = "file")
CLANG_MISSING :: "cannot run `%s`: install LLVM (`winget install LLVM.LLVM`) or set LOKE_CLANG"

Emission_Options :: struct {
	output:      string,
	emit_ll:     bool,
	keep_temps:  bool,
	runtime_dir: string,
}

// -------------------------------------------------------------- artifacts --

emit_package :: proc(c: ^Compiler, opts: Emission_Options) -> int {
	context.allocator = virtual.arena_allocator(&c.emission_arena)
	module, generated := emit_llvm_module(c)
	if !generated {
		return 2
	}
	ll_path := replace_ext(opts.output, ".ll")
	if !write_artifact(c, ll_path, module) {
		return 2
	}
	if opts.emit_ll {
		fmt.printfln("wrote %s", ll_path)
		return 0
	}
	// Windows paths ignore case; a temporary may name the requested artifact.
	defer if !opts.keep_temps && !strings.equal_fold(ll_path, opts.output) {
		os.remove(ll_path)
	}

	if c.build_mode == .Obj {
		return compile_object(c, ll_path, opts.output)
	}
	natvis_path := ""
	if c.natvis != "" {
		natvis_path = replace_ext(opts.output, ".natvis")
		// The linker reads the rules while it writes the executable, and MSVC
		// 14.51's cannot open one file as both (LNK1104): `-o x.natvis` moves
		// them aside.
		if strings.equal_fold(natvis_path, opts.output) {
			natvis_path = strings.concatenate({opts.output, ".natvis"})
		}
		if !write_artifact(c, natvis_path, c.natvis) {
			return 2
		}
	}
	defer if !opts.keep_temps && natvis_path != "" {
		os.remove(natvis_path)
	}
	return link(c, ll_path, natvis_path, opts.output, opts)
}

@(private)
write_artifact :: proc(c: ^Compiler, path, text: string) -> bool {
	if os.write_entire_file(path, transmute([]u8)text) != nil {
		errorf(c, NO_SPAN, "L0401", "cannot write `%s`", path)
		return false
	}
	return true
}

// design.md "Build modes": one relocatable object, with runtime and foreign
// references left for the C host's final link. Assembly can't ride along.
@(private = "file")
compile_object :: proc(c: ^Compiler, ll_path: string, obj_path: string) -> int {
	for imp in foreign_imports(c) {
		if assembler := assembler_for(imp.path); assembler != "" {
			errorf(
				c, imp.span, "L0603",
				"an object build cannot assemble `%s`; the final consumer must assemble it with `%s` and link the result",
				imp.path, assembler,
			)
			return 2
		}
	}

	clang := find_clang()
	command := make([dynamic]string)
	append(&command, clang, "-c", ll_path, "-o", obj_path)
	append_codegen_flags(&command, c.target, c.opt_mode)
	append(&command, "-Wno-override-module")
	state, _, stderr, err := subprocess.run(os.Process_Desc{command = command[:]}, context.allocator)
	if err != nil {
		errorf(c, NO_SPAN, "L0402", CLANG_MISSING, clang)
		return 2
	}
	if state.exit_code != 0 {
		errorf(c, NO_SPAN, "L0403", "`%s -c` failed:\n%s", clang, string(stderr))
		return 2
	}
	return 0
}

// clang does llc, the runtime's C sources, and the link in one process. Outside
// a developer prompt it cannot find the MSVC toolset, so its headers and
// libraries are located here.
@(private)
link :: proc(c: ^Compiler, ll_path, natvis_path, exe_path: string, opts: Emission_Options) -> int {
	clang := find_clang()

	// `-runtime=<dir>` replaces the bundled directory outright.
	custom_runtime := opts.runtime_dir != ""
	runtime_dir := custom_runtime ? opts.runtime_dir : install_component("runtime")
	sources, listing := runtime_sources(runtime_dir)
	if len(sources) == 0 {
		reason := "the directory holds no `.c` files"
		if !os.is_dir(runtime_dir) {
			reason = "the directory does not exist; pass `-runtime=<dir>`"
		} else if listing != nil {
			reason = fmt.tprintf("the directory cannot be listed: %s", os.error_string(listing))
		}
		errorf(c, NO_SPAN, "L0551", "no seed runtime sources in `%s`: %s", runtime_dir == "" ? "<unknown>" : runtime_dir, reason)
		return 2
	}

	foreign_inputs, assembly_temporaries, foreign_ok := collect_foreign_link_inputs(c, exe_path)
	// Also covers inputs assembled before a later one failed.
	defer if !opts.keep_temps {
		for object in assembly_temporaries {
			os.remove(object)
		}
	}
	if !foreign_ok {
		return 2
	}

	includes, _ := msvc_include_dirs()
	// A custom runtime directory is never written to.
	runtime_inputs, bitcode := sources, false
	if !custom_runtime {
		runtime_inputs, bitcode = runtime_link_inputs(clang, runtime_dir, sources, includes, c.target, c.opt_mode)
	}

	command := make([dynamic]string)
	append(&command, clang, ll_path, "-o", exe_path)
	append_codegen_flags(&command, c.target, c.opt_mode)
	// The module carries its own debug information; `-g` has the linker write
	// the PDB.
	if c.debug_info {
		append(&command, "-g")
	}
	if natvis_path != "" {
		// Not `-Wl,`, which would split the path at a comma.
		append(&command, "-Xlinker", fmt.aprintf("/NATVIS:%s", natvis_path))
	}
	if bitcode {
		append(&command, "-flto", "-fuse-ld=lld")
	}
	// design.md "Windowed executables": the CRT's own entry still starts the
	// process and calls the generated `wmain`, so only the subsystem changes. A
	// test build stays a console program, whose report a terminal shows.
	if c.build_mode == .Exe && root_subsystem(c) == .Windows {
		append(&command, "-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:wmainCRTStartup")
	}
	append(&command, ..runtime_inputs)
	append(&command, ..foreign_inputs)
	// The module's triple differs from clang's default only in the MSVC suffix.
	append(&command, "-Wno-override-module")
	// `f16` conversions need compiler-rt's helpers, which the MSVC CRT lacks.
	append(&command, "-rtlib=compiler-rt")
	// A missing header or library is left for clang to name.
	lib, _ := msvc_lib_dir()
	append(&command, "-I", runtime_dir)
	append_msvc_flags(&command, includes, lib)

	state, _, stderr, err := subprocess.run(
		os.Process_Desc{command = command[:]},
		context.allocator,
	)
	if err != nil {
		errorf(c, NO_SPAN, "L0402", CLANG_MISSING, clang)
		return 2
	}
	if state.exit_code != 0 {
		// With nothing foreign linked, an undefined name is the runtime's fault.
		if len(foreign_inputs) > 0 &&
		   (strings.contains(string(stderr), "unresolved external symbol") ||
		    strings.contains(string(stderr), "undefined symbol")) {
			errorf(
				c, NO_SPAN, "L0633",
				"a foreign link name was not found in any imported library:\n%s",
				string(stderr),
			)
			return 2
		}
		errorf(
			c, NO_SPAN, "L0403",
			"`%s` failed (seed runtime: `%s`):\n%s",
			clang, runtime_dir, string(stderr),
		)
		return 2
	}
	return 0
}

// Every `*.c` file in `dir`, sorted so one directory always gives one command.
// Listed rather than globbed: a `[` in the path would be read as glob syntax.
@(private = "file")
runtime_sources :: proc(dir: string) -> (sources: []string, err: os.Error) {
	entries := os.read_all_directory_by_path(dir, context.temp_allocator) or_return
	found := make([dynamic]string, 0, len(entries))
	for entry in entries {
		if strings.has_suffix(entry.name, ".c") {
			append(&found, join_path({dir, entry.name}))
		}
	}
	slice.sort(found[:])
	return found[:], nil
}

// What every clang command that generates code passes, the module's and the
// runtime's alike.
@(private)
append_codegen_flags :: proc(command: ^[dynamic]string, target: Target_Info, opt_mode: Opt_Mode) {
	append(command, OPT_CLANG_FLAGS[opt_mode])
	append_target_flags(command, target.cpu)
}

// So the module, the runtime, and a C host compiling the runtime cannot disagree
// on the instruction set. `-ffp-contract=off` is not a default: for C, clang's
// is `on`, which fuses `a*b + c` within an expression, and for IR input the
// option still sets the backend's fusion mode (design.md "Floating-point
// operators").
@(private = "file")
append_target_flags :: proc(command: ^[dynamic]string, cpu: Cpu_Level) {
	append(command, strings.concatenate({"-march=", cpu_level_name(cpu)}, context.temp_allocator))
	append(command, "-ffp-contract=off")
}

// --------------------------------------------------------- foreign inputs --

// design.md "Foreign system": the command an assembly import needs, or "" for a
// library. clang assembles `.s`/`.S` itself during the link.
@(private = "file")
assembler_for :: proc(path: string) -> string {
	switch strings.to_lower(filepath.ext(path)) {
	case ".asm":
		return "nasm -f win64"
	case ".s":
		return "clang -c"
	}
	return ""
}

@(private = "file")
foreign_imports :: proc(c: ^Compiler) -> []^Item_Foreign_Import {
	out := make([dynamic]^Item_Foreign_Import)
	for id in package_order(c) {
		for file in package_of(c, id).files {
			for item in file.active_items {
				if imp, is_imp := item.(^Item_Foreign_Import); is_imp {
					append(&out, imp)
				}
			}
		}
	}
	return out[:]
}

// design.md "Foreign system": deduplicated link inputs. `system:name` becomes
// `-lname`, a relative path resolves against the importing file, and `.asm` is
// assembled first; those objects also come back as temporaries.
@(private = "file")
collect_foreign_link_inputs :: proc(
	c: ^Compiler,
	exe_path: string,
) -> (
	inputs: []string,
	temporaries: []string,
	ok: bool,
) {
	out := make([dynamic]string)
	objects := make([dynamic]string)
	seen := make(map[string]bool)
	ok = true
	for imp in foreign_imports(c) {
		if imp.path == "" {
			continue
		}
		if strings.has_prefix(imp.path, "system:") {
			name := imp.path[len("system:"):]
			extension := filepath.ext(name)
			if strings.equal_fold(extension, ".lib") || strings.equal_fold(extension, ".a") {
				name = strings.trim_suffix(name, extension)
			}
			if name != "" {
				flag := fmt.aprintf("-l%s", name)
				if !seen[flag] {
					seen[flag] = true
					append(&out, flag)
				}
			}
			continue
		}
		dir := path_dir(c.sources[imp.span.file].path)
		resolved := filepath.is_abs(imp.path) ? imp.path : join_path({dir, imp.path})
		// Windows: one file in any spelling is one link input.
		input_key := strings.concatenate({"file:", strings.to_lower(filepath.clean(resolved) or_else resolved)})
		if seen[input_key] {
			continue
		}
		seen[input_key] = true
		if !os.is_file(resolved) {
			errorf(c, imp.span, "L0631", "cannot find the foreign import `%s`", resolved)
			ok = false
			continue
		}
		if strings.equal_fold(filepath.ext(resolved), ".asm") {
			if obj, assembled := assemble_nasm(c, resolved, exe_path, imp.span); assembled {
				append(&out, obj)
				append(&objects, obj)
			} else {
				ok = false
			}
			continue
		}
		if extension := filepath.ext(resolved); extension != ".s" && extension != ".S" {
			warn_foreign_crt(c, imp, resolved)
		}
		append(&out, resolved)
	}
	return out[:], objects[:], ok
}

// compiler-guide.md "C runtime": an executable links the static C runtime, and
// neither link.exe nor lld-link says when an input asks for another, so the
// program would quietly hold two. A `system:` library comes from the SDK or
// the toolset, which link the same one, and is not read.
@(private = "file")
warn_foreign_crt :: proc(c: ^Compiler, imp: ^Item_Foreign_Import, path: string) {
	// Not the emission arena, which would keep a large archive to the end.
	data, err := os.read_entire_file(path, runtime.heap_allocator())
	if err != nil {
		// The linker names an input it cannot read.
		return
	}
	defer delete(data, runtime.heap_allocator())
	CRT_NAMES := [Crt_Kind]string {
		.Static        = "the static C runtime (`/MT`)",
		.Static_Debug  = "the debug static C runtime (`/MTd`)",
		.Dynamic       = "the dynamic C runtime (`/MD`)",
		.Dynamic_Debug = "the debug dynamic C runtime (`/MDd`)",
	}
	for kind in coff_requested_crts(data) - {.Static} {
		warnf(
			c, imp.span, "L0755",
			"`%s` was compiled for %s, but the executable links %s, so it would hold two C runtimes",
			path, CRT_NAMES[kind], CRT_NAMES[.Static],
		)
		add_notef(
			c, NO_SPAN,
			"link a build of the library compiled with `/MT`, or its DLL through the DLL's import library",
		)
		return
	}
}

@(private = "file")
assemble_nasm :: proc(c: ^Compiler, source, exe_path: string, span: Span) -> (obj: string, ok: bool) {
	nasm := os.get_env("LOKE_NASM", context.allocator)
	if nasm == "" {
		nasm = "nasm"
	}
	obj = assembly_object_path(source, exe_path)
	state, _, stderr, err := subprocess.run(
		os.Process_Desc{command = []string{nasm, "-f", "win64", source, "-o", obj}},
		context.allocator,
	)
	if err != nil {
		errorf(c, span, "L0632", "cannot assemble `%s`: install `nasm` on PATH or set LOKE_NASM", source)
		return "", false
	}
	if state.exit_code != 0 {
		errorf(c, span, "L0632", "`nasm` failed to assemble `%s`:\n%s", source, string(stderr))
		return "", false
	}
	return obj, true
}

// Hashing the path keeps two packages' `helper.asm` objects apart.
assembly_object_path :: proc(source, exe_path: string) -> string {
	name := fmt.aprintf("%s.%x.obj", filepath.stem(source), path_digest(filepath.clean(source) or_else source))
	return join_path({path_dir(exe_path), name})
}

// -------------------------------------------------------------- discovery --

// `-print-toolchain`: one `flag=` line per word, in command order. The test
// harness reads this instead of repeating the discovery.
print_toolchain :: proc(cpu: Cpu_Level) -> int {
	context.allocator = context.temp_allocator
	clang := find_clang()
	// A bare `clang` is only known to exist once it runs.
	_, _, _, probe := subprocess.run(
		os.Process_Desc{command = []string{clang, "--version"}},
		context.allocator,
	)
	fmt.printfln("clang=%s", clang)
	fmt.printfln("msvc=%s", msvc_tools_dir())
	fmt.printfln("lto=%s", links_runtime_bitcode(clang, .Speed) ? "yes" : "no")

	includes, includes_complete := msvc_include_dirs()
	lib, lib_complete := msvc_lib_dir()
	flags := make([dynamic]string)
	append_target_flags(&flags, cpu)
	append_msvc_flags(&flags, includes, lib)
	for flag in flags {
		fmt.printfln("flag=%s", flag)
	}

	ready := probe == nil && includes_complete && lib_complete
	fmt.printfln("ready=%s", ready ? "yes" : "no")
	return 0
}

@(private)
find_clang :: proc() -> string {
	if configured := os.get_env("LOKE_CLANG", context.allocator); configured != "" {
		return configured
	}
	candidates := []string {
		`C:\Program Files\LLVM\bin\clang.exe`,
		`C:\Program Files (x86)\LLVM\bin\clang.exe`,
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return "clang"
}

// What `msvc_include_dirs` and `msvc_lib_dir` found, as clang flags.
@(private)
append_msvc_flags :: proc(command: ^[dynamic]string, includes: []string, lib: string) {
	for include in includes {
		append(command, "-isystem", include)
	}
	if lib != "" {
		append(command, "-L", lib)
	}
}

// The MSVC toolset's `lib\x64`, or "" when LIB already supplies it (complete)
// or nothing was found (incomplete).
@(private = "file")
msvc_lib_dir :: proc() -> (dir: string, complete: bool) {
	if os.get_env("LIB", context.allocator) != "" {
		return "", true
	}
	if root := msvc_tools_dir(); root != "" {
		return join_path({root, "lib", "x64"}), true
	}
	return "", false
}

// The MSVC and UCRT headers, or none when INCLUDE already supplies them.
@(private = "file")
msvc_include_dirs :: proc() -> (dirs: []string, complete: bool) {
	if os.get_env("INCLUDE", context.allocator) != "" {
		return nil, true
	}
	out := make([dynamic]string)
	root := msvc_tools_dir()
	if root != "" {
		append(&out, join_path({root, "include"}))
	}
	sdk := newest_containing(
		{`C:\Program Files (x86)\Windows Kits\10\Include\*`, `C:\Program Files\Windows Kits\10\Include\*`},
		"ucrt",
	)
	if sdk != "" {
		append(&out, join_path({sdk, "ucrt"}))
	}
	return out[:], root != "" && sdk != ""
}

// `...\VC\Tools\MSVC\<version>`. A toolset needs both headers and libraries:
// mixing one version's headers with another's libraries is worse than none.
@(private = "file")
msvc_tools_dir :: proc() -> string {
	return newest_containing(
		{`C:\Program Files\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*`,
		 `C:\Program Files (x86)\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*`},
		"include", `lib\x64`,
	)
}

// The match with the highest version, taken from its last path element, that
// holds every child directory.
// ponytail: a glob and a string compare instead of vswhere.exe; fine for real
// MSVC and SDK version numbers today.
newest_containing :: proc(patterns: []string, children: ..string) -> string {
	found := make([dynamic]string, context.temp_allocator)
	for pattern in patterns {
		if matches, err := filepath.glob(pattern, context.temp_allocator); err == nil {
			append(&found, ..matches)
		}
	}
	slice.sort_by(found[:], proc(a, b: string) -> bool {
		return filepath.base(a) > filepath.base(b)
	})
	candidates: for candidate in found {
		for child in children {
			if !os.is_dir(join_path({candidate, child}, context.temp_allocator)) {
				continue candidates
			}
		}
		return strings.clone(candidate)
	}
	return ""
}
