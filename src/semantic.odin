// Stable semantic identities and compilation-owned stores (compiler-plan
// A8/B5-B8). Syntax nodes contain IDs into these stores, never pointers to
// reallocating arrays or backend-specific state.
package lokec

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

Identifier_Id :: distinct u32
Symbol_Id     :: distinct u32
Type_Id       :: distinct u32
Package_Id    :: distinct u32

INVALID_IDENTIFIER :: Identifier_Id(0)
INVALID_SYMBOL     :: Symbol_Id(0)
INVALID_TYPE       :: Type_Id(0)
INVALID_PACKAGE    :: Package_Id(0)

// The predeclared types, in the order `init_semantic_stores` appends them.
// Every one of these is a distinct identity: `int` is not `i64` and `rune` is
// not `i32`, so an assignment between them needs a written conversion.
TYPE_VOID     :: Type_Id(1)
TYPE_BOOL     :: Type_Id(2)
TYPE_I8       :: Type_Id(3)
TYPE_I16      :: Type_Id(4)
TYPE_I32      :: Type_Id(5)
TYPE_I64      :: Type_Id(6)
TYPE_I128     :: Type_Id(7)
TYPE_U8       :: Type_Id(8)
TYPE_U16      :: Type_Id(9)
TYPE_U32      :: Type_Id(10)
TYPE_U64      :: Type_Id(11)
TYPE_U128     :: Type_Id(12)
TYPE_INT      :: Type_Id(13)
TYPE_UINT     :: Type_Id(14)
TYPE_UINTPTR  :: Type_Id(15)
TYPE_F16      :: Type_Id(16)
TYPE_F32      :: Type_Id(17)
TYPE_F64      :: Type_Id(18)
TYPE_RUNE     :: Type_Id(19)
TYPE_RAWPTR   :: Type_Id(20)
TYPE_TYPE     :: Type_Id(21)

// `string` became an owning runtime carrier in M6a; `typeid` and `any_view`
// became real runtime types in M4b.
TYPE_STRING   :: Type_Id(22)
TYPE_TYPEID   :: Type_Id(23)
TYPE_ANY_VIEW :: Type_Id(24)

TYPE_UNTYPED_INT   :: Type_Id(25)
TYPE_UNTYPED_FLOAT :: Type_Id(26)
TYPE_UNTYPED_BOOL  :: Type_Id(27)
TYPE_UNTYPED_RUNE  :: Type_Id(28)
TYPE_UNTYPED_NIL   :: Type_Id(29)
// A compile-time string. It may be concatenated, compared, measured, and used
// as a configuration value or diagnostic message. It is not a runtime carrier:
// where a value is wanted it defaults to `string` (m3-plan decision
// "Strings").
TYPE_UNTYPED_STRING :: Type_Id(30)

// A borrowed view over UTF-8 text: a pointer and a byte length, and no
// allocator. design.md "string type conversions": it "has the same byte, rune,
// and iteration operations as `string`, but it has no allocator and does not own
// or terminate its storage".
TYPE_STRING_VIEW :: Type_Id(31)

// design.md "Allocators" and "Allocation failure". `core:mem` and `base:runtime`
// export exactly these identities rather than declaring their own: the
// catalogue's `Cloneable` and the fixed lifecycle signatures spell them
// unqualified, so they stay predeclared as well (m6a-plan decision
// "Compiler-owned names").
//
// `Allocator` is a one-word nominal handle pointing at the seed runtime's
// provider record. Per-expression region identity is semantic metadata in
// `src/borrow.odin`, not part of the type or the ABI.
TYPE_ALLOCATOR :: Type_Id(32)
// A nil-comparable error code. Nil is success, so `err != nil` is the whole
// interface an explicitly fallible operation needs.
TYPE_ALLOCATOR_ERROR :: Type_Id(33)

// design.md "C string views": a non-owning, zero-terminated byte view — the type
// a C `char const *` maps to. One word, and deliberately not a promise of UTF-8.
TYPE_CSTRING_VIEW :: Type_Id(34)

FIRST_DYNAMIC_TYPE :: Type_Id(35)

Type_Kind :: enum {
	Invalid,
	Void,
	Bool,
	Int,
	Float,
	Rune,
	Raw_Pointer,
	Untyped_Int,
	Untyped_Float,
	Untyped_Bool,
	Untyped_Rune,
	Untyped_Nil,
	Untyped_String,
	String,
	String_View,
	CString_View,
	Typeid,
	Any_View,
	Pointer,
	Multi_Pointer,
	Slice,
	// design.md "Allocators": a nominal runtime handle, and a nil-comparable
	// error code. Both are compiler-owned identities that `core:mem` exports.
	Allocator,
	Allocator_Error,
	Dynamic_Array,
	Array,
	Map,
	Distinct,
	Proc,
	Struct,
	Enum,
	Union,
	Interface,
	Dyn,
	Type,
}

// A member set the compiler installs on a type rather than the user writing it.
Contribution :: enum u8 {
	Iteration,
	Lifecycle,
	// design.md "Dynamic arrays" and "Maps": the operation set the compiler
	// contributes to a container type, so `xs.append(1)` is an ordinary method
	// call and generic code finds the same members (m6b-plan step 2).
	Container,
}

Type_Info :: struct {
	kind:       Type_Kind,
	name:       Identifier_Id,
	symbol:     Symbol_Id,
	element:    Type_Id,
	key:        Type_Id,
	count:      u64,
	// Scalar shape. `bits` is the width in bits of an integer, float, rune or
	// enum backing; `signed` distinguishes `i32` from `u32`.
	bits:       u16,
	signed:     bool,
	mutable:    bool,
	// Struct fields and enum members, in declaration order. Each symbol carries
	// its own type, index, and (for an enum member) discriminant.
	fields:     []Symbol_Id,
	// A union's variants, in declaration order. Variant 0 is the first written
	// one; tag 0 is nil (m4a-plan decision "Union representation").
	variants:   []Type_Id,
	// A validated `union @(align=N)` or `struct @(align=N)`, or 0. Kept apart from
	// `align`, which the layout pass overwrites with the computed result:
	// `union_layout` is asked again by the emitter after that, and both must get
	// the same answer.
	written_align: u64,
	// design.md "@(packed)": this struct removes inter-field padding and has a
	// natural alignment of 1 (an `@(align=N)` may still raise it). (m7-plan step 2)
	packed:        bool,
	// Inherent members written by `impl`: methods, associated constants, and
	// associated types. `extend` never writes here — its members are package-scoped
	// and live in `Package.extensions` (m4a-plan decision "Method storage").
	members:    []Symbol_Id,
	// Which compiler-contributed member sets are already installed. More than one
	// contributor appends here — iteration for a range, array, or slice, and the
	// lifecycle hooks for a record — so "already has members" cannot be the
	// idempotence guard: whichever ran first would suppress the other.
	contributed: bit_set[Contribution],
	parameters: []Type_Id,
	param_modes: []Param_Mode,
	// design.md "Procedure types": "`@(allocator_reset)` is part of the
	// parameter's procedure type: a reset-capable procedure cannot be stored in a
	// procedure value whose type hides that effect."
	param_resets: []bool,
	// Foreign ABI adapters are part of procedure type identity. Erasing either
	// one changes the LLVM function type at an indirect call site.
	param_by_ptr: []bool,
	c_vararg:     bool,
	results:    []Type_Id,
	result_inout: []bool,
	convention: string,
	// Set once the finite-size check has visited this nominal type, so a cycle
	// is reported at one place instead of once per reference.
	size_state: Size_State,
	// A monomorphized instance of a generic record: the template it came from,
	// and the argument vector that produced it. Structural specialization matches
	// against these (m4b-plan step 1).
	instance_of:   Symbol_Id,
	instance_args: []Generic_Arg,
	// The backend spelling of an instance, kept apart from `name`, which is the
	// readable `Table(int, i32)` diagnostics use.
	mangled:       string,
	// A `dyn Interface(args...)` type: the interface it erases behind, and the
	// non-subject arguments of the application.
	dyn_interface: Symbol_Id,
	dyn_args:      []Generic_Arg,
	// A compiler-owned `Range(T)` value: low endpoint, high endpoint, and the
	// closed/half-open flag, so `..<` and `..=` survive being stored or passed
	// (m4b-plan decision "Runtime range representation").
	is_range:      bool,
	// A compiler-owned reflection descriptor. Its values are ordinary constant
	// aggregates, and this is the marker that forbids materializing one into
	// runtime storage (design.md "Compile-time reflection").
	descriptor:    bool,
	// One of the two local allocator-region providers, `mem.Arena` and
	// `mem.Scratch` (`src/region.odin`). The marker the lifecycle classifier, the
	// region lattice, and the drop path all read.
	provider:      bool,
	// Cached natural layout (`src/layout.odin`). `offsets` has one entry per
	// struct field, in declaration order.
	layout_state: Size_State,
	size:         u64,
	align:        u64,
	offsets:      []u64,
}

