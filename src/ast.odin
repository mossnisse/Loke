// AST. Every node carries a Span, and the checker annotates the nodes in place
// (compiler-architecture.md "One annotated AST"). Types and expressions share one
// node domain, since the grammar cannot tell `Matrix(f32, 4)` from `f(a, b)`;
// `parse_type` restricts type positions, and the checker decides what syntax
// cannot.
package lokec

import "core:mem/virtual"

Expr_Base :: struct {
	span:          Span,
	type:          Type_Id,
	denoted_type:  Type_Id, // non-zero when this expression denotes a type
	// `.Invalid` when the expression is not constant, or its constant failed.
	const_value:   Const_Value,
	resolution:    Resolution,
	value_category: Value_Category,
	// Independent place facts: a value parameter is addressable, not assignable.
	addressable:  bool,
	assignable:   bool,
	immutable:    Immutable_Reason,
	// The concrete type a `dyn` view that `type` names was made from, at a
	// `..dyn I` pack or as a `dyn proc`.
	erased_from: Type_Id,
	// A `string` borrowed as a `string_view`, or a `[dynamic]T` as a `[]T`: the
	// source type to narrow from.
	view_from:   Type_Id,
	// A scalar widened to a SIMD vector: the lane type to splat from.
	splat_from:  Type_Id,
	// An anonymous union widened by label: the smaller union to remap from. A
	// copy site clones at this type before remapping.
	widened_from: Type_Id,
	// A copy site's source: the type a copy of this place clones at, which may
	// run `hook(copy)`.
	copied_as:   Type_Id,
	// A borrowed temporary its statement extends to the block's end, or a node on
	// the way to it (`mark_extended_temporaries`).
	extended:    bool,
	// This node or any child is an error node.
	has_error:   bool,
}

// Literals keep their spelling; the checker decides whether a value fits.
Literal_Kind :: enum {
	Int,
	Float,
	String,
	Raw_String,
	Rune,
}

Expr :: union {
	^Expr_Error,
	^Expr_Literal,
	^Expr_Ident,
	^Expr_Selector,
	^Expr_Index,
	^Expr_Slice,
	^Expr_Call,
	^Expr_Postfix,
	^Expr_Propagated_Error,
	^Expr_Unary,
	^Expr_Binary,
	^Expr_Range,
	^Expr_Or_Else,
	^Expr_Cond,
	^Expr_Move,
	^Expr_Composite,
	^Expr_Proc,
	^Expr_Proc_Group,
	^Expr_Operator,

	// Type forms. Named types are `Expr_Ident` / `Expr_Selector`; a generic
	// application is an `Expr_Call`.
	^Type_Pointer,
	^Type_C_Pointer,
	^Type_Slice,
	^Type_Dynamic_Array,
	^Type_Array,
	^Type_Map,
	^Type_Distinct,
	^Type_Dyn,
	^Type_Type,
	^Type_Poly,
	^Type_Proc,
	^Type_Record,
	^Type_Anon_Record,
	^Type_Anon_Union,
	^Type_Enum,
	^Type_Interface,
}

// Error nodes, rather than nil, keep the surrounding syntax after recovery.
Expr_Error :: struct {
	using base: Expr_Base,
}

Expr_Literal :: struct {
	using base: Expr_Base,
	kind:       Literal_Kind,
	text:       string, // the spelling, source-backed
}

Expr_Ident :: struct {
	using base: Expr_Base,
	name:       string,
	name_id:    Identifier_Id,
	symbol:     Symbol_Id,
}

// `a.b`, and the implicit-selector primary `.Member` when `operand` is nil.
Expr_Selector :: struct {
	using base: Expr_Base,
	operand:    Expr,
	name:       Name,
	// A selected union variant: the union and the variant's index.
	variant_union: Type_Id,
	variant_index: int,
	// design.md "@(synchronized)": a synchronized field reached from outside its
	// declaring package, which the borrow analysis counts as exclusive access.
	synchronized:  bool,
	// `check_receiver` has checked `operand` for the call being checked, and
	// `check_selector` takes that answer rather than checking it again.
	receiver_checked: bool,
}

// `x[a]`, and the user-defined comma form `x[a, b]`.
Expr_Index :: struct {
	using base: Expr_Base,
	operand:    Expr,
	indices:    []Expr,
	// A user `operator([])`: the arguments in parameter order, receiver first.
	bound:      []Expr,
	// `m[key] = elem`, the one index form that creates a map entry.
	map_inserts: bool,
}

// `x[lo:hi]`; either endpoint may be nil.
Expr_Slice :: struct {
	using base: Expr_Base,
	operand:    Expr,
	lo:         Expr,
	hi:         Expr,
	// Written `&mut a[lo:hi]`: the one way to ask for a `[]mut T` (design.md
	// "Slices"). The span starts at the `&`.
	mutable:    bool,
	// A user `operator([:])`: receiver, low, and high in parameter order.
	bound:      []Expr,
}

Argument_Mode :: enum {
	Value,
	Inout,
	Spread,
}

// `Argument`. An empty `name.text` is a positional argument.
Argument :: struct {
	span:  Span,
	name:  Name,
	mode:  Argument_Mode,
	value: Expr,
	// A spread whose operand the union argument expansion check already
	// checked and found no union; binding reuses its type.
	checked: bool,
}

// The compiler-defined operations of a `meta.Field` descriptor.
Reflect_Op :: enum {
	Field_Get,
	Field_Pointer,
}

// The compiler-defined operations of a text carrier.
Text_Op :: enum {
	None,
	Byte_Len,   // O(1), and what `len(text)` is shorthand for
	Rune_Count, // O(n) Unicode scalar values
	Bytes,      // a read-only borrowed []u8
	Runes,      // a borrowed `string_view`, iterated as Unicode scalar values
	Rune_Offsets, // a borrowed view yielding `(value: rune, offset: int)`
	Copy,       // an independent managed byte copy
	To_C_View,  // a zero-terminated borrow for the complete expression
	To_Runes,   // `st.to_runes()`, a `[dynamic]rune` by copy
}

// The named text constructors, which validate and return Option(T).
Text_Conversion :: enum {
	String_From_Bytes,  // `string.from_utf8(bytes)` — validate and copy
	View_From_Bytes,    // `string_view.from_utf8(bytes)` — validate and borrow
	String_From_C_View, // `string.from_utf8(cview)` — scan, validate, and copy
	C_View_From_Bytes,  // `cstring_view.from_bytes(bytes)` — check the terminator and borrow
	String_From_Runes,  // `string.from_runes(runes)` — validate and copy
}

