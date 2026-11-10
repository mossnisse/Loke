// Generics: templates, inference, `where`, and the monomorphization cache.
// Each argument vector gets a cloned declaration whose scope binds the `$`
// names and hangs off the declaration's own scope, never the caller's.
package lokec

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

// Recursive instantiation need not terminate; running out is a diagnostic.
MAX_INSTANTIATION_DEPTH :: 64
MAX_INSTANTIATIONS :: 4096

Generic_Kind :: enum {
	None,
	Procedure,
	Record,
	// design.md "Parametric aliases": a type alias whose body binds `$` names.
	// It is never instantiated; an application denotes its body's type.
	Alias,
}

// One bound generic argument. A `type` parameter carries a `Type_Id`; every
// other parameter carries a frozen constant.
Generic_Arg :: struct {
	is_type:    bool,
	type:       Type_Id,
	value:      Const_Value,
	value_type: Type_Id,
}

Generic_Binding :: struct {
	name: Identifier_Id,
	span: Span,
	arg:  Generic_Arg,
}

// Where a generic declaration is read, which `enter_generic_location` enters.
Generic_Location :: struct {
	// A template's is the declaration's own lexical scope: an instance's scope
	// hangs off this one so a caller's names can never enter the instantiation.
	scope:      ^Scope,
	pkg:        Package_Id,
	lookup_pkg: Package_Id,
	impl_type:  Type_Id,
	file:       u32,
	file_node:  ^File,
}

// A declaration that means nothing until its arguments are supplied.
Generic_Template :: struct {
	symbol:     Symbol_Id,
	decl:       ^Decl,
	kind:       Generic_Kind,
	using location: Generic_Location,
	// Record templates only, in declaration order.
	params:     []Generic_Param_Decl,
	// Record templates only: every instance made so far, so a block registered
	// after one exists still reaches it.
	instances:   [dynamic]^Instance,
	// Its declaration was rejected and reported; a use reports nothing more.
	rejected:    bool,
	// Alias templates only: the view of an application is being built, so one
	// reached again from inside stays an application (`alias_view_of_application`).
	expanding:   bool,
}

Generic_Param_Decl :: struct {
	name:        Identifier_Id,
	span:        Span,
	type_syntax: Expr,
	// Alias templates only, which have no written parameter types: `type` for a
	// parameter bound by a type, or the constant's type, as `int` for `$N` in
	// `[$N]u8` (design.md "Parametric aliases").
	fixed_type:  Type_Id,
	// Alias templates only: the application in the body that decides a constant's
	// type once the arguments before it are bound, as `Value($T, $V)` for `$V`
	// where `Value :: struct($T: type, $V: T)`, and which of its parameters that
	// is. With one, `fixed_type` means nothing.
	dependent_on:    ^Expr_Call,
	dependent_index: int,
}

// One entry in the monomorphization cache.
Instance :: struct {
	symbol:       Symbol_Id,
	type:         Type_Id,
	decl:         ^Decl,
	scope:        ^Scope,
	template:     Symbol_Id,
	bindings:     []Generic_Binding,
	// A provisional entry is on the instantiation stack: a request that reaches it
	// again is recursion, not a cache hit.
	provisional:  bool,
	signature_ok: bool,
	// Deferred so an unselected overload never has its body diagnosed.
	body_checked: bool,
	span:         Span,
	// The call that selected this instance for its body to be checked, which a
	// later diagnostic in the body names (`note_instance_sites`).
	selected_at:  Span,
	// Why a silent probe rejected this cached instance, for a later request that
	// reports.
	rejection:    Instance_Rejection,
	// The `where` bound a silent probe found false, so an overload note can name
	// it; a later request that reports re-checks the bounds itself.
	failed_bound: Expr,
	// Whether the `where` bounds were checked by a reporting request. A silent
	// probe's check is rolled back, so committing the body checks them again.
	bounds_committed: bool,
	// Record instances only: the members of those blocks no other block is more
	// specialized than, by name and table. The table holds the one survivor,
	// or a group of crossed ones a call finds ambiguous (design.md "Generic
	// types": tie-breaker 5 decides for a use).
	impl_candidates: map[Impl_Member_Key][dynamic]Impl_Candidate,
}

// The head diagnostic of a contained rejection, kept rather than the whole
// list: it is the cause, and everything after it is that cause's fallout.
Instance_Rejection :: struct {
	code:    string,
	message: string,
	span:    Span,
}

// One step of an instantiation. Named only if a note is written
// (`note_instantiation_stack`), since most never are.
Instantiation_Frame :: struct {
	symbol:   Symbol_Id,
	bindings: []Generic_Binding,
	span:     Span,
	// A silent probe: what is reported beneath it is truncated if it fails.
	silent:   bool,
}

// An instance whose declaration is yet to be read for private names
// (`check_generic_private_names`): an instance can appear inside a probe, which
// would roll back a warning about it.
Pending_Private_Read :: struct {
	decl: ^Decl,
	using location: Generic_Location,
}

// A procedure instance waiting to be named and emitted with its defining
// package's items: a template's instance, or with no `template` a member of an
// instantiated `impl` block.
Instance_Decl :: struct {
	symbol:   Symbol_Id,
	decl:     ^Decl,
	template: Symbol_Id,
	args:     []Generic_Arg,
}

// ------------------------------------------------------------- templates --

// The template a symbol denotes, or nil. Registered lazily, since another
// package may name it before its own signature phase.
generic_template_for :: proc(k: ^Checker, symbol_id: Symbol_Id) -> ^Generic_Template {
	if symbol_id == INVALID_SYMBOL {
		return nil
	}
	if template, found := k.c.generic_templates[symbol_id]; found {
		return template
	}
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.decl == nil || sym.instance_of != INVALID_SYMBOL {
		return nil
	}
	kind := declaration_generic_kind(sym.decl)
	if kind == .None {
		return nil
	}
	return register_generic_template(k, symbol_id, sym.decl, kind)
}

// Whether `template`'s declaration was rejected and reported, settling that
// declaration first so a use checked before it cannot miss the answer.
template_rejected :: proc(k: ^Checker, template: ^Generic_Template) -> bool {
	resolve_symbol_signature_in_place(k, template.symbol, template.impl_type)
	return template.rejected
}

symbol_is_generic :: proc(k: ^Checker, symbol_id: Symbol_Id) -> bool {
	return generic_template_for(k, symbol_id) != nil
}

// design.md "Generics": a generic declaration has no runtime representation
// before instantiation, so it is not part of any ABI.
reject_uninstantiated_generic :: proc(k: ^Checker, d: ^Decl) {
	if has_attribute(d.attributes, "export") {
		errorf(
			k.c,
			d.span,
			"L0438",
			"a generic declaration has no ABI until it is instantiated, so it cannot be `@(export)`",
		)
	}
	literal := decl_proc_literal(d)
	if literal != nil && literal.bodiless && !symbol_of(k.c, d.symbols[0]).is_foreign {
		proc_shape_ok(k, literal, is_value = false)
	}
	rejected := false
	if literal != nil && literal.signature != nil {
		stand_ins := signature_stand_ins(k, literal.signature.params)
		check_independent_poly_defaults(k, literal.signature.params, stand_ins)
		for parameter in literal.signature.params {
			for entry in parameter.names {
				if entry.is_poly {
					rejected |= reject_generic_parameter_type(k, stand_ins, entry.name, parameter.type)
				}
			}
		}
		for name in signature_poly_names(literal) {
			rejected |= reject_reserved_name(k, name.id, name.span)
		}
	}
	if record, is_record := d.values[0].(^Type_Record); is_record {
		stand_ins := new_scope(k.c, k.scope, .Local)
		for group in record.generic_params {
			for name in group.names {
				declare_stand_in(k, stand_ins, name.text, name.span)
			}
		}
		for group in record.generic_params {
			for name in group.names {
				rejected |= reject_generic_parameter_type(k, stand_ins, name, group.type)
				rejected |= reject_reserved_name(k, name.id, name.span)
			}
		}
	}
	if rejected && len(d.symbols) > 0 {
		if template := generic_template_for(k, d.symbols[0]); template != nil {
			template.rejected = true
		}
	}
	if literal != nil && literal.signature != nil && literal.signature.convention != "" {
		// A foreign member inherited its convention; L0624 already reports it.
		if len(d.symbols) > 0 {
			if sym := symbol_of(k.c, d.symbols[0]); sym != nil && sym.is_foreign {
				return
			}
		}
		errorf(k.c, d.span, "L0438", "a generic procedure cannot use a foreign calling convention")
	}
}

// What a `$` parameter's type may name that only an instance binds, as a type
// naming an earlier `$T` does. Each stand-in resolves to nothing, and marks the scope.
@(private = "file")
signature_stand_ins :: proc(k: ^Checker, params: []Parameter) -> ^Scope {
	stand_ins := new_scope(k.c, k.scope, .Local)
	for parameter in params {
		for entry in parameter.names {
			declare_stand_in(k, stand_ins, entry.name.text, entry.name.span)
		}
		for name in pattern_names(parameter.type) {
			declare_stand_in(k, stand_ins, name.text, name.span)
		}
	}
	return stand_ins
}

// A `$` parameter's type names the same thing in every instance unless it names
// another parameter, so what is wrong with it is said here rather than at the first
// instance, which a declaration need never have. design.md "`type` and `typeid`": a
// `typeid` is a runtime value and does not make a generic declaration, so a `$`
// parameter of that type is an error here rather than a failure at every call.
@(private = "file")
reject_generic_parameter_type :: proc(k: ^Checker, stand_ins: ^Scope, name: Name, type_syntax: Expr) -> bool {
	if type_syntax == nil || type_syntax_has_poly(type_syntax) {
		return false
	}
	// From before the probe: a declaration it settled may have said why already.
	reported := k.c.error_count
	if _, reached := check_against_stand_ins(k, stand_ins, type_syntax, as_type = true); reached {
		return false
	}
	type := resolve_type_syntax(k, clone_expr(k.c, type_syntax))
	if type == INVALID_TYPE {
		if k.c.error_count == reported {
			report_unresolved_type(k, type_syntax)
		}
		return true
	}
	if type_underlying(k.c, type) != TYPE_TYPEID {
		return false
	}
	errorf(
		k.c, expr_span(type_syntax), "L0439",
		"a `$` parameter cannot be a `typeid`: a runtime type identifier does not specialize a declaration",
	)
	add_notef(k.c, name.span, "write `$%s: type`, and `typeid_of(%s)` where the identifier is needed", name.text, name.text)
	return true
}

// A `$` default naming no parameter means the same in every instance, so it is
// checked here; one naming a parameter waits for the call. A speculative check
// against stand-ins for every parameter name tells them apart.
@(private = "file")
check_independent_poly_defaults :: proc(k: ^Checker, params: []Parameter, stand_ins: ^Scope) {
	for parameter in params {
		poly := false
		for entry in parameter.names {
			poly ||= entry.is_poly
		}
		if !poly || parameter.default == nil {
			continue
		}
		// The parameter's type may still name `$T`; then only constness is known.
		probe := begin_probe(k.c)
		wanted := resolve_type_syntax(k, parameter.type)
		saved := k.scope
		k.scope = stand_ins
		stand_ins.reached = false
		check_poly_default(k, clone_expr(k.c, parameter.default), wanted)
		k.scope = saved
		end_probe(k.c, probe)
		if !stand_ins.reached {
			check_poly_default(k, parameter.default, wanted)
		}
	}
}

@(private = "file")
check_poly_default :: proc(k: ^Checker, default: Expr, wanted: Type_Id) {
	if wanted == TYPE_TYPE {
		errors := k.c.error_count
		if resolve_type_syntax(k, default) == INVALID_TYPE && k.c.error_count == errors {
			report_unresolved_type(k, default)
		}
		return
	}
	checked := false
	if wanted == INVALID_TYPE {
		checked = check_single_expr(k, default) != INVALID_TYPE
	} else {
		checked = check_value_expr(k, default, wanted, "pass")
	}
	if checked {
		require_const(k, default, "a `$` parameter's default", "L0432")
	}
}

