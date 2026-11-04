// Compile-time reflection and `type_of`/`typeid_of`.
//
// `meta.Field`, `meta.Enum_Value`, and `meta.Variant` are compiler-owned nominal struct types
// whose values are ordinary `Const_Aggregate`s. A descriptor is kept out of
// runtime storage by the `descriptor` marker on its type.
package lokec

// ------------------------------------------------------- descriptor types --

// Every descriptor's members, in this order. The payload is what it says of the
// thing it names: a `meta.Field`'s or `meta.Variant`'s `type`, a `meta.Enum_Value`'s
// `value`.
META_NAME :: 0
META_PAYLOAD :: 1
META_INDEX :: 2
META_OWNER :: 3

meta_field_type :: proc(c: ^Compiler) -> Type_Id {
	return descriptor_type(c, &c.meta_field_type, "meta.Field", "type", TYPE_TYPE)
}

meta_enum_value_type :: proc(c: ^Compiler) -> Type_Id {
	return descriptor_type(c, &c.meta_enum_value_type, "meta.Enum_Value", "value", TYPE_INT)
}

meta_variant_type :: proc(c: ^Compiler) -> Type_Id {
	return descriptor_type(c, &c.meta_variant_type, "meta.Variant", "type", TYPE_TYPE)
}

// A descriptor names the type it was reflected from, so it describes that type
// alone and compares equal only to itself. That member is out of reach: a
// non-public symbol of no package is visible from none.
@(private = "file")
descriptor_type :: proc(c: ^Compiler, slot: ^Type_Id, name, payload_name: string, payload: Type_Id) -> Type_Id {
	if slot^ != INVALID_TYPE {
		return slot^
	}
	slot^ = new_type(c, Type_Info{kind = .Struct, name = intern_identifier(c, name), descriptor = true})
	members := make([]Symbol_Id, 4, c.semantic_allocator)
	members[META_NAME] = new_field(c, "name", TYPE_STRING_VIEW, META_NAME, public = true)
	members[META_PAYLOAD] = new_field(c, payload_name, payload, META_PAYLOAD, public = true)
	members[META_INDEX] = new_field(c, "index", TYPE_INT, META_INDEX, public = true)
	members[META_OWNER] = new_field(c, "owner", TYPE_TYPE, META_OWNER)
	type_of(c, slot^).fields = members
	return slot^
}

type_is_descriptor :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	return info != nil && info.descriptor
}

// design.md: a `type` value and a reflection descriptor exist only during
// compilation, so neither may be the type of runtime storage.
type_is_compile_time_only :: proc(c: ^Compiler, id: Type_Id) -> bool {
	under := type_underlying(c, id)
	if under == TYPE_TYPE || type_is_descriptor(c, under) {
		return true
	}
	if info := type_of(c, under); info != nil && info.kind == .Array {
		return type_is_compile_time_only(c, info.element)
	}
	return false
}

// A value reflection folds: `type`, a descriptor, or a fixed array of them. An
// iteration view over one is compile-time-only too, but is never folded; static
// `foreach` peels it instead.
type_is_reflection_value :: proc(c: ^Compiler, id: Type_Id) -> bool {
	under := type_underlying(c, id)
	if under == TYPE_TYPE || (under != INVALID_TYPE && (under == c.meta_field_type || under == c.meta_enum_value_type || under == c.meta_variant_type)) {
		return true
	}
	if info := type_of(c, under); info != nil && info.kind == .Array {
		return type_is_reflection_value(c, info.element)
	}
	return false
}

// `type_is_supported` rejects a whole shape when a compile-time-only type sits
// anywhere inside it, so `proc(f: meta.Field)` has no name of its own to blame.
// This finds the component to blame, or INVALID_TYPE. Driven off the recorded
// components rather than an exhaustive kind switch: a kind this misses falls
// back to the generic gate, which is where it already was.
compile_time_only_component :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	seen: Type_Walk
	defer delete(seen)
	return compile_time_only_walk(c, id, &seen)
}

