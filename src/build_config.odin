// Build configuration: the `LOKE_*` predeclared constants and their enum types
// (m7-plan step 1, decision "Build constants").
//
// design.md "Build configuration": `LOKE_ARCH`, `LOKE_OS`, `LOKE_ENDIAN`,
// `LOKE_BUILD_MODE`, `LOKE_DEBUG`, `LOKE_OPTIMIZATION_MODE`, `LOKE_VENDOR`, and
// `LOKE_VERSION` are predeclared universe constants, readable with no import so
// `when (LOKE_OS == .Windows)` compiles anywhere. Their enum types are
// synthesized once and bound into `base:runtime` through `src/stdlib.odin`, so
// `runtime.Os` and the constant's own type are one identity — the same pattern
// `mem.Arena` uses.
package lokec

import "core:reflect"

// The driver's whole-program build selections. Windows x64 is the only v1
// target, so architecture, OS, endianness, and vendor are fixed.
Opt_Mode :: enum {
	None,      // -O0
	Minimal,   // -O1
	Size,      // -Os
	Speed,     // -O2
	Aggressive, // -O3
}

Build_Mode :: enum {
	Exe,
	Obj,
}

// The `-opt=` name to clang `-O` flag map (m7-plan decision "Release output").
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

// The synthesized enum types, created lazily and cached so the many
// `build_universe` calls share one identity apiece. Indexed by the constant
// that names them, so the mapping has no second spelling to drift from.
// `.None` indexes a zero entry, i.e. `INVALID_TYPE`.
Build_Config :: struct {
	ready: bool,
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

@(private = "file")
enum_const :: proc(c: ^Compiler, which: Build_Config_Enum, index: int) -> Symbol {
	// The enum `type` is left INVALID and filled in lazily on first use, so a
	// program that never reads build config allocates no enum types and keeps its
	// type numbering byte-identical.
	return Symbol {
		kind              = .Const,
		type              = INVALID_TYPE,
		build_config_enum = which,
		const_value       = Const_Value{kind = .Integer, integer = bi_from_i64(c, i64(index))},
	}
}

// The enum `Type_Id` for one build-config constant, created on first demand.
// Creation order fixes the type numbering, so the six stay in this order.
//
// `Build_Mode` and `Optimization_Mode` take their member names from the driver
// enums the `LOKE_*` constants index with `int(c.build_mode)` and
// `int(c.opt_mode)`. Spelling them out again would let a new mode land in one
// list and not the other — a stale list would then name the constant the
// wrong member instead of failing to compile.
build_config_enum_type :: proc(c: ^Compiler, which: Build_Config_Enum) -> Type_Id {
	bc := &c.build_config
	if !bc.ready {
		bc.ready = true
		bc.types[.Arch] = synth_enum(c, "Arch", {"Amd64", "Arm64"})
		bc.types[.Os] = synth_enum(c, "Os", {"Windows", "Linux", "Darwin"})
		bc.types[.Endian] = synth_enum(c, "Endian", {"Little", "Big"})
		bc.types[.Build_Mode] = synth_enum(c, "Build_Mode", reflect.enum_field_names(Build_Mode))
		bc.types[.Optimization_Mode] = synth_enum(
			c, "Optimization_Mode", reflect.enum_field_names(Opt_Mode),
		)
		bc.types[.Vendor] = synth_enum(c, "Vendor", {"Loke"})
	}
	return bc.types[which]
}

// Predeclares the eight `LOKE_*` constants into the universe scope. Their enum
// values track the driver's selections, which are on the compiler before the
// first `when` is evaluated.
predeclare_build_config :: proc(c: ^Compiler, universe: ^Scope) {
	define_universe(c, universe, "LOKE_ARCH", enum_const(c, .Arch, 0)) // Amd64
	define_universe(c, universe, "LOKE_OS", enum_const(c, .Os, 0)) // Windows
	define_universe(c, universe, "LOKE_ENDIAN", enum_const(c, .Endian, 0)) // Little
	define_universe(c, universe, "LOKE_BUILD_MODE", enum_const(c, .Build_Mode, int(c.build_mode)))
	define_universe(c, universe, "LOKE_OPTIMIZATION_MODE", enum_const(c, .Optimization_Mode, int(c.opt_mode)))
	define_universe(c, universe, "LOKE_VENDOR", enum_const(c, .Vendor, 0)) // Loke
	// design.md "Debug selection": M7 accepts no debug build, so `LOKE_DEBUG` is
	// present and always false. A later debug milestone flips it.
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
