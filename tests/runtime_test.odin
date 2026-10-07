// The seed runtime as the driver links it: its C ABI against the compiler's
// LLVM spelling of it, and the reuse of its prebuilt objects.
package tests

import "core:fmt"
import "core:os"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// The compiler's carrier types and the C records they are passed as.
@(private = "file")
RUNTIME_RECORDS :: [][2]string {
	{"%loke.string", "loke_rt_string_v1"},
	{"%loke.container", "loke_rt_dynamic_v1"},
	{"%loke.container", "loke_rt_map_v1"},
	{"%loke.container_ops", "loke_rt_container_ops_v1"},
}

@(private = "file")
DEFAULT_ALLOCATOR :: "@loke_rt_v1_default_allocator"

// runtime/loke_rt.h declares each `loke_rt_v1_` function and record; the
// emitter writes its own `declare` (or, for a function the runtime calls back,
// `define`) of each, and names the records by their LLVM types. Linking checks
// neither: a parameter of the wrong width links and misbehaves. So clang lowers
// the header for the compiler's target, and each lowered signature and record
// must match the compiler's, including the attributes that change how an
// argument is passed, such as `signext` or `byval`.
@(test)
runtime_abi_matches_header :: proc(t: ^testing.T) {
	clang, flags, found := host_toolchain()
	if !found {
		skipped_capability(t, "no usable clang, so the runtime header's ABI is never lowered")
		return
	}
	os.make_directory(TMP)

	// The compiler's side: every literal runtime declaration in the emitter, and
	// the target and record types every module carries.
	compiler_signatures := make(map[string]string, context.temp_allocator)
	compiler_defines := make(map[string]bool, context.temp_allocator)
	sources, _ := filepath.glob("src/emit_llvm*.odin", context.temp_allocator)
	for source in sources {
		if strings.has_suffix(source, "_test.odin") {
			continue
		}
		text, read := os.read_entire_file(source, context.temp_allocator)
		testing.expectf(t, read, "cannot read %s", source)
		for line, index in strings.split_lines(string(text), context.temp_allocator) {
			for keyword in ([]string{"declare ", "define "}) {
				name, signature, ok := runtime_signature(line, keyword)
				if !ok {
					continue
				}
				site := fmt.tprintf("%s:%d", source, index + 1)
				formatted := strings.contains(signature, "%s") || strings.contains(signature, "%d")
				if !testing.expectf(t, !formatted, "%s: a formatted runtime signature cannot be checked", site) {
					continue
				}
				if previous, seen := compiler_signatures[name]; seen {
					testing.expectf(t, previous == signature, "%s: `%s` is `%s` here and `%s` elsewhere", site, name, signature, previous)
				}
				compiler_signatures[name] = signature
				compiler_defines[name] ||= keyword == "define "
			}
		}
	}
	if !testing.expect(t, len(compiler_signatures) > 0, "found no runtime declarations in src/emit_llvm*.odin") {
		return
	}

	state, _, stderr, err := exec(
		os2.Process_Desc {
			command = []string{compiler_path(), "examples/hello.loke", "-emit-ll", "-o", fmt.tprintf("%s/abi_module.exe", TMP)},
		},
		context.allocator,
	)
	if !testing.expectf(t, err == nil && state.exit_code == 0, "cannot emit a module:\n%s", string(stderr)) {
		return
	}
	module, module_read := os.read_entire_file(fmt.tprintf("%s/abi_module.ll", TMP), context.temp_allocator)
	if !testing.expect(t, module_read, "the emitted module is missing") {
		return
	}
	triple := ""
	compiler_types := make(map[string]string, context.temp_allocator)
	for line in strings.split_lines(string(module), context.temp_allocator) {
		name, _, body := strings.partition(line, " = ")
		switch {
		case name == "target triple":
			triple = strings.trim(body, "\"")
		case strings.has_prefix(name, "%loke.") && strings.has_prefix(body, "type "):
			compiler_types[name] = body[len("type "):]
		case name == DEFAULT_ALLOCATOR:
			_, _, compiler_types[name] = strings.partition(body, " global ")
		}
	}

	// The header's side: every function it declares that the compiler names,
	// referenced so clang lowers its declaration, and one global per record.
	header, header_read := os.read_entire_file("runtime/loke_rt.h", context.temp_allocator)
	if !testing.expect(t, header_read, "cannot read runtime/loke_rt.h") {
		return
	}
	unit := strings.builder_make(context.temp_allocator)
	strings.write_string(&unit, "#include \"loke_rt.h\"\nvoid *loke_abi_refs[] = {\n")
	unheaded := make([dynamic]string, context.temp_allocator)
	for name in compiler_signatures {
		if !strings.contains(string(header), fmt.tprintf("%s(", name)) {
			// A function the compiler defines and the runtime never calls, such as
			// `loke_rt_v1_program_init`, has no header declaration to agree with.
			testing.expectf(t, compiler_defines[name], "`%s` is declared by the compiler but not in runtime/loke_rt.h", name)
			append(&unheaded, name)
			continue
		}
		fmt.sbprintfln(&unit, "\t(void *)%s,", name)
	}
	for name in unheaded {
		delete_key(&compiler_signatures, name)
	}
	fmt.sbprintfln(&unit, "\t(void *)&%s,", DEFAULT_ALLOCATOR[1:])
	strings.write_string(&unit, "};\n")
	for record, index in RUNTIME_RECORDS {
		fmt.sbprintfln(&unit, "%s loke_abi_record_%d;", record[1], index)
	}
	unit_path := fmt.tprintf("%s/abi_unit.c", TMP)
	lowered_path := fmt.tprintf("%s/abi_unit.ll", TMP)
	_ = os.write_entire_file(unit_path, transmute([]byte)strings.to_string(unit))
	command := make([dynamic]string, context.temp_allocator)
	append(&command, clang, "-S", "-emit-llvm", "-O0", "-target", triple, "-Iruntime", unit_path, "-o", lowered_path)
	append(&command, ..flags)
	clang_state, _, clang_stderr, clang_err := exec(os2.Process_Desc{command = command[:]}, context.allocator)
	if !testing.expectf(t, clang_err == nil && clang_state.exit_code == 0, "clang cannot lower the header:\n%s", string(clang_stderr)) {
		return
	}
	lowered, lowered_read := os.read_entire_file(lowered_path, context.temp_allocator)
	if !testing.expect(t, lowered_read, "clang wrote no module") {
		return
	}

	header_signatures := make(map[string]string, context.temp_allocator)
	structs := make(map[string]string, context.temp_allocator)
	allocator_type := ""
	for line in strings.split_lines(string(lowered), context.temp_allocator) {
		if function, signature, ok := runtime_signature(line, "declare "); ok {
			header_signatures[function] = signature
			continue
		}
		name, _, body := strings.partition(line, " = ")
		switch {
		case strings.has_prefix(name, "%struct.") && strings.has_prefix(body, "type "):
			structs[name] = body[len("type "):]
		case name == DEFAULT_ALLOCATOR:
			_, _, global := strings.partition(body, " global ")
			allocator_type, _, _ = strings.partition(global, ",")
		}
	}

	for name, signature in compiler_signatures {
		lowered_signature, declared := header_signatures[name]
		if testing.expectf(t, declared, "clang declared no `%s`", name) {
			testing.expectf(
				t, signature == lowered_signature,
				"`%s`: the compiler says `%s`, the header lowers to `%s`", name, signature, lowered_signature,
			)
		}
	}
	allocator_record := flatten_struct(structs, allocator_type)
	testing.expectf(
		t, compiler_types[DEFAULT_ALLOCATOR] == allocator_record,
		"`%s`: the compiler says `%s`, the header lowers to `%s`",
		DEFAULT_ALLOCATOR, compiler_types[DEFAULT_ALLOCATOR], allocator_record,
	)
	for record in RUNTIME_RECORDS {
		c_type := flatten_struct(structs, fmt.tprintf("%%struct.%s", record[1]))
		testing.expectf(
			t, compiler_types[record[0]] == c_type,
			"`%s` is `%s`, but `%s` lowers to `%s`", record[0], compiler_types[record[0]], record[1], c_type,
		)
	}
}

