// Stable semantic identities and compilation-owned stores. Syntax nodes contain
// IDs into these stores, never pointers to reallocating arrays or
// backend-specific state.
package lokec

import "core:fmt"
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
// where a value is wanted it defaults to `string`.
TYPE_UNTYPED_STRING :: Type_Id(30)

// A borrowed view over UTF-8 text: a pointer and a byte length, and no
// allocator. It supports the same byte, rune, and iteration operations as
// `string`, but owns and terminates nothing (design.md "string type
// conversions").
TYPE_STRING_VIEW :: Type_Id(31)

// design.md "Allocators" and "Allocation failure". `core:mem` and `base:runtime`
// export these identities rather than declaring their own, since the
// catalogue's `Cloneable` and the fixed lifecycle signatures spell them
// unqualified.
//
// `Allocator` is a one-word nominal handle to the seed runtime's provider
// record. Per-expression region identity is semantic metadata in
// `src/borrow.odin`, not part of the type or ABI.
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
	C_Pointer,
	Slice,
	// design.md "Allocators": a nominal runtime handle, and a nil-comparable
	// error code. Both are compiler-owned identities that `core:mem` exports.
	Allocator,
	Allocator_Error,
	Dynamic_Array,
	Array,
	Map,
	// design.md "SIMD vectors": `Simd(T, N)`, `N` lanes of `T` with the ordinary
	// operators acting lane-wise. It sits beside `Array` because it is the same
	// shape — an element type and a count — with its own layout rule and its own
	// operator set.
	Simd,
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
	// The compiler-owned receiver members behind the closed standard free-alias
	// set: `len`, `cap`, and `hash` on the built-in types that provide them.
	Standard_Customization,
	// design.md "Dynamic arrays" and "Maps": the operation set the compiler
	// contributes to a container type, so `xs.append(1)` is an ordinary method
	// call and generic code finds the same members.
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
	// A union's variants, in declaration order. The index *is* the variant's
	// identity — two variants may carry the same payload type — and is also the
	// tag, so variant 0 has tag 0 and there is no nil tag.
	//
	// `variants[i]` is variant `i`'s payload type (`TYPE_VOID` if payloadless);
	// `variant_names[i]` is its name.
	variants:   []Type_Id,
	variant_names: []Identifier_Id,
	// design.md "Unions": `@(zero=name)` designates the semantic zero, which must
	// be the first variant so that the all-zero representation stays the zero
	// value. `@(failure=name)` designates the failure variant of a two-variant
	// union, which is what `or_else`/`or_return` recognise structurally.
	zero_designated:    bool,
	failure_designated: bool,
	failure_variant:    int,
	// design.md "@(require_results)": `@(require_results)` on a type declaration.
	// A bare call statement is rejected when any result type requires handling.
	requires_results: bool,
	// A validated `union @(align=N)` or `struct @(align=N)`, or 0. Kept apart from
	// `align`, which the layout pass overwrites with the computed result —
	// `union_layout` is asked again by the emitter after that, and both must agree.
	written_align: u64,
	// design.md "@(packed)": this struct removes inter-field padding and has a
	// natural alignment of 1 (an `@(align=N)` may still raise it).
	packed:        bool,
	// `move_only struct` suppresses the generated ownership-copy operations.
	// Containing records inherit the property recursively through lifecycle
	// classification; this bit records an explicit leaf declaration.
	move_only:     bool,
	// Inherent members written by `impl`: methods, associated constants, and
	// associated types. `extend` never writes here — its members are package-scoped
	// and live in `Package.extensions`.
	members:    []Symbol_Id,
	// Which compiler-contributed member sets are already installed. More than one
	// contributor appends here — iteration for a range, array, or slice, and the
	// lifecycle hooks for a record — so "already has members" can't be the
	// idempotence guard: whichever ran first would suppress the other.
	contributed: bit_set[Contribution],
	parameters: []Type_Id,
	param_modes: []Param_Mode,
	// `@(allocator_reset)` is part of the parameter's procedure type: a
	// reset-capable procedure cannot be stored in a procedure value whose type
	// hides that effect (design.md "Procedure type").
	param_resets: []bool,
	// design.md/`@(escape=...)`: what a call may leave behind, per parameter. Part
	// of procedure type identity for the same reason the reset effect is — an
	// indirect call must not launder a promise through a type that hides it. Nil
	// means every parameter is at the default.
	param_escapes: []Escape_Level,
	// Foreign ABI adapters are part of procedure type identity. Erasing either
	// one changes the LLVM function type at an indirect call site.
	param_by_ptr: []bool,
	c_vararg:     bool,
	// design.md: a procedure returns at most one value. INVALID_TYPE means it has
	// none, and requires `result_inout == false`; `TYPE_VOID` remains the checked
	// expression type of a no-result call and is never stored here.
	result:       Type_Id,
	result_inout: bool,
	// `(key: string_view, value: int)`: a structural record with no declaration
	// site. `name` holds its readable spelling for diagnostics, but identity is
	// the ordered `(field name, field type)` vector, so this bit keeps the
	// display string out of every key that would otherwise use it.
	anonymous_record: bool,
	convention: string,
	// Set once the finite-size check has visited this nominal type, so a cycle
	// is reported at one place instead of once per reference.
	size_state: Size_State,
	// A monomorphized instance of a generic record: the template it came from,
	// and the argument vector that produced it. Structural specialization matches
	// against these.
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
	// closed/half-open flag, so `..<` and `..=` survive being stored or passed.
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

