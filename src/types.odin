// Questions about a type in the semantic stores: its kind and shape, the walks
// over its components, and its printed name.
package lokec

import "core:fmt"
import "core:mem"
import "core:strings"

type_of :: proc(c: ^Compiler, id: Type_Id) -> ^Type_Info {
	index := int(id)
	if index < 0 || index >= len(c.types) {
		return nil
	}
	return c.types[index]
}

type_kind :: proc(c: ^Compiler, id: Type_Id) -> Type_Kind {
	info := type_of(c, id)
	return info == nil ? .Invalid : info.kind
}

// The number of value bits in a scalar type. An enum reports its backing width.
type_bits :: proc(c: ^Compiler, id: Type_Id) -> int {
	info := underlying_info(c, id)
	return info == nil ? 0 : int(info.bits)
}

type_signed :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	return info != nil && info.signed
}

// A distinct type is a fresh identity but keeps the *shape* of what it wraps,
// which is what layout, folding, and lowering need.
type_underlying :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	current := id
	// A valid chain cannot visit more types than the compilation owns, which
	// bounds the walk without an arbitrary nesting limit. An invalid cycle
	// returns a member of itself; the finite-size pass diagnoses it.
	for _ in 0 ..< len(c.types) + 1 {
		info := type_of(c, current)
		if info == nil || info.kind != .Distinct || info.element == INVALID_TYPE {
			return current
		}
		current = info.element
	}
	return current
}

// A distinct type answers structural questions through what it wraps, so these
// two are the pairing almost every query wants.
underlying_info :: proc(c: ^Compiler, id: Type_Id) -> ^Type_Info {
	return type_of(c, type_underlying(c, id))
}

underlying_kind :: proc(c: ^Compiler, id: Type_Id) -> Type_Kind {
	return type_kind(c, type_underlying(c, id))
}

type_is_untyped :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return type_kind(c, id) in Type_Kinds{.Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil, .Untyped_String}
}

type_is_integer :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) in Type_Kinds{.Int, .Untyped_Int}
}

type_is_rune :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) in Type_Kinds{.Rune, .Untyped_Rune}
}

type_is_float :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) in Type_Kinds{.Float, .Untyped_Float}
}

type_is_boolean :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) in Type_Kinds{.Bool, .Untyped_Bool}
}

type_is_enum :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Enum
}

type_is_box :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Box
}

type_is_pointer :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) in Type_Kinds{.Pointer, .Raw_Pointer, .Proc}
}

// Integer-like for the purposes of arithmetic: an enum is deliberately absent
// (design.md "Arithmetic operators").
type_is_numeric :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return type_is_integer(c, id) || type_is_float(c, id) || type_is_rune(c, id)
}

type_is_aggregate :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) in Type_Kinds{.Struct, .Array}
}

// The type an untyped value takes when nothing else selects one
// (design.md "Unfixed constants").
default_type :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	#partial switch type_kind(c, id) {
	case .Untyped_Int:
		return TYPE_INT
	case .Untyped_Float:
		return TYPE_F64
	case .Untyped_Bool:
		return TYPE_BOOL
	case .Untyped_Rune:
		return TYPE_RUNE
	case .Untyped_Nil:
		return INVALID_TYPE // `x := nil` has no type to infer
	case .Untyped_String:
		// design.md "string type": an untyped string literal defaults to the
		// owning `string`, and a `string_view` parameter borrows it from there.
		return TYPE_STRING
	}
	return id
}

// grammar.md "Records": a `_` field is padding, a member with no name.
field_is_padding :: proc(c: ^Compiler, field: Symbol_Id) -> bool {
	sym := symbol_of(c, field)
	return sym != nil && sym.kind == .Field && sym.name == INVALID_IDENTIFIER
}

// design.md "Anonymous records": an unlabelled record's fields are named by
// their positions, `0`, `1`, ..., which no selector or literal element can
// spell. The names keep it apart from every labelled record when interned.
positional_field_name :: proc(c: ^Compiler, position: int) -> Identifier_Id {
	return intern_identifier(c, fmt.tprintf("%d", position))
}

field_is_positional :: proc(c: ^Compiler, field: Symbol_Id) -> bool {
	sym := symbol_of(c, field)
	return sym != nil && sym.kind == .Field && name_is_positional(identifier_text(c, sym.name))
}

name_is_positional :: proc(text: string) -> bool {
	return len(text) > 0 && text[0] >= '0' && text[0] <= '9'
}

// design.md "Implicit type conversions": a labelled anonymous record converts
// to the unlabelled one with its field types, dropping the names. Nothing
// converts the other way, or between two sets of names.
record_drops_labels_to :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	info := type_of(c, from)
	return info != nil && info.anonymous_record && info.unlabelled != INVALID_TYPE && info.unlabelled == to
}

