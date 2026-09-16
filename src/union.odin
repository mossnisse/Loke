// Unions: named variants, layout, variant construction, and the type switch.
//
// Representation: a payload region carrying the widest variant's ABI
// alignment — or the validated `@(align=N)` — followed by an `iN` tag and
// explicit padding. Variants are numbered in declaration order and the index is
// the tag, so variant 0 has tag 0 and there is no nil tag.
//
// A variant's *identity* is its declaration index, never its payload type: two
// variants may carry the same payload, which is what makes `Result(int, int)`
// a legal type rather than a duplicate-variant error.
//
// `layout.odin` remains the source of truth for size, alignment, and the tag's
// offset. The emitter builds a storage type whose LLVM-reported layout matches
// those cached facts rather than asking LLVM to infer one.
package lokec

import "core:slice"

// design.md "Unions": a discriminated union of named variants.
resolve_union_variants :: proc(k: ^Checker, type: Type_Id, value: ^Type_Record) {
	payloads := make([dynamic]Type_Id, 0, len(value.variants), k.c.semantic_allocator)
	names := make([dynamic]Identifier_Id, 0, len(value.variants), k.c.semantic_allocator)
	for variant in value.variants {
		name := intern_identifier(k.c, variant.name.text)
		if slice.contains(names[:], name) {
			errorf(
				k.c, variant.span, "L0422",
				"`%s` is already a variant of this union", variant.name.text,
			)
			continue
		}
		// A payloadless variant carries `void`, which is zero-sized and inert. It
		// is the one way `void` reaches `variants`, so it also *is* the test for
		// "payloadless" everywhere downstream.
		payload := TYPE_VOID
		if variant.type != nil {
			payload = resolve_type_syntax(k, variant.type)
			if payload == INVALID_TYPE {
				errorf(k.c, expr_span(variant.type), "L0422", "this union variant payload is not a type")
				continue
			}
			if payload == TYPE_VOID || payload == TYPE_UNTYPED_NIL {
				errorf(
					k.c, expr_span(variant.type), "L0422",
					"`%s` cannot be a union variant payload", type_name(k.c, payload),
				)
				continue
			}
		}
		append(&payloads, payload)
		append(&names, name)
	}
	info := type_of(k.c, type)
	if info == nil {
		return
	}
	info.variants = payloads[:]
	info.variant_names = names[:]
	info.written_align = record_written_alignment(k, value)
	resolve_union_zero(k, info, value)
	resolve_union_failure(k, info, value)
	// `@(packed)` on a union is rejected by the attribute table (L0607); design.md
	// applies it to a struct only.
}

// design.md "Zero values": `@(zero=name)` designates the semantic zero. Only
// the *first* variant may be named, so tag 0 plus a zero payload stays the
// all-zero representation every container, global, and allocation depends on.
@(private = "file")
resolve_union_zero :: proc(k: ^Checker, info: ^Type_Info, value: ^Type_Record) {
	attribute, written := record_attribute(value, "zero")
	if !written {
		return
	}
	name, ok := attribute_variant_name(k, attribute, "zero")
	if !ok {
		return
	}
	index := -1
	for candidate, position in info.variant_names {
		if candidate == name {
			index = position
			break
		}
	}
	if index < 0 {
		errorf(
			k.c, attribute.span, "L0423",
			"`@(zero=%s)` names no variant of this union", identifier_text(k.c, name),
		)
		return
	}
	if index != 0 {
		errorf(
			k.c, attribute.span, "L0423",
			"`@(zero=%s)` must name the first variant, so the zero value stays all-zero",
			identifier_text(k.c, name),
		)
		return
	}
	// Tag 0 alone is not the all-zero representation: the payload beside it has
	// to be all-zero too, which a no-zero payload is not.
	if payload := info.variants[0]; payload != TYPE_VOID && !type_has_zero(k.c, payload) {
		errorf(
			k.c, attribute.span, "L0423",
			"`@(zero=%s)` needs an all-zero payload, and `%s` has no zero value",
			identifier_text(k.c, name), type_name(k.c, payload),
		)
		return
	}
	info.zero_designated = true
}