declare_stand_in :: proc(k: ^Checker, scope: ^Scope, name: string, span: Span) {
	id := intern_identifier(k.c, name)
	scope.names[id] = new_symbol(k.c, Symbol{name = id, span = span, pkg = k.pkg})
}

// A declaration is a template when its signature binds a `$` name, or when its
// record body declares generic parameters.
declaration_generic_kind :: proc(d: ^Decl) -> Generic_Kind {
	if d == nil || d.kind != .Const || len(d.values) != 1 {
		return .None
	}
	if literal := decl_proc_literal(d); literal != nil {
		return proc_signature_is_generic(literal) ? .Procedure : .None
	}
	if record, is_record := d.values[0].(^Type_Record); is_record && len(record.generic_params) > 0 {
		return .Record
	}
	// design.md "Parametric aliases": `Status :: Result(Unit, $E);`.
	if type_syntax_has_poly(d.values[0]) {
		return .Alias
	}
	return .None
}

proc_signature_is_generic :: proc(literal: ^Expr_Proc) -> bool {
	if literal == nil || literal.signature == nil {
		return false
	}
	for parameter in literal.signature.params {
		for entry in parameter.names {
			if entry.is_poly {
				return true
			}
		}
		if type_syntax_has_poly(parameter.type) {
			return true
		}
	}
	return false
}

type_syntax_has_poly :: proc(e: Expr) -> bool {
	_, poly := pattern_shape(e)
	return poly
}

Pattern_Relation :: enum {
	Equal,
	Left,
	Right,
	Crossed,
}

@(private = "file")
merge_pattern_relation :: proc(a, b: Pattern_Relation) -> Pattern_Relation {
	if a == .Crossed || b == .Crossed {
		return .Crossed
	}
	if a == .Equal {
		return b
	}
	if b == .Equal || a == b {
		return a
	}
	return .Crossed
}

@(private = "file")
capability_relation :: proc(left, right: bool) -> Pattern_Relation {
	if left == right {
		return .Equal
	}
	return left ? .Left : .Right
}

@(private = "file")
pattern_relation :: proc(a, b: Expr) -> Pattern_Relation {
	if a == nil || b == nil {
		return a == b ? .Equal : .Crossed
	}
	a_poly := type_syntax_has_poly(a)
	b_poly := type_syntax_has_poly(b)
	if !a_poly || !b_poly {
		switch {
		case a_poly: return .Right
		case b_poly: return .Left
		case:        return .Equal
		}
	}
	_, a_is_poly := a.(^Type_Poly)
	_, b_is_poly := b.(^Type_Poly)
	if a_is_poly || b_is_poly {
		switch {
		case a_is_poly && b_is_poly: return .Equal
		case a_is_poly:              return .Right
		case:                        return .Left
		}
	}

	#partial switch left in a {
	case ^Type_Pointer:
		right, ok := b.(^Type_Pointer)
		if !ok { return .Crossed }
		return merge_pattern_relation(capability_relation(left.mutable, right.mutable), pattern_relation(left.elem, right.elem))
	case ^Type_C_Pointer:
		right, ok := b.(^Type_C_Pointer)
		return ok ? pattern_relation(left.elem, right.elem) : .Crossed
	case ^Type_Slice:
		right, ok := b.(^Type_Slice)
		if !ok { return .Crossed }
		return merge_pattern_relation(capability_relation(left.mutable, right.mutable), pattern_relation(left.elem, right.elem))
	case ^Type_Dynamic_Array:
		right, ok := b.(^Type_Dynamic_Array)
		return ok ? pattern_relation(left.elem, right.elem) : .Crossed
	case ^Type_Distinct:
		right, ok := b.(^Type_Distinct)
		return ok ? pattern_relation(left.elem, right.elem) : .Crossed
	case ^Type_Dyn:
		right, ok := b.(^Type_Dyn)
		if !ok { return .Crossed }
		return merge_pattern_relation(capability_relation(left.mutable, right.mutable), pattern_relation(left.interface_expr, right.interface_expr))
	case ^Type_Array:
		right, ok := b.(^Type_Array)
		if !ok { return .Crossed }
		return merge_pattern_relation(pattern_relation(left.length, right.length), pattern_relation(left.elem, right.elem))
	case ^Type_Map:
		right, ok := b.(^Type_Map)
		if !ok { return .Crossed }
		return merge_pattern_relation(pattern_relation(left.key, right.key), pattern_relation(left.value, right.value))
	case ^Expr_Call:
		right, ok := b.(^Expr_Call)
		return ok ? pattern_relations(argument_values(left.args), argument_values(right.args)) : .Crossed
	case ^Type_Proc:
		right, ok := b.(^Type_Proc)
		if !ok || (left.result == nil) != (right.result == nil) {
			return .Crossed
		}
		relation := pattern_relations(flat_parameter_types(left.params), flat_parameter_types(right.params))
		if left.result != nil {
			relation = merge_pattern_relation(relation, pattern_relation(left.result.type, right.result.type))
		}
		return relation
	case ^Type_Anon_Record:
		right, ok := b.(^Type_Anon_Record)
		if !ok { return .Crossed }
		left_fields := anon_record_pattern_fields(left)
		right_fields := anon_record_pattern_fields(right)
		if len(left_fields) != len(right_fields) {
			return .Crossed
		}
		relation := Pattern_Relation.Equal
		for field, index in left_fields {
			if field.name != right_fields[index].name {
				return .Crossed
			}
			relation = merge_pattern_relation(relation, pattern_relation(field.type, right_fields[index].type))
		}
		return relation
	case ^Type_Anon_Union:
		right, ok := b.(^Type_Anon_Union)
		if !ok || len(left.variants) != len(right.variants) {
			return .Crossed
		}
		relation := Pattern_Relation.Equal
		for variant in left.variants {
			other := anon_union_pattern_variant(right, variant.name.text)
			if other == nil || (variant.type == nil) != (other.type == nil) {
				return .Crossed
			}
			if variant.type != nil {
				relation = merge_pattern_relation(relation, pattern_relation(variant.type, other.type))
			}
		}
		return relation
	}
	return .Equal
}

// Equal lists relate as their elements merged; lists of different lengths cross.
pattern_relations :: proc(left, right: []Expr) -> Pattern_Relation {
	if len(left) != len(right) {
		return .Crossed
	}
	relation := Pattern_Relation.Equal
	for pattern, index in left {
		relation = merge_pattern_relation(relation, pattern_relation(pattern, right[index]))
	}
	return relation
}

@(private = "file")
argument_values :: proc(args: []Argument) -> []Expr {
	values := make([]Expr, len(args), context.temp_allocator)
	for arg, index in args {
		values[index] = arg.value
	}
	return values
}

// A signature's parameter types one per name, `a, b: T` as two.
@(private = "file")
flat_parameter_types :: proc(params: []Parameter) -> []Expr {
	types := make([dynamic]Expr, context.temp_allocator)
	for parameter in params {
		for _ in 0 ..< max(len(parameter.names), 1) {
			append(&types, parameter.type)
		}
	}
	return types[:]
}

// A written record's fields one per name, `a, b: T` as two; an unlabelled
// field's name is empty, since its position is its name.
@(private = "file")
Pattern_Field :: struct {
	name: string,
	type: Expr,
}

@(private = "file")
anon_record_pattern_fields :: proc(record: ^Type_Anon_Record) -> []Pattern_Field {
	fields := make([dynamic]Pattern_Field, context.temp_allocator)
	for field in record.fields {
		if len(field.names) == 0 {
			append(&fields, Pattern_Field{type = field.type})
		}
		for name in field.names {
			append(&fields, Pattern_Field{name = name.text, type = field.type})
		}
	}
	return fields[:]
}

@(private = "file")
anon_union_pattern_variant :: proc(written: ^Type_Anon_Union, label: string) -> ^Variant {
	for &variant in written.variants {
		if variant.name.text == label {
			return &variant
		}
	}
	return nil
}

// design.md "Parametric aliases": a parameter written through an alias ranks
// as its expansion, so `Io_Result($T)` is more specialized than
// `Result($T, $E)`.
compare_generic_specificity :: proc(k: ^Checker, a, b: ^Generic_Template) -> int {
	if a == nil || b == nil {
		return 0
	}
	left := decl_proc_literal(a.decl)
	right := decl_proc_literal(b.decl)
	if left == nil || right == nil || left.signature == nil || right.signature == nil {
		return 0
	}
	views :: proc(k: ^Checker, scope: ^Scope, params: []Parameter) -> []Expr {
		types := flat_parameter_types(params)
		for &type in types {
			type = alias_view(k, scope, type)
		}
		return types
	}
	switch pattern_relations(views(k, a.scope, left.signature.params), views(k, b.scope, right.signature.params)) {
	case .Left:  return -1
	case .Right: return 1
	case .Equal, .Crossed:
	}
	return 0
}

// The patterns a written type is built from, in written order. design.md
// "Specialization": a structural type's fields and payloads are patterns, matched
// by label and order.
type_pattern_parts :: proc(e: Expr) -> []Expr {
	parts := make([dynamic]Expr, context.temp_allocator)
	#partial switch v in e {
	case ^Type_Pointer:
		append(&parts, v.elem)
	case ^Type_C_Pointer:
		append(&parts, v.elem)
	case ^Type_Slice:
		append(&parts, v.elem)
	case ^Type_Dynamic_Array:
		append(&parts, v.elem)
	case ^Type_Distinct:
		append(&parts, v.elem)
	case ^Type_Dyn:
		append(&parts, v.interface_expr)
	case ^Type_Array:
		append(&parts, v.length, v.elem)
	case ^Type_Map:
		append(&parts, v.key, v.value)
	case ^Type_Proc:
		for parameter in v.params {
			append(&parts, parameter.type)
		}
		if v.result != nil {
			append(&parts, v.result.type)
		}
	case ^Expr_Call:
		for arg in v.args {
			append(&parts, arg.value)
		}
	case ^Type_Anon_Record:
		for field in v.fields {
			append(&parts, field.type)
		}
	case ^Type_Anon_Union:
		for variant in v.variants {
			if variant.type != nil {
				append(&parts, variant.type)
			}
		}
	}
	return parts[:]
}

// Also collects the parsed bindings for default checking (design.md "Default values"),
// so comments and literal text cannot introduce parameter names.
pattern_shape :: proc(e: Expr, bindings: ^[dynamic]Name = nil) -> (specificity: int, has_poly: bool) {
	if e == nil {
		return 0, false
	}
	switch v in e {
	case ^Type_Poly:
		if bindings != nil {
			append(bindings, v.name)
		}
		return 0, true
	case ^Expr_Call:
		_, has_poly = pattern_shape(v.callee, bindings)
	case ^Type_Pointer, ^Type_C_Pointer, ^Type_Slice, ^Type_Dynamic_Array, ^Type_Distinct, ^Type_Dyn, ^Type_Array, ^Type_Map,
	     ^Type_Proc, ^Type_Anon_Record, ^Type_Anon_Union:
	// One layer each, holding no pattern: a name, a value, or a declared body.
	case ^Expr_Error, ^Expr_Literal, ^Expr_Ident, ^Expr_Selector, ^Expr_Index,
	     ^Expr_Slice, ^Expr_Postfix, ^Expr_Propagated_Error, ^Expr_Unary, ^Expr_Binary, ^Expr_Range, ^Expr_Or_Else, ^Expr_Cond,
	     ^Expr_Move, ^Expr_Composite, ^Expr_Proc, ^Expr_Proc_Group, ^Expr_Operator, ^Type_Type,
	     ^Type_Record, ^Type_Enum, ^Type_Interface:
		return 1, false
	}
	specificity = 1
	for part in type_pattern_parts(e) {
		part_specificity, part_poly := pattern_shape(part, bindings)
		specificity += part_specificity
		has_poly ||= part_poly
	}
	return specificity, has_poly
}

// The `$` names a pattern binds, in written order, repeats included.
pattern_names :: proc(e: Expr) -> []Name {
	names := make([dynamic]Name, context.temp_allocator)
	pattern_shape(e, &names)
	return names[:]
}

