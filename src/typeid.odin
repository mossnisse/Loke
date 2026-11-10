// The `typeid` freeze pass and the canonical key types are numbered by.
//
// `typeid` is symbolic during checking — a `typeid_of(T)` constant carries the
// canonical `Type_Id` — and numeric only after `freeze_typeids`. This keeps
// traversal and instantiation discovery order from changing an observable ID,
// and keeps zero reserved for the nil `typeid`.
package lokec

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:slice"
import "core:strings"

// design.md "Invalid representations": every `typeid` bit pattern is a value,
// numbers no type has included. A constant read back from storage, as
// `unsafe.transmute(typeid, u64(7))` is, keeps that number in `integer` and
// names no type: types are numbered only by `freeze_typeids`, after discovery,
// so it cannot be matched to one while checking. Zero is the nil `typeid`,
// `type_const(INVALID_TYPE)`.
typeid_number_const :: proc(storage: Value_Storage, number: u64) -> Const_Value {
	if number == 0 {
		return type_const(INVALID_TYPE)
	}
	return Const_Value{kind = .Type, type_value = INVALID_TYPE, integer = bi_from_u64(storage, number)}
}

// The number a `typeid` constant holds when it is already known: the nil one's
// and a bit-cast one's. A `typeid_of(T)` constant's waits for `freeze_typeids`.
typeid_const_number :: proc(c: Value_Storage, value: Const_Value) -> (number: u64, known: bool) {
	if value.kind != .Type || value.type_value != INVALID_TYPE {
		return 0, false
	}
	if bi_is_zero(value.integer) {
		return 0, true
	}
	number, _ = bi_to_u64(c, value.integer)
	return number, true
}

// `==` between two `typeid` (or `type`) constants. A known number against a
// `typeid_of(T)` is undecided until `T` is numbered, except that no type is
// numbered zero.
type_consts_equal :: proc(c: Value_Storage, a, b: Const_Value) -> (equal: bool, known: bool) {
	left, left_known := typeid_const_number(c, a)
	right, right_known := typeid_const_number(c, b)
	switch {
	case left_known && right_known:
		return left == right, true
	case left_known:
		return false, left == 0
	case right_known:
		return false, right == 0
	}
	return a.type_value == b.type_value, true
}

// Whether a constant of this value and type names a type, as an alias does.
// `typeid_of(T)` folds to the same constant kind, but its type says it is a
// runtime `typeid` value, which is a value and never a type.
const_names_type :: proc(c: ^Compiler, value: Const_Value, type: Type_Id) -> bool {
	return value.kind == .Type && type_underlying(c, type) != TYPE_TYPEID
}

