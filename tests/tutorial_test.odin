package tests

import "core:fmt"
import "core:os"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

// The tutorials under `tutorials/` are checked from the pages themselves, so
// what a reader copies is what was compiled. A fenced block is a checked file
// when its info string names one, and a checked result when it names a program:
//
//   ```odin file=hello.loke           a program of one file, compiled as a file
//   ```odin file=shop/main.loke       a file of the program `shop`, compiled as
//                                     a directory; `shop/stock/stock.loke` is
//                                     a package it imports
//   ```text file=scores.csv           a data file the programs can read
//   ```c file=square.c                C source, compiled to `square.obj` for a
//                                     program's `foreign import`
//   ```text output=hello              what the console shows when `hello` runs:
//                                     its standard output, then its errors
//   ```text panic=hello               the same, for a run that panics
//   ```text error=hello               what lokec reports when it rejects `hello`
//
// A run takes an argument per `args=` and expects `exit=` (default 0), so one
// program may have several runs. A program is either rejected or run at least
// once, so none arrives unchecked.
//
// Every program is compiled and run from the one directory all of them are
// written into, as a reader following the pages would. Only a one-file program
// may show an error, because lokec prints a file argument's path as given but a
// directory's files by their full path.
@(private)
Tutorial_Run :: struct {
	site:     string,
	args:     [dynamic]string,
	panics:   bool,
	exit:     int,
	expected: string,
}

@(private)
Tutorial_Program :: struct {
	page:        string,
	single_file: bool,
	rejected:    bool,
	diagnostics: string,
	runs:        [dynamic]Tutorial_Run,
}

@(test)
tutorials_compile_and_run :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/tutorials", TMP)
	os.make_directory(TMP)
	os2.remove_all(root)
	os.make_directory(root)

	programs := make(map[string]Tutorial_Program, context.temp_allocator)
	files := make(map[string]string, context.temp_allocator)

	pages, _ := filepath.glob("tutorials/*.md", context.temp_allocator)
	testing.expect(t, len(pages) > 0, "tutorials/ holds no pages")
	for page in pages {
		text, ok := os.read_entire_file(page, context.temp_allocator)
		if !testing.expectf(t, ok, "cannot read %s", page) {
			continue
		}
		read_tutorial_page(t, page, string(text), root, &programs, &files)
	}

	compile_tutorial_c_files(t, root, files)

	for name, program in programs {
		label := fmt.tprintf("%s: %s", program.page, name)
		if !testing.expectf(
			t, program.rejected != (len(program.runs) > 0),
			"%s needs an error= block, or output= and panic= blocks, but not both", label,
		) {
			continue
		}
		input := fmt.tprintf("%s.loke", name) if program.single_file else name
		command := make([dynamic]string, context.temp_allocator)
		append(&command, compiler_path(), input, "-o", fmt.tprintf("%s.exe", name))
		append(&command, ..env_flags())
		state, _, stderr, err := os2.process_exec(
			os2.Process_Desc{command = command[:], working_dir = root},
			context.temp_allocator,
		)
		if !testing.expectf(t, err == nil, "%s: cannot run %s", label, compiler_path()) {
			continue
		}
		if program.rejected {
			testing.expectf(t, state.exit_code == 1, "%s: expected lokec to reject it", label)
			expect_tutorial_text(t, label, "diagnostics", program.diagnostics, string(stderr))
			continue
		}
		if !testing.expectf(t, state.exit_code == 0, "%s: compile failed\n%s", label, string(stderr)) {
			continue
		}
		exe := launch_path(fmt.tprintf("%s/%s.exe", root, name))
		for run in program.runs {
			run_command := make([dynamic]string, context.temp_allocator)
			append(&run_command, exe)
			append(&run_command, ..run.args[:])
			run_state, stdout, run_stderr, run_err := os2.process_exec(
				os2.Process_Desc{command = run_command[:], working_dir = root},
				context.temp_allocator,
			)
			if !testing.expectf(t, run_err == nil, "%s: cannot run %s", run.site, exe) {
				continue
			}
			if run.panics {
				testing.expectf(t, run_state.exit_code != 0, "%s: expected %s to panic", run.site, name)
			} else {
				testing.expectf(
					t, run_state.exit_code == run.exit,
					"%s: %s exited with %d, not %d", run.site, name, run_state.exit_code, run.exit,
				)
			}
			console := fmt.tprintf("%s%s", string(stdout), string(run_stderr))
			expect_tutorial_text(t, run.site, "console", run.expected, console)
		}
	}
}

