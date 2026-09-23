// Compile-time reflection, `type_of`/`typeid_of`, and the `typeid` freeze pass.
//
// `meta.Field` and `meta.Enum_Value` are compiler-owned nominal struct types
// whose values are ordinary `Const_Aggregate`s, reusing the existing constant
// representation instead of inventing a third one. A descriptor is kept out of
// runtime storage by the `descriptor` marker on its type.
//
// `typeid` is symbolic during checking — a `typeid_of(T)` constant carries the
// canonical `Type_Id` — and numeric only after `freeze_typeids`. This keeps
// traversal and instantiation discovery order from changing an observable ID,
// and keeps zero reserved for the nil `typeid`.
package lokec

import "core:fmt"
import "core:slice"
import "core:strings"

// ------------------------------------------------------- descriptor types --

meta_field_type :: proc(c: ^Compiler) -> Type_Id {
	if c.meta_field_type != INVALID_TYPE {
		return c.meta_field_type
	}
	c.meta_field_type = new_descriptor_type(c, "meta.Field", []Descriptor_Field {
		{"name", TYPE_STRING_VIEW, false},
		{"type", TYPE_TYPE, false},
		{"index", TYPE_INT, false},
		{"owner", TYPE_TYPE, true},
	})
	return c.meta_field_type
}

META_FIELD_NAME :: 0
META_FIELD_TYPE :: 1
META_FIELD_INDEX :: 2
META_FIELD_OWNER :: 3

meta_enum_value_type :: proc(c: ^Compiler) -> Type_Id {
	if c.meta_enum_value_type != INVALID_TYPE {
		return c.meta_enum_value_type
	}
	c.meta_enum_value_type = new_descriptor_type(c, "meta.Enum_Value", []Descriptor_Field {
		{"name", TYPE_STRING_VIEW, false},
		{"value", TYPE_INT, false},
		{"index", TYPE_INT, false},
		{"owner", TYPE_TYPE, true},
	})
	return c.meta_enum_value_type
}

META_ENUM_NAME :: 0
META_ENUM_VALUE :: 1
META_ENUM_INDEX :: 2
META_ENUM_OWNER :: 3

// A descriptor names the type it was reflected from, so it describes that type
// alone and compares equal only to itself. `hidden` keeps that member out of
// reach: a non-public symbol of no package is visible from none.
@(private = "file")
Descriptor_Field :: struct {
	name:   string,
	type:   Type_Id,
	hidden: bool,
}

