// Runtime type metadata: the `type_info_of` table of every requested `typeid`,
// and its member tables.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// design.md "`type` and `typeid`": one entry per requested `typeid`, indexed
// by id, with an empty entry 0.
TYPE_INFO_TABLE :: "@.loke.type_info"

@(private)
emit_type_info_tables :: proc(e: ^Emitter) {
	if !e.c.type_info_requested {
		return
	}
	record, has_record := e.c.runtime_types["Type_Info"]
	if !has_record {
		backend_fail(e, "`type_info_of` was checked without the `base:runtime` layouts")
		return
	}
	entries := make([]string, len(e.c.typeid_order) + 1)
	for type in e.c.typeid_order {
		entries[typeid_value(e.c, type)] = type_info_entry(e, record, type)
	}
	append_constant_array(e, generated_name(e, TYPE_INFO_TABLE), struct_name(e, record), entries)
}

// A private constant array; an empty entry is the element's zero.
@(private)
append_constant_array :: proc(e: ^Emitter, name, element: string, entries: []string) {
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x %s] [", name, len(entries), element)
	for entry, index in entries {
		fmt.sbprintf(&b, "%s %s %s", index > 0 ? "," : "", element, entry == "" ? "zeroinitializer" : entry)
	}
	strings.write_string(&b, " ]\n")
	append(&e.globals, strings.to_string(b))
}

// design.md "`type` and `typeid`": an entry describes a type's shape, not its
// members.
@(private = "file")
type_info_entry :: proc(e: ^Emitter, record, type: Type_Id) -> string {
	element, key, count := type_info_relations(e.c, type)
	return record_constant(e, record, {
		fmt.aprintf("%d", typeid_value(e.c, type)),
		fmt.aprintf("%d", int(public_type_kind(e.c, type))),
		text_view_constant(e, type_name(e.c, type)),
		fmt.aprintf("%d", type_size(e.c, type)),
		fmt.aprintf("%d", type_align(e.c, type)),
		fmt.aprintf("%d", typeid_value(e.c, element)),
		fmt.aprintf("%d", typeid_value(e.c, key)),
		fmt.aprintf("%d", count),
	})
}

// The public `Type_Kind`, whose order the checker verified against `base/runtime`.
@(private = "file")
public_type_kind :: proc(c: ^Compiler, type: Type_Id) -> Runtime_Type_Kind {
	if type_kind(c, type) == .Distinct {
		return .Distinct
	}
	under := type_underlying(c, type)
	#partial switch type_kind(c, under) {
	case .Void:            return .Void
	case .Bool:            return .Bool
	case .Int:             return type_signed(c, under) ? .Signed_Int : .Unsigned_Int
	case .Float:           return .Float
	case .Rune:            return .Rune
	case .Raw_Pointer:     return .Raw_Pointer
	case .Pointer:         return .Pointer
	case .C_Pointer:       return .C_Pointer
	case .Array:           return .Array
	case .Simd:            return .Simd
	case .Slice:           return .Slice
	case .Dynamic_Array:   return .Dynamic_Array
	case .Map:             return .Map
	case .Struct:          return .Struct
	case .Enum:            return .Enum
	case .Union:           return .Union
	case .Proc:            return .Proc
	case .String:          return .String
	case .String_View:     return .String_View
	case .CString_View:    return .CString_View
	case .Typeid:          return .Typeid
	case .Dyn:             return .Dyn
	case .Allocator:       return .Allocator
	case .Allocator_Error: return .Allocator_Error
	case .Box:             return .Box
	}
	return .Invalid
}

// A metadata record from its fields in `TYPE_INFO_LAYOUT` order, which the
// checker pinned.
@(private = "file")
record_constant :: proc(e: ^Emitter, record: Type_Id, values: []string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{")
	for field, index in underlying_info(e.c, record).fields {
		fmt.sbprintf(&b, "%s %s %s", index > 0 ? "," : "", llvm_type(e, symbol_of(e.c, field).type), values[index])
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// design.md "`type` and `typeid`": the zero, an out-of-range, or a forged id
// gives the `Invalid` entry, which is entry 0.
@(private)
emit_type_info_of :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	safe := typeid_index(e, emit_expr(e, v.bound[0]))
	return gep_at(e, struct_name(e, e.c.runtime_types["Type_Info"]), generated_name(e, TYPE_INFO_TABLE), safe)
}

// `id` clamped into a table of every `typeid`: a nil or out-of-range id maps to
// the empty entry 0.
@(private)
typeid_index :: proc(e: ^Emitter, id: string) -> string {
	past, safe := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %d", past, id, len(e.c.typeid_order))
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", safe, past, id)
	return safe
}
