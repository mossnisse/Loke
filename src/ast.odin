// AST. Every node carries a Span, and the checker annotates the nodes in place
// (decision A1). Types and expressions share one node domain, since the grammar
// cannot tell `Matrix(f32, 4)` from `f(a, b)`; `parse_type` restricts type
// positions, and the checker decides what syntax cannot.
package lokec

import "core:mem/virtual"

Expr_Base :: struct {
	span:          Span,
	type:          Type_Id,
	denoted_type:  Type_Id, // non-zero when this expression denotes a type
	const_value:   Const_Value,
	is_const:      bool,
	resolution:    Resolution,
	value_category: Value_Category,
	// Independent place facts: a value parameter is addressable, not assignable.
	addressable:  bool,
	assignable:   bool,
	immutable:    Immutable_Reason,
	// The concrete type erased into the `any_view` that `type` names.
	erased_from: Type_Id,
	// A `string` borrowed as a `string_view`, or a `[dynamic]T` as a `[]T`: the
	// source type to narrow from.
	view_from:   Type_Id,
	// A scalar widened to a SIMD vector: the lane type to splat from.
	splat_from:  Type_Id,
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
}

// `x.(T)` traps and yields one value; `x.as(T)` yields `(T, bool)`.
Extract_Mode :: enum {
	Trap,
	Optional,
}

