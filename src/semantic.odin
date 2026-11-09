// Stable semantic identities and compilation-owned stores. Syntax nodes contain
// IDs into these stores, never pointers to reallocating arrays or
// backend-specific state.
package lokec

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
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

TYPE_STRING   :: Type_Id(22)
TYPE_TYPEID   :: Type_Id(23)

TYPE_UNTYPED_INT   :: Type_Id(24)
TYPE_UNTYPED_FLOAT :: Type_Id(25)
TYPE_UNTYPED_BOOL  :: Type_Id(26)
TYPE_UNTYPED_RUNE  :: Type_Id(27)
TYPE_UNTYPED_NIL   :: Type_Id(28)
// A compile-time string; where a value is wanted it defaults to `string`.
TYPE_UNTYPED_STRING :: Type_Id(29)

// design.md "string type conversions": a borrowed view over UTF-8 text that
// owns and terminates nothing.
TYPE_STRING_VIEW :: Type_Id(30)

// design.md "Allocators" and "Allocation failure". `core:mem` and `base:runtime`
// export these identities rather than declaring their own, since the fixed
// lifecycle signatures spell them unqualified. `Allocator` is a one-word
// nominal handle; region identity lives in `src/borrow.odin`, not in the ABI.
TYPE_ALLOCATOR :: Type_Id(31)
TYPE_ALLOCATOR_ERROR :: Type_Id(32)

// design.md "C string views": a non-owning, zero-terminated byte view, and
// deliberately not a promise of UTF-8.
TYPE_CSTRING_VIEW :: Type_Id(33)

FIRST_DYNAMIC_TYPE :: Type_Id(34)

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
	Pointer,
	C_Pointer,
	Slice,
	// design.md "Allocators": a nominal runtime handle, and a nil-comparable
	// error code. Both are compiler-owned identities that `core:mem` exports.
	Allocator,
	Allocator_Error,
	Dynamic_Array,
	// design.md "Owned values": `Box(T)`, one address owning one `T` and the
	// allocator that made it.
	Box,
	Array,
	Map,
	// design.md "SIMD vectors": `Simd(T, N)`, an element type and a count like
	// `Array`, with its own layout rule and operator set.
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

Type_Kinds :: bit_set[Type_Kind]

// A member set the compiler installs on a type rather than the user writing it.
Contribution :: enum u8 {
	Mutable_Iteration,
	Iteration,
	Lifecycle,
	// The `Lifecycle` members are enrolled for emission. A hypothetical check
	// creates them to resolve a lookup; only a real use enrolls them.
	Lifecycle_Enrolled,
	// The compiler-owned canonical receiver members: `len`, `cap`, and `hash` on
	// the built-in types that provide them.
	Standard_Customization,
	Format_Enrolled,
	// design.md "Dynamic arrays" and "Maps": the operation set that makes
	// `xs.append(1)` an ordinary method call.
	Container,
	// The constructors and handle of a local region provider (`src/region.odin`).
}

