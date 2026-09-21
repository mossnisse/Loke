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

TYPE_STRING   :: Type_Id(22)
TYPE_TYPEID   :: Type_Id(23)
TYPE_ANY_VIEW :: Type_Id(24)

TYPE_UNTYPED_INT   :: Type_Id(25)
TYPE_UNTYPED_FLOAT :: Type_Id(26)
TYPE_UNTYPED_BOOL  :: Type_Id(27)
TYPE_UNTYPED_RUNE  :: Type_Id(28)
TYPE_UNTYPED_NIL   :: Type_Id(29)
// A compile-time string; where a value is wanted it defaults to `string`.
TYPE_UNTYPED_STRING :: Type_Id(30)

// design.md "string type conversions": a borrowed view over UTF-8 text that
// owns and terminates nothing.
TYPE_STRING_VIEW :: Type_Id(31)

// design.md "Allocators" and "Allocation failure". `core:mem` and `base:runtime`
// export these identities rather than declaring their own, since the fixed
// lifecycle signatures spell them unqualified. `Allocator` is a one-word
// nominal handle; region identity lives in `src/borrow.odin`, not in the ABI.
TYPE_ALLOCATOR :: Type_Id(32)
TYPE_ALLOCATOR_ERROR :: Type_Id(33)

// design.md "C string views": a non-owning, zero-terminated byte view, and
// deliberately not a promise of UTF-8.
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

