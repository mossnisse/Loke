// `-check-layout`: a module that asks LLVM for the layout the checker computed.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import "subprocess"

// One number the checker claims and LLVM can be made to compute.
@(private = "file")
Layout_Probe :: struct {
	description: string,
	llvm:        string, // a constant expression that evaluates to the number
	expected:    u64,
}

// `-check-layout`: runs a module printing LLVM's size, alignment, and field
// offsets for every type and compares them with the checker's layout.
check_layout_agreement :: proc(c: ^Compiler, opts: Emission_Options) -> int {
	context.allocator = virtual.arena_allocator(&c.emission_arena)
	e := make_emitter(c)
	fmt.sbprintfln(&e.b, `target triple = "%s"`, c.target.triple)
	fmt.sbprintln(&e.b, `@.fmt_int = private unnamed_addr constant [6 x i8] c"%lld\0A\00"`)
	fmt.sbprintln(&e.b, "declare i32 @printf(ptr, ...)")
	// The seed runtime calls this on thread detach.
	fmt.sbprintln(&e.b, "define void @loke_rt_v1_program_tls_cleanup() { ret void }")
	emit_sink_bridge(&e)
	emit_carrier_types(&e)
	emit_struct_definitions(&e)

	probes := make([dynamic]Layout_Probe)
	for index in 0 ..< len(c.types) {
		type := Type_Id(index)
		if !layout_probeable(c, type) {
			continue
		}
		llvm := llvm_type(&e, type)
		name := type_name(c, type)
		append(&probes, Layout_Probe {
			description = fmt.aprintf("size_of(%s)", name),
			llvm        = fmt.aprintf("ptrtoint (ptr getelementptr (%s, ptr null, i64 1) to i64)", llvm),
			expected    = type_size(c, type),
		})
		// LLVM has no `alignof`; the offset of `T` in `{ i8, T }` is its alignment.
		append(&probes, Layout_Probe {
			description = fmt.aprintf("align_of(%s)", name),
			// `{` is a format directive to core:fmt, so this one is concatenated.
			llvm        = strings.concatenate(
				{"ptrtoint (ptr getelementptr ({ i8, ", llvm, " }, ptr null, i64 0, i32 1) to i64)"},
			),
			expected    = type_align(c, type),
		})
		info := type_of(c, type)
		if info.kind != .Struct {
			continue
		}
		for field, position in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil {
				continue
			}
			append(&probes, Layout_Probe {
				description = fmt.aprintf("offset_of(%s, %s)", name, identifier_text(c, symbol.name)),
				llvm        = fmt.aprintf("ptrtoint (ptr getelementptr (%s, ptr null, i64 0, i32 %d) to i64)", llvm, position),
				expected    = type_field_offset(c, type, position),
			})
		}
	}

	fmt.sbprintln(&e.b, "define i32 @main() {")
	fmt.sbprintln(&e.b, "entry:")
	for probe in probes {
		fmt.sbprintfln(&e.b, "  call i32 (ptr, ...) @printf(ptr @.fmt_int, i64 %s)", probe.llvm)
	}
	fmt.sbprintln(&e.b, "  ret i32 0")
	fmt.sbprintln(&e.b, "}")

	ll_path := replace_ext(opts.output, ".layout.ll")
	if !write_artifact(c, ll_path, strings.to_string(e.b)) {
		return 2
	}
	defer if !opts.keep_temps {
		os.remove(ll_path)
	}
	// The probe is not the program, so `-o` keeps what it holds, and it has no
	// debug information for a PDB to carry.
	exe_path := replace_ext(opts.output, ".layout.exe")
	c.debug_info = false
	if code := link(c, ll_path, "", exe_path, opts); code != 0 {
		return code
	}
	defer if !opts.keep_temps {
		os.remove(exe_path)
	}

	// A bare name would be searched for, beside the compiler first.
	state, stdout, _, err := subprocess.run(
		os.Process_Desc{command = []string{filepath.abs(exe_path, context.allocator) or_else exe_path}},
		context.allocator,
	)
	if err != nil || state.exit_code != 0 {
		errorf(c, no_span(), "L0405", "cannot run the layout probe")
		return 2
	}
	text, _ := strings.replace_all(string(stdout), "\r\n", "\n")
	lines := strings.split_lines(strings.trim_space(text))
	if len(lines) != len(probes) {
		errorf(c, no_span(), "L0405", "the layout probe produced %d values, expected %d", len(lines), len(probes))
		return 2
	}
	disagreements := 0
	for probe, index in probes {
		actual, parsed := strconv.parse_u64(strings.trim_space(lines[index]))
		if !parsed || actual != probe.expected {
			errorf(
				c,
				no_span(),
				"L0405",
				"%s: the checker says %d, LLVM says %s",
				probe.description,
				probe.expected,
				lines[index],
			)
			disagreements += 1
		}
	}
	if disagreements > 0 {
		return 1
	}
	fmt.printfln("%d layout facts agree with LLVM", len(probes))
	return 0
}

// A type that lowers to a real LLVM type and holds a runtime value.
@(private = "file")
layout_probeable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := type_of(c, type)
	if info == nil || !type_is_supported(c, type) {
		return false
	}
	// A generic record's shell has no emitted definition.
	if sym := symbol_of(c, info.symbol); sym != nil && sym.generic {
		return false
	}
	#partial switch info.kind {
	case .Bool, .Int, .Float, .Rune, .Raw_Pointer, .String, .String_View, .CString_View, .Typeid,
	     .Pointer, .C_Pointer, .Slice, .Allocator, .Allocator_Error, .Dynamic_Array, .Box, .Array,
	     .Map, .Simd, .Distinct, .Proc, .Struct, .Enum, .Union, .Dyn:
		return true
	}
	return false
}
