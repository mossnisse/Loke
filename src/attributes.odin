// Attribute discipline: one table of every attribute design.md defines, with the
// positions it may appear in and the value shape it takes. Behaviour lives with
// the owning feature; this file reports misuse and records what a declaration
// says on its symbol or type.
package lokec

import "core:strings"

Attr_Pos :: enum {
	Package_Clause,
	Import,
	Proc_Decl,
	Proc_Group,
	Var_Decl,
	Const_Decl,
	Type_Decl,
	Struct_Field,
	Parameter,
	Struct_Decl,
	Union_Decl,
	Foreign_Block,
	Static_Assert,
	Delegate,
	Impl,
	Statement,
}

// Where a declaration's attribute list sits, for the rules the position alone
// cannot express.
Attr_Scope :: enum {
	Global,
	Local,   // inside a body: no linkage or visibility
	Foreign, // a foreign block member: `@(link_name)` needs no `@(export)`
}

Attr_Shape :: enum {
	None,           // `@(name)`
	Value_Required, // `@(name="...")`
	Deferred,       // the owning feature validates the value
}

Attr_Spec :: struct {
	positions:   bit_set[Attr_Pos],
	shape:       Attr_Shape,
	global_only: bool,
}

// design.md "Attributes" and "Layout and ABI attributes". A switch rather than a
// map, so the lookup allocates nothing and shares nothing between compilers.
attribute_spec :: proc(name: string) -> (Attr_Spec, bool) {
	switch name {
	case "public":
		return {{.Package_Clause, .Proc_Decl, .Proc_Group, .Var_Decl, .Const_Decl, .Type_Decl, .Struct_Decl, .Union_Decl, .Struct_Field, .Foreign_Block}, .None, true}, true
	case "private":
		return {{.Proc_Decl, .Proc_Group, .Var_Decl, .Const_Decl, .Type_Decl, .Struct_Decl, .Union_Decl, .Struct_Field, .Foreign_Block}, .None, true}, true
	case "default_allocator", "default_logger":
		// Also read before import discovery by `collect_source_provider_defaults`.
		return {{.Package_Clause}, .Value_Required, false}, true
	case "require_results":
		return {{.Proc_Decl, .Proc_Group, .Foreign_Block, .Type_Decl, .Struct_Decl, .Union_Decl}, .None, false}, true
	case "deprecated":
		return {{.Proc_Decl}, .Value_Required, false}, true
	case "cold":
		// That the procedure has a body is `validate_decl_attributes`'.
		return {{.Proc_Decl}, .None, false}, true
	case "cpu_dispatch":
		// Which procedures may carry it is `validate_cpu_dispatch`'.
		return {{.Proc_Decl}, .Value_Required, true}, true
	case "test":
		// Its other rules are `check_test_procedures`'.
		return {{.Proc_Decl}, .None, true}, true
	case "export":
		return {{.Proc_Decl, .Var_Decl}, .None, true}, true
	case "link_name":
		return {{.Proc_Decl, .Var_Decl}, .Value_Required, true}, true
	case "default_calling_convention":
		return {{.Foreign_Block}, .Value_Required, false}, true
	case "allocator_reset", "by_ptr", "c_vararg":
		return {{.Parameter}, .None, false}, true
	case "escape":
		// A bare level identifier, checked by `check_escape_attribute`.
		return {{.Parameter}, .Deferred, false}, true
	case "packed":
		return {{.Struct_Decl}, .None, false}, true
	case "align":
		return {{.Struct_Decl, .Union_Decl}, .Deferred, false}, true
	case "initialized":
		// A sibling field name, checked by `resolve_uninitialized_fields`.
		return {{.Struct_Field}, .Deferred, false}, true
	case "required":
		return {{.Struct_Field}, .None, false}, true
	case "synchronized":
		// Which variables may carry it is `validate_decl_attributes`'.
		return {{.Struct_Field, .Var_Decl}, .None, false}, true
	case "move_only", "thread_affine", "wakes_on_drop":
		return {{.Struct_Decl, .Union_Decl}, .None, false}, true
	case "fieldwise_copy":
		// What the record must be is `check_copy_decision`'.
		return {{.Struct_Decl}, .None, false}, true
	case "cross_thread":
		// What the parameter must be is `check_cross_thread_attribute`'.
		return {{.Parameter}, .None, false}, true
	case "intrinsic":
		// Bound by `src/intrinsic.odin`, which validates the declaration's other
		// attributes; one reaching the ordinary pass is misplaced.
		return {{.Proc_Decl, .Type_Decl, .Struct_Decl, .Union_Decl, .Const_Decl}, .None, true}, true
	case "zero", "failure":
		// A variant name, checked in `src/union.odin`.
		return {{.Union_Decl}, .Deferred, false}, true
	}
	return {}, false
}