// design.md "The failure protocol and `@(failure=)`": `@(failure=name)`
// designates one of exactly two variants as the failure one.
// `or_else`/`or_return` recognise the shape, never a privileged type name.
@(private = "file")
resolve_union_failure :: proc(k: ^Checker, info: ^Type_Info, value: ^Type_Record) {
	attribute, written := record_attribute(value, "failure")
	if !written {
		return
	}
	name, ok := attribute_variant_name(k, attribute, "failure")
	if !ok {
		return
	}
	index := -1
	for candidate, position in info.variant_names {
		if candidate == name {
			index = position
			break
		}
	}
	if index < 0 {
		errorf(
			k.c, attribute.span, "L0423",
			"`@(failure=%s)` names no variant of this union", identifier_text(k.c, name),
		)
		return
	}
	if len(info.variants) != 2 {
		errorf(
			k.c, attribute.span, "L0423",
			"`@(failure=...)` needs a union of exactly two variants, found %d",
			len(info.variants),
		)
		return
	}
	info.failure_designated = true
	info.failure_variant = index
}

// The attribute's value is a bare variant name, so it is read rather than
// checked as an expression: the name lives in the union's own variant list and
// resolves against no scope.
@(private = "file")
attribute_variant_name :: proc(k: ^Checker, attribute: Attribute, what: string) -> (Identifier_Id, bool) {
	ident, is_ident := attribute.value.(^Expr_Ident)
	if !is_ident {
		errorf(k.c, attribute.span, "L0423", "`@(%s=name)` needs a variant name", what)
		return INVALID_IDENTIFIER, false
	}
	return intern_identifier(k.c, ident.name), true
}

@(private = "file")
record_attribute :: proc(value: ^Type_Record, name: string) -> (Attribute, bool) {
	for attribute in value.attributes {
		if len(attribute.path) == 1 && attribute.path[0].text == name {
			return attribute, true
		}
	}
	return Attribute{}, false
}

// design.md "@(packed)": whether a struct/union literal carries the tag.
record_is_packed :: proc(value: ^Type_Record) -> bool {
	_, written := record_attribute(value, "packed")
	return written
}