// A member set the compiler installs on a type rather than the user writing it.
Contribution :: enum u8 {
	Mutable_Iteration,
	Iteration,
	Lifecycle,
	// The compiler-owned canonical receiver members: `len`, `cap`, and `hash` on
	// the built-in types that provide them.
	Standard_Customization,
	// design.md "Dynamic arrays" and "Maps": the operation set that makes
	// `xs.append(1)` an ordinary method call.
	Container,
	// The constructors and handle of a local region provider (`src/region.odin`).
	Provider,
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
	// A validated `union @(align=N)` or `struct @(align=N)`, or 0. Kept apart from
	// `align`, which the layout pass overwrites with the computed result —
	// `union_layout` is asked again by the emitter after that, and both must agree.
	written_align: u64,
	// design.md "@(packed)": no inter-field padding, natural alignment 1 (an
	// `@(align=N)` may still raise it).
	packed:        bool,
	// `move_only struct` suppresses the generated ownership-copy operations.
	// This bit records an explicit leaf declaration; containing records inherit
	// it through lifecycle classification.
	move_only:     bool,
	// Inherent members written by `impl`. `extend` never writes here — its
	// members are package-scoped and live in `Package.extensions`.
	members:    []Symbol_Id,
	// Which contributed member sets are installed. Several contributors append
	// here, so "already has members" can't be the idempotence guard: whichever
	// ran first would suppress the other.
	contributed: bit_set[Contribution],
	parameters: []Type_Id,
	param_modes: []Param_Mode,
	// design.md "Procedure type": the reset effect and the escape levels are part
	// of procedure type identity — an indirect call must not launder a promise
	// through a type that hides it. Nil means every parameter is at the default.
	param_resets: []bool,
	param_escapes: []Escape_Level,
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
	convention: string,
	// Set once the finite-size check has visited this nominal type, so a cycle
	// is reported at one place instead of once per reference.
	size_state: Size_State,
	// A monomorphized instance: the template it came from and the arguments that
	// produced it. Structural specialization matches against these.
	instance_of:   Symbol_Id,
	instance_args: []Generic_Arg,
	// The backend spelling of an instance, kept apart from `name`, which is the
	// readable `Table(int, i32)` diagnostics use.
	mangled:       string,
	// A `dyn Interface(args...)` type: the interface it erases behind, and the
	// non-subject arguments of the application.
	dyn_interface: Symbol_Id,
	dyn_args:      []Generic_Arg,
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

// Sticky: `Unknown` is never left, because the pass asks about the whole body
// rather than one path through it (`nil_uses.odin`).
Nil_Writes :: enum u8 {
	None,
	Nil_Only,
	Unknown,
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
	// design.md "Compile-time built-ins": `static_assert` forces the compile-time
	// phase plain `assert` inherits from its caller, `build_config` reads a
	// `-define` key, and the location forms fold to a `Source_Code_Location`.
	Static_Assert,
	Build_Config,
	Source_Location,
	Caller_Location,
	Size_Of,
	Align_Of,
	Offset_Of,
	// design.md "Built-in procedures": whether a copy exists at all. No member can
	// answer it — a scalar is copyable and has no clone to name.
	Is_Copyable,
	// Compile-time reflection (design.md "`type` and `typeid`", "Compile-time
	// reflection").
	Type_Of,
	Typeid_Of,
	Fields_Of,
	Enum_Values_Of,
	// design.md "Allocators" and "Allocation failure": explicitly fallible, so
	// they always return an error and never invoke a failure policy. `free_all`
	// lowers to the provider's reset entry once provenance proves no dependant
	// survives it.
	New,
	New_Clone,
	Free,
	Free_All,
	// design.md "Dynamic arrays" and "Maps": its first operand is a *type*, which
	// no ordinary signature can spell.
	Make,
	// `mem.default_allocator()`. Compiler-owned and bound by `core:mem`, so a
	// generated default argument and a written call are one call.
	Default_Allocator,
	// design.md "Storage modifiers": a special form over a storage location, not
	// a keyword and not an ordinary procedure.
	Drop,
	// design.md "Exchange": no ordinary signature can express "moves both ways
	// with nothing observable between".
	Exchange,
	// The `core:unsafe` surface (design.md "unsafe.raw_data procedure", "string
	// type conversions"), where losing bounds and borrow capability is visible
	// at the call site. Each takes an operand ordinary signatures can't spell.
	Unsafe_Raw_Data,
	Unsafe_String_View,
	Unsafe_C_String_View,
	// design.md "Storage modifiers": consumes an owning operand and runs no
	// cleanup for it or anything it owns.
	Unsafe_Forget,
	// design.md "Uninitialized capacity": the pair a container author needs to
	// move an element into and out of capacity, which `move` cannot name and
	// `exchange` cannot reach without a replacement the element may not have.
	Unsafe_Take,
	Unsafe_Write,
	// Releases an allocation whose root the compiler cannot see — one reached
	// through a `rawptr` field, a parameter, or foreign code.
	Unsafe_Free,
	// design.md "`unsafe.transmute`": its first argument is a *type*, and
	// reinterpretation is not a universally valid conversion.
	Unsafe_Transmute,
	// design.md "SIMD vectors": the `core:simd` operations a constant lane index
	// makes unwritable as a loop. `Simd_Reduce` takes the fold as a constant
	// parameter, exactly as an atomic takes its ordering.
	Simd_Cast,
	Simd_Select,
	Simd_Reduce,
	// design.md "`type` and `typeid`": a `typeid` is an ordinary scalar and can be
	// forged, so the lookup is checked rather than an unchecked index.
	Type_Info_Of,
	// design.md "String format printing": the compiler-owned half of `core:fmt`.
	Fmt_Stdout_Writer,
	Fmt_Stderr_Writer,
	Fmt_Write_Bytes,
	Fmt_Format_Any,
	// `core:slice`'s typed comparator bridge to the shared runtime introsort. The
	// comparator pointer is used synchronously and never retained.
	Slice_Sort_By,
	// Contributed package-privately to `core:strings` (published as
	// `copy`/`try_copy`) and to `core:fmt`, which can't import `core:strings`
	// for `to_string` without pulling in the whole package.
	Strings_Allocate,
	// design.md "Concurrency and the memory model": the atomic intrinsics
	// `Atomic(T)` wraps, contributed package-privately to `core:sync`. Each
	// requires a constant ordering, which no ordinary signature can ask for.
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

// What a non-owning binding views. `.None` is an ordinary owning binding.
Borrowed_Binding :: enum u8 {
	None,
	Switch_Payload,
	Loop_Element,
}

Symbol :: struct {
	name:        Identifier_Id,
	span:        Span,
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
	// Whether every value this local has been given is `nil`, which is what lets
	// a use of it be reported rather than trapped (`nil_uses.odin`).
	nil_writes:  Nil_Writes,
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
	// Expression-position procedures have no declaration wrapper; keeping their
	// syntax here lets the evaluator run the same body the backend emits.
	proc_literal: ^Expr_Proc,
	pkg:         Package_Id,
	// The package whose method, operator, and extension tables this body may use
	// — not always the one being checked: `delegate` freezes it at its
	// declaration, and instantiations look up at their definition site.
	lookup_pkg:  Package_Id,
	// The `impl`/`extend` subject this member belongs to, or INVALID_TYPE.
	owner_type:  Type_Id,
	// `generic` marks a template, which has no signature until instantiated.
	// `def_scope` is the declaration's own lexical scope, what definition-site
	// lookup hangs an instantiation off instead of the caller's.
	generic:       bool,
	instance_of:   Symbol_Id,
	def_scope:     ^Scope,
	def_file:      u32,
	def_file_node: ^File,
	// A first parameter named `self` whose type is the owner. `^T` is not a
	// receiver and gets no method-call sugar.
	has_receiver: bool,
	receiver:     Param_Mode,
	// A closed compiler-controlled semantic role; operators use `operator` below.
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
	// `delegate_target` is INVALID_SYMBOL when that operation is the built-in.
	delegated:           bool,
	delegate_underlying: Type_Id,
	delegate_target:     Symbol_Id,
	iteration_target:    Symbol_Id,
	// Signature resolution already reported why this procedure has no usable
	// type, so the gate must not report a second time for the same mistake.
	signature_error: bool,
	// design.md "where clauses": the bound of an instantiated generic `impl` does
	// not hold, so the method is not part of that instantiation. The symbol stays
	// only so a call can say why it is missing.
	bound_excluded: bool,
	// A procedure the compiler contributes: it has a real symbol and signature,
	// and the backend writes its body (`src/iterate.odin`).
	synth:       Synth_Kind,
	// Field or enum-member position in its owning type; parameter position in
	// its signature.
	index:       u32,
	// design.md "Uninitialized capacity": `@(initialized = count)` names the
	// sibling field holding how many leading elements are live. The generated
	// copy and drop visit that prefix only.
	initialized_by: Symbol_Id,
	mode:        Param_Mode,
	// The declaring procedure literal, for the capture check in step 6.
	owner_proc:  rawptr,
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
	// design.md `@(escape=...)`: what a call may leave behind that depends on
	// this parameter. `.Result` unless written otherwise.
	escape:          Escape_Level,
	// design.md "Managed values and storage": an implicit `defer drop(value)` at
	// the declaration point. `src/lifecycle.odin` decides from the CFG whether
	// scope exit drops this local, and whether that is the same on every path —
	// a definite state needs no runtime flag.
	drop_at_exit:     bool,
	drop_conditional: bool,
	cleanup_slot:     int,
	// design.md "Allocators": the written `via` expression, or nil for the lazy
	// default. Kept on the *declaration* because it survives drop and move and is
	// what a later revival selects; a live value carries its own handle.
	via:              Expr,
	// design.md "Storage modifiers": `static` or `thread_local` makes a *local*
	// declaration name storage outside the frame, so the backend gives it a
	// global rather than an `alloca`.
	duration:         Duration,
	// Which `LOKE_*` enum this predeclared constant belongs to, or `.None`.
	build_config_enum: Build_Config_Enum,
	// design.md "`@(deprecated=<string>)`": the warning message printed at each
	// use of this procedure, or "" if it is not deprecated.
	deprecated_message: string,
	deprecated:         bool,
	// design.md "@(require_results)": each call must use or explicitly discard the
	// results. Applied to a procedure group after overload selection.
	require_results:    bool,
	// design.md "Foreign system": no body, so the backend emits a
	// `declare`/`external global` under `link_name`. The source library isn't
	// recorded — every foreign block links against the one image.
	is_foreign:         bool,
	link_name:          string,
	// design.md "Promoted struct fields": a `using` field, whose own fields its
	// record's selectors also reach.
	is_using:           bool,
	// design.md "@(export)": emit under `link_name` rather than the mangled
	// `@loke.p...`, so a C consumer can link to it.
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
	// same-named packages cannot collide. The root package's key is "".
	key:            string,
	files:          [dynamic]^File,
	scope:          ^Scope,
	// `extend` members, keyed by subject type. Package-scoped by design: an
	// unused import must not make an existing expression ambiguous, so this is
	// never merged into the type itself.
	extensions:     map[Type_Id][]Symbol_Id,
	operators:      map[string]^[dynamic]Symbol_Id,
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
}

init_semantic_stores :: proc(c: ^Compiler) {
	if c.semantic_initialized {
		return
	}
	c.semantic_initialized = true
	c.target = WINDOWS_X64
	// A growing virtual arena, not `mem.Dynamic_Arena`: the latter rejects any
	// allocation over its block size with `.Invalid_Argument`, which
	// `append`/`make` swallow — the symbol store crossing that threshold kept its
	// old length while `new_symbol` handed out IDs for elements never stored.
	if err := virtual.arena_init_growing(&c.semantic_arena); err != nil {
		panic("cannot reserve the compilation's semantic arena")
	}
	c.semantic_allocator = virtual.arena_allocator(&c.semantic_arena)
	if err := virtual.arena_init_growing(&c.analysis_arena); err != nil {
		panic("cannot reserve the compilation's analysis arena")
	}
	c.analysis_allocator = virtual.arena_allocator(&c.analysis_arena)
	c.collections = make(map[string]string, c.semantic_allocator)
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
	c.view_types = make(map[View_Key]Type_Id, c.semantic_allocator)
	c.adapter_members = make(map[Adapter_Key]Symbol_Id, c.semantic_allocator)
	c.item_states = make(map[Item_Key]Item_State, c.semantic_allocator)
	c.carrier_reach = make(map[Type_Id]Carrier_Reach, c.semantic_allocator)
	c.carrier_shapes = make(map[Type_Id][]Carrier_Path, c.semantic_allocator)
	c.synth_procs = make([dynamic]Symbol_Id, 0, 8, c.semantic_allocator)
	c.dyn_types = make(map[string]Type_Id, c.semantic_allocator)
	c.witnesses = make(map[string]^Witness, c.semantic_allocator)
	c.witness_order = make([dynamic]^Witness, 0, 4, c.semantic_allocator)
	c.witness_names = make(map[string]bool, c.semantic_allocator)
	c.materialized = make(map[Symbol_Id]^Materialized, c.semantic_allocator)
	c.materialized_order = make([dynamic]^Materialized, 0, 4, c.semantic_allocator)
	c.lifecycles = make(map[Type_Id]^Lifecycle, c.semantic_allocator)
	c.validated_attributes = make(map[u64]bool, c.semantic_allocator)
	c.lifecycle_operations = make(map[Type_Id]Lifecycle_Operations, c.semantic_allocator)
	c.runtime_types = make(map[string]Type_Id, c.semantic_allocator)
	c.formatters = make(map[Type_Id]Symbol_Id, c.semantic_allocator)
	c.result_summary_dependencies = make(map[Symbol_Id][]Symbol_Id, c.semantic_allocator)
	c.reset_dead = make(map[^Expr_Call][]Symbol_Id, c.semantic_allocator)
	c.cleanup_reset_dead = make(map[Cleanup_Reset_Key][]Symbol_Id, c.semantic_allocator)
	c.package_by_dir = make(map[string]Package_Id, c.semantic_allocator)
	c.map_keyed = make(map[Type_Id]bool, c.semantic_allocator)
	c.checked_bodies = make([dynamic]Checked_Body, 0, 16, c.semantic_allocator)
	c.result_summaries = make(map[Symbol_Id]^Proc_Summary, c.semantic_allocator)
	c.proc_contract_checks = make([dynamic]Proc_Contract_Check, 0, 4, c.semantic_allocator)
	c.static_locals = make([dynamic]Symbol_Id, 0, 4, c.semantic_allocator)

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
	proc_contract := INVALID_SYMBOL,
) -> Type_Id {
	init_semantic_stores(c)
	for &info, index in c.types {
		if info.kind == .Proc &&
		   info.convention == convention &&
		   equal_type_ids(info.parameters, parameters) &&
		   equal_param_modes(info.param_modes, param_modes) &&
		   info.result == result &&
		   info.result_inout == result_inout &&
		   equal_reset_effects(info.param_resets, param_resets) &&
		   equal_reset_effects(info.param_by_ptr, param_by_ptr) &&
		   equal_escape_levels(info.param_escapes, param_escapes) &&
		   info.proc_contract == proc_contract &&
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
		proc_contract = proc_contract,
		param_by_ptr  = by_ptr_copy,
		c_vararg      = c_vararg,
		result        = result,
		result_inout  = result_inout,
		convention    = convention,
	})
}

// A level vector is only stored when something in it is not the default, so an
// unannotated signature interns exactly the type it always did.
@(private = "file")
has_escape_level :: proc(levels: []Escape_Level) -> bool {
	for level in levels {
		if level != .Result {
			return true
		}
	}
	return false
}

@(private = "file")
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

proc_parameter_mode :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> Param_Mode {
	info := underlying_info(c, proc_type)
	return info != nil && index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
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
	if b.proc_contract != INVALID_SYMBOL && a.proc_contract == INVALID_SYMBOL {
		return false
	}
	return true
}

@(private = "file")
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
	// Both names first: `type_of` points into `c.types`, so anything that
	// appended a type while the pointer was live would dangle it.
	display := intern_identifier(c, anon_record_display(c, fields))
	mangled := anon_record_mangled(c, fields)
	if info := type_of(c, id); info != nil {
		info.fields = members
		info.name = display
		info.mangled = mangled
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
			&b, ".%s.%s", llvm_safe(identifier_text(c, field.name), allocator = context.temp_allocator),
			llvm_safe(typeid_sort_key(c, field.type), allocator = context.temp_allocator),
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
	// Nominal, like `proc_escape_weakens_to`: reaching through `distinct` would
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
	info := underlying_info(c, id)
	if info == nil {
		return 0
	}
	return info.kind == .Enum ? type_bits(c, info.element) : int(info.bits)
}

type_signed :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	if info == nil {
		return false
	}
	return info.kind == .Enum ? type_signed(c, info.element) : info.signed
}