// The type whose backend representation a record shares: the unlabelled
// counterpart of a labelled anonymous record, so dropping the labels emits
// nothing, as weakening a carrier emits nothing.
record_abi_type :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	info := type_of(c, type)
	if info != nil && info.anonymous_record && info.unlabelled != INVALID_TYPE {
		return info.unlabelled
	}
	return type
}

// What reflection and formatting call a field: a positional field has no name.
field_label :: proc(c: ^Compiler, field: Symbol_Id) -> string {
	if field_is_positional(c, field) {
		return ""
	}
	sym := symbol_of(c, field)
	return sym == nil ? "" : identifier_text(c, sym.name)
}

// A record's fields without its padding: what a literal's positional elements,
// destructuring, and reflection see. Read-only: without padding this is
// `info.fields` itself.
named_fields :: proc(c: ^Compiler, info: ^Type_Info) -> []Symbol_Id {
	count := named_field_count(c, info)
	if count == len(info.fields) {
		return info.fields
	}
	out := make([dynamic]Symbol_Id, 0, count, c.semantic_allocator)
	for field in info.fields {
		if !field_is_padding(c, field) {
			append(&out, field)
		}
	}
	return out[:]
}

named_field_count :: proc(c: ^Compiler, info: ^Type_Info) -> int {
	count := 0
	for field in info.fields {
		if !field_is_padding(c, field) {
			count += 1
		}
	}
	return count
}

// The slot of a record's `position`-th named field, which a padding field
// before it moves past its position.
named_field_slot :: proc(c: ^Compiler, info: ^Type_Info, position: int) -> int {
	seen := 0
	for field, slot in info.fields {
		if field_is_padding(c, field) {
			continue
		}
		if seen == position {
			return slot
		}
		seen += 1
	}
	return position
}

// Whether any component of this type never resolved. Told apart from
// "unsupported" so an unsupported-type error is not reported for a component
// that was already rejected where it was written.
type_mentions_invalid :: proc(c: ^Compiler, id: Type_Id) -> bool {
	seen: Type_Walk
	defer delete(seen)
	return type_contains_invalid(c, id, &seen)
}

// The types a walk over a type's components has entered: the nominal ones, since
// a recursive type can only refer back to itself through one, and the structural
// ones with several components, since a chain of aliases naming the previous one
// twice would otherwise take a walk exponential time. A type met again answers
// the walk's neutral value: its own declaration is checked once, and a walk stops
// at its first decisive answer, so a finished visit was neutral too. A record
// diagnosed as containing itself by value still reaches body checking, so every
// walk needs this guard.
Type_Walk :: map[Type_Id]struct{}

// Whether `id` is new to the walk, recording it when the walk has to.
type_walk_enter :: proc(seen: ^Type_Walk, id: Type_Id, info: ^Type_Info) -> bool {
	#partial switch info.kind {
	case .Struct, .Union, .Distinct, .Map, .Proc:
		if id in seen {
			return false
		}
		seen[id] = {}
	}
	return true
}

// Every type `info` is built from, in the temp allocator; some may be INVALID_TYPE.
type_components :: proc(c: ^Compiler, info: ^Type_Info) -> []Type_Id {
	components := make([dynamic]Type_Id, 0, 3 + len(info.parameters) + len(info.variants) + len(info.fields), context.temp_allocator)
	append(&components, info.element, info.key, info.result)
	append(&components, ..info.parameters)
	append(&components, ..info.variants)
	if info.kind == .Struct {
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil {
				append(&components, sym.type)
			}
		}
	}
	return components[:]
}

@(private = "file")
type_contains_invalid :: proc(c: ^Compiler, id: Type_Id, seen: ^Type_Walk) -> bool {
	info := type_of(c, id)
	if info == nil || !type_walk_enter(seen, id, info) {
		return false
	}
	// Exhaustive on purpose: a new composed `Type_Kind` must not quietly answer
	// "no invalid part" the way a scalar correctly does.
	switch info.kind {
	case .Invalid:
		return true
	case .Void, .Bool, .Int, .Float, .Rune, .Enum, .Raw_Pointer, .Typeid,
	     .String, .String_View, .CString_View, .Dyn, .Interface, .Type,
	     .Allocator, .Allocator_Error,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		return false
	case .Pointer, .C_Pointer, .Slice, .Dynamic_Array, .Box, .Array, .Simd, .Distinct:
		return type_contains_invalid(c, info.element, seen)
	case .Map:
		return type_contains_invalid(c, info.key, seen) ||
		       type_contains_invalid(c, info.element, seen)
	case .Union:
		for variant in info.variants {
			if type_contains_invalid(c, variant, seen) {
				return true
			}
		}
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil || type_contains_invalid(c, symbol.type, seen) {
				return true
			}
		}
	case .Proc:
		for parameter in info.parameters {
			if type_contains_invalid(c, parameter, seen) {
				return true
			}
		}
		// design.md: a procedure with no result carries INVALID_TYPE for one, which
		// is the absence of a result rather than a type that failed to resolve.
		return info.result != INVALID_TYPE && type_contains_invalid(c, info.result, seen)
	}
	return false
}