// The operation the checker selected for a call; nil until checked.
Call_Operation :: union {
	Call_Procedure,
	Call_Compile_Time,
	Call_Builtin,
	Call_Conversion,
	Call_Reflect,
	Call_Text,
	Call_Enum_From_Int,
	Call_Union_Construct,
	Call_Union_As,
	Call_Text_Conversion,
	Call_Atomic,
	Call_Sort_By,
	Call_Simd_Reduce,
	Call_Dyn_Conversion,
	Call_Dyn_Slot,
	Call_Allocation,
	Call_Box_Unbox,
}

Call_Procedure :: struct {}
Call_Compile_Time :: struct {} // type/interface applications, never runtime calls
Call_Builtin :: struct {} // intrinsic without additional checked metadata
// A representation/numeric conversion, no user hook. A managed operand keeps its
// representation, so one read from a place is cloned like any other copy.
Call_Conversion :: struct {
	clones: bool,
}
Call_Reflect :: struct { op: Reflect_Op, field: Symbol_Id }
Call_Text :: struct { op: Text_Op }
Call_Enum_From_Int :: struct { type: Type_Id }
Call_Union_Construct :: struct { index: int, clone: bool }
// `u.as(.name)`: the variant tested and copied out.
Call_Union_As :: struct { index: int }
Call_Text_Conversion :: struct { op: Text_Conversion }
// Orderings and the element type are settled during checking, not runtime args.
Call_Atomic :: struct { type: Type_Id, order: Memory_Order, failure_order: Memory_Order }
Call_Sort_By :: struct { comparator: Symbol_Id }
Call_Simd_Reduce :: struct { fold: Simd_Fold }
// The witness the pointed-to type satisfies the interface with.
Call_Dyn_Conversion :: struct { witness: ^Witness }
Call_Dyn_Slot :: struct { index: int }
// The payload of `box` or `unsafe.new`, or the container type of `make`.
// `fallible`: a `try_` form, whose result is `Result(T, Allocator_Error)`.
Call_Allocation :: struct { type: Type_Id, fallible: bool }
// `move(b).unbox()`: the payload taken out of a box it consumes.
Call_Box_Unbox :: struct {}

// A call, a conversion, or a generic application; syntax cannot tell them apart.
Expr_Call :: struct {
	using base: Expr_Base,
	callee:     Expr,
	args:       []Argument,
	// Arguments in parameter order, with defaults; `args` stays as written.
	bound:      []Expr,
	// Parameter slots in evaluation order (written arguments, then defaults);
	// nil when that is parameter order.
	bound_order: []int,
	operation: Call_Operation,
	// A `foreach` took this adapter's call apart, so its view is never made
	// (`peel_resolved_adapter`).
	adapter_peeled: bool,
	// The members overload resolution chose among, when there were several; only
	// diagnostics read it.
	overload_members: []Symbol_Id,
	// The procedure group the call selected through, whose attributes, such as
	// `@(require_results)`, still apply once the callee names the member.
	group: Symbol_Id,
	// `variadic_slot`, when `is_variadic`, is the packed parameter.
	// `variadic_forwards` passes one spread slice through; otherwise elements and
	// spreads are concatenated in `variadic_order` (true = next spread, false =
	// next element).
	is_variadic:       bool,
	variadic_slot:     int,
	variadic_forwards: bool,
	variadic_elements: []Expr,
	variadic_spreads:  []Expr,
	variadic_order:    []bool,
	// `show(..answer)` over a union: the switch it stands for, whose cases carry
	// each variant's call as their `arm` (design.md "Union argument expansion").
	// Every later pass reads this instead of the callee and arguments.
	dispatch: ^Stmt_Switch,
}

// The suffixes `^` and `or_return`.
Expr_Postfix :: struct {
	using base: Expr_Base,
	// Over a place, the payloads are copied out and the source stays live.
	borrows:    bool,
	// `b^` of a box: a projection of the box's own place rather than a load
	// through a carrier (design.md "Owned values").
	boxed:      bool,
	op:         Token_Kind,
	op_span:    Span,
	operand:    Expr,
	// `or_return failure`: the written failure operand, or nil
	// (design.md "or_return operator").
	failure:    Expr,
	// Set by the checker when `failure` is written: the `return` taken on
	// failure, whose value wraps the replacement or the mapper's result in the
	// procedure's failure variant. A mapper reads the error through an
	// `Expr_Propagated_Error` naming this node.
	failure_exit: ^Stmt_Return,
	// The failure operand maps the error rather than replacing it: the error is
	// taken from the operand instead of dropped.
	failure_maps: bool,
}

// The error an `or_return` mapper is called with: the operand's failure
// payload, moved out of a temporary or copied out of a place. The checker
// builds it; it is never written.
Expr_Propagated_Error :: struct {
	using base: Expr_Base,
	owner:      ^Expr_Postfix,
}

// `mutable` is `&mut place`: the exclusive borrow form. It is meaningful only
// when `op` is `.Amp`.
Expr_Unary :: struct {
	using base: Expr_Base,
	op:         Token_Kind,
	op_span:    Span,
	mutable:    bool,
	operand:    Expr,
}

Expr_Binary :: struct {
	using base: Expr_Base,
	op:         Token_Kind,
	op_span:    Span,
	lhs:        Expr,
	rhs:        Expr,
	// `a != b` through a user `==`, whose result is negated.
	negated:    bool,
}

// `a ..= b` and `a ..< b`, kept apart from Expr_Binary.
Expr_Range :: struct {
	using base: Expr_Base,
	op:         Token_Kind,
	op_span:    Span,
	lo:         Expr,
	hi:         Expr,
}

Expr_Or_Else :: struct {
	using base: Expr_Base,
	value:      Expr,
	// Nil when the failure leaves instead (design.md "or_else expression").
	fallback:   Expr,
	// `break`, `continue`, or `return value` in the fallback position: a
	// `^Stmt_Branch` or `^Stmt_Return`, nil for an ordinary fallback.
	exit:       Stmt,
	// A place operand is copied from and stays live; a temporary is moved.
	borrows:    bool,
	// A managed fallback place is cloned into the result.
	fallback_clone: bool,
}

