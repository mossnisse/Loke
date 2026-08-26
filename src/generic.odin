// Generics: templates, inference, specialization, `where`, and the
// monomorphization cache.
//
// Decision A2 is monomorphization: every distinct argument vector produces its
// own instance, its own symbol, and its own emitted body. Because type
// annotations live on the AST nodes (decision A1), an instance also needs its
// own syntax, which is what `ast_clone.odin` supplies.
//
// Substitution is not a rewrite. A clone keeps `$T` exactly as written, and the
// instance's scope binds `T` to the argument; `resolve_type_syntax` then
// resolves the clone's parameter, field, and result types to concrete ones. The
// clone's scope parent is the *declaration's* lexical scope, never the caller's,
// which is what makes the same instantiation mean the same thing everywhere.
package lokec

import "core:fmt"
import "core:strings"

// design.md: recursive generic instantiation does not terminate in general, and
// M3's rule is that resource exhaustion is a diagnostic, never a silent
// fallback.
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
	// Tie-breaker 4: how much structure the parameter patterns pin down.
	specificity: int,
	// Record templates only: every instance made so far, so a block registered
	// after one exists still reaches it.
	instances:   [dynamic]^Instance,
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
	body_checked: bool,
	// Deferred so an unselected overload never has its body diagnosed.
	span:         Span,
}

Instantiation_Frame :: struct {
	description: string,
	span:        Span,
}

// An instantiated `impl` block waiting for its bodies to be checked.
// Signatures are installed as soon as the instance exists, so a method is
// callable from the code that created the instantiation; bodies wait until the
// requesting package is finished, so a method may itself use the instance.
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

// The template a symbol denotes, or nil. Registration is lazy: a generic
// declaration may be named from another package long before its own signature
// phase runs.
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
	if literal != nil && literal.signature != nil && literal.signature.convention != "" {
		// A foreign block's member inherited its convention from the block rather
		// than writing one, and `check_foreign_block` already rejects it as L0624 —
		// the answer that names the real mistake. Complaining about the inherited
		// convention as well would be two diagnostics for one error (m7-plan step 6).
		if len(d.symbols) > 0 {
			if sym := symbol_of(k.c, d.symbols[0]); sym != nil && sym.is_foreign {
				return
			}
		}
		errorf(k.c, d.span, "L0438", "a generic procedure cannot use a foreign calling convention")
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
	if e == nil {
		return false
	}
	#partial switch v in e {
	case ^Type_Poly:
		return true
	case ^Type_Pointer:
		return type_syntax_has_poly(v.elem)
	case ^Type_Multi_Pointer:
		return type_syntax_has_poly(v.elem)
	case ^Type_Slice:
		return type_syntax_has_poly(v.elem)
	case ^Type_Dynamic_Array:
		return type_syntax_has_poly(v.elem)
	case ^Type_Distinct:
		return type_syntax_has_poly(v.elem)
	case ^Type_Dyn:
		return type_syntax_has_poly(v.interface_expr)
	case ^Type_Array:
		return type_syntax_has_poly(v.length) || type_syntax_has_poly(v.elem)
	case ^Type_Map:
		return type_syntax_has_poly(v.key) || type_syntax_has_poly(v.value)
	case ^Expr_Call:
		for arg in v.args {
			if type_syntax_has_poly(arg.value) {
				return true
			}
		}
		return type_syntax_has_poly(v.callee)
	}
	return false
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
				id := name.id
				if id == INVALID_IDENTIFIER {
					id = intern_identifier(k.c, name.text)
				}
				append(&params, Generic_Param_Decl{name = id, span = name.span, type_syntax = group.type})
			}
		}
		template.params = params[:]
	case .Procedure:
		literal := decl_proc_literal(d)
		for parameter in literal.signature.params {
			template.specificity += pattern_specificity(parameter.type)
		}
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
	name := poly.name.id
	if name == INVALID_IDENTIFIER {
		name = intern_identifier(k.c, poly.name.text)
	}
	sym := symbol_of(k.c, lookup_symbol(k.scope, name))
	if sym == nil || sym.kind != .Const || sym.const_value.kind != .Integer {
		return 0, false
	}
	length, fits := bi_to_i64(k.c, sym.const_value.integer)
	if !fits || length < 0 {
		return 0, false
	}
	return u64(length), true
}

