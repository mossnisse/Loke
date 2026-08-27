// Unions: variants, layout, checked extractions, and the type switch.
//
// Representation: a payload region carrying the widest variant's ABI
// alignment — or the validated `@(align=N)` — followed by an `iN` tag and
// explicit padding. Tag 0 is nil; variants are numbered in declaration
// order, so variant `i` has tag `i + 1`.
//
// `layout.odin` remains the source of truth for size, alignment, and the tag's
// offset. The emitter builds a storage type whose LLVM-reported layout matches
// those cached facts rather than asking LLVM to infer one.
package lokec

// `value.active_typeid()` exposes the active runtime variant without extracting
// its payload. The nil union maps to the nil `typeid` (zero); every concrete
// variant maps to the same deterministic id as `typeid_of(Variant)`.
check_union_operation :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	if sel.name.text != "active_typeid" {
		return false
	}
	// Keep an ordinary method with this name available on non-union types without
	// checking its receiver twice.
	if ident, is_ident := sel.operand.(^Expr_Ident); is_ident {
		sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
		if sym != nil && sym.kind != .Type && !type_is_union(k.c, sym.type) {
			return false
		}
	}

	operand := check_single_expr(k, sel.operand)
	if operand == INVALID_TYPE || !type_is_union(k.c, operand) {
		return false
	}

	v.value_category = .Value
	v.union_op = .Active_Typeid
	v.resolution = Resolution{kind = .Builtin_Operator}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = sel.operand
	v.bound = bound
	if len(v.args) != 0 {
		errorf(k.c, v.span, "L0425", "`active_typeid` takes no arguments, found %d", len(v.args))
		v.type = INVALID_TYPE
		return true
	}

	info := type_of(k.c, operand)
	if info == nil {
		v.type = INVALID_TYPE
		return true
	}
	for variant in info.variants {
		request_typeid(k.c, variant)
	}
	v.type = TYPE_TYPEID
	return true
}

// design.md "Checked extractions": `value.as(T)` is the optional spelling. It
// is written with selector/call syntax but is not a call — it resolves to the
// same `Expr_Checked_Extract` `value.(T)` produces, so the flow graph, the
// evaluator, and the emitter keep one extraction path rather than two.
//
// `as` is a name users choose, so the receiver's *type* decides which meaning
// applies: a union or `any_view` takes the built-in, and every other type keeps
// its declared member. Resolving the receiver first is what makes that true for
// `f().as(T)`, `a.b.as(T)`, and `xs[0].as(T)` as well as for a plain name.
check_union_extract :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	if sel.name.text != "as" {
		return false
	}
	// A package selector names a declaration, not a value receiver.
	if ident, ok := sel.operand.(^Expr_Ident); ok {
		if sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident))); sym != nil &&
		   sym.kind == .Package_Alias {
			return false
		}
	}
	operand := check_single_expr(k, sel.operand)
	if operand != TYPE_ANY_VIEW && !type_is_union(k.c, operand) {
		return false
	}

	v.value_category = .Value
	v.union_op = .Extract
	v.resolution = Resolution{kind = .Builtin_Operator}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = sel.operand
	v.bound = bound

	// Exactly one positional type argument, which is the extraction's target.
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value ||
	   v.args[0].value == nil {
		errorf(
			k.c, v.span, "L0425",
			"`as` names the requested type as its one positional argument, found %d argument%s",
			len(v.args), len(v.args) == 1 ? "" : "s",
		)
		v.type = INVALID_TYPE
		return true
	}

	extract := new(Expr_Checked_Extract, k.c.semantic_allocator)
	extract.span = v.span
	extract.operand = sel.operand
	extract.target = v.args[0].value
	extract.mode = .Optional
	v.extract = extract

	check_extract_of(k, extract, operand)
	v.type = extract.type
	v.result_types = extract.result_types
	return true
}

