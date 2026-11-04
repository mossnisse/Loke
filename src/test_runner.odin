// The `-test` driver: runs a built test executable once per test.
package lokec

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "subprocess"

// compiler-guide.md "Running tests": each test runs in a process of its own,
// so a panic ends only its test, and the runner reports every test by name.
run_tests :: proc(c: ^Compiler, exe: string) -> int {
	path := filepath.abs(exe, context.temp_allocator) or_else exe
	failed := 0
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
			return 2
		}
		if state.exit_code == 0 {
			fmt.printfln("ok   %s", name)
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
		fmt.printfln("%d passed, %d failed", len(c.tests) - failed, failed)
	}
	return failed > 0 ? 1 : 0
}

@(private = "file")
print_indented :: proc(text: string) {
	rest := strings.trim_right(text, "\r\n")
	for line in strings.split_lines_iterator(&rest) {
		fmt.printfln("     %s", line)
	}
}