// design.md tie-breaker 4: a structural specialization beats an unspecialized
// parameter. A `$T` pins nothing down; every written layer of structure counts.
pattern_specificity :: proc(e: Expr) -> int {
	if e == nil {
		return 0
	}
	#partial switch v in e {
	case ^Type_Poly:
		return 0
	case ^Type_Pointer:
		return 1 + pattern_specificity(v.elem)
	case ^Type_Multi_Pointer:
		return 1 + pattern_specificity(v.elem)
	case ^Type_Slice:
		return 1 + pattern_specificity(v.elem)
	case ^Type_Dynamic_Array:
		return 1 + pattern_specificity(v.elem)
	case ^Type_Distinct:
		return 1 + pattern_specificity(v.elem)
	case ^Type_Dyn:
		return 1 + pattern_specificity(v.interface_expr)
	case ^Type_Array:
		return 1 + pattern_specificity(v.length) + pattern_specificity(v.elem)
	case ^Type_Map:
		return 1 + pattern_specificity(v.key) + pattern_specificity(v.value)
	case ^Expr_Call:
		total := 1
		for arg in v.args {
			total += pattern_specificity(arg.value)
		}
		return total
	}
	return 1
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
			fmt.sbprintf(&b, "V%d:%s", u32(binding.arg.value_type), const_key_text(c, binding.arg.value))
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
	}
	return "?"
}

// A readable `Table(string, int)` for diagnostics and mangled symbol names.
generic_instance_name :: proc(c: ^Compiler, template: Symbol_Id, bindings: []Generic_Binding) -> string {
	b := strings.builder_make(c.semantic_allocator)
	if sym := symbol_of(c, template); sym != nil {
		strings.write_string(&b, identifier_text(c, sym.name))
	}
	strings.write_string(&b, "(")
	for binding, index in bindings {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		if binding.arg.is_type {
			strings.write_string(&b, type_name(c, binding.arg.type))
		} else {
			strings.write_string(&b, const_key_text(c, binding.arg.value))
		}
	}
	strings.write_string(&b, ")")
	return strings.to_string(b)
}