// `mutable` is the borrow capability, part of a carrier's identity: `[]T` and
// `[]mut T`, `^T` and `^mut T`, are distinct types over one representation. A
// field of its own, not a spare bit of `count`, so a capability question never
// has to touch array metadata.
Type_Key :: struct {
	kind:    Type_Kind,
	element: Type_Id,
	key:     Type_Id,
	count:   u64,
	mutable: bool,
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
	// For a union-typed constant: the variant it holds, with `elements[0]` its
	// payload (an `Invalid` value when the variant is payloadless). Unread for
	// a struct or array constant.
	variant:  int,
}

// Text is source/compilation backed; `integer` is arena-owned and immutable
// after publication (see `src/bigint.odin`).
Const_Value :: struct {
	kind:       Const_Kind,
	integer:    Big_Int, // Integer and Rune
	float:      f64,
	float_bits: u16,     // the semantic width a Float was last rounded to
	// The exact encoding of a Float at `float_bits`. `float` alone cannot carry
	// it: an f32 signalling NaN round-tripped through the f64 field comes back
	// quiet, so `unsafe.transmute(u32, x)` would not answer the bits it was
	// handed. Every Float constant carries its pattern; only a bit cast reads it.
	float_raw:  u64,
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
	rounded := round_float(value, bits)
	return Const_Value{kind = .Float, float = rounded, float_bits = bits, float_raw = float_pattern(rounded, bits)}
}

// The `unsafe.transmute` direction: exact bits in, the nearest `f64` view of
// them alongside for every ordinary constant operation.
float_bits_const :: proc(raw: u64, bits: u16) -> Const_Value {
	return Const_Value{kind = .Float, float = float_from_pattern(raw, bits), float_bits = bits, float_raw = raw}
}

// The IEEE-754 encoding of a value already rounded to `bits`, and its inverse.
// The f16 halves are the hand-rolled pair below; 32 and 64 are hardware widths.
float_pattern :: proc(value: f64, bits: u16) -> u64 {
	switch bits {
	case 16:
		return u64(f64_to_f16_bits(value))
	case 32:
		return u64(transmute(u32)f32(value))
	}
	return transmute(u64)value
}

// The encoding a Float constant is spelled with at `bits`. It carries the exact
// pattern of the width it was rounded to; any other width re-encodes from the
// numeric field, which is what every non-NaN value round-trips through anyway.
const_float_pattern :: proc(value: Const_Value, bits: u16) -> u64 {
	if value.float_bits == bits {
		return value.float_raw
	}
	return float_pattern(value.float, bits)
}

float_from_pattern :: proc(raw: u64, bits: u16) -> f64 {
	switch bits {
	case 16:
		return f16_bits_to_f64(u16(raw))
	case 32:
		return f64(transmute(f32)u32(raw))
	}
	return transmute(f64)raw
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
// 2049 into 2050 where the hardware `fadd half` LLVM emits produces 2048, which
// would make a folded `f16` constant disagree with the runtime expression.
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
	// `U.name` / `.name` naming a union variant that still needs its payload:
	// the selector alone is not a value, and `check_call` completes it.
	Union_Variant,
}

Value_Category :: enum {
	Invalid,
	Value,
	Place,
	Type,
}

// Why a readable place cannot be assigned to. A value parameter is addressable
// but immutable; a composite literal is addressable temporary storage; neither
// fact follows from the other, so the checker records both plus this reason.
Immutable_Reason :: enum {
	None,
	Constant,
	Value_Parameter,
	Temporary,
	Discard,
	Not_A_Place,
	// A place in read-only storage: an element of a `[]T`, or anything inside a
	// materialised constant. A real place — it has an address the backend can
	// read, and `&` may borrow it — but no operation may write it or hand out a
	// `^mut T` to it.
	Read_Only,
	// The same, reached by dereferencing or projecting a `^T`. Kept apart from
	// `Read_Only` only so the diagnostic can name the fix: `^mut`.
	Through_Pointer,
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
	Field,
	Enum_Member,
	Builtin,
}

