// design.md "Build configuration": the predeclared `LOKE_*` constants and their
// synthesized enum types.
package lokec

import "core:reflect"

Opt_Mode :: enum {
	None,       // -O0
	Minimal,    // -O1
	Size,       // -Os
	Speed,      // -O2
	Aggressive, // -O3
}

Build_Mode :: enum {
	Exe,
	Obj,
}

// `-Ofast` is deliberately absent: it changes floating-point semantics.
opt_clang_flag :: proc(mode: Opt_Mode) -> string {
	switch mode {
	case .None:       return "-O0"
	case .Minimal:    return "-O1"
	case .Size:       return "-Os"
	case .Speed:      return "-O2"
	case .Aggressive: return "-O3"
	}
	return "-O0"
}

LOKE_VERSION_STRING :: "0.7.0"

// One cached enum type per constant; `.None` stays `INVALID_TYPE`.
Build_Config :: struct {
	types: [Build_Config_Enum]Type_Id,
}

@(private = "file")
synth_enum :: proc(c: ^Compiler, name: string, members: []string) -> Type_Id {
	type := new_type(c, Type_Info {
		kind    = .Enum,
		name    = intern_identifier(c, name),
		element = TYPE_INT,
		bits    = u16(type_bits(c, TYPE_INT)),
		signed  = true,
	})
	fields := make([]Symbol_Id, len(members), c.semantic_allocator)
	for member, index in members {
		fields[index] = new_symbol(c, Symbol {
			name        = intern_identifier(c, member),
			span        = no_span(),
			kind        = .Enum_Member,
			type        = type,
			index       = u32(index),
			const_value = Const_Value{kind = .Integer, integer = bi_from_i64(c, i64(index))},
		})
	}
	type_of(c, type).fields = fields
	return type
}

// The type stays INVALID until first use (see `build_config_enum_type`).
@(private = "file")
enum_const :: proc(c: ^Compiler, which: Build_Config_Enum, index: int) -> Symbol {
	return Symbol {
		kind              = .Const,
		type              = INVALID_TYPE,
		build_config_enum = which,
		const_value       = Const_Value{kind = .Integer, integer = bi_from_i64(c, i64(index))},
	}
}

// Created together on first use, so a program that never reads build config
// keeps its type numbering. Creation order fixes that numbering: append only.
// The driver-backed enums take their member names from the driver's own enums,
// so the two lists cannot drift apart.
build_config_enum_type :: proc(c: ^Compiler, which: Build_Config_Enum) -> Type_Id {
	bc := &c.build_config
	if bc.types[.Arch] == INVALID_TYPE {
		bc.types[.Arch] = synth_enum(c, "Arch", {"Amd64", "Arm64"})
		bc.types[.Os] = synth_enum(c, "Os", {"Windows", "Linux", "Darwin"})
		bc.types[.Endian] = synth_enum(c, "Endian", {"Little", "Big"})
		bc.types[.Build_Mode] = synth_enum(c, "Build_Mode", reflect.enum_field_names(Build_Mode))
		bc.types[.Optimization_Mode] = synth_enum(c, "Optimization_Mode", reflect.enum_field_names(Opt_Mode))
		bc.types[.Vendor] = synth_enum(c, "Vendor", {"Loke"})
		bc.types[.Log_Level] = synth_enum(c, "Log_Level", reflect.enum_field_names(Log_Level))
	}
	return bc.types[which]
}

// Windows x64 is the only target, so architecture, OS, endianness, and vendor
// are fixed at their first member.
predeclare_build_config :: proc(c: ^Compiler, universe: ^Scope) {
	define_universe(c, universe, "LOKE_ARCH", enum_const(c, .Arch, 0))
	define_universe(c, universe, "LOKE_OS", enum_const(c, .Os, 0))
	define_universe(c, universe, "LOKE_ENDIAN", enum_const(c, .Endian, 0))
	define_universe(c, universe, "LOKE_BUILD_MODE", enum_const(c, .Build_Mode, int(c.build_mode)))
	define_universe(c, universe, "LOKE_OPTIMIZATION_MODE", enum_const(c, .Optimization_Mode, int(c.opt_mode)))
	define_universe(c, universe, "LOKE_LOG_LEVEL", enum_const(c, .Log_Level, int(c.log_level)))
	define_universe(c, universe, "LOKE_VENDOR", enum_const(c, .Vendor, 0))
	// No driver flag sets this yet (future-plans.md).
	define_universe(c, universe, "LOKE_DEBUG", Symbol {
		kind        = .Const,
		type        = TYPE_UNTYPED_BOOL,
		const_value = bool_const(false),
	})
	define_universe(c, universe, "LOKE_VERSION", Symbol {
		kind        = .Const,
		type        = TYPE_UNTYPED_STRING,
		const_value = Const_Value{kind = .String, text = LOKE_VERSION_STRING},
	})
}