// Every `$` name a procedure's signature binds, in written order, repeats
// included.
@(private = "file")
signature_poly_names :: proc(literal: ^Expr_Proc) -> []Name {
	names := make([dynamic]Name, context.temp_allocator)
	for parameter in literal.signature.params {
		for entry in parameter.names {
			if entry.is_poly {
				append(&names, entry.name)
			}
		}
		pattern_shape(parameter.type, &names)
	}
	return names[:]
}

@(private = "file")
register_generic_template :: proc(k: ^Checker, symbol_id: Symbol_Id, d: ^Decl, kind: Generic_Kind) -> ^Generic_Template {
	sym := symbol_of(k.c, symbol_id)
	template := new(Generic_Template, k.c.semantic_allocator)
	template.symbol = symbol_id
	template.decl = d
	template.kind = kind
	template.pkg = sym.pkg
	template.lookup_pkg = sym.lookup_pkg == INVALID_PACKAGE ? sym.pkg : sym.lookup_pkg
	template.impl_type = sym.owner_type
	template.file = sym.def_file
	template.file_node = sym.def_file_node
	template.scope = sym.def_scope
	if template.scope == nil {
		if pkg := package_of(k.c, sym.pkg); pkg != nil {
			template.scope = pkg.scope
		}
	}

	switch kind {
	case .Record:
		template.instances = make([dynamic]^Instance, 0, 2, k.c.semantic_allocator)
		record := d.values[0].(^Type_Record)
		params := make([dynamic]Generic_Param_Decl, 0, 4, k.c.semantic_allocator)
		for group in record.generic_params {
			for name in group.names {
				append(&params, Generic_Param_Decl{name = name_identifier(k.c, name), span = name.span, type_syntax = group.type})
			}
		}
		template.params = params[:]
	case .Alias:
		template.params = alias_parameters(k, d.values[0])
	case .Procedure:
	case .None:
	}

	sym.generic = true
	k.c.generic_templates[symbol_id] = template
	return template
}

// design.md "One result": which of a union template's parameters the payload
// of its variant `success` names, as `Result`'s `ok: T` names `T`, or, for an
// alias, which of its parameters reach that payload of the union its body
// applies, as `Status(E)` reaches none. A payload holding an inline
// definition, or a template that applies no union, marks every parameter, so
// the caller assumes the worst.
success_parameters :: proc(k: ^Checker, template: ^Generic_Template, success: int) -> []bool {
	marks := make([]bool, len(template.params), context.temp_allocator)
	if template.kind == .Alias {
		saved := k.scope
		k.scope = template.scope
		defer k.scope = saved
		call, is_call := template.decl.values[0].(^Expr_Call)
		applied: ^Generic_Template
		if is_call {
			applied = generic_template_for(k, named_callee_symbol(k, call.callee))
		}
		if applied == nil || (applied.kind != .Record && applied.kind != .Alias) || len(call.args) != len(applied.params) {
			slice.fill(marks, true)
			return marks
		}
		reached := success_parameters(k, applied, success)
		for arg, index in call.args {
			if reached[index] {
				mark_named_parameters(k, template.params, arg.value, marks)
			}
		}
		return marks
	}
	record, is_record := template.decl.values[0].(^Type_Record)
	if template.kind != .Record || !is_record || success >= len(record.variants) {
		slice.fill(marks, true)
		return marks
	}
	mark_named_parameters(k, template.params, record.variants[success].type, marks)
	return marks
}

// What a `Name_Match` reads of a node: a name written there, none for a selector
// or `distinct`, which the walk goes on through, or an inline definition, which
// is not looked into.
@(private = "file")
classify_type_name :: proc(node: Expr) -> (name: string, inline: bool) {
	#partial switch v in node {
	case ^Expr_Ident:
		return v.name, false
	case ^Type_Poly:
		return v.name.text, false
	case ^Expr_Selector, ^Type_Distinct:
		return "", false
	}
	return "", true
}

// Marks each of `params` that `syntax` names, by `$` name or plain name; an
// inline definition marks them all.
mark_named_parameters :: proc(k: ^Checker, params: []Generic_Param_Decl, syntax: Expr, marks: []bool) {
	Param_Marks :: struct {
		c:      ^Compiler,
		params: []Generic_Param_Decl,
		marks:  []bool,
	}
	data := Param_Marks{c = k.c, params = params, marks = marks}
	type_syntax_any_name(syntax, &data, proc(data: rawptr, node: Expr) -> bool {
		data := (^Param_Marks)(data)
		name, inline := classify_type_name(node)
		if inline {
			slice.fill(data.marks, true)
			return false
		}
		for parameter, i in data.params {
			if identifier_text(data.c, parameter.name) == name {
				data.marks[i] = true
			}
		}
		return false
	})
}

// The symbol a callee names, whether written plainly or package-qualified.
named_callee_symbol :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	#partial switch v in callee {
	case ^Expr_Ident:
		return lookup_symbol(k.scope, identifier_of(k.c, v))
	case ^Expr_Selector:
		_, alias, is_alias := selector_package_alias(k, v)
		if !is_alias {
			return INVALID_SYMBOL
		}
		target := package_of(k.c, symbol_of(k.c, alias).pkg)
		if target == nil || target.scope == nil {
			return INVALID_SYMBOL
		}
		member, found := target.scope.names[name_identifier(k.c, v.name)]
		if !found {
			return INVALID_SYMBOL
		}
		if sym := symbol_of(k.c, member); sym == nil || !sym.public {
			return INVALID_SYMBOL
		}
		return member
	}
	return INVALID_SYMBOL
}

// The generics whose application names a type: a record or a parametric alias.
TYPE_GENERICS :: bit_set[Generic_Kind]{.Record, .Alias}

// The generic of one of `kinds` that `callee` names, or nil.
generic_template_of_callee :: proc(k: ^Checker, callee: Expr, kinds: bit_set[Generic_Kind]) -> ^Generic_Template {
	template := generic_template_for(k, named_callee_symbol(k, callee))
	return template != nil && template.kind in kinds ? template : nil
}

// -------------------------------------------------------------- cache key --

// Most requests find their key, so a lookup keeps nothing of it (`cached_instance`);
// only an insertion builds one to keep.
instance_key :: proc(c: ^Compiler, template: Symbol_Id, bindings: []Generic_Binding, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "%d", u32(template))
	for binding in bindings {
		// The name keeps two orders of the same arguments apart.
		fmt.sbprintf(&b, "|%d=", u32(binding.name))
		write_generic_arg_key(c, &b, binding.arg)
	}
	return strings.to_string(b)
}

@(private = "file")
cached_instance :: proc(c: ^Compiler, template: Symbol_Id, bindings: []Generic_Binding) -> (^Instance, bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return c.instances[instance_key(c, template, bindings, context.temp_allocator)]
}

cached_alias_expansion :: proc(c: ^Compiler, template: Symbol_Id, bindings: []Generic_Binding) -> (Type_Id, bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return c.alias_expansions[instance_key(c, template, bindings, context.temp_allocator)]
}

// One argument's part of a cache key: a type's number, or a constant's type and
// value, length-prefixed since a string may contain `|`.
write_generic_arg_key :: proc(c: ^Compiler, b: ^strings.Builder, arg: Generic_Arg) {
	if arg.is_type {
		fmt.sbprintf(b, "T%d", u32(arg.type))
	} else {
		text := const_key_text(c, arg.value)
		fmt.sbprintf(b, "V%d:%d:%s", u32(arg.value_type), len(text), text)
	}
}

// In the temp allocator: every caller reads it at once. `write_value_key` in
// typeid.odin follows the same aggregate encoding, but spells a type by its
// canonical key rather than by its `Type_Id`; a change to one may need the other.
const_key_text :: proc(c: ^Compiler, value: Const_Value) -> string {
	#partial switch value.kind {
	case .Integer, .Rune:
		return bi_text(context.temp_allocator, value.integer)
	case .Boolean:
		return value.boolean ? "true" : "false"
	case .Float:
		// design.md "Generic argument identity": keep the converted encoding,
		// including signalling NaNs the widened numeric field cannot preserve.
		return fmt.aprintf("f%d:%x", value.float_bits, value.float_raw, allocator = context.temp_allocator)
	case .String:
		return value.text
	case .Type:
		// A bit-cast `typeid` names no type, only its number.
		if number, known := typeid_const_number(c, value); known && number != 0 {
			return fmt.aprintf("n%d", number, allocator = context.temp_allocator)
		}
		return fmt.aprintf("t%d", u32(value.type_value), allocator = context.temp_allocator)
	case .Nil:
		return "nil"
	case .Aggregate:
		if value.aggregate == nil {
			return "{}"
		}
		b := strings.builder_make(context.temp_allocator)
		// The variant leads: `.ok(1)` and `.err(1)` have the same elements.
		fmt.sbprintf(&b, "{{%d", value.aggregate.variant)
		for element in value.aggregate.elements {
			// Length-prefixed, like `instance_key`.
			text := const_key_text(c, element)
			fmt.sbprintf(&b, ",%d:%s", len(text), text)
		}
		strings.write_string(&b, "}")
		return strings.to_string(b)
	}
	return "?"
}

// Compare the same type and value identity encoded by instance and witness keys
// (design.md "Generic argument identity"), including aggregate elements.
generic_arg_equal :: proc(c: ^Compiler, a, b: Generic_Arg) -> bool {
	if a.is_type != b.is_type {
		return false
	}
	if a.is_type {
		return a.type == b.type
	}
	return a.value_type == b.value_type && const_key_text(c, a.value) == const_key_text(c, b.value)
}

generic_args_equal :: proc(c: ^Compiler, a, b: []Generic_Arg) -> bool {
	if len(a) != len(b) {
		return false
	}
	for arg, index in a {
		if !generic_arg_equal(c, arg, b[index]) {
			return false
		}
	}
	return true
}

// A readable `Table(string, int)` for diagnostics.
@(private = "file")
generic_instance_name :: proc(c: ^Compiler, template: Symbol_Id, bindings: []Generic_Binding) -> string {
	b := strings.builder_make(c.semantic_allocator)
	if sym := symbol_of(c, template); sym != nil {
		if sym.owner_type != INVALID_TYPE {
			strings.write_string(&b, type_name(c, sym.owner_type))
			strings.write_string(&b, ".")
		}
		strings.write_string(&b, identifier_text(c, sym.name))
	}
	strings.write_string(&b, "(")
	for binding, index in bindings {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, generic_argument_text(c, binding.arg))
	}
	strings.write_string(&b, ")")
	return strings.to_string(b)
}

// Human-readable arguments are separate from cache and backend identity.
generic_argument_text :: proc(c: ^Compiler, arg: Generic_Arg) -> string {
	return arg.is_type ? type_name(c, arg.type) : generic_value_text(c, arg.value)
}

generic_value_text :: proc(c: ^Compiler, value: Const_Value, depth := 0) -> string {
	switch value.kind {
	case .String:
		return fmt.aprintf("%q", value.text, allocator = c.semantic_allocator)
	case .Nil:
		return "nil"
	case .Rune:
		code, _ := bi_to_i64(c, value.integer)
		return fmt.aprintf("%q", rune(code), allocator = c.semantic_allocator)
	case .Float:
		if value.float != value.float {
			return fmt.aprintf("NaN(f%d, 0x%x)", value.float_bits, value.float_raw, allocator = c.semantic_allocator)
		}
		if value.float == 0 { return value.float_raw == 0 ? "0.0" : "-0.0" }
		return const_display_text(c, value)
	case .Aggregate:
		aggregate := value.aggregate
		if aggregate == nil { return "{}" }
		if depth >= 4 { return "..." }
		b := strings.builder_make(c.semantic_allocator)
		strings.write_string(&b, type_name(c, aggregate.type))
		info := underlying_info(c, aggregate.type)
		if info != nil && info.kind == .Union {
			strings.write_string(&b, ".")
			strings.write_string(&b, identifier_text(c, info.variant_names[aggregate.variant]))
			if payload := info.variants[aggregate.variant]; payload == TYPE_VOID || payload == c.unit_type { return strings.to_string(b) }
			strings.write_string(&b, "(")
		} else {
			strings.write_string(&b, "{")
		}
		for element, index in aggregate.elements {
			if index > 0 { strings.write_string(&b, ", ") }
			if index == 8 { strings.write_string(&b, "..."); break }
			strings.write_string(&b, generic_value_text(c, element, depth + 1))
		}
		strings.write_string(&b, info != nil && info.kind == .Union ? ")" : "}")
		return strings.to_string(b)
	case .Invalid:
		return "<invalid value>"
	case .Integer, .Boolean, .Type:
		return const_display_text(c, value)
	}
	return "<value>"
}