Size_State :: enum {
	Unchecked,
	Checking,
	Finite,
	Cyclic,
}

Type_Key :: struct {
	kind:    Type_Kind,
	element: Type_Id,
	key:     Type_Id,
	count:   u64,
}

// The one target M2 compiles for. Checker and emitter read the same widths, so
// `int` cannot mean 64 bits in one and 32 in the other.
Target_Info :: struct {
	triple:       string,
	pointer_bits: u16,
	int_bits:     u16,
	// The widest alignment a scalar takes. On x86-64 a 128-bit integer is
	// 16-aligned and nothing is wider, which is what LLVM's own data layout for
	// this triple says.
	max_align:    u16,
}

WINDOWS_X64 :: Target_Info {
	triple       = "x86_64-pc-windows-msvc",
	pointer_bits = 64,
	int_bits     = 64,
	max_align    = 16,
}

Const_Kind :: enum {
	Invalid,
	Integer,
	Boolean,
	Float,
	String,
	Rune,
	Nil,
	Type,
	Aggregate,
}

// Struct and array constants. Held behind a pointer so `Const_Value` stays a
// fixed-size value type that an AST node can embed.
Const_Aggregate :: struct {
	type:     Type_Id,
	elements: []Const_Value,
}

// Text is source/compilation backed; `integer` is arena-owned and immutable
// after publication (see `src/bigint.odin`).
Const_Value :: struct {
	kind:       Const_Kind,
	integer:    Big_Int, // Integer and Rune
	float:      f64,
	float_bits: u16,     // the semantic width a Float was last rounded to
	boolean:    bool,
	text:       string,
	type_value: Type_Id,
	aggregate:  ^Const_Aggregate,
}

integer_const :: proc(c: ^Compiler, value: Big_Int) -> Const_Value {
	return Const_Value{kind = .Integer, integer = value}
}

int_const :: proc(c: ^Compiler, value: i64) -> Const_Value {
	return Const_Value{kind = .Integer, integer = bi_from_i64(c, value)}
}

rune_const :: proc(c: ^Compiler, value: Big_Int) -> Const_Value {
	return Const_Value{kind = .Rune, integer = value}
}

bool_const :: proc(value: bool) -> Const_Value {
	return Const_Value{kind = .Boolean, boolean = value}
}

float_const :: proc(value: f64, bits: u16) -> Const_Value {
	return Const_Value{kind = .Float, float = round_float(value, bits), float_bits = bits}
}

nil_const :: proc() -> Const_Value {
	return Const_Value{kind = .Nil}
}

type_const :: proc(type: Type_Id) -> Const_Value {
	return Const_Value{kind = .Type, type_value = type}
}

// A typed float operation rounds to its own width after every step: folding an
// `f32` expression entirely in `f64` and rounding once at the end can disagree
// with what the same expression computes at runtime.
round_float :: proc(value: f64, bits: u16) -> f64 {
	switch bits {
	case 16:
		return f16_bits_to_f64(f64_to_f16_bits(value))
	case 32:
		return f64(f32(value))
	}
	return value
}

// IEEE-754 binary16, rounding to nearest with ties to even.
//
// Odin's own `f16(x)` conversion rounds halfway cases away from zero — it turns
// 2049 into 2050 where the hardware `fadd half` LLVM emits produces 2048. Every
// folded `f16` constant would then disagree with the same expression evaluated
// at runtime, so the conversion is done here instead.
f64_to_f16_bits :: proc(value: f64) -> u16 {
	pattern := transmute(u64)value
	sign := u16((pattern >> 48) & 0x8000)
	exponent := int((pattern >> 52) & 0x7ff)
	mantissa := pattern & 0x000f_ffff_ffff_ffff

	if exponent == 0x7ff {
		return mantissa != 0 ? sign | 0x7e00 : sign | 0x7c00 // NaN, or infinity
	}
	if exponent == 0 {
		return sign // zero, or an f64 subnormal, which is far below f16's range
	}

	unbiased := exponent - 1023
	if unbiased > 15 {
		return sign | 0x7c00 // beyond f16's largest finite value
	}
	significand := mantissa | (u64(1) << 52) // 53 bits, implicit bit included
	target_exponent := unbiased + 15
	shift := 42 // 52 explicit bits down to f16's 10
	if target_exponent <= 0 {
		// An f16 subnormal: the implicit bit moves into the stored mantissa.
		shift = 43 - target_exponent
		if shift > 63 {
			return sign
		}
		target_exponent = 0
	}

	dropped := significand & ((u64(1) << u64(shift)) - 1)
	result := significand >> u64(shift)
	halfway := u64(1) << u64(shift - 1)
	if dropped > halfway || (dropped == halfway && (result & 1) != 0) {
		result += 1
	}
	if target_exponent == 0 {
		// Rounding may have carried a subnormal up to the smallest normal, whose
		// encoding is the next value in sequence; no special case is needed.
		return sign | u16(result)
	}
	if result >= (u64(1) << 11) {
		result >>= 1
		target_exponent += 1
		if target_exponent >= 31 {
			return sign | 0x7c00
		}
	}
	return sign | u16(u64(target_exponent) << 10) | u16(result & 0x3ff)
}

f16_bits_to_f64 :: proc(bits: u16) -> f64 {
	sign := u64(bits & 0x8000) << 48
	exponent := int((bits >> 10) & 0x1f)
	mantissa := u64(bits & 0x3ff)

	switch {
	case exponent == 0x1f:
		pattern := sign | 0x7ff0_0000_0000_0000 | (mantissa != 0 ? u64(0x0008_0000_0000_0000) : 0)
		return transmute(f64)pattern
	case exponent == 0 && mantissa == 0:
		return transmute(f64)sign
	case exponent == 0:
		// Subnormal: `mantissa * 2^-24`, exact in f64 both times.
		magnitude := f64(mantissa) / 16777216.0
		return sign != 0 ? -magnitude : magnitude
	}
	pattern := sign | (u64(exponent - 15 + 1023) << 52) | (mantissa << 42)
	return transmute(f64)pattern
}