// A distinct type is a fresh identity but keeps the *shape* of what it wraps,
// which is what layout, folding, and lowering need.
type_underlying :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	current := id
	// A valid chain cannot visit more types than the compilation owns, which
	// bounds the walk without an arbitrary nesting limit. An invalid cycle
	// returns a member of itself; the finite-size pass diagnoses it.
	for _ in 0 ..< len(c.types) + 1 {
		info := type_of(c, current)
		if info == nil || info.kind != .Distinct || info.element == INVALID_TYPE {
			return current
		}
		current = info.element
	}
	return current
}

// A distinct type answers structural questions through what it wraps, so these
// two are the pairing almost every query wants.
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

// design.md: a slice or a dynamic interface value compares against `nil` and
// nothing else, so it is not a comparable leaf either. Kept apart from
// `type_is_comparable` because an aggregate reads that one to decide whether it
// may be compared field-wise, which these two may not.
type_compares_to_nil_only :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .Slice, .Dyn:
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

// Whether any component of this type never resolved. Told apart from
// "unsupported" so a milestone answer is not reported for a component that was
// already rejected where it was written.
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
	// Exhaustive on purpose: a new composed `Type_Kind` must not quietly answer
	// "no invalid part" the way a scalar correctly does.
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
		// Runtime carriers; their borrow provenance is checked by
		// `src/borrow.odin` rather than restricted here.
		return true
	case .Slice:
		return type_is_supported_depth(c, info.element, depth + 1)
	case .C_Pointer:
		// design.md "C pointers": a documented trust boundary, not an unsupported
		// type — no length, no capability, and no lifetime check after conversion.
		return type_is_supported_depth(c, info.element, depth + 1)
	case .Interface:
		return false
	case .Dynamic_Array:
		return type_is_supported_depth(c, info.element, depth + 1)
	case .Map:
		return type_is_supported_depth(c, info.key, depth + 1) &&
		       type_is_supported_depth(c, info.element, depth + 1)
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

