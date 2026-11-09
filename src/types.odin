// Questions about a type in the semantic stores: its kind and shape, the walks
// over its components, and its printed name.
package lokec

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

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

// `Allocator`, or a distinct type over it.
type_is_allocator :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return type_underlying(c, id) == TYPE_ALLOCATOR
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

// Whether a value of `type` may hold an address, checked or not: a carrier, a C
// pointer or `rawptr`, or an allocator, procedure, or interface value referring to
// storage elsewhere, inline or in what the value owns. Provenance follows only
// checked borrows; `unsafe.raw_data` leaves an address no borrow records, and a
// value of a type holding none cannot name a temporary at all. Only the queried
// type is cached, as `type_carries_borrow` caches: a walk answers `false` for a
// type it is already inside, which is right only for the walk.
type_may_hold_address :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if cached, found := c.may_hold_address[type]; found {
		return cached
	}
	seen: Type_Walk
	defer delete(seen)
	holds := type_may_hold_address_walk(c, type, &seen)
	c.may_hold_address[type] = holds
	return holds
}

@(private = "file")
type_may_hold_address_walk :: proc(c: ^Compiler, id: Type_Id, seen: ^Type_Walk) -> bool {
	if type_is_carrier(c, id) {
		return true
	}
	info := underlying_info(c, id)
	if info == nil || !type_walk_enter(seen, id, info) {
		return false
	}
	// What `type_is_carrier` leaves out: unchecked pointers, and the values that
	// refer to code or storage elsewhere without a carrier's provenance.
	#partial switch info.kind {
	case .Raw_Pointer, .C_Pointer, .Proc, .Interface:
		return true
	}
	for part in type_owned_parts(c, info) {
		if type_may_hold_address_walk(c, part, seen) {
			return true
		}
	}
	return false
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

// The types `info` is built from: in the temp allocator, or sharing its storage.
// INVALID_TYPE among them is a part that never resolved; what a kind does not have
// is left out. Exhaustive on purpose: a new composed `Type_Kind` must not quietly
// answer "no parts" the way a scalar correctly does.
type_parts :: proc(c: ^Compiler, info: ^Type_Info) -> []Type_Id {
	switch info.kind {
	case .Invalid, .Void, .Bool, .Int, .Float, .Rune, .Enum, .Raw_Pointer, .Typeid,
	     .String, .String_View, .CString_View, .Dyn, .Interface, .Type,
	     .Allocator, .Allocator_Error,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		return nil
	case .Pointer, .C_Pointer, .Slice, .Dynamic_Array, .Box, .Array, .Simd, .Distinct:
		return ([^]Type_Id)(&info.element)[:1]
	case .Map:
		parts := make([]Type_Id, 2, context.temp_allocator)
		parts[0], parts[1] = info.key, info.element
		return parts
	case .Union:
		return info.variants
	case .Struct:
		parts := make([]Type_Id, len(info.fields), context.temp_allocator)
		for field, index in info.fields {
			if symbol := symbol_of(c, field); symbol != nil {
				parts[index] = symbol.type
			}
		}
		return parts
	case .Proc:
		// design.md: a procedure with no result carries INVALID_TYPE for one, which
		// is the absence of a result rather than a type that failed to resolve.
		if info.result == INVALID_TYPE {
			return info.parameters
		}
		parts := make([]Type_Id, len(info.parameters) + 1, context.temp_allocator)
		copy(parts, info.parameters)
		parts[len(info.parameters)] = info.result
		return parts
	}
	return nil
}

// The parts a value owns, which are copied and dropped with it, as what a pointer
// or a procedure refers to is not.
type_owned_parts :: proc(c: ^Compiler, info: ^Type_Info) -> []Type_Id {
	#partial switch info.kind {
	case .Array, .Dynamic_Array, .Box, .Map, .Struct, .Union:
		return type_parts(c, info)
	}
	return nil
}

// Every type `info` records: its parts, and what a compiler-made record or an enum
// keeps beside them, an iterator's element and subject or the enum's backing type.
// Some may be INVALID_TYPE, for one it does not have.
type_components :: proc(c: ^Compiler, info: ^Type_Info) -> []Type_Id {
	parts := type_parts(c, info)
	if info.kind != .Struct && info.kind != .Enum {
		return parts
	}
	components := make([]Type_Id, 2 + len(parts), context.temp_allocator)
	components[0], components[1] = info.element, info.key
	copy(components[2:], parts)
	return components
}