// Which built-in a `Symbol_Kind.Builtin` symbol is. One shared `Builtin` kind
// with no identity would leave every built-in call indistinguishable at the
// point that has to lower it.
Builtin_Kind :: enum {
	None,
	Assert,
	Panic,
	// design.md "Compile-time built-ins". Ordinary predeclared identifiers:
	// `static_assert` forces the compile-time phase plain `assert` inherits from
	// its caller, `build_config` reads a `-define` key, and the two location
	// forms fold to a `runtime.Source_Code_Location`.
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
	// design.md "Iteration protocol": `iter` is a receiver method whose standard
	// free alias selects the same member, for built-ins and user types alike.
	Iter,
	// Closed standard aliases whose implementation is always a receiver method.
	// Unlike an ordinary free procedure, these symbols contribute no overloads
	// of their own: the checker rewrites the call to the selected member.
	Standard_Alias,
	// `clone(value)` and `try_clone(value)` are standard free aliases for the
	// type's generated receiver members (design.md "Standard customization
	// procedures"). Both spellings select one procedure.
	Clone,
	Try_Clone,
	// design.md "Allocators" and "Allocation failure". The explicitly fallible
	// primitives always return an error and never invoke a failure policy; `free`
	// returns no status. `free_all` lowers to the provider's reset entry once
	// region provenance proves no dependant survives it.
	New,
	New_Clone,
	Free,
	Free_All,
	// design.md "Dynamic arrays" and "Maps": `make` creates a container bound to
	// the selected allocator, with an optional initial length and capacity. Its
	// first operand is a *type*, which no ordinary signature can spell.
	Make,
	// The default provider handle, spelled `mem.default_allocator()`. The symbol
	// is compiler-owned and `core:mem` binds it, so a generated default argument
	// and a written call are one call.
	Default_Allocator,
	// `drop` is a predeclared identifier, not a keyword (design.md "Storage
	// modifiers") — a compiler special form over a storage location, which is
	// why it is a built-in rather than an ordinary procedure.
	Drop,
	// design.md "Exchange": replaces a definitely live value and returns the
	// previous one without cloning it. Also a special form, because no ordinary
	// signature can express "moves both ways with nothing observable between".
	Exchange,
	// The `core:unsafe` surface, where losing bounds and borrow capability is
	// visible right at the call site (design.md "unsafe.raw_data procedure",
	// "string type conversions"). Each takes an operand whose shape ordinary
	// signature language can't spell.
	Unsafe_Raw_Data,
	Unsafe_String_View,
	Unsafe_C_String_View,
	// `unsafe.forget(value)` consumes an owning operand and runs no cleanup for
	// it or for anything it owns (design.md "Storage modifiers"). No signature
	// can express "consume without cleanup", so it is a built-in too.
	Unsafe_Forget,
	// `unsafe.free(pointer, allocator)` releases an allocation whose root the
	// compiler cannot see — one reached through a `rawptr` field, a parameter, or
	// foreign code. design.md's `free` bullet names this crossing directly:
	// "releasing an unchecked or foreign allocation crosses the `core:unsafe` or
	// foreign-allocator boundary."
	Unsafe_Free,
	// `unsafe.transmute(T, value)` reinterprets the bits of a same-sized value
	// (design.md "`unsafe.transmute`"). Its first argument is a *type*,
	// which no ordinary signature can spell, and reinterpretation is not a safe
	// universally valid conversion — hence a `core:unsafe` built-in rather than a
	// predeclared one.
	Unsafe_Transmute,
	// design.md "SIMD vectors": the `core:simd` operations a lane index being
	// constant makes unwritable as a loop in ordinary Loke. `Simd_Cast` is both
	// array directions — its result follows its operand — and `Simd_Reduce`
	// takes the fold as a constant parameter, exactly as an atomic takes its
	// ordering.
	Simd_Cast,
	Simd_Select,
	Simd_Reduce,
	// `type_info_of(id)` takes a runtime `typeid` and returns runtime metadata
	// (design.md "`type` and `typeid`"). A `typeid` is an ordinary scalar and
	// can be forged, so the lookup is checked rather than an unchecked index.
	Type_Info_Of,
	// design.md "String format printing": the compiler-owned half of `core:fmt`.
	// The writers reach the process streams the seed runtime owns, and
	// `format_any` is the erased dispatch that makes formatting coherent.
	Fmt_Stdout_Writer,
	Fmt_Stderr_Writer,
	Fmt_Write_Bytes,
	Fmt_Format_Any,
	// String-producing procedures take a conventional `allocator` argument when
	// selection is needed (design.md "Allocators") — built-ins otherwise allocate
	// from the default provider. Contributed package-privately to `core:strings`
	// (published as `copy`/`try_copy`) and to `core:fmt`, which can't import
	// `core:strings` for `to_string` without pulling in the whole package.
	Strings_Allocate,
	// design.md "Concurrency and the memory model": the compiler atomic
	// intrinsics `Atomic(T)` wraps. Contributed package-privately to `core:sync`,
	// which publishes them as ordinary methods and as `fence`. Each requires a
	// constant ordering, which is what no ordinary signature can ask for.
	Atomic_Load,
	Atomic_Store,
	Atomic_Exchange,
	Atomic_Compare_Exchange,
	Atomic_Add,
	Atomic_Sub,
	Atomic_And,
	Atomic_Or,
	Atomic_Xor,
	Atomic_Fence,
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
	result:      Type_Id, // INVALID_TYPE when the procedure has no result
	result_inout: bool,
	proc_type:   Type_Id,
	// Flattened one entry per parameter name, so `proc(a, b: int)` has two of
	// each. Defaults are the declaration's syntax, evaluated at the call site.
	param_symbols:  []Symbol_Id,
	param_defaults: []Expr,
	members:     []Symbol_Id,
	decl:        ^Decl,
	// Expression-position procedures have no declaration wrapper. Keeping their
	// syntax here lets the compile-time evaluator execute the same hoisted body
	// that the backend emits.
	proc_literal: ^Expr_Proc,
	pkg:         Package_Id,
	// The package whose method, operator, and extension tables this declaration's
	// body may use — not always the package being checked: `delegate` freezes it
	// at its declaration, and M4b's instantiations look up at their definition
	// site.
	lookup_pkg:  Package_Id,
	// The `impl`/`extend` subject this member belongs to, or INVALID_TYPE.
	owner_type:  Type_Id,
	// Generics. `generic` marks a template, which has no signature and no
	// runtime representation until instantiated; `instance_of` names the
	// template an instance came from. `def_scope` is the declaration's own
	// lexical scope, what definition-site lookup hangs an instantiation off
	// instead of the caller's.
	generic:       bool,
	instance_of:   Symbol_Id,
	def_scope:     ^Scope,
	def_file:      u32,
	def_file_node: ^File,
	// A first parameter named `self` whose type is the owner. `^T` is not a
	// receiver, so it leaves this false and gets no method-call sugar.
	has_receiver: bool,
	receiver:     Param_Mode,
	// `@(implicit)` on a `hook(convert)` declaration: reachable from an untyped
	// constant without being written.
	implicit:     bool,
	// A closed compiler-controlled semantic role. Ordinary procedure names have
	// no hook meaning; operators continue to use the symbolic field below.
	hook:         Hook_Kind,
	// Which container operation a contributed member is (`src/container.odin`).
	container_op: Container_Op,
	// Which region-provider operation it is (`src/region.odin`).
	provider_op:  Provider_Op,
	// The canonical text of `operator(sym)`, or "" for an ordinary procedure.
	// `[]=` and `[:]` are several tokens, so this is text rather than a token.
	operator:     string,
	// A forwarding overload `delegate(...)` generated. It has no body: the
	// backend applies the underlying type's operation to the unwrapped operands.
	// `delegate_target` is the underlying type's own overload if it has one, or
	// INVALID_SYMBOL when the underlying operation is the built-in.
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
	// design.md `@(escape=...)`: what a call may leave behind that depends on
	// this parameter. `.Result` unless written otherwise.
	escape:          Escape_Level,
	// A managed local declaration places an implicit conditional
	// `defer drop(value)` at the declaration point (design.md "Managed values
	// and storage"). `src/lifecycle.odin` decides both from the CFG: whether
	// scope exit drops this local at all, and whether its exit state is the
	// same on every path — a definite state needs no runtime flag.
	drop_at_exit:     bool,
	drop_conditional: bool,
	cleanup_slot:     int,
	// design.md "Allocators": the `via` allocator expression this declaration
	// wrote, or nil for the lazy default binding. Kept on the *declaration*
	// since it survives drop and move and is what a later revival selects, while
	// the handle a live value currently holds travels in the value itself.
	via:              Expr,
	// design.md "Storage modifiers": `static` exists for the life of the process,
	// `thread_local` for the life of its thread. Either makes a *local*
	// declaration name storage outside the frame, so the backend gives it a
	// global rather than an `alloca`.
	duration:         Duration,
	// design.md "Build configuration": which `LOKE_*` enum this predeclared
	// constant belongs to, or `.None`. Its enum type is allocated lazily on first
	// use so a program that never reads build config keeps identical type
	// numbering.
	build_config_enum: Build_Config_Enum,
	// design.md "`@(deprecated=<string>)`": the warning message printed at each
	// use of this procedure, or "" if it is not deprecated.
	deprecated_message: string,
	deprecated:         bool,
	// design.md "@(require_results)": each call must use or explicitly discard the
	// results. Copied to a foreign block's members and applied to a procedure
	// group after overload selection.
	require_results:    bool,
	// design.md "Foreign system": a foreign declaration has no
	// body. It names an external symbol under `link_name` (its own written name
	// unless `@(link_name)` renamed it), and the backend emits a
	// `declare`/`external global` rather than a definition. The source library
	// isn't recorded: every foreign block links against the one image, so
	// nothing downstream asks which block a symbol was written in.
	is_foreign:         bool,
	link_name:          string,
	// design.md "@(export)": the declaration emits its symbol into
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
	Log_Level,
}