@(private = "file")
compile_time_only_walk :: proc(c: ^Compiler, id: Type_Id, seen: ^Type_Walk) -> Type_Id {
	if id == INVALID_TYPE {
		return INVALID_TYPE
	}
	if type_is_compile_time_only(c, id) {
		return id
	}
	if own := type_of(c, id); own == nil || !type_walk_enter(seen, id, own) {
		return INVALID_TYPE
	}
	info := underlying_info(c, id)
	if info == nil {
		return INVALID_TYPE
	}
	for component in type_components(c, info) {
		if found := compile_time_only_walk(c, component, seen); found != INVALID_TYPE {
			return found
		}
	}
	return INVALID_TYPE
}

// ---------------------------------------------------------- descriptors --

@(private = "file")
descriptor_const :: proc(c: ^Compiler, type: Type_Id, name: string, payload: Const_Value, index: int, owner: Type_Id) -> Const_Value {
	values := make([]Const_Value, 4, c.semantic_allocator)
	values[META_NAME] = string_const(name)
	values[META_PAYLOAD] = payload
	values[META_INDEX] = int_const(c, i64(index))
	values[META_OWNER] = type_const(owner)
	return aggregate_const(c, type, values)
}

// The `[N]meta.Field` a `fields_of(T)` call folds to. design.md: reflection
// observes only what is visible from the lookup package.
@(private = "file")
fields_descriptor_array :: proc(k: ^Checker, subject: Type_Id) -> (Type_Id, Const_Value, bool) {
	info := underlying_info(k.c, subject)
	if info == nil || info.kind != .Struct || info.descriptor {
		return INVALID_TYPE, Const_Value{}, false
	}
	descriptor := meta_field_type(k.c)
	elements := make([dynamic]Const_Value, 0, len(info.fields), k.c.semantic_allocator)
	for member in named_fields(k.c, info) {
		sym := symbol_of(k.c, member)
		if sym == nil || !member_is_visible(k, sym) {
			continue
		}
		// A filtered descriptor still addresses the field's physical slot in the
		// original record; its position in this compact array is not a storage index.
		append(&elements, descriptor_const(k.c, descriptor, field_label(k.c, member), type_const(sym.type), int(sym.index), subject))
	}
	return descriptor_array(k.c, descriptor, elements[:])
}

// Enum members carry no visibility of their own: the grammar has no
// `@(private)` on one, and an importer that can name the enum can name `.Red`.
// Filtering them would disagree with both name lookup and the runtime
// `type_info_of` table, which lists every member.
@(private = "file")
enum_values_descriptor_array :: proc(k: ^Checker, subject: Type_Id) -> (Type_Id, Const_Value, bool) {
	info := underlying_info(k.c, subject)
	if info == nil || info.kind != .Enum {
		return INVALID_TYPE, Const_Value{}, false
	}
	descriptor := meta_enum_value_type(k.c)
	elements := make([dynamic]Const_Value, 0, len(info.fields), k.c.semantic_allocator)
	for member in info.fields {
		sym := symbol_of(k.c, member)
		if sym == nil {
			continue
		}
		append(&elements, descriptor_const(k.c, descriptor, identifier_text(k.c, sym.name), sym.const_value, int(sym.index), subject))
	}
	return descriptor_array(k.c, descriptor, elements[:])
}

// Every member and variant is listed (design.md "Compile-time reflection"); an
// enum member's value stays enum_values_of's.
@(private = "file")
variants_descriptor_array :: proc(k: ^Checker, subject: Type_Id) -> (Type_Id, Const_Value, bool) {
	info := underlying_info(k.c, subject)
	if info == nil || (info.kind != .Enum && info.kind != .Union) {
		return INVALID_TYPE, Const_Value{}, false
	}
	descriptor := meta_variant_type(k.c)
	if info.kind == .Enum {
		elements := make([dynamic]Const_Value, 0, len(info.fields), k.c.semantic_allocator)
		for member in info.fields {
			if sym := symbol_of(k.c, member); sym != nil {
				append(&elements, descriptor_const(k.c, descriptor, identifier_text(k.c, sym.name), type_const(k.c.unit_type), int(sym.index), subject))
			}
		}
		return descriptor_array(k.c, descriptor, elements[:])
	}
	elements := make([]Const_Value, len(info.variants), k.c.semantic_allocator)
	for _, index in info.variants {
		elements[index] = variant_descriptor(k.c, subject, index)
	}
	return descriptor_array(k.c, descriptor, elements)
}

