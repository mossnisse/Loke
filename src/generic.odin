// Generics: templates, inference, `where`, and the monomorphization cache.
// Each argument vector gets a cloned declaration whose scope binds the `$`
// names and hangs off the declaration's own scope, never the caller's.
package lokec

import "core:fmt"
import "core:strings"

// Recursive instantiation need not terminate; running out is a diagnostic.
MAX_INSTANTIATION_DEPTH :: 64
MAX_INSTANTIATIONS :: 4096

Generic_Kind :: enum {
	None,
	Procedure,
	Record,
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

// A declaration that means nothing until its arguments are supplied.
Generic_Template :: struct {
	symbol:     Symbol_Id,
	decl:       ^Decl,
	kind:       Generic_Kind,
	// The declaration's own lexical scope: an instance's scope hangs off this one
	// so a caller's names can never enter the instantiation.
	scope:      ^Scope,
	pkg:        Package_Id,
	lookup_pkg: Package_Id,
	impl_type:  Type_Id,
	file:       u32,
	file_node:  ^File,
	// Record templates only, in declaration order.
	params:     []Generic_Param_Decl,
	// Record templates only: every instance made so far, so a block registered
	// after one exists still reaches it.
	instances:   [dynamic]^Instance,
	// Its declaration was rejected and reported; a use reports nothing more.
	rejected:    bool,
}

Generic_Param_Decl :: struct {
	name:        Identifier_Id,
	span:        Span,
	type_syntax: Expr,
}

// An `impl` block written against a generic type, kept aside until an
// instantiation of that type exists to install it on.
Generic_Impl :: struct {
	item:        ^Item_Impl,
	template:    Symbol_Id,
	pkg:         Package_Id,
	scope:       ^Scope,
	file:        u32,
	file_node:   ^File,
	// Written arguments, so `impl Table(string, int)` applies to one instance and
	// `impl Table($K, $V)` to every one.
	args:        []Expr,
	specificity: int,
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
	// The backend spelling of this instance, kept apart from the readable name
	// diagnostics use.
	mangled:      string,
	signature_ok: bool,
	// Deferred so an unselected overload never has its body diagnosed.
	body_checked: bool,
	span:         Span,
	// Why a silent probe rejected this cached instance, for a later request that
	// reports.
	rejection:    Instance_Rejection,
	// The `where` bound a silent probe found false, so an overload note can name
	// it; a later request that reports re-checks the bounds itself.
	failed_bound: Expr,
	// Whether the `where` bounds were checked by a reporting request. A silent
	// probe's check is rolled back, so committing the body checks them again.
	bounds_committed: bool,
}

// The head diagnostic of a contained rejection, kept rather than the whole
// list: it is the cause, and everything after it is that cause's fallout.
Instance_Rejection :: struct {
	code:    string,
	message: string,
	span:    Span,
}

Instantiation_Frame :: struct {
	description: string,
	span:        Span,
}

// An instantiated `impl` block waiting for its bodies to be checked.
// Signatures are installed as soon as the instance exists, so a method is
// callable right away; bodies wait until the requesting package is finished,
// so a method may itself use the instance.
Pending_Impl :: struct {
	item:      ^Item_Impl,
	scope:     ^Scope,
	pkg:       Package_Id,
	file:      u32,
	file_node: ^File,
	subject:   Type_Id,
	checked:   bool,
}

// A procedure instance waiting to be named and emitted with its defining
// package's items.
Instance_Decl :: struct {
	symbol: Symbol_Id,
	decl:   ^Decl,
	name:   string,
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
	rejected := false
	if literal != nil && literal.signature != nil {
		check_independent_poly_defaults(k, literal.signature.params)
		for parameter in literal.signature.params {
			for entry in parameter.names {
				if entry.is_poly {
					rejected |= reject_typeid_generic_parameter(k, entry.name, parameter.type)
				}
			}
		}
	}
	if record, is_record := d.values[0].(^Type_Record); is_record {
		for group in record.generic_params {
			for name in group.names {
				rejected |= reject_typeid_generic_parameter(k, name, group.type)
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

// design.md "`type` and `typeid`": a `typeid` is a runtime value and does not
// make a generic declaration, so a `$` parameter of that type is an error here
// rather than a failure at every call. Resolved as a speculation, since the type
// may name an earlier `$T` that only an instance binds.
@(private = "file")
reject_typeid_generic_parameter :: proc(k: ^Checker, name: Name, type_syntax: Expr) -> bool {
	if type_syntax == nil {
		return false
	}
	mark := len(k.c.diagnostics)
	k.c.speculation_depth += 1
	type := resolve_type_syntax(k, type_syntax)
	k.c.speculation_depth -= 1
	truncate_diagnostics(k.c, mark)
	if type == INVALID_TYPE || type_underlying(k.c, type) != TYPE_TYPEID {
		return false
	}
	errorf(
		k.c, expr_span(type_syntax), "L0439",
		"a `$` parameter cannot be a `typeid`: a runtime type identifier does not specialize a declaration",
	)
	add_notef(k.c, name.span, "write `$%s: type`, and `typeid_of(%s)` where the identifier is needed", name.text, name.text)
	return true
}

// A `$` default that names no parameter means the same in every instance, so it
// is checked where it is written: a mistake in it is the declaration's, and it
// would otherwise surface only as an inapplicable candidate at a call, or not at
// all when every call supplies the argument. A default that names a parameter,
// as `$N: int = size_of(T)` does, is checked per call once `T` is bound. Which
// it is, resolution decides: a speculative check against a scope of stand-ins
// for every parameter name, `$` names in types included, sees whether any
// lookup reached one. A field or a nested parameter spelled `T` does not.
@(private = "file")
check_independent_poly_defaults :: proc(k: ^Checker, params: []Parameter) {
	stand_ins := new_scope(k.c, k.scope, .Local)
	for parameter in params {
		for entry in parameter.names {
			declare_stand_in(k, stand_ins, entry.name.text, entry.name.span)
		}
		declare_poly_stand_ins(k, stand_ins, expr_span(parameter.type))
	}
	for parameter in params {
		poly := false
		for entry in parameter.names {
			poly ||= entry.is_poly
		}
		if !poly || parameter.default == nil {
			continue
		}
		// The parameter's type may still name `$T`; then only constness is known.
		mark := len(k.c.diagnostics)
		k.c.speculation_depth += 1
		wanted := resolve_type_syntax(k, parameter.type)
		saved := k.scope
		k.scope = stand_ins
		stand_ins.reached = false
		check_poly_default(k, clone_expr(k.c, parameter.default), wanted)
		k.scope = saved
		k.c.speculation_depth -= 1
		truncate_diagnostics(k.c, mark)
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

@(private = "file")
declare_stand_in :: proc(k: ^Checker, scope: ^Scope, name: string, span: Span) {
	id := intern_identifier(k.c, name)
	scope.names[id] = new_symbol(k.c, Symbol{name = id, span = span, pkg = k.pkg})
}

// Every `$name` written in `span`. A `$` outside a string or rune literal
// always binds a name, so spelling is exact here.
@(private = "file")
declare_poly_stand_ins :: proc(k: ^Checker, scope: ^Scope, span: Span) {
	if span.file == NO_FILE || int(span.file) >= len(k.c.sources) {
		return
	}
	text := k.c.sources[span.file].text
	i, hi := int(span.lo), min(int(span.hi), len(text))
	for i < hi {
		ch := text[i]
		switch {
		case ch == '"' || ch == '\'' || ch == '`':
			i += 1
			for i < hi && text[i] != ch {
				i += ch != '`' && text[i] == '\\' ? 2 : 1
			}
			i += 1
		case ch == '$':
			i += 1
			start := i
			for i < hi && (text[i] == '_' || ('a' <= text[i] && text[i] <= 'z') || ('A' <= text[i] && text[i] <= 'Z') || ('0' <= text[i] && text[i] <= '9')) {
				i += 1
			}
			if i > start {
				declare_stand_in(k, scope, text[start:i], Span{file = span.file, lo = u32(start), hi = u32(i)})
			}
		case:
			i += 1
		}
	}
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

// design.md tie-breaker 5: a structural specialization beats an unspecialized
// parameter. A `$T` pins nothing down; every written layer of structure counts.
pattern_specificity :: proc(e: Expr) -> int {
	specificity, _ := pattern_shape(e)
	return specificity
}

@(private = "file")
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
		if !ok || len(left.args) != len(right.args) { return .Crossed }
		relation := Pattern_Relation.Equal
		for arg, index in left.args {
			relation = merge_pattern_relation(relation, pattern_relation(arg.value, right.args[index].value))
		}
		return relation
	case ^Type_Proc:
		right, ok := b.(^Type_Proc)
		if !ok || (left.result == nil) != (right.result == nil) {
			return .Crossed
		}
		left_params := make([dynamic]Expr, context.temp_allocator)
		right_params := make([dynamic]Expr, context.temp_allocator)
		for parameter in left.params {
			for _ in 0 ..< max(len(parameter.names), 1) { append(&left_params, parameter.type) }
		}
		for parameter in right.params {
			for _ in 0 ..< max(len(parameter.names), 1) { append(&right_params, parameter.type) }
		}
		if len(left_params) != len(right_params) {
			return .Crossed
		}
		relation := Pattern_Relation.Equal
		for parameter, index in left_params {
			relation = merge_pattern_relation(relation, pattern_relation(parameter, right_params[index]))
		}
		if left.result != nil {
			relation = merge_pattern_relation(relation, pattern_relation(left.result.type, right.result.type))
		}
		return relation
	}
	return .Equal
}

compare_generic_specificity :: proc(a, b: ^Generic_Template) -> int {
	if a == nil || b == nil {
		return 0
	}
	left := decl_proc_literal(a.decl)
	right := decl_proc_literal(b.decl)
	if left == nil || right == nil || left.signature == nil || right.signature == nil {
		return 0
	}
	left_patterns := make([dynamic]Expr, context.temp_allocator)
	right_patterns := make([dynamic]Expr, context.temp_allocator)
	for parameter in left.signature.params {
		for _ in 0 ..< max(len(parameter.names), 1) { append(&left_patterns, parameter.type) }
	}
	for parameter in right.signature.params {
		for _ in 0 ..< max(len(parameter.names), 1) { append(&right_patterns, parameter.type) }
	}
	if len(left_patterns) != len(right_patterns) {
		return 0
	}
	relation := Pattern_Relation.Equal
	for pattern, index in left_patterns {
		relation = merge_pattern_relation(relation, pattern_relation(pattern, right_patterns[index]))
	}
	switch relation {
	case .Left:  return -1
	case .Right: return 1
	case .Equal, .Crossed:
	}
	return 0
}

@(private = "file")
pattern_shape :: proc(e: Expr) -> (specificity: int, has_poly: bool) {
	if e == nil {
		return 0, false
	}
	parts: [dynamic]Expr
	parts.allocator = context.temp_allocator
	#partial switch v in e {
	case ^Type_Poly:
		return 0, true
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
		_, has_poly = pattern_shape(v.callee)
	case:
		return 1, false
	}
	specificity = 1
	for part in parts {
		part_specificity, part_poly := pattern_shape(part)
		specificity += part_specificity
		has_poly ||= part_poly
	}
	return specificity, has_poly
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
	case .Procedure:
	case .None:
	}

	sym.generic = true
	k.c.generic_templates[symbol_id] = template
	return template
}

// The symbol a callee names, whether written plainly or package-qualified.
// `pkg.Table(int)` names a template as plainly as `Table(int)` does.
named_callee_symbol :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	#partial switch v in callee {
	case ^Expr_Ident:
		return lookup_symbol(k.scope, identifier_of(k.c, v))
	case ^Expr_Selector:
		ident, is_ident := v.operand.(^Expr_Ident)
		if !is_ident {
			return INVALID_SYMBOL
		}
		alias := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
		if alias == nil || alias.kind != .Package_Alias {
			return INVALID_SYMBOL
		}
		target := package_of(k.c, alias.pkg)
		if target == nil || target.scope == nil {
			return INVALID_SYMBOL
		}
		member, found := target.scope.names[intern_identifier(k.c, v.name.text)]
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

// The template a generic application names, or nil.
generic_template_of_callee :: proc(k: ^Checker, callee: Expr, kind: Generic_Kind) -> ^Generic_Template {
	template := generic_template_for(k, named_callee_symbol(k, callee))
	return template != nil && template.kind == kind ? template : nil
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

// -------------------------------------------------------------- cache key --

@(private = "file")
instance_key :: proc(c: ^Compiler, template: Symbol_Id, bindings: []Generic_Binding) -> string {
	b := strings.builder_make(c.semantic_allocator)
	fmt.sbprintf(&b, "%d", u32(template))
	for binding in bindings {
		strings.write_string(&b, "|")
		if binding.arg.is_type {
			fmt.sbprintf(&b, "T%d", u32(binding.arg.type))
		} else {
			// Length-prefixed, since a string may contain `|`.
			text := const_key_text(c, binding.arg.value)
			fmt.sbprintf(&b, "V%d:%d:%s", u32(binding.arg.value_type), len(text), text)
		}
	}
	return strings.to_string(b)
}

const_key_text :: proc(c: ^Compiler, value: Const_Value) -> string {
	#partial switch value.kind {
	case .Integer, .Rune:
		return bi_text(c, value.integer)
	case .Boolean:
		return value.boolean ? "true" : "false"
	case .Float:
		return fmt.aprintf("%h", value.float, allocator = c.semantic_allocator)
	case .String:
		return value.text
	case .Type:
		return fmt.aprintf("t%d", u32(value.type_value), allocator = c.semantic_allocator)
	case .Nil:
		return "nil"
	case .Aggregate:
		if value.aggregate == nil {
			return "{}"
		}
		b := strings.builder_make(c.semantic_allocator)
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

// A readable `Table(string, int)` for diagnostics and mangled symbol names.
generic_instance_name :: proc(c: ^Compiler, template: Symbol_Id, bindings: []Generic_Binding) -> string {
	b := strings.builder_make(c.semantic_allocator)
	if sym := symbol_of(c, template); sym != nil {
		if sym.owner_type != INVALID_TYPE {
			strings.write_string(&b, type_name(c, sym.owner_type))
			strings.write_string(&b, ".")
			strings.write_string(&b, identifier_text(c, sym.name))
		} else {
			strings.write_string(&b, identifier_text(c, sym.name))
		}
	}
	strings.write_string(&b, "(")
	for binding, index in bindings {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		if binding.arg.is_type {
			strings.write_string(&b, type_name(c, binding.arg.type))
		} else if binding.arg.value.kind == .String {
			strings.write_quoted_string(&b, binding.arg.value.text)
		} else {
			strings.write_string(&b, const_key_text(c, binding.arg.value))
		}
	}
	strings.write_string(&b, ")")
	return strings.to_string(b)
}

// The same identity as a backend symbol, `Table.int.i32`; each part is escaped
// on its own, so distinct vectors stay distinct.
generic_mangled_name :: proc(c: ^Compiler, template: Symbol_Id, bindings: []Generic_Binding) -> string {
	b := strings.builder_make(c.semantic_allocator)
	if sym := symbol_of(c, template); sym != nil {
		// `Atomic(int).load` and `Atomic(bool).load` are two templates named `load`.
		if sym.owner_type != INVALID_TYPE {
			owner := llvm_safe(qualified_member_name(c, sym, context.temp_allocator))
			strings.write_string(&b, owner)
			delete(owner)
		} else {
			strings.write_string(&b, identifier_text(c, sym.name))
		}
	}
	for binding in bindings {
		strings.write_string(&b, ".")
		part := binding.arg.is_type ? type_name(c, binding.arg.type) : const_key_text(c, binding.arg.value)
		escaped := llvm_safe(part, dots = false)
		strings.write_string(&b, escaped)
		delete(escaped)
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------- instance scope --

// A scope whose parent is the declaration's lexical scope, holding one symbol
// per bound generic name: a `Type` symbol for a type argument and a `Const` for
// a value argument, so ordinary name resolution finds both.
@(private = "file")
new_instance_scope :: proc(k: ^Checker, template: ^Generic_Template) -> ^Scope {
	parent := template.scope
	if parent == nil {
		parent = build_universe(k.c)
	}
	return new_scope(k.c, parent, .Local)
}

bind_generic_name :: proc(k: ^Checker, scope: ^Scope, binding: Generic_Binding) {
	sym := Symbol {
		name = binding.name,
		span = binding.span,
		pkg  = k.pkg,
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

// -------------------------------------------------------- pattern matching --

// Binds every `$` name in a written parameter type from the shape of a supplied
// argument's type. Returns false only when a binding is impossible — a pattern
// with no `$` is not this function's business, and ordinary conversion ranking
// still decides whether the argument fits.
// design.md "Dynamic arrays": a `[dynamic]T` argument reaches a `[]T` pattern
// through the implicit view, so `sum(xs: []$T)` accepts one. A failed attempt
// leaves no binding behind.
@(private = "file")
match_dynamic_as_view :: proc(
	k: ^Checker, pattern: Expr, actual: Type_Id, scope: ^Scope, out: ^[dynamic]Generic_Binding,
) -> bool {
	info := underlying_info(k.c, actual)
	if _, is_slice := pattern.(^Type_Slice); !is_slice || info == nil || info.kind != .Dynamic_Array {
		return false
	}
	before := len(out)
	if match_type_pattern(k, pattern, slice_of(k.c, info.element, false), scope, out) {
		return true
	}
	resize(out, before)
	return false
}

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
		return bind_pattern_name(k, v.name, Generic_Arg{is_type = true, type = default_type(k.c, actual)}, scope, out)

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
		// A `[]mut E` argument reaches a `[]$E` parameter through capability
		// weakening; a `[]E` argument cannot reach a `[]mut $E` parameter.
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
		if length, is_poly := v.length.(^Type_Poly); is_poly {
			arg := Generic_Arg {
				value      = int_const(k.c, i64(info.count)),
				value_type = TYPE_INT,
			}
			if !bind_pattern_name(k, length.name, arg, scope, out) {
				return false
			}
		}
		return match_type_pattern(k, v.elem, info.element, scope, out)

	case ^Expr_Call:
		// design.md "SIMD vectors": `Simd($T, $N)` is written like a generic
		// application but is a predeclared type constructor, so its parts come
		// from the type itself rather than from a template's bound arguments.
		if simd_callee(k, v.callee) {
			if info.kind != .Simd || len(v.args) != 2 {
				return false
			}
			if lanes, is_poly := v.args[1].value.(^Type_Poly); is_poly {
				arg := Generic_Arg {
					value      = int_const(k.c, i64(info.count)),
					value_type = TYPE_INT,
				}
				if !bind_pattern_name(k, lanes.name, arg, scope, out) {
					return false
				}
			}
			return match_type_pattern(k, v.args[0].value, info.element, scope, out)
		}
		// `Range($T)` is the same shape: one part, taken from the type itself.
		if range_callee(k, v.callee) {
			if !info.is_range || len(v.args) != 1 {
				return false
			}
			return match_type_pattern(k, v.args[0].value, info.element, scope, out)
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
		index := 0
		for parameter in v.params {
			for _ in 0 ..< max(len(parameter.names), 1) {
				if index >= len(info.parameters) ||
				   !match_type_pattern(k, parameter.type, info.parameters[index], scope, out) {
					return false
				}
				index += 1
			}
		}
		if index != len(info.parameters) || (v.result == nil) != (info.result == INVALID_TYPE) {
			return false
		}
		return v.result == nil || match_type_pattern(k, v.result.type, info.result, scope, out)
	}
	return false
}

// Written arguments of `Name(...)` against an instance's bound ones: a `$` name
// binds, and a written argument is left to ranking.
@(private = "file")
match_generic_args :: proc(
	k: ^Checker, args: []Argument, bound: []Generic_Arg, scope: ^Scope, out: ^[dynamic]Generic_Binding,
) -> bool {
	for arg, index in args {
		if poly, is_poly := arg.value.(^Type_Poly); is_poly {
			if !bind_pattern_name(k, poly.name, bound[index], scope, out) {
				return false
			}
		} else if type_syntax_has_poly(arg.value) {
			if !bound[index].is_type || !match_type_pattern(k, arg.value, bound[index].type, scope, out) {
				return false
			}
		}
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
		if existing.arg.is_type != arg.is_type {
			return false
		}
		if arg.is_type {
			return existing.arg.type == arg.type
		}
		equal, comparable := const_equal(k.c, existing.arg.value, arg.value)
		return comparable && equal
	}
	binding := Generic_Binding{name = id, span = name.span, arg = arg}
	append(out, binding)
	bind_generic_name(k, scope, binding)
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
	ok:           bool,
}

// Walks a template's written signature left to right, binding every `$` name
// as it goes, so a later parameter type may name an earlier binding. `$`
// parameters are compile-time inputs and do not survive into the instance's
// runtime signature.
infer_generic_arguments :: proc(k: ^Checker, template: ^Generic_Template, args: []Arg_Info) -> Inference {
	result := Inference{}
	literal := decl_proc_literal(template.decl)
	if literal == nil || literal.signature == nil {
		result.reason = "this name is not a procedure"
		return result
	}

	scope := new_instance_scope(k, template)
	bindings := make([dynamic]Generic_Binding, 0, 4, k.c.semantic_allocator)
	runtime := make([dynamic]Arg_Info, 0, len(args), k.c.semantic_allocator)
	result.scope = scope

	saved := enter_instance(k, template, scope)
	defer restore_checker_location(k, saved)

	// Checked on the written call, before `$` arguments leave the signature.
	named := false
	for arg in args {
		if arg.name != INVALID_IDENTIFIER {
			named = true
		} else if named {
			result.reason = "a positional argument cannot follow a named one"
			return result
		}
	}

	claimed := make([]bool, len(args), k.c.semantic_allocator)
	compile_time := make([]bool, len(args), k.c.semantic_allocator)
	compile_targets := make([]Type_Id, len(args), k.c.semantic_allocator)
	next := 0
	position := 0
	for parameter in literal.signature.params {
		if parameter.mode == .Variadic {
			// A pattern in the element type binds from the first of the remaining
			// arguments; the rest are ranked, not matched.
			if index, found := claim_argument(args, INVALID_IDENTIFIER, &next, claimed); found {
				matched := args[index].type
				// A spread supplies the pack slice, while the written variadic type is
				// its element. Infer `$T` in `..$T` from `..values`, not from the
				// whole `[]T` carrier.
				if args[index].mode == .Spread {
					matched = slice_element(k.c, matched)
				}
				if matched == INVALID_TYPE ||
				   !match_type_pattern(k, parameter.type, matched, scope, &bindings) {
					result.reason = fmt.aprintf(
						"`%s` does not match the variadic parameter's element shape",
						type_name(k.c, args[index].type),
						allocator = k.c.semantic_allocator,
					)
					return result
				}
			}
			for {
				if _, found := claim_argument(args, INVALID_IDENTIFIER, &next, claimed); !found {
					break
				}
			}
			continue
		}
		for entry in parameter.names {
			position += 1
			index, found := claim_argument(args, entry.name.id, &next, claimed)
			if !found {
				if parameter.default == nil {
					result.reason = "it needs more arguments than were supplied"
					return result
				}
				// An omitted `$` default is bound, since it selects the instance.
				if !entry.is_poly {
					continue
				}
				result.compile_omitted += 1
				wanted := resolve_type_syntax(k, parameter.type)
				bound, bound_ok := bind_default_compile_time_argument(
					k, entry.name, parameter.default, wanted, scope, &bindings,
				)
				if !bound_ok {
					result.reason = bound
					return result
				}
				continue
			}
			arg := args[index]
			if !entry.is_poly {
				// An ordinary runtime parameter, whose written type may still be a
				// pattern binding parts of the argument's type.
				if !match_type_pattern(k, parameter.type, arg.type, scope, &bindings) &&
				   !match_dynamic_as_view(k, parameter.type, arg.type, scope, &bindings) {
					result.reason = fmt.aprintf(
						"`%s` does not match the shape of parameter %d",
						type_name(k.c, arg.type),
						position,
						allocator = k.c.semantic_allocator,
					)
					return result
				}
				continue
			}
			compile_time[index] = true

			// A `$` parameter is a compile-time input. Its declared type may itself
			// be `$I`, which binds the argument's own type.
			if poly, is_poly := parameter.type.(^Type_Poly); is_poly {
				value_type := default_type(k.c, arg.type)
				if !bind_pattern_name(k, poly.name, Generic_Arg{is_type = true, type = value_type}, scope, &bindings) {
					result.reason = "its generic parameter types do not agree"
					return result
				}
			}
			wanted := resolve_type_syntax(k, parameter.type)
			bound, bound_ok := bind_compile_time_argument(k, entry.name, arg, wanted, scope, &bindings)
			if !bound_ok {
				result.reason = bound
				return result
			}
			compile_targets[index] = wanted != INVALID_TYPE ? wanted : default_type(k.c, arg.type)
		}
	}
	// An argument no parameter claimed, named or positional, is the extra one.
	for _, index in args {
		if !claimed[index] {
			result.reason = fmt.aprintf(
				"it takes %d argument%s, found %d",
				position,
				position == 1 ? "" : "s",
				len(args),
				allocator = k.c.semantic_allocator,
			)
			return result
		}
	}
	// Runtime arguments keep their written order for `build_candidate`.
	for arg, index in args {
		if !compile_time[index] {
			append(&runtime, arg)
		}
	}

	result.bindings = bindings[:]
	result.runtime_args = runtime[:]
	result.compile_time = compile_time
	result.compile_targets = compile_targets
	result.ok = true
	return result
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
			// A named argument belongs to the parameter it names, so it never fills a
			// positional slot; the parameter it names claims it above.
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
// same words.
@(private = "file")
bind_default_compile_time_argument :: proc(
	k: ^Checker,
	name: Name,
	default: Expr,
	wanted: Type_Id,
	scope: ^Scope,
	out: ^[dynamic]Generic_Binding,
) -> (string, bool) {
	// Evaluated as a written argument is, so a default may call a procedure. The
	// declaration's syntax is shared by every call and checking annotates it, so
	// each call checks its own copy: `twice(size_of(T))` resolves per `T`. A
	// failed default makes the candidate inapplicable, which the call reports, and
	// its own diagnostics are rolled back; so the check is a speculation and must
	// claim no report-once cache and hoist no literal.
	per_call := clone_expr(k.c, default)
	mark := len(k.c.diagnostics)
	k.c.speculation_depth += 1
	type := check_expr(k, per_call, wanted)
	folded, evaluated := Const_Value{}, false
	if type != INVALID_TYPE && wanted != TYPE_TYPE {
		folded, evaluated = require_const(k, per_call, "a `$` parameter's default", "L0432")
	}
	k.c.speculation_depth -= 1
	truncate_diagnostics(k.c, mark)
	if type == INVALID_TYPE {
		return "its omitted `$` argument's default does not check", false
	}
	arg := Arg_Info {
		expr        = per_call,
		span        = expr_span(per_call),
		name        = INVALID_IDENTIFIER,
		type        = type,
		is_const    = evaluated,
		const_value = folded,
	}
	return bind_compile_time_argument(k, name, arg, wanted, scope, out)
}

// A `$N: int` or `$T: type` argument. `type` receives a type; everything else
// receives a compile-time constant.
@(private = "file")
bind_compile_time_argument :: proc(
	k: ^Checker,
	name: Name,
	arg: Arg_Info,
	wanted: Type_Id,
	scope: ^Scope,
	out: ^[dynamic]Generic_Binding,
) -> (string, bool) {
	if wanted == TYPE_TYPE {
		denoted := INVALID_TYPE
		if base := expr_base(arg.expr); base != nil {
			denoted = base.denoted_type
		}
		if denoted == INVALID_TYPE {
			denoted = resolve_type_syntax(k, arg.expr)
		}
		if denoted == INVALID_TYPE {
			return "a `$` parameter of type `type` needs a type argument", false
		}
		// design.md "Maps": settled where the map type is named, as for an
		// interface argument, since the body may reach its members without ever
		// declaring a value of it.
		if !require_nested_map_key_policies(k, denoted, arg.span) {
			return "its type argument names a map with an invalid key", false
		}
		if !bind_pattern_name(k, name, Generic_Arg{is_type = true, type = denoted}, scope, out) {
			return "its generic arguments do not agree", false
		}
		return "", true
	}
	if !arg.is_const {
		return "a `$` parameter needs a compile-time constant argument", false
	}
	value := arg.const_value
	value_type := default_type(k.c, arg.type)
	if wanted != INVALID_TYPE {
		converted, problem := convert_generic_value(k, value, arg.type, wanted)
		if problem != "" {
			return problem, false
		}
		value, value_type = converted, wanted
	}
	arg_value := Generic_Arg{value = value, value_type = value_type}
	if !bind_pattern_name(k, name, arg_value, scope, out) {
		return "its generic arguments do not agree", false
	}
	return "", true
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
	key := instance_key(k.c, template.symbol, bindings)
	if existing, found := k.c.instances[key]; found {
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
			k.c.instantiation_limit_hit = true
			errorf(
				k.c,
				span,
				"L0436",
				"instantiating `%s` exceeds the compiler's generic instantiation limit (%d deep, %d instances)",
				generic_instance_name(k.c, template.symbol, bindings),
				MAX_INSTANTIATION_DEPTH,
				MAX_INSTANTIATIONS,
			)
			note_instantiation_stack(k)
		}
		return nil, false
	}

	instance := new(Instance, k.c.semantic_allocator)
	instance.template = template.symbol
	instance.bindings = bindings
	instance.scope = scope
	instance.provisional = true
	instance.span = span
	k.c.instances[key] = instance
	// Reserved before resolution, which may instantiate recursively. A rejected
	// entry stays cached, so repeated probes cost no further slots.
	k.c.instantiation_count += 1

	name := generic_instance_name(k.c, template.symbol, bindings)
	instance.mangled = generic_mangled_name(k.c, template.symbol, bindings)
	append(&k.c.instantiation_stack, Instantiation_Frame{description = name, span = span})
	defer {
		pop(&k.c.instantiation_stack)
		instance.provisional = false
	}

	mark := len(k.c.diagnostics)
	switch template.kind {
	case .Record:
		instance.signature_ok = instantiate_record_body(k, template, instance, name, report)
	case .Procedure:
		instance.signature_ok = instantiate_procedure_signature(k, template, instance, name, report)
	case .None:
	}
	// A silent probe must not fail the compilation over a signature that does not
	// resolve; keep the head diagnostic for a later request that reports.
	if !report && !instance.signature_ok && len(k.c.diagnostics) > mark {
		head := k.c.diagnostics[mark]
		instance.rejection = Instance_Rejection {
			code    = head.code,
			message = strings.clone(head.message, k.c.semantic_allocator),
			span    = head.span,
		}
		truncate_diagnostics(k.c, mark)
	}
	return instance, instance.signature_ok
}

@(private = "file")
report_rejected_instance :: proc(k: ^Checker, template: ^Generic_Template, instance: ^Instance, span: Span) {
	if instance == nil {
		return
	}
	name := generic_instance_name(k.c, template.symbol, instance.bindings)
	saved := enter_instance(k, template, instance.scope)
	defer restore_checker_location(k, saved)

	append(&k.c.instantiation_stack, Instantiation_Frame{description = name, span = span})
	defer pop(&k.c.instantiation_stack)
	// A contained rejection: the caret on this request, a note at the original.
	if instance.rejection.code != "" {
		errorf(k.c, span, instance.rejection.code, "%s", instance.rejection.message)
		add_notef(k.c, instance.rejection.span, "in the signature of `%s`", name)
		note_instantiation_stack(k)
		return
	}
	if instance.decl == nil {
		return
	}
	#partial switch template.kind {
	case .Record:
		if record, ok := instance.decl.values[0].(^Type_Record); ok {
			check_where_clauses(k, record.where_clauses, span, name, report = true)
		}
	case .Procedure:
		if literal := decl_proc_literal(instance.decl); literal != nil {
			check_where_clauses(k, literal.where_clauses, span, name, report = true)
		}
	case .None:
	}
}

@(private = "file")
report_instantiation_cycle :: proc(k: ^Checker, span: Span, template: ^Generic_Template, bindings: []Generic_Binding) {
	errorf(
		k.c,
		span,
		"L0436",
		"`%s` is being instantiated in terms of itself",
		generic_instance_name(k.c, template.symbol, bindings),
	)
	note_instantiation_stack(k)
}

// The innermost frames name a recursion; the rest are counted.
NOTED_INSTANTIATION_FRAMES :: 4

note_instantiation_stack :: proc(k: ^Checker) {
	// Every unwinding level sees the same diagnostic; note the stack once.
	if len(k.c.diagnostics) == 0 || k.c.last_noted_diagnostic == len(k.c.diagnostics) {
		return
	}
	k.c.last_noted_diagnostic = len(k.c.diagnostics)
	shown := 0
	#reverse for frame in k.c.instantiation_stack {
		if shown >= NOTED_INSTANTIATION_FRAMES {
			add_notef(
				k.c,
				no_span(),
				"and %d more instantiation%s",
				len(k.c.instantiation_stack) - shown,
				len(k.c.instantiation_stack) - shown == 1 ? "" : "s",
			)
			return
		}
		add_notef(k.c, frame.span, "while instantiating `%s`", frame.description)
		shown += 1
	}
}

// Positions the checker at an instance's definition: its scope, package, and
// file. Restored with `restore_checker_location`.
@(private = "file")
enter_generic_location :: proc(
	k: ^Checker, scope: ^Scope, pkg, lookup_pkg: Package_Id, impl_type: Type_Id, file: u32, file_node: ^File,
) -> Checker_Location {
	saved := save_checker_location(k)
	k.scope = scope
	k.pkg, k.lookup_pkg = pkg, lookup_pkg
	k.impl_type = impl_type
	k.proc_literal = nil
	k.generic_depth += 1
	if file_node != nil {
		k.file, k.file_node = file, file_node
	}
	return saved
}

@(private = "file")
enter_instance :: proc(k: ^Checker, template: ^Generic_Template, scope: ^Scope) -> Checker_Location {
	return enter_generic_location(
		k, scope, template.pkg, template.lookup_pkg, template.impl_type, template.file, template.file_node,
	)
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
		info.mangled = generic_mangled_name(k.c, template.symbol, instance.bindings)
	}
	instance.symbol = symbol_id
	instance.type = type
	saved := enter_instance(k, template, instance.scope)
	defer restore_checker_location(k, saved)

	// Bounds first: `where N > 0` is what makes `[N]int` well formed.
	if !check_where_clauses(k, record.where_clauses, instance.span, name, report) {
		return false
	}
	before := len(k.c.diagnostics)
	if record.kind == .Struct {
		resolve_struct_fields(k, type, record)
	} else {
		resolve_union_variants(k, type, record)
	}
	apply_type_metadata(k, clone, type)
	if report && len(k.c.diagnostics) > before {
		note_instantiation_stack(k)
	}

	path := make([dynamic]Type_Id, 0, 8, context.temp_allocator)
	check_finite_size(k, type, template.decl.span, &path)

	// Settled, so a method naming its own instantiation is a cache hit.
	instance.provisional = false
	instance.signature_ok = true
	append(&template.instances, instance)
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
	if template_rejected(k, template) {
		return INVALID_TYPE
	}
	if !generic_arguments_positional(k, v.args, "L0431", report) {
		return INVALID_TYPE
	}
	if len(v.args) != len(template.params) {
		if report {
			report_generic_arity(k, v.span, template, len(v.args))
		}
		return INVALID_TYPE
	}

	scope := new_instance_scope(k, template)
	bindings := make([dynamic]Generic_Binding, 0, len(template.params), k.c.semantic_allocator)
	saved_scope := k.scope
	ok := true
	for parameter, index in template.params {
		arg := v.args[index]
		k.scope = scope
		wanted := resolve_type_syntax(k, parameter.type_syntax)
		k.scope = saved_scope
		bound, bound_ok := bind_record_argument(k, parameter, arg, wanted, scope, &bindings, report)
		if !bound_ok {
			if report && bound != "" {
				errorf(k.c, arg.span, "L0432", "%s", bound)
			}
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
	v.resolution = Resolution{kind = .Generic_Application, symbol = instance.symbol}
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

@(private = "file")
report_generic_arity :: proc(k: ^Checker, span: Span, template: ^Generic_Template, found: int) {
	errorf(
		k.c, span, "L0431", "`%s` takes %d generic argument%s, found %d",
		identifier_text(k.c, symbol_of(k.c, template.symbol).name),
		len(template.params), len(template.params) == 1 ? "" : "s", found,
	)
}

// `Option(int)` from type ids, for compiler-built uses of source-declared
// templates.
instantiate_record_types :: proc(k: ^Checker, symbol: Symbol_Id, args: []Type_Id, span: Span) -> Type_Id {
	template := generic_template_for(k, symbol)
	if template == nil || len(template.params) != len(args) {
		return INVALID_TYPE
	}
	scope := new_instance_scope(k, template)
	bindings := make([dynamic]Generic_Binding, 0, len(args), k.c.semantic_allocator)
	for parameter, index in template.params {
		name := Name{text = identifier_text(k.c, parameter.name), span = span, id = parameter.name}
		if !bind_pattern_name(k, name, Generic_Arg{is_type = true, type = args[index]}, scope, &bindings) {
			return INVALID_TYPE
		}
	}
	instance, made := instantiate_generic(k, template, bindings[:], scope, span, report = true)
	if !made {
		return INVALID_TYPE
	}
	return instance.type
}

@(private = "file")
bind_record_argument :: proc(
	k: ^Checker,
	parameter: Generic_Param_Decl,
	arg: Argument,
	wanted: Type_Id,
	scope: ^Scope,
	out: ^[dynamic]Generic_Binding,
	report: bool,
) -> (string, bool) {
	name := Name{text = identifier_text(k.c, parameter.name), span = arg.span, id = parameter.name}
	if wanted == TYPE_TYPE || wanted == INVALID_TYPE {
		denoted := resolve_type_syntax(k, arg.value)
		if denoted == INVALID_TYPE {
			return "a generic `type` parameter needs a type argument", false
		}
		if !bind_pattern_name(k, name, Generic_Arg{is_type = true, type = denoted}, scope, out) {
			return "this generic argument disagrees with an earlier one", false
		}
		return "", true
	}
	if check_single_expr(k, arg.value, wanted) == INVALID_TYPE {
		return "", false // already reported
	}
	folded, evaluated := require_const(k, arg.value, "a generic argument", "L0432")
	if !evaluated {
		return "", false
	}
	converted, problem := convert_generic_value(k, folded, expr_base(arg.value).type, wanted)
	if problem != "" {
		return problem, false
	}
	if !bind_pattern_name(k, name, Generic_Arg{value = converted, value_type = wanted}, scope, out) {
		return "this generic argument disagrees with an earlier one", false
	}
	return "", true
}

// A constant generic argument converted to its parameter's type, or why not.
@(private = "file")
convert_generic_value :: proc(k: ^Checker, value: Const_Value, value_type, wanted: Type_Id) -> (Const_Value, string) {
	if type_is_enum(k.c, wanted) && !assignable(k.c, value_type, wanted) {
		return {}, "an enum generic argument must be a variant of the parameter's enum type"
	}
	converted, fits := convert_const(k.c, value, wanted, false)
	if !fits {
		return {}, fmt.aprintf(
			"`%s` is not representable by the generic parameter's type `%s`",
			const_key_text(k.c, value), type_name(k.c, wanted), allocator = k.c.semantic_allocator,
		)
	}
	return converted, ""
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
	if literal == nil {
		return false
	}
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
	defer restore_checker_location(k, saved)

	before := k.c.error_count
	clone.sig_state = .Checked
	resolve_proc_signature(k, literal, symbol_id)
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
	if k.c.speculation_depth > 0 || instance == nil || instance.body_checked || !instance.signature_ok {
		return
	}
	instance.body_checked = true
	template, found := k.c.generic_templates[instance.template]
	if !found || template.kind != .Procedure {
		return
	}
	literal := decl_proc_literal(instance.decl)
	if literal == nil || literal.body == nil {
		return
	}

	saved := enter_instance(k, template, instance.scope)
	defer restore_checker_location(k, saved)

	// Diagnosed against the selecting call; a probe-created instance has none.
	append(&k.c.instantiation_stack, Instantiation_Frame {
		description = identifier_text(k.c, symbol_of(k.c, instance.symbol).name),
		span        = span.file == NO_FILE ? instance.span : span,
	})
	defer pop(&k.c.instantiation_stack)

	before := len(k.c.diagnostics)
	if !instance.bounds_committed {
		// Known to hold; checked again only for what it reports, such as a
		// deprecated call, which the probe rolled back.
		instance.bounds_committed = true
		_ = check_where_clauses(k, literal.where_clauses, instance.span, identifier_text(k.c, symbol_of(k.c, instance.symbol).name), true)
	}
	instance.decl.check_state = .Checked
	// An inferred `$T` can be a compile-time-only type the template never wrote,
	// such as `type` from `f(int)`, so the instance's runtime shape is gated.
	proc_type := symbol_of(k.c, instance.symbol).proc_type
	if offender := compile_time_only_component(k.c, proc_type); offender != INVALID_TYPE {
		report_compile_time_only(k, offender, literal.span)
	} else if gate_type(k, proc_type, literal.span) {
		check_proc_body(k, literal)
	}
	if len(k.c.diagnostics) > before {
		note_instantiation_stack(k)
	}

	if pkg := package_of(k.c, template.pkg); pkg != nil {
		append(&pkg.instances, Instance_Decl {
			symbol = instance.symbol,
			decl   = instance.decl,
			name   = instance.mangled,
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
	for clause in clauses {
		mark := len(k.c.diagnostics)
		errors := k.c.error_count
		if !report {
			k.c.speculation_depth += 1
		}
		type := check_single_expr(k, clause, TYPE_BOOL)
		folded, evaluated := require_const(k, clause, "a `where` bound", "L0435")
		if !report {
			k.c.speculation_depth -= 1
		}
		failed := type == INVALID_TYPE || !evaluated || folded.kind != .Boolean
		if !failed && folded.boolean {
			// A reporting check is committed, so what a passing bound reported stays.
			if !report {
				truncate_diagnostics(k.c, mark)
			}
			continue
		}
		if !report && !(failed && report_malformed) {
			truncate_diagnostics(k.c, mark)
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
			note_instantiation_stack(k)
			return false
		}
		// An interface bound names the failed requirement; a predicate, itself.
		if report_failed_interface_bound(k, clause, span) {
			note_instantiation_stack(k)
			return false
		}
		errorf(k.c, span, "L0434", "`%s` does not satisfy the bound `%s`", what, where_bound_text(k.c, clause))
		add_notef(k.c, expr_span(clause), "the bound is written here")
		note_instantiation_stack(k)
		return false
	}
	return true
}

// Why a silent probe's `where` bounds rejected `instance`, for an overload note.
// Read in the instance's scope, as the bound was, and leaves no diagnostic.
failed_bound_reason :: proc(k: ^Checker, template: ^Generic_Template, instance: ^Instance) -> string {
	saved := enter_instance(k, template, instance.scope)
	defer restore_checker_location(k, saved)
	mark := len(k.c.diagnostics)
	k.c.speculation_depth += 1
	text := failed_bound_text(k, instance.failed_bound)
	k.c.speculation_depth -= 1
	truncate_diagnostics(k.c, mark)
	return text
}

where_bound_text :: proc(c: ^Compiler, clause: Expr) -> string {
	span := expr_span(clause)
	if span.file == NO_FILE || int(span.file) >= len(c.sources) {
		return "where"
	}
	src := &c.sources[span.file]
	lo, hi := int(span.lo), min(int(span.hi), len(src.text))
	if lo < 0 || lo >= hi {
		return "where"
	}
	return src.text[lo:hi]
}

// ------------------------------------------------- generic `impl` blocks --

// `impl Table($K, $V)` or `impl Table(string, int)`, kept until an instance
// exists to install it on.
register_generic_impl :: proc(k: ^Checker, item: ^Item_Impl, template: Symbol_Id, args: []Argument) -> bool {
	blocks, found := &k.c.generic_impls[template]
	if !found {
		k.c.generic_impls[template] = make([dynamic]^Generic_Impl, 0, 2, k.c.semantic_allocator)
		blocks = &k.c.generic_impls[template]
	}
	for existing in blocks {
		if existing.item == item {
			return true // an earlier discovery round already registered it
		}
	}
	// Inherent in the template's own package, an extension elsewhere.
	owner := symbol_of(k.c, template)
	item.kind = owner != nil && owner.pkg == k.pkg ? .Impl : .Extend

	written := make([]Expr, len(args), k.c.semantic_allocator)
	specificity := 0
	for arg, index in args {
		written[index] = arg.value
		specificity += pattern_specificity(arg.value)
	}
	block := new(Generic_Impl, k.c.semantic_allocator)
	block.item = item
	block.template = template
	block.pkg = k.pkg
	block.scope = package_of(k.c, k.pkg).scope
	block.file, block.file_node = k.file, k.file_node
	block.args = written
	block.specificity = specificity
	register_generic_extension_groups(k, block)
	append(blocks, block)
	item.declared = true
	// A late block still applies to instances that already exist.
	if existing := k.c.generic_templates[template]; existing != nil {
		for instance in existing.instances {
			install_one_generic_impl(k, existing, instance, block)
		}
	}
	return true
}

// A generic `impl` subject with the wrong argument count, or a written argument
// that does not resolve, would silently match no instance.
check_generic_impl_subject :: proc(k: ^Checker, item: ^Item_Impl) {
	call, is_call := item.type.(^Expr_Call)
	if !is_call {
		return
	}
	template := generic_template_of_callee(k, call.callee, .Record)
	if template == nil {
		return
	}
	if !generic_arguments_positional(k, call.args, "L0431", true) {
		return
	}
	if len(call.args) != len(template.params) {
		report_generic_arity(k, expr_span(item.type), template, len(call.args))
		return
	}
	for arg, index in call.args {
		if type_syntax_has_poly(arg.value) {
			continue
		}
		parameter := template.params[index]
		// The template reports its own parameter types; this only reads one.
		mark, errors := len(k.c.diagnostics), k.c.error_count
		k.c.speculation_depth += 1
		wanted := resolve_type_syntax(k, parameter.type_syntax)
		k.c.speculation_depth -= 1
		truncate_diagnostics(k.c, mark)
		if wanted == TYPE_TYPE || wanted == INVALID_TYPE {
			if resolve_type_syntax(k, arg.value) == INVALID_TYPE && k.c.error_count == errors {
				report_unresolved_type(k, arg.value)
			}
		} else if check_single_expr(k, arg.value, wanted) != INVALID_TYPE {
			require_const(k, arg.value, "a generic argument", "L0432")
		}
	}
}

// A public procedure on a generic extension gets its package name as an empty
// group before any instance exists; instances fill it.
@(private = "file")
register_generic_extension_groups :: proc(k: ^Checker, block: ^Generic_Impl) {
	if block.item.kind != .Extend {
		return
	}
	pkg := package_of(k.c, block.pkg)
	if pkg == nil || pkg.scope == nil {
		return
	}
	for member in block.item.members {
		d, is_decl := member.(^Decl)
		if !is_decl || d.kind != .Const || decl_proc_literal(d) == nil || !declaration_is_public(k, d) {
			continue
		}
		for name in d.names {
			if name.text == "_" {
				continue
			}
			name_id := name_identifier(k.c, name)
			// Never displaces a name the package already owns.
			if _, taken := pkg.scope.names[name_id]; taken {
				continue
			}
			pkg.scope.names[name_id] = new_symbol(k.c, Symbol {
				name          = name_id,
				span          = name.span,
				kind          = .Proc_Group,
				pkg           = block.pkg,
				lookup_pkg    = block.pkg,
				def_scope     = block.scope,
				def_file      = block.file,
				def_file_node = block.file_node,
				public        = true,
				instance_of   = block.template,
			})
		}
	}
}

// Installs every matching block on a fresh instance, most specialized first, so
// a specialized member wins (tie-breaker 5).
@(private = "file")
install_generic_impls :: proc(k: ^Checker, template: ^Generic_Template, instance: ^Instance) {
	blocks, found := k.c.generic_impls[template.symbol]
	if !found || len(blocks) == 0 {
		return
	}
	ordered := make([dynamic]^Generic_Impl, 0, len(blocks), context.temp_allocator)
	for block in blocks {
		append(&ordered, block)
	}
	for i in 1 ..< len(ordered) {
		entry := ordered[i]
		j := i - 1
		for j >= 0 && ordered[j].specificity < entry.specificity {
			ordered[j + 1] = ordered[j]
			j -= 1
		}
		ordered[j + 1] = entry
	}
	for block in ordered {
		install_one_generic_impl(k, template, instance, block)
	}
}

install_one_generic_impl :: proc(k: ^Checker, template: ^Generic_Template, instance: ^Instance, block: ^Generic_Impl) {
	if len(block.args) != len(instance.bindings) {
		return
	}
	scope := new_scope(k.c, block.scope, .Local)
	saved := enter_generic_location(k, scope, block.pkg, block.pkg, INVALID_TYPE, block.file, block.file_node)
	defer restore_checker_location(k, saved)

	// A written argument that differs from the bound one skips this instance;
	// `check_generic_impl_subject` reports one that could never match, so each
	// comparison here is a speculation whose diagnostics are rolled back.
	for written, index in block.args {
		bound := instance.bindings[index].arg
		if poly, is_poly := written.(^Type_Poly); is_poly {
			bind_generic_name(k, scope, Generic_Binding{name = name_identifier(k.c, poly.name), span = poly.name.span, arg = bound})
			continue
		}
		if bound.is_type {
			mark := len(k.c.diagnostics)
			k.c.speculation_depth += 1
			resolved := resolve_type_syntax(k, written)
			k.c.speculation_depth -= 1
			truncate_diagnostics(k.c, mark)
			if resolved != bound.type {
				return
			}
			continue
		}
		mark := len(k.c.diagnostics)
		folded, evaluated := Const_Value{}, false
		k.c.speculation_depth += 1
		if check_single_expr(k, written, bound.value_type) != INVALID_TYPE {
			folded, evaluated = require_const(k, written, "a generic argument", "L0432")
		}
		k.c.speculation_depth -= 1
		truncate_diagnostics(k.c, mark)
		if !evaluated {
			return
		}
		equal, comparable := const_equal(k.c, folded, bound.value)
		if !comparable || !equal {
			return
		}
	}

	clone := clone_item(k.c, block.item).(^Item_Impl)
	clone.subject = instance.type
	clone.declared = true
	k.impl_type = instance.type
	declare_instance_impl_members(k, clone, instance.type, block)
	// Resolved here, in the block's own scope.
	for member in clone.members {
		if d, is_decl := member.(^Decl); is_decl {
			resolve_declaration_signature(k, d)
			exclude_member_on_failed_bound(k, d)
		}
	}
	for member in clone.members {
		if delegate, is_delegate := member.(^Item_Delegate); is_delegate {
			check_delegate(k, delegate, instance.type)
		}
	}
	append(&k.c.pending_impl_instances, Pending_Impl{item = clone, scope = scope, pkg = block.pkg, file = block.file, file_node = block.file_node, subject = instance.type})
}

// design.md "where clauses": a method whose bound fails is dropped from that
// instance, as `Small_Array` drops copying methods for a move-only `T`.
// Evaluated beside the signature, since calls resolve before bodies.
@(private = "file")
exclude_member_on_failed_bound :: proc(k: ^Checker, d: ^Decl) {
	literal := decl_proc_literal(d)
	if literal == nil || len(literal.where_clauses) == 0 {
		return
	}
	if len(d.symbols) == 0 || d.symbols[0] == INVALID_SYMBOL {
		return
	}
	symbol := symbol_of(k.c, d.symbols[0])
	if symbol == nil {
		return
	}
	name := identifier_text(k.c, symbol.name)
	// A malformed bound is reported and keeps the member, rather than removing it
	// over a typo.
	errors := k.c.error_count
	ok := check_where_clauses(
		k, literal.where_clauses, literal.span, name, report = false, report_malformed = true,
	)
	if !ok && k.c.error_count == errors {
		symbol.bound_excluded = true
	}
}

// Members of an instantiated block. Names a specialized block already supplied
// are left alone rather than reported as duplicates.
@(private = "file")
declare_instance_impl_members :: proc(k: ^Checker, item: ^Item_Impl, subject: Type_Id, block: ^Generic_Impl) {
	added := make([dynamic]Symbol_Id, 0, len(item.members), k.c.semantic_allocator)
	for member in item.members {
		d, is_decl := member.(^Decl)
		if !is_decl || d.kind != .Const {
			continue
		}
		symbols := make([dynamic]Symbol_Id, 0, len(d.names), k.c.semantic_allocator)
		d.top_level = true
		for name in d.names {
			if name.text == "_" {
				append(&symbols, INVALID_SYMBOL)
				continue
			}
			name_id := name_identifier(k.c, name)
			if member_named(k.c, impl_member_table(k, item.kind, subject, block.pkg), name_id) !=
			   INVALID_SYMBOL {
				append(&symbols, INVALID_SYMBOL) // a more specialized block supplied it
				continue
			}
			if member_named(k.c, added[:], name_id) != INVALID_SYMBOL {
				errorf(
					k.c, name.span, "L0409",
					"`%s` already has a member `%s`", type_name(k.c, subject), name.text,
				)
				append(&symbols, INVALID_SYMBOL)
				continue
			}
			if subject_field_named(k, subject, name_id) != INVALID_SYMBOL {
				errorf(
					k.c, name.span, "L0409",
					"`%s` already has a field `%s`", type_name(k.c, subject), name.text,
				)
				append(&symbols, INVALID_SYMBOL)
				continue
			}
			id := new_symbol(k.c, Symbol {
				name       = name_id,
				span       = name.span,
				decl       = d,
				pkg        = block.pkg,
				lookup_pkg = block.pkg,
				owner_type = subject,
				public     = declaration_is_public(k, d),
				kind       = decl_proc_literal(d) != nil ? Symbol_Kind.Proc : Symbol_Kind.Const,
				def_scope  = k.scope,
				def_file   = k.file,
				def_file_node = k.file_node,
			})
			public := false
			if sym := symbol_of(k.c, id); sym != nil {
				public = sym.public
				if sym.kind == .Proc {
					sym.type = TYPE_VOID
				}
			}
			// As for an ordinary extension block, a public extension procedure also
			// gets its plain package-qualified spelling.
			if item.kind == .Extend && public {
				register_instance_extension_name(k, block, name_id, id, name.span)
			}
			append(&symbols, id)
			append(&added, id)
		}
		d.symbols = symbols[:]
	}
	install_impl_members(k, item.kind, subject, added[:], block.pkg)
}

// The package-qualified name of a public instantiated `extend` member. Each
// instance adds its procedure to one group; a name the package already uses for
// something else keeps its meaning.
@(private = "file")
register_instance_extension_name :: proc(
	k: ^Checker, block: ^Generic_Impl, name: Identifier_Id, member: Symbol_Id, span: Span,
) {
	pkg := package_of(k.c, block.pkg)
	if pkg == nil || pkg.scope == nil {
		return
	}
	existing, taken := pkg.scope.names[name]
	if !taken {
		pkg.scope.names[name] = member
		return
	}
	sym := symbol_of(k.c, existing)
	if sym == nil {
		return
	}
	if sym.kind == .Proc_Group && sym.instance_of == block.template {
		for existing_member in sym.members {
			if existing_member == member {
				return
			}
		}
		members := make([]Symbol_Id, len(sym.members) + 1, k.c.semantic_allocator)
		copy(members, sym.members)
		members[len(sym.members)] = member
		sym.members = members
		return
	}
	// The first instance's member: the two become a group. `new_symbol` may move
	// the store, so `sym` is not read after it.
	if sym.kind != .Proc || instance_template_of(k.c, sym.owner_type) != block.template {
		return
	}
	members := make([]Symbol_Id, 2, k.c.semantic_allocator)
	members[0], members[1] = existing, member
	pkg.scope.names[name] = new_symbol(k.c, Symbol {
		name        = name,
		span        = span,
		kind        = .Proc_Group,
		pkg         = block.pkg,
		lookup_pkg  = block.pkg,
		public      = true,
		instance_of = block.template,
		members     = members,
	})
}

// The template an instance type came from, or INVALID_SYMBOL for anything else.
@(private = "file")
instance_template_of :: proc(c: ^Compiler, type: Type_Id) -> Symbol_Id {
	info := type_of(c, type)
	return info == nil ? INVALID_SYMBOL : info.instance_of
}

// The block instances discovered so far are checked after the package that
// requested them, so a method's body sees every instantiation its own signature
// created.
check_pending_impl_instances :: proc(k: ^Checker) {
	for index := 0; index < len(k.c.pending_impl_instances); index += 1 {
		pending := k.c.pending_impl_instances[index]
		if pending.checked {
			continue
		}
		k.c.pending_impl_instances[index].checked = true

		saved := enter_generic_location(
			k, pending.scope, pending.pkg, pending.pkg, pending.subject, pending.file, pending.file_node,
		)

		for member in pending.item.members {
			if d, is_decl := member.(^Decl); is_decl {
				check_decl(k, d)
			}
		}
		if pkg := package_of(k.c, pending.pkg); pkg != nil {
			for member in pending.item.members {
				d, is_decl := member.(^Decl)
				if !is_decl || len(d.symbols) == 0 || d.symbols[0] == INVALID_SYMBOL {
					continue
				}
				if decl_proc_literal(d) == nil {
					continue
				}
				sym := symbol_of(k.c, d.symbols[0])
				// A method whose bound did not hold is not part of this instantiation:
				// its body was never checked, so there is no body to emit.
				if sym != nil && sym.bound_excluded {
					continue
				}
				append(&pkg.instances, Instance_Decl {
					symbol = d.symbols[0],
					decl   = d,
					name   = qualified_member_name(k.c, sym, k.c.semantic_allocator),
				})
			}
		}

		restore_checker_location(k, saved)
	}
}