// design.md "@(align=N)": `union @(align=4) {...}` and `struct @(align=4)
// {...}`. Only a power of two the target supports is accepted; a written
// alignment under the natural one raises rather than lowers.
record_written_alignment :: proc(k: ^Checker, value: ^Type_Record) -> u64 {
	attribute, written := record_attribute(value, "align")
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
	if !evaluated || folded.kind != .Integer {
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

// The layout facts the checker and the emitter share. Computed from the cached
// per-variant layout, never from LLVM's own idea of a struct.
Union_Layout :: struct {
	payload_size:  u64,
	align:         u64,
	tag_offset:    u64,
	tag_bytes:     u64,
	size:          u64,
}

union_layout :: proc(c: ^Compiler, type: Type_Id) -> Union_Layout {
	info := type_of(c, type)
	if info == nil || info.kind != .Union {
		return Union_Layout{align = 1, tag_bytes = 1, size = 1}
	}
	out := Union_Layout{align = 1}
	for variant in info.variants {
		out.payload_size = max(out.payload_size, type_size(c, variant))
		out.align = max(out.align, type_align(c, variant))
	}
	// `resolve_union_variants` parks a validated `@(align=N)` here, and it may
	// only raise the alignment.
	info = type_of(c, type)
	out.align = max(out.align, info.written_align)
	out.tag_bytes = union_tag_bytes(len(info.variants))
	// The tag is a member like any other, so a tag wider than every payload
	// raises the union's alignment. Only a union of many payloadless or very
	// narrow variants reaches that.
	out.align = max(out.align, out.tag_bytes)
	out.payload_size = align_to(out.payload_size, out.align)
	out.tag_offset = align_to(out.payload_size, out.tag_bytes)
	out.size = align_to(out.tag_offset + out.tag_bytes, out.align)
	return out
}

// The narrowest tag representing `0 ..< variant_count`. 256 variants still fit
// in one byte; 257 need two. An empty union keeps the minimum one byte.
union_tag_bytes :: proc(variants: int) -> u64 {
	switch {
	case variants <= 256:
		return 1
	case variants <= 65536:
		return 2
	}
	return 4
}

align_to :: proc(value, alignment: u64) -> u64 {
	if alignment <= 1 {
		return value
	}
	return (value + alignment - 1) / alignment * alignment
}

// A variant's declaration index, which is also its tag. -1 when the union has
// no variant with that name.
union_variant_index :: proc(c: ^Compiler, union_type: Type_Id, name: Identifier_Id) -> int {
	info := type_of(c, type_underlying(c, union_type))
	if info == nil {
		return -1
	}
	for candidate, index in info.variant_names {
		if candidate == name {
			return index
		}
	}
	return -1
}

// The payload type of variant `index`, or `TYPE_VOID` when it is payloadless.
union_variant_payload :: proc(c: ^Compiler, union_type: Type_Id, index: int) -> Type_Id {
	info := type_of(c, type_underlying(c, union_type))
	if info == nil || index < 0 || index >= len(info.variants) {
		return INVALID_TYPE
	}
	return info.variants[index]
}

union_variant_name :: proc(c: ^Compiler, union_type: Type_Id, index: int) -> string {
	info := type_of(c, type_underlying(c, union_type))
	if info == nil || index < 0 || index >= len(info.variant_names) {
		return "?"
	}
	return identifier_text(c, info.variant_names[index])
}

type_is_union :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type_kind(c, type) == .Union
}

// ------------------------------------------------------ variant construction --

// `U.name` / `.name` naming a variant of `subject`. A payloadless variant is a
// complete compile-time constant; a payload variant is only half a value, and
// `check_union_construct` finishes it from the call's argument.
//
// Returns false when `subject` is not a union or has no such variant, so every
// other selector keeps its ordinary meaning.
check_union_variant_selector :: proc(k: ^Checker, sel: ^Expr_Selector, subject: Type_Id) -> bool {
	if subject == INVALID_TYPE || !type_is_union(k.c, type_underlying(k.c, subject)) {
		return false
	}
	index := union_variant_index(k.c, subject, intern_identifier(k.c, sel.name.text))
	if index < 0 {
		return false
	}
	sel.value_category = .Value
	sel.type = subject
	sel.variant_union = subject
	sel.variant_index = index
	// A `Unit` payload has one value, so outside a call the bare `.ok` is already
	// complete: payloadless and `Unit`-carrying variants are spelled alike.
	payload := union_variant_payload(k.c, subject, index)
	unit_payload := payload == k.c.unit_type && !k.in_callee
	if payload != TYPE_VOID && !unit_payload {
		sel.resolution = Resolution{kind = .Union_Variant}
		return true
	}
	payload_value := Const_Value{}
	if unit_payload {
		payload_value, _ = zero_const(k.c, payload)
	}
	sel.resolution = Resolution{kind = .Builtin_Operator}
	sel.is_const = true
	sel.immutable = .Constant
	sel.const_value = union_const(k.c, subject, index, payload_value)
	return true
}

// design.md "Unions": `U.name(payload)` and the contextual `.name(payload)`,
// entered once the callee selector resolved to a payload variant.
check_union_construct :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) {
	subject, index := sel.variant_union, sel.variant_index
	payload := union_variant_payload(k.c, subject, index)
	v.value_category = .Value
	v.operation = Call_Union_Construct{index = index}
	v.resolution = Resolution{kind = .Builtin_Operator}
	v.type = subject

	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value ||
	   v.args[0].value == nil {
		errorf(
			k.c, v.span, "L0425",
			"`%s.%s` takes exactly one payload argument, found %d",
			type_name(k.c, subject), sel.name.text, len(v.args),
		)
		v.type = INVALID_TYPE
		return
	}
	// Record-field initialization rules: a place argument clones and must be
	// copyable, a temporary or `move(x)` transfers.
	if !check_value_expr(k, v.args[0].value, payload, "supply") {
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
	// Variant construction is aggregate construction: `.some(x)` where `x` names a
	// place leaves that place owning its value, so the variant receives a clone.
	classify_copy_cost(k, v.args[0].value, payload, .Variant)
	v.operation = Call_Union_Construct{
		index = index,
		clone = classify_copy(k, v.args[0].value, payload, .Variant),
	}

	// design.md "Zero values": explicit constant variant construction is
	// permitted at static duration when its payload is constant.
	if inner := expr_base(v.args[0].value); inner != nil && inner.is_const &&
	   variant_payload_is_constant(k.c, payload, inner.const_value) {
		v.is_const = true
		v.const_value = union_const(k.c, subject, index, inner.const_value)
	}
}

// Whether this constant has a complete target byte image. Text values contain
// relocatable pointers and therefore keep using their ordinary typed LLVM
// constants; scalars and recursively byte-serializable aggregates can live in
// a union's inline payload storage.
variant_payload_is_constant :: proc(c: ^Compiler, payload: Type_Id, value: Const_Value) -> bool {
	if payload == TYPE_VOID || type_size(c, payload) == 0 || value.kind == .Invalid || value.kind == .Nil {
		return true
	}
	info := type_of(c, type_underlying(c, payload))
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Bool, .Int, .Enum, .Rune, .Float, .Typeid, .Allocator_Error:
		return true
	case .Array:
		if value.aggregate == nil {
			return false
		}
		for index in 0 ..< int(info.count) {
			element := index < len(value.aggregate.elements) ? value.aggregate.elements[index] : Const_Value{}
			if !variant_payload_is_constant(c, info.element, element) {
				return false
			}
		}
		return true
	case .Struct:
		if value.aggregate == nil {
			return false
		}
		for field, index in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil {
				return false
			}
			element := index < len(value.aggregate.elements) ? value.aggregate.elements[index] : Const_Value{}
			if !variant_payload_is_constant(c, symbol.type, element) {
				return false
			}
		}
		return true
	case .Union:
		if value.aggregate == nil || value.aggregate.variant < 0 || value.aggregate.variant >= len(info.variants) {
			return false
		}
		element := len(value.aggregate.elements) > 0 ? value.aggregate.elements[0] : Const_Value{}
		return variant_payload_is_constant(c, info.variants[value.aggregate.variant], element)
	}
	return false
}