// A page that shows foreign code has the reader compile it with the clang lokec
// uses, which `-print-toolchain` names: `name.c` becomes `name.obj` beside it.
@(private)
compile_tutorial_c_files :: proc(t: ^testing.T, root: string, files: map[string]string) {
	clang := ""
	for path, site in files {
		if !strings.has_suffix(path, ".c") {
			continue
		}
		if clang == "" {
			state, stdout, _, err := os2.process_exec(
				os2.Process_Desc{command = []string{compiler_path(), "-print-toolchain"}},
				context.temp_allocator,
			)
			if !testing.expectf(t, err == nil && state.exit_code == 0, "%s: lokec -print-toolchain failed", site) {
				return
			}
			for line in strings.split_lines(string(stdout), context.temp_allocator) {
				if strings.has_prefix(line, "clang=") {
					clang = strings.trim_space(line[len("clang="):])
				}
			}
			if !testing.expectf(t, clang != "", "%s: lokec -print-toolchain names no clang", site) {
				return
			}
		}
		object := fmt.tprintf("%s.obj", strings.trim_suffix(path, ".c"))
		state, _, stderr, err := os2.process_exec(
			os2.Process_Desc{command = []string{clang, "-c", path, "-o", object}, working_dir = root},
			context.temp_allocator,
		)
		testing.expectf(
			t, err == nil && state.exit_code == 0,
			"%s: clang could not compile %s\n%s", site, path, string(stderr),
		)
	}
}

@(private)
expect_tutorial_text :: proc(t: ^testing.T, label, what, expected, actual: string) {
	testing.expectf(
		t,
		normalise(actual) == normalise(expected),
		"%s: expected the %s\n%s\ngot\n%s",
		label, what, normalise(expected), normalise(actual),
	)
}

@(private)
read_tutorial_page :: proc(
	t: ^testing.T,
	page, text, root: string,
	programs: ^map[string]Tutorial_Program,
	files: ^map[string]string,
) {
	lines := strings.split_lines(normalise_newlines(text), context.temp_allocator)
	for i := 0; i < len(lines); i += 1 {
		if !strings.has_prefix(lines[i], "```") {
			continue
		}
		info := strings.fields(lines[i][3:], context.temp_allocator)
		start := i + 1
		for i += 1; i < len(lines) && !strings.has_prefix(lines[i], "```"); i += 1 {}
		if !testing.expectf(t, i < len(lines), "%s: a code block is not closed", page) {
			return
		}
		if len(info) < 2 {
			continue
		}
		body := strings.join(lines[start:i], "\n", context.temp_allocator)
		site := fmt.tprintf("%s:%d", page, start)

		// The first attribute says what the block is; the rest qualify a run.
		key, _, value := strings.partition(info[1], "=")
		run := Tutorial_Run {
			site     = site,
			args     = make([dynamic]string, context.temp_allocator),
			panics   = key == "panic",
			expected = body,
		}
		for attribute in info[2:] {
			qualifier, _, argument := strings.partition(attribute, "=")
			if qualifier == "args" && (key == "output" || key == "panic") {
				append(&run.args, argument)
			} else if qualifier == "exit" && key == "output" {
				exit, ok := strconv.parse_int(argument)
				testing.expectf(t, ok && exit != 0, "%s: exit=%s is not a failing exit code", site, argument)
				run.exit = exit
			} else {
				testing.expectf(t, false, "%s: %q does not apply to a %s= block", site, attribute, key)
			}
		}

		switch key {
		case "file":
			write_tutorial_file(t, site, page, value, body, root, programs, files)
		case "output", "panic", "error":
			program, known := programs[value]
			if !testing.expectf(t, known, "%s: %s=%s names no program written before it", site, key, value) {
				continue
			}
			if key != "error" {
				append(&program.runs, run)
			} else if testing.expectf(t, !program.rejected, "%s: %s already has an error= block", site, value) &&
			   testing.expectf(
				   t, program.single_file,
				   "%s: error=%s needs a one-file program; a directory's diagnostics print full paths",
				   site, value,
			   ) {
				program.rejected = true
				program.diagnostics = body
			}
			programs[value] = program
		case:
			testing.expectf(t, false, "%s: unknown code block attribute %q", site, info[1])
		}
	}
}

@(private)
write_tutorial_file :: proc(
	t: ^testing.T,
	site, page, path, body, root: string,
	programs: ^map[string]Tutorial_Program,
	files: ^map[string]string,
) {
	if !testing.expectf(
		t, !strings.contains(path, "..") && !strings.contains(path, "\\") && !filepath.is_abs(path),
		"%s: file=%s must be a relative path with forward slashes", site, path,
	) {
		return
	}
	if previous, seen := files[path]; seen {
		testing.expectf(t, false, "%s: %s is already written by %s", site, path, previous)
		return
	}
	files[path] = site
	destination := fmt.tprintf("%s/%s", root, path)
	os2.make_directory_all(filepath.dir(destination, context.temp_allocator))
	written := os.write_entire_file(destination, transmute([]u8)fmt.tprintf("%s\n", body))
	testing.expectf(t, written, "%s: cannot write %s", site, destination)
	if !strings.has_suffix(path, ".loke") {
		return
	}
	name, _, rest := strings.partition(path, "/")
	single := rest == ""
	if single {
		name = strings.trim_suffix(name, ".loke")
	}
	program := programs[name] or_else Tutorial_Program {
		page        = page,
		single_file = single,
		runs        = make([dynamic]Tutorial_Run, context.temp_allocator),
	}
	testing.expectf(
		t, program.single_file == single && program.page == page,
		"%s: program %s is also written by %s", site, name, program.page,
	)
	programs[name] = program
}

@(private)
normalise_newlines :: proc(text: string) -> string {
	return strings.replace_all(text, "\r\n", "\n", context.temp_allocator) or_else text
}