Resolution_Kind :: enum {
	Unresolved,
	Error,
	Value,
	Type,
	Package,
	Field,
	Method,
	Procedure_Group,
	Call,
	Conversion,
	Generic_Application,
	Builtin_Operator,
	User_Operator,
}

Value_Category :: enum {
	Invalid,
	Value,
	Place,
	Type,
}

// Why a readable place cannot be assigned to. A value parameter is addressable
// but immutable; a composite literal is addressable temporary storage; neither
// fact follows from the other, so the checker records both plus this reason
// (m2-plan decision "Place model").
Immutable_Reason :: enum {
	None,
	Constant,
	Value_Parameter,
	Temporary,
	Discard,
	Not_A_Place,
	// A place in read-only storage: an element of a `[]T`, or anything inside a
	// materialised constant. It is a real place — it has an address the backend
	// can read — but no operation may write it or hand out a `^T` to it.
	Read_Only,
}

Resolution :: struct {
	kind:            Resolution_Kind,
	symbol:          Symbol_Id,
	chosen_overload: Symbol_Id,
}

Symbol_Kind :: enum {
	Invalid,
	Var,
	Const,
	Proc,
	Proc_Group,
	Type,
	Package_Alias,
	Parameter,
	Result,
	Field,
	Enum_Member,
	Builtin,
}

// Which built-in a `Symbol_Kind.Builtin` symbol is. One shared `Builtin` kind
// with no identity would leave every built-in call indistinguishable at the
// point that has to lower it (m3-plan decision "Phase-neutral `assert`/`panic`").
Builtin_Kind :: enum {
	None,
	Assert,
	Panic,
	// design.md "Compile-time built-ins". Ordinary predeclared identifiers like
	// every other built-in: `static_assert` forces the compile-time phase that
	// plain `assert` inherits from its caller, `build_config` reads a `-define`
	// key, and the two location forms fold to a `runtime.Source_Code_Location`.
	Static_Assert,
	Build_Config,
	Source_Location,
	Caller_Location,
	Size_Of,
	Align_Of,
	Offset_Of,
	Len,
	// design.md "Dynamic arrays": `cap(value)` is the container header's third
	// word, and unlike `len` it has no fixed-array or text meaning.
	Cap,
	// design.md "Standard interface catalogue": the built-ins promised to satisfy
	// `Hashable` need an operation to satisfy it *with*, so the compiler
	// contributes one rather than the catalogue hard-coding a predicate.
	Hash,
	// Compile-time reflection (design.md "`type` and `typeid`", "Compile-time
	// reflection").
	Type_Of,
	Typeid_Of,
	Fields_Of,
	Enum_Values_Of,
	// design.md "Iteration protocol": `iter(value)` is a free call in the
	// `Iterable` requirement, so it has to resolve for a built-in and for a user
	// type's own `impl` member alike.
	Iter,
	// design.md "Standard customization procedures": `clone(value)` and
	// `try_clone(value)` are "written as free calls ... which is canonical and
	// always available". Both forward to the type's own fixed hook, so the free
	// call and `value.clone()` select one procedure.
	Clone,
	Try_Clone,
	// design.md "Allocators" and "Allocation failure". The explicitly fallible
	// primitives always return an error and never invoke a failure policy;
	// `free` returns no status. `free_all` lowers to the provider's reset entry
	// once region provenance has proved no dependant survives it.
	New,
	New_Clone,
	Free,
	Free_All,
	// design.md "Dynamic arrays" and "Maps": `make` creates a container bound to
	// the selected allocator, with an optional initial length and capacity. Its
	// first operand is a *type*, which no ordinary signature can spell, so it is
	// a built-in (m6b-plan step 1).
	Make,
	// The default provider handle, spelled `mem.default_allocator()`. The symbol
	// is compiler-owned and `core:mem` binds it, so a generated default argument
	// and a written call are one call.
	Default_Allocator,
	// design.md "Storage modifiers": "`drop` is a predeclared identifier, not a
	// keyword" — a compiler special form over a storage location, which is why it
	// is a built-in rather than an ordinary procedure (m5a-plan step 4).
	Drop,
	// design.md "Exchange": replaces a definitely live value and returns the
	// previous one without cloning it. Also a special form, because no ordinary
	// signature can express "moves both ways with nothing observable between".
	Exchange,
	// design.md "unsafe.raw_data procedure" and "string type conversions": the
	// `core:unsafe` surface, where "the loss of bounds and borrow capability
	// [is] visible at the call site". Each takes an operand whose shape the
	// ordinary signature language cannot spell, so each is a built-in.
	Unsafe_Raw_Data,
	Unsafe_String_View,
	Unsafe_C_String_View,
	// design.md "`type` and `typeid`": `type_info_of(id)` "accepts a runtime
	// `typeid` and returns runtime metadata". A `typeid` is an ordinary scalar and
	// can be forged, so the lookup is checked rather than an unchecked index.
	Type_Info_Of,
	// design.md "String format printing": the compiler-owned half of `core:fmt`.
	// The writers reach the process streams the seed runtime owns, and
	// `format_any` is the erased dispatch that makes formatting coherent.
	Fmt_Stdout_Writer,
	Fmt_Stderr_Writer,
	Fmt_Write_Bytes,
	Fmt_Format_Any,
	// design.md "Allocators": "string-producing procedures accept a conventional
	// `allocator` argument when selection is needed". Every built-in text
	// operation allocates from the default provider instead, so this is the one
	// bridge a library needs to honour a caller's allocator. It is contributed
	// package-privately to `core:strings`, which publishes it as `copy` and
	// `try_copy`, and to `core:fmt`, which cannot import `core:strings` for
	// `to_string` without emitting that whole package into every program.
	Strings_Allocate,
}