// `then if cond else otherwise`, in source order.
Expr_Cond :: struct {
	using base: Expr_Base,
	then:       Expr,
	cond:       Expr,
	otherwise:  Expr,
	// A managed place operand is cloned into the result; a temporary transfers.
	then_clone: bool,
	else_clone: bool,
}

Expr_Move :: struct {
	using base: Expr_Base,
	value:      Expr,
	// Not written: a copy at the local's last use, which the lifecycle pass
	// turned into this move (design.md "Last-use transfer").
	implicit:   bool,
}

// `Element`. A nil `key` is an unkeyed element.
Element :: struct {
	span:  Span,
	key:   Expr,
	value: Expr,
}

// `T{...}`, or `{...}` taking its type from context when `type_expr` is nil.
Expr_Composite :: struct {
	using base: Expr_Base,
	type_expr:  Expr,
	elements:   []Element,
	// Struct field slots in source order, resolved during checking. For a fixed
	// array, each element's first slot, with `slot_ends` its exclusive end
	// (design.md "Fixed arrays": `2 = x`, `3..=5 = y`).
	field_indices: []int,
	slot_ends:     []int,
	// Per element: a borrowed managed element is cloned, not moved.
	element_clones: []bool,
	// A slice literal's hidden `[N]T` storage; INVALID_TYPE otherwise.
	backing:    Type_Id,
	// The destination's `via` a container literal constructs with, or nil.
	via:        Expr,
	// A procedure literal with a capture clause, which checking lowers to this
	// literal of a body-local record whose `call` is the procedure (design.md
	// "Capture literals"). `type_expr` and `elements` are then the checker's.
	capture:    ^Capture_Literal,
}

// How a capture entry takes its place: `x`, `&x`, `&mut x`, or `move(x)`.
Capture_Mode :: enum {
	Copy,
	Borrow,
	Borrow_Mut,
	Move,
}

// One `capture(...)` entry. `value` is what is captured, written after `=` or
// the entry's own name; the mode's `&`, `&mut`, or `move` is not part of it.
Capture_Entry :: struct {
	span:  Span,
	mode:  Capture_Mode,
	name:  Name,
	value: Expr,
}

Capture_Literal :: struct {
	// The literal as written, minus the clause. It is never checked itself:
	// its body becomes the record's `call`.
	procedure:   ^Expr_Proc,
	entries:     []Capture_Entry,
	clause_span: Span,
	// The record checking lowered it to, and its checked `call` method's
	// literal, for queries over the body.
	record:      Type_Id,
	method:      ^Expr_Proc,
}

// `^T` is a read-only borrow, `^mut T` a mutable one.
Type_Pointer :: struct {
	using base: Expr_Base,
	mutable:    bool,
	elem:       Expr,
}

Type_C_Pointer :: struct {
	using base: Expr_Base,
	elem:       Expr,
}

// `[]T` is read-only, `[]mut T` has mutable elements.
Type_Slice :: struct {
	using base: Expr_Base,
	mutable:    bool,
	elem:       Expr,
}

Type_Dynamic_Array :: struct {
	using base: Expr_Base,
	elem:       Expr,
}

// `[N]T`, and `[?]T` where `length` is nil.
Type_Array :: struct {
	using base: Expr_Base,
	length:     Expr,
	elem:       Expr,
}

Type_Map :: struct {
	using base: Expr_Base,
	key:        Expr,
	value:      Expr,
}

Type_Distinct :: struct {
	using base: Expr_Base,
	elem:       Expr,
}

// `dyn Interface(args...)`; `interface_expr` carries the name and its arguments.
// `dyn I` is a read-only view, `dyn mut I` a mutable one.
Type_Dyn :: struct {
	using base:     Expr_Base,
	mutable:        bool,
	interface_expr: Expr,
}

// The `type` keyword: the compile-time-only type of types.
Type_Type :: struct {
	using base: Expr_Base,
}

// An inferred specialization binding, `$T`.
Type_Poly :: struct {
	using base: Expr_Base,
	name:       Name,
}

// `Borrow` is a `self: ^` receiver or a synthesized read-only one, passed by
// address. It is last because a mode number reaches the type identity key
// (`typeid_sort_key_walk`).
Param_Mode :: enum u8 {
	Value,
	Inout,
	Move,
	Variadic,
	Borrow,
}

// `"$"? (Identifier | "_")`
Param_Name :: struct {
	name:    Name,
	is_poly: bool,
}

// A parameter with no type is the receiver `self`, whose type comes from the
// enclosing `impl`/`extend` block or interface `slot`.
Parameter :: struct {
	span:       Span,
	attributes: []Attribute,
	names:   []Param_Name,
	mode:    Param_Mode,
	type:    Expr,
	default: Expr,
	symbols: []Symbol_Id,
}

// A procedure's one anonymous result; `inout` makes it a place.
Result :: struct {
	span:     Span,
	is_inout: bool,
	type:     Expr, // nil for `-> !`
	// `-> !`: the procedure never returns (design.md "Diverging procedures").
	diverges: bool,
}

// `Proc_Type`: a signature with no body.
Type_Proc :: struct {
	using base: Expr_Base,
	convention: string, // the calling-convention literal's spelling, or ""
	params:     []Parameter,
	result:     ^Result, // nil when the procedure has no result
}

// `Proc_Literal`: a signature plus a block, or `---` for a bodiless
// declaration.
Expr_Proc :: struct {
	using base:    Expr_Base,
	signature:     ^Type_Proc,
	where_clauses: []Expr,
	body:          ^Block,
	bodiless:      bool,
	// Enrolled for emission, its body checked for the program: a literal is not
	// checked twice, and a second copy of it would be a redefinition.
	hoisted:       bool,
	// The procedure this literal becomes.
	symbol:        Symbol_Id,
	// Cleanup slots this body needs, allocated in the entry block.
	defer_count:   int,
	// A generic instance, whose `$` parameters are not in its runtime signature.
	generic_instance: bool,
}

// `proc { a, b }`
Expr_Proc_Group :: struct {
	using base: Expr_Base,
	names:      []Name,
}

Hook_Kind :: enum u8 {
	None,
	Convert,
	Copy,
	Drop,
}