// Keep the beginning and end of deep instance names without cutting UTF-8.
@(private = "file")
short_instantiation_name :: proc(c: ^Compiler, name: string) -> string {
	if len(name) <= 80 { return name }
	end, start := 64, len(name) - 12
	for end > 0 && name[end] & 0xC0 == 0x80 { end -= 1 }
	for start < len(name) && name[start] & 0xC0 == 0x80 { start += 1 }
	return fmt.aprintf("%s...%s", name[:end], name[start:], allocator = c.semantic_allocator)
}

// ---------------------------------------------------------- instance scope --

// A scope whose parent is the declaration's lexical scope, holding one symbol
// per bound generic name: a `Type` symbol for a type argument and a `Const` for
// a value argument, so ordinary name resolution finds both.
new_instance_scope :: proc(k: ^Checker, template: ^Generic_Template) -> ^Scope {
	return new_param_scope(k, template.scope)
}

// A local scope for binding generic parameters, inside `parent`, or the
// universe for a template declared without one.
new_param_scope :: proc(k: ^Checker, parent: ^Scope) -> ^Scope {
	return new_scope(k.c, parent if parent != nil else build_universe(k.c), .Local)
}

// An instance scope for arguments bound without one (`bind_pattern_name`).
new_bound_instance_scope :: proc(k: ^Checker, template: ^Generic_Template, bindings: []Generic_Binding) -> ^Scope {
	scope := new_instance_scope(k, template)
	for binding in bindings {
		bind_generic_name(k, scope, binding)
	}
	return scope
}

bind_generic_name :: proc(k: ^Checker, scope: ^Scope, binding: Generic_Binding) {
	sym := Symbol {
		name = binding.name,
		span = binding.span,
		pkg  = k.pkg,
		generic_binding = true,
	}
	if binding.arg.is_type {
		sym.kind = .Type
		sym.type = binding.arg.type
	} else {
		sym.kind = .Const
		sym.type = binding.arg.value_type
		sym.const_value = binding.arg.value
	}
	scope.names[binding.name] = new_symbol(k.c, sym)
}

// The constant a `[$N]E` length is bound to inside an instance.
poly_array_length :: proc(k: ^Checker, poly: ^Type_Poly) -> (u64, bool) {
	sym := symbol_of(k.c, lookup_symbol(k.scope, name_identifier(k.c, poly.name)))
	if sym == nil || sym.kind != .Const || sym.const_value.kind != .Integer {
		return 0, false
	}
	length, fits := bi_to_i64(k.c, sym.const_value.integer)
	if !fits || length < 0 {
		return 0, false
	}
	return u64(length), true
}

// -------------------------------------------------------- pattern matching --

// design.md "Dynamic arrays" and "Fixed arrays": a `[dynamic]T` or `[N]T`
// argument reaches a `[]T` pattern through the implicit view, so
// `sum(xs: []$T)` accepts one.
@(private = "file")
match_array_as_view :: proc(
	k: ^Checker, pattern: Expr, actual: Type_Id, scope: ^Scope, out: ^[dynamic]Generic_Binding,
) -> bool {
	info := underlying_info(k.c, actual)
	if info == nil {
		return false
	}
	// A `Box(T)` reaches a `^T` pattern the same way (design.md "Owned values").
	if pointer, is_pointer := pattern.(^Type_Pointer); is_pointer && info.kind == .Box && !pointer.mutable {
		return match_type_pattern(k, pattern, pointer_to(k.c, info.element, false), scope, out)
	}
	if _, is_slice := pattern.(^Type_Slice); is_slice && (info.kind == .Dynamic_Array || info.kind == .Array) {
		return match_type_pattern(k, pattern, slice_of(k.c, info.element, false), scope, out)
	}
	return false
}

// Binds every `$` name in a written parameter type from the shape of a supplied
// argument's type. Returns false only when a binding is impossible — a pattern
// with no `$` is not this function's business, and ordinary conversion ranking
// still decides whether the argument fits.
match_type_pattern :: proc(
	k: ^Checker,
	pattern: Expr,
	actual: Type_Id,
	scope: ^Scope,
	out: ^[dynamic]Generic_Binding,
) -> bool {
	if pattern == nil || actual == INVALID_TYPE {
		return true
	}
	if !type_syntax_has_poly(pattern) {
		return true
	}
	info := type_of(k.c, actual)
	if info == nil {
		return false
	}
	#partial switch v in pattern {
	case ^Type_Poly:
		// An untyped constant binds a generic parameter at its default type: `$T`
		// stands for a real type, and `untyped int` is not one a body could use.
		// `nil` has no default type, so it binds nothing.
		bound := default_type(k.c, actual)
		if bound == INVALID_TYPE {
			return false
		}
		return bind_pattern_name(k, v.name, Generic_Arg{is_type = true, type = bound}, scope, out)

	case ^Type_Pointer:
		if info.kind != .Pointer {
			return false
		}
		// A `^mut E` argument reaches a `^$E` parameter through capability
		// weakening, but not the reverse. Slices follow the same rule, so one
		// helper written on the read-only spelling serves both capabilities.
		if v.mutable && !info.mutable {
			return false
		}
		return match_type_pattern(k, v.elem, info.element, scope, out)

	case ^Type_C_Pointer:
		if info.kind != .C_Pointer {
			return false
		}
		return match_type_pattern(k, v.elem, info.element, scope, out)

	case ^Type_Slice:
		if info.kind != .Slice {
			return false
		}
		if v.mutable && !info.mutable {
			return false
		}
		return match_type_pattern(k, v.elem, info.element, scope, out)

	case ^Type_Dynamic_Array:
		if info.kind != .Dynamic_Array {
			return false
		}
		return match_type_pattern(k, v.elem, info.element, scope, out)

	case ^Type_Distinct:
		if info.kind != .Distinct {
			return false
		}
		return match_type_pattern(k, v.elem, info.element, scope, out)

	case ^Type_Dyn:
		// `dyn proc(...)` is the callable view: its one argument is the
		// signature, which a procedure or capture literal converting to the view
		// supplies too (design.md "Borrowed callable views").
		if signature, is_proc := v.interface_expr.(^Type_Proc); is_proc {
			called := info.kind == .Dyn ? dyn_proc_signature(k.c, actual) : dyn_proc_source_signature(k.c, actual)
			return called != INVALID_TYPE && match_type_pattern(k, signature, called, scope, out)
		}
		if info.kind != .Dyn || (v.mutable && !info.mutable) {
			return false
		}
		callee := v.interface_expr
		args: []Argument
		if call, is_call := callee.(^Expr_Call); is_call {
			args = call.args
			callee = call.callee
		}
		if named_callee_symbol(k, callee) != info.dyn_interface || len(args) != len(info.dyn_args) {
			return false
		}
		return match_generic_args(k, args, info.dyn_args, scope, out)

	case ^Type_Map:
		if info.kind != .Map {
			return false
		}
		return match_type_pattern(k, v.key, info.key, scope, out) &&
		       match_type_pattern(k, v.value, info.element, scope, out)

	case ^Type_Array:
		if info.kind != .Array {
			return false
		}
		return bind_count_pattern(k, v.length, info.count, scope, out) &&
		       match_type_pattern(k, v.elem, info.element, scope, out)

	case ^Expr_Call:
		// design.md "Owned values": `Box($T)` matches a box and binds its element.
		if predeclared_callee(k, v.callee, "Box") {
			if info.kind != .Box || len(v.args) != 1 {
				return false
			}
			return match_type_pattern(k, v.args[0].value, info.element, scope, out)
		}
		// design.md "SIMD vectors": `Simd($T, $N)` is written like a generic
		// application but is a predeclared type constructor, so its parts come
		// from the type itself rather than from a template's bound arguments.
		if predeclared_callee(k, v.callee, "Simd") {
			if info.kind != .Simd || len(v.args) != 2 {
				return false
			}
			return bind_count_pattern(k, v.args[1].value, info.count, scope, out) &&
			       match_type_pattern(k, v.args[0].value, info.element, scope, out)
		}
		// `Range($T)` is the same shape: one part, taken from the type itself.
		if predeclared_callee(k, v.callee, "Range") {
			if !info.is_range || len(v.args) != 1 {
				return false
			}
			return match_type_pattern(k, v.args[0].value, info.element, scope, out)
		}
		// design.md "Specialization": `Status($E)` matches what its body does.
		if template := generic_template_of_callee(k, v.callee, {.Alias}); template != nil {
			return match_alias_pattern(k, v, template, actual, scope, out)
		}
		// `Table($K, $V)`: an instance of that template supplies the parts.
		if info.instance_of == INVALID_SYMBOL || named_callee_symbol(k, v.callee) != info.instance_of ||
		   len(v.args) != len(info.instance_args) {
			return false
		}
		return match_generic_args(k, v.args, info.instance_args, scope, out)

	case ^Type_Proc:
		if info.kind != .Proc {
			return false
		}
		parameters := flat_parameter_types(v.params)
		if len(parameters) != len(info.parameters) || (v.result == nil) != (info.result == INVALID_TYPE) {
			return false
		}
		for parameter, index in parameters {
			if !match_type_pattern(k, parameter, info.parameters[index], scope, out) {
				return false
			}
		}
		return v.result == nil || match_type_pattern(k, v.result.type, info.result, scope, out)

	case ^Type_Anon_Record:
		// design.md "Specialization": the same labels in the same order, each
		// field's pattern against that field's type. An unlabelled pattern takes
		// a labelled record by position, as the record converts to it.
		if info.kind != .Struct || !info.anonymous_record {
			return false
		}
		fields := anon_record_pattern_fields(v)
		if len(fields) != len(info.fields) {
			return false
		}
		for field, index in fields {
			member := symbol_of(k.c, info.fields[index])
			if member == nil || (field.name != "" && identifier_text(k.c, member.name) != field.name) {
				return false
			}
			if !match_type_pattern(k, field.type, member.type, scope, out) {
				return false
			}
		}
		return true

	case ^Type_Anon_Union:
		// Each of the argument's alternatives is one of the pattern's by label,
		// in any order, as widening asks; its payload binds that alternative's
		// pattern. An alternative the argument lacks binds nothing.
		if info.kind != .Union || !info.anonymous_union {
			return false
		}
		for name, index in info.variant_names {
			written := anon_union_pattern_variant(v, identifier_text(k.c, name))
			payload := info.variants[index]
			if written == nil || (written.type == nil) != (payload == TYPE_VOID) {
				return false
			}
			if written.type != nil && !match_type_pattern(k, written.type, payload, scope, out) {
				return false
			}
		}
		return true
	}
	return false
}

// A `[$N]` length or `Simd(_, $N)` lane count binds the type's count.
@(private = "file")
bind_count_pattern :: proc(k: ^Checker, e: Expr, count: u64, scope: ^Scope, out: ^[dynamic]Generic_Binding) -> bool {
	poly, is_poly := e.(^Type_Poly)
	if !is_poly {
		return true
	}
	return bind_pattern_name(k, poly.name, Generic_Arg{value = int_const(k.c, i64(count)), value_type = TYPE_INT}, scope, out)
}

// Written arguments of `Name(...)` against an instance's bound ones: a `$` name
// binds, and a written argument is left to ranking.
@(private = "file")
match_generic_args :: proc(
	k: ^Checker, args: []Argument, bound: []Generic_Arg, scope: ^Scope, out: ^[dynamic]Generic_Binding,
) -> bool {
	for arg, index in args {
		if !match_generic_arg(k, arg.value, bound[index], scope, out) {
			return false
		}
	}
	return true
}