// What tells apart two types that are alike in everything else: where one is
// written, or for a type made per package, only `pkg`.
Type_Site :: struct {
	pkg:   Package_Id,
	span:  Span,
	scope: ^Scope,
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
	enum_backing_explicit: bool,
	mutable:    bool,
	// Struct fields and enum members, in declaration order.
	fields:     []Symbol_Id,
	// A union's variants, in declaration order. The index *is* the variant's
	// identity and its tag — two variants may carry the same payload type — so
	// variant 0 has tag 0 and there is no nil tag. `variants[i]` is the payload
	// type (`TYPE_VOID` if payloadless).
	variants:   []Type_Id,
	variant_names: []Identifier_Id,
	// design.md "Unions": `@(zero=name)` must be the first variant so the
	// all-zero representation stays the zero value; `@(failure=name)` is what
	// `or_else`/`or_return` recognise structurally.
	zero_designated:    bool,
	failure_designated: bool,
	failure_variant:    int,
	// design.md "@(require_results)": a bare call statement is rejected when any
	// result type requires handling.
	requires_results: bool,
	// A validated `@(align=N)` on a union or struct, or 0. Kept apart from
	// `align`, which the layout pass overwrites with the computed result —
	// `union_layout` is asked again by the emitter after that, and both must agree.
	written_align: u64,
	// design.md "@(packed)": no inter-field padding, natural alignment 1 (an
	// `@(align=N)` may still raise it).
	packed:        bool,
	// `@(move_only)` suppresses the generated ownership-copy operations.
	// This bit records an explicit leaf declaration; containing records inherit
	// it through lifecycle classification.
	move_only:     bool,
	// design.md "@(thread_affine)": values must stay on the thread that made
	// them. Only the declaring type is marked; `transfer_facts` finds what holds
	// or reaches one when it crosses a thread boundary.
	thread_affine: bool,
	// design.md "@(wakes_on_drop)": dropping a value may wake threads waiting
	// on the storage it borrows. Only the declaring type is marked;
	// `type_reaches_waker` finds what holds or reaches one.
	wakes_on_drop: bool,
	// Inherent members written by `impl`. `extend` never writes here — its
	// members are package-scoped and live in `Package.extensions`.
	members:    []Symbol_Id,
	// Which contributed member sets are installed. Several contributors append
	// here, so "already has members" can't be the idempotence guard: whichever
	// ran first would suppress the other.
	contributed: bit_set[Contribution],
	// A generic instance whose hooks are declared and whose hooks' bounds are not
	// all evaluated, so `lifecycle_of` keeps no answer about it yet.
	hooks_resolving: bool,
	parameters: []Type_Id,
	param_modes: []Param_Mode,
	// design.md "Procedure type": the reset effect and the escape levels are part
	// of procedure type identity — an indirect call must not launder a promise
	// through a type that hides it. Nil means every parameter is at the default.
	param_resets: []bool,
	param_escapes: []Escape_Level,
	// design.md "@(cross_thread)": the parameters whose argument runs or travels
	// on another thread, which every call checks, through a value too.
	param_cross_thread: []bool,
	// A compile-time reference to an inferred result contract; plain written
	// signatures erase this bound.
	proc_contract: Symbol_Id,
	// A foreign ABI adapter, also part of identity: erasing it changes the LLVM
	// function type at an indirect call site.
	param_by_ptr: []bool,
	c_vararg:     bool,
	// design.md: at most one result. INVALID_TYPE means none; `TYPE_VOID` is the
	// checked expression type of a no-result call and is never stored here.
	result:       Type_Id,
	result_inout: bool,
	// `(key: string_view, value: int)`: a structural record whose identity is the
	// ordered `(field name, field type)` vector, not the `name` it displays as.
	anonymous_record: bool,
	// `(left: int | right:)`: a structural union whose identity is the ordered
	// `(label, payload)` vector (design.md "Anonymous unions").
	anonymous_union: bool,
	// A labelled anonymous record's unlabelled counterpart, its field types by
	// position: a value converts to it implicitly, and the two share one backend
	// type (design.md "Implicit type conversions").
	unlabelled: Type_Id,
	convention: string,
	// Set once the finite-size check has visited this nominal type, so a cycle
	// is reported at one place instead of once per reference.
	size_state: Size_State,
	// `type_is_supported` said yes, of a type whose records were all finished, so
	// the answer cannot change.
	known_supported: bool,
	// A monomorphized instance: the template it came from and the arguments that
	// produced it. Structural specialization matches against these.
	instance_of:   Symbol_Id,
	instance_args: []Generic_Arg,
	// A compiler-made type's identity for backend names, as readable text such
	// as `Range.int`; the emitter escapes and spells it. An instance is spelled
	// from `instance_of` and `instance_args` instead.
	backend_label: string,
	// An in-place `distinct`, a fresh identity at each place and copy of its text,
	// or an iteration adapter, made per package because its members are looked up
	// from one.
	site:          Type_Site,
	// A `dyn Interface(args...)` type: the interface it erases behind, and the
	// non-subject arguments of the application.
	dyn_interface: Symbol_Id,
	dyn_args:      []Generic_Arg,
	// On a `dyn mut I`: the `dyn I` whose ABI type both capabilities share.
	dyn_read_only: Type_Id,
	// A compiler-owned `Range(T)`, so `..<` and `..=` survive being stored.
	is_range:      bool,
	// design.md "Storage roots and borrow carriers": a borrowed view or
	// iterator. Its storage is a raw pointer or a `string_view`, so nothing
	// structural says "this holds a loan" — this marker is what makes the borrow
	// analysis follow it.
	is_view:       bool,
	// Which traversal a container view names; `.None` on an iterator.
	view_kind:     View_Kind,
	adapter_kind:  Adapter_Kind,
	adapter_by_value: bool,
	// design.md "Compile-time reflection": forbids materializing this descriptor
	// into runtime storage.
	descriptor:    bool,
	// `mem.Arena` or `mem.Scratch` (`src/region.odin`), read by the lifecycle
	// classifier, the region lattice, and the drop path.
	provider:      bool,
	// Cached natural layout (`src/layout.odin`). `offsets` has one entry per
	// struct field, in declaration order.
	layout_state: Size_State,
	// The maximum field alignment with no `@(align=N)`: 1 for a packed or empty
	// record, and for anything else.
	natural_align: u64,
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
// `[]mut T`, `^T` and `^mut T`, are distinct types over one representation.
Type_Key :: struct {
	kind:    Type_Kind,
	element: Type_Id,
	key:     Type_Id,
	count:   u64,
	mutable: bool,
}

Resolution_Kind :: enum u8 {
	Unresolved,
	Error,
	Value,
	Type,
	Package,
	Field,
	Method,
	Call,
	Builtin_Operator,
	User_Operator,
	// `U.name` / `.name` naming a union variant that still needs its payload:
	// the selector alone is not a value, and `check_call` completes it.
	Union_Variant,
}

Value_Category :: enum u8 {
	Invalid,
	Value,
	Place,
	Type,
}

// Why a readable place cannot be assigned to. A value parameter is addressable
// but immutable; a composite literal is addressable temporary storage; neither
// fact follows from the other, so the checker records both plus this reason.
Immutable_Reason :: enum u8 {
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
	// The same, an element of a `[]T`, so the diagnostic can name `[]mut T`.
	Through_Slice,
	// A `foreach` binding over a traversal that lends its element read-only.
	Loop_Binding,
	// A `switch` binding over a payload the subject still owns.
	Payload_Binding,
	// A capture literal's copied or moved capture, a field of its `call`'s
	// plain receiver (design.md "Capture literals").
	Captured_Copy,
	// Any other immutable name, such as an interface requirement binding. These
	// share one flag with a value parameter, so the reason is what keeps the
	// diagnostic from calling every one of them a parameter.
	Read_Only_Name,
}

Resolution :: struct {
	symbol:          Symbol_Id,
	chosen_overload: Symbol_Id,
	kind:            Resolution_Kind,
}

Symbol_Kind :: enum u8 {
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

// Which built-in a `Symbol_Kind.Builtin` symbol is.
Builtin_Kind :: enum u8 {
	None,
	Assert,
	Panic,
	// design.md "Compile-time built-ins".
	Static_Assert,
	Build_Config,
	Source_Location,
	Caller_Location,
	Size_Of,
	Align_Of,
	Offset_Of,
	// design.md "Built-in procedures": no member can answer whether a copy exists.
	Is_Copyable,
	// design.md "Built-in procedures": so a `where` bound can ask at the call.
	Is_Union,
	// design.md "`type` and `typeid`", "Compile-time reflection".
	Type_Of,
	Typeid_Of,
	Fields_Of,
	Enum_Values_Of,
	Variants_Of,
	// design.md "Allocators", "Allocation failure".
	Free_All,
	// design.md "Owned values".
	Box_New,
	Try_Box,
	// design.md "Dynamic arrays", "Maps": its first operand is a *type*.
	Make,
	Try_Make,
	// `mem.default_allocator()`: a generated default argument and a written call
	// are one call.
	Default_Allocator,
	// design.md "Storage modifiers": not a keyword and not an ordinary procedure.
	Drop,
	// design.md "Exchange": no signature says "moves both ways with nothing
	// observable between".
	Exchange,
	// design.md "unsafe.raw_data procedure", "string type conversions": each takes
	// an operand ordinary signatures can't spell.
	Unsafe_Raw_Data,
	Unsafe_String_View,
	Unsafe_C_String_View,
	// design.md "Storage modifiers".
	Unsafe_Forget,
	// design.md "Uninitialized capacity".
	Unsafe_Take,
	Unsafe_Write,
	// Releases an allocation whose root the compiler cannot see.
	Unsafe_Free,
	// design.md "The `unsafe` package".
	Unsafe_New,
	Unsafe_Try_New,
	// design.md "`unsafe.transmute`": its first argument is a *type*.
	Unsafe_Transmute,
	// design.md "Type conversion".
	Math_Wrap,
	// compiler-guide.md "CPU levels". Package-private to `core:math`.
	Math_Fma_Available,
	Math_Fma_Instruction,
	// standard-library.md "`core:math`": each is one instruction with a compile-time
	// value. Package-private to `core:math`.
	Math_Sqrt_Instruction,
	Math_Floor_Instruction,
	Math_Ceil_Instruction,
	Math_Trunc_Instruction,
	Math_Round_Instruction,
	Math_Mod_Instruction,
	Math_Count_Ones,
	Math_Leading_Zeros,
	Math_Trailing_Zeros,
	Math_Rotate_Left,
	Math_Rotate_Right,
	Math_Bit_Width,
	Math_Reverse_Bits,
	Math_Is_Power_Of_Two,
	Math_Next_Power_Of_Two,
	Math_Checked_Next_Power_Of_Two,
	// design.md "SIMD vectors": what a constant lane index makes unwritable as a
	// loop.
	Simd_Cast,
	Simd_Select,
	Simd_Reduce,
	// design.md "`type` and `typeid`": a `typeid` can be forged, so the lookup is
	// checked.
	Type_Info_Of,
	// standard-library.md "Printed forms": the compiler-owned half of `core:fmt`.
	Fmt_Stdout_Writer,
	Fmt_Stderr_Writer,
	Fmt_Write_Bytes,
	// `core:slice`'s typed comparator bridge to the shared runtime introsort.
	Slice_Sort_By,
	// Package-private to `core:strings` and to `core:fmt`, which can't import
	// `core:strings` without pulling in the whole package.
	Strings_Allocate,
	// design.md "Allocation failure": for an `Allocator_Error` a library wrapper
	// got from a `try_` form.
	Allocation_Failed,
	// design.md "Concurrency and the memory model": each requires a constant
	// ordering, which no ordinary signature can ask for.
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

// design.md "Allocation failure": `try_new`, `try_new_clone`, and `try_make`
// are `new`, `new_clone`, and `make` returning the error instead of following
// the allocator's policy.
allocation_builtin :: proc(kind: Builtin_Kind) -> (base: Builtin_Kind, fallible: bool) {
	#partial switch kind {
	case .Try_Box:
		return .Box_New, true
	case .Unsafe_Try_New:
		return .Unsafe_New, true
	case .Try_Make:
		return .Make, true
	}
	return kind, false
}

// What a non-owning binding views. `.None` is an ordinary owning binding.
Borrowed_Binding :: enum u8 {
	None,
	Switch_Payload,
	Loop_Element,
}

// A procedure the compiler contributes: a real symbol whose body the backend
// writes by shape.
Synth_Kind :: enum u8 {
	None,
	Adapter_View,
	Adapter_Iter,
	Indexed_Next,
	Copied_Next,
	Iterator_Copy,
	// Receiver forms of the built-in `len`, `cap` and `hash`.
	Standard_Len,
	Standard_Cap,
	Standard_Hash,
	Standard_Format,
	Range_Iter,
	Range_Iter_Reverse,
	Range_Next,
	Array_Iter,
	Array_Iter_Reverse,
	Array_Next,
	Slice_Mut_Next,
	Slice_Ref_Next,
	// Builds a slice's `{ data, index }`, so `next` is the slice one.
	Dynamic_Iter,
	Dynamic_Iter_Reverse,
	Map_Iter,
	Map_Next,
	Map_Keys_Next,
	Map_Values_Next,
	Map_View_Iter,
	// Serves `string`, `string_view` and the rune-offset view alike.
	Text_Iter,
	Text_Next,
	Rune_Offsets_Next,
	// standard-library.md "Chunks of a mutable slice".
	Chunks_Next,
	Try_Clone,
	Clone,
	Dyn_Forward,
	// A procedure held by a `dyn proc` view: its data word, called with the rest.
	Dyn_Proc_Adapter,
	// Which operation is `Symbol.container_op`.
	Container_Op,
	// Which operation is `Symbol.provider_op`.
	Provider_Op,
	// `U.name` of a payload variant used as a value: the owner type is the
	// union and the symbol's name the variant.
	Variant_Construct,
}

// One per local and field in the compilation, so the fields go by size, largest
// first, and leave no padding between them.
Symbol :: struct {
	const_value: Const_Value,
	params:      []Type_Id,
	// Flattened one entry per parameter name, so `proc(a, b: int)` has two of
	// each. Defaults are the declaration's syntax, evaluated at the call site.
	param_symbols:  []Symbol_Id,
	param_defaults: []Expr,
	members:     []Symbol_Id,
	decl:        ^Decl,
	// Expression-position procedures have no declaration wrapper; keeping their
	// syntax here lets the evaluator run the same body the backend emits.
	proc_literal: ^Expr_Proc,
	// The declaration's own lexical scope, what definition-site lookup hangs an
	// instantiation off instead of the caller's.
	def_scope:     ^Scope,
	def_file_node: ^File,
	// The canonical text of `operator(sym)`, or "" for an ordinary procedure.
	// `[]=` and `[:]` are several tokens, so this is text rather than a token.
	operator:     string,
	// The declaring procedure literal, for the capture check.
	owner_proc:  rawptr,
	// design.md "@(packed)": a case binding over a place whose storage is a
	// packed field, by that field's name. It is bound as a copy, and borrowing
	// it is the misaligned borrow `&value.field` would be.
	packed_field:     string,
	cleanup_slot:     int,
	// design.md "Allocators": the written `via` expression, or nil for the lazy
	// default. Kept on the *declaration* because it survives drop and move and is
	// what a later revival selects; a live value carries its own handle.
	via:              Expr,
	// design.md "`@(deprecated=<string>)`": the warning message printed at each
	// use of this procedure, or "" if it is not deprecated.
	deprecated_message: string,
	link_name:          string,

	name:        Identifier_Id,
	span:        Span,
	type:        Type_Id,
	result:      Type_Id, // INVALID_TYPE when the procedure has no result
	proc_type:   Type_Id,
	pkg:         Package_Id,
	// The package whose method, operator, and extension tables this body may use
	// — not always the one being checked: `delegate` freezes it at its
	// declaration, and instantiations look up at their definition site.
	lookup_pkg:  Package_Id,
	// The `impl`/`extend` subject this member belongs to, or INVALID_TYPE.
	owner_type:  Type_Id,
	instance_of:   Symbol_Id,
	def_file:      u32,
	// A `delegated` overload's underlying type, and the operation it forwards to:
	// INVALID_SYMBOL when that operation is the built-in.
	delegate_underlying: Type_Id,
	delegate_target:     Symbol_Id,
	iteration_target:    Symbol_Id,
	// Field or enum-member position in its owning type; parameter position in
	// its signature.
	index:       u32,
	// design.md "Uninitialized capacity": `@(initialized = count)` names the
	// sibling field holding how many leading elements are live. The generated
	// copy and drop visit that prefix only.
	initialized_by: Symbol_Id,

	kind:        Symbol_Kind,
	builtin:     Builtin_Kind,
	// design.md "Exported names": package-private by default.
	public:      bool,
	// design.md "@(require_results)": whether the name was ever read after its
	// declaration. Only a local of a required-result type asks.
	named:       bool,
	// design.md "Predeclared names": `true`, `false` and `nil` spell literals, so
	// a declaration may not take one of those names. Every other predeclared name
	// stays shadowable.
	reserved:    bool,
	// A generic argument bound in an instance's scope, so a signature can tell
	// which of its types change with the instance (design.md "Success returns").
	generic_binding: bool,
	result_inout: bool,
	// Declared `-> !`: a call never returns and stands in for any value
	// (design.md "Diverging procedures"). Not part of `proc_type`.
	diverges:    bool,
	// A template, which has no signature until instantiated.
	generic:       bool,
	// A first parameter named `self` whose type is the owner. `^T` is not a
	// receiver and gets no method-call sugar.
	has_receiver: bool,
	receiver:     Param_Mode,
	// A closed compiler-controlled semantic role; operators use `operator` above.
	hook:         Hook_Kind,
	// `validate_semantic_hook` accepted this lifecycle role.
	hook_bound:   bool,
	// Which container operation a contributed member is (`src/container.odin`).
	container_op: Container_Op,
	// Which region-provider operation it is (`src/region.odin`).
	provider_op:  Provider_Op,
	// A forwarding overload `delegate(...)` generated. It has no body: the
	// backend applies the underlying type's operation to the unwrapped operands.
	delegated:           bool,
	// Signature resolution already reported why this procedure has no usable
	// type, so the gate must not report a second time for the same mistake.
	signature_error: bool,
	// design.md "where clauses": the bound of an instantiated generic `impl` does
	// not hold, so the method is not part of that instantiation. The symbol stays
	// only so a call can say why it is missing.
	bound_excluded: bool,
	// An instantiated generic `impl` member a more specialized block replaced
	// before any use: no longer a member, so its body is neither checked nor
	// emitted for that instance.
	superseded: bool,
	// A member lookup found this entry, so a later block can no longer replace it.
	looked_up: bool,
	// A procedure the compiler contributes: it has a real symbol and signature,
	// and the backend writes its body (`src/iterate.odin`).
	synth:       Synth_Kind,
	// In `synth_procs`, so emitted: a use that commits it enrolled it.
	synth_enrolled: bool,
	// design.md "Required fields": every literal supplies this field, so its
	// record has no zero value.
	required:    bool,
	// design.md "@(synchronized)": a field or shared variable whose declaring
	// package synchronizes every access to it.
	synchronized: bool,
	mode:        Param_Mode,
	// A value parameter is immutable storage; an `inout` parameter is a mutable
	// alias. Both are addressable.
	immutable:   bool,
	// A binding that views storage another owner still holds, so `move`/`drop`
	// have no owner here to transfer or release (design.md "Unions",
	// "By-reference iteration").
	borrowed_binding: Borrowed_Binding,
	// design.md "`@(allocator_reset)`": a successful call may end this
	// parameter's region. Verified in the body, carried in the procedure type.
	allocator_reset: bool,
	// design.md "@(cross_thread)": the argument runs or travels on another
	// thread. Carried in the procedure type.
	cross_thread:    bool,
	// design.md `@(escape=...)`: what a call may leave behind that depends on
	// this parameter. `.Result` unless written otherwise.
	escape:          Escape_Level,
	// design.md "Managed values and storage": an implicit `defer drop(value)` at
	// the declaration point. `src/lifecycle.odin` decides from the CFG whether
	// scope exit drops this local, and whether that is the same on every path —
	// a definite state needs no runtime flag.
	drop_at_exit:     bool,
	drop_conditional: bool,
	// Live where a statement may panic, so the unwind may drop it though every
	// normal exit finds it moved out (design.md "What the unwind runs, and what it
	// does not").
	drop_on_unwind:   bool,
	// design.md "Storage modifiers": `static` or `thread_local` makes a *local*
	// declaration name storage outside the frame, so the backend gives it a
	// global rather than an `alloca`.
	duration:         Duration,
	deprecated:         bool,
	// design.md "@(require_results)": each call must use or explicitly discard the
	// results. Applied to a procedure group after overload selection.
	require_results:    bool,
	// design.md "@(cpu_dispatch=<string>)": a call runs a copy compiled for this
	// level where the processor has it, when the build's level is lower. The
	// baseline, never above a build's level, for a procedure that does not ask.
	dispatch_cpu:       Cpu_Level,
	// design.md "Foreign system": no body, so the backend emits a
	// `declare`/`external global` under `link_name`. The source library isn't
	// recorded — every foreign block links against the one image.
	is_foreign:         bool,
	// design.md "Promoted struct fields": a `using` field, whose own fields its
	// record's selectors also reach.
	is_using:           bool,
	// design.md "@(export)": emit under `link_name` rather than the mangled
	// `@loke.p...`, so a C consumer can link to it.
	exported:           bool,
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
	// Set when a lookup finds a name here. Only a probe reads it: whether a
	// `$` default resolves any of its procedure's parameters.
	reached:    bool,
	// Set when an operator is declared here, so most scopes skip that search.
	declares_operator: bool,
	// The generic instance whose bindings this scope holds, or nil. A type
	// declared in one instance's body is told from another's by it.
	instance:   ^Instance,
	// Which copy of a static expansion or expanded case this scope holds, from 1,
	// or 0. It tells a type declared in one copy from the others', as `instance` does.
	expansion:  int,
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
	// The canonical import identity — root-relative, or
	// `collection:relative/path` — which every user symbol is mangled with. Never
	// an alias and never a host absolute path, so a build is reproducible and two
	// same-named packages cannot collide. The root package's key is "", unless
	// its directory is inside a collection.
	key:            string,
	files:          [dynamic]^File,
	scope:          ^Scope,
	// `extend` members, keyed by subject type. Package-scoped by design: an
	// unused import must not make an existing expression ambiguous, so this is
	// never merged into the type itself.
	extensions:     map[Type_Id][]Symbol_Id,
	operators:      map[string][dynamic]Symbol_Id,
	imports:        [dynamic]Package_Import,
	// How many of `imports` already had their alias bound. The edge list only
	// grows, so a later discovery round starts here instead of re-reporting an
	// alias that already collided.
	bound_aliases:  int,
	// Procedure literals lifted out of expression position, owned by the package
	// that declared them.
	hoisted_procs:  [dynamic]^Expr_Proc,
	// Generic instances defined here, in deterministic instantiation order.
	// Emitted after the package's own items, so a cross-package generic call has
	// a final name before any body is written.
	instances:      [dynamic]Instance_Decl,
	// Whether the compiler already bound its own members into this package's
	// scope (`src/stdlib.odin`). Discovery re-runs; contribution must not.
	contributed:    bool,
	// The names contributed, in contribution order, and the `@(intrinsic)`
	// declarations that describe them (`src/intrinsic.odin`), bound once.
	contributions:  [dynamic]Identifier_Id,
	intrinsics:     [dynamic]Intrinsic_Decl,
	// Its declarations by name, for the private-name reads (`src/private_names.odin`).
	declared_names: ^Package_Names,
	// Whether a file-scope `when` here has not settled, every name its branches
	// could declare, every member an `impl` block in them could declare, and
	// whether one holds a lifecycle hook. Rebuilt with the active view, so within a
	// round they still cover what that round's choices selected but have not
	// declared.
	has_pending_whens:     bool,
	pending_when_names:    map[Identifier_Id]bool,
	pending_block_members: map[Identifier_Id]bool,
	pending_block_hooks:   bool,
}

// Address space each per-body scratch arena reserves.
SCRATCH_ARENA_RESERVE :: mem.Gigabyte

// The per-body scratch arenas, empty.
@(private)
init_analysis_arenas :: proc(c: ^Compiler) {
	for arena in ([]^Scratch_Arena{&c.analysis_arena, &c.replay_carry_arena, &c.replay_round_arena}) {
		if err := scratch_arena_init(arena, SCRATCH_ARENA_RESERVE); err != nil {
			panic("cannot reserve the compilation's analysis arenas")
		}
	}
	c.analysis_allocator = scratch_allocator(&c.analysis_arena)
}

@(private)
destroy_analysis_arenas :: proc(c: ^Compiler) {
	scratch_arena_destroy(&c.analysis_arena)
	scratch_arena_destroy(&c.replay_carry_arena)
	scratch_arena_destroy(&c.replay_round_arena)
}

init_semantic_stores :: proc(c: ^Compiler) {
	if c.semantic_initialized {
		return
	}
	c.semantic_initialized = true
	c.target = windows_x64_target(c.cpu)
	// A growing virtual arena: `mem.Dynamic_Arena` rejects allocations over its
	// block size, and `append`/`make` swallow the error.
	if err := virtual.arena_init_growing(&c.semantic_arena); err != nil {
		panic("cannot reserve the compilation's semantic arena")
	}
	c.semantic_allocator = virtual.arena_allocator(&c.semantic_arena)
	init_analysis_arenas(c)
	c.collections = make(map[string]string, c.semantic_allocator)
	c.identifier_names = make([dynamic]string, 0, 64, c.semantic_allocator)
	c.identifier_by_name = make(map[string]Identifier_Id, c.semantic_allocator)
	c.types = make([dynamic]^Type_Info, 0, 64, c.semantic_allocator)
	c.type_by_shape = make(map[Type_Key]Type_Id, c.semantic_allocator)
	c.anon_record_types = make(map[u64][]Type_Id, c.semantic_allocator)
	c.anon_union_types = make(map[u64][]Type_Id, c.semantic_allocator)
	c.proc_types = make(map[u64][]Type_Id, c.semantic_allocator)
	c.symbols = make([dynamic]^Symbol, 0, 128, c.semantic_allocator)
	c.packages = make([dynamic]^Package, 0, 8, c.semantic_allocator)
	c.generic_templates = make(map[Symbol_Id]^Generic_Template, c.semantic_allocator)
	c.generic_impls = make(map[Symbol_Id][dynamic]^Generic_Impl, c.semantic_allocator)
	c.instances = make(map[string]^Instance, c.semantic_allocator)
	c.procedure_instances = make(map[Symbol_Id]^Instance, c.semantic_allocator)
	c.alias_expansions = make(map[string]Type_Id, c.semantic_allocator)
	c.instantiation_stack = make([dynamic]Instantiation_Frame, 0, 8, c.semantic_allocator)
	c.pending_impl_instances = make([dynamic]Pending_Impl, 0, 4, c.semantic_allocator)
	c.pending_delegates = make(map[Type_Id][dynamic]Pending_Delegate, c.semantic_allocator)
	c.pending_operator_blocks = make([dynamic]Pending_Operator_Block, 0, 8, c.semantic_allocator)
	c.pending_operators = make([dynamic]Pending_Operator, 0, 8, c.semantic_allocator)
	c.pending_private_reads = make([dynamic]Pending_Private_Read, 0, 4, c.semantic_allocator)
	c.private_reads_settled = make(map[Span]bool, c.semantic_allocator)
	c.private_names_warned = make(map[Span]bool, c.semantic_allocator)
	c.generic_impl_types = make(map[Span]bool, c.semantic_allocator)
	c.interfaces = make(map[Symbol_Id]^Interface_Info, c.semantic_allocator)
	c.map_key_policies = make(map[Type_Id]Key_Policy, c.semantic_allocator)
	c.order_policies = make(map[Type_Id]Order_Policy, c.semantic_allocator)
	c.typeid_requested = make(map[Type_Id]bool, c.semantic_allocator)
	c.typeid_order = make([dynamic]Type_Id, 0, 8, c.semantic_allocator)
	c.typeid_values = make(map[Type_Id]u64, c.semantic_allocator)
	c.range_types = make(map[Type_Id]Type_Id, c.semantic_allocator)
	c.iterator_types = make(map[Type_Id]Type_Id, c.semantic_allocator)
	c.view_types = make(map[View_Key]Type_Id, c.semantic_allocator)
	c.adapter_members = make(map[Adapter_Key]Symbol_Id, c.semantic_allocator)
	c.derived_members = make(map[Derived_Key]struct{}, c.semantic_allocator)
	c.capture_records = make(map[Type_Id]^Expr_Proc, c.semantic_allocator)
	c.capture_placeholders = make(map[Symbol_Id]Capture_Placeholder, c.semantic_allocator)
	c.carrier_reach = make(map[Type_Id]Carrier_Reach, c.semantic_allocator)
	c.reaches_destination = make(map[Type_Id]bool, c.semantic_allocator)
	c.reaches_mutable = make(map[Type_Id]bool, c.semantic_allocator)
	c.provider_carriers = make(map[Type_Id]bool, c.semantic_allocator)
	c.has_region = make(map[Type_Id]bool, c.semantic_allocator)
	c.holds_allocator = make(map[Type_Id]bool, c.semantic_allocator)
	c.view_reaches_provider = make(map[Type_Id]bool, c.semantic_allocator)
	c.carrier_shapes = make(map[Type_Id][]Carrier_Path, c.semantic_allocator)
	c.may_hold_address = make(map[Type_Id]bool, c.semantic_allocator)
	c.region_shapes = make(map[Type_Id][]Prov_Region_Content, c.semantic_allocator)
	c.synth_procs = make([dynamic]Symbol_Id, 0, 8, c.semantic_allocator)
	c.variant_constructors = make(map[Variant_Key]Symbol_Id, c.semantic_allocator)
	c.dyn_types = make(map[string]Type_Id, c.semantic_allocator)
	c.dyn_slots = make(map[Type_Id][]Interface_Slot, c.semantic_allocator)
	c.witnesses = make(map[string]^Witness, c.semantic_allocator)
	c.interface_witnesses = make(map[Symbol_Id][dynamic]^Witness, c.semantic_allocator)
	c.witness_order = make([dynamic]^Witness, 0, 4, c.semantic_allocator)
	c.dyn_proc_adapters = make(map[Type_Id]Symbol_Id, c.semantic_allocator)
	c.materialized = make(map[Materialized_Key]^Materialized, c.semantic_allocator)
	c.materialized_order = make([dynamic]^Materialized, 0, 4, c.semantic_allocator)
	c.spawn_tasks = make([dynamic]^Spawn_Task, 0, 2, c.semantic_allocator)
	c.spawn_calls = make(map[^Expr_Call]^Spawn_Task, 2, c.semantic_allocator)
	c.lifecycles = make(map[Type_Id]^Lifecycle, c.semantic_allocator)
	c.validated_attributes = make(map[u64]bool, c.semantic_allocator)
	c.reported_copy_failures = make(map[u64]bit_set[Copy_Failure], c.semantic_allocator)
	c.reported_generic_hooks = make(map[u64]bool, c.semantic_allocator)
	c.lifecycle_operations = make(map[Type_Id]Lifecycle_Operations, c.semantic_allocator)
	c.runtime_types = make(map[string]Type_Id, c.semantic_allocator)
	c.formatters = make(map[Type_Id]^Witness, c.semantic_allocator)
	c.result_summary_dependencies = make(map[Symbol_Id][]Symbol_Id, c.semantic_allocator)
	c.reset_dead = make(map[Reset_Key]Reset_Liveness, c.semantic_allocator)
	c.cleanup_reset_dead = make(map[Reset_Key]Reset_Liveness, c.semantic_allocator)
	c.package_by_dir = make(map[string]Package_Id, c.semantic_allocator)
	c.map_keyed = make(map[Type_Id]bool, c.semantic_allocator)
	c.checked_bodies = make([dynamic]Checked_Body, 0, 16, c.semantic_allocator)
	c.checked_body_symbols = make(map[Symbol_Id]bool, c.semantic_allocator)
	c.result_summaries = make(map[Symbol_Id]^Result_Provenance, c.semantic_allocator)
	c.receiver_contracts = make(map[Symbol_Id]Symbol_Id, c.semantic_allocator)
	c.receiver_contract_of = make(map[Symbol_Id]Symbol_Id, c.semantic_allocator)
	c.written_summaries = make(map[Symbol_Id]Written_Summary, c.semantic_allocator)
	c.carrier_moves = make(map[Symbol_Id][]Carrier_Move, c.semantic_allocator)
	c.thread_local_writes = make(map[Symbol_Id][]Symbol_Id, c.semantic_allocator)
	c.callback_thread_local_writes = make(map[Symbol_Id][]Callback_Write, c.semantic_allocator)
	c.callback_result_reads = make(map[Symbol_Id][]Callback_Read, c.semantic_allocator)
	c.called_values = make(map[Call_Site][]Effect_Arg, c.semantic_allocator)
	c.argument_values = make(map[Call_Site][]Effect_Arg, c.semantic_allocator)
	c.proc_contract_checks = make([dynamic]Proc_Contract_Check, 0, 4, c.semantic_allocator)
	c.contract_joins = make([dynamic]Symbol_Id, 0, 4, c.semantic_allocator)
	c.static_locals = make([dynamic]Symbol_Id, 0, 4, c.semantic_allocator)
	c.tests = make([dynamic]Symbol_Id, 0, 4, c.semantic_allocator)

	append(&c.identifier_names, "")
	pointer_bits := c.target.pointer_bits
	int_bits := c.target.int_bits
	predeclared := [?]Type_Info {
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
	}
	for info in predeclared {
		new_type(c, info)
	}
	assert(Type_Id(len(c.types)) == FIRST_DYNAMIC_TYPE, "predeclared type table is out of step with its IDs")
	new_symbol(c, Symbol{})
	append(&c.packages, new(Package, c.semantic_allocator))
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
	owned := strings.clone(text, c.semantic_allocator)
	append(&c.identifier_names, owned)
	c.identifier_by_name[owned] = id
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
	append(&c.symbols, new_clone(value, c.semantic_allocator))
	return id
}

// One field of a compiler-owned struct-shaped type — a slice, a container
// header, a range.
new_field :: proc(c: ^Compiler, name: string, type: Type_Id, index: int, public := false) -> Symbol_Id {
	return new_symbol(c, Symbol {
		name   = intern_identifier(c, name),
		span   = NO_SPAN,
		kind   = .Field,
		type   = type,
		index  = u32(index),
		public = public,
	})
}

add_members :: proc(c: ^Compiler, type: Type_Id, added: []Symbol_Id) {
	info := type_of(c, type)
	if info == nil || len(added) == 0 {
		return
	}
	info.members = slice.concatenate([][]Symbol_Id{info.members, added}, c.semantic_allocator)
}

new_associated_type :: proc(c: ^Compiler, name: string, value, owner: Type_Id) -> Symbol_Id {
	return new_symbol(c, Symbol {
		name        = intern_identifier(c, name),
		span        = NO_SPAN,
		kind        = .Const,
		type        = TYPE_TYPE,
		const_value = type_const(value),
		owner_type  = owner,
		public      = true,
	})
}

new_parameter :: proc(c: ^Compiler, name: Identifier_Id, type: Type_Id, mode: Param_Mode) -> Symbol_Id {
	return new_symbol(c, Symbol{name = name, kind = .Parameter, type = type, mode = mode})
}

synth_proc :: proc(
	c: ^Compiler,
	name: string,
	kind: Synth_Kind,
	owner: Type_Id,
	params: []Type_Id,
	modes: []Param_Mode,
	result: Type_Id,
	enroll := true,
) -> Symbol_Id {
	proc_type := intern_proc_type(c, params, modes, result, false, "")
	id := new_symbol(c, Symbol {
		name          = intern_identifier(c, name),
		span          = NO_SPAN,
		kind          = .Proc,
		public        = true,
		owner_type    = owner,
		params        = type_of(c, proc_type).parameters,
		result        = result,
		param_symbols = make([]Symbol_Id, len(params), c.semantic_allocator),
		param_defaults = make([]Expr, len(params), c.semantic_allocator),
		proc_type     = proc_type,
		synth         = kind,
	})
	if enroll { enroll_synth(c, id) }
	return id
}

// A member whose receiver is its first parameter.
synth_receiver_proc :: proc(
	c: ^Compiler,
	name: string,
	kind: Synth_Kind,
	owner: Type_Id,
	params: []Type_Id,
	modes: []Param_Mode,
	result: Type_Id,
	enroll := true,
) -> Symbol_Id {
	id := synth_proc(c, name, kind, owner, params, modes, result, enroll)
	sym := symbol_of(c, id)
	sym.has_receiver, sym.receiver = true, modes[0]
	return id
}

// A member taking only its receiver, whose result depends on that receiver: an
// `iter` or `next`, say, with the member it wraps as its `target`.
synth_self_member :: proc(c: ^Compiler, name: string, kind: Synth_Kind, owner: Type_Id, mode: Param_Mode, result: Type_Id, target := INVALID_SYMBOL) -> Symbol_Id {
	id := synth_receiver_proc(c, name, kind, owner, []Type_Id{owner}, []Param_Mode{mode}, result)
	sym := symbol_of(c, id)
	sym.iteration_target = target
	// `synth_proc` enrolled the adapter before it had a target.
	if sym.synth_enrolled { enroll_synth(c, target) }
	set_synth_result_summary(c, id, 0)
	return id
}

// The constant zero of `type`, for a defaulted parameter of a synthesized member.
zero_literal_arg :: proc(c: ^Compiler, type: Type_Id) -> Expr {
	literal := new(Expr_Literal, c.semantic_allocator)
	literal.span = NO_SPAN
	literal.kind = .Int
	literal.type = type
	literal.value_category = .Value
	literal.const_value = int_const(c, 0)
	return literal
}

// A synthesized member stays on its type once created, but only a use that
// commits it is emitted (compiler-architecture.md "Checking and overload
// resolution"), so a use that finds one a probe created enrolls it here, along
// with what its emitted body calls.
enroll_synth :: proc(c: ^Compiler, id: Symbol_Id) {
	sym := symbol_of(c, id)
	if !committing(c) || sym == nil || sym.synth == .None || sym.synth_enrolled {
		return
	}
	sym.synth_enrolled = true
	append(&c.synth_procs, id)
	// An adapter's body calls the member it adapts.
	enroll_synth(c, sym.iteration_target)
}

symbol_of :: proc(c: ^Compiler, id: Symbol_Id) -> ^Symbol {
	index := int(id)
	if index <= 0 || index >= len(c.symbols) {
		return nil
	}
	return c.symbols[index]
}

// Static, thread-local, or file-scope storage: it outlives every procedure body.
symbol_outlives_bodies :: proc(sym: ^Symbol) -> bool {
	return sym.duration != .None || (sym.decl != nil && sym.decl.top_level)
}

// How a diagnostic names such storage; a top-level declaration has no duration.
storage_phrase :: proc(duration: Duration) -> string {
	switch duration {
	case .Thread_Local: return "`thread_local` storage"
	case .Static:       return "`static` storage"
	case .None:
	}
	return "file-scope storage"
}

new_type :: proc(c: ^Compiler, value: Type_Info) -> Type_Id {
	init_semantic_stores(c)
	id := Type_Id(len(c.types))
	append(&c.types, new_clone(value, c.semantic_allocator))
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
	proc_contract := INVALID_SYMBOL,
	param_cross_thread: []bool = nil,
) -> Type_Id {
	init_semantic_stores(c)
	hash := HASH_OFFSET_BASIS
	for parameter in parameters {
		hash = hash_mix(hash, u64(parameter))
	}
	for mode in param_modes {
		hash = hash_mix(hash, u64(mode))
	}
	hash = hash_mix(hash, u64(result))
	// Every field the comparison below reads contributes, normalized the same
	// way: same-shape procedures with distinct contracts would otherwise share
	// one bucket and make each insertion scan and copy all of them.
	hash = hash_mix(hash, u64(proc_contract))
	hash = hash_mix(hash, u64(result_inout) ~ u64(c_vararg) << 1)
	for index in 0 ..< len(convention) {
		hash = hash_mix(hash, u64(convention[index]))
	}
	for value, index in param_resets {
		if value { hash = hash_mix(hash, u64(index + 1)) }
	}
	for value, index in param_by_ptr {
		if value { hash = hash_mix(hash, u64(index + 1) << 16) }
	}
	for level, index in param_escapes {
		if level != .Result {
			hash = hash_mix(hash, u64(index + 1) << 32 ~ u64(level))
		}
	}
	for value, index in param_cross_thread {
		if value { hash = hash_mix(hash, u64(index + 1) << 48) }
	}
	bucket := c.proc_types[hash]
	for candidate in bucket {
		info := c.types[candidate]
		if info.convention == convention &&
		   slice.equal(info.parameters, parameters) &&
		   slice.equal(info.param_modes, param_modes) &&
		   info.result == result &&
		   info.result_inout == result_inout &&
		   equal_padded(info.param_resets, param_resets, false) &&
		   equal_padded(info.param_by_ptr, param_by_ptr, false) &&
		   equal_padded(info.param_escapes, param_escapes, Escape_Level.Result) &&
		   equal_padded(info.param_cross_thread, param_cross_thread, false) &&
		   info.proc_contract == proc_contract &&
		   info.c_vararg == c_vararg {
			return candidate
		}
	}
	id := new_type(c, Type_Info {
		kind          = .Proc,
		bits          = c.target.pointer_bits,
		parameters    = slice.clone(parameters, c.semantic_allocator),
		param_modes   = slice.clone(param_modes, c.semantic_allocator),
		param_resets  = clone_unless_default(param_resets, false, c.semantic_allocator),
		param_escapes = clone_unless_default(param_escapes, Escape_Level.Result, c.semantic_allocator),
		param_cross_thread = clone_unless_default(param_cross_thread, false, c.semantic_allocator),
		proc_contract = proc_contract,
		param_by_ptr  = clone_unless_default(param_by_ptr, false, c.semantic_allocator),
		c_vararg      = c_vararg,
		result        = result,
		result_inout  = result_inout,
		convention    = convention,
	})
	bucket_append(c, &c.proc_types, hash, id)
	return id
}

// A per-parameter list is stored only when something in it is not the default.
@(private = "file")
clone_unless_default :: proc(values: []$T, default: T, allocator: mem.Allocator) -> []T {
	for value in values {
		if value != default {
			return slice.clone(values, allocator)
		}
	}
	return nil
}

// Whether two per-parameter lists agree, where one too short, or absent, is at
// the default for the parameters it lacks.
@(private = "file")
equal_padded :: proc(a, b: []$T, default: T) -> bool {
	for index in 0 ..< max(len(a), len(b)) {
		left := index < len(a) ? a[index] : default
		right := index < len(b) ? b[index] : default
		if left != right {
			return false
		}
	}
	return true
}

// Appends `item` unless `list` holds it already; whether it did.
@(private)
append_unique :: proc(list: ^[dynamic]$T, item: T) -> bool {
	if slice.contains(list[:], item) {
		return false
	}
	append(list, item)
	return true
}

// Adds `item` to a set kept as a slice; returns whether the set grew.
@(private)
set_add :: proc(set: ^[]$T, item: T, allocator: mem.Allocator) -> bool {
	if slice.contains(set^, item) {
		return false
	}
	grown := make([]T, len(set^) + 1, allocator)
	copy(grown, set^)
	grown[len(set^)] = item
	set^ = grown
	return true
}

// Adds a newly interned type to the bucket its hash selects.
@(private = "file")
bucket_append :: proc(c: ^Compiler, buckets: ^map[u64][]Type_Id, hash: u64, id: Type_Id) {
	bucket := buckets[hash]
	grown := make([]Type_Id, len(bucket) + 1, c.semantic_allocator)
	copy(grown, bucket)
	grown[len(bucket)] = id
	buckets[hash] = grown
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

// A parameter's mode, by value when the type records none for it.
param_mode_at :: proc(info: ^Type_Info, index: int) -> Param_Mode {
	return info != nil && index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
}

proc_parameter_mode :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> Param_Mode {
	return param_mode_at(underlying_info(c, proc_type), index)
}

// The procedure type a call goes through: the chosen overload's, or the callee
// value's for an indirect call, which is where `@(escape=...)` matters most.
call_proc_type :: proc(c: ^Compiler, v: ^Expr_Call) -> Type_Id {
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil {
		return sym.proc_type
	}
	if base := expr_base(v.callee); base != nil {
		return base.type
	}
	return INVALID_TYPE
}

symbol_param_mode :: proc(c: ^Compiler, symbol: ^Symbol, index: int) -> Param_Mode {
	return proc_parameter_mode(c, symbol.proc_type, index)
}

// design.md `@(escape=<level>)`. Levels carry no ABI, so the assignment is a
// plain pointer copy.
proc_type_weakens_to :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	a := type_of(c, from)
	b := type_of(c, to)
	if a == nil || b == nil || a.kind != .Proc || b.kind != .Proc {
		return false
	}
	if a.convention != b.convention ||
	   a.c_vararg != b.c_vararg ||
	   !parameters_weaken_to(c, a, b) ||
	   a.result != b.result ||
	   a.result_inout != b.result_inout ||
	   !equal_padded(a.param_resets, b.param_resets, false) ||
	   !equal_padded(a.param_by_ptr, b.param_by_ptr, false) {
		return false
	}
	for index in 0 ..< len(a.parameters) {
		// design.md "@(cross_thread)": calls through the destination may check an
		// argument the procedure does not need checked, never skip one it does.
		if proc_param_crosses_thread(c, from, index) && !proc_param_crosses_thread(c, to, index) {
			return false
		}
		have, want := proc_param_escape(c, from, index), proc_param_escape(c, to, index)
		// An inferred contract may meet a written `none`; `check_proc_contracts`
		// checks it once inference settles.
		if have > want && !(have == .Result && want == .None && a.proc_contract != INVALID_SYMBOL) {
			return false
		}
	}
	if b.proc_contract != INVALID_SYMBOL && a.proc_contract == INVALID_SYMBOL {
		return false
	}
	return true
}

// design.md "Receiver forms": a `self: ^Self` method is the same procedure as
// one taking `^Self`, so a method value stores in a `proc(^T)` variable.
@(private = "file")
parameters_weaken_to :: proc(c: ^Compiler, a, b: ^Type_Info) -> bool {
	if len(a.parameters) != len(b.parameters) || len(a.param_modes) != len(b.param_modes) {
		return false
	}
	for index in 0 ..< len(a.parameters) {
		from, to := a.parameters[index], b.parameters[index]
		from_mode := param_mode_at(a, index)
		to_mode := param_mode_at(b, index)
		if from == to && from_mode == to_mode {
			continue
		}
		target := type_of(c, to)
		if from_mode != .Borrow || to_mode != .Value ||
		   target.kind != .Pointer || target.mutable || target.element != from {
			return false
		}
	}
	return true
}

// design.md "@(cross_thread)": whether the argument for parameter `index` runs
// or travels on another thread.
proc_param_crosses_thread :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> bool {
	info := underlying_info(c, proc_type)
	return info != nil && index < len(info.param_cross_thread) && info.param_cross_thread[index]
}

proc_param_resets :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> bool {
	info := underlying_info(c, proc_type)
	return info != nil && index < len(info.param_resets) && info.param_resets[index]
}

// The identity of a type made here is its key: everything else in its
// `Type_Info` follows from that, so who interns it first cannot show.
intern_type :: proc(c: ^Compiler, key: Type_Key) -> Type_Id {
	if id, ok := c.type_by_shape[key]; ok {
		return id
	}
	id := new_type(c, Type_Info {
		kind    = key.kind,
		element = key.element,
		key     = key.key,
		count   = key.count,
		mutable = key.mutable,
	})
	if key.kind in (Type_Kinds{.Pointer, .C_Pointer, .Box}) {
		c.types[id].bits = c.target.pointer_bits
	}
	c.type_by_shape[key] = id
	return id
}

// One field or alternative of an anonymous type, whose identity is the ordered
// sequence of these (design.md "Anonymous records", "Anonymous unions"). A
// payloadless alternative's type is `TYPE_VOID`, as a named union's is.
Anon_Member :: struct {
	name: Identifier_Id,
	type: Type_Id,
}

@(private = "file")
anon_hash :: proc(members: []Anon_Member) -> u64 {
	hash := HASH_OFFSET_BASIS
	for member in members {
		hash = hash_mix(hash, u64(member.name))
		hash = hash_mix(hash, u64(member.type))
	}
	return hash
}

// Interns one anonymous record. Takes specs rather than field symbols so a
// cache hit does not leak the orphan `Symbol`s a caller would have had to build
// speculatively.
anon_record_type :: proc(c: ^Compiler, fields: []Anon_Member) -> Type_Id {
	hash := anon_hash(fields)
	for candidate in c.anon_record_types[hash] {
		info := c.types[candidate]
		if len(info.fields) != len(fields) {
			continue
		}
		same := true
		for field, index in fields {
			member := symbol_of(c, info.fields[index])
			if member.name != field.name || member.type != field.type {
				same = false
				break
			}
		}
		if same {
			return candidate
		}
	}

	unlabelled := INVALID_TYPE
	if len(fields) >= 2 && !name_is_positional(identifier_text(c, fields[0].name)) {
		positional := make([]Anon_Member, len(fields), context.temp_allocator)
		for field, index in fields {
			positional[index] = {name = positional_field_name(c, index), type = field.type}
		}
		unlabelled = anon_record_type(c, positional)
	}

	members := make([]Symbol_Id, len(fields), c.semantic_allocator)
	for field, index in fields {
		members[index] = new_field(c, identifier_text(c, field.name), field.type, index, public = true)
	}
	id := new_type(c, Type_Info {
		kind             = .Struct,
		anonymous_record = true,
		fields           = members,
		name             = intern_identifier(c, anon_record_display(c, fields)),
		backend_label    = anon_record_label(c, fields),
		unlabelled       = unlabelled,
	})
	bucket_append(c, &c.anon_record_types, hash, id)
	return id
}

@(private = "file")
anon_record_display :: proc(c: ^Compiler, fields: []Anon_Member) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "(")
	for field, index in fields {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		// A positional field is spelled by its type alone.
		if text := identifier_text(c, field.name); !name_is_positional(text) {
			strings.write_string(&b, text)
			strings.write_string(&b, ": ")
		}
		strings.write_string(&b, type_name(c, field.type))
	}
	strings.write_string(&b, ")")
	return strings.to_string(b)
}