// design.md "Compiled log level". The member names are `core:log`'s own, and
// `Off` is last so `LOKE_LOG_LEVEL <= .Error` is false when logging is compiled
// out entirely.
Log_Level :: enum u8 {
	Debug,
	Info,
	Warning,
	Error,
	Off,
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
	// The logical canonical import identity — root-relative, or
	// `collection:relative/path` — which every user symbol is mangled with.
	// Never an alias and never a host absolute path, so a build is reproducible
	// and two same-named packages cannot collide. The root package's key is "".
	key:            string,
	files:          [dynamic]^File,
	scope:          ^Scope,
	// `extend` members, keyed by subject type. Package-scoped by design: an
	// unused import must not change or make an existing expression ambiguous, so
	// this is never merged into the type itself.
	extensions:     map[Type_Id][]Symbol_Id,
	operators:      map[string]^Operator_Set,
	imports:        [dynamic]Package_Import,
	// Procedure literals lifted out of expression position, owned by the package
	// that declared them: a compiler-global list would be discarded by the next
	// package checked.
	hoisted_procs:  [dynamic]^Expr_Proc,
	// Generic instances defined by this package, in deterministic instantiation
	// order. Named and emitted after the package's own items, so a cross-package
	// generic call still has a final name before any body is written.
	instances:      [dynamic]Instance_Decl,
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
	// A growing virtual arena, not `mem.Dynamic_Arena`: the latter rejects any
	// single allocation over its block size (64 KiB by default) with
	// `.Invalid_Argument`, which `append`/`make` swallow — the symbol store
	// crossing that threshold kept its old length while `new_symbol` handed out
	// IDs for elements never stored. This arena serves any allocation size,
	// honours the cache-line alignment Odin's maps assert on, and still frees
	// the lot in one `destroy_compilation`.
	//
	// The per-file syntax arena in `File` only ever gets small nodes and holds no
	// maps, so it stays as it is.
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
	c.anon_record_types = make(map[u64][]Type_Id, c.semantic_allocator)
	c.symbols = make([dynamic]Symbol, 0, 128, c.semantic_allocator)
	c.packages = make([dynamic]Package, 0, 8, c.semantic_allocator)
	c.generic_templates = make(map[Symbol_Id]^Generic_Template, c.semantic_allocator)
	c.generic_impls = make(map[Symbol_Id][dynamic]^Generic_Impl, c.semantic_allocator)
	c.instances = make(map[string]^Instance, c.semantic_allocator)
	c.procedure_instances = make(map[Symbol_Id]^Instance, c.semantic_allocator)
	c.instantiation_stack = make([dynamic]Instantiation_Frame, 0, 8, c.semantic_allocator)
	c.pending_impl_instances = make([dynamic]Pending_Impl, 0, 4, c.semantic_allocator)
	c.interfaces = make(map[Symbol_Id]^Interface_Info, c.semantic_allocator)
	c.map_key_policies = make(map[Type_Id]Key_Policy, c.semantic_allocator)
	c.order_policies = make(map[Type_Id]Order_Policy, c.semantic_allocator)
	c.typeid_requested = make(map[Type_Id]bool, c.semantic_allocator)
	c.typeid_order = make([dynamic]Type_Id, 0, 8, c.semantic_allocator)
	c.typeid_values = make(map[Type_Id]u64, c.semantic_allocator)
	c.range_types = make(map[Type_Id]Type_Id, c.semantic_allocator)
	c.iterator_types = make(map[Type_Id]Type_Id, c.semantic_allocator)
	c.carrier_reach = make(map[Type_Id]Carrier_Reach, c.semantic_allocator)
	c.carrier_shapes = make(map[Type_Id][]Carrier_Path, c.semantic_allocator)
	c.synth_procs = make([dynamic]Symbol_Id, 0, 8, c.semantic_allocator)
	c.dyn_types = make(map[string]Type_Id, c.semantic_allocator)
	c.witnesses = make(map[string]^Witness, c.semantic_allocator)
	c.witness_order = make([dynamic]^Witness, 0, 4, c.semantic_allocator)
	c.materialized = make(map[Symbol_Id]^Materialized, c.semantic_allocator)
	c.materialized_order = make([dynamic]^Materialized, 0, 4, c.semantic_allocator)
	c.lifecycles = make(map[Type_Id]^Lifecycle, c.semantic_allocator)
	c.lifecycle_operations = make(map[Type_Id]Lifecycle_Operations, c.semantic_allocator)
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
	result: Type_Id,
	result_inout: bool,
	convention: string,
	param_resets: []bool = nil,
	param_by_ptr: []bool = nil,
	c_vararg := false,
	param_escapes: []Escape_Level = nil,
) -> Type_Id {
	init_semantic_stores(c)
	for info, index in c.types {
		if info.kind == .Proc &&
		   info.convention == convention &&
		   equal_type_ids(info.parameters, parameters) &&
		   equal_param_modes(info.param_modes, param_modes) &&
		   info.result == result &&
		   info.result_inout == result_inout &&
		   equal_reset_effects(info.param_resets, param_resets) &&
		   equal_reset_effects(info.param_by_ptr, param_by_ptr) &&
		   equal_escape_levels(info.param_escapes, param_escapes) &&
		   info.c_vararg == c_vararg {
			return Type_Id(index)
		}
	}
	parameter_copy := make([]Type_Id, len(parameters), c.semantic_allocator)
	mode_copy := make([]Param_Mode, len(param_modes), c.semantic_allocator)
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
	escape_copy: []Escape_Level
	if has_escape_level(param_escapes) {
		escape_copy = make([]Escape_Level, len(param_escapes), c.semantic_allocator)
		copy(escape_copy, param_escapes)
	}
	copy(parameter_copy, parameters)
	copy(mode_copy, param_modes)
	return new_type(c, Type_Info {
		kind          = .Proc,
		bits          = c.target.pointer_bits,
		parameters    = parameter_copy,
		param_modes   = mode_copy,
		param_resets  = reset_copy,
		param_escapes = escape_copy,
		param_by_ptr  = by_ptr_copy,
		c_vararg      = c_vararg,
		result        = result,
		result_inout  = result_inout,
		convention    = convention,
	})
}

