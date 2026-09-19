// The runtime and the `base`/`core` roots ship beside the compiler, so they
// resolve from its own path rather than the working directory.
package lokec

import os2 "core:os/os2"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// A component bundled beside the compiler (`runtime`, `base`, `core`), or ""
// when the platform cannot say where the compiler is.
install_component :: proc(name: string) -> string {
	dir, err := os2.get_executable_directory(context.allocator)
	if err != nil {
		return ""
	}
	defer delete(dir)
	return filepath.join({dir, name})
}

// Every `*.c` file in `dir`, sorted so one directory always gives one command.
// Listed rather than globbed: a `[` in the path would be read as glob syntax.
runtime_sources :: proc(dir: string) -> []string {
	if dir == "" {
		return nil
	}
	entries, err := os2.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return nil
	}
	sources := make([dynamic]string, 0, len(entries))
	for entry in entries {
		if strings.has_suffix(entry.name, ".c") {
			append(&sources, filepath.join({dir, entry.name}))
		}
	}
	slice.sort(sources[:])
	return sources[:]
}

// `-runtime=<dir>` replaces the bundled directory outright.
resolved_runtime_dir :: proc(opts: Options) -> string {
	if opts.runtime_dir != "" {
		return opts.runtime_dir
	}
	return install_component("runtime")
}
