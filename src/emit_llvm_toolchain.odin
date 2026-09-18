// Artifact writing, clang/NASM invocation, host discovery, and layout probes.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import os2 "core:os/os2"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

CLANG_MISSING :: "cannot run `%s`: install LLVM (`winget install LLVM.LLVM`) or set LOKE_CLANG"

emit_package :: proc(c: ^Compiler, opts: Options) -> int {
	context.allocator = virtual.arena_allocator(&c.emission_arena)
	module, generated := emit_llvm_module(c)
	if !generated {
		return 2
	}
	ll_path := replace_ext(opts.output, ".ll")
	if !os.write_entire_file(ll_path, transmute([]u8)module) {
		errorf(c, no_span(), "L0401", "cannot write `%s`", ll_path)
		return 2
	}
	if opts.emit_ll {
		fmt.printfln("wrote %s", ll_path)
		return 0
	}
	// With `-o <path>.ll` the module is the artifact, so it must stay.
	defer if !opts.keep_temps && ll_path != opts.output {
		os.remove(ll_path)
	}

	if c.build_mode == .Obj {
		return compile_object(c, ll_path, opts.output, opts)
	}
	return link(c, ll_path, opts.output, opts)
}

// design.md "Build modes": one relocatable object, with runtime and foreign
// references left for the C host's final link. Assembly can't ride along.
@(private = "file")
compile_object :: proc(c: ^Compiler, ll_path: string, obj_path: string, opts: Options) -> int {
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
	command := []string{clang, "-c", ll_path, "-o", obj_path, opt_clang_flag(opts.opt_mode), "-Wno-override-module"}
	state, _, stderr, err := os2.process_exec(os2.Process_Desc{command = command}, context.allocator)
	if err != nil {
		errorf(c, no_span(), "L0402", CLANG_MISSING, clang)
		return 2
	}
	if state.exit_code != 0 {
		errorf(c, no_span(), "L0403", "`%s -c` failed:\n%s", clang, string(stderr))
		return 2
	}
	return 0
}

@(private = "file")
NASM :: "nasm -f win64"

// design.md "Foreign system": the command an assembly import needs, or "" for a
// library. clang assembles `.s`/`.S` itself during the link.
@(private = "file")
assembler_for :: proc(path: string) -> string {
	switch strings.to_lower(filepath.ext(path)) {
	case ".asm":
		return NASM
	case ".s":
		return "clang -c"
	}
	return ""
}

// ------------------------------------------------------- layout agreement --

// One number the checker claims and LLVM can be made to compute.
@(private = "file")
Layout_Probe :: struct {
	description: string,
	llvm:        string, // a constant expression that evaluates to the number
	expected:    u64,
}