// A level vector is only stored when something in it is not the default, so an
// unannotated signature interns exactly the type it always did.
has_escape_level :: proc(levels: []Escape_Level) -> bool {
	for level in levels {
		if level != .Result {
			return true
		}
	}
	return false
}

equal_escape_levels :: proc(a, b: []Escape_Level) -> bool {
	for index in 0 ..< max(len(a), len(b)) {
		left := index < len(a) ? a[index] : Escape_Level.Result
		right := index < len(b) ? b[index] : Escape_Level.Result
		if left != right {
			return false
		}
	}
	return true
}

proc_param_escape :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> Escape_Level {
	// A distinct procedure type has its own nominal identity, but its calling
	// contract lives on the procedure representation it wraps.
	info := underlying_info(c, proc_type)
	if info == nil || index >= len(info.param_escapes) {
		return .Result
	}
	return info.param_escapes[index]
}

// design.md `@(escape=<level>)`: a callee may promise more than the type its
// value is stored in asks, never less. Levels are part of procedure type
// identity, but assigning a stricter type to a weaker one is safe — every
// caller of the weaker type already meets the stricter obligation. Everything
// else must match exactly; levels carry no ABI, so the assignment stays a
// plain pointer copy.
proc_escape_weakens_to :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	a := type_of(c, from)
	b := type_of(c, to)
	if a == nil || b == nil || a.kind != .Proc || b.kind != .Proc {
		return false
	}
	if a.convention != b.convention ||
	   a.c_vararg != b.c_vararg ||
	   !equal_type_ids(a.parameters, b.parameters) ||
	   !equal_param_modes(a.param_modes, b.param_modes) ||
	   a.result != b.result ||
	   a.result_inout != b.result_inout ||
	   !equal_reset_effects(a.param_resets, b.param_resets) ||
	   !equal_reset_effects(a.param_by_ptr, b.param_by_ptr) {
		return false
	}
	for index in 0 ..< len(a.parameters) {
		if proc_param_escape(c, from, index) > proc_param_escape(c, to, index) {
			return false
		}
	}
	return true
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

