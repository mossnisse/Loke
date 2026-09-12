// Installation-relative discovery.
//
// The seed runtime and the bundled `base`/`core` roots ship beside the
// compiler, so they resolve from the canonical `lokec.exe` path rather than
// the current directory: a compiler invoked from anywhere — test harness,
// installed copy — finds the same files.
package lokec

import "core:os"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:slice"

// The directory holding the running compiler, or "" when the platform cannot
// say. Callers treat "" as "no bundled component", which is diagnosed at the
// point something actually needs one.
install_dir :: proc() -> string {
	// The result is allocated by the caller's context allocator. Caching it in
	// process-wide storage would let one compiler instance retain another
	// instance's allocation and would make initialization race between tests.
	if dir, err := os2.get_executable_directory(context.allocator); err == nil {
		return dir
	}
	return ""
}

// A component bundled beside the compiler: `runtime`, `base`, `core`.
install_component :: proc(name: string) -> string {
	dir := install_dir()
	if dir == "" {
		return ""
	}
	// `install_dir` allocates, and only the joined path outlives this call.
	defer delete(dir)
	return filepath.join({dir, name})
}

// Every `*.c` input of the seed runtime, sorted, so one directory always
// produces one command. An empty result means no sources — the caller reports
// that with the resolved path, since a wrong `-runtime` and a missing
// installation look the same from inside the linker.
runtime_sources :: proc(dir: string) -> []string {
	if dir == "" {
		return nil
	}
	matches, err := filepath.glob(filepath.join({dir, "*.c"}))
	if err != nil {
		return nil
	}
	slice.sort(matches)
	return matches
}

// `-runtime=<dir>` replaces the bundled directory outright.
resolved_runtime_dir :: proc(opts: Options) -> string {
	if opts.runtime_dir != "" {
		return opts.runtime_dir
	}
	return install_component("runtime")
}

// Whether a directory exists at all, which separates "you pointed `-runtime` at
// nothing" from "the installation has no C sources in it".
dir_exists :: proc(path: string) -> bool {
	return path != "" && os.is_dir(path)
}