// `x.(T)`, and the node `x.as(T)` resolves to.
Expr_Checked_Extract :: struct {
	using base: Expr_Base,
	operand:    Expr,
	target:     Expr,
	mode:       Extract_Mode,
	// The requested type; `type` is `Option(T)` for `.as(T)`.
	payload:    Type_Id,
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

// The compiler-defined operations of a `meta.Field` descriptor.
Reflect_Op :: enum {
	None,
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
	From_Runes, // `string.from_runes(runes)`, validating, optional-ok
}

// The named UTF-8 constructors, which validate and return Option(T).
Text_Conversion :: enum {
	None,
	String_From_Bytes,  // `string.from_utf8(bytes)` — validate and copy
	View_From_Bytes,    // `string_view.from_utf8(bytes)` — validate and borrow
	String_From_C_View, // `string.from_utf8(cview)` — scan, validate, and copy
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
	Call_Extract,
	Call_Text_Conversion,
	Call_Atomic,
	Call_Sort_By,
	Call_Simd_Reduce,
	Call_Dyn_Conversion,
	Call_Dyn_Slot,
	Call_Allocation,
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
// The same checked extraction node used by the postfix spelling.
Call_Extract :: struct { node: ^Expr_Checked_Extract }
Call_Text_Conversion :: struct { op: Text_Conversion }
// Orderings and the element type are settled during checking, not runtime args.
Call_Atomic :: struct { type: Type_Id, order: int, failure_order: int }
Call_Sort_By :: struct { comparator: Symbol_Id }
Call_Simd_Reduce :: struct { fold: Simd_Fold }
// A nil witness represents conversion of a nil pointer to a nil dyn view.
Call_Dyn_Conversion :: struct { witness: ^Witness }
Call_Dyn_Slot :: struct { index: int }
// The element of new/new_clone, or the container type of make.
Call_Allocation :: struct { type: Type_Id }

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
	// The members overload resolution chose among, when there were several; only
	// diagnostics read it.
	overload_members: []Symbol_Id,
	// `variadic_slot` is the packed parameter, or -1. `variadic_forwards` passes
	// one spread slice through; otherwise elements and spreads are concatenated
	// in `variadic_order` (true = next spread, false = next element).
	is_variadic:       bool,
	variadic_slot:     int,
	variadic_forwards: bool,
	variadic_elements: []Expr,
	variadic_spreads:  []Expr,
	variadic_order:    []bool,
}

// The suffixes that take no operand: `^` and `or_return`.
Expr_Postfix :: struct {
	using base: Expr_Base,
	// Over a place, the payloads are copied out and the source stays live.
	borrows:    bool,
	op:         Token_Kind,
	op_span:    Span,
	operand:    Expr,
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
	fallback:   Expr,
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
	// Struct field slots in source order, resolved during checking.
	field_indices: []int,
	// Per element: a borrowed managed element is cloned, not moved.
	element_clones: []bool,
	// A slice literal's hidden `[N]T` storage; INVALID_TYPE otherwise.
	backing:    Type_Id,
	// The destination's `via` a container literal constructs with, or nil.
	via:        Expr,
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

// `$T` and `$T: Constraint`.
Type_Poly :: struct {
	using base: Expr_Base,
	name:       Name,
	constraint: Expr,
}

// `Borrow` is a `self: ^` receiver, or a synthesized member's read-only receiver:
// passed by address, which method syntax takes implicitly. It is last because a mode number
// reaches the type identity key (`typeid_sort_key_walk`).
Param_Mode :: enum {
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
	type:     Expr,
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

Hook_Kind :: enum {
	None,
	Convert,
	Copy,
	Drop,
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

// `fields` for a struct, `variants` for a union.
Type_Record :: struct {
	using base:     Expr_Base,
	kind:           Record_Kind,
	move_only:      bool,
	generic_params: []Generic_Param,
	attributes:     []Attribute,
	where_clauses:  []Expr,
	fields:         []Field,
	variants:       []Variant,
}

// `(name: Type, ...)`: the anonymous structural record.
Type_Anon_Record :: struct {
	using base: Expr_Base,
	fields:     []Field,
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

// Exhaustive, so a new node kind is a compile error here.
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
	case ^Type_C_Pointer:
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
	case ^Type_Anon_Record:
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

// A header adapter traversing the same iterable differently.
Foreach_Adapter :: enum {
	None,
	Reversed,
}

Stmt_Foreach :: struct {
	using base: Node_Base,
	bindings:   []Foreach_Binding,
	iterable:   Expr,
	body:       ^Block,
	// Written by the checker, read by the backend.
	kind:          Foreach_Kind,
	adapter:       Foreach_Adapter,
	// `indexed()`, always the outermost adapter.
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
	Type,
	// A union switch with per-case `.variant(binding)`; the checker turns a
	// `Value` switch over a union into this.
	Pattern,
}

// A case's values, or none for the default case.
Switch_Case :: struct {
	span:   Span,
	values: []Expr,
	stmts:  []Stmt,
	// The binding in `.variant(name)`, or empty.
	binding: Name,
	// A type switch's per-case binding: the payload type for one variant, the
	// union type for a grouped or default case.
	binding_symbol: Symbol_Id,
	binding_type:   Type_Id,
	// A union switch's cases as variant indices.
	variant_indices: []int,
}

Stmt_Switch :: struct {
	using base: Node_Base,
	kind:       Switch_Kind,
	init:       Stmt,
	binding:    Name, // the traditional type switch's header `Binding_Name`
	subject:    Expr,
	cases:      []Switch_Case,
	// Every path enters a case: all variants covered, or a default.
	exhaustive: bool,
}

Stmt_Defer :: struct {
	using base: Node_Base,
	stmt:       Stmt,
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

stmt_base :: proc(s: Stmt) -> ^Node_Base {
	switch v in s {
	case ^Decl:
		return &v.base
	case ^Item_Impl:
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
}

// The literal of `name :: proc() { ... }`, or nil.
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

// As `decl_proc`, but also looking through `operator(sym)` and hooks.
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

decl_hook_kind :: proc(d: ^Decl) -> Hook_Kind {
	if d == nil || d.kind != .Const || len(d.values) != 1 {
		return .None
	}
	if wrapper, ok := d.values[0].(^Expr_Operator); ok {
		return wrapper.hook
	}
	return .None
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
	members:    []Item,
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

// File-scope `when`. Once `resolved`, the choice is final, and only the taken
// branch reaches `File.active_items`.
Item_When :: struct {
	using base: Node_Base,
	cond:       Expr,
	then:       ^Item_Block,
	otherwise:  Item, // `^Item_When` for `else when`, `^Item_Block` for `else`
	resolved:   bool,
	taken:      bool, // this node's own condition was true
	// Reported as unanswerable, and selects nothing.
	stalled:    bool,
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
	case ^Item_Static_Assert:
		return &v.base
	}
	return nil
}

item_span :: proc(item: Item) -> Span {
	base := item_base(item)
	return base == nil ? no_span() : base.span
}

File :: struct {
	// Owns all syntax; source text lives with the source manager.
	arena:        virtual.Arena,
	file:         u32,
	attributes:   []Attribute, // on the package clause
	package_name: string,
	package_span: Span,
	items:        []Item,
	// `items` with selected `when` branches flattened in, in source order. The
	// checker reads this; `-dump-ast` prints `items`.
	active_items: []Item,
}

destroy_ast :: proc(f: ^File) {
	virtual.arena_destroy(&f.arena)
}