// The backend label. It is built from the structural sort key rather than the
// display name, so two packages' unrelated `Token` types cannot collide in a
// generated symbol merely because both print as `Token`.
@(private = "file")
anon_record_label :: proc(c: ^Compiler, fields: []Anon_Member) -> string {
	b := strings.builder_make(c.semantic_allocator)
	strings.write_string(&b, "anon")
	for field in fields {
		fmt.sbprintf(&b, ".%s.%s", identifier_text(c, field.name), typeid_sort_key(c, field.type))
	}
	return strings.to_string(b)
}

// Interns one anonymous union. It carries no attributes, so it has no zero and
// no failure variant, and it is never move-only on its own account.
anon_union_type :: proc(c: ^Compiler, variants: []Anon_Member) -> Type_Id {
	hash := anon_hash(variants)
	for candidate in c.anon_union_types[hash] {
		info := c.types[candidate]
		if len(info.variants) != len(variants) {
			continue
		}
		same := true
		for variant, index in variants {
			if info.variant_names[index] != variant.name || info.variants[index] != variant.type {
				same = false
				break
			}
		}
		if same {
			return candidate
		}
	}

	names := make([]Identifier_Id, len(variants), c.semantic_allocator)
	payloads := make([]Type_Id, len(variants), c.semantic_allocator)
	display := strings.builder_make(context.temp_allocator)
	label := strings.builder_make(c.semantic_allocator)
	strings.write_string(&display, "(")
	strings.write_string(&label, "anon_union")
	for variant, index in variants {
		names[index] = variant.name
		payloads[index] = variant.type
		if index > 0 {
			strings.write_string(&display, " | ")
		}
		fmt.sbprintf(&display, "%s:", identifier_text(c, variant.name))
		if variant.type != TYPE_VOID {
			fmt.sbprintf(&display, " %s", type_name(c, variant.type))
		}
		// The structural sort key, not the display name, as for records.
		payload_key := variant.type == TYPE_VOID ? "void" : typeid_sort_key(c, variant.type)
		fmt.sbprintf(&label, ".%s.%s", identifier_text(c, variant.name), payload_key)
	}
	strings.write_string(&display, ")")
	id := new_type(c, Type_Info {
		kind            = .Union,
		anonymous_union = true,
		variants        = payloads,
		variant_names   = names,
		name            = intern_identifier(c, strings.to_string(display)),
		backend_label   = strings.to_string(label),
	})
	bucket_append(c, &c.anon_union_types, hash, id)
	return id
}