Symbol :: struct {
	name:        Identifier_Id,
	span:        Span,
	kind:        Symbol_Kind,
	builtin:     Builtin_Kind,
	// design.md "Exported names": package-private by default; `@(public)` on the
	// declaration, or on the package clause, exports it.
	public:      bool,
	type:        Type_Id,
	const_value: Const_Value,
	params:      []Type_Id,
	results:     []Type_Id,
	proc_type:   Type_Id,
	// Flattened one entry per parameter name, so `proc(a, b: int)` has two of
	// each. Defaults are the declaration's syntax, evaluated at the call site.
	param_symbols:  []Symbol_Id,
	param_defaults: []Expr,
	result_symbols: []Symbol_Id,
	members:     []Symbol_Id,
	decl:        ^Decl,
	// Expression-position procedures have no declaration wrapper. Keeping their
	// syntax here lets the compile-time evaluator execute the same hoisted body
	// that the backend emits.
	proc_literal: ^Expr_Proc,
	pkg:         Package_Id,
	// The package whose method, operator, and extension tables this declaration's
	// body may use, which is not always the package being checked: `delegate`
	// freezes it at its declaration, and M4b's instantiations look up at their
	// definition site (m4a-plan decision "Lookup package").
	lookup_pkg:  Package_Id,
	// The `impl`/`extend` subject this member belongs to, or INVALID_TYPE.
	owner_type:  Type_Id,
	// Generics (m4b-plan step 1). `generic` marks a template, which has no
	// signature and no runtime representation until it is instantiated;
	// `instance_of` names the template an instance came from. `def_scope` is the
	// declaration's own lexical scope, which is what definition-site lookup hangs
	// an instantiation off instead of the caller's.
	generic:       bool,
	instance_of:   Symbol_Id,
	def_scope:     ^Scope,
	def_file:      u32,
	def_file_node: ^File,
	// A first parameter named `self` whose type is the owner. `^T` is not a
	// receiver, so it leaves this false and gets no method-call sugar.
	has_receiver: bool,
	receiver:     Param_Mode,
	// `@(implicit)` on a one-argument `init` overload: reachable from an untyped
	// constant without being written.
	implicit:     bool,
	// Which container operation a contributed member is (`src/container.odin`).
	container_op: Container_Op,
	// Which region-provider operation it is (`src/region.odin`).
	provider_op:  Provider_Op,
	// The canonical text of `operator(sym)`, or "" for an ordinary procedure.
	// `[]=` and `[:]` are several tokens, so this is text rather than a token.
	operator:     string,
	// A forwarding overload `delegate(...)` generated. It has no body: the
	// backend applies the underlying type's operation to the unwrapped operands.
	// `delegate_target` is the underlying type's own overload when there is one,
	// and INVALID_SYMBOL when the underlying operation is the built-in.
	delegated:           bool,
	delegate_underlying: Type_Id,
	delegate_target:     Symbol_Id,
	// Signature resolution already reported why this procedure has no usable
	// type, so the gate must not report a second time for the same mistake.
	signature_error: bool,
	// A procedure the compiler contributes: it has a real symbol and signature,
	// and the backend writes its body (`src/iterate.odin`).
	synth:       Synth_Kind,
	// Field or enum-member position in its owning type; parameter position in
	// its signature.
	index:       u32,
	mode:        Param_Mode,
	// The declaring procedure literal, for the capture check in step 6.
	owner_proc:  rawptr,
	// A value parameter is immutable storage; an `inout` parameter is a mutable
	// alias. Both are addressable.
	immutable:   bool,
	// design.md "`@(allocator_reset)`": this `Allocator` parameter's region may
	// be ended by a successful call. The promise is verified in the body and
	// carried in the procedure type.
	allocator_reset: bool,
	// design.md "Managed values and storage": "A managed local declaration places
	// an implicit conditional `defer drop(value)` at the declaration point."
	// `src/lifecycle.odin` decides both from the CFG: whether scope exit drops
	// this local at all, and whether the state it exits in is the same on every
	// path. A definite state needs no runtime flag (m5a-plan decision
	// "Conditional liveness").
	drop_at_exit:     bool,
	drop_conditional: bool,
	cleanup_slot:     int,
	// design.md "Storage modifiers": "`manual` disables automatic cleanup. Use it
	// for arenas, foreign ownership, custom containers, and low-level allocator
	// code." The value is still tracked — an explicit `drop` and use-after-drop
	// both need its liveness — it simply has no scope-exit obligation.
	manual:           bool,
	// design.md "Allocators": the `via` allocator expression this declaration
	// wrote, or nil for the lazy default binding. m6b-plan decision "Allocator
	// binding" keeps this on the *declaration*: it survives drop and move and is
	// what a later revival selects, while the handle a live value currently holds
	// travels in the value itself.
	via:              Expr,
	// design.md "Storage modifiers": `static` exists for the life of the process
	// and `thread_local` for the life of its thread. Either one makes a *local*
	// declaration name storage outside the frame, so the backend gives it a
	// global rather than an `alloca` (m5a-plan step 4).
	duration:         Duration,
	// design.md "Build configuration": which `LOKE_*` enum this predeclared
	// constant belongs to, or `.None`. Its enum type is allocated lazily on first
	// use so a program that never reads build config keeps identical type
	// numbering (m7-plan step 1).
	build_config_enum: Build_Config_Enum,
	// design.md "@(deprecated)": the warning message printed at each use of this
	// procedure, or "" if it is not deprecated (m7-plan step 1).
	deprecated_message: string,
	deprecated:         bool,
	// design.md "@(require_results)": each call must use or explicitly discard the
	// results. Copied to a foreign block's members and applied to a procedure group
	// after overload selection (m7-plan step 1).
	require_results:    bool,
	// design.md "Foreign system" (m7-plan step 4): a foreign declaration has no
	// body. It names an external symbol in `foreign_library` under `link_name`
	// (its own written name unless `@(link_name)` renamed it), and the backend
	// emits a `declare`/`external global` rather than a definition.
	is_foreign:         bool,
	foreign_library:    string,
	link_name:          string,
	// design.md "@(export)" (m7-plan step 5): the declaration emits its symbol into
	// the object under `link_name` (its written name unless `@(link_name)` renamed
	// it) instead of the mangled `@loke.p...`, so a C consumer can link to it.
	exported:           bool,
}

Build_Config_Enum :: enum u8 {
	None,
	Arch,
	Os,
	Endian,
	Build_Mode,
	Optimization_Mode,
	Vendor,
}

Scope_Kind :: enum {
	Universe,
	Package,
	Procedure,
	Local,
}

Scope :: struct {
	parent: ^Scope,
	names:  map[Identifier_Id]Symbol_Id,
	kind:   Scope_Kind,
	// The procedure literal this scope belongs to, or nil at package/universe
	// level. Used to detect a capture across a procedure-literal boundary.
	owner_proc: rawptr,
}

Operator_Set :: struct {
	candidates: [dynamic]Symbol_Id,
}

// One resolved `import` edge, with the statement that wrote it: a cycle is
// reported as an ordered path of those spans, not as a set of package names.
Package_Import :: struct {
	target: Package_Id,
	span:   Span,
	alias:  string,
}

Package :: struct {
	id:             Package_Id,
	name:           Identifier_Id,
	canonical_path: string,
	// The logical canonical import identity — root-relative, or
	// `collection:relative/path` — which is what every user symbol is mangled
	// with. Never an alias and never a host absolute path, so a build is
	// reproducible and two same-named packages cannot collide
	// (m3-plan decision "Symbol mangling"). The root package's key is "".
	key:            string,
	files:          [dynamic]^File,
	scope:          ^Scope,
	// `extend` members, keyed by subject type. Package-scoped by design: an
	// unused import must not change or make ambiguous an existing expression, so
	// this is never merged into the type itself.
	extensions:     map[Type_Id][]Symbol_Id,
	operators:      map[string]^Operator_Set,
	imports:        [dynamic]Package_Import,
	// Procedure literals lifted out of expression position, owned by the package
	// that declared them: a compiler-global list would be discarded by the next
	// package checked (m3-plan decision "Package-owned backend state").
	hoisted_procs:  [dynamic]^Expr_Proc,
	// Generic instances defined by this package, in deterministic instantiation
	// order. Named and emitted after the package's own items, so a cross-package
	// generic call still has a final name before any body is written.
	instances:      [dynamic]Instance_Decl,
	// Which discovery work this package has already had. Monotonic, so a later
	// round only does what a newly selected branch added.
	collected:      bool,
	// Whether the compiler already bound its own members into this package's
	// scope (`src/stdlib.odin`). Discovery re-runs; contribution must not.
	contributed:    bool,
}

