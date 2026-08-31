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

// Both clang seams — the object compile and the link — give the same advice.
CLANG_MISSING :: "cannot run `%s`: install LLVM (`winget install LLVM.LLVM`) or set LOKE_CLANG"

emit_package :: proc(c: ^Compiler, package_id: Package_Id, opts: Options) -> int {
	module, generated := emit_llvm_module(c, package_id)
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
	defer if !opts.keep_temps {
		os.remove(ll_path)
	}

	// design.md "Build modes" (m7-plan step 5): an object build is one relocatable
	// module. `clang -c` compiles the generated `.ll` alone; the seed runtime and
	// foreign symbols stay unresolved for the C host to supply at its final link.
	if c.build_mode == .Obj {
		return compile_object(c, ll_path, opts.output, opts)
	}
	return link(c, ll_path, opts.output, opts)
}

// The object-build compile seam (m7-plan step 5): no runtime sources, no
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
				if strings.to_lower(filepath.ext(imp.path)) == ".asm" {
					errorf(
						c, imp.span, "L0603",
						"an object build cannot assemble `%s`; the final consumer must assemble it with `nasm -f win64` and link the result",
						imp.path,
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
	e := Emitter {
		c            = c,
		names        = make(map[Symbol_Id]string),
		struct_names = make(map[Type_Id]string),
		place_align  = make(map[string]u64),
		cleanups     = make([dynamic]Cleanup_Scope),
		param_values = make(map[Symbol_Id]string),
		pending      = make([dynamic]string),
		pending_thunks = make([dynamic]string),
		container_ops = make(map[Type_Id]string),
		container_thunks = make(map[string]bool),
		messages     = make(map[string]string),
		literals     = make(map[string]string),
		globals      = make([dynamic]string),
	}
	strings.builder_init(&e.b)
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
	lines := strings.split_lines(strings.trim_space(strings.replace_all(string(stdout), "\r\n", "\n") or_else ""))
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
	// command, libraries and assembled objects alike (m7-plan step 4). A missing
	// file or assembler is diagnosed here, by name, before clang runs.
	foreign_inputs, foreign_ok := collect_foreign_link_inputs(c, exe_path)
	if !foreign_ok {
		return 2
	}

	command := make([dynamic]string)
	append(&command, clang, ll_path, "-o", exe_path)
	// design.md "Build configuration": the selected optimization mode maps to one
	// `-O` flag on the single clang invocation (m7-plan decision "Release output").
	append(&command, opt_clang_flag(opts.opt_mode))
	for source in sources {
		append(&command, source)
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
	if lib := msvc_lib_dir(); lib != "" {
		append(&command, "-L", lib)
	}
	for include in msvc_include_dirs() {
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
		// the binding named a symbol the libraries do not define (m7-plan step 4).
		if strings.contains(string(stderr), "unresolved external symbol") ||
		   strings.contains(string(stderr), "undefined symbol") {
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

// design.md "Library resolution" (m7-plan step 4): every active `foreign import`
// becomes a link input. A `system:` prefix passes the bare name to the linker's
// search path; a relative path resolves against the importing file. `.s`/`.S` go
// to clang, `.asm` is assembled by `nasm`, and anything else is a library file.
// The inputs are deduplicated and returned in a deterministic order.
@(private = "file")
collect_foreign_link_inputs :: proc(c: ^Compiler, exe_path: string) -> (inputs: []string, ok: bool) {
	out := make([dynamic]string)
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
					} else {
						ok = false
					}
					continue
				}
				append(&out, resolved)
			}
		}
	}
	return out[:], ok
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
	canonical := filepath.clean(source)
	key := strings.to_lower(canonical)
	hash := u64(14695981039346656037) // FNV-1a offset basis
	for index in 0 ..< len(key) {
		hash = (hash ~ u64(key[index])) * HASH_MULTIPLIER
	}
	name := fmt.aprintf("%s.%x.obj", filepath.stem(source), hash)
	return filepath.join({filepath.dir(exe_path), name})
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
@(private = "file")
msvc_lib_dir :: proc() -> string {
	if os2.get_env("LIB", context.allocator) != "" {
		return ""
	}
	if root := msvc_tools_dir(); root != "" {
		return filepath.join({root, "lib", "x64"})
	}
	return ""
}

// The C headers the seed runtime includes: the MSVC toolset's own, and the
// Windows SDK's UCRT. Empty in a developer prompt, whose INCLUDE clang honours.
//
// Only the runtime's `.c` inputs need these — a generated `.ll` includes
// nothing — so they arrived with M6a rather than with the original link seam.
@(private = "file")
msvc_include_dirs :: proc() -> []string {
	if os2.get_env("INCLUDE", context.allocator) != "" {
		return nil
	}
	dirs := make([dynamic]string)
	if root := msvc_tools_dir(); root != "" {
		append(&dirs, filepath.join({root, "include"}))
	}
	if ucrt := newest_match(
		`C:\Program Files (x86)\Windows Kits\10\Include\*\ucrt`,
		`C:\Program Files\Windows Kits\10\Include\*\ucrt`,
	); ucrt != "" {
		append(&dirs, ucrt)
	}
	return dirs[:]
}

// `...\VC\Tools\MSVC\<version>`, the root both the libraries and the headers
// hang off. A toolset must hold both to be a candidate: a build-tools
// installation can ship headers with no `lib\x64`, and mixing its headers with
// another version's libraries is worse than not finding it at all.
@(private = "file")
msvc_tools_dir :: proc() -> string {
	@(static) cached: string
	@(static) resolved: bool
	if resolved {
		return cached
	}
	resolved = true
	for candidate in newest_matches(
		`C:\Program Files\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*`,
		`C:\Program Files (x86)\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*`,
	) {
		if os.is_dir(filepath.join({candidate, "include"})) &&
		   os.is_dir(filepath.join({candidate, "lib", "x64"})) {
			cached = candidate
			return cached
		}
	}
	return cached
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
