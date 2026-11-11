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
	Member,  // a member of a file-scope `impl` block
}

Attr_Shape :: enum {
	None,           // `@(name)`
	Value_Required, // `@(name="...")`
	Deferred,       // the owning feature validates the value
}

Attr_Spec :: struct {
	positions:     bit_set[Attr_Pos],
	shape:         Attr_Shape,
	barred_scopes: bit_set[Attr_Scope],
}

// design.md "Attributes" and "Layout and ABI attributes". A switch rather than a
// map, so the lookup allocates nothing and shares nothing between compilers.
attribute_spec :: proc(name: string) -> (Attr_Spec, bool) {
	switch name {
	case "public":
		return {{.Package_Clause, .Proc_Decl, .Proc_Group, .Var_Decl, .Const_Decl, .Type_Decl, .Struct_Decl, .Union_Decl, .Struct_Field, .Foreign_Block}, .None, {.Local}}, true
	case "private":
		return {{.Proc_Decl, .Proc_Group, .Var_Decl, .Const_Decl, .Type_Decl, .Struct_Decl, .Union_Decl, .Struct_Field, .Foreign_Block}, .None, {.Local}}, true
	case "default_allocator", "default_logger":
		// Also read before import discovery by `collect_source_provider_defaults`.
		return {{.Package_Clause}, .Value_Required, {}}, true
	case "subsystem":
		// Where is `validate_root_only_attributes`', how often
		// `validate_subsystem_attributes`'.
		return {{.Package_Clause}, .Value_Required, {}}, true
	case "require_results":
		return {{.Proc_Decl, .Proc_Group, .Foreign_Block, .Type_Decl, .Struct_Decl, .Union_Decl}, .None, {}}, true
	case "deprecated":
		return {{.Proc_Decl}, .Value_Required, {}}, true
	case "cold":
		// design.md "@(cold)": a foreign declaration has no body to mark.
		return {{.Proc_Decl}, .None, {.Foreign}}, true
	case "cpu_dispatch":
		// Which procedures may carry it is `validate_cpu_dispatch`'.
		return {{.Proc_Decl}, .Value_Required, {.Local, .Foreign, .Member}}, true
	case "test":
		// design.md "Test procedures": declared at file scope. Its other rules are
		// `check_test_procedures`'.
		return {{.Proc_Decl}, .None, {.Local, .Foreign, .Member}}, true
	case "export":
		// design.md "@(export)": a foreign declaration has no definition to emit.
		return {{.Proc_Decl, .Var_Decl}, .None, {.Local, .Foreign}}, true
	case "link_name":
		return {{.Proc_Decl, .Var_Decl}, .Value_Required, {.Local}}, true
	case "default_calling_convention":
		return {{.Foreign_Block}, .Value_Required, {}}, true
	case "allocator_reset", "by_ptr", "c_vararg":
		return {{.Parameter}, .None, {}}, true
	case "escape":
		// A bare level identifier, checked by `check_escape_attribute`.
		return {{.Parameter}, .Deferred, {}}, true
	case "packed", "positional":
		return {{.Struct_Decl}, .None, {}}, true
	case "align":
		return {{.Struct_Decl, .Union_Decl}, .Deferred, {}}, true
	case "initialized":
		// A sibling field name, checked by `resolve_uninitialized_fields`.
		return {{.Struct_Field}, .Deferred, {}}, true
	case "required":
		return {{.Struct_Field}, .None, {}}, true
	case "synchronized":
		// Which variables may carry it is `validate_decl_attributes`'.
		return {{.Struct_Field, .Var_Decl}, .None, {}}, true
	case "move_only", "thread_affine", "wakes_on_drop":
		return {{.Struct_Decl, .Union_Decl}, .None, {}}, true
	case "fieldwise_copy":
		// What the record must be is `check_copy_decision`'.
		return {{.Struct_Decl}, .None, {}}, true
	case "cross_thread":
		// What the parameter must be is `check_cross_thread_attribute`'.
		return {{.Parameter}, .None, {}}, true
	case "intrinsic":
		// Bound by `src/intrinsic.odin`, which validates the declaration's other
		// attributes; one reaching the ordinary pass is misplaced.
		return {{.Proc_Decl, .Type_Decl, .Struct_Decl, .Union_Decl}, .None, {}}, true
	case "zero", "failure":
		// A variant name, checked in `src/union.odin`.
		return {{.Union_Decl}, .Deferred, {}}, true
	}
	return {}, false
}