init_semantic_stores :: proc(c: ^Compiler) {
	if c.semantic_initialized {
		return
	}
	c.semantic_initialized = true
	c.target = WINDOWS_X64
	// A growing virtual arena, not `mem.Dynamic_Arena`. The latter rejects any
	// single allocation larger than its block size — 64 KiB by default — with
	// `.Invalid_Argument`, and both `append` and `make` swallow that: the symbol
	// store crossing the threshold kept its old length while `new_symbol` handed
	// out IDs for elements that were never stored. This arena serves an
	// allocation of any size, honours the cache-line alignment Odin's maps
	// assert on, and one `destroy_compilation` still frees the lot.
	//
	// The per-file syntax arena in `File` is only ever asked for small nodes and
	// holds no maps, so it stays as it is.
	if err := virtual.arena_init_growing(&c.semantic_arena); err != nil {
		panic("cannot reserve the compilation's semantic arena")
	}
	c.semantic_allocator = virtual.arena_allocator(&c.semantic_arena)
	if err := virtual.arena_init_growing(&c.analysis_arena); err != nil {
		panic("cannot reserve the compilation's analysis arena")
	}
	c.analysis_allocator = virtual.arena_allocator(&c.analysis_arena)
	c.identifier_names = make([dynamic]string, 0, 64, c.semantic_allocator)
	c.identifier_by_name = make(map[string]Identifier_Id, c.semantic_allocator)
	c.types = make([dynamic]Type_Info, 0, 64, c.semantic_allocator)
	c.type_by_shape = make(map[Type_Key]Type_Id, c.semantic_allocator)
	c.symbols = make([dynamic]Symbol, 0, 128, c.semantic_allocator)
	c.packages = make([dynamic]Package, 0, 8, c.semantic_allocator)
	c.generic_templates = make(map[Symbol_Id]^Generic_Template, c.semantic_allocator)
	c.generic_impls = make(map[Symbol_Id][dynamic]^Generic_Impl, c.semantic_allocator)
	c.instances = make(map[string]^Instance, c.semantic_allocator)
	c.instantiation_stack = make([dynamic]Instantiation_Frame, 0, 8, c.semantic_allocator)
	c.pending_impl_instances = make([dynamic]Pending_Impl, 0, 4, c.semantic_allocator)
	c.interfaces = make(map[Symbol_Id]^Interface_Info, c.semantic_allocator)
	c.typeid_requested = make(map[Type_Id]bool, c.semantic_allocator)
	c.typeid_order = make([dynamic]Type_Id, 0, 8, c.semantic_allocator)
	c.typeid_values = make(map[Type_Id]u64, c.semantic_allocator)
	c.range_types = make(map[Type_Id]Type_Id, c.semantic_allocator)
	c.iterator_types = make(map[Type_Id]Type_Id, c.semantic_allocator)
	c.synth_procs = make([dynamic]Symbol_Id, 0, 8, c.semantic_allocator)
	c.dyn_types = make(map[string]Type_Id, c.semantic_allocator)
	c.witnesses = make(map[string]^Witness, c.semantic_allocator)
	c.witness_order = make([dynamic]^Witness, 0, 4, c.semantic_allocator)
	c.materialized = make(map[Symbol_Id]^Materialized, c.semantic_allocator)
	c.materialized_order = make([dynamic]^Materialized, 0, 4, c.semantic_allocator)
	c.lifecycles = make(map[Type_Id]^Lifecycle, c.semantic_allocator)
	c.runtime_types = make(map[string]Type_Id, c.semantic_allocator)
	c.formatters = make(map[Type_Id]Symbol_Id, c.semantic_allocator)
	c.result_summary_dependencies = make(map[Symbol_Id][]Symbol_Id, c.semantic_allocator)
	c.reset_dead = make(map[^Expr_Call][]Symbol_Id, c.semantic_allocator)

	append(&c.identifier_names, "")
	pointer_bits := c.target.pointer_bits
	int_bits := c.target.int_bits
	append(&c.types,
		Type_Info{kind = .Invalid},
		Type_Info{kind = .Void},
		Type_Info{kind = .Bool, bits = 8},
		Type_Info{kind = .Int, bits = 8, signed = true},
		Type_Info{kind = .Int, bits = 16, signed = true},
		Type_Info{kind = .Int, bits = 32, signed = true},
		Type_Info{kind = .Int, bits = 64, signed = true},
		Type_Info{kind = .Int, bits = 128, signed = true},
		Type_Info{kind = .Int, bits = 8},
		Type_Info{kind = .Int, bits = 16},
		Type_Info{kind = .Int, bits = 32},
		Type_Info{kind = .Int, bits = 64},
		Type_Info{kind = .Int, bits = 128},
		Type_Info{kind = .Int, bits = int_bits, signed = true},
		Type_Info{kind = .Int, bits = int_bits},
		Type_Info{kind = .Int, bits = pointer_bits},
		Type_Info{kind = .Float, bits = 16},
		Type_Info{kind = .Float, bits = 32},
		Type_Info{kind = .Float, bits = 64},
		Type_Info{kind = .Rune, bits = 32, signed = true},
		Type_Info{kind = .Raw_Pointer, bits = pointer_bits},
		Type_Info{kind = .Type},
		Type_Info{kind = .String},
		Type_Info{kind = .Typeid, bits = 64},
		Type_Info{kind = .Any_View},
		Type_Info{kind = .Untyped_Int},
		Type_Info{kind = .Untyped_Float},
		Type_Info{kind = .Untyped_Bool},
		Type_Info{kind = .Untyped_Rune},
		Type_Info{kind = .Untyped_Nil},
		Type_Info{kind = .Untyped_String},
		Type_Info{kind = .String_View, bits = 2 * pointer_bits},
		Type_Info{kind = .Allocator, bits = pointer_bits},
		Type_Info{kind = .Allocator_Error, bits = int_bits},
		Type_Info{kind = .CString_View, bits = pointer_bits},
	)
	assert(Type_Id(len(c.types)) == FIRST_DYNAMIC_TYPE, "predeclared type table is out of step with its IDs")
	append(&c.symbols, Symbol{})
	append(&c.packages, Package{})
}

intern_identifier :: proc(c: ^Compiler, text: string) -> Identifier_Id {
	init_semantic_stores(c)
	if text == "" {
		return INVALID_IDENTIFIER
	}
	if id, ok := c.identifier_by_name[text]; ok {
		return id
	}
	id := Identifier_Id(len(c.identifier_names))
	append(&c.identifier_names, text)
	c.identifier_by_name[text] = id
	return id
}

identifier_text :: proc(c: ^Compiler, id: Identifier_Id) -> string {
	index := int(id)
	if index <= 0 || index >= len(c.identifier_names) {
		return ""
	}
	return c.identifier_names[index]
}

new_symbol :: proc(c: ^Compiler, value: Symbol) -> Symbol_Id {
	init_semantic_stores(c)
	id := Symbol_Id(len(c.symbols))
	append(&c.symbols, value)
	return id
}

// One field of a compiler-owned struct-shaped type — a slice, a container
// header, `any_view`, a range. Every such type installs its fields the same way,
// so they share one constructor rather than a private copy apiece.
new_field :: proc(c: ^Compiler, name: string, type: Type_Id, index: int, public := false) -> Symbol_Id {
	return new_symbol(c, Symbol {
		name   = intern_identifier(c, name),
		span   = no_span(),
		kind   = .Field,
		type   = type,
		index  = u32(index),
		public = public,
	})
}