attr_pos_name :: proc(pos: Attr_Pos) -> string {
	switch pos {
	case .Package_Clause: return "a package clause"
	case .Import:         return "an import"
	case .Proc_Decl:      return "a procedure declaration"
	case .Proc_Group:     return "a procedure group"
	case .Var_Decl:       return "a variable declaration"
	case .Const_Decl:     return "a constant declaration"
	case .Type_Decl:      return "a type declaration"
	case .Struct_Field:   return "a struct field"
	case .Parameter:      return "a parameter"
	case .Struct_Decl:    return "a struct declaration"
	case .Union_Decl:     return "a union declaration"
	case .Foreign_Block:  return "a foreign block"
	case .Static_Assert:  return "a `static_assert`"
	case .Delegate:       return "a `delegate`"
	case .Impl:           return "an `impl` block"
	case .Statement:      return "a statement"
	}
	return "here"
}

// Reports each misuse in one attribute list, once per written list: generic
// instances and static foreach copies share the spans, so they are skipped.
validate_attribute_list :: proc(
	k: ^Checker,
	attributes: []Attribute,
	pos: Attr_Pos,
	scope := Attr_Scope.Global,
	duration := Duration.None,
) {
	if len(attributes) == 0 {
		return
	}
	// A speculative check discards its diagnostics, so it must not claim the list.
	if committing(k.c) {
		first := attributes[0].span
		key := u64(first.file) << 32 | u64(first.lo)
		if k.c.validated_attributes[key] {
			return
		}
		k.c.validated_attributes[key] = true
	}
	seen := make(map[string]bool, len(attributes), context.temp_allocator)
	for attribute in attributes {
		if len(attribute.path) == 0 {
			continue
		}
		// No toolchain extension is currently enabled.
		if len(attribute.path) > 1 {
			names := make([]string, len(attribute.path), context.temp_allocator)
			for part, index in attribute.path {
				names[index] = part.text
			}
			errorf(
				k.c, attribute.span, "L0610",
				"`@(%s)` is an extension attribute; its `%s` namespace is not enabled",
				strings.join(names, ".", context.temp_allocator), names[0],
			)
			continue
		}
		name := attribute.path[0].text
		spec, known := attribute_spec(name)
		if !known {
			errorf(k.c, attribute.span, "L0606", "unknown attribute `@(%s)`", name)
			continue
		}
		if seen[name] {
			errorf(k.c, attribute.span, "L0609", "`@(%s)` is written more than once here", name)
			continue
		}
		seen[name] = true
		if name == "intrinsic" {
			report_misplaced_intrinsic(k, attribute.span)
			continue
		}
		if pos not_in spec.positions {
			errorf(k.c, attribute.span, "L0607", "`@(%s)` cannot appear on %s", name, attr_pos_name(pos))
			continue
		}
		if scope == .Local && spec.global_only {
			errorf(k.c, attribute.span, "L0607", "`@(%s)` cannot appear on a local declaration", name)
			continue
		}
		switch spec.shape {
		case .None:
			if attribute.value != nil {
				errorf(k.c, attribute.span, "L0608", "`@(%s)` takes no value", name)
			}
		case .Value_Required:
			if attribute.value == nil {
				errorf(k.c, attribute.span, "L0608", "`@(%s)` needs a value: `@(%s=...)`", name, name)
			} else if lit, ok := attribute.value.(^Expr_Literal); !ok ||
			          (lit.kind != .String && lit.kind != .Raw_String) {
				errorf(k.c, attribute.span, "L0608", "`@(%s)` needs a string value", name)
			}
		case .Deferred:
		}
		if name == "synchronized" && pos == .Var_Decl {
			validate_synchronized_variable(k, attribute, scope, duration)
		}
	}
	// design.md: `@(link_name)` names an exported or foreign symbol.
	if scope == .Global && (pos == .Proc_Decl || pos == .Var_Decl) && seen["link_name"] && !seen["export"] {
		for attribute in attributes {
			if len(attribute.path) == 1 && attribute.path[0].text == "link_name" {
				errorf(
					k.c, attribute.span, "L0607",
					"`@(link_name)` names a linked symbol, so it needs `@(export)` outside a foreign block",
				)
			}
		}
	}
}