// One written generic argument against its bound one. A written argument with
// no `$` matches here; the caller compares it.
match_generic_arg :: proc(k: ^Checker, written: Expr, bound: Generic_Arg, scope: ^Scope, out: ^[dynamic]Generic_Binding) -> bool {
	if poly, is_poly := written.(^Type_Poly); is_poly {
		return bind_pattern_name(k, poly.name, bound, scope, out)
	}
	if type_syntax_has_poly(written) {
		return bound.is_type && match_type_pattern(k, written, bound.type, scope, out)
	}
	return true
}

@(private = "file")
bind_pattern_name :: proc(
	k: ^Checker,
	name: Name,
	arg: Generic_Arg,
	scope: ^Scope,
	out: ^[dynamic]Generic_Binding,
) -> bool {
	id := name_identifier(k.c, name)
	for existing in out {
		if existing.name != id {
			continue
		}
		// `proc(a, b: [2]$E)` binds `E` twice: the two argument types must agree.
		return generic_arg_equal(k.c, existing.arg, arg)
	}
	binding := Generic_Binding{name = id, span = name.span, arg = arg}
	append(out, binding)
	// A record whose parameters are all types binds on a cache miss instead.
	if scope != nil {
		bind_generic_name(k, scope, binding)
	}
	return true
}

// -------------------------------------------------------------- inference --

Inference :: struct {
	bindings:     []Generic_Binding,
	runtime_args: []Arg_Info,
	// Which written arguments were consumed by `$` parameters, and the concrete
	// type each was converted to. Overload ordering still ranks these even
	// though they don't survive into the runtime signature.
	compile_time:    []bool,
	compile_targets: []Type_Id,
	compile_omitted: int,
	scope:        ^Scope,
	reason:       string,
	// design.md "Arguments typed after inference": the waiting argument whose
	// parameter type still names an unbound `$` name, which `reason` explains.
	unbound_wait: bool,
	waiting_arg:  int,
	ok:           bool,
}

// An argument that waits for inference, and the written parameter type it will
// take (the element type, for a variadic pack).
@(private = "file")
Waiting_Argument :: struct {
	index:     int,
	written:   Expr,
	parameter: string,
}

// design.md "Implicit selector expression": the type a generic procedure's
// parameter gives an argument that needs one, such as `.ZYX`, before
// inference. Only a parameter whose written type names none of the
// procedure's `$` parameters has one then, as `order: Euler_Order` beside
// `first: $T` does, and so does a `$` parameter's, as `$mode: Mode`;
// `Option(T)` waits for `T` (`generic_parameter_waits`). `has_parameter` is false
// when the argument fills no parameter of this procedure.
generic_parameter_context_type :: proc(
	k: ^Checker, template: ^Generic_Template, name: Identifier_Id, position: int,
) -> (type: Type_Id, has_parameter: bool) {
	written, _ := generic_parameter_written(k, template, name, position)
	if written == nil {
		return INVALID_TYPE, false
	}
	if names_poly_parameter_in(template, written) {
		return INVALID_TYPE, true
	}
	saved := enter_instance(k, template, new_instance_scope(k, template))
	defer k.location = saved
	return resolve_type_syntax(k, clone_expr(k.c, written)), true
}

// design.md "Arguments typed after inference": whether an argument that needs
// its parameter's type waits for the other arguments' inference here, because
// the runtime parameter it fills names the procedure's `$` parameters. A `$`
// parameter's argument never waits, since it selects the instance.
generic_parameter_waits :: proc(k: ^Checker, template: ^Generic_Template, name: Identifier_Id, position: int) -> bool {
	written, compile_time := generic_parameter_written(k, template, name, position)
	return written != nil && !compile_time && names_poly_parameter_in(template, written)
}

// The written type of the parameter an argument fills, by name or position (a
// variadic pack takes every later position), and whether that parameter is a `$`
// one.
@(private = "file")
generic_parameter_written :: proc(
	k: ^Checker, template: ^Generic_Template, name: Identifier_Id, position: int,
) -> (written: Expr, compile_time: bool) {
	literal := decl_proc_literal(template.decl)
	if literal == nil || literal.signature == nil {
		return
	}
	current := 0
	for parameter in literal.signature.params {
		for entry in parameter.names {
			selected := current == position || (parameter.mode == .Variadic && current <= position)
			if name != INVALID_IDENTIFIER {
				selected = name_identifier(k.c, entry.name) == name
			}
			if selected {
				return parameter.type, entry.is_poly
			}
			current += 1
		}
	}
	return
}

// The `$` names inference left unbound, and the first one a waiting
// argument's parameter type names; an inline definition, which is not looked
// into, counts as naming the first.
@(private = "file")
Unbound_Names :: struct {
	names: [dynamic]string,
	found: string,
}

@(private = "file")
names_unbound_parameter :: proc(data: rawptr, node: Expr) -> bool {
	unbound := (^Unbound_Names)(data)
	text, inline := classify_type_name(node)
	if inline {
		unbound.found = unbound.names[0]
		return true
	}
	for name in unbound.names {
		if name == text {
			unbound.found = name
			return true
		}
	}
	return false
}

// Whether written type syntax names one of the procedure's `$` parameters, or
// holds an inline definition, which is not looked into.
@(private = "file")
names_poly_parameter_in :: proc(template: ^Generic_Template, written: Expr) -> bool {
	poly := signature_poly_names(decl_proc_literal(template.decl))
	return type_syntax_any_name(written, &poly, proc(data: rawptr, node: Expr) -> bool {
		text, inline := classify_type_name(node)
		_, is_poly := node.(^Type_Poly)
		if inline || is_poly {
			return true
		}
		for name in (^[]Name)(data)^ {
			if name.text == text {
				return true
			}
		}
		return false
	})
}

// What a walk over a call's arguments has claimed, bound and left waiting so far.
@(private = "file")
Inference_Walk :: struct {
	args:     []Arg_Info,
	claimed:  []bool,
	next:     int,
	scope:    ^Scope,
	bindings: [dynamic]Generic_Binding,
	waits:    [dynamic]Waiting_Argument,
}

@(private = "file")
refuse :: proc(k: ^Checker, result: ^Inference, format: string, args: ..any) -> Inference {
	result.reason = fmt.aprintf(format, ..args, allocator = k.c.semantic_allocator)
	return result^
}

// Walks a template's written signature left to right, binding every `$` name
// as it goes, so a later parameter type may name an earlier binding. `$`
// parameters are compile-time inputs and do not survive into the instance's
// runtime signature.
infer_generic_arguments :: proc(k: ^Checker, template: ^Generic_Template, args: []Arg_Info) -> Inference {
	result := Inference{}
	literal := decl_proc_literal(template.decl)
	if literal == nil || literal.signature == nil {
		return refuse(k, &result, "this name is not a procedure")
	}

	scope := new_instance_scope(k, template)
	result.scope = scope

	saved := enter_instance(k, template, scope)
	defer k.location = saved

	// Checked on the written call, before `$` arguments leave the signature.
	named := false
	for arg in args {
		if arg.name != INVALID_IDENTIFIER {
			named = true
		} else if named {
			return refuse(k, &result, "a positional argument cannot follow a named one")
		}
	}

	walk := Inference_Walk {
		args     = args,
		claimed  = make([]bool, len(args), context.temp_allocator),
		scope    = scope,
		bindings = make([dynamic]Generic_Binding, 0, 4, context.temp_allocator),
		waits    = make([dynamic]Waiting_Argument, 0, 2, context.temp_allocator),
	}
	result.compile_time = make([]bool, len(args), k.c.semantic_allocator)
	result.compile_targets = make([]Type_Id, len(args), k.c.semantic_allocator)
	position := 0
	for parameter, parameter_index in literal.signature.params {
		names := parameter.names
		// `proc(self, u: $U)` is one parameter group, but `self` is the receiver
		// and takes the block's type, not `$U` (`parameter_splits_receiver`).
		// The receiver's own type is checked when the candidate is ranked.
		if template.impl_type != INVALID_TYPE && parameter_splits_receiver(parameter, parameter_index) {
			position += 1
			if _, found := claim_argument(args, names[0].name.id, &walk.next, walk.claimed); !found {
				return refuse(k, &result, "it needs more arguments than were supplied")
			}
			names = names[1:]
		}
		if parameter.mode == .Variadic {
			result.reason = infer_variadic_pack(k, &walk, parameter.type, len(names) > 0 ? names[0].name.text : "")
			if result.reason != "" {
				return result
			}
			continue
		}
		for entry in names {
			position += 1
			index, found := claim_argument(args, entry.name.id, &walk.next, walk.claimed)
			if !found {
				if parameter.default == nil {
					return refuse(k, &result, "it needs more arguments than were supplied")
				}
				// An omitted `$` default is bound, since it selects the instance.
				if !entry.is_poly {
					continue
				}
				result.compile_omitted += 1
				result.reason = bind_default_compile_time_argument(k, entry.name, parameter.default, parameter.type, scope, &walk.bindings)
				if result.reason != "" {
					return result
				}
				continue
			}
			arg := args[index]
			if arg.waiting {
				// A `$` argument selects the instance, so it cannot wait for one.
				if entry.is_poly {
					return refuse(
						k, &result, "argument %d needs its parameter's type, which the `$` parameter `%s` does not give",
						index + 1, entry.name.text,
					)
				}
				append(&walk.waits, Waiting_Argument{index, parameter.type, entry.name.text})
				continue
			}
			if !entry.is_poly {
				// An ordinary runtime parameter, whose written type may still be a
				// pattern binding parts of the argument's type.
				if !match_type_pattern(k, parameter.type, arg.type, scope, &walk.bindings) &&
				   !match_array_as_view(k, parameter.type, arg.type, scope, &walk.bindings) {
					if arg.type == TYPE_UNTYPED_NIL {
						return refuse(k, &result, "`nil` has no type to infer parameter %d from", position)
					}
					return refuse(k, &result, "`%s` does not match the shape of parameter %d", type_name(k.c, arg.type), position)
				}
				continue
			}
			result.compile_time[index] = true
			wanted: Type_Id
			wanted, result.reason = poly_parameter_type(k, parameter.type, arg.type, scope, &walk.bindings)
			if result.reason == "" {
				result.reason = bind_compile_time_argument(k, entry.name, arg, wanted, scope, &walk.bindings)
			}
			if result.reason != "" {
				return result
			}
			result.compile_targets[index] = wanted != INVALID_TYPE ? wanted : default_type(k.c, arg.type)
		}
	}
	for _, index in args {
		if !walk.claimed[index] {
			result.reason = unclaimed_argument_reason(k, args, index, position)
			return result
		}
	}
	if reason, waiting := unbound_wait_reason(k, literal, walk.waits[:], walk.bindings[:]); reason != "" {
		result.reason = reason
		result.unbound_wait = true
		result.waiting_arg = waiting
		return result
	}
	// Runtime arguments keep their written order for `build_candidate`.
	runtime_args := make([dynamic]Arg_Info, 0, len(args), k.c.semantic_allocator)
	for arg, index in args {
		if !result.compile_time[index] {
			append(&runtime_args, arg)
		}
	}

	result.bindings = bindings_in_declaration_order(k, literal, walk.bindings[:])
	result.runtime_args = runtime_args[:]
	result.ok = true
	return result
}

// The rest of the arguments, into a variadic pack. A pattern in the element type
// binds from the first that does not wait; the rest are ranked, not matched. Why
// not, or empty.
@(private = "file")
infer_variadic_pack :: proc(k: ^Checker, walk: ^Inference_Walk, element: Expr, label: string) -> string {
	matched_one := false
	for {
		index, found := claim_argument(walk.args, INVALID_IDENTIFIER, &walk.next, walk.claimed)
		if !found {
			return ""
		}
		if walk.args[index].waiting {
			append(&walk.waits, Waiting_Argument{index, element, label})
			continue
		}
		if matched_one {
			continue
		}
		matched_one = true
		matched := walk.args[index].type
		// A spread supplies the pack slice, while the written variadic type is
		// its element. Infer `$T` in `..$T` from `..values`, not from the
		// whole `[]T` carrier.
		if walk.args[index].mode == .Spread {
			matched = slice_element(k.c, matched)
		}
		if matched == INVALID_TYPE || !match_type_pattern(k, element, matched, walk.scope, &walk.bindings) {
			return fmt.aprintf(
				"`%s` does not match the variadic parameter's element shape",
				type_name(k.c, walk.args[index].type),
				allocator = k.c.semantic_allocator,
			)
		}
	}
}

