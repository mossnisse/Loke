// The bundled runtime's cached objects, and how a link takes the runtime.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "subprocess"

// Beside a prebuilt set: what it was built from.
@(private = "file")
RUNTIME_MANIFEST :: "build-inputs.txt"

// In `runtime/prebuilt/`: why the latest link could not use a set. Never read
// by the compiler; it explains a slow link, and a test failure.
@(private = "file")
RUNTIME_CACHE_FAILURE :: "last-failure.txt"

// The runtime file every function of which is baseline code.
@(private = "file")
CPU_CHECK_SOURCE :: "cpu.c"

// What a link of the bundled runtime takes for it, whether that is bitcode, and
// whether it is a prebuilt set rather than the sources. Only a prebuilt set is
// bitcode: sources the link compiles itself are compiled as an unoptimized
// build's are, `cpu.c` among them.
@(private)
runtime_link_inputs :: proc(
	clang, runtime_dir: string, sources, toolchain: []string, target: Target_Info, opt_mode: Opt_Mode,
) -> (
	inputs: []string,
	bitcode: bool,
	prebuilt: bool,
) {
	bitcode = links_runtime_bitcode(clang, opt_mode)
	if objects := prebuilt_runtime_objects(runtime_dir, sources, toolchain, target, opt_mode, bitcode); objects != nil {
		return objects, bitcode, true
	}
	return sources, false, false
}

// Cached objects; see compiler-architecture.md "Runtime and library boundary".
// A set's directory is named by its manifest's hash and never modified, so
// concurrent links can share it. nil: the link compiles the sources.
// ponytail: superseded sets are left behind (about 100 KB each); a sweep
// would need to know no link still reads them.
@(private = "file")
prebuilt_runtime_objects :: proc(
	runtime_dir: string,
	sources, toolchain: []string,
	target: Target_Info,
	opt_mode: Opt_Mode,
	bitcode: bool,
) -> []string {
	commands := runtime_compile_commands(runtime_dir, sources, toolchain, target, opt_mode, bitcode)
	manifest, identified := runtime_build_manifest(runtime_dir, commands)
	if !identified {
		return runtime_cache_failed(runtime_dir, "cannot read the runtime sources in `%s`", runtime_dir)
	}
	// The manifest decides; the level and mode in the name are for a reader.
	name := fmt.tprintf("%s-%v-%16x", cpu_level_name(target.cpu), opt_mode, hash.fnv64a(transmute([]byte)manifest))
	dir := join_path({runtime_dir, "prebuilt", name})
	objects := make([]string, len(sources))
	for source, index in sources {
		objects[index] = join_path({dir, replace_ext(filepath.base(source), ".o")})
	}
	if prebuilt_current(dir, objects, manifest) {
		return objects
	}
	staging := join_path({runtime_dir, "prebuilt", fmt.tprintf(".staging-%d", os.get_pid())})
	defer remove_tree(staging)
	if err := os.make_directory_all(staging); err != nil {
		return runtime_cache_failed(runtime_dir, "cannot create `%s`: %v", staging, err)
	}
	for command in commands {
		if reason := compile_runtime_sources(command, staging); reason != "" {
			return runtime_cache_failed(runtime_dir, "%s", reason)
		}
	}
	if os.write_entire_file(join_path({staging, RUNTIME_MANIFEST}), transmute([]byte)manifest) != nil {
		return runtime_cache_failed(runtime_dir, "cannot write `%s` in `%s`", RUNTIME_MANIFEST, staging)
	}
	// A concurrent link that installed the same set first wins; either copy
	// serves.
	if err := rename_directory(staging, dir); err != nil && !prebuilt_current(dir, objects, manifest) {
		return runtime_cache_failed(runtime_dir, "cannot rename `%s` to `%s`: %v", staging, dir, err)
	}
	return objects
}

// Windows refuses to move a directory while any process holds a file in it
// open, and a scanner opens the objects clang just wrote, so a refusal is
// retried for about two seconds before the link gives up on the cache. A
// directory the link cannot write fails the same way and costs that wait. It
// also refuses when `to` exists, which no wait changes.
@(private)
rename_directory :: proc(from, to: string) -> (err: os.Error) {
	pause := 5 * time.Millisecond
	waited: time.Duration
	for {
		err = os.rename(from, to)
		if err != .Permission_Denied || waited >= 2 * time.Second || os.exists(to) {
			return
		}
		time.sleep(pause)
		waited += pause
		pause = min(2 * pause, 200 * time.Millisecond)
	}
}

@(private = "file")
runtime_cache_failed :: proc(runtime_dir: string, format: string, args: ..any) -> []string {
	reason := fmt.tprintfln(format, ..args)
	prebuilt := join_path({runtime_dir, "prebuilt"}, context.temp_allocator)
	if os.make_directory_all(prebuilt) == nil {
		_ = os.write_entire_file(join_path({prebuilt, RUNTIME_CACHE_FAILURE}, context.temp_allocator), transmute([]byte)reason)
	}
	return nil
}