symbol_of :: proc(c: ^Compiler, id: Symbol_Id) -> ^Symbol {
	index := int(id)
	if index <= 0 || index >= len(c.symbols) {
		return nil
	}
	return &c.symbols[index]
}

new_type :: proc(c: ^Compiler, value: Type_Info) -> Type_Id {
	init_semantic_stores(c)
	id := Type_Id(len(c.types))
	append(&c.types, value)
	return id
}

intern_proc_type :: proc(
	c: ^Compiler,
	parameters: []Type_Id,
	param_modes: []Param_Mode,
	results: []Type_Id,
	result_inout: []bool,
	convention: string,
	param_resets: []bool = nil,
	param_by_ptr: []bool = nil,
	c_vararg := false,
) -> Type_Id {
	init_semantic_stores(c)
	for info, index in c.types {
		if info.kind == .Proc &&
		   info.convention == convention &&
		   equal_type_ids(info.parameters, parameters) &&
		   equal_param_modes(info.param_modes, param_modes) &&
		   equal_type_ids(info.results, results) &&
		   equal_bools(info.result_inout, result_inout) &&
		   equal_reset_effects(info.param_resets, param_resets) &&
		   equal_reset_effects(info.param_by_ptr, param_by_ptr) &&
		   info.c_vararg == c_vararg {
			return Type_Id(index)
		}
	}
	parameter_copy := make([]Type_Id, len(parameters), c.semantic_allocator)
	mode_copy := make([]Param_Mode, len(param_modes), c.semantic_allocator)
	result_copy := make([]Type_Id, len(results), c.semantic_allocator)
	inout_copy := make([]bool, len(result_inout), c.semantic_allocator)
	reset_copy: []bool
	if has_reset_effect(param_resets) {
		reset_copy = make([]bool, len(param_resets), c.semantic_allocator)
		copy(reset_copy, param_resets)
	}
	by_ptr_copy: []bool
	if has_reset_effect(param_by_ptr) {
		by_ptr_copy = make([]bool, len(param_by_ptr), c.semantic_allocator)
		copy(by_ptr_copy, param_by_ptr)
	}
	copy(parameter_copy, parameters)
	copy(mode_copy, param_modes)
	copy(result_copy, results)
	copy(inout_copy, result_inout)
	return new_type(c, Type_Info {
		kind          = .Proc,
		bits          = c.target.pointer_bits,
		parameters    = parameter_copy,
		param_modes   = mode_copy,
		param_resets  = reset_copy,
		param_by_ptr  = by_ptr_copy,
		c_vararg      = c_vararg,
		results       = result_copy,
		result_inout  = inout_copy,
		convention    = convention,
	})
}

has_reset_effect :: proc(resets: []bool) -> bool {
	for value in resets {
		if value {
			return true
		}
	}
	return false
}

// A signature with no reset-marked parameter is the same type whether the list
// is absent or all false, so an ordinary procedure never interns twice.
@(private = "file")
equal_reset_effects :: proc(a, b: []bool) -> bool {
	limit := max(len(a), len(b))
	for index in 0 ..< limit {
		left := index < len(a) && a[index]
		right := index < len(b) && b[index]
		if left != right {
			return false
		}
	}
	return true
}

// Whether parameter `index` of this procedure type may reset the allocator
// region it receives.
proc_param_resets :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> bool {
	info := underlying_info(c, proc_type)
	return info != nil && index < len(info.param_resets) && info.param_resets[index]
}

@(private = "file")
equal_type_ids :: proc(a, b: []Type_Id) -> bool {
	if len(a) != len(b) { return false }
	for value, index in a { if value != b[index] { return false } }
	return true
}

@(private = "file")
equal_param_modes :: proc(a, b: []Param_Mode) -> bool {
	if len(a) != len(b) { return false }
	for value, index in a { if value != b[index] { return false } }
	return true
}

@(private = "file")
equal_bools :: proc(a, b: []bool) -> bool {
	if len(a) != len(b) { return false }
	for value, index in a { if value != b[index] { return false } }
	return true
}

intern_type :: proc(c: ^Compiler, key: Type_Key, value: Type_Info) -> Type_Id {
	init_semantic_stores(c)
	if id, ok := c.type_by_shape[key]; ok {
		return id
	}
	id := new_type(c, value)
	c.type_by_shape[key] = id
	return id
}

// An interned type by shape, without creating one. The backend uses this where
// making a type mid-emission would grow the store it is walking.
lookup_type :: proc(c: ^Compiler, key: Type_Key) -> (Type_Id, bool) {
	init_semantic_stores(c)
	id, ok := c.type_by_shape[key]
	return id, ok
}

pointer_to :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	return intern_type(
		c,
		Type_Key{kind = .Pointer, element = element},
		Type_Info{kind = .Pointer, element = element, bits = c.target.pointer_bits},
	)
}

// design.md "Multi-pointers": "`[^]T` is a multi-pointer to T value(s)", an
// address with neither a length nor a read-only capability.
multi_pointer_to :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	return intern_type(
		c,
		Type_Key{kind = .Multi_Pointer, element = element},
		Type_Info{kind = .Multi_Pointer, element = element, bits = c.target.pointer_bits},
	)
}

array_of :: proc(c: ^Compiler, element: Type_Id, count: u64) -> Type_Id {
	return intern_type(
		c,
		Type_Key{kind = .Array, element = element, count = count},
		Type_Info{kind = .Array, element = element, count = count},
	)
}

type_of :: proc(c: ^Compiler, id: Type_Id) -> ^Type_Info {
	index := int(id)
	if index < 0 || index >= len(c.types) {
		return nil
	}
	return &c.types[index]
}

type_kind :: proc(c: ^Compiler, id: Type_Id) -> Type_Kind {
	info := type_of(c, id)
	return info == nil ? .Invalid : info.kind
}

// The number of value bits in a scalar type. An enum reports its backing width.
type_bits :: proc(c: ^Compiler, id: Type_Id) -> int {
	info := type_of(c, id)
	if info == nil {
		return 0
	}
	if info.kind == .Enum || info.kind == .Distinct {
		return type_bits(c, info.element)
	}
	return int(info.bits)
}

type_signed :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := type_of(c, id)
	if info == nil {
		return false
	}
	if info.kind == .Enum || info.kind == .Distinct {
		return type_signed(c, info.element)
	}
	return info.signed
}

// A distinct type is a fresh identity but keeps the *shape* of what it wraps,
// which is what layout, folding, and lowering need.
type_underlying :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	current := id
	// A valid chain cannot visit more types than the compilation owns. Using that
	// invariant avoids both an arbitrary nesting limit and an allocation in this
	// very hot helper. If an invalid distinct cycle exists, return a member of the
	// cycle; the finite-size pass is responsible for diagnosing it.
	for _ in 0 ..< len(c.types) + 1 {
		info := type_of(c, current)
		if info == nil || info.kind != .Distinct || info.element == INVALID_TYPE {
			return current
		}
		current = info.element
	}
	return current
}