// The whole-package pass. Record fields and parameters nested anywhere are also
// validated where they resolve (`resolve_type_syntax`, the signatures).
validate_attributes :: proc(k: ^Checker, pkg: ^Package) {
	for file in pkg.files {
		k.file, k.file_node = file.file, file
		validate_attribute_list(k, file.attributes, .Package_Clause)
		for attribute in file.attributes {
			if _, is_provider := source_provider_slot(attribute); is_provider &&
			   pkg.id != k.c.root_package {
				errorf(
					k.c, attribute.span, "L0613",
					"`@(%s=...)` is only allowed on the root package clause",
					attribute.path[0].text,
				)
			}
		}
		validate_item_attributes(k, file.items)
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				validate_decl_attributes(k, v)
			case ^Item_Impl:
				validate_impl_attributes(k, v)
			case ^Item_Static_Assert:
				validate_attribute_list(k, v.attributes, .Static_Assert)
			case ^Item_Foreign_Block:
				validate_attribute_list(k, v.attributes, .Foreign_Block)
				for member in v.members {
					if d, ok := member.(^Decl); ok {
						validate_decl_attributes(k, d, .Foreign)
					}
				}
			}
		}
	}
}

// Imports and `when` blocks, in every branch: neither takes an attribute.
@(private = "file")
validate_item_attributes :: proc(k: ^Checker, items: []Item) {
	for item in items {
		#partial switch v in item {
		case ^Item_Import:
			validate_attribute_list(k, v.attributes, .Import)
		case ^Item_Foreign_Import:
			validate_attribute_list(k, v.attributes, .Import)
		case ^Item_When:
			validate_attribute_list(k, v.attributes, .Statement)
			if v.then != nil {
				validate_item_attributes(k, {v.then})
			}
			validate_item_attributes(k, {v.otherwise})
		case ^Item_Block:
			validate_attribute_list(k, v.attributes, .Statement)
			validate_item_attributes(k, v.items)
		}
	}
}

validate_impl_attributes :: proc(k: ^Checker, item: ^Item_Impl) {
	validate_attribute_list(k, item.attributes, .Impl)
	for member in item.members {
		#partial switch m in member {
		case ^Decl:
			validate_decl_attributes(k, m, member = true)
		case ^Item_Delegate:
			validate_attribute_list(k, m.attributes, .Delegate)
		}
	}
}