// `operator(+) proc ...` or `hook(convert) proc ...`.
Expr_Operator :: struct {
	using base:  Expr_Base,
	symbol:      string,
	symbol_span: Span,
	hook:        Hook_Kind,
	value:       Expr,
}

// `Generic_Parameter`: one or more `$Name`s sharing a type.
Generic_Param :: struct {
	span:  Span,
	names: []Name,
	type:  Expr,
	symbols: []Symbol_Id,
}

// `Field`. A field named `_` is padding; `using` promotes it.
Field :: struct {
	span:       Span,
	attributes: []Attribute,
	is_using:   bool,
	names:    []Name,
	type:     Expr,
	symbols:  []Symbol_Id,
}

Enum_Field :: struct {
	span:  Span,
	name:  Name,
	value: Expr,
	symbol: Symbol_Id,
}

// `Binding_Group` inside an interface requirement's `Bindings`.
Binding_Group :: struct {
	span:     Span,
	names:    []Name,
	is_inout: bool,
	type:     Expr,
	symbols:  []Symbol_Id,
}

Requirement_Kind :: enum {
	Expression,
	Slot,
}

// Either `bindings? expression ("->" result)? ";"` or `slot name: proc(...);`.
Requirement :: struct {
	span:         Span,
	kind:         Requirement_Kind,
	bindings:     []Binding_Group,
	expr:         Expr,
	result_inout: bool,
	result:       Expr,
	name:         Name, // the slot's name
	slot_type:    Expr,
}

Record_Kind :: enum {
	Struct,
	Union,
}

// A union variant, `name: T` or payloadless `name:`, identified by name.
Variant :: struct {
	span: Span,
	name: Name,
	type: Expr, // nil for a payloadless variant
}

// `fields` for a struct, `variants` for a union. A generic instance clones the
// record alone, so `attributes` repeats the declaration's list to keep
// `@(align=N)` reachable.
Type_Record :: struct {
	using base:     Expr_Base,
	kind:           Record_Kind,
	move_only:      bool,
	generic_params: []Generic_Param,
	attributes:     []Attribute,
	where_clauses:  []Expr,
	// Where the body's `{` is.
	body_lo:        u32,
	fields:         []Field,
	variants:       []Variant,
}

// `(name: Type, ...)`: the anonymous structural record.
Type_Anon_Record :: struct {
	using base: Expr_Base,
	fields:     []Field,
}

// `(name: Type | name:)`: the anonymous structural union, whose alternatives
// are written as a named union's variants are (design.md "Anonymous unions").
Type_Anon_Union :: struct {
	using base: Expr_Base,
	variants:   []Variant,
}

Type_Enum :: struct {
	using base: Expr_Base,
	backing:    Expr, // nil when the backing type is omitted
	fields:     []Enum_Field,
}

Type_Interface :: struct {
	using base:     Expr_Base,
	generic_params: []Generic_Param,
	where_clauses:  []Expr,
	requirements:   []Requirement,
}

// The array slots one literal element fills: its position, or the index or
// index range its key designates.
composite_element_slots :: proc(v: ^Expr_Composite, index: int) -> (lo, hi: int) {
	if index < len(v.slot_ends) {
		return v.field_indices[index], v.slot_ends[index]
	}
	return index, index + 1
}

hook_name :: proc(kind: Hook_Kind) -> string {
	switch kind {
	case .Convert: return "convert"
	case .Copy:    return "copy"
	case .Drop:    return "drop"
	case .None:    return ""
	}
	return ""
}

// The value a `return` exit of an `or_else` carries, or nil.
or_else_exit_value :: proc(v: ^Expr_Or_Else) -> Expr {
	if ret, is_return := v.exit.(^Stmt_Return); is_return && ret.value != nil {
		return ret.value.expr
	}
	return nil
}

// Whether a literal's `key` is the name of a field. An array's index or a map's
// key is an expression, which the checker resolves; where it did not look, the
// literal's written type says.
key_names_field :: proc(v: ^Expr_Composite, key: Expr) -> bool {
	ident, is_ident := key.(^Expr_Ident)
	if !is_ident || ident.resolution.symbol != INVALID_SYMBOL || ident.symbol != INVALID_SYMBOL {
		return false
	}
	#partial switch _ in v.type_expr {
	case ^Type_Array, ^Type_Slice, ^Type_Dynamic_Array, ^Type_Map:
		return false
	}
	return true
}

base_is_const :: proc(base: ^Expr_Base) -> bool {
	return base.const_value.kind != .Invalid
}

conversion_source :: proc(base: ^Expr_Base) -> Type_Id {
	for from in ([]Type_Id{base.widened_from, base.splat_from, base.erased_from, base.view_from}) {
		if from != INVALID_TYPE { return from }
	}
	return INVALID_TYPE
}

expression_converts_storage :: proc(value: Expr) -> bool {
	base := expr_base(value)
	return base != nil && conversion_source(base) != INVALID_TYPE
}

// Exhaustive, so a new node kind is a compile error here.
expr_base :: proc(e: Expr) -> ^Expr_Base {
	switch v in e {
	case ^Expr_Error: return &v.base
	case ^Expr_Literal: return &v.base
	case ^Expr_Ident: return &v.base
	case ^Expr_Selector: return &v.base
	case ^Expr_Index: return &v.base
	case ^Expr_Slice: return &v.base
	case ^Expr_Call: return &v.base
	case ^Expr_Postfix: return &v.base
	case ^Expr_Propagated_Error: return &v.base
	case ^Expr_Unary: return &v.base
	case ^Expr_Binary: return &v.base
	case ^Expr_Range: return &v.base
	case ^Expr_Or_Else: return &v.base
	case ^Expr_Cond: return &v.base
	case ^Expr_Move: return &v.base
	case ^Expr_Composite: return &v.base
	case ^Expr_Proc: return &v.base
	case ^Expr_Proc_Group: return &v.base
	case ^Expr_Operator: return &v.base
	case ^Type_Pointer: return &v.base
	case ^Type_C_Pointer: return &v.base
	case ^Type_Slice: return &v.base
	case ^Type_Dynamic_Array: return &v.base
	case ^Type_Array: return &v.base
	case ^Type_Map: return &v.base
	case ^Type_Distinct: return &v.base
	case ^Type_Dyn: return &v.base
	case ^Type_Type: return &v.base
	case ^Type_Poly: return &v.base
	case ^Type_Proc: return &v.base
	case ^Type_Record: return &v.base
	case ^Type_Anon_Record: return &v.base
	case ^Type_Anon_Union: return &v.base
	case ^Type_Enum: return &v.base
	case ^Type_Interface: return &v.base
	}
	return nil
}