intern_type :: proc(c: ^Compiler, key: Type_Key, value: Type_Info) -> Type_Id {
	init_semantic_stores(c)
	if id, ok := c.type_by_shape[key]; ok {
		return id
	}
	id := new_type(c, value)
	c.type_by_shape[key] = id
	return id
}

// design.md "Anonymous records": `(key: string_view, value: int)` has no
// declaration site, so its identity is the ordered sequence of its
// `(field name, field type)` pairs. Field order matters and field names are
// part of the type, which is exactly the vector compared here.
Anon_Record_Field :: struct {
	name: Identifier_Id,
	type: Type_Id,
}

// Interns one anonymous record. Takes specs rather than field symbols so a
// cache hit does not leak the orphan `Symbol`s a caller would have had to build
// speculatively.
anon_record_type :: proc(c: ^Compiler, fields: []Anon_Record_Field) -> Type_Id {
	init_semantic_stores(c)
	hash := u64(0xcbf29ce484222325)
	for field in fields {
		hash = (hash ~ u64(field.name)) * HASH_MULTIPLIER
		hash = (hash ~ u64(field.type)) * HASH_MULTIPLIER
	}
	bucket := c.anon_record_types[hash]
	for candidate in bucket {
		info := type_of(c, candidate)
		if info == nil || len(info.fields) != len(fields) {
			continue
		}
		same := true
		for field, index in fields {
			member := symbol_of(c, info.fields[index])
			if member == nil || member.name != field.name || member.type != field.type {
				same = false
				break
			}
		}
		if same {
			return candidate
		}
	}

	id := new_type(c, Type_Info{kind = .Struct, anonymous_record = true})
	members := make([]Symbol_Id, len(fields), c.semantic_allocator)
	for field, index in fields {
		members[index] = new_symbol(c, Symbol {
			name   = field.name,
			span   = no_span(),
			kind   = .Field,
			type   = field.type,
			index  = u32(index),
			public = true,
		})
	}
	if info := type_of(c, id); info != nil {
		info.fields = members
		info.name = intern_identifier(c, anon_record_display(c, fields))
		info.mangled = anon_record_mangled(c, fields)
	}
	grown := make([]Type_Id, len(bucket) + 1, c.semantic_allocator)
	copy(grown, bucket)
	grown[len(bucket)] = id
	c.anon_record_types[hash] = grown
	return id
}