// A type's own `Type_Info` and kind are almost never what a question is about —
// a distinct type answers structural questions through what it wraps. These two
// are that pairing, spelled once: `underlying_info` is nil for an invalid type
// exactly as `type_of` is, and `underlying_kind` reports `.Invalid` for one
// exactly as `type_kind` does.
underlying_info :: proc(c: ^Compiler, id: Type_Id) -> ^Type_Info {
	return type_of(c, type_underlying(c, id))
}

underlying_kind :: proc(c: ^Compiler, id: Type_Id) -> Type_Kind {
	return type_kind(c, type_underlying(c, id))
}

type_is_untyped :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch type_kind(c, id) {
	case .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		return true
	}
	return false
}

type_is_integer :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .Int, .Untyped_Int:
		return true
	}
	return false
}

type_is_rune :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .Rune, .Untyped_Rune:
		return true
	}
	return false
}

type_is_float :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .Float, .Untyped_Float:
		return true
	}
	return false
}

type_is_boolean :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .Bool, .Untyped_Bool:
		return true
	}
	return false
}

type_is_enum :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Enum
}

type_is_pointer :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .Pointer, .Raw_Pointer, .Proc:
		return true
	}
	return false
}

// Integer-like for the purposes of arithmetic: an enum is deliberately absent
// (design.md "Arithmetic operators").
type_is_numeric :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return type_is_integer(c, id) || type_is_float(c, id) || type_is_rune(c, id)
}

type_is_aggregate :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .Struct, .Array:
		return true
	}
	return false
}

// design.md "Comparison operators". Aggregates are comparable when every leaf
// is; that recursion is what the backend then generates.
type_is_comparable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Bool, .Int, .Float, .Rune, .Raw_Pointer, .Pointer, .Multi_Pointer, .Proc, .Enum,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		return true
	// design.md: "`string` and `string_view` values are comparable and ordered,
	// lexically byte-wise." A `cstring_view` is not: it promises no encoding and
	// carries no length, so comparing two of them would compare addresses.
	case .String, .String_View:
		return true
	// design.md "Allocation failure": recovery is written `if (err != nil)`, so
	// the error code is nil-comparable. An `Allocator` handle is comparable for
	// the same reason a pointer is.
	case .Allocator, .Allocator_Error:
		return true
	// design.md: two `type` values support `==` and `!=` during compilation, and
	// `typeid` is an ordinary runtime scalar. Neither has an ordering.
	case .Type, .Typeid:
		return true
	case .Array:
		return type_is_comparable(c, info.element)
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil || !type_is_comparable(c, symbol.type) {
				return false
			}
		}
		return true
	case .Dyn, .Slice:
		// design.md: dynamic interface values and slices are comparable only with
		// `nil`; `check_binary` is what holds them to that.
		return true
	case .Union:
		// Comparable against nil always, and against another value of the same
		// union when every variant is itself comparable.
		for variant in info.variants {
			if !type_is_comparable(c, variant) {
				return false
			}
		}
		return true
	}
	return false
}

type_is_ordered :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .Int, .Float, .Rune, .Enum, .Untyped_Int, .Untyped_Float, .Untyped_Rune,
	     .Untyped_String, .String, .String_View:
		return true
	// design.md: "Ordering compares the addresses as unsigned `uintptr` values,
	// producing a total order within one execution."
	case .Pointer, .Multi_Pointer, .Raw_Pointer:
		return true
	}
	return false
}

// The type an untyped value takes when nothing else selects one
// (design.md "Untyped types").
default_type :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	#partial switch type_kind(c, id) {
	case .Untyped_Int:
		return TYPE_INT
	case .Untyped_Float:
		return TYPE_F64
	case .Untyped_Bool:
		return TYPE_BOOL
	case .Untyped_Rune:
		return TYPE_RUNE
	case .Untyped_Nil:
		return INVALID_TYPE // `x := nil` has no type to infer
	case .Untyped_String:
		// design.md "string type": an untyped string literal defaults to the
		// owning `string`, and a `string_view` parameter borrows it from there.
		return TYPE_STRING
	}
	return id
}

// Does this milestone compile a value of this type at all? Composite deferred
// syntax still resolves to a real `Type_Id`, so this walks rather than looking
// for absence (m2-plan decision "Deferred types").
//
// Nothing is deferred after M6b. `interface` as a runtime type is the one
// rejection left here, and it is not a deferral: an interface is deliberately
// compile-time metadata, so `gate_type` gives it its own L0441.
type_is_supported :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return type_is_supported_depth(c, id, 0)
}

@(private = "file")
type_is_supported_depth :: proc(c: ^Compiler, id: Type_Id, depth: int) -> bool {
	if depth > 32 {
		return true // a recursive nominal type; its own declaration is checked once
	}
	info := type_of(c, id)
	if info == nil {
		return false
	}
	if info.descriptor {
		return false // a descriptor exists only during compilation
	}
	#partial switch info.kind {
	case .Invalid:
		return false
	case .Void, .Bool, .Int, .Float, .Rune, .Raw_Pointer, .Type,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		return true
	case .Typeid:
		return true
	case .Any_View, .Dyn:
		return true
	case .Allocator, .Allocator_Error:
		return true
	case .String, .String_View, .CString_View:
		// design.md "string type" and "C string views": real runtime carriers since
		// M6a. Their borrow provenance is checked by `src/borrow.odin` rather than
		// restricted here.
		return true
	case .Multi_Pointer:
		// design.md "Multi-pointers": a multi-pointer "carries neither a length nor
		// a read-only capability, and its lifetime is no longer checked after
		// conversion" — a documented trust boundary, not an unsupported type.
		return type_is_supported_depth(c, info.element, depth + 1)
	case .Interface:
		return false
	case .Dynamic_Array:
		// design.md "Dynamic arrays": an owning managed container since M6b. Its
		// operations are gated individually rather than by the type, so the zero
		// value is a usable constant from step 1 onwards.
		return type_is_supported_depth(c, info.element, depth + 1)
	case .Map:
		return type_is_supported_depth(c, info.key, depth + 1) &&
		       type_is_supported_depth(c, info.element, depth + 1)
	case .Slice:
		// A slice is a supported runtime carrier, and its borrow provenance is
		// checked by `src/borrow.odin` rather than restricted here.
		return type_is_supported_depth(c, info.element, depth + 1)
	case .Union:
		for variant in info.variants {
			if !type_is_supported_depth(c, variant, depth + 1) {
				return false
			}
		}
		return len(info.variants) > 0
	case .Pointer, .Array, .Distinct:
		return type_is_supported_depth(c, info.element, depth + 1)
	case .Enum:
		return true
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil || !type_is_supported_depth(c, symbol.type, depth + 1) {
				return false
			}
		}
		return true
	case .Proc:
		for parameter in info.parameters {
			if !type_is_supported_depth(c, parameter, depth + 1) {
				return false
			}
		}
		for result in info.results {
			if !type_is_supported_depth(c, result, depth + 1) {
				return false
			}
		}
		return true
	}
	return false
}

