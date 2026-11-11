// A `/...` input: the packages of a tree, and the actions other than `-test`
// that take each in turn (`test_tree` is in `src/test_runner.odin`).
package lokec

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// compiler-guide.md "Trees": the directory before a final `/...` or `\...`, or
// false for any other input. `...` alone is the working directory's.
tree_root :: proc(input: string) -> (string, bool) {
	if input == "..." {
		return ".", true
	}
	if !strings.has_suffix(input, "/...") && !strings.has_suffix(input, "\\...") {
		return "", false
	}
	root := input[:len(input) - len("/...")]
	// `/...` and `C:\...` keep the separator that makes their directory a root.
	if root == "" || root == filepath.volume_name(input) {
		root = input[:len(root) + 1]
	}
	return root, true
}

// compiler-guide.md "Trees": the packages of the tree at `root`, in temporary
// storage, and whether every directory could be read. None, after saying why,
// when `root` is no directory or holds no package.
tree_packages :: proc(root: string) -> (packages: []string, readable: bool) {
	if !os.is_dir(root) {
		fmt.eprintfln("error: `%s` is not a directory", root)
		return nil, false
	}
	found := make([dynamic]string, context.temp_allocator)
	readable = collect_tree_packages(root, &found)
	if len(found) == 0 && readable {
		fmt.eprintfln("error: no package in `%s` or below it", root)
	}
	return found[:], readable
}

// `dir` when it directly holds a `.loke` file, then the packages below it, a
// directory's entries by name. A directory named with a leading `.` or `_` is
// skipped, and a link to one is not followed: it is not a `.Directory` entry. False
// after saying which directory could not be read; the walk goes on without it.
// `packages` borrows `dir` and the temporary paths below it.
@(private)
collect_tree_packages :: proc(dir: string, packages: ^[dynamic]string) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("error: cannot read `%s`: %v", display_path(dir), err)
		return false
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for entry in entries {
		if is_source_file(entry) {
			append(packages, dir)
			break
		}
	}
	readable := true
	for entry in entries {
		if entry.type == .Directory && !strings.has_prefix(entry.name, ".") && !strings.has_prefix(entry.name, "_") {
			below, _ := filepath.join({dir, entry.name}, context.temp_allocator)
			readable = collect_tree_packages(below, packages) && readable
		}
	}
	return readable
}

// compiler-guide.md "Trees": `-fmt` or `-migrate`, as `rewrite`, over the files
// of each package of the tree. The status is the worst of the packages', and 1
// when a directory could not be read.
rewrite_tree :: proc(
	root: string,
	config: Compilation_Config,
	check: bool,
	rewrite: proc(c: ^Compiler, input: string, check: bool) -> int,
) -> int {
	packages, readable := tree_packages(root)
	if len(packages) == 0 {
		return 1
	}
	s: Compilation_Session
	defer destroy_session(&s)
	c := &s.compiler
	if !init_session(&s, config) {
		report(c)
		return 1
	}
	code := 0 if readable else 1
	for dir in packages {
		code = max(code, rewrite(c, dir, check))
	}
	report(c)
	return code
}

// compiler-guide.md "Trees": `-api` or, with `check`, `-api-check` for each
// package of the tree, checked as the root of a compilation of its own. Each
// writes or compares only its own interface file: the tree names the packages,
// and one that several import is then listed once.
write_tree_interfaces :: proc(root: string, config: Compilation_Config, check: bool) -> int {
	packages, readable := tree_packages(root)
	if len(packages) == 0 {
		return 1
	}
	code := 0 if readable else 1
	for dir in packages {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		s: Compilation_Session
		defer destroy_session(&s)
		c := &s.compiler
		if !init_session(&s, config) {
			// The configuration is every package's, so none would check.
			report(c)
			return 1
		}
		if check_session(&s, dir, true) {
			code = max(code, write_interfaces(c, c.root_package, check, root_only = true))
		} else {
			code = max(code, 1)
		}
		report(c)
	}
	return code
}
