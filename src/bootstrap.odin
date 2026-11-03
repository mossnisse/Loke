// The `base:runtime` bootstrap (design.md "Typed fallibility"). `Unit`, `Option`,
// `Result`, `Status`, the shared handles and their constructors are ordinary
// runtime source bound into the universe, so the compiler and a program name one
// declaration each rather than two that print the same.
package lokec

import "core:fmt"
import "core:slice"


@(private = "file")
Bootstrap_Kind :: enum {
	Type,
	// A type, or a parametric alias of one: `Status :: Result(Unit, $E)`.
	Type_Or_Alias,
	Proc_Group,
}

// Called for every package, and acts once, when `base:runtime`'s names exist.
// Every name is looked up so each missing one is reported, and whatever was found is still bound.
bind_runtime_bootstrap :: proc(k: ^Checker, pkg: ^Package) {
	c := k.c
	if c.bootstrap_ready || pkg.key != STD_RUNTIME {
		return
	}
	c.bootstrap_ready = true

	unit := bootstrap_symbol(k, pkg, "Unit", .Type)
	c.option_symbol = bootstrap_symbol(k, pkg, "Option", .Type)
	c.result_symbol = bootstrap_symbol(k, pkg, "Result", .Type)
	bootstrap_symbol(k, pkg, "Status", .Type_Or_Alias)
	// design.md "Shared ownership".
	c.shared_symbol = bootstrap_symbol(k, pkg, "Shared", .Type)
	c.weak_symbol = bootstrap_symbol(k, pkg, "Weak", .Type)
	c.shared_construct_symbol = bootstrap_symbol(k, pkg, "shared", .Proc_Group)
	c.try_shared_symbol = bootstrap_symbol(k, pkg, "try_shared", .Proc_Group)
	if sym := symbol_of(c, unit); sym != nil {
		c.unit_type = sym.type
	}

	// design.md "Container insertion": `Status(Allocator_Error)`.
	c.alloc_result_type = result_type(k, c.unit_type, TYPE_ALLOCATOR_ERROR)
}

// Binds the name into the universe when `base:runtime` declares it as wanted.
@(private = "file")
bootstrap_symbol :: proc(k: ^Checker, pkg: ^Package, name: string, want: Bootstrap_Kind) -> Symbol_Id {
	name_id := intern_identifier(k.c, name)
	id := pkg.scope.names[name_id]
	found := false
	if sym := symbol_of(k.c, id); sym != nil {
		switch want {
		case .Type:
			found = sym.kind == .Type
		case .Type_Or_Alias:
			found = sym.kind == .Type || declaration_generic_kind(sym.decl) == .Alias
		case .Proc_Group:
			// A group's symbol kind is settled only when its signature resolves.
			found = sym.decl != nil && decl_is_proc_group(sym.decl)
		}
	}
	if found {
		k.c.universe.names[name_id] = id
		return id
	}
	errorf(
		k.c, NO_SPAN, "L0704",
		"`base:runtime` must declare `%s` as a %s; the compiler cannot bootstrap without it",
		name, want == .Proc_Group ? "procedure group" : "type",
	)
	return INVALID_SYMBOL
}

// `Option(T)`, through the one generic instance cache.
option_type :: proc(k: ^Checker, payload: Type_Id, span := Span{}) -> Type_Id {
	if payload == INVALID_TYPE {
		return INVALID_TYPE
	}
	return instantiate_record_types(k, k.c.option_symbol, []Type_Id{payload}, span)
}

result_type :: proc(k: ^Checker, payload, error: Type_Id) -> Type_Id {
	if payload == INVALID_TYPE || error == INVALID_TYPE {
		return INVALID_TYPE
	}
	return instantiate_record_types(k, k.c.result_symbol, []Type_Id{payload, error}, Span{})
}

// An instance of `Shared(T)` or `Weak(T)`? design.md "Shared ownership" rejects
// `via` on either.
type_is_shared_handle :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := type_of(c, type_underlying(c, id))
	return info != nil && info.instance_of != INVALID_SYMBOL &&
	       (info.instance_of == c.shared_symbol || info.instance_of == c.weak_symbol)
}

// The payload type of a `Shared(T)` or `Weak(T)`, or INVALID_TYPE. The record
// holds its block as a `rawptr`, so the compiler supplies what the handle
// carries: its payload's borrows (design.md "Values that contain borrows").
shared_payload_type :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	if !type_is_shared_handle(c, id) {
		return INVALID_TYPE
	}
	info := type_of(c, type_underlying(c, id))
	if len(info.instance_args) != 1 || !info.instance_args[0].is_type {
		return INVALID_TYPE
	}
	return info.instance_args[0].type
}

// `shared(value)` or `try_shared(value)`: the payload it takes, and whether its
// result is a `Result`. Nil for any other call.
shared_constructor_payload :: proc(c: ^Compiler, v: ^Expr_Call) -> (payload: Expr, fallible: bool) {
	chosen := symbol_of(c, v.resolution.chosen_overload)
	if chosen == nil || len(v.bound) == 0 {
		return nil, false
	}
	template := chosen.instance_of != INVALID_SYMBOL ? chosen.instance_of : v.resolution.chosen_overload
	for group, index in ([2]Symbol_Id{c.shared_construct_symbol, c.try_shared_symbol}) {
		if members := symbol_of(c, group); members != nil && slice.contains(members.members, template) {
			return v.bound[0], index == 1
		}
	}
	return nil, false
}