validate_decl_attributes :: proc(k: ^Checker, d: ^Decl, scope := Attr_Scope.Global, member := false) {
	if len(d.symbols) == 0 {
		return
	}
	validate_attribute_list(k, d.attributes, decl_attr_position(k, d), scope, d.duration)
	if scope != .Local {
		validate_cpu_dispatch(k, d, scope, member)
	}
	// design.md "@(cold)": it describes the procedure's code, which a foreign
	// declaration does not have.
	if scope == .Foreign {
		if attribute, found := find_attribute(d.attributes, "cold"); found && decl_attr_position(k, d) == .Proc_Decl {
			errorf(
				k.c, attribute.span, "L0607",
				"`@(cold)` marks a procedure's body, and a foreign declaration has none",
			)
		}
	}
	// design.md "@(require_results)": a property of a value's type, and no value
	// has an interface's type.
	if attribute, found := find_attribute(d.attributes, "require_results"); found && len(d.values) == 1 {
		if _, is_interface := d.values[0].(^Type_Interface); is_interface {
			errorf(k.c, attribute.span, "L0607", "`@(require_results)` cannot appear on an interface")
		}
	}
	// design.md "Test procedures": declared at file scope.
	if member || scope == .Foreign {
		if attribute, found := find_attribute(d.attributes, "test"); found {
			errorf(k.c, attribute.span, "L0607", "`@(test)` cannot appear on %s", member ? "an `impl` member" : "a foreign declaration")
		}
	}
	// A generic template never resolves, so its parameters and record are
	// reached here rather than only at resolution.
	if literal := decl_proc_literal(d); literal != nil {
		validate_param_attributes(k, literal.signature.params)
	}
	if len(d.values) == 1 {
		if record, ok := d.values[0].(^Type_Record); ok {
			validate_record_attributes(k, record)
		}
	}
}

// design.md "@(synchronized)": a variable every thread shares, which is
// file-scope or `static` storage. A `thread_local` one is the thread's own, a
// plain local is the frame's, and foreign storage is no package's to vouch for.
@(private = "file")
validate_synchronized_variable :: proc(k: ^Checker, attribute: Attribute, scope: Attr_Scope, duration: Duration) {
	reason := ""
	switch {
	case scope == .Foreign:
		reason = "a foreign variable, whose accesses no package synchronizes"
	case duration == .Thread_Local:
		reason = "a `thread_local` variable, which each thread has its own of"
	case scope == .Local && duration != .Static:
		reason = "a local variable, which only its own frame reaches"
	}
	if reason != "" {
		errorf(
			k.c, attribute.span, "L0721",
			"`@(synchronized)` marks storage every thread shares, and this is %s", reason,
		)
	}
}

validate_param_attributes :: proc(k: ^Checker, params: []Parameter) {
	for param in params {
		validate_attribute_list(k, param.attributes, .Parameter)
	}
}

// A record's attributes are its declaration's, so only its fields have a list of
// their own here.
validate_record_attributes :: proc(k: ^Checker, record: ^Type_Record) {
	for field in record.fields {
		validate_attribute_list(k, field.attributes, .Struct_Field)
	}
}

// design.md "@(cpu_dispatch=<string>)": a level above baseline, on a file-scope
// procedure the compiler can emit twice, which a generic, a foreign-convention
// procedure, and a foreign declaration are not.
@(private = "file")
validate_cpu_dispatch :: proc(k: ^Checker, d: ^Decl, scope: Attr_Scope, member: bool) {
	for attribute in d.attributes {
		if len(attribute.path) != 1 || attribute.path[0].text != "cpu_dispatch" {
			continue
		}
		literal := decl_proc_literal(d)
		if literal == nil || decl_attr_position(k, d) != .Proc_Decl {
			return
		}
		reason := ""
		switch {
		case scope == .Foreign:
			reason = "a foreign declaration, which has no body to emit"
		case member:
			reason = "a member of an `impl` block; it marks file-scope procedures"
		case proc_signature_is_generic(literal):
			reason = "a generic procedure"
		case literal.signature != nil && convention_is_foreign(literal.signature.convention):
			reason = "a procedure with a foreign calling convention"
		}
		if reason != "" {
			errorf(k.c, attribute.span, "L0739", "`@(cpu_dispatch)` cannot mark %s", reason)
			return
		}
		if text, ok := attribute_string_value(k.c, d.attributes, "cpu_dispatch"); ok {
			if _, known := dispatch_cpu_level(text); !known {
				errorf(
					k.c, attribute.span, "L0739",
					"`@(cpu_dispatch)` names a CPU level above baseline, `x86-64-v2` or `x86-64-v3`; found `%s`", text,
				)
			}
		}
		return
	}
}