// An interned type by shape, without creating one. The backend uses this where
// making a type mid-emission would grow the store it is walking.
lookup_type :: proc(c: ^Compiler, key: Type_Key) -> (Type_Id, bool) {
	id, ok := c.type_by_shape[key]
	return id, ok
}

// `^T` is a read-only borrow of one value and `^mut T` a mutable one. Both are
// one machine address with one LLVM type: the capability is static, so
// weakening a `^mut T` to a `^T` emits nothing (design.md "Capabilities and the
// one rule").
pointer_to :: proc(c: ^Compiler, element: Type_Id, mutable: bool) -> Type_Id {
	return intern_type(c, Type_Key{kind = .Pointer, element = element, mutable = mutable})
}

// The one backend type a struct-shaped carrier's two capabilities share.
// Mutability is static and leaves the ABI unchanged, so weakening is a no-op at
// the value level rather than a copy through a second shape.
carrier_abi_type :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil || !info.mutable {
		return under
	}
	#partial switch info.kind {
	case .Slice:
		readonly, found := lookup_type(c, Type_Key{kind = .Slice, element = info.element, mutable = false})
		assert(found, "a `[]mut T` was interned without the read-only variant it shares an ABI with")
		return readonly
	case .Dyn:
		return info.dyn_read_only
	}
	return under
}