// The bundled runtime's prebuilt objects are reused only by a link with the
// same C build. Naming the same clang by another spelling in `LOKE_CLANG` is a
// different build and gets a set of its own, which parallel links install
// without taking objects from one another; naming it as before reuses the
// first set. An edit to a runtime source that keeps its size and modification
// time is a different build too. A private copy of the compiler and runtime
// keeps these builds away from the objects the corpus links against.
@(test)
runtime_cache_follows_build_inputs :: proc(t: ^testing.T) {
	clang, _, found := host_toolchain()
	if !found {
		skipped_capability(t, "no usable clang, so no runtime object is ever built")
		return
	}
	root := fmt.tprintf("%s/runtime_cache", TMP)
	os2.remove_all(root)
	os2.make_directory_all(fmt.tprintf("%s/runtime", root))
	compiler := launch_path(fmt.tprintf("%s/lokec.exe", root))
	testing.expect(t, os2.copy_file(compiler, compiler_path()) == nil, "cannot copy the compiler")
	entries, _ := os2.read_all_directory_by_path("runtime", context.temp_allocator)
	for entry in entries {
		if strings.has_suffix(entry.name, ".c") || strings.has_suffix(entry.name, ".h") {
			testing.expect(t, os2.copy_file(fmt.tprintf("%s/runtime/%s", root, entry.name), entry.fullpath) == nil, "cannot copy the runtime")
		}
	}

	inherited, _ := os2.environ(context.temp_allocator)
	with_clang :: proc(inherited: []string, clang: string) -> []string {
		out := make([dynamic]string, context.temp_allocator)
		for entry in inherited {
			if !strings.has_prefix(strings.to_upper(entry, context.temp_allocator), "LOKE_CLANG=") {
				append(&out, entry)
			}
		}
		append(&out, fmt.tprintf("LOKE_CLANG=%s", clang))
		return out[:]
	}
	respelled, _ := strings.replace_all(clang, "\\", "/", context.temp_allocator)
	if respelled == clang {
		respelled, _ = strings.replace_all(clang, "/", "\\", context.temp_allocator)
	}
	// Links through the private compiler, `count` at once, and answers whether
	// every one succeeded.
	Link :: struct {
		command: []string,
		env:     []string,
		ok:      bool,
		stderr:  string,
	}
	link_all :: proc(t: ^testing.T, compiler, root: string, env: []string, count: int) -> bool {
		links := make([]Link, count, context.temp_allocator)
		threads := make([]^thread.Thread, count, context.temp_allocator)
		for &link, index in links {
			link.env = env
			// Its own array: a slice literal here would share one per iteration.
			command := make([dynamic]string, context.temp_allocator)
			append(&command, compiler, "examples/hello.loke", "-o", fmt.tprintf("%s/hello%d.exe", root, index))
			append(&command, "-collection", "base=base", "-collection", "core=core")
			link.command = command[:]
			threads[index] = thread.create_and_start_with_poly_data(&link, proc(link: ^Link) {
				state, _, stderr, err := exec(os2.Process_Desc{command = link.command, env = link.env}, context.allocator)
				link.ok, link.stderr = err == nil && state.exit_code == 0, string(stderr)
			})
		}
		all := true
		for worker, index in threads {
			thread.join(worker)
			thread.destroy(worker)
			all &&= testing.expectf(t, links[index].ok, "link %d of %d failed:\n%s", index + 1, count, links[index].stderr)
		}
		return all
	}
	// The installed sets, and when the one for `name` built its first object.
	sets :: proc(root: string) -> []os2.File_Info {
		entries, _ := os2.read_all_directory_by_path(fmt.tprintf("%s/runtime/prebuilt", root), context.temp_allocator)
		out := make([dynamic]os2.File_Info, context.temp_allocator)
		for entry in entries {
			if entry.type == .Directory && !strings.has_prefix(entry.name, ".") {
				append(&out, entry)
			}
		}
		return out[:]
	}
	built_at :: proc(set: os2.File_Info) -> time.Time {
		stamp, _ := os2.modification_time_by_path(fmt.tprintf("%s/alloc.o", set.fullpath))
		return stamp
	}
	// The installed sets' names, and why the latest link could not use one, to
	// tell a host that refused a file from a cache that chose wrongly.
	cache_state :: proc(root: string) -> string {
		names := make([dynamic]string, context.temp_allocator)
		for set in sets(root) {
			append(&names, set.name)
		}
		reason, recorded := os.read_entire_file(fmt.tprintf("%s/runtime/prebuilt/last-failure.txt", root), context.temp_allocator)
		return fmt.tprintf(
			"installed sets: [%s]; last failure: %s",
			strings.join(names[:], ", ", context.temp_allocator),
			recorded ? strings.trim_space(string(reason)) : "none recorded",
		)
	}

	if !link_all(t, compiler, root, with_clang(inherited, clang), 1) ||
	   !testing.expectf(t, len(sets(root)) == 1, "the first link did not install exactly one set; %s", cache_state(root)) {
		return
	}
	first := sets(root)[0]
	first_built := built_at(first)
	link_all(t, compiler, root, with_clang(inherited, clang), 1)
	testing.expect(t, len(sets(root)) == 1 && built_at(first) == first_built, "an unchanged build rebuilt the runtime")
	// Every link needs the new set at once, as a parallel corpus does after an
	// input changes; none may lose the objects it links against.
	link_all(t, compiler, root, with_clang(inherited, respelled), 8)
	testing.expectf(t, len(sets(root)) == 2, "a `LOKE_CLANG` of `%s` did not get a set of its own; %s", respelled, cache_state(root))
	link_all(t, compiler, root, with_clang(inherited, clang), 1)
	testing.expect(t, len(sets(root)) == 2 && built_at(first) == first_built, "returning to the first clang did not reuse its set")

	// The same bytes count and timestamp, different contents: the edited
	// formatter must be the one linked.
	format_c := fmt.tprintf("%s/runtime/format.c", root)
	format_info, stat_err := os2.stat(format_c, context.temp_allocator)
	original, read := os.read_entire_file(format_c, context.temp_allocator)
	edited, replaced := strings.replace(string(original), `"true", 4`, `"nope", 4`, 1, context.temp_allocator)
	if !testing.expect(t, stat_err == nil && read && replaced, "cannot find the formatter's `true` in the runtime copy") {
		return
	}
	testing.expect(t, os.write_entire_file(format_c, transmute([]byte)edited), "cannot edit the runtime copy")
	testing.expect(t, os2.change_times(format_c, format_info.access_time, format_info.modification_time) == nil, "cannot restore the edited source's time")
	program := fmt.tprintf("%s/prints_true.loke", root)
	_ = os.write_entire_file(program, transmute([]byte)string("package main; import \"core:fmt\"; main :: proc() { fmt.println(true); }\n"))
	exe := fmt.tprintf("%s/prints_true.exe", root)
	built, _, stderr, build_err := exec(
		os2.Process_Desc{command = []string{compiler, program, "-o", exe, "-collection", "base=base", "-collection", "core=core"}, env = with_clang(inherited, clang)},
		context.temp_allocator,
	)
	if !testing.expectf(t, build_err == nil && built.exit_code == 0, "the program did not compile against the edited runtime:\n%s", string(stderr)) {
		return
	}
	_, stdout, _, run_err := exec(os2.Process_Desc{command = []string{launch_path(exe)}}, context.temp_allocator)
	printed := strings.trim_space(string(stdout))
	testing.expectf(t, run_err == nil && printed == "nope", "an edit that kept the size and time linked the old runtime: printed `%s`; %s", printed, cache_state(root))
	testing.expectf(t, len(sets(root)) == 3, "the edited runtime did not get a set of its own; %s", cache_state(root))
}

