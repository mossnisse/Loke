// Path utilities: what the compiler does to a path before it means anything.
package lokec

import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

// `filepath.join` with its allocation error dropped: a path the compiler
// cannot allocate is not one it can go on with either.
join_path :: proc(elems: []string, allocator := context.allocator) -> string {
	return filepath.join(elems, allocator) or_else ""
}

// Deletes `path` and everything below it, entry by entry. `os.remove_all`
// deletes through the Windows shell, which raises and then handles an access
// violation of its own; a test runner's vectored exception handler sees that
// first and stops the test as a segmentation fault.
remove_tree :: proc(path: string) -> os.Error {
	if entries, err := os.read_all_directory_by_path(path, context.temp_allocator); err == nil {
		for entry in entries {
			if entry.type == .Directory {
				remove_tree(entry.fullpath)
			} else {
				os.remove(entry.fullpath)
			}
		}
	}
	return os.remove(path)
}

// The cleaned directory part of `path`, `.` when it has none. `filepath.dir`
// only splits, so `a/../b/x` would keep its `..` and `x` would give "".
path_dir :: proc(path: string, allocator := context.allocator) -> string {
	return filepath.clean(filepath.dir(path), allocator) or_else "."
}

// Produces a temporary absolute, cleaned, `/`-separated path.
canonical_dir :: proc(path: string) -> string {
	absolute, abs_err := filepath.abs(path, context.temp_allocator)
	cleaned := filepath.clean(abs_err == nil ? absolute : path, context.temp_allocator) or_else path
	slashed, _ := strings.replace_all(cleaned, "\\", "/", context.temp_allocator)
	return slashed
}

// Windows paths are case-insensitive, so package identity must be too.
dir_key :: proc(dir: string, allocator := context.temp_allocator) -> string {
	return strings.to_lower(dir, allocator)
}

// FNV-1a distinguishes otherwise identical visible path names.
path_digest :: proc(path: string) -> u64 {
	return hash.fnv64a(transmute([]byte)strings.to_lower(path, context.temp_allocator))
}