// Why an argument no parameter claimed is one too many. A named one says so by
// name, as a call of a procedure that is not generic does (`named_slot_is_open`).
@(private = "file")
unclaimed_argument_reason :: proc(k: ^Checker, args: []Arg_Info, index, count: int) -> string {
	name := args[index].name
	if name == INVALID_IDENTIFIER {
		return arity_reason(count, len(args))
	}
	for earlier in args[:index] {
		if earlier.name == name {
			return fmt.aprintf("`%s` is given twice", identifier_text(k.c, name), allocator = k.c.semantic_allocator)
		}
	}
	return fmt.aprintf("no parameter named `%s`", identifier_text(k.c, name), allocator = k.c.semantic_allocator)
}

// design.md "Arguments typed after inference": a waiting argument takes its
// parameter's type once every `$` name that type names is bound by the other
// arguments. One that only it could bind stays unbound, so the call is rejected;
// the argument is typed after selection (`bind_chosen_call`). Why, and which
// argument, or empty.
@(private = "file")
unbound_wait_reason :: proc(
	k: ^Checker, literal: ^Expr_Proc, waits: []Waiting_Argument, bindings: []Generic_Binding,
) -> (reason: string, waiting: int) {
	if len(waits) == 0 {
		return
	}
	unbound := Unbound_Names{names = make([dynamic]string, 0, 2, context.temp_allocator)}
	for name in signature_poly_names(literal) {
		id := name_identifier(k.c, name)
		bound := false
		for binding in bindings {
			bound ||= binding.name == id
		}
		if !bound {
			append(&unbound.names, name.text)
		}
	}
	if len(unbound.names) == 0 {
		return
	}
	for wait in waits {
		if type_syntax_any_name(wait.written, &unbound, names_unbound_parameter) {
			return fmt.aprintf(
				"argument %d takes its type from parameter `%s`, whose type names `%s`, and no other argument binds `%s`",
				wait.index + 1, wait.parameter, unbound.found, unbound.found,
				allocator = k.c.semantic_allocator,
			), wait.index
		}
	}
	return
}

// The type a `$` parameter's argument takes. A declared type of `$I` binds the
// argument's own type. A copy, so `[N]int` names this call's `N` and not a cached
// earlier one. Why not, or empty.
@(private = "file")
poly_parameter_type :: proc(
	k: ^Checker, declared: Expr, arg_type: Type_Id, scope: ^Scope, out: ^[dynamic]Generic_Binding,
) -> (wanted: Type_Id, reason: string) {
	if poly, is_poly := declared.(^Type_Poly); is_poly {
		value_type := default_type(k.c, arg_type)
		if value_type == INVALID_TYPE {
			return INVALID_TYPE, fmt.aprintf("`nil` has no type to infer `$%s` from", poly.name.text, allocator = k.c.semantic_allocator)
		}
		if !bind_pattern_name(k, poly.name, Generic_Arg{is_type = true, type = value_type}, scope, out) {
			return INVALID_TYPE, "its generic parameter types do not agree"
		}
	}
	return resolve_type_syntax(k, clone_expr(k.c, declared)), ""
}

// design.md "Generic argument identity": an instance is its declaration and its
// ordered arguments, so bindings take the order their `$` names are written in
// the signature. Matching order is not that order: a union pattern binds in the
// argument's alternative order, and a name an absent alternative holds is
// bound by a later parameter.
@(private = "file")
bindings_in_declaration_order :: proc(
	k: ^Checker, literal: ^Expr_Proc, bindings: []Generic_Binding,
) -> []Generic_Binding {
	ordered := make([dynamic]Generic_Binding, 0, len(bindings), k.c.semantic_allocator)
	taken := make([]bool, len(bindings), context.temp_allocator)
	for name in signature_poly_names(literal) {
		id := name_identifier(k.c, name)
		for binding, index in bindings {
			if !taken[index] && binding.name == id {
				taken[index] = true
				append(&ordered, binding)
			}
		}
	}
	// Every binding comes from a name written in the signature.
	assert(len(ordered) == len(bindings))
	return ordered[:]
}

// The argument a parameter takes: the one written with its name if any,
// otherwise the next unclaimed positional argument. Named arguments match
// first, so `f(reader, limit = 5)` binds `limit` to its own parameter rather
// than the one it sits next to.
@(private = "file")
claim_argument :: proc(
	args: []Arg_Info, name: Identifier_Id, next: ^int, claimed: []bool,
) -> (int, bool) {
	if name != INVALID_IDENTIFIER {
		for arg, index in args {
			if !claimed[index] && arg.name == name {
				claimed[index] = true
				return index, true
			}
		}
	}
	for next^ < len(args) {
		index := next^
		next^ += 1
		if claimed[index] {
			continue
		}
		if args[index].name != INVALID_IDENTIFIER {
			continue
		}
		claimed[index] = true
		return index, true
	}
	return -1, false
}

// The default of an omitted `$` parameter, checked in the declaration's own
// scope and bound as if it had been written at the call. A default that is not
// a constant is the same mistake a non-constant argument is, and says so in the
// same words. Why not, or empty.
@(private = "file")
bind_default_compile_time_argument :: proc(
	k: ^Checker,
	name: Name,
	default: Expr,
	declared: Expr,
	scope: ^Scope,
	out: ^[dynamic]Generic_Binding,
) -> string {
	context_type := resolve_type_syntax(k, clone_expr(k.c, declared))
	// Checked per call on a copy, as `twice(size_of(T))` resolves per `T`. A failure
	// only makes the candidate inapplicable, so this is a speculation.
	per_call := clone_expr(k.c, default)
	probe := begin_probe(k.c)
	type := check_expr(k, per_call, context_type)
	folded, evaluated := Const_Value{}, false
	if type != INVALID_TYPE && context_type != TYPE_TYPE {
		folded, evaluated = require_const(k, per_call, "a `$` parameter's default", "L0432")
	}
	end_probe(k.c, probe)
	if type == INVALID_TYPE {
		return "its omitted `$` argument's default does not check"
	}
	// `$N: $I = 3` binds `I` from the default's type, as a written argument's
	// type binds it.
	wanted, reason := poly_parameter_type(k, declared, type, scope, out)
	if reason != "" {
		return reason
	}
	arg := Arg_Info {
		expr        = per_call,
		span        = expr_span(per_call),
		name        = INVALID_IDENTIFIER,
		type        = type,
		const_value = folded,
	}
	return bind_compile_time_argument(k, name, arg, wanted, scope, out)
}

// A `$N: int` or `$T: type` argument. `type` receives a type; everything else
// receives a compile-time constant. Why not, or empty.
@(private = "file")
bind_compile_time_argument :: proc(
	k: ^Checker,
	name: Name,
	arg: Arg_Info,
	wanted: Type_Id,
	scope: ^Scope,
	out: ^[dynamic]Generic_Binding,
) -> string {
	if wanted == TYPE_TYPE {
		denoted := INVALID_TYPE
		if base := expr_base(arg.expr); base != nil {
			denoted = base.denoted_type
		}
		if denoted == INVALID_TYPE {
			denoted = resolve_type_syntax(k, arg.expr)
		}
		if denoted == INVALID_TYPE {
			return "a `$` parameter of type `type` needs a type argument"
		}
		// design.md "Maps": settled where the map type is named, as for an
		// interface argument, since the body may reach its members without ever
		// declaring a value of it.
		if !require_nested_map_key_policies(k, denoted, arg.span) {
			return "its type argument names a map with an invalid key"
		}
		if !bind_pattern_name(k, name, Generic_Arg{is_type = true, type = denoted}, scope, out) {
			return "its generic arguments do not agree"
		}
		return ""
	}
	if arg.const_value.kind == .Invalid {
		return "a `$` parameter needs a compile-time constant argument"
	}
	value := arg.const_value
	value_type := default_type(k.c, arg.type)
	if wanted != INVALID_TYPE {
		converted, problem := convert_generic_value(k, value, arg.type, wanted)
		if problem != "" {
			return problem
		}
		value, value_type = converted, wanted
	}
	if !bind_pattern_name(k, name, Generic_Arg{value = value, value_type = value_type}, scope, out) {
		return "its generic arguments do not agree"
	}
	return ""
}

// ---------------------------------------------------------- instantiation --

// The instance for one argument vector, creating it on first request. The
// signature is resolved and every `where` bound evaluated; the body is not
// checked until the instance is actually selected.
instantiate_generic :: proc(
	k: ^Checker,
	template: ^Generic_Template,
	bindings: []Generic_Binding,
	scope: ^Scope,
	span: Span,
	report: bool,
) -> (^Instance, bool) {
	if existing, found := cached_instance(k.c, template.symbol, bindings); found {
		if existing.provisional {
			if report {
				report_instantiation_cycle(k, span, template, bindings)
			}
			return nil, false
		}
		if !existing.signature_ok && report {
			report_rejected_instance(k, template, existing, span)
		}
		return existing, existing.signature_ok
	}

	if len(k.c.instantiation_stack) >= MAX_INSTANTIATION_DEPTH ||
	   k.c.instantiation_count >= MAX_INSTANTIATIONS {
		// Reported once, and never by a silent probe.
		if report && !k.c.instantiation_limit_hit {
			report_instantiation_limit(
				k, span, "instantiating `%s` exceeds the compiler's generic instantiation limit (%d deep, %d instances)",
				short_instantiation_name(k.c, generic_instance_name(k.c, template.symbol, bindings)),
				MAX_INSTANTIATION_DEPTH, MAX_INSTANTIATIONS,
			)
		}
		return nil, false
	}

	instance := new(Instance, k.c.semantic_allocator)
	instance.template = template.symbol
	instance.bindings = slice.clone(bindings, k.c.semantic_allocator)
	instance.scope = scope != nil ? scope : new_bound_instance_scope(k, template, bindings)
	instance.scope.instance = instance
	instance.provisional = true
	instance.span = span
	k.c.instances[instance_key(k.c, template.symbol, bindings, k.c.semantic_allocator)] = instance
	// Reserved before resolution, which may instantiate recursively. A rejected
	// entry stays cached, so repeated probes cost no further slots.
	k.c.instantiation_count += 1

	name := generic_instance_name(k.c, template.symbol, bindings)
	append(&k.c.instantiation_stack, Instantiation_Frame{symbol = template.symbol, bindings = instance.bindings, span = span, silent = !report})
	defer {
		pop(&k.c.instantiation_stack)
		instance.provisional = false
	}

	// A silent request is a probe: it must not fail the compilation over a
	// signature that does not resolve, so a rejection rolls its diagnostics back
	// and keeps the head one for a later request that reports.
	probe: Probe
	if !report {
		probe = begin_probe(k.c)
	}
	switch template.kind {
	case .Record:
		instance.signature_ok = instantiate_record_body(k, template, instance, name, report)
	case .Procedure:
		instance.signature_ok = instantiate_procedure_signature(k, template, instance, name, report)
	case .Alias, .None:
		// An alias application denotes its body's type (`resolve_alias_application`).
	}
	if !report {
		if !instance.signature_ok {
			instance.rejection = instance_rejection_since(k.c, probe.diagnostics)
		}
		end_probe(k.c, probe, keep = instance.signature_ok)
	}
	return instance, instance.signature_ok
}

// The first error since `mark`: the cause of a contained rejection, kept for a
// later request that reports.
@(private = "file")
instance_rejection_since :: proc(c: ^Compiler, mark: int) -> Instance_Rejection {
	for d in c.diagnostics[mark:] {
		if d.severity == .Error {
			return {code = d.code, message = strings.clone(d.message, c.semantic_allocator), span = d.span}
		}
	}
	return {}
}