// Contents are hashed because an edit can keep both size and modification time;
// a reinstall changes clang's modification time.
@(private = "file")
runtime_build_manifest :: proc(runtime_dir: string, commands: [][]string) -> (manifest: string, ok: bool) {
	b := strings.builder_make()
	for command, index in commands {
		if index > 0 {
			strings.write_byte(&b, '\n')
		}
		for word in command {
			strings.write_string(&b, word)
			strings.write_byte(&b, '\n')
		}
	}
	clang := commands[0][0]
	stamp, stamp_err := os.modification_time_by_path(clang)
	if stamp_err != nil {
		stamp, _ = os.modification_time_by_path(find_on_path(clang))
	}
	fmt.sbprintfln(&b, "clang modified %d", time.to_unix_nanoseconds(stamp))
	// clang reads it when the commands name no toolset (`msvc_toolchain_flags`).
	fmt.sbprintfln(&b, "INCLUDE %s", os.get_env("INCLUDE", context.temp_allocator))
	entries, err := os.read_all_directory_by_path(runtime_dir, context.temp_allocator)
	if err != nil {
		return "", false
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for entry in entries {
		if strings.has_suffix(entry.name, ".c") || strings.has_suffix(entry.name, ".h") {
			contents, read_err := os.read_entire_file(entry.fullpath, context.temp_allocator)
			if read_err != nil {
				return "", false
			}
			fmt.sbprintfln(&b, "%s %16x", entry.name, hash.fnv64a(contents))
		}
	}
	return strings.to_string(b), true
}

@(private = "file")
prebuilt_current :: proc(dir: string, objects: []string, manifest: string) -> bool {
	recorded, read_err := os.read_entire_file(join_path({dir, RUNTIME_MANIFEST}), context.temp_allocator)
	if read_err != nil || string(recorded) != manifest {
		return false
	}
	for object in objects {
		if !os.exists(object) {
			return false
		}
	}
	return true
}

// One clang process, and with `bitcode` a second; `-c` with several inputs
// writes each object into the working directory. A bitcode set is the runtime
// as LLVM bitcode for the link to optimize with the module, except the CPU
// check, which stays machine code so nothing of a higher level is inlined into
// it (compiler-guide.md "CPU levels").
@(private)
runtime_compile_commands :: proc(
	runtime_dir: string, sources, toolchain: []string, target: Target_Info, opt_mode: Opt_Mode, bitcode: bool,
) -> [][]string {
	compile :: proc(runtime_dir: string, sources, toolchain: []string, target: Target_Info, opt_mode: Opt_Mode, lto: bool) -> []string {
		command := make([dynamic]string, context.temp_allocator)
		append(&command, find_clang(), "-c")
		append(&command, ..sources)
		append_codegen_flags(&command, target, opt_mode)
		if lto {
			append(&command, "-flto")
		}
		append(&command, "-I", runtime_dir)
		append(&command, ..toolchain)
		return command[:]
	}
	optimized := make([dynamic]string, context.temp_allocator)
	native := make([dynamic]string, context.temp_allocator)
	for source in sources {
		append(bitcode && filepath.base(source) != CPU_CHECK_SOURCE ? &optimized : &native, source)
	}
	commands := make([dynamic][]string, context.temp_allocator)
	if len(optimized) > 0 {
		append(&commands, compile(runtime_dir, optimized[:], toolchain, target, opt_mode, true))
	}
	if len(native) > 0 {
		append(&commands, compile(runtime_dir, native[:], toolchain, target, opt_mode, false))
	}
	return commands[:]
}

// An optimized build links with lld-link when it sits beside clang, so the
// runtime, compiled to bitcode, is optimized with the module and its small
// operations can inline where they are hot. Without one the build links the
// runtime's machine code as an unoptimized build does.
@(private)
links_runtime_bitcode :: proc(clang: string, opt_mode: Opt_Mode) -> bool {
	if opt_mode == .None {
		return false
	}
	dir := path_dir(clang, context.temp_allocator)
	return dir != "" && dir != "." && os.is_file(join_path({dir, "lld-link.exe"}, context.temp_allocator))
}

// Why the sources did not compile, or "" when they did. Not reported: the link
// then compiles the sources and clang explains.
@(private = "file")
compile_runtime_sources :: proc(command: []string, staging: string) -> (reason: string) {
	state, _, stderr, err := subprocess.run(
		os.Process_Desc{command = command, working_dir = staging},
		context.temp_allocator,
	)
	if err != nil {
		return fmt.tprintf("cannot run `%s`: %v", command[0], err)
	}
	if state.exit_code != 0 {
		return fmt.tprintf("`%s` exited with %d:\n%s", command[0], state.exit_code, string(stderr))
	}
	return ""
}