// design.md "Unions": a discriminated union whose zero value is nil.
resolve_union_variants :: proc(k: ^Checker, type: Type_Id, value: ^Type_Record) {
	variants := make([dynamic]Type_Id, 0, len(value.variants), k.c.semantic_allocator)
	for variant in value.variants {
		resolved := resolve_type_syntax(k, variant)
		if resolved == INVALID_TYPE {
			errorf(k.c, expr_span(variant), "L0422", "this union variant is not a type")
			continue
		}
		if resolved == TYPE_VOID || resolved == TYPE_UNTYPED_NIL {
			errorf(k.c, expr_span(variant), "L0422", "`%s` cannot be a union variant", type_name(k.c, resolved))
			continue
		}
		duplicate := false
		for existing in variants {
			if existing == resolved {
				errorf(k.c, expr_span(variant), "L0422", "`%s` is already a variant of this union", type_name(k.c, resolved))
				duplicate = true
				break
			}
		}
		if !duplicate {
			append(&variants, resolved)
		}
	}
	if len(variants) == 0 {
		errorf(k.c, value.span, "L0422", "a union needs at least one variant")
	}
	info := type_of(k.c, type)
	if info == nil {
		return
	}
	info.variants = variants[:]
	info.written_align = record_written_alignment(k, value)
	// `@(packed)` on a union is rejected by the attribute table (L0607); design.md
	// applies it to a struct only (m7-plan step 2).
}

// design.md "@(packed)": whether a struct/union literal carries the tag.
record_is_packed :: proc(value: ^Type_Record) -> bool {
	for attribute in value.attributes {
		if len(attribute.path) == 1 && attribute.path[0].text == "packed" {
			return true
		}
	}
	return false
}

// design.md "@(align=N)": `union @(align=4) {...}` and `struct @(align=4) {...}`.
// Only a power of two the target supports is accepted; a written alignment under
// the natural one raises rather than lowers (m7-plan decision on layout).
record_written_alignment :: proc(k: ^Checker, value: ^Type_Record) -> u64 {
	for attribute in value.attributes {
		if len(attribute.path) != 1 || attribute.path[0].text != "align" {
			continue
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
		written, fits := bi_to_i64(k.c, folded.integer)
		if !fits || written <= 0 || written > i64(k.c.target.max_align) || (written & (written - 1)) != 0 {
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
		return u64(written)
	}
	return 0
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
	out.payload_size = align_to(out.payload_size, out.align)
	out.tag_offset = align_to(out.payload_size, out.tag_bytes)
	out.size = align_to(out.tag_offset + out.tag_bytes, out.align)
	return out
}

// The narrowest tag that holds nil plus every variant.
union_tag_bytes :: proc(variants: int) -> u64 {
	switch {
	case variants < 255:
		return 1
	case variants < 65535:
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

// The tag a variant carries. Tag 0 is nil, so the first written variant is 1.
union_variant_tag :: proc(c: ^Compiler, union_type, variant: Type_Id) -> int {
	info := type_of(c, union_type)
	if info == nil {
		return -1
	}
	for candidate, index in info.variants {
		if candidate == variant {
			return index + 1
		}
	}
	return -1
}

type_is_union :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type_kind(c, type) == .Union
}

// Is `variant` one of this union's variants? A union is not assignable from an
// arbitrary value, only from something it can actually hold.
union_holds :: proc(c: ^Compiler, union_type, variant: Type_Id) -> bool {
	return union_variant_tag(c, union_type, variant) > 0
}

// Does this constant put a non-nil variant into a union, anywhere inside it?
//
// The only union constant is its zero value: writing the tag needs code, and a
// file-scope initialiser has none. Diagnosing it is what keeps a global from
// silently starting at nil when the source says otherwise.
const_holds_live_union :: proc(c: ^Compiler, value: Const_Value, type: Type_Id, depth := 0) -> bool {
	if depth > 32 {
		return false
	}
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Union:
		return value.kind != .Nil && value.kind != .Invalid
	case .Array:
		if value.aggregate == nil {
			return false
		}
		for element in value.aggregate.elements {
			if const_holds_live_union(c, element, info.element, depth + 1) {
				return true
			}
		}
	case .Struct:
		if value.aggregate == nil {
			return false
		}
		for field, index in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil || index >= len(value.aggregate.elements) {
				continue
			}
			if const_holds_live_union(c, value.aggregate.elements[index], symbol.type, depth + 1) {
				return true
			}
		}
	}
	return false
}