@(private = "file")
type_contains_invalid :: proc(c: ^Compiler, id: Type_Id, seen: ^Type_Walk) -> bool {
	info := type_of(c, id)
	if info == nil || !type_walk_enter(seen, id, info) {
		return false
	}
	if info.kind == .Invalid {
		return true
	}
	for part in type_parts(c, info) {
		if type_contains_invalid(c, part, seen) {
			return true
		}
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
	// A descriptor exists only during compilation. A string form is a runtime
	// carrier, whose borrow provenance `src/borrow.odin` checks, and a C pointer is
	// a documented trust boundary (design.md "C pointers"): no length, no capability,
	// and no lifetime check after conversion. Neither is unsupported.
	if info.descriptor || info.kind == .Invalid || info.kind == .Interface {
		return false
	}
	if info.kind == .Struct || info.kind == .Union {
		walk.finished &&= record_finished(c, info)
	}
	for part in type_parts(c, info) {
		if !type_is_supported_walk(c, part, walk) {
			return false
		}
	}
	return true
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

// standard-library.md "Printed forms": a structural type prints in full, and an alias
// has no name of its own, so a chain of aliases each naming the last twice doubles
// its text at each step. A name past this length stops at `...`, so that printing one
// costs no more than this, whatever its depth. Identity never reads this text.
TYPE_NAME_LIMIT :: 4096

// Queries format names in their own arena without allocating semantic state.
type_name_alloc :: proc(c: ^Compiler, id: Type_Id, allocator: mem.Allocator) -> string {
	w := Type_Name_Writer{c = c, b = strings.builder_make(allocator)}
	write_type_name(&w, id)
	return strings.to_string(w.b)
}

@(private = "file")
Type_Name_Writer :: struct {
	c:   ^Compiler,
	b:   strings.Builder,
	cut: bool,
}

// Whether the name goes on; the first write past the limit ends it, and nothing that
// would close what is open is written after that.
@(private = "file")
type_name_open :: proc(w: ^Type_Name_Writer) -> bool {
	if !w.cut && strings.builder_len(w.b) >= TYPE_NAME_LIMIT {
		w.cut = true
		strings.write_string(&w.b, "...")
	}
	return !w.cut
}

@(private = "file")
type_name_text :: proc(w: ^Type_Name_Writer, text: string) {
	if !type_name_open(w) {
		return
	}
	room := TYPE_NAME_LIMIT - strings.builder_len(w.b)
	if len(text) <= room {
		strings.write_string(&w.b, text)
		return
	}
	// A generic instance's name is one such text, however long its arguments' are.
	for room > 0 && !utf8.rune_start(text[room]) {
		room -= 1
	}
	strings.write_string(&w.b, text[:room])
	w.cut = true
	strings.write_string(&w.b, "...")
}

@(private = "file")
write_type_name :: proc(w: ^Type_Name_Writer, id: Type_Id) {
	if !type_name_open(w) {
		return
	}
	c := w.c
	if int(id) < len(PREDECLARED_NAMES) && PREDECLARED_NAMES[id] != "" {
		type_name_text(w, PREDECLARED_NAMES[id])
		return
	}
	info := type_of(c, id)
	if info == nil {
		type_name_text(w, "<invalid>")
		return
	}
	if info.name != INVALID_IDENTIFIER {
		type_name_text(w, identifier_text(c, info.name))
		return
	}
	#partial switch info.kind {
	case .Pointer:
		type_name_text(w, info.mutable ? "^mut " : "^")
		write_type_name(w, info.element)
	case .C_Pointer:
		type_name_text(w, "[^]")
		write_type_name(w, info.element)
	case .Array:
		fmt.sbprintf(&w.b, "[%d]", info.count)
		write_type_name(w, info.element)
	case .Simd:
		type_name_text(w, "Simd(")
		write_type_name(w, info.element)
		if type_name_open(w) {
			fmt.sbprintf(&w.b, ", %d)", info.count)
		}
	case .Slice:
		type_name_text(w, info.mutable ? "[]mut " : "[]")
		write_type_name(w, info.element)
	case .Dynamic_Array:
		type_name_text(w, "[dynamic]")
		write_type_name(w, info.element)
	case .Box:
		type_name_text(w, "Box(")
		write_type_name(w, info.element)
		type_name_text(w, ")")
	case .Map:
		type_name_text(w, "map[")
		write_type_name(w, info.key)
		type_name_text(w, "]")
		write_type_name(w, info.element)
	case .Distinct:
		type_name_text(w, "distinct ")
		write_type_name(w, info.element)
	case .Struct:
		type_name_text(w, "struct")
	case .Enum:
		type_name_text(w, "enum")
	case .Union:
		type_name_text(w, "union")
	case .Interface:
		type_name_text(w, "interface")
	case .Proc:
		write_proc_type_name(w, info)
	case:
		type_name_text(w, "<type>")
	}
}

// Everything in the type's identity prints, or a mismatch report names the same
// text twice.
@(private = "file")
write_proc_type_name :: proc(w: ^Type_Name_Writer, info: ^Type_Info) {
	c := w.c
	type_name_text(w, "proc")
	if info.convention != "" && type_name_open(w) {
		fmt.sbprintf(&w.b, " %q", info.convention)
	}
	type_name_text(w, "(")
	for parameter, index in info.parameters {
		if index > 0 {
			type_name_text(w, ", ")
		}
		if index < len(info.param_resets) && info.param_resets[index] {
			type_name_text(w, "@(allocator_reset) ")
		}
		if index < len(info.param_cross_thread) && info.param_cross_thread[index] {
			type_name_text(w, "@(cross_thread) ")
		}
		if index < len(info.param_escapes) && info.param_escapes[index] != .Result {
			type_name_text(w, "@(escape=")
			type_name_text(w, escape_level_name(info.param_escapes[index]))
			type_name_text(w, ") ")
		}
		if index < len(info.param_by_ptr) && info.param_by_ptr[index] {
			type_name_text(w, "@(by_ptr) ")
		}
		#partial switch param_mode_at(info, index) {
		case .Inout:  type_name_text(w, "inout ")
		case .Borrow: type_name_text(w, "^")
		case .Move:   type_name_text(w, "move ")
		}
		write_type_name(w, parameter)
	}
	if info.c_vararg {
		type_name_text(w, len(info.parameters) > 0 ? ", .." : "..")
	}
	type_name_text(w, ")")
	if info.result != INVALID_TYPE {
		type_name_text(w, " -> ")
		if info.result_inout {
			type_name_text(w, "inout ")
		}
		write_type_name(w, info.result)
	}
	if sym := symbol_of(c, info.proc_contract); sym != nil && type_name_open(w) {
		fmt.sbprintf(&w.b, " [result contract: %s]", identifier_text(c, sym.name))
	}
}
