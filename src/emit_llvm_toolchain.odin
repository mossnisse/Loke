// Artifact writing, clang/NASM invocation, host discovery, and layout probes.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:os"
import "core:path/filepath"
import os2 "core:os/os2"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// Both clang seams — the object compile and the link — give the same advice.
CLANG_MISSING :: "cannot run `%s`: install LLVM (`winget install LLVM.LLVM`) or set LOKE_CLANG"

emit_package :: proc(c: ^Compiler, opts: Options) -> int {
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
	// `-o <path>.ll` makes the module's own path the output path. clang reads the
	// module before it writes over it, so the build still succeeds — but this
	// cleanup would then delete the artifact that build just produced.
	defer if !opts.keep_temps && ll_path != opts.output {
		os.remove(ll_path)
	}

	// design.md "Build modes": an object build is one relocatable
	// module. `clang -c` compiles the generated `.ll` alone; the seed runtime and
	// foreign symbols stay unresolved for the C host to supply at its final link.
	if c.build_mode == .Obj {
		return compile_object(c, ll_path, opts.output, opts)
	}
	return link(c, ll_path, opts.output, opts)
}

// The object-build compile seam: no runtime sources, no
// libraries, no entry — `clang -c` turns the module's `.ll` into one `.obj`
// with runtime and foreign references left unresolved. An assembly import
// can't ride along in a single relocatable object, so it is diagnosed with
// the instruction its final consumer needs.
@(private = "file")
compile_object :: proc(c: ^Compiler, ll_path: string, obj_path: string, opts: Options) -> int {
	for id in package_order(c) {
		pkg := package_of(c, id)
		if pkg == nil {
			continue
		}
		for file in pkg.files {
			for item in file.active_items {
				imp, is_imp := item.(^Item_Foreign_Import)
				if !is_imp {
					continue
				}
				if assembler := assembler_for(imp.path); assembler != "" {
					errorf(
						c, imp.span, "L0603",
						"an object build cannot assemble `%s`; the final consumer must assemble it with `%s` and link the result",
						imp.path, assembler,
					)
					return 2
				}
			}
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

// design.md "Foreign system": the recognized assembly extensions are `.asm`,
// `.s`, and `.S`, and this is the command each one needs. "" for anything else —
// a library file the linker takes as it is. `.asm` is NASM syntax; the GNU
// syntax of `.s`/`.S` clang assembles itself, which is why an `exe` build hands
// those straight to the link and only `.asm` goes through `assemble_nasm`.
@(private = "file")
assembler_for :: proc(path: string) -> string {
	// `to_lower` already folds `.S`.
	switch strings.to_lower(filepath.ext(path)) {
	case ".asm":
		return "nasm -f win64"
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

// `-check-layout`: builds a module that prints LLVM's own size, alignment,
// and field offsets for every type, runs it, and compares against the
// checker's cached layout. Executing LLVM-derived values tests the actual
// target backend rather than a second copy of the checker's formula.
check_layout_agreement :: proc(c: ^Compiler, opts: Options) -> int {
	e := make_emitter(c)
	fmt.sbprintfln(&e.b, `target triple = "%s"`, c.target.triple)
	fmt.sbprintln(&e.b, `@.fmt_int = private unnamed_addr constant [6 x i8] c"%lld\0A\00"`)
	fmt.sbprintln(&e.b, "declare i32 @printf(ptr, ...)")
	// The normal module supplies this detach callback. A layout probe has no Loke
	// thread-local values, but it links the same seed runtime and therefore owes
	// the runtime the no-op side of that ABI.
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
		// The offset of the second member of `{ i8, T }` is T's alignment: LLVM
		// has no `alignof`, but it does have to place that member.
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
	// `replace_all` reports whether it allocated, not whether it succeeded: it
	// hands the input straight back when there is nothing to convert, so the
	// second value must not be read as an `or_else` guard.
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

// A type whose layout LLVM can be asked about at all: it must lower to a real
// LLVM type and hold a runtime value.
@(private = "file")
layout_probeable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := type_of(c, type)
	if info == nil || !type_is_supported(c, type) {
		return false
	}
	// A generic record's own shell is a placeholder for its instances: no
	// definition is emitted for it, so LLVM has no layout to be asked about.
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
	// A dot in a parent directory isn't this file's extension. Preserving the
	// spelling otherwise also keeps an extensionless output from moving to a
	// different directory when deriving its `.ll` companion.
	separator := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	if i := strings.last_index_byte(path, '.'); i > separator {
		return strings.concatenate({path[:i], ext})
	}
	return strings.concatenate({path, ext})
}

// The bundled seed runtime's objects, compiled once per optimization mode and
// reused by every later link. Recompiling the nine C sources is where a build
// actually spends its time: 550ms of an 800ms `-O0` link and 800ms at `-O3`,
// against a 31ms front end.
//
// The mode is the whole key because the host is the only target — nothing passes
// `-target`, so one `-O` flag is all that varies between two links. A driver
// that learns to cross-compile has to name the triple here as well.
//
// A custom `-runtime=<dir>` always compiles from source. The cache lives inside
// the runtime directory, and that tree belongs to whoever named it: it was given
// to be read, not written to.
//
// A set older than any source is ignored rather than repaired, so editing the
// runtime costs the speedup and never correctness. Population compiles into a
// process-unique directory and renames it into place, so a concurrent link
// cannot observe a half-written set; the loser of that race discards its own
// copy and uses the winner's.
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
	// Covers every failing return below, and is a no-op once the rename succeeded.
	defer os2.remove_all(staging)
	if os2.make_directory_all(staging) != nil {
		return nil
	}
	if !compile_runtime_sources(runtime_dir, sources, staging, opts) {
		return nil
	}
	if os2.rename(staging, dir) != nil {
		// Either a concurrent link installed this set first, or a stale one is in
		// the way. Losing the replacement is safe: a reader holding an object open
		// keeps it, and this link then compiles from source as it always did.
		os2.remove_all(dir)
		if os2.rename(staging, dir) != nil {
			return nil
		}
	}
	return objects
}

// Every object present and no older than every runtime source. The headers count
// too: all nine sources include `loke_rt.h`, so a header-only edit has to
// invalidate the set as well.
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

// One clang process for all nine sources. `-c` with several inputs writes each
// object beside its own name in the working directory, which is why the staging
// directory is passed as that rather than through a per-file `-o`.
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
	append(&command, opt_clang_flag(opts.opt_mode), "-I", runtime_dir)
	includes, _ := msvc_include_dirs()
	for include in includes {
		append(&command, "-isystem", include)
	}
	state, _, _, err := os2.process_exec(
		os2.Process_Desc{command = command[:], working_dir = staging},
		context.allocator,
	)
	// Nothing is reported here. A runtime that cannot be precompiled is not a
	// failed build: the caller links the sources instead, which is what diagnoses
	// a genuinely broken runtime tree, with clang's own message.
	return err == nil && state.exit_code == 0
}

// clang does llc + link + CRT startup in one process (decision A5, A7). It
// finds the Windows SDK itself but computes a relative, unusable
// VCToolsInstallDir outside a developer prompt, so the CRT import libraries
// are located here. The seed runtime's C sources join the same invocation:
// one object-and-link seam already existed, and compiling the runtime here
// keeps it in step with the module beside it.
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

	// design.md "Foreign system": every active foreign import joins the link
	// command, libraries and assembled objects alike. A missing
	// file or assembler is diagnosed here, by name, before clang runs.
	foreign_inputs, assembly_temporaries, foreign_ok := collect_foreign_link_inputs(c, exe_path)
	// The assembler's objects exist only to reach the command below. Removing
	// them from one `defer` rather than at each `return` also covers a collection
	// that assembled some inputs and then failed on a later one.
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
	// design.md "Build configuration": the selected optimization mode maps to one
	// `-O` flag on the single clang invocation.
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
	append(&command, "-I", runtime_dir)
	// The module states its triple; clang's default carries an MSVC version
	// suffix, and the mismatch is not interesting.
	append(&command, "-Wno-override-module")
	// `f16` arithmetic lowers to the compiler-rt conversion helpers
	// (`__extendhfsf2`, `__truncsfhf2`) on x86-64 without F16C, and the MSVC CRT
	// does not provide them.
	append(&command, "-rtlib=compiler-rt")
	// Incompleteness is not diagnosed here: clang names the header or library it
	// could not find, which beats anything this could say before running it.
	if lib, _ := msvc_lib_dir(); lib != "" {
		append(&command, "-L", lib)
	}
	includes, _ := msvc_include_dirs()
	for include in includes {
		append(&command, "-isystem", include)
	}

	state, _, stderr, err := os2.process_exec(
		os2.Process_Desc{command = command[:]},
		context.allocator,
	)
	if err != nil {
		errorf(c, no_span(), "L0402", CLANG_MISSING, clang)
		return 2
	}
	if state.exit_code != 0 {
		// design.md "Foreign system": an unresolved link name is its own failure —
		// the binding named a symbol the libraries do not define. With nothing
		// foreign linked it cannot be that: a stale or partial `-runtime` tree
		// leaves the `loke_rt_v1_*` names undefined too, and that belongs to the
		// seed runtime L0403 names rather than to the program's bindings.
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

// design.md "Foreign system": every active `foreign import` becomes a link
// input. A `system:` prefix passes the bare name to the linker's search path; a
// relative path resolves against the importing file. `.s`/`.S` go to clang,
// `.asm` is assembled by `nasm`, and anything else is a library file. The
// inputs are deduplicated and returned in a deterministic order. The objects
// `nasm` produced come back separately as well: they are this link's
// temporaries, and only the caller knows when the command that reads them has
// run.
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
	for id in package_order(c) {
		pkg := package_of(c, id)
		if pkg == nil {
			continue
		}
		for file in pkg.files {
			for item in file.active_items {
				imp, is_imp := item.(^Item_Foreign_Import)
				if !is_imp || imp.path == "" {
					continue
				}
				if strings.has_prefix(imp.path, "system:") {
					// A bare library name for the linker's own search path. clang finds
					// it through `-l<name>`; a `.lib`/`.a` suffix is dropped so the
					// linker adds its own.
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
				// The v1 target is Windows: alternate separator/case spellings of one
				// file are one link input, just as they are one package identity.
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
				ext := strings.to_lower(filepath.ext(resolved))
				if ext == ".asm" {
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
		}
	}
	return out[:], objects[:], ok
}

// Assembles a `.asm` input with `nasm` for the Windows x64 object format. A
// missing or failing assembler is L0632 — the assembler-specific diagnostic.
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

// Two packages may each import `helper.asm`. NASM runs before the final clang
// link, so a basename-only temporary lets the later source overwrite the
// earlier one. A stable hash of the canonical, case-folded Windows path keeps
// those objects distinct while deduplicating alternate spellings of one file.
assembly_object_path :: proc(source, exe_path: string) -> string {
	name := fmt.aprintf("%s.%x.obj", filepath.stem(source), path_digest(filepath.clean(source)))
	return filepath.join({filepath.dir(exe_path), name})
}

// `-print-toolchain`: what the link above would use on this machine — the
// clang it resolved, the MSVC toolset it picked, and the flags it would add,
// one `flag=` line each in command order so a caller passes them through
// without having to know what any of them mean. `ready=no` says a link would
// not get off the ground here: no runnable clang, or a piece of the toolset
// missing that the environment does not already supply.
//
// The test harness is the other caller. It is a separate package and cannot
// call the discovery below, so it used to keep a second copy of these rules,
// and that copy drifting looser made an object-build test skip — or fail — on
// a machine where a real build worked.
print_toolchain :: proc() -> int {
	clang := find_clang()
	// `find_clang` falls back to a bare name for PATH to resolve, so running it
	// is the only way to learn whether it is there.
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

	// Each half reports for itself, having already taken its own environment
	// variable into account.
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

// The MSVC toolset's `lib\x64`, or "" when there is nothing to add: a developer
// prompt has already put it in LIB, which lld-link honours.
//
// `complete` separates the two reasons for "": nothing to add because the
// environment supplies it, and nothing to add because there was nothing to
// find. Only the second means a link cannot run here, and a caller reporting
// on the host cannot tell them apart from the path alone.
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

// The C headers the seed runtime includes: the MSVC toolset's own, and the
// Windows SDK's UCRT. Empty in a developer prompt, whose INCLUDE clang honours.
//
// Only the runtime's `.c` inputs need these — a generated `.ll` includes
// nothing — so they arrived with M6a rather than with the original link seam.
// `complete` is both of them, for the same reason `msvc_lib_dir` reports one:
// a short list does not say which half is missing, and counting the entries to
// find out would break the moment a third directory belongs here.
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
	ucrt := newest_match(
		`C:\Program Files (x86)\Windows Kits\10\Include\*\ucrt`,
		`C:\Program Files\Windows Kits\10\Include\*\ucrt`,
	)
	if ucrt != "" {
		append(&out, ucrt)
	}
	return out[:], root != "" && ucrt != ""
}

// `...\VC\Tools\MSVC\<version>`, the root both the libraries and the headers
// hang off. A toolset must hold both to be a candidate: a build-tools
// installation can ship headers with no `lib\x64`, and mixing its headers with
// another version's libraries is worse than not finding it at all.
@(private = "file")
msvc_tools_dir :: proc() -> string {
	// `newest_matches` allocates through the caller's context. Do not retain
	// one compiler instance's result in process-wide storage.
	for candidate in newest_matches(
		`C:\Program Files\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*`,
		`C:\Program Files (x86)\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*`,
	) {
		if os.is_dir(filepath.join({candidate, "include"})) &&
		   os.is_dir(filepath.join({candidate, "lib", "x64"})) {
			return candidate
		}
	}
	return ""
}

@(private = "file")
newest_match :: proc(patterns: ..string) -> string {
	all := newest_matches(..patterns)
	return len(all) == 0 ? "" : all[0]
}

// ponytail: a glob and a string compare instead of vswhere.exe. Orders by the
// last path element, which sorts real MSVC and SDK version numbers correctly
// today and keeps a newer toolset under `Program Files` from losing to an older
// one under `(x86)`. Switch to vswhere if that ever stops holding, or if a build
// needs a specific toolset.
@(private = "file")
newest_matches :: proc(patterns: ..string) -> []string {
	found := make([dynamic]string)
	for pattern in patterns {
		matches, err := filepath.glob(pattern)
		if err != nil {
			continue
		}
		append(&found, ..matches)
	}
	slice.sort_by(found[:], proc(a, b: string) -> bool {
		return filepath.base(a) > filepath.base(b)
	})
	return found[:]
}