// `-check-layout`: runs a module printing LLVM's size, alignment, and field
// offsets for every type and compares them with the checker's layout.
check_layout_agreement :: proc(c: ^Compiler, opts: Options) -> int {
	context.allocator = virtual.arena_allocator(&c.emission_arena)
	e := make_emitter(c)
	fmt.sbprintfln(&e.b, `target triple = "%s"`, c.target.triple)
	fmt.sbprintln(&e.b, `@.fmt_int = private unnamed_addr constant [6 x i8] c"%lld\0A\00"`)
	fmt.sbprintln(&e.b, "declare i32 @printf(ptr, ...)")
	// The seed runtime calls this on thread detach.
	fmt.sbprintln(&e.b, "define void @loke_rt_v1_program_tls_cleanup() { ret void }")
	emit_carrier_types(&e)
	emit_struct_definitions(&e)

	probes := make([dynamic]Layout_Probe)
	for index in 0 ..< len(c.types) {
		type := Type_Id(index)
		if !layout_probeable(c, type) {
			continue
		}
		llvm := llvm_type(&e, type)
		name := type_name(c, type)
		append(&probes, Layout_Probe {
			description = fmt.aprintf("size_of(%s)", name),
			llvm        = fmt.aprintf("ptrtoint (ptr getelementptr (%s, ptr null, i64 1) to i64)", llvm),
			expected    = type_size(c, type),
		})
		// LLVM has no `alignof`; the offset of `T` in `{ i8, T }` is its alignment.
		append(&probes, Layout_Probe {
			description = fmt.aprintf("align_of(%s)", name),
			// `{` is a format directive to core:fmt, so this one is concatenated.
			llvm        = strings.concatenate(
				{"ptrtoint (ptr getelementptr ({ i8, ", llvm, " }, ptr null, i64 0, i32 1) to i64)"},
			),
			expected    = type_align(c, type),
		})
		info := type_of(c, type)
		if info.kind != .Struct {
			continue
		}
		for field, position in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil {
				continue
			}
			append(&probes, Layout_Probe {
				description = fmt.aprintf("offset_of(%s, %s)", name, identifier_text(c, symbol.name)),
				llvm        = fmt.aprintf("ptrtoint (ptr getelementptr (%s, ptr null, i64 0, i32 %d) to i64)", llvm, position),
				expected    = type_field_offset(c, type, position),
			})
		}
	}

	fmt.sbprintln(&e.b, "define i32 @main() {")
	fmt.sbprintln(&e.b, "entry:")
	for probe in probes {
		fmt.sbprintfln(&e.b, "  call i32 (ptr, ...) @printf(ptr @.fmt_int, i64 %s)", probe.llvm)
	}
	fmt.sbprintln(&e.b, "  ret i32 0")
	fmt.sbprintln(&e.b, "}")

	ll_path := replace_ext(opts.output, ".layout.ll")
	if !os.write_entire_file(ll_path, transmute([]u8)strings.to_string(e.b)) {
		errorf(c, no_span(), "L0401", "cannot write `%s`", ll_path)
		return 2
	}
	defer if !opts.keep_temps {
		os.remove(ll_path)
	}
	if code := link(c, ll_path, opts.output, opts); code != 0 {
		return code
	}
	defer if !opts.keep_temps {
		os.remove(opts.output)
	}

	state, stdout, _, err := os2.process_exec(
		os2.Process_Desc{command = []string{opts.output}},
		context.allocator,
	)
	if err != nil || state.exit_code != 0 {
		errorf(c, no_span(), "L0405", "cannot run the layout probe")
		return 2
	}
	text, _ := strings.replace_all(string(stdout), "\r\n", "\n")
	lines := strings.split_lines(strings.trim_space(text))
	if len(lines) != len(probes) {
		errorf(c, no_span(), "L0405", "the layout probe produced %d values, expected %d", len(lines), len(probes))
		return 2
	}
	disagreements := 0
	for probe, index in probes {
		actual, parsed := strconv.parse_u64(strings.trim_space(lines[index]))
		if !parsed || actual != probe.expected {
			errorf(
				c,
				no_span(),
				"L0405",
				"%s: the checker says %d, LLVM says %s",
				probe.description,
				probe.expected,
				lines[index],
			)
			disagreements += 1
		}
	}
	if disagreements > 0 {
		return 1
	}
	fmt.printfln("%d layout facts agree with LLVM", len(probes))
	return 0
}

// A type that lowers to a real LLVM type and holds a runtime value.
@(private = "file")
layout_probeable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := type_of(c, type)
	if info == nil || !type_is_supported(c, type) {
		return false
	}
	// A generic record's shell has no emitted definition.
	if sym := symbol_of(c, info.symbol); sym != nil && sym.generic {
		return false
	}
	#partial switch info.kind {
	case .Bool, .Int, .Float, .Rune, .Raw_Pointer, .Pointer, .Proc, .Enum, .Array, .Struct,
	     .Distinct, .Union, .Slice, .Allocator, .Allocator_Error,
	     .Dynamic_Array, .Map:
		return true
	}
	return false
}

replace_ext :: proc(path: string, ext: string) -> string {
	// A dot in a parent directory isn't this file's extension.
	separator := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	if i := strings.last_index_byte(path, '.'); i > separator {
		return strings.concatenate({path[:i], ext})
	}
	return strings.concatenate({path, ext})
}

// The bundled runtime's objects, compiled once per optimization mode (the host
// is the only target) and reused by later links. A custom `-runtime=<dir>` is
// never written to. A new set is compiled in a private staging directory and
// renamed into place, so no link sees a partial set.
@(private = "file")
prebuilt_runtime_objects :: proc(runtime_dir: string, sources: []string, opts: Options) -> []string {
	if opts.runtime_dir != "" {
		return nil
	}
	dir := filepath.join({runtime_dir, "prebuilt", fmt.tprintf("%v", opts.opt_mode)})
	objects := make([]string, len(sources))
	for source, index in sources {
		objects[index] = filepath.join({dir, replace_ext(filepath.base(source), ".o")})
	}
	if prebuilt_current(runtime_dir, objects) {
		return objects
	}
	staging := filepath.join({runtime_dir, "prebuilt", fmt.tprintf(".staging-%d", os2.get_pid())})
	defer os2.remove_all(staging)
	if os2.make_directory_all(staging) != nil {
		return nil
	}
	if !compile_runtime_sources(runtime_dir, sources, staging, opts) {
		return nil
	}
	if os2.rename(staging, dir) != nil {
		// A concurrent link that installed first may be using its set: keep it.
		if prebuilt_current(runtime_dir, objects) {
			return objects
		}
		os2.remove_all(dir)
		if os2.rename(staging, dir) != nil {
			return nil
		}
	}
	return objects
}