// How a diagnostic names each position and scope.
@(private = "file", rodata)
ATTR_POS_NAMES := [Attr_Pos]string {
	.Package_Clause = "a package clause",
	.Import         = "an import",
	.Proc_Decl      = "a procedure declaration",
	.Proc_Group     = "a procedure group",
	.Var_Decl       = "a variable declaration",
	.Const_Decl     = "a constant declaration",
	.Type_Decl      = "a type declaration",
	.Struct_Field   = "a struct field",
	.Parameter      = "a parameter",
	.Struct_Decl    = "a struct declaration",
	.Union_Decl     = "a union declaration",
	.Foreign_Block  = "a foreign block",
	.Static_Assert  = "a `static_assert`",
	.Delegate       = "a `delegate`",
	.Impl           = "an `impl` block",
	.Statement      = "a statement",
}

@(private = "file", rodata)
ATTR_SCOPE_NAMES := [Attr_Scope]string {
	.Global  = "a file-scope declaration",
	.Local   = "a local declaration",
	.Foreign = "a foreign declaration",
	.Member  = "an `impl` member",
}

// Reports each misuse in one attribute list, once per written list: generic
// instances and static foreach copies share the spans, so they are skipped.
validate_attribute_list :: proc(
	k: ^Checker,
	attributes: []Attribute,
	pos: Attr_Pos,
	scope := Attr_Scope.Global,
	duration := Duration.None,
	allow_intrinsic := false,
) {
	if len(attributes) == 0 {
		return
	}
	// A speculative check discards its diagnostics, so it must not claim the list.
	if committing(k.c) {
		key := span_key(attributes[0].span)
		if k.c.validated_attributes[key] {
			return
		}
		k.c.validated_attributes[key] = true
	}
	for attribute, index in attributes {
		if len(attribute.path) == 0 {
			continue
		}
		// No toolchain extension is currently enabled.
		if len(attribute.path) > 1 {
			names := make([]string, len(attribute.path), context.temp_allocator)
			for part, part_index in attribute.path {
				names[part_index] = part.text
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
		if has_attribute(attributes[:index], name) {
			errorf(k.c, attribute.span, "L0609", "`@(%s)` is written more than once here", name)
			continue
		}
		if name == "intrinsic" && !allow_intrinsic {
			report_misplaced_intrinsic(k, attribute.span)
			continue
		}
		if pos not_in spec.positions {
			errorf(k.c, attribute.span, "L0607", "`@(%s)` cannot appear on %s", name, ATTR_POS_NAMES[pos])
			continue
		}
		if scope in spec.barred_scopes {
			errorf(k.c, attribute.span, "L0607", "`@(%s)` cannot appear on %s", name, ATTR_SCOPE_NAMES[scope])
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
			} else if name == "link_name" {
				// design.md "`@(link_name=<string>)`".
				if text, _ := attribute_string_text(k.c, attribute); text == "" {
					errorf(k.c, attribute.span, "L0608", "`@(link_name)` needs a symbol name, not an empty string")
				}
			}
		case .Deferred:
		}
		if name == "synchronized" && pos == .Var_Decl {
			validate_synchronized_variable(k, attribute, scope, duration)
		}
	}
	// design.md "@(link_name=<string>)": it names an exported or foreign symbol.
	if (scope == .Global || scope == .Member) && (pos == .Proc_Decl || pos == .Var_Decl) && !has_attribute(attributes, "export") {
		if attribute, named := find_attribute(attributes, "link_name"); named {
			errorf(
				k.c, attribute.span, "L0607",
				"`@(link_name)` names a linked symbol, so it needs `@(export)` outside a foreign block",
			)
		}
	}
}

// The whole-package pass. Record fields and parameters nested anywhere are also
// validated where they resolve (`resolve_type_syntax`, the signatures).
validate_attributes :: proc(k: ^Checker, pkg: ^Package) {
	for file in pkg.files {
		k.file, k.file_node = file.file, file
		validate_attribute_list(k, file.attributes, .Package_Clause)
		validate_root_only_attributes(k, pkg, file)
		validate_item_attributes(k, file.items)
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				validate_decl_attributes(k, v)
			case ^Item_Impl:
				validate_impl_attributes(k, v, .Member)
			case ^Item_Static_Assert:
				validate_attribute_list(k, v.attributes, .Static_Assert)
			case ^Item_Foreign_Block:
				validate_attribute_list(k, v.attributes, .Foreign_Block)
				for d in v.members {
					validate_decl_attributes(k, d, .Foreign)
				}
			}
		}
	}
	validate_subsystem_attributes(k, pkg)
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