expr_span :: proc(e: Expr) -> Span {
	base := expr_base(e)
	return base == nil ? NO_SPAN : base.span
}

expr_has_error :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base.has_error
}

// How far a walk of a built pack's operands has come: how many it has taken, in
// all and of each kind.
Call_Pack_Cursor :: struct {
	taken, elements, spreads: int,
}

// A call's next variadic pack operand in written order (`variadic_order`), and
// whether it is a spread.
call_pack_next :: proc(call: ^Expr_Call, cursor: ^Call_Pack_Cursor) -> (operand: Expr, spread: bool, more: bool) {
	if cursor.taken >= len(call.variadic_order) {
		return nil, false, false
	}
	spread = call.variadic_order[cursor.taken]
	cursor.taken += 1
	if spread {
		operand = call.variadic_spreads[cursor.spreads]
		cursor.spreads += 1
	} else {
		operand = call.variadic_elements[cursor.elements]
		cursor.elements += 1
	}
	return operand, spread, true
}

// `_` as a destination; its value is dropped.
is_discard :: proc(target: Expr) -> bool {
	ident, ok := target.(^Expr_Ident)
	return ok && ident.name == "_"
}

// The base of statements, declarations and items.
Node_Base :: struct {
	span:       Span,
	has_error:  bool,
	attributes: []Attribute,
}

// `@(name)`, `@(name=value)`, or the extension form `@(ns.name)`.
Attribute :: struct {
	span:  Span,
	path:  []Name,
	value: Expr, // nil unless the attribute was written `name = value`
}

has_attribute :: proc(attributes: []Attribute, name: string) -> bool {
	_, found := find_attribute(attributes, name)
	return found
}

find_attribute :: proc(attributes: []Attribute, name: string) -> (Attribute, bool) {
	for attribute in attributes {
		if len(attribute.path) == 1 && attribute.path[0].text == name {
			return attribute, true
		}
	}
	return {}, false
}

Stmt :: union {
	^Decl,
	// An `impl` of a type declared in the same body.
	^Item_Impl,
	^Stmt_Error,
	^Stmt_Expr,
	^Stmt_Assign,
	^Stmt_If,
	^Stmt_For,
	^Stmt_Foreach,
	^Stmt_When,
	^Stmt_Switch,
	^Stmt_Defer,
	^Stmt_Return,
	^Stmt_Branch,
	^Stmt_Parallel,
	^Stmt_Spawn,
	^Block,
}

Stmt_Error :: struct {
	using base: Node_Base,
	// The simple statement the parser could not finish, as far as it got, or
	// nil. Only the checker reads it, so editor queries see its names and types.
	partial: Stmt,
}

Block :: struct {
	using base: Node_Base,
	stmts:      []Stmt,
}

// `Simple_Statement`'s expression-list form.
Stmt_Expr :: struct {
	using base: Node_Base,
	exprs:      []Expr,
}

// `a, b = c, d`, and the compound form `a += b`.
Stmt_Assign :: struct {
	using base: Node_Base,
	op:         Token_Kind,
	op_span:    Span,
	lhs:        []Expr,
	rhs:        []Expr,
	// Per right side: whether it clones, and the destination's liveness
	// (`src/lifecycle.odin`).
	rhs_clones:       []bool,
	destination_live: []Liveness,
	destructure:      Destructure,
	// A user `+=`, or the `+` it falls back to; INVALID_SYMBOL when built in.
	operator:        Symbol_Id,
	operator_direct: bool,
	// `grid[x, y] = v` through `operator([]=)`, bound in parameter order.
	place_setter:    Symbol_Id,
	setter_bound:    []Expr,
	// `grid[x, y] += v` through `operator([])` and `operator([]=)`: the checked
	// block later phases run instead of this statement.
	lowered:         ^Block,
}

Stmt_If :: struct {
	using base: Node_Base,
	init:       Stmt, // the optional `Init_Statement`
	cond:       Expr,
	then:       ^Block,
	otherwise:  Stmt, // `^Stmt_If` for `else if`, `^Block` for `else`
}

Stmt_For :: struct {
	using base:     Node_Base,
	init:           Stmt,
	cond:           Expr,
	post:           Stmt,
	body:           ^Block,
	condition_only: bool, // the `for (cond)` header
}

// A `foreach` binding `$`? `&`? name, or a parenthesised group of them
// (design.md "Element bindings"). A group has an empty `name.text` but a span.
Foreach_Binding :: struct {
	name:      Name,
	is_static: bool,
	is_ref:    bool,
	symbol:    Symbol_Id,
	group:     []Foreach_Binding,
}

// How the checker resolved a `foreach`.
Foreach_Kind :: enum {
	Unresolved,
	Static,
	Range,
	Stored_Range,
	Array,
	Slice,
	Dynamic,
	// Yields `struct{key, value}` entries, in unspecified order.
	Map,
	// Yields Unicode scalar values.
	Text,
	Protocol,
}

Stmt_Foreach :: struct {
	using base: Node_Base,
	bindings:   []Foreach_Binding,
	iterable:   Expr,
	body:       ^Block,
	// Written by the checker, read by the backend.
	kind:          Foreach_Kind,
	// The header adapters, which traverse the same iterable differently:
	// `reversed()`, and `indexed()`, always the outermost.
	reversed:      bool,
	indexed:       bool,
	// What one binding names: the yielded value, or a map entry or indexed pair.
	element_type:  Type_Id,
	// A lent record bound to one name, as pointers to its parts; else INVALID_TYPE.
	item_type:     Type_Id,
	// Elements are lent from the container rather than copied out.
	borrows:       bool,
	count:         u64,       // a fixed array's length
	iterator_type: Type_Id,   // the protocol path's opaque iterator
	iter_symbol:   Symbol_Id,
	next_symbol:   Symbol_Id,
	// A static expansion's checked copies, one per element; `body` is not emitted.
	expansion:  []^Block,
}

// Only the selected branch is declared, checked and emitted, with no new scope.
Stmt_When :: struct {
	using base: Node_Base,
	cond:       Expr,
	then:       ^Block,
	otherwise:  Stmt,
	resolved:   bool,
	selected:   ^Block, // nil when no branch was taken
}