// Every object present and no older than any runtime source or header.
@(private = "file")
prebuilt_current :: proc(runtime_dir: string, objects: []string) -> bool {
	newest: time.Time
	for pattern in ([]string{"*.c", "*.h"}) {
		matches, err := filepath.glob(filepath.join({runtime_dir, pattern}))
		if err != nil {
			return false
		}
		for match in matches {
			stamp, stamp_err := os2.modification_time_by_path(match)
			if stamp_err != nil {
				return false
			}
			if time.diff(newest, stamp) > 0 {
				newest = stamp
			}
		}
	}
	for object in objects {
		stamp, err := os2.modification_time_by_path(object)
		if err != nil || time.diff(newest, stamp) < 0 {
			return false
		}
	}
	return true
}

// One clang process; `-c` with several inputs writes each object into the
// working directory.
@(private = "file")
compile_runtime_sources :: proc(
	runtime_dir: string,
	sources: []string,
	staging: string,
	opts: Options,
) -> bool {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, find_clang(), "-c")
	for source in sources {
		append(&command, source)
	}
	append(&command, opt_clang_flag(opts.opt_mode))
	append_c_includes(&command, runtime_dir)
	state, _, _, err := os2.process_exec(
		os2.Process_Desc{command = command[:], working_dir = staging},
		context.allocator,
	)
	// Not reported: the link then compiles the sources and clang explains.
	return err == nil && state.exit_code == 0
}

// clang does llc, the runtime's C sources, and the link in one process
// (decisions A5, A7). Outside a developer prompt it cannot find the MSVC
// toolset, so its headers and libraries are located here.
@(private = "file")
link :: proc(c: ^Compiler, ll_path: string, exe_path: string, opts: Options) -> int {
	clang := find_clang()

	runtime_dir := resolved_runtime_dir(opts)
	sources := runtime_sources(runtime_dir)
	if len(sources) == 0 {
		errorf(
			c,
			no_span(),
			"L0551",
			"no seed runtime sources in `%s`: %s",
			runtime_dir == "" ? "<unknown>" : runtime_dir,
			dir_exists(runtime_dir) \
				? "the directory holds no `.c` files" \
				: "the directory does not exist; pass `-runtime=<dir>`",
		)
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

	command := make([dynamic]string)
	append(&command, clang, ll_path, "-o", exe_path)
	append(&command, opt_clang_flag(opts.opt_mode))
	runtime_inputs := sources
	if prebuilt := prebuilt_runtime_objects(runtime_dir, sources, opts); prebuilt != nil {
		runtime_inputs = prebuilt
	}
	for input in runtime_inputs {
		append(&command, input)
	}
	for input in foreign_inputs {
		append(&command, input)
	}
	// The module's triple differs from clang's default only in the MSVC suffix.
	append(&command, "-Wno-override-module")
	// `f16` conversions need compiler-rt's helpers, which the MSVC CRT lacks.
	append(&command, "-rtlib=compiler-rt")
	// A missing header or library is left for clang to name.
	if lib, _ := msvc_lib_dir(); lib != "" {
		append(&command, "-L", lib)
	}
	append_c_includes(&command, runtime_dir)

	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = command[:]},
		context.allocator,
	)
	if err != nil {
		errorf(c, no_span(), "L0402", CLANG_MISSING, clang)
		return 2
	}
	if state.exit_code != 0 {
		// With nothing foreign linked, an undefined name is the runtime's fault.
		if len(foreign_inputs) > 0 &&
		   (strings.contains(string(stderr), "unresolved external symbol") ||
		    strings.contains(string(stderr), "undefined symbol")) {
			errorf(
				c, no_span(), "L0633",
				"a foreign link name was not found in any imported library:\n%s",
				string(stderr),
			)
			return 2
		}
		errorf(
			c, no_span(), "L0403",
			"`%s` failed (seed runtime: `%s`):\n%s",
			clang, runtime_dir, string(stderr),
		)
		return 2
	}
	return 0
}

// The C headers the runtime's sources need.
@(private = "file")
append_c_includes :: proc(command: ^[dynamic]string, runtime_dir: string) {
	append(command, "-I", runtime_dir)
	includes, _ := msvc_include_dirs()
	for include in includes {
		append(command, "-isystem", include)
	}
}