// The level a `@(cpu_dispatch)` value names, which is never baseline.
dispatch_cpu_level :: proc(text: string) -> (Cpu_Level, bool) {
	cpu, known := parse_cpu_level(text)
	return cpu, known && cpu != .X86_64
}

record_attr_position :: proc(record: ^Type_Record) -> Attr_Pos {
	return record.kind == .Struct ? .Struct_Decl : .Union_Decl
}

@(private = "file")
decl_attr_position :: proc(k: ^Checker, d: ^Decl) -> Attr_Pos {
	if len(d.values) == 1 {
		if record, is_record := d.values[0].(^Type_Record); is_record {
			return record_attr_position(record)
		}
	}
	if sym := symbol_of(k.c, d.symbols[0]); sym != nil {
		#partial switch sym.kind {
		case .Proc:       return .Proc_Decl
		case .Proc_Group: return .Proc_Group
		case .Type:       return .Type_Decl
		case .Const:      return .Const_Decl
		}
	}
	return d.kind == .Const ? .Const_Decl : .Var_Decl
}

// Records `@(deprecated)`, `@(require_results)`, `@(test)`, and
// `@(cpu_dispatch)` on the symbol
// while its signature resolves, so a use in another package already sees them.
apply_proc_metadata :: proc(k: ^Checker, d: ^Decl, symbol_id: Symbol_Id) {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
		return
	}
	for attribute in d.attributes {
		if len(attribute.path) != 1 {
			continue
		}
		switch attribute.path[0].text {
		case "deprecated":
			sym.deprecated = true
			if lit, ok := attribute.value.(^Expr_Literal); ok && (lit.kind == .String || lit.kind == .Raw_String) {
				if text, decoded := decode_string_literal(k.c, lit.text, lit.kind == .Raw_String); decoded {
					sym.deprecated_message = text
				}
			}
		case "require_results":
			sym.require_results = true
		case "cpu_dispatch":
			if text, ok := attribute_string_value(k.c, d.attributes, "cpu_dispatch"); ok && sym.kind == .Proc {
				sym.dispatch_cpu, sym.dispatches = dispatch_cpu_level(text)
			}
		}
	}
}

// design.md "@(require_results)": a type carrying it makes every value aggregate
// containing it require its results too (`type_requires_results`).
apply_type_metadata :: proc(k: ^Checker, d: ^Decl, type: Type_Id) {
	if info := type_of(k.c, type); info != nil && has_attribute(d.attributes, "require_results") {
		info.requires_results = true
	}
}

// The string value of a named attribute in a list, decoded from its literal.
attribute_string_value :: proc(c: ^Compiler, attributes: []Attribute, name: string) -> (string, bool) {
	for attribute in attributes {
		if len(attribute.path) != 1 || attribute.path[0].text != name {
			continue
		}
		if lit, ok := attribute.value.(^Expr_Literal); ok && (lit.kind == .String || lit.kind == .Raw_String) {
			if text, decoded := decode_string_literal(c, lit.text, lit.kind == .Raw_String); decoded {
				return text, true
			}
		}
	}
	return "", false
}

report_misplaced_intrinsic :: proc(k: ^Checker, span: Span) {
	errorf(
		k.c, span, "L0734",
		"`@(intrinsic)` describes a name the compiler supplies, so it belongs at file scope, outside `when`, in a bundled package",
	)
}