type_is_supported :: proc(c: ^Compiler, id: Type_Id) -> bool {
	walk := Support_Walk{finished = true}
	defer delete(walk.seen)
	if !type_is_supported_walk(c, id, &walk) {
		return false
	}
	if walk.finished {
		for reached in walk.seen {
			type_of(c, reached).known_supported = true
		}
	}
	return true
}

// Whether no record `id` reaches is still waiting for its fields, so a question
// about what it holds has its final answer.
type_records_finished :: proc(c: ^Compiler, id: Type_Id) -> bool {
	walk := Support_Walk{finished = true}
	defer delete(walk.seen)
	type_is_supported_walk(c, id, &walk)
	return walk.finished
}

@(private = "file")
Support_Walk :: struct {
	seen:     Type_Walk,
	// No record reached is still waiting for its fields.
	finished: bool,
}

@(private = "file")
type_is_supported_walk :: proc(c: ^Compiler, id: Type_Id, walk: ^Support_Walk) -> bool {
	info := type_of(c, id)
	if info == nil {
		return false
	}
	if info.known_supported || !type_walk_enter(&walk.seen, id, info) {
		return true
	}
	if info.descriptor {
		return false // a descriptor exists only during compilation
	}
	#partial switch info.kind {
	// A string form is a runtime carrier: its borrow provenance is checked by
	// `src/borrow.odin` rather than restricted here.
	case .Void, .Bool, .Int, .Float, .Rune, .Raw_Pointer, .Type, .Typeid, .Dyn, .Enum,
	     .Allocator, .Allocator_Error, .String, .String_View, .CString_View,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		return true
	// design.md "C pointers": a documented trust boundary, not an unsupported
	// type — no length, no capability, and no lifetime check after conversion.
	case .Pointer, .C_Pointer, .Slice, .Dynamic_Array, .Box, .Array, .Simd, .Distinct:
		return type_is_supported_walk(c, info.element, walk)
	case .Map:
		return type_is_supported_walk(c, info.key, walk) &&
		       type_is_supported_walk(c, info.element, walk)
	case .Union:
		walk.finished &&= record_finished(c, info)
		for variant in info.variants {
			if !type_is_supported_walk(c, variant, walk) {
				return false
			}
		}
		return true
	case .Struct:
		walk.finished &&= record_finished(c, info)
		for field in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil || !type_is_supported_walk(c, symbol.type, walk) {
				return false
			}
		}
		return true
	case .Proc:
		for parameter in info.parameters {
			if !type_is_supported_walk(c, parameter, walk) {
				return false
			}
		}
		if info.result != INVALID_TYPE && !type_is_supported_walk(c, info.result, walk) {
			return false
		}
		return true
	}
	return false
}

// Whether a record's declaration has given it its fields. A compiler-made or
// structural one has them from the start.
@(private = "file")
record_finished :: proc(c: ^Compiler, info: ^Type_Info) -> bool {
	sym := symbol_of(c, info.symbol)
	return sym == nil || sym.decl == nil || sym.decl.sig_state == .Checked
}

// Indexed by `Type_Id`, so a new predeclared type is added here beside its
// constant instead of in a third switch that has to be kept in step.
// `TYPE_ALLOCATOR` and `TYPE_ALLOCATOR_ERROR` are deliberately absent: they
// print under the nominal name `build_universe` gives them.
@(private = "file")
PREDECLARED_NAMES := [int(FIRST_DYNAMIC_TYPE)]string {
	INVALID_TYPE         = "<invalid>",
	TYPE_VOID            = "()",
	TYPE_BOOL            = "bool",
	TYPE_I8              = "i8",
	TYPE_I16             = "i16",
	TYPE_I32             = "i32",
	TYPE_I64             = "i64",
	TYPE_I128            = "i128",
	TYPE_U8              = "u8",
	TYPE_U16             = "u16",
	TYPE_U32             = "u32",
	TYPE_U64             = "u64",
	TYPE_U128            = "u128",
	TYPE_INT             = "int",
	TYPE_UINT            = "uint",
	TYPE_UINTPTR         = "uintptr",
	TYPE_F16             = "f16",
	TYPE_F32             = "f32",
	TYPE_F64             = "f64",
	TYPE_RUNE            = "rune",
	TYPE_RAWPTR          = "rawptr",
	TYPE_TYPE            = "type",
	TYPE_STRING          = "string",
	TYPE_TYPEID          = "typeid",
	TYPE_UNTYPED_INT     = "untyped int",
	TYPE_UNTYPED_FLOAT   = "untyped float",
	TYPE_UNTYPED_BOOL    = "untyped bool",
	TYPE_UNTYPED_RUNE    = "untyped rune",
	TYPE_UNTYPED_NIL     = "untyped nil",
	TYPE_UNTYPED_STRING  = "untyped string",
	TYPE_STRING_VIEW     = "string_view",
	TYPE_CSTRING_VIEW    = "cstring_view",
}