@(private = "file")
report_rejected_instance :: proc(k: ^Checker, template: ^Generic_Template, instance: ^Instance, span: Span) {
	name := generic_instance_name(k.c, template.symbol, instance.bindings)
	saved := enter_instance(k, template, instance.scope)
	defer k.location = saved

	append(&k.c.instantiation_stack, Instantiation_Frame{symbol = template.symbol, bindings = instance.bindings, span = span})
	defer pop(&k.c.instantiation_stack)
	// A contained rejection: the caret on this request, a note at the original.
	if instance.rejection.code != "" {
		errorf(k.c, span, instance.rejection.code, "%s", instance.rejection.message)
		add_notef(k.c, instance.rejection.span, "in the %s of `%s`", template.kind == .Record ? "fields" : "signature", name)
		note_instantiation_stack(k)
		return
	}
	#partial switch template.kind {
	case .Record:
		check_where_clauses(k, instance.decl.values[0].(^Type_Record).where_clauses, span, name, report = true)
	case .Procedure:
		check_where_clauses(k, decl_proc_literal(instance.decl).where_clauses, span, name, report = true)
	}
}

// Whether a diagnostic reported now may yet be rolled back: by a probe, or by a
// silent instantiation that fails. A silent instantiation is a probe, but
// compile-time evaluation beneath it runs at depth zero, so its frame is asked.
@(private = "file")
diagnostics_provisional :: proc(k: ^Checker) -> bool {
	if !committing(k.c) {
		return true
	}
	for frame in k.c.instantiation_stack {
		if frame.silent {
			return true
		}
	}
	return false
}

@(private = "file")
report_instantiation_cycle :: proc(k: ^Checker, span: Span, template: ^Generic_Template, bindings: []Generic_Binding) {
	errorf(
		k.c,
		span,
		"L0436",
		"`%s` is being instantiated in terms of itself",
		short_instantiation_name(k.c, generic_instance_name(k.c, template.symbol, bindings)),
	)
	note_instantiation_stack(k)
}

// Counts a step of a type application that happens before any instance exists.
// False, reported once, past the instantiation limit; otherwise the caller pops
// the frame.
push_application_frame :: proc(k: ^Checker, span: Span, symbol: Symbol_Id, bindings: []Generic_Binding, report: bool) -> bool {
	if len(k.c.instantiation_stack) >= MAX_INSTANTIATION_DEPTH {
		if report && !k.c.instantiation_limit_hit {
			report_instantiation_limit(
				k, span, "expanding `%s` exceeds the compiler's generic instantiation limit (%d deep)",
				short_instantiation_name(k.c, generic_instance_name(k.c, symbol, bindings)), MAX_INSTANTIATION_DEPTH,
			)
		}
		return false
	}
	append(&k.c.instantiation_stack, Instantiation_Frame{symbol = symbol, bindings = bindings, span = span, silent = !report})
	return true
}

// The limit's report, made once. A report a probe will roll back has not been made.
@(private = "file")
report_instantiation_limit :: proc(k: ^Checker, span: Span, format: string, args: ..any) {
	k.c.instantiation_limit_hit = committing(k.c)
	errorf(k.c, span, "L0436", format, ..args)
	note_instantiation_stack(k)
}

// The innermost frames name a recursion; the rest are counted.
NOTED_INSTANTIATION_FRAMES :: 4

note_instantiation_stack :: proc(k: ^Checker, from := -1) {
	// Every unwinding level sees the same diagnostic; note the stack once.
	if len(k.c.diagnostics) == 0 || (from < 0 && k.c.last_noted_diagnostic == len(k.c.diagnostics)) {
		return
	}
	k.c.last_noted_diagnostic = len(k.c.diagnostics)
	context.allocator = diagnostic_allocator(k.c)
	for index := from < 0 ? len(k.c.diagnostics) - 1 : from; index < len(k.c.diagnostics); index += 1 {
		diagnostic := &k.c.diagnostics[index]
		if diagnostic.severity != .Error { continue }
		noted := false
		for note in diagnostic.notes { noted ||= strings.has_prefix(note.message, "while instantiating `") }
		if noted { continue }
		shown := 0
		#reverse for frame in k.c.instantiation_stack {
			if shown >= NOTED_INSTANTIATION_FRAMES {
				append(&diagnostic.notes, Note{span = NO_SPAN, message = fmt.aprintf(
					"and %d more instantiation%s", len(k.c.instantiation_stack) - shown,
					len(k.c.instantiation_stack) - shown == 1 ? "" : "s",
				)})
				break
			}
			append(&diagnostic.notes, Note{span = frame.span, message = fmt.aprintf(
				"while instantiating `%s`", short_instantiation_name(k.c, generic_instance_name(k.c, frame.symbol, frame.bindings)),
			)})
			shown += 1
		}
	}
}

// Positions the checker at an instance's definition: its scope, package, and
// file. Restored by assigning `k.location`.
enter_generic_location :: proc(k: ^Checker, location: Generic_Location) -> Checker_Location {
	saved := k.location
	k.scope = location.scope
	k.pkg, k.lookup_pkg = location.pkg, location.lookup_pkg
	k.impl_type = location.impl_type
	k.body = {}
	k.generic_depth += 1
	if location.file_node != nil {
		k.file, k.file_node = location.file, location.file_node
	}
	return saved
}

enter_instance :: proc(k: ^Checker, template: ^Generic_Template, scope: ^Scope) -> Checker_Location {
	location := template.location
	location.scope = scope
	return enter_generic_location(k, location)
}

// ------------------------------------------------------- record instances --

@(private = "file")
instantiate_record_body :: proc(
	k: ^Checker,
	template: ^Generic_Template,
	instance: ^Instance,
	name: string,
	report: bool,
) -> bool {
	clone := clone_decl(k.c, template.decl)
	record := clone.values[0].(^Type_Record)
	instance.decl = clone

	kind := record.kind == .Struct ? Type_Kind.Struct : Type_Kind.Union
	name_id := intern_identifier(k.c, name)
	symbol_id := new_symbol(k.c, Symbol {
		name        = name_id,
		span        = template.decl.span,
		kind        = .Type,
		pkg         = template.pkg,
		lookup_pkg  = template.lookup_pkg,
		decl        = clone,
		instance_of = template.symbol,
		def_scope   = instance.scope,
	})
	type := new_type(k.c, Type_Info{kind = kind, name = name_id, symbol = symbol_id, move_only = record.move_only})
	if sym := symbol_of(k.c, symbol_id); sym != nil {
		sym.type = type
	}
	if info := type_of(k.c, type); info != nil {
		info.instance_of = template.symbol
		info.instance_args = generic_args_of(k.c, instance.bindings)
	}
	instance.symbol = symbol_id
	instance.type = type
	instance.impl_candidates = make(map[Impl_Member_Key][dynamic]Impl_Candidate, k.c.semantic_allocator)
	saved := enter_instance(k, template, instance.scope)
	defer k.location = saved

	// Bounds first: `where N > 0` is what makes `[N]int` well formed.
	if !check_where_clauses(k, record.where_clauses, instance.span, name, report) {
		return false
	}
	// Settled once its bounds hold, as a non-generic record is once declared: a
	// field or a method of another instance can name this one while its own
	// fields resolve. Until they have, `sig_state` marks them incomplete, so
	// nothing measures or caches a partial record.
	instance.provisional = false
	instance.signature_ok = true
	clone.sig_state = .Checking
	before := len(k.c.diagnostics)
	// design.md "Interface bodies": the fields have the grant of the record's bounds.
	k.body.bounds, k.body.bounds_set = record.where_clauses, true
	if record.kind == .Struct {
		resolve_struct_fields(k, type, record)
	} else {
		resolve_union_variants(k, type, record)
	}
	k.body.bounds, k.body.bounds_set = nil, false
	apply_type_metadata(k, clone, type)
	clone.sig_state = .Checked
	if report && len(k.c.diagnostics) > before {
		note_instantiation_stack(k, before)
	}
	// Errors an enclosing probe will roll back would leave a broken instance in
	// the cache that no later use reports, so the instance is rejected and keeps
	// its cause, as a silently rejected signature does.
	if errors_since(k.c, before) && diagnostics_provisional(k) {
		instance.rejection = instance_rejection_since(k.c, before)
		// Emptied like an instance whose bound failed, since the backend defines
		// every record in the type store.
		if info := type_of(k.c, type); info != nil {
			info.fields = nil
		}
		instance.signature_ok = false
		return false
	}

	path := make([dynamic]Type_Id, 0, 8, context.temp_allocator)
	check_finite_size(k, type, template.decl.span, &path)

	append(&template.instances, instance)
	pend_template_private_read(k, template, instance.scope)
	install_generic_impls(k, template, instance)
	return true
}

generic_args_of :: proc(c: ^Compiler, bindings: []Generic_Binding) -> []Generic_Arg {
	out := make([]Generic_Arg, len(bindings), c.semantic_allocator)
	for binding, index in bindings {
		out[index] = binding.arg
	}
	return out
}

// A generic type applied in type position: `Table(string, int)`.
instantiate_record_application :: proc(k: ^Checker, v: ^Expr_Call, template: ^Generic_Template, report: bool) -> Type_Id {
	if template_rejected(k, template) || !generic_application_fits(k, v.args, v.span, template, report) {
		return INVALID_TYPE
	}

	// Every use of `Option(int)` comes here, and all but the first find its
	// instance: parameters that are all types need no scope to read them in, so
	// one is made only if the cache misses.
	all_types := true
	for parameter in template.params {
		all_types &&= parameter_takes_type(parameter)
	}
	scope := all_types ? nil : new_instance_scope(k, template)
	bindings := make([dynamic]Generic_Binding, 0, len(template.params), context.temp_allocator)
	saved_scope := k.scope
	ok := true
	for parameter, index in template.params {
		wanted := TYPE_TYPE
		if !parameter_takes_type(parameter) {
			// A constant parameter's type can apply this template again, as
			// `$V: Record(T, 0)` does, before any instance is pushed, so the limit
			// counts it.
			if !push_application_frame(k, v.span, template.symbol, bindings[:], report) {
				return INVALID_TYPE
			}
			k.scope = scope
			// A copy, so `[N]int` names this application's `N` and not a cached earlier one.
			wanted = resolve_type_syntax(k, clone_expr(k.c, parameter.type_syntax))
			k.scope = saved_scope
			pop(&k.c.instantiation_stack)
			// At the limit `wanted` is invalid, and the argument must not then be read as a type.
			if wanted == INVALID_TYPE && k.c.instantiation_limit_hit {
				return INVALID_TYPE
			}
		}
		if !bind_record_argument(k, parameter, v.args[index], wanted, scope, &bindings, report) {
			ok = false
		}
	}
	if !ok {
		return INVALID_TYPE
	}

	instance, made := instantiate_generic(k, template, bindings[:], scope, v.span, report)
	if !made {
		return INVALID_TYPE
	}
	v.denoted_type = instance.type
	v.value_category = .Type
	v.resolution = Resolution{kind = .Type, symbol = instance.symbol}
	return instance.type
}

// grammar.md `Type_Arguments`: a generic argument is a bare type or value. The
// call syntax it shares would otherwise let a name or mode through unread, so
// `Box(N = int, T = 2)` bound by position.
generic_arguments_positional :: proc(k: ^Checker, args: []Argument, code: string, report: bool) -> bool {
	for arg in args {
		what := ""
		switch {
		case arg.name.text != "":
			what = "cannot be named; generic arguments are positional"
		case arg.mode == .Inout:
			what = "cannot be `inout`"
		case arg.mode == .Spread:
			what = "cannot be spread"
		case:
			continue
		}
		if report {
			errorf(k.c, arg.span, code, "a generic argument %s", what)
		}
		return false
	}
	return true
}

// Whether a record's or interface's parameter is written `$T: type`, which needs
// no resolving.
parameter_takes_type :: proc(parameter: Generic_Param_Decl) -> bool {
	_, is_type := parameter.type_syntax.(^Type_Type)
	return is_type || parameter.type_syntax == nil
}

