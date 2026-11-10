// The `-test` driver: runs a built test executable once per test, and tests each
// package of a tree.
package lokec

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "subprocess"

// compiler-guide.md "Running tests": each test runs in a process of its own,
// so a panic ends only its test, and the runner reports every test by name.
run_tests :: proc(c: ^Compiler, exe: string) -> (code, passed, failed: int) {
	path := filepath.abs(exe, context.temp_allocator) or_else exe
	for test in c.tests {
		// One test's captured output at a time, however chatty the suite.
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		symbol := symbol_of(c, test)
		name := identifier_text(c, symbol.name)
		state, stdout, stderr, err := subprocess.run(
			os.Process_Desc{command = {path, name}}, context.temp_allocator,
		)
		if err != nil {
			fmt.eprintfln("error: cannot run `%s`: %v", exe, err)
			return 2, passed, failed
		}
		if state.exit_code == 0 {
			fmt.printfln("ok   %s", name)
			passed += 1
			continue
		}
		failed += 1
		src := &c.sources[symbol.span.file]
		line, col := line_col(src, symbol.span.lo)
		fmt.printfln("FAIL %s (%s:%d:%d)", name, display_path(src.path), line, col)
		print_indented(string(stdout))
		print_indented(string(stderr))
	}
	if len(c.tests) == 0 {
		fmt.println("no tests")
	} else {
		fmt.printfln("%d passed, %d failed", passed, failed)
	}
	return failed > 0 ? 1 : 0, passed, failed
}

@(private = "file")
print_indented :: proc(text: string) {
	rest := strings.trim_right(text, "\r\n")
	for line in strings.split_lines_iterator(&rest) {
		fmt.printfln("     %s", line)
	}
}

// compiler-guide.md "Testing a tree": the directory before a final `/...` or
// `\...`, or false for any other input. `...` alone is the working directory's.
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

// compiler-guide.md "Testing a tree": each package of the tree is the root of
// a compilation of its own. Every one is checked; one that declares a test is
// built and, when `run`, tested; and the report ends with the tree's totals.
// `emission.output` is empty, or the directory standing in for the one holding
// `root`.
test_tree :: proc(root: string, config: Compilation_Config, emission: Emission_Options, run: bool) -> int {
	if !os.is_dir(root) {
		fmt.eprintfln("error: `%s` is not a directory", root)
		return 1
	}
	// The packages and `parent` outlive each package's temporary guard below.
	packages := make([dynamic]string, context.temp_allocator)
	readable := collect_tree_packages(root, &packages)
	if len(packages) == 0 {
		if readable {
			fmt.eprintfln("error: no package in `%s` or below it", root)
		}
		return 1
	}
	output := emission.output
	parent := ""
	if output != "" {
		absolute, err := filepath.abs(root, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("error: cannot resolve `%s`", root)
			return 2
		}
		parent = path_dir(absolute, context.temp_allocator)
	}

	code := 0 if readable else 1
	tested, not_built, passed, failed, listed := 0, 0, 0, 0, 0
	for dir in packages {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		s: Compilation_Session
		defer destroy_session(&s)
		c := &s.compiler
		if !init_session(&s, config) {
			// The configuration is every package's, so none would build.
			report(c)
			return 1
		}
		checked := check_session(&s, dir)
		if checked && len(c.tests) == 0 {
			report(c)
			continue
		}
		fmt.printf("%s%s\n", listed > 0 ? "\n" : "", display_path(dir))
		listed += 1
		exe := tree_output_path(dir, parent, output)
		status := 0 if checked else 1
		if checked && exe == "" {
			// Only a root, as `C:\`, has no name, and with a tree `-o` cannot give it one.
			fmt.eprintfln("error: `%s` is a root directory, which names no test executable", display_path(dir))
			status = 2
		} else if checked {
			if output != "" {
				os.make_directory_all(path_dir(exe, context.temp_allocator))
			}
			opts := emission
			opts.output = exe
			status = emit_session(&s, opts)
		}
		report(c)
		if status != 0 {
			fmt.println("not built")
			not_built += 1
			code = max(code, status)
			continue
		}
		tested += 1
		if run {
			outcome, package_passed, package_failed := run_tests(c, exe)
			passed += package_passed
			failed += package_failed
			code = max(code, outcome)
		}
	}

	if listed > 0 {
		fmt.println()
	}
	fmt.printf("%d package%s, %d with tests", len(packages), len(packages) == 1 ? "" : "s", tested)
	if not_built > 0 {
		fmt.printf(", %d not built", not_built)
	}
	if run {
		fmt.printf(": %d passed, %d failed", passed, failed)
	}
	fmt.println()
	return code
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

// Where `-test` alone would write `dir`'s executable, or, with `output`, that
// path below `parent` moved below `output`. Empty when `dir` has no name.
@(private)
tree_output_path :: proc(dir, parent, output: string) -> string {
	if output == "" {
		return default_output_path(dir, .Test)
	}
	absolute, err := filepath.abs(dir, context.temp_allocator)
	if err != nil {
		return ""
	}
	relative, rel_err := filepath.rel(parent, absolute, context.temp_allocator)
	if rel_err != nil || relative == "." || strings.has_prefix(relative, "..") {
		return ""
	}
	joined, _ := filepath.join({output, relative}, context.temp_allocator)
	return strings.concatenate({joined, ".test.exe"}, context.temp_allocator)
}
