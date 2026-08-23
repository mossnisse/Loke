// AST (compiler-plan B4). Every node carries a Span; the checker annotates
// these same nodes in place, which is the "typed AST" of decision A1.
//
// Types and expressions share one node domain. The grammar refuses to separate
// them — `Generic_Argument = Type | Expression`, `Argument_Value = Expression |
// Type`, `Primary = "(" Type ")"` — and `Matrix(f32, 4)` and `f(a, b)` are the
// same token stream. Type positions go through `parse_type`, a restricted entry
// point into this one domain, so `x: 1 + 2;` is still a parse error. What syntax
// genuinely cannot decide is left for name resolution in M2.
package lokec

import "core:mem"

Expr_Base :: struct {
	span:          Span,
	type:          Type_Id,
	denoted_type:  Type_Id, // non-zero when this expression denotes a type
	const_value:   Const_Value,
	is_const:      bool,
	resolution:    Resolution,
	value_category: Value_Category,
	// Independent place facts (m2-plan decision "Place model"). A value
	// parameter is addressable and not assignable; a composite literal is
	// addressable temporary storage; `_` is neither. One bit cannot say that.
	addressable:  bool,
	assignable:   bool,
	immutable:    Immutable_Reason,
	// A call to a procedure with several results. `type` stays the
	// exactly-one-value type, so nothing that expects one value silently reads
	// the first of many.
	result_types: []Type_Id,
	// The variant type this expression produces before it is wrapped into the
	// union `type` now names. INVALID_TYPE when no wrap happens; the emitter
	// evaluates the node at this type and then writes payload and tag.
	union_from:  Type_Id,
	// The concrete type this expression produces before it is erased into the
	// `any_view` that `type` now names. The emitter evaluates the node at this
	// type, takes its address, and pairs it with the frozen `typeid`.
	erased_from: Type_Id,
	// design.md "string type conversions": a `string` borrowed as a
	// `string_view`. The source type is kept so the backend narrows the owning
	// three-word value to the two-word view rather than reinterpreting it.
	view_from:   Type_Id,
	// Set at construction when this node or any child is an error node, so
	// recovery never has to re-walk a subtree to find out.
	has_error:   bool,
}

// Literals keep their spelling. Deciding whether `9223372036854775808` fits an
// `int` is a semantic question, so the checker asks it (grammar.md has no
// representability rule).
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
	^Expr_Checked_Extract,
	^Expr_Index,
	^Expr_Slice,
	^Expr_Call,
	^Expr_Postfix,
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

	// Type forms. Named types are `Expr_Ident` / `Expr_Selector`, and a generic
	// application is an `Expr_Call` — that is the whole point of one domain.
	^Type_Pointer,
	^Type_Multi_Pointer,
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
	^Type_Enum,
	^Type_Interface,
}

// Error nodes are retained in the tree instead of being represented by nil, so
// recovery preserves surrounding syntax and AST dumps stay useful for malformed
// files.
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
}

// `x.(T)`. One construct with two result shapes chosen by context: a
// single-value position traps on a mismatch, while a comma-ok destination or an
// `or_else` left operand yields `(T, bool)` and never traps.
Expr_Checked_Extract :: struct {
	using base: Expr_Base,
	operand:    Expr,
	target:     Expr,
	optional:   bool,
}

// `x[a]`, and the user-defined comma form `x[a, b]`.
Expr_Index :: struct {
	using base: Expr_Base,
	operand:    Expr,
	indices:    []Expr,
	// A user `operator([])`: the arguments in parameter order, receiver first.
	// The resolution names the overload; an `inout` result makes this a place.
	bound:      []Expr,
	// design.md "Maps": `m[key]` in a *place* position inserts the zero value
	// when the key is absent, while a read of the same syntax does not. Which one
	// this occurrence is comes from its position, so the checker records it.
	map_inserts: bool,
	// A comma-ok destination, which gives `m[key]` its `(V, bool)` shape.
	map_optional: bool,
}

// `x[lo:hi]`; either endpoint may be nil.
Expr_Slice :: struct {
	using base: Expr_Base,
	operand:    Expr,
	lo:         Expr,
	hi:         Expr,
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
}

// The compiler-defined operations a `meta.Field` descriptor supplies. Their
// result type follows the descriptor constant, so they are recognised at the
// call rather than found by method lookup.
Reflect_Op :: enum {
	None,
	Field_Get,
	Field_Pointer,
}