// design.md "Exported names", "`@(public)`": L0338 unless L0332 already rejected
// it; a public default leaves a variable package-private silently.
declaration_is_public :: proc(k: ^Checker, d: ^Decl) -> bool {
	public := attributes_are_public(k, d.attributes, d.span, "declaration")
	if d.kind != .Var {
		return public
	}
	if attribute, written := find_attribute(d.attributes, "public"); written && !has_attribute(d.attributes, "private") {
		errorf(
			k.c,
			attribute.span,
			"L0338",
			"a variable cannot be `@(public)`; export a procedure that reads it or returns a borrow of it",
		)
	}
	return false
}

// The operators a `delegate` generates are members as a declaration in the
// same `impl` would be, so an importer finds an inherent one as it finds a
// hand-written one (design.md "Delegating operators"); an extension's stay in
// its package's table. A `delegate` takes no visibility attribute (L0607), so
// the file's default decides.
delegation_is_public :: proc(k: ^Checker) -> bool {
	return k.file_node != nil && has_attribute(k.file_node.attributes, "public")
}

// `declaration_is_public`'s rule, for a struct field. design.md "Exported
// names": nothing imports a `package main`, so its fields are public by
// default, which is what reflection and printing see. Its declarations keep the
// package default: a public extension would export a name.
field_is_public :: proc(k: ^Checker, field: ^Field) -> bool {
	in_main := k.file_node != nil && k.file_node.package_name == "main"
	return attributes_are_public(k, field.attributes, field.span, "field", in_main)
}

@(private = "file")
attributes_are_public :: proc(k: ^Checker, attributes: []Attribute, span: Span, what: string, by_default := false) -> bool {
	own_public := has_attribute(attributes, "public")
	own_private := has_attribute(attributes, "private")
	if own_public && own_private {
		errorf(k.c, span, "L0332", "this %s is both `@(public)` and `@(private)`", what)
		return false
	}
	return written_is_public(attributes, k.file_node.attributes if k.file_node != nil else nil, by_default)
}

// The same rule without its diagnostic, for syntax no symbol records: a
// generic record's fields and a generic `impl`'s members are checked per
// instance, so `-doc` reads the template's attributes.
written_is_public :: proc(attributes, file_attributes: []Attribute, by_default := false) -> bool {
	if has_attribute(attributes, "private") {
		return false
	}
	return has_attribute(attributes, "public") || by_default || has_attribute(file_attributes, "public")
}

// design.md `@(escape=...)`: the written level, which only a parameter carrying
// a borrow, or taking an owner by `move`, may have.
check_escape_attribute :: proc(
	k: ^Checker,
	attributes: []Attribute,
	type: Type_Id,
	span: Span,
	mode: Param_Mode,
	generic_instance: bool,
) -> Escape_Level {
	level, written, ok := attribute_escape_level(attributes)
	if !written {
		return .Result
	}
	if !ok {
		errorf(
			k.c, span, "L0648",
			"`@(escape=...)` takes one of `none`, `result`, `stored`, or `static`",
		)
		return .Result
	}
	if mode == .Borrow || mode == .Inout || mode == .Move || type == INVALID_TYPE {
		return level
	}
	// A generic signature serves bindings with and without borrows, such as
	// `Small_Array(string_view, N)` and `Small_Array(int, N)`, so it is exempt.
	// In one without, the level says nothing, and the procedure type has none.
	if generic_instance {
		return type_records_finished(k.c, type) && !type_carries_borrow(k.c, type).any ? .Result : level
	}
	if cap(k.deferred_escape_parts) == 0 {
		k.deferred_escape_parts = make([dynamic]Escape_Part, 0, 4, k.c.semantic_allocator)
	}
	append(&k.deferred_escape_parts, Escape_Part{type, span})
	return level
}