type_name :: proc(c: ^Compiler, id: Type_Id) -> string {
	return type_name_alloc(c, id, c.semantic_allocator)
}

// Queries format names in their own arena without allocating semantic state.
type_name_alloc :: proc(c: ^Compiler, id: Type_Id, allocator: mem.Allocator) -> string {
	if int(id) < len(PREDECLARED_NAMES) && PREDECLARED_NAMES[id] != "" {
		return PREDECLARED_NAMES[id]
	}
	info := type_of(c, id)
	if info == nil {
		return "<invalid>"
	}
	if info.name != INVALID_IDENTIFIER {
		return identifier_text(c, info.name)
	}
	#partial switch info.kind {
	case .Pointer:
		return fmt.aprintf("^%s%s", info.mutable ? "mut " : "", type_name_alloc(c, info.element, allocator), allocator = allocator)
	case .C_Pointer:
		return fmt.aprintf("[^]%s", type_name_alloc(c, info.element, allocator), allocator = allocator)
	case .Array:
		return fmt.aprintf("[%d]%s", info.count, type_name_alloc(c, info.element, allocator), allocator = allocator)
	case .Simd:
		return fmt.aprintf("Simd(%s, %d)", type_name_alloc(c, info.element, allocator), info.count, allocator = allocator)
	case .Slice:
		return fmt.aprintf("[]%s%s", info.mutable ? "mut " : "", type_name_alloc(c, info.element, allocator), allocator = allocator)
	case .Dynamic_Array:
		return fmt.aprintf("[dynamic]%s", type_name_alloc(c, info.element, allocator), allocator = allocator)
	case .Box:
		return fmt.aprintf("Box(%s)", type_name_alloc(c, info.element, allocator), allocator = allocator)
	case .Map:
		return fmt.aprintf("map[%s]%s", type_name_alloc(c, info.key, allocator), type_name_alloc(c, info.element, allocator), allocator = allocator)
	case .Distinct:
		return fmt.aprintf("distinct %s", type_name_alloc(c, info.element, allocator), allocator = allocator)
	case .Struct:
		return "struct"
	case .Enum:
		return "enum"
	case .Union:
		return "union"
	case .Interface:
		return "interface"
	case .Proc:
		return proc_type_name(c, info, allocator)
	}
	return "<type>"
}

// Everything in the type's identity prints, or a mismatch report names the same
// text twice.
@(private = "file")
proc_type_name :: proc(c: ^Compiler, info: ^Type_Info, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "proc")
	if info.convention != "" {
		fmt.sbprintf(&b, " %q", info.convention)
	}
	strings.write_string(&b, "(")
	for parameter, index in info.parameters {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		if index < len(info.param_resets) && info.param_resets[index] {
			strings.write_string(&b, "@(allocator_reset) ")
		}
		if index < len(info.param_cross_thread) && info.param_cross_thread[index] {
			strings.write_string(&b, "@(cross_thread) ")
		}
		if index < len(info.param_escapes) && info.param_escapes[index] != .Result {
			strings.write_string(&b, "@(escape=")
			strings.write_string(&b, escape_level_name(info.param_escapes[index]))
			strings.write_string(&b, ") ")
		}
		if index < len(info.param_by_ptr) && info.param_by_ptr[index] {
			strings.write_string(&b, "@(by_ptr) ")
		}
		if index < len(info.param_modes) {
			#partial switch info.param_modes[index] {
			case .Inout:  strings.write_string(&b, "inout ")
			case .Borrow: strings.write_string(&b, "^")
			case .Move:   strings.write_string(&b, "move ")
			}
		}
		strings.write_string(&b, type_name_alloc(c, parameter, allocator))
	}
	if info.c_vararg {
		strings.write_string(&b, len(info.parameters) > 0 ? ", .." : "..")
	}
	strings.write_string(&b, ")")
	if info.result != INVALID_TYPE {
		strings.write_string(&b, " -> ")
		if info.result_inout {
			strings.write_string(&b, "inout ")
		}
		strings.write_string(&b, type_name_alloc(c, info.result, allocator))
	}
	if sym := symbol_of(c, info.proc_contract); sym != nil {
		fmt.sbprintf(&b, " [result contract: %s]", identifier_text(c, sym.name))
	}
	return strings.to_string(b)
}