Switch_Kind :: enum {
	Value,
	// A union switch, whose cases name variants and may bind with
	// `.variant(binding)`; the checker turns a `Value` switch over a union
	// into this.
	Pattern,
}

// A case's values, or none for the default case.
Switch_Case :: struct {
	span:   Span,
	values: []Expr,
	stmts:  []Stmt,
	// The binding in `.variant(name)`, or empty.
	binding: Name,
	// `.variant(&mut name)`: the binding is the subject's payload place, or,
	// with `fields`, some field binding is.
	binding_ref: bool,
	// `.variant(a, &mut b)`: the bindings of a record payload's fields, set
	// instead of `binding`.
	fields: []Case_Field,
	// A type switch's per-case binding: the payload type for one variant, the
	// union type for a grouped or default case.
	binding_symbol: Symbol_Id,
	binding_type:   Type_Id,
	// A union switch's cases as variant indices.
	variant_indices: []int,
	// One copy of an expanded case, `case $variant(payload):`, which the checker
	// makes for each variant no earlier case names: the name `$variant` binds,
	// and the `meta.Variant` it binds to (design.md "Per-variant switch cases").
	expanded:   Name,
	descriptor: Const_Value,
	// A union argument expansion's call for this variant, whose value is the
	// whole call's (design.md "Union argument expansion"); nil in a statement.
	arm: Expr,
}

// One field binding of a case (design.md "Inspecting a union").
Case_Field :: struct {
	name:   Name,
	is_ref: bool,
	// Resolved by the checker: the field's slot in the payload record, which
	// counts padding, and its symbol, none for `_`.
	slot:   int,
	type:   Type_Id,
	symbol: Symbol_Id,
}

Stmt_Switch :: struct {
	using base: Node_Base,
	kind:       Switch_Kind,
	init:       Stmt,
	subject:    Expr,
	cases:      []Switch_Case,
	// Every path enters a case: all variants covered, or a default.
	exhaustive: bool,
	// The cases as written, kept when an expanded case replaced `cases` with
	// its copies, so a clone expands afresh (design.md "Per-variant switch
	// cases").
	written:    []Switch_Case,
	// A union argument expansion's switch: the type its value is expected to
	// have, which each arm is checked against.
	arm_expected: Type_Id,
}

// `defer` or `errdefer` (design.md "defer statement").
Stmt_Defer :: struct {
	using base: Node_Base,
	stmt:       Stmt,
	// `errdefer`: runs only when the procedure leaves with its failure variant,
	// or unwinds.
	on_failure: bool,
	// This registration's flag slot in the procedure's entry block.
	slot:       int,
}

// `"inout"? Expression`
Return_Value :: struct {
	span:     Span,
	is_inout: bool,
	expr:     Expr,
	// A borrowed managed value is cloned on return rather than moved.
	clone_on_return: bool,
}

Stmt_Return :: struct {
	using base: Node_Base,
	value:      ^Return_Value, // nil for `return;`
}

Stmt_Branch :: struct {
	using base: Node_Base,
	kind:       Token_Kind, // `.Break` or `.Continue`
}

// `parallel { ... }`, which joins every task it starts before it is left
// (design.md "Parallel blocks").
Stmt_Parallel :: struct {
	using base: Node_Base,
	keyword:    Span,
	executor:   Expr, // nil for the bare form
	body:       ^Block,
	// Written by the checker: the block later phases run instead of this
	// statement, which declares the hidden scope local before `body`.
	lowered:    ^Block,
	scope:      Symbol_Id,
	// The lowered spawns whose task this block joins, in source order.
	spawns:     [dynamic]^Stmt_Spawn,
}

// `spawn call;` or `spawn result = call;`, directly inside a `parallel` block
// (design.md "Spawn statements").
Stmt_Spawn :: struct {
	using base: Node_Base,
	keyword:    Span,
	result:     ^Expr_Ident, // nil unless the call's value is assigned
	call:       Expr, // an `^Expr_Call`; the parser rejects anything else
	// Written by the checker.
	task:       ^Spawn_Task,
}

stmt_base :: proc(s: Stmt) -> ^Node_Base {
	switch v in s {
	case ^Decl: return &v.base
	case ^Item_Impl: return &v.base
	case ^Stmt_Error: return &v.base
	case ^Stmt_Expr: return &v.base
	case ^Stmt_Assign: return &v.base
	case ^Stmt_If: return &v.base
	case ^Stmt_For: return &v.base
	case ^Stmt_Foreach: return &v.base
	case ^Stmt_When: return &v.base
	case ^Stmt_Switch: return &v.base
	case ^Stmt_Defer: return &v.base
	case ^Stmt_Return: return &v.base
	case ^Stmt_Branch: return &v.base
	case ^Stmt_Parallel: return &v.base
	case ^Stmt_Spawn: return &v.base
	case ^Block: return &v.base
	}
	return nil
}

stmt_span :: proc(s: Stmt) -> Span {
	base := stmt_base(s)
	return base == nil ? NO_SPAN : base.span
}

stmt_has_error :: proc(s: Stmt) -> bool {
	base := stmt_base(s)
	return base != nil && base.has_error
}

Decl_Kind :: enum {
	Var,
	Const,
}

Check_State :: enum {
	Unchecked,
	Checking,
	Checked,
}

Name :: struct {
	text: string,
	span: Span,
	id:   Identifier_Id,
}

Duration :: enum u8 {
	None,
	Static,
	Thread_Local,
}

// `a, b := record;`, resolved once by the checker (design.md "Destructuring").
Destructure :: struct {
	active: bool,
	record: Type_Id,
	fields: []Symbol_Id,
	// A place operand stays live and its managed fields are cloned out.
	from_place: bool,
	// Per binding: false for `_`, whose field later phases must ignore.
	retained: []bool,
	// Per binding: whether the field is cloned.
	clones: []bool,
}

// `x: int;`, `x: int = e;`, `x := e;`, `x: int : e;`. A nil `values` entry is
// `---`; an omitted initialiser leaves `values` empty.
Decl :: struct {
	using base:    Node_Base,
	kind:          Decl_Kind,
	names:         []Name,
	duration:      Duration,
	declared_type: Expr, // nil when the type is inferred
	via:           Expr, // the `via` allocator expression, or nil
	values:        []Expr,
	symbols:       []Symbol_Id,
	// Per initialiser: whether it clones a managed place instead of moving.
	value_clones:  []bool,
	destructure:   Destructure,
	top_level:     bool,
	// Separate, since the evaluator may need a body before its checking phase.
	sig_state:     Check_State,
	check_state:   Check_State,
	// Checking reported an error, so the evaluator must not run the body: its
	// nodes may carry no resolution at all.
	check_failed:  bool,
}