@(private = "file")
anon_record_display :: proc(c: ^Compiler, fields: []Anon_Record_Field) -> string {
	b := strings.builder_make(c.semantic_allocator)
	strings.write_string(&b, "(")
	for field, index in fields {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, identifier_text(c, field.name))
		strings.write_string(&b, ": ")
		strings.write_string(&b, type_name(c, field.type))
	}
	strings.write_string(&b, ")")
	return strings.to_string(b)
}

// The backend spelling. It is built from the structural sort key rather than
// the display name, so two packages' unrelated `Token` types cannot collide in
// a generated symbol merely because both print as `Token`.
@(private = "file")
anon_record_mangled :: proc(c: ^Compiler, fields: []Anon_Record_Field) -> string {
	b := strings.builder_make(c.semantic_allocator)
	strings.write_string(&b, "anon")
	for field in fields {
		fmt.sbprintf(
			&b, ".%s.%s", llvm_safe(identifier_text(c, field.name)),
			llvm_safe(typeid_sort_key(c, field.type)),
		)
	}
	return strings.to_string(b)
}

// An interned type by shape, without creating one. The backend uses this where
// making a type mid-emission would grow the store it is walking.
lookup_type :: proc(c: ^Compiler, key: Type_Key) -> (Type_Id, bool) {
	init_semantic_stores(c)
	id, ok := c.type_by_shape[key]
	return id, ok
}

// `^T` is a read-only borrow of one value and `^mut T` a mutable one. Both are
// one machine address with one LLVM type: the capability is static, so
// weakening a `^mut T` to a `^T` emits nothing (design.md "Capabilities and the
// one rule").
pointer_to :: proc(c: ^Compiler, element: Type_Id, mutable: bool) -> Type_Id {
	return intern_type(
		c,
		Type_Key{kind = .Pointer, element = element, mutable = mutable},
		Type_Info{kind = .Pointer, element = element, mutable = mutable, bits = c.target.pointer_bits},
	)
}

pointer_is_mutable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	return info != nil && info.kind == .Pointer && info.mutable
}

// The one backend type a struct-shaped carrier's two capabilities share.
// Mutability is static and leaves the ABI unchanged, so weakening is a no-op at
// the value level rather than a copy through a second shape.
carrier_abi_type :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	if underlying_kind(c, id) == .Dyn {
		return dyn_abi_type(c, id)
	}
	return slice_abi_type(c, id)
}

// A mutable carrier implicitly weakens to a read-only one of the same shape; a
// read-only carrier never strengthens. Slices, pointers, and dyn views share
// this semantic rule and one representation per shape.
carrier_weakens_to :: proc(c: ^Compiler, from: Type_Id, to: Type_Id) -> bool {
	from_info := underlying_info(c, from)
	to_info := underlying_info(c, to)
	if from_info == nil || to_info == nil {
		return false
	}
	if from_info.kind != to_info.kind || !from_info.mutable || to_info.mutable {
		return false
	}
	#partial switch from_info.kind {
	case .Slice, .Pointer:
		return from_info.element == to_info.element
	case .Dyn:
		return dyn_same_application(from_info, to_info)
	}
	return false
}

// `[^]T` is a C pointer to T value(s) (design.md "C pointers"), an
// address with neither a length nor a read-only capability.
c_pointer_to :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	return intern_type(
		c,
		Type_Key{kind = .C_Pointer, element = element},
		Type_Info{kind = .C_Pointer, element = element, bits = c.target.pointer_bits},
	)
}

array_of :: proc(c: ^Compiler, element: Type_Id, count: u64) -> Type_Id {
	return intern_type(
		c,
		Type_Key{kind = .Array, element = element, count = count},
		Type_Info{kind = .Array, element = element, count = count},
	)
}

// design.md "SIMD vectors": `Simd(T, N)`. The element and lane count are the
// whole identity, exactly as for an array — the difference is layout, the
// operator set, and that it is not a sequence.
simd_of :: proc(c: ^Compiler, element: Type_Id, count: u64) -> Type_Id {
	return intern_type(
		c,
		Type_Key{kind = .Simd, element = element, count = count},
		Type_Info{kind = .Simd, element = element, count = count},
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
	// A valid chain cannot visit more types than the compilation owns — using
	// that invariant avoids both an arbitrary nesting limit and an allocation in
	// this hot helper. If an invalid distinct cycle exists, this returns a member
	// of it; the finite-size pass is responsible for diagnosing it.
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
// like `type_of`, and `underlying_kind` reports `.Invalid` for one like
// `type_kind`.
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
	case .Bool, .Int, .Float, .Rune, .Raw_Pointer, .Pointer, .C_Pointer, .Proc, .Enum,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		return true
	// A payloadless union variant carries `void`, and two of them are equal when
	// their tags are.
	case .Void:
		return true
	// `string` and `string_view` values are comparable and ordered, lexically
	// byte-wise (design.md). A `cstring_view` is not: it promises no encoding and
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
	// Ordering compares the addresses as unsigned `uintptr` values, producing a
	// total order within one execution (design.md).
	case .Pointer, .C_Pointer, .Raw_Pointer:
		return true
	}
	return false
}