// design.md "string type" and "string type conversions": the operations a text
// carrier answers to. They are compiler-defined rather than library members
// because their operand types are built in and their results follow the carrier
// (m6a-plan step 4).
Text_Op :: enum {
	None,
	Byte_Len,   // O(1), and what `len(text)` is shorthand for
	Rune_Count, // O(n) Unicode scalar values
	Bytes,      // a read-only borrowed []u8
	Copy,       // an independent managed byte copy
	To_C_View,  // a zero-terminated borrow for the complete expression
	To_Runes,   // `st.to_runes()`, a `[dynamic]rune` by copy
	From_Runes, // `string.from_runes(runes)`, validating, optional-ok
}

// The compiler-defined operation available on every union value. It is kept
// separate from ordinary method lookup so a union cannot replace the meaning
// of runtime variant inspection.
Union_Op :: enum {
	None,
	Active_Typeid,
}

// design.md "string type conversions": the conversions that validate their
// input, and therefore have optional-ok results rather than a plain value.
Text_Conversion :: enum {
	None,
	String_From_Bytes,  // `string(bytes)`   — validate and copy
	View_From_Bytes,    // `string_view(bytes)` — validate and borrow
	String_From_C_View, // `string(cview)`   — scan, validate, and copy
}

// A call, a conversion, or a generic application — syntax cannot tell them
// apart, and M2's name resolution does not need it to.
Expr_Call :: struct {
	using base: Expr_Base,
	callee:     Expr,
	args:       []Argument,
	// Arguments in parameter order after names and defaults are resolved. This
	// is what the backend evaluates; `args` stays the written syntax.
	bound:      []Expr,
	// `field.get(value)` / `field.pointer(value)`, with the struct field the
	// descriptor selected.
	reflect:       Reflect_Op,
	reflect_field: Symbol_Id,
	// `text.byte_len()`, `text.bytes()`, and the rest of the text surface.
	text:            Text_Op,
	// `value.active_typeid()` on a union.
	union_op:        Union_Op,
	// A validating text conversion, which has optional-ok results.
	text_conversion: Text_Conversion,
	// design.md "Variadic parameters". `variadic_slot` is the packed parameter's
	// index, or -1. `variadic_forwards` marks the sole-spread case, where
	// `bound[variadic_slot]` is the slice itself; otherwise the explicit
	// `variadic_elements` and the `variadic_spreads` are concatenated in
	// `variadic_order` (true = the next spread, false = the next element).
	is_variadic:       bool,
	variadic_slot:     int,
	variadic_forwards: bool,
	variadic_elements: []Expr,
	variadic_spreads:  []Expr,
	variadic_order:    []bool,
	// The witness a `(dyn I)(&value)` conversion selected, or nil.
	dyn_witness:   ^Witness,
	// A slot call through a `dyn` value: its index in the witness.
	dyn_slot:      int,
	is_dyn_call:   bool,
	// `new(T)` / `new_clone(value)`: the allocated element type. The backend
	// needs its size, and the checker records it so the pointee is not
	// re-derived from the result type (m5a-plan step 3).
	alloc_type:    Type_Id,
}

// The suffixes that take no operand: `^` and `or_return`.
Expr_Postfix :: struct {
	using base: Expr_Base,
	op:         Token_Kind,
	op_span:    Span,
	operand:    Expr,
}

Expr_Unary :: struct {
	using base: Expr_Base,
	op:         Token_Kind,
	op_span:    Span,
	operand:    Expr,
}

Expr_Binary :: struct {
	using base: Expr_Base,
	op:         Token_Kind,
	op_span:    Span,
	lhs:        Expr,
	rhs:        Expr,
	// `a != b` reached through the `!(a == b)` fallback: the resolution names the
	// `==` overload and the result is negated (design.md "Operator declarations").
	negated:    bool,
}

// `a ..= b` and `a ..< b`. Kept apart from Expr_Binary so a phase that only
// understands arithmetic cannot silently treat a range as one.
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
	fallback:   Expr,
}

// `then if cond else otherwise`, in source order.
Expr_Cond :: struct {
	using base: Expr_Base,
	then:       Expr,
	cond:       Expr,
	otherwise:  Expr,
}

Expr_Move :: struct {
	using base: Expr_Base,
	value:      Expr,
}

// `Element`. A nil `key` is an unkeyed element.
Element :: struct {
	span:  Span,
	key:   Expr,
	value: Expr,
}