// The one value of a constant declaration, or nil.
decl_value :: proc(d: ^Decl) -> Expr {
	if d.kind != .Const || len(d.values) != 1 {
		return nil
	}
	return d.values[0]
}

// The literal of `name :: proc() { ... }`, or nil.
decl_proc :: proc(d: ^Decl) -> ^Expr_Proc {
	literal, _ := decl_value(d).(^Expr_Proc)
	return literal
}

// As `decl_proc`, but also looking through `operator(sym)` and hooks.
decl_proc_literal :: proc(d: ^Decl) -> ^Expr_Proc {
	value := decl_value(d)
	if operator, is_operator := value.(^Expr_Operator); is_operator {
		value = operator.value
	}
	literal, _ := value.(^Expr_Proc)
	return literal
}

decl_is_lifecycle_hook :: proc(d: ^Decl) -> bool {
	role := decl_hook_kind(d)
	return role == .Drop || role == .Copy
}

decl_hook_kind :: proc(d: ^Decl) -> Hook_Kind {
	wrapper, is_wrapper := decl_value(d).(^Expr_Operator)
	return wrapper.hook if is_wrapper else .None
}

// Top-level syntax has its own union so `Decl` never becomes a catch-all.
Item :: union {
	^Decl,
	^Item_Error,
	^Item_Import,
	^Item_Foreign_Import,
	^Item_Foreign_Block,
	^Item_Impl,
	^Item_Delegate,
	^Item_When,
	^Item_Block,
	^Item_Static_Assert,
}

Item_Error :: struct {
	using base: Node_Base,
}

// `import "core:fmt";` and the aliased `import f "core:fmt";`
Item_Import :: struct {
	using base: Node_Base,
	alias:      Name,   // empty when no local name was written
	path:       string, // the string literal's spelling
	// Bound per item: selected `when` branches insert imports anywhere.
	bound:      bool,
}

// `foreign import raylib "raylib.lib";`
Item_Foreign_Import :: struct {
	using base: Node_Base,
	name:       Name,
	path:       string,
}

// `foreign raylib { ... }`.
Item_Foreign_Block :: struct {
	using base: Node_Base,
	library:    Name, // a label only; every block links against the one image
	members:    []^Decl,
	// Members collected; discovery re-prepares a package each round.
	declared:   bool,
}

// Inherent to a subject declared in this package, or an extension of one
// declared elsewhere; set by `declare_impl_block`.
Impl_Kind :: enum {
	Unresolved,
	Impl,
	Extend,
}

// `impl T { ... }`, whether `T` is declared here or elsewhere.
Item_Impl :: struct {
	using base: Node_Base,
	kind:       Impl_Kind,
	type:       Expr,
	members:    []Item,
	// Set once members are installed, so a later discovery round skips them.
	subject:    Type_Id,
	declared:   bool,
}

// `delegate(+, -);` inside an `impl` body.
Item_Delegate :: struct {
	using base: Node_Base,
	symbols:    []string,
}

Item_When_State :: enum {
	Pending,
	Taken, // this node's own condition was true
	Not_Taken,
	// Reported as unanswerable, and selects nothing.
	Stalled,
}

// File-scope `when`. Once it leaves `Pending`, the choice is final, and only the
// selected branch reaches `File.active_items`.
Item_When :: struct {
	using base: Node_Base,
	cond:       Expr,
	then:       ^Item_Block,
	otherwise:  Item, // `^Item_When` for `else when`, `^Item_Block` for `else`
	state:      Item_When_State,
}

// `Top_Level_Block`
Item_Block :: struct {
	using base: Node_Base,
	items:      []Item,
}

// `static_assert(condition[, message]);` at file scope, checked as the built-in.
Item_Static_Assert :: struct {
	using base: Node_Base,
	call:       Expr,
}

item_base :: proc(item: Item) -> ^Node_Base {
	switch v in item {
	case ^Decl: return &v.base
	case ^Item_Error: return &v.base
	case ^Item_Import: return &v.base
	case ^Item_Foreign_Import: return &v.base
	case ^Item_Foreign_Block: return &v.base
	case ^Item_Impl: return &v.base
	case ^Item_Delegate: return &v.base
	case ^Item_When: return &v.base
	case ^Item_Block: return &v.base
	case ^Item_Static_Assert: return &v.base
	}
	return nil
}

item_span :: proc(item: Item) -> Span {
	base := item_base(item)
	return base == nil ? NO_SPAN : base.span
}

File :: struct {
	// Owns all syntax; source text lives with the source manager.
	arena:        virtual.Arena,
	file:         u32,
	attributes:   []Attribute, // on the package clause
	package_name: string,
	package_span: Span, // its name
	// Where the clause starts, at its first attribute.
	package_lo:   u32,
	items:        []Item,
	// `items` with selected `when` branches flattened in, in source order. The
	// checker reads this; `-dump-ast` prints `items`.
	active_items: []Item,
	// Every `import` the file writes, at file scope or in a `when` branch, in
	// source order.
	imports:        []^Item_Import,
	// Where each `parallel` keyword is. A block's hidden scope is a
	// `core:thread` type, so that package is a dependency of a file whose
	// selected items hold one; `parallel_bound` once import discovery has
	// added it.
	parallels:      []u32,
	parallel_bound: bool,
	// What `-migrate` rewrites. Nothing else reads it.
	earlier_spellings: []Earlier_Spelling,
}

// A record written the way an earlier release required: its `move_only` keyword
// and its in-type attribute groups, each span empty when absent. `declaration` is
// the constant whose value it is, if any.
Earlier_Spelling :: struct {
	offset:      u32,
	record:      ^Type_Record,
	declaration: ^Decl,
	keyword:     Span,
	groups:      Span,
}

destroy_ast :: proc(f: ^File) {
	virtual.arena_destroy(&f.arena)
}