// A payloadless variant selector used where a payload one was needed, or the
// reverse: one diagnostic each, raised where the shape is finally known.
reject_incomplete_variant :: proc(k: ^Checker, sel: ^Expr_Selector) {
	errorf(
		k.c, sel.span, "L0425",
		"`%s.%s` carries a payload: write `%s(value)`",
		type_name(k.c, sel.variant_union), sel.name.text, sel.name.text,
	)
}

union_const :: proc(c: ^Compiler, union_type: Type_Id, index: int, payload: Const_Value) -> Const_Value {
	aggregate := new(Const_Aggregate, c.semantic_allocator)
	aggregate.type = union_type
	aggregate.variant = index
	elements := make([]Const_Value, 1, c.semantic_allocator)
	elements[0] = payload
	aggregate.elements = elements
	return Const_Value{kind = .Aggregate, aggregate = aggregate}
}

// The declaration index of a variant named in compiler-owned code. The names
// come from `base:runtime`'s own declarations, so nothing here hard-codes a
// tag: renaming `some` in the source renames it everywhere.
union_index_of :: proc(c: ^Compiler, union_type: Type_Id, name: string) -> int {
	return union_variant_index(c, union_type, intern_identifier(c, name))
}

variant_count :: proc(c: ^Compiler, union_type: Type_Id) -> int {
	info := type_of(c, type_underlying(c, union_type))
	return info == nil ? 0 : len(info.variants)
}
