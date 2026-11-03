// design.md "Build constants": the predeclared `LOKE_*` constants and their
// synthesized enum types.
package lokec

import "core:reflect"

Opt_Mode :: enum {
	None,
	Minimal,
	Size,
	Speed,
	Aggressive,
}

Build_Mode :: enum {
	Exe,
	Obj,
	// design.md "Test procedures": an executable whose entry runs the root
	// package's tests.
	Test,
}

// compiler-guide.md "CPU levels": the instruction set a build may use. Each
// level adds to the one before it.
Cpu_Level :: enum u8 {
	X86_64,
	X86_64_V2,
	X86_64_V3,
}

// The `-cpu` spelling, which is also clang's `-march` name.
cpu_level_name :: proc(cpu: Cpu_Level) -> string {
	switch cpu {
	case .X86_64:    return "x86-64"
	case .X86_64_V2: return "x86-64-v2"
	case .X86_64_V3: return "x86-64-v3"
	}
	return "x86-64"
}

parse_cpu_level :: proc(text: string) -> (Cpu_Level, bool) {
	for cpu in Cpu_Level {
		if text == cpu_level_name(cpu) {
			return cpu, true
		}
	}
	return .X86_64, false
}

// compiler-guide.md "CPU levels": whether the level has a fused multiply-add
// instruction.
cpu_has_fma :: proc(cpu: Cpu_Level) -> bool {
	return cpu == .X86_64_V3
}

// The one target, at the CPU level the driver selected. Checker and emitter
// read the same widths, so `int` cannot mean 64 bits in one and 32 in the other.
Target_Info :: struct {
	triple:       string,
	pointer_bits: u16,
	int_bits:     u16,
	// The widest alignment a scalar takes. On x86-64 a 128-bit integer is
	// 16-aligned and nothing is wider, which is what LLVM's own data layout for
	// this triple says.
	max_align:    u16,
	// compiler-guide.md "CPU levels": the level the code generator may use. A
	// level changes no result: arithmetic is never contracted at any of them
	// (design.md "Floating-point operators").
	cpu:          Cpu_Level,
}

windows_x64_target :: proc(cpu: Cpu_Level) -> Target_Info {
	return Target_Info {
		triple       = "x86_64-pc-windows-msvc",
		pointer_bits = 64,
		int_bits     = 64,
		max_align    = 16,
		cpu          = cpu,
	}
}

// `-Ofast` is deliberately absent: it changes floating-point semantics.
OPT_CLANG_FLAGS := [Opt_Mode]string {
	.None       = "-O0",
	.Minimal    = "-O1",
	.Size       = "-Os",
	.Speed      = "-O2",
	.Aggressive = "-O3",
}

LOKE_VERSION_STRING :: "0.9.0"

// standard-library.md "Compiled log level". The member names are `core:log`'s own, and
// `Off` is last so `LOKE_LOG_LEVEL <= .Error` is false when logging is compiled
// out entirely.
Log_Level :: enum u8 {
	Debug,
	Info,
	Warning,
	Error,
	Off,
}

@(private = "file")
enum_const :: proc(c: ^Compiler, type: Type_Id, index: int) -> Symbol {
	return Symbol {
		kind        = .Const,
		type        = type,
		const_value = Const_Value{kind = .Integer, integer = bi_from_i64(c, i64(index))},
	}
}

// Windows x64 is the only target, so architecture, OS, endianness, and vendor
// are fixed at their first member. The driver-backed enums take their member
// names from the driver's own enums, so the two lists cannot drift apart.
predeclare_build_config :: proc(c: ^Compiler) {
	define_universe(c, "LOKE_ARCH", enum_const(c, synth_enum(c, "Arch", {"Amd64", "Arm64"}), 0))
	define_universe(c, "LOKE_OS", enum_const(c, synth_enum(c, "Os", {"Windows", "Linux", "Darwin"}), 0))
	define_universe(c, "LOKE_ENDIAN", enum_const(c, synth_enum(c, "Endian", {"Little", "Big"}), 0))
	define_universe(c, "LOKE_BUILD_MODE", enum_const(c, synth_enum(c, "Build_Mode", reflect.enum_field_names(Build_Mode)), int(c.build_mode)))
	define_universe(c, "LOKE_OPTIMIZATION_MODE", enum_const(c, synth_enum(c, "Optimization_Mode", reflect.enum_field_names(Opt_Mode)), int(c.opt_mode)))
	c.log_level_type = synth_enum(c, "log.Level", reflect.enum_field_names(Log_Level))
	define_universe(c, "LOKE_LOG_LEVEL", enum_const(c, c.log_level_type, int(c.log_level)))
	define_universe(c, "LOKE_VENDOR", enum_const(c, synth_enum(c, "Vendor", {"Loke"}), 0))
	define_universe(c, "LOKE_DEBUG", Symbol {
		kind        = .Const,
		type        = TYPE_UNTYPED_BOOL,
		const_value = bool_const(c.debug),
	})
	define_universe(c, "LOKE_VERSION", Symbol {
		kind        = .Const,
		type        = TYPE_UNTYPED_STRING,
		const_value = Const_Value{kind = .String, text = LOKE_VERSION_STRING},
	})
}