// What `type_syntax_any_name` asks of each node it does not walk itself, with
// the caller's data: an `Expr_Ident`, a `$` name (`Type_Poly`), or an inline
// definition (`Expr_Proc`, `Type_Record`, `Type_Enum`, `Type_Interface`). Each
// caller decides what a `$` name and a declared body mean for its question. An
// `Expr_Selector` and a `Type_Distinct` are asked about too, before what they
// hold is walked, as each can matter beyond that.
Name_Match :: proc(data: rawptr, node: Expr) -> bool

// Whether type syntax holds a node `matches` accepts, through the expressions a
// type may contain, such as an array length. A bare name keying a literal of a
// named type is an index if that type is an array, which syntax cannot tell, so
// it is asked about too; `skip_field_keys` is for a caller looking for what no
// index can be, such as a type.
type_syntax_any_name :: proc(e: Expr, data: rawptr, matches: Name_Match, skip_field_keys := false) -> bool {
	walk := Name_Walk{data, matches, skip_field_keys}
	return walk_names(&walk, e)
}

// The `$` names written in type syntax, as `T` in `[]$T`.
bind_poly_names :: proc(bound: ^[dynamic]string, e: Expr) {
	type_syntax_any_name(e, bound, proc(data: rawptr, node: Expr) -> bool {
		if poly, is_poly := node.(^Type_Poly); is_poly {
			append((^[dynamic]string)(data), poly.name.text)
		}
		return false
	})
}

bind_generic_params :: proc(bound: ^[dynamic]string, parameters: []Generic_Param) {
	for parameter in parameters {
		for name in parameter.names {
			append(bound, name.text)
		}
	}
}

// Each `$` parameter's name, and each `$` name its types and defaults bind. A
// plain parameter's name is in no type's scope, so `proc(T: int) -> T` means what
// `T` means outside it.
bind_signature :: proc(bound: ^[dynamic]string, signature: ^Type_Proc) {
	for parameter in signature.params {
		for name in parameter.names {
			if name.is_poly {
				append(bound, name.name.text)
			}
		}
		bind_poly_names(bound, parameter.type)
		bind_poly_names(bound, parameter.default)
	}
}

@(private = "file")
Name_Walk :: struct {
	data:            rawptr,
	matches:         Name_Match,
	skip_field_keys: bool,
}

@(private = "file")
walk_names :: proc(w: ^Name_Walk, e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Ident, ^Type_Poly, ^Expr_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
		return w.matches(w.data, e)
	case ^Type_Distinct, ^Expr_Selector:
		if w.matches(w.data, e) {
			return true
		}
	case ^Expr_Composite:
		if !w.skip_field_keys {
			for element in v.elements {
				if key_names_field(v, element.key) && walk_names(w, element.key) {
					return true
				}
			}
		}
	}
	return expr_children(e, w, proc(data: rawptr, child: Expr) -> bool {
		return walk_names((^Name_Walk)(data), child)
	})
}

// What `expr_children` asks of each child, which may be nil, with the caller's
// data. True ends the walk.
Expr_Visit :: proc(data: rawptr, child: Expr) -> bool

// Asks `visit` about each expression `e` directly holds, in written order, until
// it answers true, and says whether it did. A literal's key that names a field
// (`key_names_field`) is no expression. A form that binds names of its own, an
// `Expr_Proc`, `Type_Record`, `Type_Enum` or `Type_Interface`, has no children
// here, as each walker decides what its body means for its question.
expr_children :: proc(e: Expr, data: rawptr, visit: Expr_Visit) -> bool {
	switch v in e {
	case ^Expr_Error, ^Expr_Literal, ^Expr_Ident, ^Expr_Proc, ^Expr_Proc_Group, ^Expr_Propagated_Error,
	     ^Type_Type, ^Type_Poly, ^Type_Record, ^Type_Enum, ^Type_Interface:
		return false
	case ^Type_Pointer:
		return visit(data, v.elem)
	case ^Type_C_Pointer:
		return visit(data, v.elem)
	case ^Type_Slice:
		return visit(data, v.elem)
	case ^Type_Dynamic_Array:
		return visit(data, v.elem)
	case ^Type_Distinct:
		return visit(data, v.elem)
	case ^Type_Dyn:
		return visit(data, v.interface_expr)
	case ^Type_Array:
		return visit(data, v.length) || visit(data, v.elem)
	case ^Type_Map:
		return visit(data, v.key) || visit(data, v.value)
	case ^Expr_Selector:
		return visit(data, v.operand)
	case ^Expr_Index:
		if visit(data, v.operand) {
			return true
		}
		for index in v.indices {
			if visit(data, index) {
				return true
			}
		}
		return false
	case ^Expr_Slice:
		return visit(data, v.operand) || visit(data, v.lo) || visit(data, v.hi)
	case ^Expr_Call:
		if visit(data, v.callee) {
			return true
		}
		for argument in v.args {
			if visit(data, argument.value) {
				return true
			}
		}
		return false
	case ^Expr_Postfix:
		return visit(data, v.operand) || visit(data, v.failure)
	case ^Expr_Unary:
		return visit(data, v.operand)
	case ^Expr_Binary:
		return visit(data, v.lhs) || visit(data, v.rhs)
	case ^Expr_Range:
		return visit(data, v.lo) || visit(data, v.hi)
	case ^Expr_Or_Else:
		return visit(data, v.value) || visit(data, v.fallback) || visit(data, or_else_exit_value(v))
	case ^Expr_Cond:
		return visit(data, v.cond) || visit(data, v.then) || visit(data, v.otherwise)
	case ^Expr_Move:
		return visit(data, v.value)
	case ^Expr_Composite:
		if visit(data, v.type_expr) || visit(data, v.via) {
			return true
		}
		for element in v.elements {
			if !key_names_field(v, element.key) && visit(data, element.key) {
				return true
			}
			if visit(data, element.value) {
				return true
			}
		}
		return false
	case ^Expr_Operator:
		return visit(data, v.value)
	case ^Type_Proc:
		for parameter in v.params {
			if visit(data, parameter.type) || visit(data, parameter.default) {
				return true
			}
		}
		return v.result != nil && visit(data, v.result.type)
	case ^Type_Anon_Record:
		for field in v.fields {
			if visit(data, field.type) {
				return true
			}
		}
		return false
	case ^Type_Anon_Union:
		for variant in v.variants {
			if visit(data, variant.type) {
				return true
			}
		}
		return false
	}
	return false
}