// Every active `foreign import`, in package order.
@(private = "file")
foreign_imports :: proc(c: ^Compiler) -> []^Item_Foreign_Import {
	out := make([dynamic]^Item_Foreign_Import)
	for id in package_order(c) {
		pkg := package_of(c, id)
		if pkg == nil {
			continue
		}
		for file in pkg.files {
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
			name = strings.trim_suffix(name, ".lib")
			name = strings.trim_suffix(name, ".a")
			if name != "" {
				flag := fmt.aprintf("-l%s", name)
				if !seen[flag] {
					seen[flag] = true
					append(&out, flag)
				}
			}
			continue
		}
		dir := filepath.dir(c.sources[imp.span.file].path)
		resolved := filepath.is_abs(imp.path) ? imp.path : filepath.join({dir, imp.path})
		// Windows: one file in any spelling is one link input.
		input_key := strings.concatenate({"file:", strings.to_lower(filepath.clean(resolved))})
		if seen[input_key] {
			continue
		}
		seen[input_key] = true
		if !os.is_file(resolved) {
			errorf(c, imp.span, "L0631", "cannot find the foreign import `%s`", resolved)
			ok = false
			continue
		}
		if assembler_for(resolved) == NASM {
			if obj, assembled := assemble_nasm(c, resolved, exe_path, imp.span); assembled {
				append(&out, obj)
				append(&objects, obj)
			} else {
				ok = false
			}
			continue
		}
		append(&out, resolved)
	}
	return out[:], objects[:], ok
}

@(private = "file")
assemble_nasm :: proc(c: ^Compiler, source, exe_path: string, span: Span) -> (obj: string, ok: bool) {
	nasm := os2.get_env("LOKE_NASM", context.allocator)
	if nasm == "" {
		nasm = "nasm"
	}
	obj = assembly_object_path(source, exe_path)
	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = []string{nasm, "-f", "win64", source, "-o", obj}},
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
	name := fmt.aprintf("%s.%x.obj", filepath.stem(source), path_digest(filepath.clean(source)))
	return filepath.join({filepath.dir(exe_path), name})
}

// `-print-toolchain`: the clang, MSVC toolset, and extra flags a link would use,
// one `flag=` line each in command order. `ready=no` means a link cannot run
// here. The test harness reads this instead of repeating the discovery.
print_toolchain :: proc() -> int {
	context.allocator = context.temp_allocator
	clang := find_clang()
	// A bare `clang` is only known to exist once it runs.
	_, _, _, probe := os2.process_exec(
		os2.Process_Desc{command = []string{clang, "--version"}},
		context.allocator,
	)
	fmt.printfln("clang=%s", clang)
	fmt.printfln("msvc=%s", msvc_tools_dir())

	includes, includes_complete := msvc_include_dirs()
	for include in includes {
		fmt.println("flag=-isystem")
		fmt.printfln("flag=%s", include)
	}
	lib, lib_complete := msvc_lib_dir()
	if lib != "" {
		fmt.println("flag=-L")
		fmt.printfln("flag=%s", lib)
	}

	ready := probe == nil && includes_complete && lib_complete
	fmt.printfln("ready=%s", ready ? "yes" : "no")
	return 0
}

@(private = "file")
find_clang :: proc() -> string {
	if configured := os2.get_env("LOKE_CLANG", context.allocator); configured != "" {
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

// The MSVC toolset's `lib\x64`, or "" when LIB already supplies it (complete)
// or nothing was found (incomplete).
@(private = "file")
msvc_lib_dir :: proc() -> (dir: string, complete: bool) {
	if os2.get_env("LIB", context.allocator) != "" {
		return "", true
	}
	if root := msvc_tools_dir(); root != "" {
		return filepath.join({root, "lib", "x64"}), true
	}
	return "", false
}

// The MSVC and UCRT headers, or none when INCLUDE already supplies them.
@(private = "file")
msvc_include_dirs :: proc() -> (dirs: []string, complete: bool) {
	if os2.get_env("INCLUDE", context.allocator) != "" {
		return nil, true
	}
	out := make([dynamic]string)
	root := msvc_tools_dir()
	if root != "" {
		append(&out, filepath.join({root, "include"}))
	}
	sdk := newest_containing(
		{`C:\Program Files (x86)\Windows Kits\10\Include\*`, `C:\Program Files\Windows Kits\10\Include\*`},
		"ucrt",
	)
	ucrt := sdk != "" ? filepath.join({sdk, "ucrt"}) : ""
	if ucrt != "" {
		append(&out, ucrt)
	}
	return out[:], root != "" && ucrt != ""
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
			if !os.is_dir(filepath.join({candidate, child}, context.temp_allocator)) {
				continue candidates
			}
		}
		return strings.clone(candidate)
	}
	return ""
}
