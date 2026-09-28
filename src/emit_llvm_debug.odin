// Debug information: procedure records and source locations as LLVM metadata.
//
// Part of the textual LLVM backend; see compiler-architecture.md. Hundreds of
// sites write instructions, so none of them spells a location. Under `-g` the
// emitter writes a marker line after each procedure's `define` and before each
// statement, and `attach_debug_info` turns the markers into `!dbg` attachments
// once the module is complete. Without `-g` no marker is written, so the module
// is unchanged.
package lokec

import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

@(private = "file")
PROC_MARKER :: ";dbg.proc "
@(private = "file")
LOCATION_MARKER :: ";dbg.loc "

// The procedure whose `define` line was just written.
@(private)
debug_mark_proc :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	if e.c.debug_info {
		fmt.sbprintfln(&e.b, "%s%d", PROC_MARKER, u32(symbol_id))
	}
}

// The statement whose instructions follow.
@(private)
debug_mark_location :: proc(e: ^Emitter, span: Span) {
	if e.c.debug_info && span.file != NO_FILE {
		fmt.sbprintfln(&e.b, "%s%d %d", LOCATION_MARKER, span.file, span.lo)
	}
}

@(private = "file")
Debug_Info :: struct {
	c:         ^Compiler,
	meta:      strings.Builder,
	count:     int,
	files:     map[u32]int,
	// By subprogram, line, and column.
	locations: map[[3]int]int,
}

// Metadata `!0` to `!3` are fixed: the unit, the two module flags, and the one
// subroutine type every procedure shares, since no debugger needs its
// parameter types to set a breakpoint or walk the stack.
@(private = "file")
UNIT :: 0
@(private = "file")
SUBROUTINE_TYPE :: 3

// The module with every marker replaced: a marked procedure's `define` and its
// instructions carry `!dbg`, and the metadata they name follows the module. An
// unmarked function, such as a thunk, gets none, and markers inside it vanish.
@(private)
attach_debug_info :: proc(e: ^Emitter, module: string) -> string {
	c := e.c
	d := Debug_Info {
		c         = c,
		meta      = strings.builder_make(),
		count     = SUBROUTINE_TYPE + 1,
		files     = make(map[u32]int),
		locations = make(map[[3]int]int),
	}
	out := strings.builder_make()
	subprogram, subprogram_file, location := -1, NO_FILE, -1
	rest := module
	for line in strings.split_lines_iterator(&rest) {
		switch {
		case strings.has_prefix(line, PROC_MARKER):
			id, _ := strconv.parse_uint(line[len(PROC_MARKER):])
			symbol := symbol_of(c, Symbol_Id(id))
			if symbol == nil {
				continue
			}
			subprogram_file = symbol.span.file
			subprogram = debug_subprogram(&d, symbol, e.names[Symbol_Id(id)])
			location = debug_location(&d, subprogram, symbol.span)
			// The `define` line just written ends in ` {`.
			resize(&out.buf, len(out.buf) - len(" {\n"))
			fmt.sbprintfln(&out, " !dbg !%d {{", subprogram)
		case strings.has_prefix(line, LOCATION_MARKER):
			fields := strings.fields(line[len(LOCATION_MARKER):])
			file, _ := strconv.parse_uint(fields[0])
			lo, _ := strconv.parse_uint(fields[1])
			// A location's file is its subprogram's, so a statement written in
			// another file keeps the location before it.
			if subprogram >= 0 && u32(file) == subprogram_file {
				location = debug_location(&d, subprogram, Span{file = u32(file), lo = u32(lo)})
			}
		case subprogram >= 0 && strings.has_prefix(line, "  "):
			fmt.sbprintfln(&out, "%s, !dbg !%d", line, location)
		case:
			if line == "}" {
				subprogram = -1
			}
			fmt.sbprintln(&out, line)
		}
	}

	optimized := c.opt_mode != .None
	fmt.sbprintln(&out, "!llvm.dbg.cu = !{!0}")
	fmt.sbprintln(&out, "!llvm.module.flags = !{!1, !2}")
	// Loke has no DWARF language code; C's describes its procedures well enough.
	fmt.sbprintfln(
		&out,
		`!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !%d, producer: "lokec %s", isOptimized: %v, runtimeVersion: 0, emissionKind: FullDebug)`,
		debug_file(&d, package_of(c, c.root_package).files[0].file), LOKE_VERSION_STRING, optimized,
	)
	fmt.sbprintln(&out, `!1 = !{i32 2, !"Debug Info Version", i32 3}`)
	// Windows debuggers read CodeView, in a PDB the linker writes.
	fmt.sbprintln(&out, `!2 = !{i32 2, !"CodeView", i32 1}`)
	fmt.sbprintln(&out, "!3 = !DISubroutineType(types: !{})")
	strings.write_string(&out, strings.to_string(d.meta))
	return strings.to_string(out)
}

@(private = "file")
debug_node :: proc(d: ^Debug_Info, format: string, args: ..any) -> int {
	id := d.count
	d.count += 1
	fmt.sbprintf(&d.meta, "!%d = ", id)
	fmt.sbprintfln(&d.meta, format, ..args)
	return id
}

@(private = "file")
debug_file :: proc(d: ^Debug_Info, file: u32) -> int {
	if id, found := d.files[file]; found {
		return id
	}
	path, _ := filepath.abs(d.c.sources[file].path)
	id := debug_node(
		d, `!DIFile(filename: "%s", directory: "%s")`,
		llvm_escape(filepath.base(path)), llvm_escape(filepath.dir(path)),
	)
	d.files[file] = id
	return id
}

@(private = "file")
debug_subprogram :: proc(d: ^Debug_Info, symbol: ^Symbol, llvm_name: string) -> int {
	file := debug_file(d, symbol.span.file)
	line, _ := line_col(&d.c.sources[symbol.span.file], symbol.span.lo)
	flags := d.c.opt_mode != .None ? "DISPFlagDefinition | DISPFlagOptimized" : "DISPFlagDefinition"
	return debug_node(
		d,
		`distinct !DISubprogram(name: "%s", scope: !%d, file: !%d, line: %d, type: !%d, scopeLine: %d, spFlags: %s, unit: !%d)`,
		llvm_escape(debug_proc_name(llvm_name)), file, file, line, SUBROUTINE_TYPE, line, flags, UNIT,
	)
}

@(private = "file")
debug_location :: proc(d: ^Debug_Info, subprogram: int, span: Span) -> int {
	line, column := line_col(&d.c.sources[span.file], span.lo)
	key := [3]int{subprogram, line, column}
	if id, found := d.locations[key]; found {
		return id
	}
	id := debug_node(d, "!DILocation(line: %d, column: %d, scope: !%d)", line, column, subprogram)
	d.locations[key] = id
	return id
}

// The name a debugger shows: `@loke.p.core$3afmt.print` is `core:fmt.print`.
@(private)
debug_proc_name :: proc(llvm_name: string) -> string {
	name := strings.trim_prefix(llvm_name, "@")
	name = strings.trim_prefix(strings.trim_suffix(name, `"`), `"`)
	name = strings.trim_prefix(name, "loke.p.")
	out := make([dynamic]u8, 0, len(name))
	for i := 0; i < len(name); i += 1 {
		if name[i] == '$' && i + 2 < len(name) {
			if value, ok := strconv.parse_uint(name[i + 1:i + 3], 16); ok {
				append(&out, u8(value))
				i += 2
				continue
			}
		}
		append(&out, name[i])
	}
	return string(out[:])
}