// A mutable carrier implicitly weakens to a read-only one of the same shape; a
// read-only carrier never strengthens. Slices, pointers, and dyn views share
// this semantic rule and one representation per shape.
carrier_weakens_to :: proc(c: ^Compiler, from: Type_Id, to: Type_Id) -> bool {
	// Nominal, like `proc_type_weakens_to`: reaching through `distinct` would
	// make two unrelated distinct carriers interchangeable.
	from_info := type_of(c, from)
	to_info := type_of(c, to)
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
		return dyn_same_application(c, from_info, to_info)
	}
	return false
}

// `[^]T` is a C pointer to T value(s) (design.md "C pointers"), an
// address with neither a length nor a read-only capability.
c_pointer_to :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	return intern_type(c, Type_Key{kind = .C_Pointer, element = element})
}

// `Box(T)`: an owner of one allocated `T` (design.md "Owned values"). Its
// identity is its element, as for `[dynamic]T`; the allocator is a run-time
// property of the allocation, not of the type.
box_of :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	return intern_type(c, Type_Key{kind = .Box, element = element})
}

array_of :: proc(c: ^Compiler, element: Type_Id, count: u64) -> Type_Id {
	return intern_type(c, Type_Key{kind = .Array, element = element, count = count})
}

// design.md "SIMD vectors": `Simd(T, N)`. The element and lane count are the
// whole identity, exactly as for an array — the difference is layout, the
// operator set, and that it is not a sequence.
simd_of :: proc(c: ^Compiler, element: Type_Id, count: u64) -> Type_Id {
	return intern_type(c, Type_Key{kind = .Simd, element = element, count = count})
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
	symbol, _ := lookup_symbol_with_scope(scope, name)
	return symbol
}