// A value parameter's type under `@(escape=...)`, and where it was written.
Escape_Part :: struct {
	type: Type_Id,
	span: Span,
}

// A signature may name a record still resolving its fields, so whether the type
// carries a borrow waits until every record has them.
check_deferred_escape_parts :: proc(k: ^Checker) {
	for part in k.deferred_escape_parts {
		if !type_carries_borrow(k.c, part.type).any {
			errorf(
				k.c, part.span, "L0648",
				"`@(escape=...)` describes what a call may keep of a borrow, and `%s` carries none",
				type_name(k.c, part.type),
			)
		}
	}
	clear(&k.deferred_escape_parts)
}

// The written `@(escape=<level>)`, a bare identifier. `valid` is false for any
// other value, which the caller reports.
@(private = "file")
attribute_escape_level :: proc(attributes: []Attribute) -> (level: Escape_Level, written: bool, valid: bool) {
	attribute, found := find_attribute(attributes, "escape")
	if !found {
		return .Result, false, true
	}
	if ident, is_ident := attribute.value.(^Expr_Ident); is_ident {
		switch ident.name {
		case "none":   return .None, true, true
		case "result": return .Result, true, true
		case "stored": return .Stored, true, true
		case "static": return .Static, true, true
		}
	}
	return .Result, true, false
}

// design.md "@(cross_thread)": an argument that crosses to another thread. A
// `move` one must be keepable for the whole process, since nothing shorter
// bounds an unstructured thread, and a procedure value carries no state of its
// own. Foreign code crosses threads unchecked, so it cannot claim the checks.
check_cross_thread_attribute :: proc(
	k: ^Checker,
	attributes: []Attribute,
	type: Type_Id,
	mode: Param_Mode,
	escape: Escape_Level,
	in_foreign: bool,
	span: Span,
) -> bool {
	if !has_attribute(attributes, "cross_thread") {
		return false
	}
	problem := ""
	switch {
	case in_foreign:
		problem = "cannot mark a foreign procedure's parameter: what foreign code hands to a thread is not checked"
	case type == INVALID_TYPE || underlying_kind(k.c, type) == .Proc:
		return type != INVALID_TYPE
	case mode == .Move && escape == .Static:
		return true
	case mode == .Move:
		problem = "on a `move` parameter needs `@(escape=static)` too: nothing shorter than the process bounds another thread"
	case:
		problem = "marks a `move` parameter or one of procedure type"
	}
	errorf(k.c, span, "L0723", "`@(cross_thread)` %s", problem)
	return false
}

// design.md "@(align=N)": `@(align=4) Name :: union {...}`, or `struct {...}`.
// Only a power of two the target supports is accepted; a written
// alignment under the natural one raises rather than lowers.
record_written_alignment :: proc(k: ^Checker, value: ^Type_Record) -> u64 {
	attribute, written := find_attribute(value.attributes, "align")
	if !written {
		return 0
	}
	if attribute.value == nil {
		errorf(k.c, attribute.span, "L0423", "`@(align=N)` needs a value")
		return 0
	}
	if check_single_expr(k, attribute.value, TYPE_INT) == INVALID_TYPE {
		return 0
	}
	folded, evaluated := require_const(k, attribute.value, "an alignment", "L0423")
	if !evaluated {
		return 0
	}
	if folded.kind != .Integer {
		errorf(k.c, attribute.span, "L0423", "`@(align=N)` needs a constant integer")
		return 0
	}
	written_align, fits := bi_to_i64(k.c, folded.integer)
	if !fits || written_align <= 0 || written_align > i64(k.c.target.max_align) ||
	   (written_align & (written_align - 1)) != 0 {
		errorf(
			k.c,
			attribute.span,
			"L0423",
			"`@(align=%s)` must be a power of two between 1 and %d",
			bi_text(k.c, folded.integer),
			k.c.target.max_align,
		)
		return 0
	}
	return u64(written_align)
}