@(private = "file")
new_descriptor_type :: proc(c: ^Compiler, name: string, fields: []Descriptor_Field) -> Type_Id {
	name_id := intern_identifier(c, name)
	type := new_type(c, Type_Info{kind = .Struct, name = name_id, descriptor = true})
	members := make([]Symbol_Id, len(fields), c.semantic_allocator)
	for entry, index in fields {
		members[index] = new_symbol(c, Symbol {
			name   = intern_identifier(c, entry.name),
			span   = no_span(),
			kind   = .Field,
			type   = entry.type,
			index  = u32(index),
			public = !entry.hidden,
		})
	}
	if info := type_of(c, type); info != nil {
		info.fields = members
	}
	return type
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
	if under == TYPE_TYPE || (under != INVALID_TYPE && (under == c.meta_field_type || under == c.meta_enum_value_type)) {
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
compile_time_only_component :: proc(c: ^Compiler, id: Type_Id, depth := 0) -> Type_Id {
	if id == INVALID_TYPE || depth > 32 {
		return INVALID_TYPE // a recursive nominal type; its own declaration is checked once
	}
	if type_is_compile_time_only(c, id) {
		return id
	}
	info := underlying_info(c, id)
	if info == nil {
		return INVALID_TYPE
	}
	components := [?]Type_Id{info.element, info.key, info.result}
	for component in components {
		if found := compile_time_only_component(c, component, depth + 1); found != INVALID_TYPE {
			return found
		}
	}
	for parameter in info.parameters {
		if found := compile_time_only_component(c, parameter, depth + 1); found != INVALID_TYPE {
			return found
		}
	}
	for variant in info.variants {
		if found := compile_time_only_component(c, variant, depth + 1); found != INVALID_TYPE {
			return found
		}
	}
	if info.kind == .Struct {
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym == nil {
				continue
			}
			if found := compile_time_only_component(c, sym.type, depth + 1); found != INVALID_TYPE {
				return found
			}
		}
	}
	return INVALID_TYPE
}

// ---------------------------------------------------------- descriptors --

@(private = "file")
string_view_const :: proc(text: string) -> Const_Value {
	return Const_Value{kind = .String, text = text}
}

// The `[N]meta.Field` a `fields_of(T)` call folds to. design.md: reflection
// observes only what is visible from the lookup package, so an array formed
// inside the declaring package cannot leak fields an importer may not name.
@(private = "file")
fields_descriptor_array :: proc(k: ^Checker, subject: Type_Id) -> (Type_Id, Const_Value, bool) {
	info := underlying_info(k.c, subject)
	if info == nil || info.kind != .Struct || info.descriptor {
		return INVALID_TYPE, Const_Value{}, false
	}
	descriptor := meta_field_type(k.c)
	elements := make([dynamic]Const_Value, 0, len(info.fields), k.c.semantic_allocator)
	for member in info.fields {
		sym := symbol_of(k.c, member)
		if sym == nil || !member_is_visible(k, sym) {
			continue
		}
		values := make([]Const_Value, 4, k.c.semantic_allocator)
		values[META_FIELD_NAME] = string_view_const(identifier_text(k.c, sym.name))
		values[META_FIELD_TYPE] = type_const(sym.type)
		// A filtered descriptor still addresses the field's physical slot in the
		// original record; its position in this compact array is not a storage index.
		values[META_FIELD_INDEX] = int_const(k.c, i64(sym.index))
		values[META_FIELD_OWNER] = type_const(subject)
		append(&elements, aggregate_const(k.c, descriptor, values))
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
		values := make([]Const_Value, 4, k.c.semantic_allocator)
		values[META_ENUM_NAME] = string_view_const(identifier_text(k.c, sym.name))
		values[META_ENUM_VALUE] = sym.const_value
		values[META_ENUM_INDEX] = int_const(k.c, i64(sym.index))
		values[META_ENUM_OWNER] = type_const(subject)
		append(&elements, aggregate_const(k.c, descriptor, values))
	}
	return descriptor_array(k.c, descriptor, elements[:])
}

@(private = "file")
descriptor_array :: proc(c: ^Compiler, element: Type_Id, elements: []Const_Value) -> (Type_Id, Const_Value, bool) {
	type := array_of(c, element, u64(len(elements)))
	return type, aggregate_const(c, type, elements), true
}

@(private = "file")
aggregate_const :: proc(c: ^Compiler, type: Type_Id, elements: []Const_Value) -> Const_Value {
	aggregate := new(Const_Aggregate, c.semantic_allocator)
	aggregate.type = type
	aggregate.elements = elements
	return Const_Value{kind = .Aggregate, type_value = type, aggregate = aggregate}
}

// ------------------------------------------------------------- typeid --

@(private = "file")
typeid_const :: proc(type: Type_Id) -> Const_Value {
	return Const_Value{kind = .Type, type_value = type}
}

// Whether a constant of this value and type names a type, as an alias does.
// `typeid_of(T)` folds to the same constant kind, but its type says it is a
// runtime `typeid` value, which is a value and never a type.
const_names_type :: proc(c: ^Compiler, value: Const_Value, type: Type_Id) -> bool {
	return value.kind == .Type && type_underlying(c, type) != TYPE_TYPEID
}

request_typeid :: proc(c: ^Compiler, type: Type_Id) {
	if type == INVALID_TYPE || c.speculation_depth > 0 {
		return
	}
	if _, seen := c.typeid_requested[type]; seen {
		return
	}
	if c.typeid_frozen {
		emission_contract_error(c, "a new typeid was requested after freezing")
		return
	}
	c.typeid_requested[type] = true
	append(&c.typeid_order, type)
}

// One type and the canonical key it sorts by, so the comparison reads the key
// off its own element rather than out of a captured table.
@(private = "file")
Ranked_Type :: struct {
	key:  string,
	type: Type_Id,
}

// After semantic discovery is complete, every requested concrete type is sorted
// by a stable canonical key and given a deterministic nonzero `u64`. Zero stays
// the nil `typeid`; the mapping can't move on account of traversal order.
freeze_typeids :: proc(c: ^Compiler) {
	if c.typeid_frozen {
		return
	}
	// design.md's public metadata names element, key, field, variant, parameter,
	// and result types, so each must be resolvable through `type_info_of` too.
	// Closing the set here, before ids are assigned, makes a recursive walk of
	// the metadata terminate at a real entry rather than nil.
	if c.type_info_requested || c.format_requested {
		for index := 0; index < len(c.typeid_order); index += 1 {
			request_referenced_typeids(c, c.typeid_order[index])
		}
	}
	c.typeid_frozen = true
	// Sorting key-and-type pairs keeps the comparison non-capturing, which is what
	// `slice.stable_sort_by` needs; the sort is stable so equal keys keep request order.
	sorted := make([]Ranked_Type, len(c.typeid_order), c.semantic_allocator)
	for type, index in c.typeid_order {
		sorted[index] = Ranked_Type{typeid_sort_key(c, type), type}
	}
	slice.stable_sort_by(sorted, proc(a, b: Ranked_Type) -> bool { return a.key < b.key })
	for entry, index in sorted {
		c.typeid_values[entry.type] = u64(index) + 1
	}
}

// Every type the public metadata of `type` names. The walk is iterative over
// `typeid_order`, which this appends to, so a cycle through a record field
// terminates on the already-requested check.
@(private = "file")
request_referenced_typeids :: proc(c: ^Compiler, type: Type_Id) {
	consider :: proc(c: ^Compiler, referenced: Type_Id) {
		if referenced == INVALID_TYPE || !type_is_supported(c, referenced) {
			return
		}
		if type_is_compile_time_only(c, referenced) {
			return
		}
		request_typeid(c, referenced)
	}
	// A `distinct` entry names only the type it is declared over, whose own entry
	// carries the shape.
	if info := type_of(c, type); info != nil && info.kind == .Distinct {
		consider(c, info.element)
		return
	}
	under := underlying_info(c, type)
	if under == nil {
		return
	}
	consider(c, under.element)
	consider(c, under.key)
	if under.kind == .Struct {
		for field in under.fields {
			if sym := symbol_of(c, field); sym != nil {
				consider(c, sym.type)
			}
		}
	}
	for variant in under.variants {
		consider(c, variant)
	}
	for parameter in under.parameters {
		consider(c, parameter)
	}
	consider(c, under.result)
}

// A symbol's package-qualified identity. A bare identifier is not one: two
// packages may both declare `Token`.
@(private = "file")
symbol_key :: proc(c: ^Compiler, id: Symbol_Id) -> string {
	sym := symbol_of(c, id)
	if sym == nil {
		return "<none>"
	}
	pkg_key := ""
	if pkg := package_of(c, sym.pkg); pkg != nil {
		pkg_key = pkg.key
	}
	return fmt.aprintf(
		"%s:%s", pkg_key, identifier_text(c, sym.name),
		allocator = c.semantic_allocator,
	)
}

@(private = "file")
write_applied_args :: proc(
	c: ^Compiler,
	b: ^strings.Builder,
	args: []Generic_Arg,
	memo: ^map[Type_Id]string,
	visiting: ^map[Type_Id]bool,
) {
	for arg in args {
		if arg.is_type {
			fmt.sbprintf(b, ":t{%s}", typeid_sort_key_walk(c, arg.type, memo, visiting))
		} else {
			fmt.sbprintf(b, ":v{%s}", const_key_text(c, arg.value))
		}
	}
}

// A canonical identity independent of both request order and the internal
// Type_Id allocation order. A readable `name` is never an identity — `Token`,
// `Box(Token)` and `dyn Drawable` are each a spelling two unrelated types can
// share — so a nominal type keys on its package-qualified symbol, an applied
// type on what it was applied to plus each argument's own key, and a structural
// type on its complete recursive shape.
typeid_sort_key :: proc(c: ^Compiler, type: Type_Id) -> string {
	// Scratch: only the keys themselves live in the semantic arena.
	memo := make(map[Type_Id]string, context.temp_allocator)
	visiting := make(map[Type_Id]bool, context.temp_allocator)
	return typeid_sort_key_walk(c, type, &memo, &visiting)
}

// Memoization makes the key proportional to the type graph rather than its
// expanded tree. `visiting` is an explicit cycle detector: valid recursive
// types cross a nominal name and never recur structurally; malformed by-value
// cycles get one stable sentinel until the finite-size pass rejects them. The
// memo is per top-level call, which keeps that sentinel out of an unrelated
// type's key.
@(private = "file")
typeid_sort_key_walk :: proc(
	c: ^Compiler,
	type: Type_Id,
	memo: ^map[Type_Id]string,
	visiting: ^map[Type_Id]bool,
) -> (result: string) {
	if key, found := memo^[type]; found {
		return key
	}
	if visiting^[type] {
		return "000:<invalid-recursive-type>"
	}
	visiting^[type] = true
	defer {
		visiting^[type] = false
		memo^[type] = result
	}

	// The predeclared table holds distinct language identities with identical
	// shapes (e.g. `int` and `i64` on a 64-bit target). Catalogue position is
	// fixed by the language, but the readable name keeps the key independent of
	// both that internal position and request order.
	if type < FIRST_DYNAMIC_TYPE {
		return fmt.aprintf("predeclared:%s", type_name(c, type), allocator = c.semantic_allocator)
	}
	info := type_of(c, type)
	if info == nil {
		return "000:<invalid>"
	}
	if info.instance_of != INVALID_SYMBOL {
		b := strings.builder_make(c.semantic_allocator)
		fmt.sbprintf(&b, "instance:%s", symbol_key(c, info.instance_of))
		// A template declared in an `impl` block shares its name with the
		// templates of every other block on the same owner.
		if template := symbol_of(c, info.instance_of);
		   template != nil && template.owner_type != INVALID_TYPE {
			fmt.sbprintf(&b, ":o{%s}", typeid_sort_key_walk(c, template.owner_type, memo, visiting))
		}
		write_applied_args(c, &b, info.instance_args, memo, visiting)
		return strings.to_string(b)
	}
	if info.symbol != INVALID_SYMBOL && symbol_of(c, info.symbol) != nil {
		return fmt.aprintf("nominal:%s", symbol_key(c, info.symbol), allocator = c.semantic_allocator)
	}
	// The ordered field names plus each field type's own key — the same vector
	// `anon_record_type` interns on.
	if info.anonymous_record {
		b := strings.builder_make(c.semantic_allocator)
		strings.write_string(&b, "anon-record")
		for field in info.fields {
			member := symbol_of(c, field)
			if member == nil {
				continue
			}
			fmt.sbprintf(
				&b, ":f%s{%s}", identifier_text(c, member.name),
				typeid_sort_key_walk(c, member.type, memo, visiting),
			)
		}
		return strings.to_string(b)
	}
	// A `dyn` type carries no symbol of its own; the erased interface and its
	// arguments are the identity.
	if info.dyn_interface != INVALID_SYMBOL {
		b := strings.builder_make(c.semantic_allocator)
		fmt.sbprintf(&b, "dyn:%t:%s", info.mutable, symbol_key(c, info.dyn_interface))
		write_applied_args(c, &b, info.dyn_args, memo, visiting)
		return strings.to_string(b)
	}
	// Predeclared and compiler-owned named identities are unique compilation-wide.
	if info.name != INVALID_IDENTIFIER {
		return fmt.aprintf(
			"named:%d:%s", int(info.kind), identifier_text(c, info.name),
			allocator = c.semantic_allocator,
		)
	}
	b := strings.builder_make(c.semantic_allocator)
	fmt.sbprintf(
		&b, "shape:%d:b%d:s%t:m%t:a%d", int(info.kind), info.bits,
		info.signed, info.mutable, info.written_align,
	)
	if info.element != INVALID_TYPE {
		fmt.sbprintf(&b, ":e{%s}", typeid_sort_key_walk(c, info.element, memo, visiting))
	}
	if info.key != INVALID_TYPE {
		fmt.sbprintf(&b, ":k{%s}", typeid_sort_key_walk(c, info.key, memo, visiting))
	}
	if info.count != 0 {
		fmt.sbprintf(&b, ":n%d", info.count)
	}
	for parameter, index in info.parameters {
		mode := index < len(info.param_modes) ? int(info.param_modes[index]) : 0
		reset := index < len(info.param_resets) && info.param_resets[index]
		by_ptr := index < len(info.param_by_ptr) && info.param_by_ptr[index]
		fmt.sbprintf(
			&b, ":p%d:%t:%t{%s}", mode, reset, by_ptr,
			typeid_sort_key_walk(c, parameter, memo, visiting),
		)
	}
	if info.result != INVALID_TYPE {
		fmt.sbprintf(
			&b, ":r%t{%s}", info.result_inout,
			typeid_sort_key_walk(c, info.result, memo, visiting),
		)
	}
	if info.convention != "" {
		fmt.sbprintf(&b, ":c{%s}", info.convention)
	}
	if info.c_vararg {
		fmt.sbprint(&b, ":cvararg")
	}
	if sym := symbol_of(c, info.proc_contract); sym != nil {
		pkg := package_of(c, sym.pkg)
		path := int(sym.span.file) < len(c.sources) ? c.sources[sym.span.file].path : ""
		fmt.sbprintf(&b, ":contract{%s:%s:%s:%d}", pkg == nil ? "" : pkg.key, path, identifier_text(c, sym.name), sym.span.lo)
	}
	return strings.to_string(b)
}

typeid_value :: proc(c: ^Compiler, type: Type_Id) -> u64 {
	if value, found := c.typeid_values[type]; found {
		return value
	}
	return 0
}

// ------------------------------------------------------------- checking --

check_reflection_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.value_category = .Value
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0322", "`%s` takes 1 argument, found %d", ident.name, len(v.args))
		v.type = INVALID_TYPE
		return
	}
	operand := v.args[0].value

	if kind == .Type_Of {
		// design.md: the operand is inspected, not evaluated.
		type := resolve_type_syntax(k, operand)
		if type == INVALID_TYPE {
			type = check_single_expr(k, operand)
		}
		if type == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		v.type = TYPE_TYPE
		v.is_const = true
		v.const_value = type_const(default_type(k.c, type))
		v.denoted_type = v.const_value.type_value
		v.value_category = .Type
		return
	}

	// The remaining three take a type. `typeid_of(type_of(x))` therefore works
	// without a second spelling.
	subject := resolve_type_syntax(k, operand)
	if subject == INVALID_TYPE {
		if type := check_single_expr(k, operand); type != INVALID_TYPE {
			if base := expr_base(operand); base != nil && const_names_type(k.c, base.const_value, type) {
				subject = base.const_value.type_value
			}
		}
	}
	if subject == INVALID_TYPE {
		errorf(k.c, expr_span(operand), "L0451", "`%s` needs a type", ident.name)
		v.type = INVALID_TYPE
		return
	}

	#partial switch kind {
	case .Typeid_Of:
		// A `typeid` names a runtime type. Answered ahead of `gate_type` so the
		// diagnostic names the real reason rather than the generic storage one.
		if type_is_compile_time_only(k.c, subject) {
			errorf(
				k.c, expr_span(operand), "L0451",
				"`%s` exists only during compilation, so it has no `typeid`",
				type_name(k.c, subject),
			)
			v.type = INVALID_TYPE
			return
		}
		if !gate_type(k, subject, expr_span(operand)) {
			v.type = INVALID_TYPE
			return
		}
		request_typeid(k.c, subject)
		v.type = TYPE_TYPEID
		v.is_const = true
		v.const_value = typeid_const(subject)

	case .Fields_Of:
		type, value, ok := fields_descriptor_array(k, subject)
		if !ok {
			errorf(k.c, expr_span(operand), "L0451", "`fields_of` needs a struct type, found `%s`", type_name(k.c, subject))
			v.type = INVALID_TYPE
			return
		}
		v.type = type
		v.is_const = true
		v.const_value = value

	case .Enum_Values_Of:
		type, value, ok := enum_values_descriptor_array(k, subject)
		if !ok {
			errorf(k.c, expr_span(operand), "L0451", "`enum_values_of` needs an enum type, found `%s`", type_name(k.c, subject))
			v.type = INVALID_TYPE
			return
		}
		v.type = type
		v.is_const = true
		v.const_value = value
	}
}