// `scope` is `.Local` for a body-local block, whose members can be no more than
// any other local.
validate_impl_attributes :: proc(k: ^Checker, item: ^Item_Impl, scope: Attr_Scope) {
	validate_attribute_list(k, item.attributes, .Impl)
	for member in item.members {
		#partial switch m in member {
		case ^Decl:
			validate_decl_attributes(k, m, scope)
		case ^Item_Delegate:
			validate_attribute_list(k, m.attributes, .Delegate)
		}
	}
}

validate_decl_attributes :: proc(k: ^Checker, d: ^Decl, scope := Attr_Scope.Global) {
	// Binding an `@(intrinsic)` member already validated it.
	if len(d.symbols) == 0 && decl_is_intrinsic(d) {
		return
	}
	validate_attribute_list(k, d.attributes, decl_attr_position(k, d), scope, d.duration)
	if scope == .Global {
		validate_cpu_dispatch(k, d)
	}
	// design.md "@(require_results)": a property of a value's type, and no value
	// has an interface's type.
	if attribute, found := find_attribute(d.attributes, "require_results"); found && len(d.values) == 1 {
		if _, is_interface := d.values[0].(^Type_Interface); is_interface {
			errorf(k.c, attribute.span, "L0607", "`@(require_results)` cannot appear on an interface")
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

// design.md "@(synchronized)".
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

// design.md "@(cpu_dispatch=<string>)".
@(private = "file")
validate_cpu_dispatch :: proc(k: ^Checker, d: ^Decl) {
	attribute, written := find_attribute(d.attributes, "cpu_dispatch")
	literal := decl_proc_literal(d)
	if !written || literal == nil || decl_attr_position(k, d) != .Proc_Decl {
		return
	}
	reason := ""
	switch {
	case proc_signature_is_generic(literal):
		reason = "a generic procedure"
	case convention_is_foreign(literal.signature.convention):
		reason = "a procedure with a foreign calling convention"
	}
	if reason != "" {
		errorf(k.c, attribute.span, "L0739", "`@(cpu_dispatch)` cannot mark %s", reason)
		return
	}
	if text, ok := attribute_string_text(k.c, attribute); ok {
		if _, known := dispatch_cpu_level(text); !known {
			errorf(
				k.c, attribute.span, "L0739",
				"`@(cpu_dispatch)` names a CPU level above baseline, `x86-64-v2` or `x86-64-v3`; found `%s`", text,
			)
		}
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
	// A generic `impl`'s member has symbols only in its instances. Whether a bare
	// name there is a type or a constant is unknown, and a type allows more: its
	// instances say (`validate_instance_member_position`).
	if len(d.symbols) == 0 {
		if decl_proc_literal(d) != nil {
			return .Proc_Decl
		}
		if len(d.values) == 1 {
			#partial switch _ in d.values[0] {
			case ^Expr_Proc_Group:
				return .Proc_Group
			case ^Expr_Literal, ^Expr_Binary, ^Expr_Unary:
				return .Const_Decl
			}
			return d.declared_type != nil ? .Const_Decl : .Type_Decl
		}
		return .Var_Decl
	}
	if sym := symbol_of(k.c, d.symbols[0]); sym != nil {
		#partial switch sym.kind {
		case .Proc:       return .Proc_Decl
		case .Proc_Group: return .Proc_Group
		case .Type:       return .Type_Decl
		}
	}
	return d.kind == .Const ? .Const_Decl : .Var_Decl
}

// A generic `impl`'s member reads as what its template's syntax allows, which is
// more than what an instance finds a bare name to be (`decl_attr_position`). Every
// instance sees the same, and a repeated report is shown once.
validate_instance_member_position :: proc(k: ^Checker, d: ^Decl) {
	position := decl_attr_position(k, d)
	for attribute in d.attributes {
		if len(attribute.path) != 1 {
			continue
		}
		if spec, known := attribute_spec(attribute.path[0].text); known && position not_in spec.positions {
			errorf(k.c, attribute.span, "L0607", "`@(%s)` cannot appear on %s", attribute.path[0].text, ATTR_POS_NAMES[position])
		}
	}
}

// Runs while the signature resolves, so a use in another package already sees
// these.
apply_proc_metadata :: proc(k: ^Checker, d: ^Decl, symbol_id: Symbol_Id) {
	sym := symbol_of(k.c, symbol_id)
	for attribute in d.attributes {
		if len(attribute.path) != 1 {
			continue
		}
		switch attribute.path[0].text {
		case "deprecated":
			sym.deprecated = true
			if text, ok := attribute_string_text(k.c, attribute); ok {
				sym.deprecated_message = text
			}
		case "require_results":
			sym.require_results = true
		case "cpu_dispatch":
			if text, ok := attribute_string_text(k.c, attribute); ok && sym.kind == .Proc {
				sym.dispatch_cpu, _ = dispatch_cpu_level(text)
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

attribute_string_value :: proc(c: ^Compiler, attributes: []Attribute, name: string) -> (string, bool) {
	attribute, written := find_attribute(attributes, name)
	if !written {
		return "", false
	}
	return attribute_string_text(c, attribute)
}

// An attribute's value, when that is a string literal, decoded.
attribute_string_text :: proc(c: ^Compiler, attribute: Attribute) -> (string, bool) {
	lit, ok := attribute.value.(^Expr_Literal)
	if !ok || (lit.kind != .String && lit.kind != .Raw_String) {
		return "", false
	}
	return decode_string_literal(c, lit.text, lit.kind == .Raw_String)
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

// Whether an importer can name a field: a public one, but not padding. A generic
// record's fields are checked per instance, and an untaken `when` branch's not at
// all, so those take their visibility from what is written.
field_is_exported :: proc(c: ^Compiler, file: ^File, field: ^Field) -> bool {
	for name, index in field.names {
		if name.text == "_" {
			continue
		}
		if index >= len(field.symbols) {
			return written_is_public(field.attributes, file.attributes, file.package_name == "main")
		}
		symbol := symbol_of(c, field.symbols[index])
		return symbol != nil && symbol.public
	}
	return false
}

// Whether an importer can name `d`. A declaration no symbol records, in an
// untaken `when` branch or a generic `impl`, which is checked per instance,
// takes its visibility from its written attributes, as the checker would.
decl_is_public :: proc(c: ^Compiler, file: ^File, d: ^Decl, block: []Attribute = nil) -> bool {
	if d.names[0].text == "_" {
		return false
	}
	if len(d.symbols) > 0 {
		symbol := symbol_of(c, d.symbols[0])
		return symbol != nil && symbol.public && !symbol_is_test(symbol)
	}
	if d.kind == .Var || has_attribute(d.attributes, "test") {
		return false
	}
	return written_is_public(d.attributes, has_attribute(block, "private") ? nil : file.attributes, has_attribute(block, "public"))
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