lookup_symbol_with_scope :: proc(scope: ^Scope, name: Identifier_Id) -> (Symbol_Id, ^Scope) {
	for current := scope; current != nil; current = current.parent {
		if symbol, ok := current.names[name]; ok {
			current.reached = true
			return symbol, current
		}
	}
	return INVALID_SYMBOL, nil
}

new_package :: proc(c: ^Compiler, name: string, key := "") -> Package_Id {
	init_semantic_stores(c)
	id := Package_Id(len(c.packages))
	append(&c.packages, new_clone(Package {
		id             = id,
		name           = intern_identifier(c, name),
		key            = key,
		files          = make([dynamic]^File, 0, 4, c.semantic_allocator),
		extensions     = make(map[Type_Id][]Symbol_Id, c.semantic_allocator),
		operators      = make(map[string][dynamic]Symbol_Id, c.semantic_allocator),
		imports        = make([dynamic]Package_Import, 0, 4, c.semantic_allocator),
		hoisted_procs  = make([dynamic]^Expr_Proc, 0, 4, c.semantic_allocator),
		instances      = make([dynamic]Instance_Decl, 0, 4, c.semantic_allocator),
	}, c.semantic_allocator))
	return id
}

package_of :: proc(c: ^Compiler, id: Package_Id) -> ^Package {
	index := int(id)
	if index <= 0 || index >= len(c.packages) {
		return nil
	}
	return c.packages[index]
}