// The `meta.Variant` describing variant `index` of `subject`, which an
// expanded switch case binds (design.md "Per-variant switch cases").
variant_descriptor :: proc(c: ^Compiler, subject: Type_Id, index: int) -> Const_Value {
	payload := union_variant_payload(c, subject, index)
	return descriptor_const(
		c, meta_variant_type(c), union_variant_name(c, subject, index),
		type_const(payload_value_type(c, payload)), index, subject,
	)
}

@(private = "file")
descriptor_array :: proc(c: ^Compiler, element: Type_Id, elements: []Const_Value) -> (Type_Id, Const_Value, bool) {
	type := array_of(c, element, u64(len(elements)))
	return type, aggregate_const(c, type, elements), true
}

// ------------------------------------------------------------- checking --

check_reflection_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	// Positional value arguments only (design.md "Parameters").
	if !builtin_arguments_ok(k, v) {
		return
	}
	if !builtin_argument_count_ok(k, v, ident.name, "L0322", 1) {
		return
	}
	operand := v.args[0].value
	// The type reading comes first. It is silent for non-type syntax, so an error
	// means broken type syntax, which the value reading would report again.
	before := k.c.error_count
	denoted := resolve_type_syntax(k, operand)
	read_value := denoted == INVALID_TYPE && k.c.error_count == before

	if kind == .Type_Of {
		// design.md: the operand is inspected, not evaluated.
		type := read_value ? check_single_expr(k, operand) : denoted
		if type == INVALID_TYPE {
			return
		}
		v.type = TYPE_TYPE
		v.const_value = type_const(default_type(k.c, type))
		v.denoted_type = v.const_value.type_value
		v.value_category = .Type
		return
	}

	// The remaining four take a type. `typeid_of(type_of(x))` therefore works
	// without a second spelling.
	subject := denoted
	if read_value {
		if type := check_single_expr(k, operand); type != INVALID_TYPE {
			if base := expr_base(operand); base != nil && const_names_type(k.c, base.const_value, type) {
				subject = base.const_value.type_value
			}
		}
	}
	if subject == INVALID_TYPE {
		if k.c.error_count == before {
			errorf(k.c, expr_span(operand), "L0451", "`%s` needs a type", ident.name)
		}
		return
	}

	if kind == .Typeid_Of {
		// A `typeid` names a runtime type. Answered ahead of `gate_type` so the
		// diagnostic names the real reason rather than the generic storage one.
		if type_is_compile_time_only(k.c, subject) {
			errorf(
				k.c, expr_span(operand), "L0451",
				"`%s` exists only during compilation, so it has no `typeid`",
				type_name(k.c, subject),
			)
			return
		}
		if !gate_type(k, subject, expr_span(operand)) {
			return
		}
		request_typeid(k.c, subject)
		v.type = TYPE_TYPEID
		v.const_value = type_const(subject)
		return
	}

	type: Type_Id
	value: Const_Value
	ok: bool
	wanted: string
	#partial switch kind {
	case .Fields_Of:
		type, value, ok = fields_descriptor_array(k, subject)
		wanted = "a struct"
	case .Enum_Values_Of:
		type, value, ok = enum_values_descriptor_array(k, subject)
		wanted = "an enum"
	case .Variants_Of:
		type, value, ok = variants_descriptor_array(k, subject)
		wanted = "a union or enum"
	}
	if !ok {
		errorf(k.c, expr_span(operand), "L0451", "`%s` needs %s type, found `%s`", ident.name, wanted, type_name(k.c, subject))
		return
	}
	v.type = type
	v.const_value = value
}