// The same identity as a backend symbol: `Table.int.i32` rather than
// `Table(int, i32)`, so the emitted name stays readable instead of dissolving
// into escapes. Distinct argument vectors still produce distinct names, because
// each part is separately escaped.
generic_mangled_name :: proc(c: ^Compiler, template: Symbol_Id, bindings: []Generic_Binding) -> string {
	b := strings.builder_make(c.semantic_allocator)
	if sym := symbol_of(c, template); sym != nil {
		strings.write_string(&b, identifier_text(c, sym.name))
	}
	for binding in bindings {
		strings.write_string(&b, ".")
		if binding.arg.is_type {
			escaped := llvm_safe(type_name(c, binding.arg.type))
			strings.write_string(&b, escaped)
			delete(escaped)
		} else {
			escaped := llvm_safe(const_key_text(c, binding.arg.value))
			strings.write_string(&b, escaped)
			delete(escaped)
		}
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
// argument's type. Returns false only when a binding is impossible; a pattern
// with no `$` in it is not this function's business, and ordinary conversion
// ranking still decides whether the argument fits.
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
		// weakening; a `^E` argument cannot reach a `^mut $E` parameter. The same
		// rule slices use, so one helper written on the read-only spelling serves
		// both capabilities.
		if v.mutable && !info.mutable {
			return false
		}
		return match_type_pattern(k, v.elem, info.element, scope, out)

	case ^Type_Multi_Pointer:
		if info.kind != .Multi_Pointer {
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
		for arg, index in args {
			bound := info.dyn_args[index]
			if poly, is_poly := arg.value.(^Type_Poly); is_poly {
				if !bind_pattern_name(k, poly.name, bound, scope, out) {
					return false
				}
				continue
			}
			if !type_syntax_has_poly(arg.value) {
				continue // a written argument; equality is checked by ranking
			}
			if !bound.is_type || !match_type_pattern(k, arg.value, bound.type, scope, out) {
				return false
			}
		}
		return true

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
		// `^Table($K, $V)`: the argument must be an instance of that same template,
		// and its own bound arguments supply the parts.
		if info.instance_of == INVALID_SYMBOL {
			return false
		}
		callee, is_ident := v.callee.(^Expr_Ident)
		if !is_ident {
			return false
		}
		wanted := lookup_symbol(scope, identifier_of(k.c, callee))
		if wanted != info.instance_of {
			return false
		}
		if len(v.args) != len(info.instance_args) {
			return false
		}
		for arg, index in v.args {
			bound := info.instance_args[index]
			if poly, is_poly := arg.value.(^Type_Poly); is_poly {
				if !bind_pattern_name(k, poly.name, bound, scope, out) {
					return false
				}
				continue
			}
			if !type_syntax_has_poly(arg.value) {
				continue // a written argument; equality is checked by ranking
			}
			if !bound.is_type || !match_type_pattern(k, arg.value, bound.type, scope, out) {
				return false
			}
		}
		return true
	}
	return false
}

@(private = "file")
bind_pattern_name :: proc(
	k: ^Checker,
	name: Name,
	arg: Generic_Arg,
	scope: ^Scope,
	out: ^[dynamic]Generic_Binding,
) -> bool {
	id := name.id
	if id == INVALID_IDENTIFIER {
		id = intern_identifier(k.c, name.text)
	}
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
	// Which written arguments were consumed by `$` parameters, and the
	// concrete type each one was converted to. Overload ordering still ranks
	// those written arguments even though they do not survive in the runtime
	// signature.
	compile_time:    []bool,
	compile_targets: []Type_Id,
	scope:        ^Scope,
	reason:       string,
	ok:           bool,
}

// Walks a template's written signature left to right, binding every `$` name
// from the arguments as it goes, so a later parameter type may name an earlier
// binding. `$` parameters are compile-time inputs and do not survive into the
// instance's runtime signature.
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

	outer_scope, outer_pkg, outer_lookup, outer_impl := k.scope, k.pkg, k.lookup_pkg, k.impl_type
	outer_file, outer_file_node := k.file, k.file_node
	k.scope = scope
	k.pkg = template.pkg
	k.lookup_pkg = template.lookup_pkg
	k.impl_type = template.impl_type
	if template.file_node != nil {
		k.file, k.file_node = template.file, template.file_node
	}
	defer {
		k.scope, k.pkg, k.lookup_pkg, k.impl_type = outer_scope, outer_pkg, outer_lookup, outer_impl
		k.file, k.file_node = outer_file, outer_file_node
	}

	// This is a property of the written call, before `$` arguments disappear
	// from an instantiated signature. Delaying it until `build_candidate` would
	// accept a positional argument after a named compile-time argument.
	named := false
	for arg in args {
		if arg.name != INVALID_IDENTIFIER {
			named = true
		} else if named {
			result.reason = "a positional argument cannot follow a named one"
			return result
		}
	}

	// Inference binds `$` names; ranking is `build_candidate`'s job against the
	// substituted signature. So an argument a *name* claims goes to its own
	// parameter, an omitted one with a default is simply not bound here — the
	// instance's own signature carries the default — and every remaining argument
	// fills a variadic pack.
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
				if parameter.default != nil {
					continue
				}
				result.reason = "it needs more arguments than were supplied"
				return result
			}
			arg := args[index]
			if !entry.is_poly {
				// An ordinary runtime parameter, whose written type may still be a
				// pattern binding parts of the argument's type.
				if !match_type_pattern(k, parameter.type, arg.type, scope, &bindings) {
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
	// The runtime arguments keep their *written* order, because that is the order
	// `build_candidate` ranks them in: an unnamed argument fills the slot at its
	// own index, and a named one finds its parameter by name.
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

// The argument a parameter takes: the one written with its name if there is one,
// otherwise the next unclaimed positional argument. Named arguments are matched
// first so that `f(reader, limit = 5)` binds `limit` to its own parameter rather
// than to the one it sits next to.
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
		if !bind_pattern_name(k, name, Generic_Arg{is_type = true, type = denoted}, scope, out) {
			return "its generic arguments do not agree", false
		}
		return "", true
	}
	if !arg.is_const {
		return "a `$` parameter needs a compile-time constant argument", false
	}
	value := arg.const_value
	value_type := arg.type
	if wanted != INVALID_TYPE {
		converted, fits := convert_const(k.c, value, wanted, false)
		if !fits {
			return fmt.aprintf(
				"`%s` is not representable by the generic parameter's type `%s`",
				const_key_text(k.c, value),
				type_name(k.c, wanted),
				allocator = k.c.semantic_allocator,
			), false
		}
		value, value_type = converted, wanted
	} else {
		value_type = default_type(k.c, value_type)
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
		// Once the ceiling is reached the program is not going to compile, and
		// letting the traversal continue would report the same runaway thousands
		// of times over.
		// A silent overload probe must not consume the one diagnostic or poison a
		// later direct request for the same instance.
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
	// Reserve the unique cache entry before resolving its signature. Signature
	// resolution can recursively instantiate other declarations; reserving here
	// keeps nested work from crossing the global ceiling while unwinding. A
	// rejected entry remains negatively cached, so repeated probes do not consume
	// another slot.
	k.c.instantiation_count += 1

	name := generic_instance_name(k.c, template.symbol, bindings)
	instance.mangled = generic_mangled_name(k.c, template.symbol, bindings)
	append(&k.c.instantiation_stack, Instantiation_Frame{description = name, span = span})
	defer {
		pop(&k.c.instantiation_stack)
		instance.provisional = false
	}

	switch template.kind {
	case .Record:
		instance.signature_ok = instantiate_record_body(k, template, instance, name, report)
	case .Procedure:
		instance.signature_ok = instantiate_procedure_signature(k, template, instance, name, report)
	case .None:
	}
	// Failed bounds are negative cache entries. Reusing them avoids cloning a
	// declaration and allocating semantic artifacts on every overload probe;
	// `report_rejected_instance` can still replay the bound diagnostically.
	return instance, instance.signature_ok
}

@(private = "file")
report_rejected_instance :: proc(k: ^Checker, template: ^Generic_Template, instance: ^Instance, span: Span) {
	if instance == nil || instance.decl == nil {
		return
	}
	name := generic_instance_name(k.c, template.symbol, instance.bindings)
	saved := enter_instance(k, template, instance.scope)
	defer leave_instance(k, saved)

	append(&k.c.instantiation_stack, Instantiation_Frame{description = name, span = span})
	defer pop(&k.c.instantiation_stack)
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

// A runaway instantiation stack is thousands of frames deep and reading all of
// them helps nobody: the innermost few name the recursion, and the count says
// how far it ran.
NOTED_INSTANTIATION_FRAMES :: 4

note_instantiation_stack :: proc(k: ^Checker) {
	// Unwinding a deep instantiation passes every level, and each one sees the
	// same new diagnostic. The stack belongs to it once.
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

// Runs `body` with the checker positioned at an instance: its own scope, the
// definition's package for method, operator, and extension lookup, and the
// definition's file for visibility defaults.
// The checker state an instance displaces, named rather than positional: `pkg`
// and `lookup` are both `Package_Id`, and `file` and `generic` are both
// integers, so a positional restore had two pairs that could be swapped without
// the compiler noticing.
@(private = "file")
Instance_Context :: struct {
	scope:       ^Scope,
	pkg, lookup: Package_Id,
	impl:        Type_Id,
	file:        u32,
	node:        ^File,
	literal:     ^Expr_Proc,
	generic:     int,
}

@(private = "file")
enter_instance :: proc(k: ^Checker, template: ^Generic_Template, scope: ^Scope) -> Instance_Context {
	saved := Instance_Context {
		scope   = k.scope,
		pkg     = k.pkg,
		lookup  = k.lookup_pkg,
		impl    = k.impl_type,
		file    = k.file,
		node    = k.file_node,
		literal = k.proc_literal,
		generic = k.generic_depth,
	}
	k.scope = scope
	k.pkg = template.pkg
	k.lookup_pkg = template.lookup_pkg
	k.impl_type = template.impl_type
	k.proc_literal = nil
	k.generic_depth += 1
	if template.file_node != nil {
		k.file, k.file_node = template.file, template.file_node
	}
	return saved
}

@(private = "file")
leave_instance :: proc(k: ^Checker, saved: Instance_Context) {
	k.scope, k.pkg, k.lookup_pkg = saved.scope, saved.pkg, saved.lookup
	k.impl_type, k.file, k.file_node = saved.impl, saved.file, saved.node
	k.proc_literal = saved.literal
	k.generic_depth = saved.generic
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
	defer leave_instance(k, saved)

	before := len(k.c.diagnostics)
	if record.kind == .Struct {
		resolve_struct_fields(k, type, record)
	} else {
		resolve_union_variants(k, type, record)
	}
	if !check_where_clauses(k, record.where_clauses, instance.span, name, report) {
		return false
	}
	if report && len(k.c.diagnostics) > before {
		note_instantiation_stack(k)
	}

	path := make([dynamic]Type_Id, 0, 8, context.temp_allocator)
	check_finite_size(k, type, template.decl.span, &path)

	// The type, its fields, and its bounds are settled now, so a method that
	// names its own instantiation — `proc(self: inout Table(Key, Value))`, which
	// design.md writes out — is an ordinary cache hit rather than recursion.
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
	if len(v.args) != len(template.params) {
		if report {
			errorf(
				k.c,
				v.span,
				"L0431",
				"`%s` takes %d generic argument%s, found %d",
				identifier_text(k.c, symbol_of(k.c, template.symbol).name),
				len(template.params),
				len(template.params) == 1 ? "" : "s",
				len(v.args),
			)
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
	converted, fits := convert_const(k.c, folded, wanted, false)
	if !fits {
		return fmt.aprintf(
			"`%s` is not representable by the generic parameter's type `%s`",
			const_key_text(k.c, folded),
			type_name(k.c, wanted),
			allocator = k.c.semantic_allocator,
		), false
	}
	if !bind_pattern_name(k, name, Generic_Arg{value = converted, value_type = wanted}, scope, out) {
		return "this generic argument disagrees with an earlier one", false
	}
	return "", true
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
	clone.symbols[0] = symbol_id
	literal.symbol = symbol_id

	saved := enter_instance(k, template, instance.scope)
	defer leave_instance(k, saved)

	before := k.c.error_count
	clone.sig_state = .Checked
	resolve_proc_signature(k, literal, symbol_id)
	if k.c.error_count > before {
		if report {
			note_instantiation_stack(k)
		}
		return false
	}
	if !check_where_clauses(k, literal.where_clauses, instance.span, name, report) {
		return false
	}
	return true
}

// Checks a selected instance's body exactly once, and queues it for emission
// with its defining package's items.
promote_generic_instance :: proc(k: ^Checker, instance: ^Instance) {
	if instance == nil || instance.body_checked || !instance.signature_ok {
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
	defer leave_instance(k, saved)

	append(&k.c.instantiation_stack, Instantiation_Frame {
		description = identifier_text(k.c, symbol_of(k.c, instance.symbol).name),
		span        = instance.span,
	})
	defer pop(&k.c.instantiation_stack)

	before := len(k.c.diagnostics)
	instance.decl.check_state = .Checked
	check_proc_body(k, literal)
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

// design.md "where clauses": every bound is a compile-time boolean evaluated
// while the declaration is instantiated. A failed bound removes an overload
// candidate silently and is a hard error at a direct instantiation.
check_where_clauses :: proc(k: ^Checker, clauses: []Expr, span: Span, what: string, report: bool) -> bool {
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
			truncate_diagnostics(k.c, mark)
			k.c.error_count = errors
			continue
		}
		if !report {
			truncate_diagnostics(k.c, mark)
			k.c.error_count = errors
			return false
		}
		if failed {
			if k.c.error_count == errors {
				errorf(k.c, expr_span(clause), "L0435", "a `where` bound must be a compile-time boolean")
			}
			note_instantiation_stack(k)
			return false
		}
		truncate_diagnostics(k.c, mark)
		k.c.error_count = errors
		// design.md: an interface bound must name the requirement that failed and
		// the concrete type that failed it, never a bare "constraint not
		// satisfied". A value predicate has no requirement to name, so it reports
		// the bound as written.
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

@(private = "file")
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

// An `impl` block whose subject is a generic application is kept until
// an instantiation of that type exists. Both `impl Table($K, $V)` and
// `impl Table(string, int)` are registered here; the second simply matches
// fewer instances.
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
	// The same rule an ordinary block follows in `declare_impl_block`, decided
	// here because a generic subject is registered before it resolves to a type:
	// the template's own package makes the block inherent, anywhere else makes it
	// an extension.
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
	append(blocks, block)
	item.declared = true
	// A block declared after an instance already exists still applies to it, so
	// registration order between packages cannot decide what a type has.
	if existing := k.c.generic_templates[template]; existing != nil {
		for instance in existing.instances {
			install_one_generic_impl(k, existing, instance, block)
		}
	}
	return true
}

// Installs every matching block's members on a fresh instance, most specialized
// first. A less specialized block does not re-declare a name the specialized one
// already supplied, which is tie-breaker 4 applied where monomorphization puts
// it: both blocks resolve to the same concrete type.
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
	saved_scope, saved_pkg, saved_lookup := k.scope, k.pkg, k.lookup_pkg
	saved_impl, saved_file, saved_node := k.impl_type, k.file, k.file_node
	saved_generic := k.generic_depth
	k.scope = scope
	k.pkg = block.pkg
	k.lookup_pkg = block.pkg
	k.generic_depth += 1
	if block.file_node != nil {
		k.file, k.file_node = block.file, block.file_node
	}
	defer {
		k.scope, k.pkg, k.lookup_pkg = saved_scope, saved_pkg, saved_lookup
		k.impl_type, k.file, k.file_node = saved_impl, saved_file, saved_node
		k.generic_depth = saved_generic
	}

	// Match the block's written arguments against this instance's bound ones.
	for written, index in block.args {
		bound := instance.bindings[index].arg
		if poly, is_poly := written.(^Type_Poly); is_poly {
			name := poly.name
			if name.id == INVALID_IDENTIFIER {
				name.id = intern_identifier(k.c, name.text)
			}
			bind_generic_name(k, scope, Generic_Binding{name = name.id, span = name.span, arg = bound})
			continue
		}
		if bound.is_type {
			mark := len(k.c.diagnostics)
			errors := k.c.error_count
			resolved := resolve_type_syntax(k, written)
			truncate_diagnostics(k.c, mark)
			k.c.error_count = errors
			if resolved != bound.type {
				return
			}
			continue
		}
		mark := len(k.c.diagnostics)
		errors := k.c.error_count
		folded, evaluated := Const_Value{}, false
		if check_single_expr(k, written, bound.value_type) != INVALID_TYPE {
			folded, evaluated = require_const(k, written, "a generic argument", "L0432")
		}
		truncate_diagnostics(k.c, mark)
		k.c.error_count = errors
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
	// Signatures are resolved here, where the block's own scope and subject are
	// in place: an ordinary call site would otherwise resolve them against
	// whatever scope happened to reach the member first.
	for member in clone.members {
		if d, is_decl := member.(^Decl); is_decl {
			resolve_declaration_signature(k, d)
		}
	}
	for member in clone.members {
		if delegate, is_delegate := member.(^Item_Delegate); is_delegate {
			check_delegate(k, delegate, instance.type)
		}
	}
	append(&k.c.pending_impl_instances, Pending_Impl{item = clone, scope = scope, pkg = block.pkg, file = block.file, file_node = block.file_node, subject = instance.type})
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
			name_id := name.id
			if name.text == "_" {
				append(&symbols, INVALID_SYMBOL)
				continue
			}
			if name_id == INVALID_IDENTIFIER {
				name_id = intern_identifier(k.c, name.text)
			}
			if instance_member_named(k, subject, block.pkg, item.kind, name_id) != INVALID_SYMBOL {
				append(&symbols, INVALID_SYMBOL) // a more specialized block supplied it
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
				implicit   = has_attribute(d.attributes, "implicit"),
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
				if pkg := package_of(k.c, block.pkg); pkg != nil && pkg.scope != nil {
					if _, taken := pkg.scope.names[name_id]; !taken {
						pkg.scope.names[name_id] = id
					}
				}
			}
			append(&symbols, id)
			append(&added, id)
		}
		d.symbols = symbols[:]
	}
	install_instance_members(k, item.kind, subject, block.pkg, added[:])
}

@(private = "file")
instance_member_named :: proc(k: ^Checker, subject: Type_Id, pkg: Package_Id, kind: Impl_Kind, name: Identifier_Id) -> Symbol_Id {
	if kind == .Impl {
		if info := type_of(k.c, subject); info != nil {
			return member_named_in(k.c, info.members, name)
		}
		return INVALID_SYMBOL
	}
	if target := package_of(k.c, pkg); target != nil {
		return member_named_in(k.c, target.extensions[subject], name)
	}
	return INVALID_SYMBOL
}

member_named_in :: proc(c: ^Compiler, members: []Symbol_Id, name: Identifier_Id) -> Symbol_Id {
	for member in members {
		if sym := symbol_of(c, member); sym != nil && sym.name == name {
			return member
		}
	}
	return INVALID_SYMBOL
}

@(private = "file")
install_instance_members :: proc(k: ^Checker, kind: Impl_Kind, subject: Type_Id, pkg: Package_Id, added: []Symbol_Id) {
	if len(added) == 0 {
		return
	}
	previous: []Symbol_Id
	if kind == .Impl {
		if info := type_of(k.c, subject); info != nil {
			previous = info.members
		}
	} else if target := package_of(k.c, pkg); target != nil {
		previous = target.extensions[subject]
	}
	merged := make([]Symbol_Id, len(previous) + len(added), k.c.semantic_allocator)
	copy(merged, previous)
	copy(merged[len(previous):], added)
	if kind == .Impl {
		if info := type_of(k.c, subject); info != nil {
			info.members = merged
		}
		return
	}
	if target := package_of(k.c, pkg); target != nil {
		target.extensions[subject] = merged
	}
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

		saved_scope, saved_pkg, saved_lookup := k.scope, k.pkg, k.lookup_pkg
		saved_impl, saved_file, saved_node := k.impl_type, k.file, k.file_node
		saved_generic := k.generic_depth
		k.scope = pending.scope
		k.pkg, k.lookup_pkg = pending.pkg, pending.pkg
		k.impl_type = pending.subject
		k.generic_depth += 1
		if pending.file_node != nil {
			k.file, k.file_node = pending.file, pending.file_node
		}

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
				append(&pkg.instances, Instance_Decl {
					symbol = d.symbols[0],
					decl   = d,
					name   = qualified_member_name(k.c, sym),
				})
			}
		}

		k.scope, k.pkg, k.lookup_pkg = saved_scope, saved_pkg, saved_lookup
		k.impl_type, k.file, k.file_node = saved_impl, saved_file, saved_node
		k.generic_depth = saved_generic
	}
}