// A `declare`/`define` of a runtime function that starts a string literal or
// an IR line: its name, and its signature with everything but the types and
// the attributes that change how an argument is passed left out.
@(private = "file")
runtime_signature :: proc(line, keyword: string) -> (name, signature: string, ok: bool) {
	start := strings.index(line, keyword)
	if start < 0 || (start > 0 && line[start - 1] != '"' && line[start - 1] != '`') {
		return
	}
	rest := line[start + len(keyword):]
	at := strings.index(rest, "@loke_rt_v1_")
	open := strings.index_byte(rest, '(')
	close := strings.index_byte(rest, ')')
	if at < 0 || open < at || close < open {
		return
	}
	params := make([dynamic]string, context.temp_allocator)
	if strings.trim_space(rest[open + 1:close]) != "" {
		for param in strings.split(rest[open + 1:close], ",", context.temp_allocator) {
			append(&params, abi_parts(param))
		}
	}
	joined := strings.join(params[:], ", ", context.temp_allocator)
	return rest[at + 1:open], fmt.tprintf("%s (%s)", abi_parts(rest[:at]), joined), true
}

@(private = "file")
abi_parts :: proc(text: string) -> string {
	kept := make([dynamic]string, context.temp_allocator)
	for word in strings.fields(text, context.temp_allocator) {
		is_integer := len(word) > 1 && word[0] == 'i' && strings.trim_left(word[1:], "0123456789") == ""
		switch {
		case word == "ptr" || word == "void" || word == "float" || word == "double" || is_integer,
		     word == "signext" || word == "zeroext" || word == "inreg",
		     strings.has_prefix(word, "byval(") || strings.has_prefix(word, "sret(") || strings.has_prefix(word, "byref("),
		     strings.has_prefix(word, "inalloca("):
			append(&kept, word)
		}
	}
	return strings.join(kept[:], " ", context.temp_allocator)
}

// A clang struct type with every named struct in it spelled out, as the
// compiler writes a record.
@(private = "file")
flatten_struct :: proc(structs: map[string]string, type: string) -> string {
	body, named := structs[type]
	if !named {
		return type
	}
	out := strings.builder_make(context.temp_allocator)
	for word in strings.fields(body, context.temp_allocator) {
		field := strings.trim_suffix(word, ",")
		if strings.builder_len(out) > 0 {
			strings.write_string(&out, " ")
		}
		strings.write_string(&out, flatten_struct(structs, field))
		if len(field) < len(word) {
			strings.write_string(&out, ",")
		}
	}
	return strings.to_string(out)
}