add_package_file :: proc(c: ^Compiler, package_id: Package_Id, file: ^File) {
	append(&package_of(c, package_id).files, file)
}

destroy_compilation :: proc(c: ^Compiler) {
	context.allocator = c.semantic_allocator if c.package_cache != nil else context.allocator
	// Batch parsing owns file objects and their syntax arenas. Incremental file
	// objects/syntax share semantic storage; destroy_ast is then a no-op.
	// Hand-built tests continue to own their stack-local ASTs themselves.
	for file in c.parsed_files {
		if file != nil {
			destroy_ast(file)
			free(file)
		}
	}
	delete(c.parsed_files)

	release_held_diagnostics(c)
	delete(c.held_diagnostics)
	for &diagnostic in c.diagnostics {
		destroy_diagnostic(c, &diagnostic)
	}
	delete(c.diagnostics)
	for &source in c.sources {
		delete(source.line_starts)
		delete(source.comments)
		if source.owned_text != nil {
			delete(source.owned_text)
		}
	}
	delete(c.sources)

	if c.semantic_initialized {
		virtual.arena_destroy(&c.semantic_arena)
		destroy_analysis_arenas(c)
	}
	// Last: diagnostics raised while emitting may live in it.
	virtual.arena_destroy(&c.emission_arena)
	c^ = {}
}