// The type an untyped value takes when nothing else selects one
// (design.md "Unfixed constants").
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
// for absence.
//
// Nothing is deferred after M6b; `interface` as a runtime type is the one
// rejection left, and not a deferral — it's deliberately compile-time metadata,
// so `gate_type` gives it its own L0441. Unsupported has two causes: a
// construct this version doesn't compile, or a component that never resolved.
// Only the first is a milestone answer (an invalid component was already
// rejected where written), so the two are told apart here rather than reported
// as one.
type_mentions_invalid :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return type_contains_invalid(c, id, 0)
}

@(private = "file")
type_contains_invalid :: proc(c: ^Compiler, id: Type_Id, depth: int) -> bool {
	if id == INVALID_TYPE {
		return true
	}
	if depth > 32 {
		return false // a recursive nominal type; its own declaration is checked once
	}
	info := type_of(c, id)
	if info == nil {
		return false
	}
	// Exhaustive on purpose: this recurses through every type that has
	// components, so a new composed `Type_Kind` must not quietly answer "no
	// invalid part" the way a scalar correctly does.
	switch info.kind {
	case .Invalid:
		return true
	case .Void, .Bool, .Int, .Float, .Rune, .Enum, .Raw_Pointer, .Typeid,
	     .String, .String_View, .CString_View, .Any_View, .Dyn, .Interface, .Type,
	     .Allocator, .Allocator_Error,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String:
		// No components, so nothing to be invalid below the type itself.
		return false
	case .Pointer, .C_Pointer, .Slice, .Dynamic_Array, .Array, .Simd, .Distinct:
		return type_contains_invalid(c, info.element, depth + 1)
	case .Map:
		return type_contains_invalid(c, info.key, depth + 1) ||
		       type_contains_invalid(c, info.element, depth + 1)
	case .Union:
		for variant in info.variants {
			if type_contains_invalid(c, variant, depth + 1) {
				return true
			}
		}
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil || type_contains_invalid(c, symbol.type, depth + 1) {
				return true
			}
		}
	case .Proc:
		for parameter in info.parameters {
			if type_contains_invalid(c, parameter, depth + 1) {
				return true
			}
		}
		// design.md: a procedure with no result carries INVALID_TYPE for one, which
		// is the absence of a result rather than a type that failed to resolve.
		return info.result != INVALID_TYPE && type_contains_invalid(c, info.result, depth + 1)
	}
	return false
}

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
	case .C_Pointer:
		// A C pointer carries neither a length nor a read-only capability, and
		// its lifetime is no longer checked after conversion (design.md
		// "C pointers") — a documented trust boundary, not an unsupported type.
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
		return true
	case .Pointer, .Array, .Simd, .Distinct:
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
		if info.result != INVALID_TYPE && !type_is_supported_depth(c, info.result, depth + 1) {
			return false
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
		return fmt.aprintf("^%s%s", info.mutable ? "mut " : "", type_name(c, info.element), allocator = c.semantic_allocator)
	case .C_Pointer:
		return fmt.aprintf("[^]%s", type_name(c, info.element), allocator = c.semantic_allocator)
	case .Array:
		return fmt.aprintf("[%d]%s", info.count, type_name(c, info.element), allocator = c.semantic_allocator)
	case .Simd:
		return simd_type_name(c, info)
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
	// that otherwise match must not print the same.
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
		if index < len(info.param_escapes) && info.param_escapes[index] != .Result {
			strings.write_string(&b, "@(escape=")
			strings.write_string(&b, escape_level_name(info.param_escapes[index]))
			strings.write_string(&b, ") ")
		}
		if index < len(info.param_modes) && info.param_modes[index] == .Inout {
			strings.write_string(&b, "inout ")
		}
		strings.write_string(&b, type_name(c, parameter))
	}
	strings.write_string(&b, ")")
	if info.result != INVALID_TYPE {
		strings.write_string(&b, " -> ")
		if info.result_inout {
			strings.write_string(&b, "inout ")
		}
		strings.write_string(&b, type_name(c, info.result))
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

new_package :: proc(c: ^Compiler, name: string, key := "") -> Package_Id {
	init_semantic_stores(c)
	id := Package_Id(len(c.packages))
	pkg := Package {
		id             = id,
		name           = intern_identifier(c, name),
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