// Indexed by `Type_Id`, so a new predeclared type is added here beside its
// constant instead of in a third switch that has to be kept in step.
// `TYPE_ALLOCATOR` and `TYPE_ALLOCATOR_ERROR` are deliberately absent: they
// print under the nominal name `core:mem` binds to them.
@(private = "file")
PREDECLARED_NAMES := [int(FIRST_DYNAMIC_TYPE)]string {
	INVALID_TYPE         = "<invalid>",
	TYPE_VOID            = "()",
	TYPE_BOOL            = "bool",
	TYPE_I8              = "i8",
	TYPE_I16             = "i16",
	TYPE_I32             = "i32",
	TYPE_I64             = "i64",
	TYPE_I128            = "i128",
	TYPE_U8              = "u8",
	TYPE_U16             = "u16",
	TYPE_U32             = "u32",
	TYPE_U64             = "u64",
	TYPE_U128            = "u128",
	TYPE_INT             = "int",
	TYPE_UINT            = "uint",
	TYPE_UINTPTR         = "uintptr",
	TYPE_F16             = "f16",
	TYPE_F32             = "f32",
	TYPE_F64             = "f64",
	TYPE_RUNE            = "rune",
	TYPE_RAWPTR          = "rawptr",
	TYPE_TYPE            = "type",
	TYPE_STRING          = "string",
	TYPE_TYPEID          = "typeid",
	TYPE_ANY_VIEW        = "any_view",
	TYPE_UNTYPED_INT     = "untyped int",
	TYPE_UNTYPED_FLOAT   = "untyped float",
	TYPE_UNTYPED_BOOL    = "untyped bool",
	TYPE_UNTYPED_RUNE    = "untyped rune",
	TYPE_UNTYPED_NIL     = "untyped nil",
	TYPE_UNTYPED_STRING  = "untyped string",
	TYPE_STRING_VIEW     = "string_view",
	TYPE_CSTRING_VIEW    = "cstring_view",
}

type_name :: proc(c: ^Compiler, id: Type_Id) -> string {
	if int(id) < len(PREDECLARED_NAMES) && PREDECLARED_NAMES[id] != "" {
		return PREDECLARED_NAMES[id]
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
		return fmt.aprintf("Simd(%s, %d)", type_name(c, info.element), info.count, allocator = c.semantic_allocator)
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
		// A parameter mode is part of the type, so two signatures differing only in
		// one must not print the same — a mismatch report naming the same text twice
		// explains nothing about why the argument was refused.
		if index < len(info.param_modes) {
			#partial switch info.param_modes[index] {
			case .Inout:  strings.write_string(&b, "inout ")
			case .Borrow: strings.write_string(&b, "borrow ")
			case .Move:   strings.write_string(&b, "move ")
			}
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
	if sym := symbol_of(c, info.proc_contract); sym != nil {
		fmt.sbprintf(&b, " [result contract: %s]", identifier_text(c, sym.name))
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
		operators      = make(map[string]^[dynamic]Symbol_Id, c.semantic_allocator),
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
		destroy_diagnostic(c, &diagnostic)
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
	// Last: diagnostics raised while emitting may live in it.
	virtual.arena_destroy(&c.emission_arena)
	c^ = {}
}
