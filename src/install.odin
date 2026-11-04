// The runtime and the `base`/`core` roots ship beside the compiler, so they
// resolve from its own path rather than the working directory.
package lokec

import "core:os"

// A component bundled beside the compiler (`runtime`, `base`, `core`), or ""
// when the platform cannot say where the compiler is. In the temporary allocator.
install_component :: proc(name: string) -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {
		return ""
	}
	return join_path({dir, name}, context.temp_allocator)
}