type_name :: proc(c: ^Compiler, id: Type_Id) -> string {
	switch id {
	case INVALID_TYPE:
		return "<invalid>"
	case TYPE_VOID:
		return "()"
	case TYPE_BOOL:
		return "bool"
	case TYPE_I8:
		return "i8"
	case TYPE_I16:
		return "i16"
	case TYPE_I32:
		return "i32"
	case TYPE_I64:
		return "i64"
	case TYPE_I128:
		return "i128"
	case TYPE_U8:
		return "u8"
	case TYPE_U16:
		return "u16"
	case TYPE_U32:
		return "u32"
	case TYPE_U64:
		return "u64"
	case TYPE_U128:
		return "u128"
	case TYPE_INT:
		return "int"
	case TYPE_UINT:
		return "uint"
	case TYPE_UINTPTR:
		return "uintptr"
	case TYPE_F16:
		return "f16"
	case TYPE_F32:
		return "f32"
	case TYPE_F64:
		return "f64"
	case TYPE_RUNE:
		return "rune"
	case TYPE_RAWPTR:
		return "rawptr"
	case TYPE_TYPE:
		return "type"
	case TYPE_STRING:
		return "string"
	case TYPE_TYPEID:
		return "typeid"
	case TYPE_ANY_VIEW:
		return "any_view"
	case TYPE_STRING_VIEW:
		return "string_view"
	case TYPE_CSTRING_VIEW:
		return "cstring_view"
	case TYPE_UNTYPED_INT:
		return "untyped int"
	case TYPE_UNTYPED_FLOAT:
		return "untyped float"
	case TYPE_UNTYPED_BOOL:
		return "untyped bool"
	case TYPE_UNTYPED_RUNE:
		return "untyped rune"
	case TYPE_UNTYPED_NIL:
		return "untyped nil"
	case TYPE_UNTYPED_STRING:
		return "untyped string"
	}
	info := type_of(c, id)
	if info == nil {
		return "<invalid>"
	}
	if info.name != INVALID_IDENTIFIER {
		return identifier_text(c, info.name)
	}
	#partial switch info.kind {
	case .Pointer:
		return fmt.aprintf("^%s", type_name(c, info.element), allocator = c.semantic_allocator)
	case .Multi_Pointer:
		return fmt.aprintf("[^]%s", type_name(c, info.element), allocator = c.semantic_allocator)
	case .Array:
		return fmt.aprintf("[%d]%s", info.count, type_name(c, info.element), allocator = c.semantic_allocator)
	case .Slice:
		return fmt.aprintf("[]%s%s", info.mutable ? "mut " : "", type_name(c, info.element), allocator = c.semantic_allocator)
	case .Dynamic_Array:
		return fmt.aprintf("[dynamic]%s", type_name(c, info.element), allocator = c.semantic_allocator)
	case .Map:
		return fmt.aprintf("map[%s]%s", type_name(c, info.key), type_name(c, info.element), allocator = c.semantic_allocator)
	case .Distinct:
		return fmt.aprintf("distinct %s", type_name(c, info.element), allocator = c.semantic_allocator)
	case .Struct:
		return "struct"
	case .Enum:
		return "enum"
	case .Union:
		return "union"
	case .Interface:
		return "interface"
	case .Proc:
		return proc_type_name(c, info)
	}
	return "<type>"
}

@(private = "file")
proc_type_name :: proc(c: ^Compiler, info: ^Type_Info) -> string {
	b := strings.builder_make(c.semantic_allocator)
	strings.write_string(&b, "proc")
	// A foreign convention is part of the type, so a `loke` and a `"c"` signature
	// that otherwise match must not print the same (m7-plan step 3).
	if info.convention != "" {
		fmt.sbprintf(&b, " %q", info.convention)
	}
	strings.write_string(&b, "(")
	for parameter, index in info.parameters {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		// The reset effect is part of the type, so two otherwise identical
		// signatures must not print the same.
		if index < len(info.param_resets) && info.param_resets[index] {
			strings.write_string(&b, "@(allocator_reset) ")
		}
		if index < len(info.param_modes) && info.param_modes[index] == .Inout {
			strings.write_string(&b, "inout ")
		}
		strings.write_string(&b, type_name(c, parameter))
	}
	strings.write_string(&b, ")")
	if len(info.results) == 1 {
		strings.write_string(&b, " -> ")
		strings.write_string(&b, type_name(c, info.results[0]))
	} else if len(info.results) > 1 {
		strings.write_string(&b, " -> (")
		for result, index in info.results {
			if index > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, type_name(c, result))
		}
		strings.write_string(&b, ")")
	}
	return strings.to_string(b)
}

new_scope :: proc(c: ^Compiler, parent: ^Scope, kind: Scope_Kind) -> ^Scope {
	init_semantic_stores(c)
	scope := new(Scope, c.semantic_allocator)
	scope.parent = parent
	scope.kind = kind
	scope.names = make(map[Identifier_Id]Symbol_Id, c.semantic_allocator)
	scope.owner_proc = parent == nil ? nil : parent.owner_proc
	return scope
}

lookup_symbol :: proc(scope: ^Scope, name: Identifier_Id) -> Symbol_Id {
	for current := scope; current != nil; current = current.parent {
		if symbol, ok := current.names[name]; ok {
			return symbol
		}
	}
	return INVALID_SYMBOL
}

lookup_symbol_with_scope :: proc(scope: ^Scope, name: Identifier_Id) -> (Symbol_Id, ^Scope) {
	for current := scope; current != nil; current = current.parent {
		if symbol, ok := current.names[name]; ok {
			return symbol, current
		}
	}
	return INVALID_SYMBOL, nil
}

new_package :: proc(c: ^Compiler, name, canonical_path: string, key := "") -> Package_Id {
	init_semantic_stores(c)
	id := Package_Id(len(c.packages))
	pkg := Package {
		id             = id,
		name           = intern_identifier(c, name),
		canonical_path = canonical_path,
		key            = key,
		files          = make([dynamic]^File, 0, 4, c.semantic_allocator),
		extensions     = make(map[Type_Id][]Symbol_Id, c.semantic_allocator),
		operators      = make(map[string]^Operator_Set, c.semantic_allocator),
		imports        = make([dynamic]Package_Import, 0, 4, c.semantic_allocator),
		hoisted_procs  = make([dynamic]^Expr_Proc, 0, 4, c.semantic_allocator),
		instances      = make([dynamic]Instance_Decl, 0, 4, c.semantic_allocator),
	}
	append(&c.packages, pkg)
	return id
}

package_of :: proc(c: ^Compiler, id: Package_Id) -> ^Package {
	index := int(id)
	if index <= 0 || index >= len(c.packages) {
		return nil
	}
	return &c.packages[index]
}

add_package_file :: proc(c: ^Compiler, package_id: Package_Id, file: ^File) -> bool {
	pkg := package_of(c, package_id)
	if pkg == nil || file == nil {
		return false
	}
	append(&pkg.files, file)
	return true
}

destroy_compilation :: proc(c: ^Compiler) {
	// Production parsing gives the compilation ownership of both the file
	// object and its syntax arena. Hand-built tests keep `parsed_files` empty and
	// continue to own their stack-local ASTs themselves.
	for file in c.parsed_files {
		if file != nil {
			destroy_ast(file)
			free(file)
		}
	}
	delete(c.parsed_files)

	for &diagnostic in c.diagnostics {
		destroy_diagnostic(&diagnostic)
	}
	delete(c.diagnostics)
	for &source in c.sources {
		delete(source.line_starts)
		if source.owned_text != nil {
			delete(source.owned_text)
		}
	}
	delete(c.sources)

	if c.semantic_initialized {
		virtual.arena_destroy(&c.semantic_arena)
		virtual.arena_destroy(&c.analysis_arena)
	}
	c^ = {}
}