// ------------------------------------------------- declarations it must match --

// A type declared by `base:runtime`, recorded for the emitter's metadata tables.
// The runtime is loaded for every program, so a built-in producing one of its
// types needs no import, as `Option` and `Result` need none (design.md
// "`caller_location()`"). The compiler writes these records field by field and
// their enums as numbers, so the declaration is checked against `layout` once:
// a mismatch is reported and gives INVALID_TYPE, still `resolved`.
runtime_type_named :: proc(k: ^Checker, name: string, layout: []Runtime_Field) -> (Type_Id, bool) {
	if recorded, checked := k.c.runtime_types[name]; checked {
		return recorded, true
	}
	runtime := standard_package(k.c, STD_RUNTIME)
	// An unimported runtime has not been checked yet.
	type, found := package_type_named(k, runtime, name)
	if !found {
		return INVALID_TYPE, false
	}
	if !runtime_layout_matches(k, type, layout) {
		errorf(
			k.c, symbol_of(k.c, package_symbol_named(k.c, runtime, name)).span, "L0704",
			"`runtime.%s` does not have the layout the compiler writes: the same fields, in the same order, with the same types, and enum members in design.md's order",
			name,
		)
		// A speculative check's diagnostic is rolled back, so only a real one
		// may settle the answer.
		if !committing(k.c) {
			return INVALID_TYPE, true
		}
		type = INVALID_TYPE
	}
	k.c.runtime_types[name] = type
	return type, true
}

// `base:runtime.Memory_Order`, found by name and cached. INVALID_TYPE when it is
// missing or its members differ from the compiler's `Memory_Order`.
memory_order_type :: proc(k: ^Checker) -> Type_Id {
	if k.c.memory_order_type != INVALID_TYPE {
		return k.c.memory_order_type
	}
	type, found := package_type_named(k, standard_package(k.c, STD_RUNTIME), "Memory_Order")
	if !found || !runtime_enum_matches(k.c, type, Memory_Order) {
		return INVALID_TYPE
	}
	k.c.memory_order_type = type
	return type
}

// The public `Type_Kind` and `Member_Kind`, in the order `base:runtime`
// declares them. The emitter writes their values as these indices.
Runtime_Type_Kind :: enum {
	Invalid, Void, Bool, Signed_Int, Unsigned_Int, Float, Rune,
	Raw_Pointer, Pointer, C_Pointer, Array, Slice, Dynamic_Array, Map,
	Struct, Enum, Union, Proc, String, String_View, CString_View,
	Typeid, Dyn, Distinct, Simd, Allocator, Allocator_Error, Box,
}

Runtime_Member_Kind :: enum { Field, Enum_Value, Union_Variant, Parameter, Result }

Runtime_Field :: struct {
	name, type: string,
}

SOURCE_CODE_LOCATION_LAYOUT := [?]Runtime_Field {
	{"file", "string_view"}, {"procedure", "string_view"}, {"line", "int"}, {"column", "int"},
}

TYPE_INFO_LAYOUT := [?]Runtime_Field {
	{"id", "typeid"}, {"kind", "Type_Kind"}, {"name", "string_view"}, {"size", "int"},
	{"align", "int"}, {"bits", "int"}, {"signed", "bool"}, {"element", "typeid"},
	{"key", "typeid"}, {"count", "int"}, {"members", "[]Member_Info"},
}

MEMBER_INFO_LAYOUT := [?]Runtime_Field {
	{"kind", "Member_Kind"}, {"name", "string_view"}, {"type", "typeid"},
	{"offset", "int"}, {"value_low", "u64"}, {"value_high", "u64"},
}

// Does a `base:runtime` enum declare exactly `E`'s members, by name, in order,
// with each value its index? The compiler writes these values as numbers.
@(private = "file")
runtime_enum_matches :: proc(c: ^Compiler, type: Type_Id, $E: typeid) -> bool {
	info := type_of(c, type)
	if info == nil || info.kind != .Enum || len(info.fields) != len(E) {
		return false
	}
	for member, index in info.fields {
		sym := symbol_of(c, member)
		value, fits := bi_to_i64(c, sym.const_value.integer)
		if sym.name != intern_identifier(c, fmt.tprint(E(index))) || !fits || value != i64(index) {
			return false
		}
	}
	return true
}

@(private = "file")
runtime_layout_matches :: proc(k: ^Checker, type: Type_Id, layout: []Runtime_Field) -> bool {
	c := k.c
	info := type_of(c, type)
	if info == nil || info.kind != .Struct || len(info.fields) != len(layout) {
		return false
	}
	for field, index in info.fields {
		sym := symbol_of(c, field)
		if identifier_text(c, sym.name) != layout[index].name || type_name(c, sym.type) != layout[index].type {
			return false
		}
		if kind := type_of(c, sym.type); kind != nil && kind.kind == .Enum {
			resolve_symbol_signature_in_place(k, kind.symbol)
		}
		switch layout[index].type {
		case "Type_Kind":
			if !runtime_enum_matches(c, sym.type, Runtime_Type_Kind) {
				return false
			}
		case "Member_Kind":
			if !runtime_enum_matches(c, sym.type, Runtime_Member_Kind) {
				return false
			}
		}
	}
	return true
}