// Whether an application's arguments are positional and as many as the template
// takes; reported when `report`.
generic_application_fits :: proc(k: ^Checker, args: []Argument, span: Span, template: ^Generic_Template, report: bool) -> bool {
	if !generic_arguments_positional(k, args, "L0431", report) {
		return false
	}
	if len(args) == len(template.params) {
		return true
	}
	if report {
		errorf(
			k.c, span, "L0431", "`%s` takes %d generic argument%s, found %d",
			identifier_text(k.c, symbol_of(k.c, template.symbol).name),
			len(template.params), len(template.params) == 1 ? "" : "s", len(args),
		)
	}
	return false
}

// `Option(int)` from type ids, for compiler-built uses of source-declared
// templates.
instantiate_record_types :: proc(k: ^Checker, symbol: Symbol_Id, args: []Type_Id, span: Span) -> Type_Id {
	template := generic_template_for(k, symbol)
	if template == nil || len(template.params) != len(args) {
		return INVALID_TYPE
	}
	bindings := make([dynamic]Generic_Binding, 0, len(args), context.temp_allocator)
	for parameter, index in template.params {
		name := Name{text = identifier_text(k.c, parameter.name), span = span, id = parameter.name}
		if !bind_pattern_name(k, name, Generic_Arg{is_type = true, type = args[index]}, nil, &bindings) {
			return INVALID_TYPE
		}
	}
	instance, made := instantiate_generic(k, template, bindings[:], nil, span, report = true)
	if !made {
		return INVALID_TYPE
	}
	return instance.type
}

// One written argument of a type application against its parameter: a type, or a
// constant converted to `wanted`. Reported when `report`, or rolled back with it.
bind_record_argument :: proc(
	k: ^Checker,
	parameter: Generic_Param_Decl,
	arg: Argument,
	wanted: Type_Id,
	scope: ^Scope,
	out: ^[dynamic]Generic_Binding,
	report: bool,
) -> bool {
	reject :: proc(k: ^Checker, arg: Argument, problem: string, report: bool) -> bool {
		if report {
			errorf(k.c, arg.span, "L0432", "%s", problem)
		}
		return false
	}
	bound: Generic_Arg
	if wanted == TYPE_TYPE || wanted == INVALID_TYPE {
		denoted := resolve_type_syntax(k, arg.value)
		if denoted == INVALID_TYPE {
			if call, is_call := arg.value.(^Expr_Call); is_call && report && report_handle_type_spelling(k, call, type_position = true) {
				return false
			}
			return reject(k, arg, "a generic `type` parameter needs a type argument", report)
		}
		// design.md "Maps": settled where the map type is named, before the
		// instance's own member signatures name it inside the template, and
		// whether or not a field holds it: `Shared(T)` keeps `T` behind a `rawptr`.
		if !require_nested_map_key_policies(k, denoted, arg.span) {
			return false
		}
		bound = Generic_Arg{is_type = true, type = denoted}
	} else {
		value: Const_Value
		value_type: Type_Id
		// `M($R, $C)` re-read inside the instance that bound them, as `[$N]E` and
		// `Simd($T, $N)` are: the `$` name stands for its constant.
		if poly, is_poly := arg.value.(^Type_Poly); is_poly {
			sym := symbol_of(k.c, lookup_symbol(k.scope, name_identifier(k.c, poly.name)))
			if sym == nil || sym.kind != .Const {
				if report {
					report_unresolved_type(k, poly)
				}
				return false
			}
			value, value_type = sym.const_value, sym.type
		} else {
			if check_single_expr(k, arg.value, wanted) == INVALID_TYPE {
				return false
			}
			folded, evaluated := require_const(k, arg.value, "a generic argument", "L0432")
			if !evaluated {
				return false
			}
			value, value_type = folded, expr_base(arg.value).type
		}
		converted, problem := convert_generic_value(k, value, value_type, wanted)
		if problem != "" {
			return reject(k, arg, problem, report)
		}
		bound = Generic_Arg{value = converted, value_type = wanted}
	}
	name := Name{text = identifier_text(k.c, parameter.name), span = arg.span, id = parameter.name}
	if !bind_pattern_name(k, name, bound, scope, out) {
		return reject(k, arg, "this generic argument disagrees with an earlier one", report)
	}
	return true
}

// A constant generic argument converted to its parameter's type, or why not.
@(private = "file")
convert_generic_value :: proc(k: ^Checker, value: Const_Value, value_type, wanted: Type_Id) -> (Const_Value, string) {
	converted, fits := convert_constant_argument(k.c, value, value_type, wanted)
	if fits {
		return converted, ""
	}
	if type_is_enum(k.c, wanted) && !assignable(k.c, value_type, wanted) {
		return {}, "an enum generic argument must be a variant of the parameter's enum type"
	}
	return {}, fmt.aprintf(
		"`%s` is not representable by the generic parameter's type `%s`",
		generic_value_text(k.c, value), type_name(k.c, wanted), allocator = k.c.semantic_allocator,
	)
}

// A constant converted for a `$` parameter of type `wanted`. An enum parameter
// takes only its own variants, and `nil` only what it converts to.
convert_constant_argument :: proc(c: ^Compiler, value: Const_Value, value_type, wanted: Type_Id) -> (Const_Value, bool) {
	converted, fits := convert_const(c, value, wanted, false)
	fits &&= !type_is_enum(c, wanted) || assignable(c, value_type, wanted)
	fits &&= nil_converts(c, value_type, wanted)
	return converted, fits
}

// ---------------------------------------------------- procedure instances --

@(private = "file")
instantiate_procedure_signature :: proc(
	k: ^Checker,
	template: ^Generic_Template,
	instance: ^Instance,
	name: string,
	report: bool,
) -> bool {
	clone := clone_decl(k.c, template.decl)
	literal := decl_proc_literal(clone)
	literal.generic_instance = true
	instance.decl = clone

	origin := symbol_of(k.c, template.symbol)
	symbol_id := new_symbol(k.c, Symbol {
		name        = intern_identifier(k.c, name),
		span        = origin.span,
		kind        = .Proc,
		type        = TYPE_VOID,
		pkg         = template.pkg,
		lookup_pkg  = template.lookup_pkg,
		public      = origin.public,
		decl        = clone,
		owner_type  = origin.owner_type,
		operator    = origin.operator,
		instance_of = template.symbol,
		def_scope   = instance.scope,
	})
	instance.symbol = symbol_id
	clone.symbols = make([]Symbol_Id, 1, k.c.semantic_allocator)
	k.c.procedure_instances[symbol_id] = instance
	clone.symbols[0] = symbol_id
	literal.symbol = symbol_id

	saved := enter_instance(k, template, instance.scope)
	defer k.location = saved

	before := k.c.error_count
	clone.sig_state = .Checked
	resolve_proc_signature(k, literal, symbol_id)
	if origin.operator != "" {
		validate_operator_instance(k, clone, symbol_id)
	}
	if k.c.error_count > before {
		if report {
			note_instantiation_stack(k)
		}
		return false
	}
	if !check_where_clauses(k, literal.where_clauses, instance.span, name, report, false_bound = &instance.failed_bound) {
		return false
	}
	instance.bounds_committed = report
	return true
}

// Checks a selected instance's body exactly once, and queues it for emission
// with its defining package's items.
promote_generic_instance :: proc(k: ^Checker, instance: ^Instance, span: Span) {
	// Speculation must not commit a body whose dependencies it suppressed.
	if !committing(k.c) || instance == nil || instance.body_checked || !instance.signature_ok {
		return
	}
	instance.body_checked = true
	template, found := k.c.generic_templates[instance.template]
	if !found || template.kind != .Procedure {
		return
	}
	instance.selected_at = span.file == NO_FILE ? instance.span : span
	pend_template_private_read(k, template, instance.scope)
	literal := decl_proc_literal(instance.decl)
	if literal == nil || literal.body == nil {
		return
	}

	saved := enter_instance(k, template, instance.scope)
	defer k.location = saved

	sym := symbol_of(k.c, instance.symbol)
	// Diagnosed against the selecting call; a probe-created instance has none.
	append(&k.c.instantiation_stack, Instantiation_Frame {
		symbol   = instance.template,
		bindings = instance.bindings,
		span     = instance.selected_at,
	})
	defer pop(&k.c.instantiation_stack)

	before := len(k.c.diagnostics)
	if !instance.bounds_committed {
		// Known to hold; checked again only for what it reports, such as a
		// deprecated call, which the probe rolled back.
		instance.bounds_committed = true
		_ = check_where_clauses(k, literal.where_clauses, instance.span, identifier_text(k.c, sym.name), true)
	}
	instance.decl.check_state = .Checked
	// An inferred `$T` can be a compile-time-only type the template never wrote,
	// such as `type` from `f(int)`, so the instance's runtime shape is gated.
	if compile_time_only_procedure(k.c, sym) {
		check_proc_body(k, literal)
	} else if offender := compile_time_only_component(k.c, sym.proc_type); offender != INVALID_TYPE {
		report_compile_time_only(k, offender, literal.span)
	} else if gate_type(k, sym.proc_type, literal.span) {
		check_proc_body(k, literal)
	}
	instance.decl.check_failed = errors_since(k.c, before)
	if len(k.c.diagnostics) > before {
		note_instantiation_stack(k)
	}

	if pkg := package_of(k.c, template.pkg); pkg != nil {
		append(&pkg.instances, Instance_Decl {
			symbol   = instance.symbol,
			decl     = instance.decl,
			template = template.symbol,
			args     = generic_args_of(k.c, instance.bindings),
		})
	}
}

// ------------------------------------------------------------ where clauses --

// design.md "where clauses": a failed bound silently drops a candidate, or is an
// error when `report` is set. `report_malformed` still reports a bound that is
// not a compile-time boolean at all.
check_where_clauses :: proc(
	k: ^Checker, clauses: []Expr, span: Span, what: string, report: bool,
	report_malformed := false, false_bound: ^Expr = nil,
) -> bool {
	// design.md "Interface bodies": each bound has the grant of the others.
	outer_bounds, outer_set := k.body.bounds, k.body.bounds_set
	k.body.bounds, k.body.bounds_set = clauses, true
	defer k.body.bounds, k.body.bounds_set = outer_bounds, outer_set
	for clause in clauses {
		errors := k.c.error_count
		probe: Probe
		if !report {
			probe = begin_probe(k.c)
		}
		type := check_single_expr(k, clause, TYPE_BOOL)
		folded, evaluated := require_const(k, clause, "a `where` bound", "L0435")
		failed := type == INVALID_TYPE || !evaluated || folded.kind != .Boolean
		// A reporting check is committed, so what a passing bound reported stays;
		// so does a malformed bound's report when that is asked for.
		if !report {
			end_probe(k.c, probe, keep = failed && report_malformed)
		}
		if !failed && folded.boolean {
			continue
		}
		if !report && !(failed && report_malformed) {
			if !failed && false_bound != nil {
				false_bound^ = clause
			}
			return false
		}
		if failed {
			// An invalid bound whose cause was reported elsewhere, such as a map key
			// a report-once cache already rejected, needs no second error.
			if k.c.error_count == errors && !(type == INVALID_TYPE && k.c.error_count > 0) {
				errorf(k.c, expr_span(clause), "L0435", "a `where` bound must be a compile-time boolean")
			}
		} else if !report_failed_interface_bound(k, clause, span) {
			// An interface bound names the failed requirement; a predicate, itself.
			errorf(k.c, span, "L0434", "`%s` does not satisfy the bound `%s`", what, where_bound_text(k.c, clause))
			add_notef(k.c, expr_span(clause), "the bound is written here")
		}
		note_instantiation_stack(k)
		return false
	}
	return true
}

// Why a silent probe's `where` bounds rejected `instance`, for an overload note.
// Read in the instance's scope, as the bound was, and leaves no diagnostic.
failed_bound_reason :: proc(k: ^Checker, template: ^Generic_Template, instance: ^Instance) -> string {
	saved := enter_instance(k, template, instance.scope)
	defer k.location = saved
	probe := begin_probe(k.c)
	text := failed_bound_text(k, instance.failed_bound)
	end_probe(k.c, probe)
	return text
}

where_bound_text :: proc(c: ^Compiler, clause: Expr) -> string {
	text := source_text(c, clause)
	return text != "" ? text : "where"
}