// ------------------------------------------------- `field.get`/`field.pointer` --

// design.md: both take a `^T` so one expansion body can use either without
// restructuring its parameter, and the result type follows the descriptor
// constant — which is why this is a builtin rather than a method.
check_descriptor_operation :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	base := expr_base(sel.operand)
	if base == nil || !base.is_const || base.const_value.kind != .Aggregate {
		return false
	}
	// `meta_field_type` stays INVALID_TYPE until something names `meta.Field`, and
	// so does `base.type` after an earlier error: never let those two match.
	if k.c.meta_field_type == INVALID_TYPE || base.type != k.c.meta_field_type {
		return false
	}
	op := Reflect_Op.None
	switch sel.name.text {
	case "get":
		op = .Field_Get
	case "pointer":
		op = .Field_Pointer
	case:
		return false
	}

	aggregate := base.const_value.aggregate
	if aggregate == nil || len(aggregate.elements) != 4 {
		return false
	}
	owner := aggregate.elements[META_FIELD_OWNER].type_value
	field_index, _ := bi_to_i64(k.c, aggregate.elements[META_FIELD_INDEX].integer)

	v.value_category = .Value
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0452", "`field.%s` takes 1 argument, found %d", sel.name.text, len(v.args))
		v.type = INVALID_TYPE
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
		v.type = INVALID_TYPE
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
		v.type = INVALID_TYPE
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
		v.type = INVALID_TYPE
		return true
	}

	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
	v.operation = Call_Reflect{op = op, field = field}
	v.resolution = Resolution{kind = .Field, symbol = field}
	if op == .Field_Get {
		// The field itself, as `field.pointer(value)^` names it: a place, so a
		// binding copies it and nothing drops it as a temporary. Read-only
		// whatever the pointer's capability; writes go through `field.pointer`.
		v.type = sym.type
		v.value_category = .Place
		v.addressable = true
		v.immutable = .Read_Only
	} else {
		// `field.pointer` projects the subject pointer, so it carries the
		// subject's capability through: a `^mut T` yields a writable field
		// pointer, a `^T` a read-only one.
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