// ------------------------------------------------- `field.get`/`field.pointer` --

// design.md: both take a `^T` so one expansion body can use either without
// restructuring its parameter, and the result type follows the descriptor
// constant — which is why this is a builtin rather than a method. The operand is
// a plain name, so checking it again when this returns false is harmless.
check_descriptor_operation :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	ident, is_ident := sel.operand.(^Expr_Ident)
	if !is_ident {
		return false
	}
	named := ident_symbol(k, ident)
	if named == nil || named.kind != .Const || !type_is_descriptor(k.c, named.type) {
		return false
	}
	check_receiver(k, sel)
	base := expr_base(sel.operand)
	if base == nil || base.const_value.kind != .Aggregate {
		return false
	}
	// `meta_field_type` stays INVALID_TYPE until something names `meta.Field`, and
	// so does `base.type` after an earlier error: never let those two match.
	if k.c.meta_field_type == INVALID_TYPE || base.type != k.c.meta_field_type {
		return false
	}
	op: Reflect_Op
	switch sel.name.text {
	case "get":
		op = .Field_Get
	case "pointer":
		op = .Field_Pointer
	case:
		return false
	}

	elements := base.const_value.aggregate.elements
	owner := elements[META_OWNER].type_value
	field_index, _ := bi_to_i64(k.c, elements[META_INDEX].integer)

	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0452", "`field.%s` takes 1 argument, found %d", sel.name.text, len(v.args))
		return true
	}
	// Compiler-defined, so it has no parameter to name or mode to accept
	// (design.md "Parameters").
	if !builtin_arguments_ok(k, v) {
		check_single_expr(k, v.args[0].value)
		return true
	}
	operand_type := check_single_expr(k, v.args[0].value)
	pointee := underlying_info(k.c, operand_type)
	if pointee == nil || pointee.kind != .Pointer {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0452",
			"`field.%s` takes a pointer to the reflected value, found `%s`",
			sel.name.text,
			type_name(k.c, operand_type),
		)
		return true
	}
	// The subject must be the type the descriptor was reflected from. A look-alike
	// record would otherwise lend its field names to another's private fields.
	record := underlying_info(k.c, owner)
	field := INVALID_SYMBOL
	if pointee.element == owner && record != nil && field_index >= 0 && int(field_index) < len(record.fields) {
		field = record.fields[field_index]
	}
	sym := symbol_of(k.c, field)
	if sym == nil {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0452",
			"this descriptor does not describe `%s`",
			type_name(k.c, pointee.element),
		)
		return true
	}

	// A packed field may be misaligned (design.md "@(packed)"); `get` stays
	// usable, and `&` on it is refused by `packed_field_reached`.
	if op == .Field_Pointer && record.packed {
		errorf(
			k.c, sel.name.span, "L0614",
			"cannot take the address of `%s`: it is reached through a packed struct",
			identifier_text(k.c, sym.name),
		)
		return true
	}

	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
	v.operation = Call_Reflect{op = op, field = field}
	v.resolution = Resolution{kind = .Field, symbol = field}
	// design.md "Compile-time reflection". `get` is a place, so nothing drops it as
	// a temporary.
	if op == .Field_Get {
		v.type = sym.type
		v.value_category = .Place
		v.addressable = true
		v.immutable = .Read_Only
	} else {
		v.type = pointer_to(k.c, sym.type, pointee.mutable)
	}
	return true
}

// ---------------------------------------------------------- diagnostics --

// A descriptor array or a `type` value cannot be materialised into runtime
// storage, and saying so beats the generic milestone gate.
report_compile_time_only :: proc(k: ^Checker, type: Type_Id, span: Span) {
	if type_underlying(k.c, type) == TYPE_TYPE {
		errorf(k.c, span, "L0378", "`type` is compile-time only and cannot be stored in a variable")
		return
	}
	errorf(
		k.c,
		span,
		"L0453",
		"`%s` exists only during compilation and cannot be stored at run time",
		type_name(k.c, type),
	)
}