request_typeid :: proc(c: ^Compiler, type: Type_Id) {
	if type == INVALID_TYPE || !committing(c) {
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

// The keys made so far, and where new ones are made.
@(private = "file")
Sort_Keys :: struct {
	memo:      map[Type_Id]string,
	allocator: mem.Allocator,
}

@(private = "file")
Ranked_Type :: struct {
	key:  string,
	type: Type_Id,
}

// Numbers requested types by canonical key, from 1.
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
	// Every type is finished and the check was clean, so one memo can serve all
	// of them: no key holds the cycle sentinel. The keys are needed only to sort.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	keys := Sort_Keys{memo = make(map[Type_Id]string, context.temp_allocator), allocator = context.temp_allocator}
	// Sorting key-and-type pairs keeps the comparison non-capturing, which is what
	// `slice.stable_sort_by` needs; the sort is stable so equal keys keep request order.
	sorted := make([]Ranked_Type, len(c.typeid_order), context.temp_allocator)
	for type, index in c.typeid_order {
		sorted[index] = Ranked_Type{typeid_sort_key_walk(c, type, &keys), type}
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
	for component in type_components(c, under) {
		consider(c, component)
	}
}

// A symbol's package-qualified identity. A bare identifier is not one: two
// packages may both declare `Token`.
@(private = "file")
symbol_key :: proc(c: ^Compiler, id: Symbol_Id, allocator: mem.Allocator) -> string {
	sym := symbol_of(c, id)
	if sym == nil {
		return "<none>"
	}
	pkg_key := ""
	if pkg := package_of(c, sym.pkg); pkg != nil {
		pkg_key = pkg.key
	}
	return fmt.aprintf("%s:%s", pkg_key, identifier_text(c, sym.name), allocator = allocator)
}

// One constant in a value argument. A `typeid_of(T)` inside it keys as `T` does:
// the `Type_Id` that `const_key_text` spells follows allocation order.
@(private = "file")
write_value_key :: proc(c: ^Compiler, b: ^strings.Builder, value: Const_Value, keys: ^Sort_Keys) {
	#partial switch value.kind {
	case .Type:
		if number, known := typeid_const_number(c, value); known {
			fmt.sbprintf(b, "n%d", number)
		} else {
			fmt.sbprintf(b, "t{{%s}}", typeid_sort_key_walk(c, value.type_value, keys))
		}
	case .Aggregate:
		strings.write_string(b, "{")
		if value.aggregate != nil {
			// The variant leads: `.ok(1)` and `.err(1)` have the same elements.
			fmt.sbprintf(b, "%d", value.aggregate.variant)
			for element in value.aggregate.elements {
				strings.write_string(b, ",")
				write_value_key(c, b, element, keys)
			}
		}
		strings.write_string(b, "}")
	case:
		// Length-prefixed, as a string may hold anything a key is made of.
		text := const_key_text(c, value)
		fmt.sbprintf(b, "%d:%s", len(text), text)
	}
}

@(private = "file")
write_applied_args :: proc(c: ^Compiler, b: ^strings.Builder, args: []Generic_Arg, keys: ^Sort_Keys) {
	for arg in args {
		if arg.is_type {
			fmt.sbprintf(b, ":t{{%s}}", typeid_sort_key_walk(c, arg.type, keys))
		} else {
			strings.write_string(b, ":v{")
			write_value_key(c, b, arg.value, keys)
			strings.write_string(b, "}")
		}
	}
}

// A template applied to its arguments.
@(private = "file")
write_instance_identity :: proc(
	c: ^Compiler,
	b: ^strings.Builder,
	template_symbol: Symbol_Id,
	args: []Generic_Arg,
	keys: ^Sort_Keys,
) {
	write_symbol_identity(c, b, template_symbol, keys)
	// A template declared in an `impl` block shares its name with the
	// templates of every other block on the same owner.
	if template := symbol_of(c, template_symbol);
	   template != nil && template.owner_type != INVALID_TYPE {
		fmt.sbprintf(b, ":o{{%s}}", typeid_sort_key_walk(c, template.owner_type, keys))
	}
	write_applied_args(c, b, args, keys)
}

// The site's file as its position among the package's files, which are sorted by
// path, so the key does not depend on the order files were loaded.
@(private = "file")
declaring_file_index :: proc(c: ^Compiler, pkg_id: Package_Id, file: u32) -> int {
	if pkg := package_of(c, pkg_id); pkg != nil {
		for candidate, index in pkg.files {
			if candidate.file == file {
				return index
			}
		}
	}
	return 0
}

// Where something is written, and which copy of that text this is: the generic
// instances and static expansions around it.
@(private = "file")
write_site_key :: proc(c: ^Compiler, b: ^strings.Builder, site: Type_Site, keys: ^Sort_Keys) {
	fmt.sbprintf(b, "@%06d:%010d", declaring_file_index(c, site.pkg, site.span.file), site.span.lo)
	for scope := site.scope; scope != nil; scope = scope.parent {
		if instance := scope.instance; instance != nil {
			strings.write_string(b, ":in{")
			write_instance_identity(c, b, instance.template, generic_args_of(c, instance.bindings), keys)
			strings.write_string(b, "}")
		}
		if scope.expansion != 0 {
			fmt.sbprintf(b, ":x%d", scope.expansion)
		}
	}
}

// A symbol declared in a procedure shares its spelling with every other
// procedure's, and with itself in each copy of its text, so it also keys on where
// it is declared.
@(private = "file")
write_symbol_identity :: proc(c: ^Compiler, b: ^strings.Builder, id: Symbol_Id, keys: ^Sort_Keys) {
	strings.write_string(b, symbol_key(c, id, keys.allocator))
	if sym := symbol_of(c, id); sym != nil && sym.def_scope != nil && sym.def_scope.kind != .Package {
		write_site_key(c, b, Type_Site{sym.pkg, sym.span, sym.def_scope}, keys)
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
	keys := Sort_Keys{memo = make(map[Type_Id]string, context.temp_allocator), allocator = c.semantic_allocator}
	return typeid_sort_key_walk(c, type, &keys)
}

// A key past this length is replaced by a digest of it. A key holds its components'
// keys, so a chain of aliases each naming the last twice doubles it at each step.
SORT_KEY_LIMIT :: 1024

// Stands for `key` in whatever holds it: the same text gives the same digest in every
// build, and the digest's two seeds and the length keep two long keys apart.
@(private = "file")
bounded_sort_key :: proc(key: string, allocator: mem.Allocator) -> string {
	if len(key) <= SORT_KEY_LIMIT {
		return key
	}
	data := transmute([]u8)key
	return fmt.aprintf(
		"digest:%d:%x:%x", len(key), hash.fnv64a(data), hash.fnv64a(data, 0x9e3779b97f4a7c15),
		allocator = allocator,
	)
}

// A type being walked holds the memo's cycle sentinel: valid recursive types cross a
// nominal name and never recur structurally; malformed by-value cycles get that one
// stable key until the finite-size pass rejects them. A memo that can still meet one
// is per top-level call, which keeps the sentinel out of an unrelated type's key.
@(private = "file")
typeid_sort_key_walk :: proc(c: ^Compiler, type: Type_Id, keys: ^Sort_Keys) -> (result: string) {
	if key, found := keys.memo[type]; found {
		return key
	}
	keys.memo[type] = "000:<invalid-recursive-type>"
	defer {
		result = bounded_sort_key(result, keys.allocator)
		keys.memo[type] = result
	}

	// Distinct identities can share a shape (`int`, `i64`), so these key on their name.
	if type < FIRST_DYNAMIC_TYPE {
		return fmt.aprintf("predeclared:%s", type_name_alloc(c, type, keys.allocator), allocator = keys.allocator)
	}
	info := type_of(c, type)
	if info == nil {
		return "000:<invalid>"
	}
	b := strings.builder_make(keys.allocator)
	switch {
	case info.instance_of != INVALID_SYMBOL:
		strings.write_string(&b, "instance:")
		write_instance_identity(c, &b, info.instance_of, info.instance_args, keys)
	case symbol_of(c, info.symbol) != nil:
		strings.write_string(&b, "nominal:")
		write_symbol_identity(c, &b, info.symbol, keys)
	case info.anonymous_record:
		// The ordered field names plus each field type's own key — the same vector
		// `anon_record_type` interns on.
		strings.write_string(&b, "anon-record")
		for field in info.fields {
			member := symbol_of(c, field)
			if member == nil {
				continue
			}
			fmt.sbprintf(
				&b, ":f%s{{%s}}", identifier_text(c, member.name),
				typeid_sort_key_walk(c, member.type, keys),
			)
		}
	case info.anonymous_union:
		// The ordered labels plus each payload's own key, the vector
		// `anon_union_type` interns on.
		strings.write_string(&b, "anon-union")
		for payload, index in info.variants {
			fmt.sbprintf(&b, ":v%s", identifier_text(c, info.variant_names[index]))
			if payload != TYPE_VOID {
				fmt.sbprintf(&b, "{{%s}}", typeid_sort_key_walk(c, payload, keys))
			}
		}
	case info.dyn_interface != INVALID_SYMBOL:
		// A `dyn` type carries no symbol of its own; the erased interface and its
		// arguments are the identity.
		fmt.sbprintf(&b, "dyn:%t:", info.mutable)
		write_symbol_identity(c, &b, info.dyn_interface, keys)
		write_applied_args(c, &b, info.dyn_args, keys)
	case:
		write_shape_key(c, &b, info, keys)
	}
	return strings.to_string(b)
}

// A type with no symbol: what it is built from, the same vector `intern_type` and
// `intern_proc_type` intern on. A compiler-made type's name spells the kind of
// thing it is, but what it was made over is in its components.
@(private = "file")
write_shape_key :: proc(c: ^Compiler, b: ^strings.Builder, info: ^Type_Info, keys: ^Sort_Keys) {
	if info.name != INVALID_IDENTIFIER {
		fmt.sbprintf(b, "named:%d:%s", int(info.kind), identifier_text(c, info.name))
	} else {
		fmt.sbprintf(b, "shape:%d", int(info.kind))
	}
	fmt.sbprintf(b, ":m%t", info.mutable)
	if pkg := package_of(c, info.site.pkg); pkg != nil {
		fmt.sbprintf(b, ":pkg{{%s}}", pkg.key)
		if info.site.scope != nil {
			write_site_key(c, b, info.site, keys)
		}
	}
	if info.element != INVALID_TYPE {
		fmt.sbprintf(b, ":e{{%s}}", typeid_sort_key_walk(c, info.element, keys))
	}
	if info.key != INVALID_TYPE {
		fmt.sbprintf(b, ":k{{%s}}", typeid_sort_key_walk(c, info.key, keys))
	}
	if info.count != 0 {
		fmt.sbprintf(b, ":n%d", info.count)
	}
	for parameter, index in info.parameters {
		mode := int(param_mode_at(info, index))
		reset := index < len(info.param_resets) && info.param_resets[index]
		by_ptr := index < len(info.param_by_ptr) && info.param_by_ptr[index]
		escape := index < len(info.param_escapes) ? info.param_escapes[index] : Escape_Level.Result
		crosses := index < len(info.param_cross_thread) && info.param_cross_thread[index]
		fmt.sbprintf(
			b, ":p%d:%t:%t:%d:%t{{%s}}", mode, reset, by_ptr, int(escape), crosses,
			typeid_sort_key_walk(c, parameter, keys),
		)
	}
	if info.result != INVALID_TYPE {
		fmt.sbprintf(
			b, ":r%t{{%s}}", info.result_inout,
			typeid_sort_key_walk(c, info.result, keys),
		)
	}
	if info.convention != "" {
		fmt.sbprintf(b, ":c{{%s}}", info.convention)
	}
	if info.c_vararg {
		fmt.sbprint(b, ":cvararg")
	}
	if sym := symbol_of(c, info.proc_contract); sym != nil {
		fmt.sbprintf(b, ":contract{{%s", symbol_key(c, info.proc_contract, keys.allocator))
		write_site_key(c, b, Type_Site{sym.pkg, sym.span, sym.def_scope}, keys)
		strings.write_string(b, "}")
	}
}

typeid_value :: proc(c: ^Compiler, type: Type_Id) -> u64 {
	return c.typeid_values[type]
}