// `T{...}`, or `{...}` taking its type from context when `type` is nil.
Expr_Composite :: struct {
	using base: Expr_Base,
	type_expr:  Expr,
	elements:   []Element,
	// A borrowed managed element has value semantics: constructing the aggregate
	// clones it, while a temporary or explicit move transfers it. Kept parallel
	// to `elements` so the backend never has to reclassify ownership.
	element_clones: []bool,
	// A slice literal's hidden fixed-array root (design.md "Slice literals"). The
	// literal's own `type` is the slice; this is the `[N]T` the backend gives
	// storage and then slices. INVALID_TYPE for every other literal.
	backing:    Type_Id,
	// m6b-plan decision "Allocator binding": "A container literal initializing or
	// replacing a known destination constructs directly with that destination's
	// selected allocator rather than allocating a default-backed temporary
	// first." This is that destination's written `via`, or nil.
	via:        Expr,
}

Type_Pointer :: struct {
	using base: Expr_Base,
	elem:       Expr,
}

Type_Multi_Pointer :: struct {
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

// `[N]T`, and `[?]T` where `inferred` is set and `length` is nil.
Type_Array :: struct {
	using base: Expr_Base,
	length:     Expr,
	inferred:   bool,
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
Type_Dyn :: struct {
	using base:     Expr_Base,
	interface_expr: Expr,
}

// The `type` keyword: the compile-time-only type of types.
Type_Type :: struct {
	using base: Expr_Base,
}

// `$T` and `$T: Constraint`.
Type_Poly :: struct {
	using base: Expr_Base,
	name:       Name,
	constraint: Expr,
}

Param_Mode :: enum {
	Value,
	Inout,
	Move,
	Variadic,
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

// `Result_Item`. An unnamed result has no `names`.
Result :: struct {
	span:     Span,
	names:    []Name,
	is_inout: bool,
	type:     Expr,
	symbols:  []Symbol_Id,
}

// `Proc_Type`: a signature with no body.
Type_Proc :: struct {
	using base: Expr_Base,
	convention: string, // the calling-convention literal's spelling, or ""
	params:     []Parameter,
	results:    []Result,
}

// `Proc_Literal`: a signature plus a block, or `---` for a bodiless
// declaration.
Expr_Proc :: struct {
	using base:    Expr_Base,
	signature:     ^Type_Proc,
	where_clauses: []Expr,
	body:          ^Block,
	bodiless:      bool,
	// The procedure this literal becomes. A nested literal is hoisted to its own
	// module function under this symbol.
	symbol:        Symbol_Id,
	// Cleanup slots this body needs, allocated in the entry block.
	defer_count:   int,
	// A cloned generic instantiation. Its `$` parameters were consumed at
	// instantiation time and are not part of the instance's runtime signature.
	generic_instance: bool,
}

// `proc { a, b }`
Expr_Proc_Group :: struct {
	using base: Expr_Base,
	names:      []Name,
}

// `operator(+) proc ...`. The symbol is canonical text because `[]=` and `[:]`
// are several tokens.
Expr_Operator :: struct {
	using base:  Expr_Base,
	symbol:      string,
	symbol_span: Span,
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

// `struct` and `union` differ only in their body, so one node carries both:
// `fields` for a struct, `variants` for a union.
Type_Record :: struct {
	using base:     Expr_Base,
	kind:           Record_Kind,
	generic_params: []Generic_Param,
	attributes:     []Attribute,
	where_clauses:  []Expr,
	fields:         []Field,
	variants:       []Expr,
}

Type_Enum :: struct {
	using base: Expr_Base,
	backing:    Expr, // nil when the backing type is omitted
	fields:     []Enum_Field,
}

Type_Interface :: struct {
	using base:     Expr_Base,
	generic_params: []Generic_Param,
	requirements:   []Requirement,
}

// Every variant embeds Expr_Base first, so one switch serves every accessor.
// Odin's exhaustiveness check makes adding a node kind a compile error until
// this is updated, which is the point.
expr_base :: proc(e: Expr) -> ^Expr_Base {
	switch v in e {
	case ^Expr_Error:
		return &v.base
	case ^Expr_Literal:
		return &v.base
	case ^Expr_Ident:
		return &v.base
	case ^Expr_Selector:
		return &v.base
	case ^Expr_Checked_Extract:
		return &v.base
	case ^Expr_Index:
		return &v.base
	case ^Expr_Slice:
		return &v.base
	case ^Expr_Call:
		return &v.base
	case ^Expr_Postfix:
		return &v.base
	case ^Expr_Unary:
		return &v.base
	case ^Expr_Binary:
		return &v.base
	case ^Expr_Range:
		return &v.base
	case ^Expr_Or_Else:
		return &v.base
	case ^Expr_Cond:
		return &v.base
	case ^Expr_Move:
		return &v.base
	case ^Expr_Composite:
		return &v.base
	case ^Expr_Proc:
		return &v.base
	case ^Expr_Proc_Group:
		return &v.base
	case ^Expr_Operator:
		return &v.base
	case ^Type_Pointer:
		return &v.base
	case ^Type_Multi_Pointer:
		return &v.base
	case ^Type_Slice:
		return &v.base
	case ^Type_Dynamic_Array:
		return &v.base
	case ^Type_Array:
		return &v.base
	case ^Type_Map:
		return &v.base
	case ^Type_Distinct:
		return &v.base
	case ^Type_Dyn:
		return &v.base
	case ^Type_Type:
		return &v.base
	case ^Type_Poly:
		return &v.base
	case ^Type_Proc:
		return &v.base
	case ^Type_Record:
		return &v.base
	case ^Type_Enum:
		return &v.base
	case ^Type_Interface:
		return &v.base
	}
	return nil
}

expr_span :: proc(e: Expr) -> Span {
	base := expr_base(e)
	return base == nil ? no_span() : base.span
}

expr_has_error :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base.has_error
}

// Statements, declarations and top-level items share a base. All three can
// carry attributes; which attribute is valid where is a semantic rule, not a
// grammatical one (grammar.md "Attributes").
Node_Base :: struct {
	span:       Span,
	has_error:  bool,
	attributes: []Attribute,
}

// `Attribute`. The qualified form is an extension attribute, as in
// `@(compiler.no_alias)`.
Attribute :: struct {
	span:  Span,
	path:  []Name,
	value: Expr, // nil unless the attribute was written `name = value`
}

Stmt :: union {
	^Decl,
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
	^Block,
}

Stmt_Error :: struct {
	using base: Node_Base,
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
	// design.md "Assignment statements": assigning a managed owner deep-copies,
	// and the destination's previous value is dropped once the clone succeeded.
	// One entry per right side, and the destination's liveness at this statement,
	// filled by `src/lifecycle.odin` (m5a-plan step 4).
	rhs_clones:       []bool,
	destination_live: []Liveness,
	// A user compound assignment: either a direct `+=` overload, or the binary
	// `+` overload the fallback rule reaches. INVALID_SYMBOL for a built-in one.
	operator:        Symbol_Id,
	operator_direct: bool,
	// `grid[x, y] = v` reaching `operator([]=)`, with the receiver, indices and
	// value already bound in parameter order.
	place_setter:    Symbol_Id,
	setter_bound:    []Expr,
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

// `"$"? "&"? (Identifier | "_")`. A `$` binding is a static expansion.
Foreach_Binding :: struct {
	name:      Name,
	is_static: bool,
	is_ref:    bool,
	symbol:    Symbol_Id,
}

// How the checker resolved a `foreach`. A range and a fixed array lower
// directly to an index loop; a user type goes through `iter`/`next`.
Foreach_Kind :: enum {
	Unresolved,
	Static,
	Range,
	Stored_Range,
	Array,
	Slice,
	// design.md "Dynamic arrays": an index loop over the current allocation,
	// bounded by the header's length word rather than a static count.
	Dynamic,
	// design.md "Maps": a slot walk. "**Iteration order is unspecified.**" The
	// two-name form binds the key and the value rather than a value and an index.
	Map,
	// design.md "String iteration": yields Unicode scalar values, and "the second
	// name in a string loop is a byte offset, not a rune counter".
	Text,
	Protocol,
}

Stmt_Foreach :: struct {
	using base: Node_Base,
	bindings:   []Foreach_Binding,
	iterable:   Expr,
	body:       ^Block,
	// Semantic result, written by the checker and read by the backend.
	kind:          Foreach_Kind,
	element_type:  Type_Id,
	// A map's key type, bound by the first of two names.
	key_type:      Type_Id,
	count:         u64,       // a fixed array's length
	iterator_type: Type_Id,   // the protocol path's opaque iterator
	iter_symbol:   Symbol_Id,
	next_symbol:   Symbol_Id,
	// A static expansion's checked copies, one per element, in iterable order.
	// This is expansion rather than a loop, so the backend emits them in
	// sequence and `body` is never emitted (design.md "Static `foreach`
	// expansion").
	expansion:  []^Block,
}

// Structural source selection, not a constant `if`: only the selected branch is
// declared, checked, and emitted, and it introduces no scope of its own
// (m3-plan decision "Selected source representation").
Stmt_When :: struct {
	using base: Node_Base,
	cond:       Expr,
	then:       ^Block,
	otherwise:  Stmt,
	// Semantic result, written by the checker and read by the backend.
	resolved:   bool,
	selected:   ^Block, // nil when no branch was taken
}

Switch_Kind :: enum {
	Value,
	Type,
}

// `Value_Case` and `Type_Case` are one shape once types and expressions share a
// node domain: a list, or none for the default case.
Switch_Case :: struct {
	span:   Span,
	values: []Expr,
	stmts:  []Stmt,
	// A type switch binds one name per case: at the variant's type for a
	// single-type case, and at the union's type for a multiple-type or default
	// case, where the active variant is not known.
	binding_symbol: Symbol_Id,
	binding_type:   Type_Id,
}

Stmt_Switch :: struct {
	using base: Node_Base,
	kind:       Switch_Kind,
	init:       Stmt,
	binding:    Name, // the type switch's `Binding_Name`
	binding_symbol: Symbol_Id,
	subject:    Expr,
	cases:      []Switch_Case,
}

Stmt_Defer :: struct {
	using base: Node_Base,
	stmt:       Stmt,
	// Position of this registration's flag in the enclosing procedure's entry
	// block, assigned while checking the body.
	slot:       int,
}

// `"inout"? Expression`
Return_Value :: struct {
	span:     Span,
	is_inout: bool,
	expr:     Expr,
	// design.md "Parameter semantics": "Returning such a borrowed managed
	// parameter by value performs a logical clone, because the callee owns
	// nothing it could move out." Returning an owned local, named result,
	// temporary, or `move` parameter transfers instead (m5a-plan step 4).
	clone_on_return: bool,
}

Stmt_Return :: struct {
	using base: Node_Base,
	values:     []Return_Value,
}

Stmt_Branch :: struct {
	using base: Node_Base,
	kind:       Token_Kind, // `.Break` or `.Continue`
}

// The statement mirror of `expr_base`: every variant embeds `Node_Base` first,
// so one switch serves every accessor.
stmt_base :: proc(s: Stmt) -> ^Node_Base {
	switch v in s {
	case ^Decl:
		return &v.base
	case ^Stmt_Error:
		return &v.base
	case ^Stmt_Expr:
		return &v.base
	case ^Stmt_Assign:
		return &v.base
	case ^Stmt_If:
		return &v.base
	case ^Stmt_For:
		return &v.base
	case ^Stmt_Foreach:
		return &v.base
	case ^Stmt_When:
		return &v.base
	case ^Stmt_Switch:
		return &v.base
	case ^Stmt_Defer:
		return &v.base
	case ^Stmt_Return:
		return &v.base
	case ^Stmt_Branch:
		return &v.base
	case ^Block:
		return &v.base
	}
	return nil
}

stmt_span :: proc(s: Stmt) -> Span {
	base := stmt_base(s)
	return base == nil ? no_span() : base.span
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

Duration :: enum {
	None,
	Static,
	Thread_Local,
}

// One declaration, covering `x: int;`, `x: int = e;`, `x := e;` and
// `x: int : e;`. A `nil` entry in `values` is the uninitialised-storage marker
// `---`; an omitted initialiser leaves `values` empty instead.
Decl :: struct {
	using base:    Node_Base,
	kind:          Decl_Kind,
	names:         []Name,
	duration:      Duration,
	manual:        bool,
	declared_type: Expr, // nil when the type is inferred
	via:           Expr, // the `via` allocator expression, or nil
	values:        []Expr,
	symbols:       []Symbol_Id,
	// One entry per initialiser: whether it copies a managed place someone else
	// owns, rather than transferring a value it already owns.
	value_clones:  []bool,
	top_level:     bool,
	// Signature resolution and body checking have separate readiness states: the
	// compile-time evaluator may need a procedure's body before the phase that
	// would ordinarily check it (m3-plan decision "Evaluation readiness").
	sig_state:     Check_State,
	check_state:   Check_State,
}

// The `name :: proc() { ... }` shape: a constant whose one value is a procedure
// literal. There is no second representation for a procedure — a `proc` in
// expression position builds the same node.
decl_proc :: proc(d: ^Decl) -> ^Expr_Proc {
	if d.kind != .Const || len(d.values) != 1 {
		return nil
	}
	literal, ok := d.values[0].(^Expr_Proc)
	if !ok {
		return nil
	}
	return literal
}

// The procedure body a declaration binds, looking through `operator(sym)`. An
// operator implementation is an ordinary named procedure, so everything that
// names, checks, or emits one wants this rather than `decl_proc`.
decl_proc_literal :: proc(d: ^Decl) -> ^Expr_Proc {
	if literal := decl_proc(d); literal != nil {
		return literal
	}
	if d.kind != .Const || len(d.values) != 1 {
		return nil
	}
	if operator, is_operator := d.values[0].(^Expr_Operator); is_operator {
		if literal, is_proc := operator.value.(^Expr_Proc); is_proc {
			return literal
		}
	}
	return nil
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
}

Item_Error :: struct {
	using base: Node_Base,
}

// `import "core:fmt";` and the aliased `import f "core:fmt";`
Item_Import :: struct {
	using base: Node_Base,
	alias:      Name,   // empty when no local name was written
	path:       string, // the string literal's spelling
	// Discovery is monotonic, but selected `when` branches may insert imports
	// anywhere in the active view. Track this item rather than a list prefix.
	bound:      bool,
}

// `foreign import raylib "raylib.lib";`
Item_Foreign_Import :: struct {
	using base: Node_Base,
	name:       Name,
	path:       string,
}

// `foreign raylib { ... }`. Members are declarations, per grammar.md's
// `Foreign_Decl`, and end where a constant of the same shape would.
Item_Foreign_Block :: struct {
	using base: Node_Base,
	library:    Name,
	members:    []Item,
}

// Whether an `impl` block is *inherent* to its subject or *extends* a subject
// from elsewhere. Not written: `declare_impl_block` derives it from whether the
// subject's declaring package is this one, so a built-in or foreign subject is
// always an extension. Until then it is `.Unresolved`.
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
	// The resolved subject, and whether member symbols have been created. The
	// discovery fixed point re-prepares a package each round, so this is what
	// keeps a second round from installing the same members twice.
	subject:    Type_Id,
	declared:   bool,
}

// `delegate(+, -);` inside an `impl` body.
Item_Delegate :: struct {
	using base: Node_Base,
	symbols:    []string,
}

// File-scope `when`, whose branches are blocks of top-level items.
//
// Activation is monotonic: once `resolved` is set the choice never changes, and
// only the taken branch contributes to `File.active_items`.
Item_When :: struct {
	using base: Node_Base,
	cond:       Expr,
	then:       ^Item_Block,
	otherwise:  Item, // `^Item_When` for `else when`, `^Item_Block` for `else`
	resolved:   bool,
	taken:      bool, // this node's own condition was true
}

// `Top_Level_Block`
Item_Block :: struct {
	using base: Node_Base,
	items:      []Item,
}

item_base :: proc(item: Item) -> ^Node_Base {
	switch v in item {
	case ^Decl:
		return &v.base
	case ^Item_Error:
		return &v.base
	case ^Item_Import:
		return &v.base
	case ^Item_Foreign_Import:
		return &v.base
	case ^Item_Foreign_Block:
		return &v.base
	case ^Item_Impl:
		return &v.base
	case ^Item_Delegate:
		return &v.base
	case ^Item_When:
		return &v.base
	case ^Item_Block:
		return &v.base
	}
	return nil
}

item_span :: proc(item: Item) -> Span {
	base := item_base(item)
	return base == nil ? no_span() : base.span
}

File :: struct {
	// All syntax nodes and syntax-owned slices live in this arena. The source
	// manager owns source text separately, so source-backed names remain valid.
	arena:        mem.Dynamic_Arena,
	file:         u32,
	attributes:   []Attribute, // on the package clause
	package_name: string,
	package_span: Span,
	items:        []Item,
	// The compilation-owned selected view: `items` with every selected `when`
	// branch and every `Item_Block` flattened in place, in original source order.
	// Every semantic consumer iterates this, never `items` (m3-plan decision
	// "Selected source representation"). `-dump-ast` still prints `items`.
	active_items: []Item,
}

destroy_ast :: proc(f: ^File) {
	mem.dynamic_arena_destroy(&f.arena)
}
