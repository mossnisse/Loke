Loke is a private project to make a new programming language building on Odin.

It aims to add more high level language functionality and more possibilities for abstractions with good ergonomics and still have the possibilities to have low level access and control of the binary output similar to Odin and C.

It aims at making it easier to handle memory allocations and complex datatypes as strings and dynamic arrays, not making the language 100% memory safe as Rust.

Loke should be able to use compiled C libraries (C ABI) and have some compatibility C datatypes to make that work.

Procedures and that are called and packages that are improted should not change how the code works for the caller or importer in any unexpected ways. The opposite may be true. Having an parameter with an pointer to data that is manipulated is an nessary evil and is allowed.

Stuff like hidden allocations are allowed but procedures returning values that has to be manually hanndled should be clearly vissible that it is needed.

The normative language specification is in [design.md](design.md), and its grammar in [grammar.md](grammar.md). Open questions, differences from Odin, and non-normative design motivations are collected in [comments.md](comments.md).

## The compiler

`lokec` is written in Odin and lives in [src/](src). The build is decomposed in
[compiler-plan.md](compiler-plan.md); the current milestone is M7, planned in
[m7-plan.md](m7-plan.md), after M6b in
[m6b-plan.md](m6b-plan.md), M6a in [m6a-plan.md](m6a-plan.md), M5b in
[m5b-plan.md](m5b-plan.md), M5a in
[m5a-plan.md](m5a-plan.md), M4b in [m4b-plan.md](m4b-plan.md), M4a in
[m4a-plan.md](m4a-plan.md), M3 in
[m3-plan.md](m3-plan.md), M2 in [m2-plan.md](m2-plan.md), M1 in
[m1-plan.md](m1-plan.md) and M0 in [m0-plan.md](m0-plan.md).

M1 completed the front end: every construct in [grammar.md](grammar.md) lexes and
parses, so `-parse-only` and `-dump-ast` accept any valid program.

M2 compiles the static, non-generic, non-managed core of the language to a
Windows executable:

- every scalar type — `bool`, `i8`–`i128`, `u8`–`u128`, `int`, `uint`,
  `uintptr`, `byte`, `f16`/`f32`/`f64`, `rune`, `rawptr` — with exact
  arbitrary-precision constant folding, so `u128`'s maximum and `i128`'s minimum
  are ordinary constants;
- `struct`, `enum`, `[N]T`, `^T`, `distinct`, procedure types, and type aliases,
  including aggregate constants and recursive structural equality;
- every built-in operator, conversions `T(v)`, `x if c else y`, indexing, field
  selection, `&`/`^`, and composite literals;
- assignment in all its forms, `if`/`for`/`switch`, `break`, `continue`,
  `defer`, and `return`;
- procedures with value and `inout` parameters, defaults, named arguments,
  multiple and named results, recursion, and procedure values.

M3 adds the compile-time engine and packages:

- one tree-walking interpreter over the typed AST, with frames, locals,
  mutation, loops, `defer`, recursion, and `inout` aliases, so an ordinary
  procedure can supply a constant, an array length, or an enum value — and the
  same procedure still compiles for run time;
- `assert` and `panic` in either phase: diagnosed with the compile-time call
  stack when evaluation reaches them, lowered to the runtime trap seam
  otherwise;
- natural target layout, with `size_of`, `align_of`, `offset_of`, and fixed-array
  `len` folded to `int`. Their operands are inspected, never evaluated;
- untyped compile-time strings — joined, compared, and measured — plus
  `#assert(condition[, message])`, `#config(NAME, default)`, and
  `-define:NAME=VALUE`;
- `when` at file and procedure scope, as structural source selection: an
  unselected branch is parsed and nothing else;
- directory packages, multi-file packages, relative and `collection:` imports,
  the import DAG with cycles reported as a path of import statements,
  `@(public)`/`@(private)` visibility, and one LLVM module emitted in dependency
  order with package-qualified symbol names.

Evaluation is bounded: 1,000,000 steps, 256 explicit frames, and 64 MiB of
scratch memory. Exceeding one is a diagnostic, never a silent fallback to
generating runtime code. Reading a mutable file-scope variable, printing,
or letting a pointer escape is rejected on an executed path.

M4a makes user-defined types as capable as built-in ones at concrete types:

- one overload-resolution engine — viability filtering, per-argument conversion
  ranks, vector partial ordering, and the four tie-breakers — shared by named
  procedure groups, methods, operators, `init`, and indexing. An ambiguity lists
  every maximal candidate, its conversion vector, and the tie-breaker where
  selection failed;
- `proc{...}` groups, `impl` and `extend` blocks, the three receiver forms,
  associated constants and types, `Type.member` access, and field lookup taking
  priority over method-call sugar. An `extend` block changes lookup only inside
  its own package;
- `init` overloads with the two-stage `T(...)` resolution — a built-in or
  `distinct` conversion first, `init` overloads otherwise — and `@(implicit)`
  one-argument conversions reachable only from an untyped constant;
- `operator(sym)` declarations and groups, the `!=` and compound-assignment
  fallbacks, `operator([])`/`([]=)`/`([:])` with place-position selection, and
  `delegate(...)` on `distinct` types. A built-in operation on built-in operands
  cannot be shadowed: `int + int` keeps its meaning in every file;
- `union` with a tagged representation, `@(align=N)`, a nil zero value, `v.(T)`
  in both its trapping and comma-ok phases, the type switch with exhaustiveness
  reporting, and the error protocol — optional-ok results, `or_else`, and
  `or_return` with its named-result and definite-initialization rules.

M4b makes those abstractions generic and erasable, completing M4:

- `$` type and value parameters, inference, structural specialization
  (`[]$E`, `[$N]E`, `^Table($K, $V)`), generic records, unions, and `impl`/
  `extend` blocks, and `where` clauses evaluated per instantiation. Every
  distinct argument vector is monomorphized into its own instance with its own
  emitted symbol; a runaway recursive instantiation is a diagnostic carrying its
  instantiation stack;
- `interface` declarations with expression, validity, and `slot` requirements,
  composition, and associated types. An application such as `Additive(int)` is a
  compile-time boolean, and a failure names the requirement line and the concrete
  type that failed it. A named slot is matched only by an inherent method or an
  extension from the interface's own package, so a caller-local `extend` cannot
  make a requirement appear satisfied;
- the standard interface catalogue as ordinary Loke source in
  [base/interfaces](base/interfaces), reached with `-collection base=base`,
  `Cloneable` included: a record satisfies it through the `try_clone` its `impl`
  block writes or the field-wise one the compiler generates, and
  `try_clone :: ---` fails it;
- compile-time reflection: `fields_of`, `enum_values_of`, `field.get`,
  `field.pointer`, `type_of`, `typeid_of`, and static `foreach` expansion, which
  type-checks one copy of its body per element;
- `foreach` over integer ranges, fixed arrays, and user types through the
  `iter`/`next` protocol, with first-class `Range(T)` values that keep their
  half-open or closed kind after being stored or passed;
- erased views: `typeid` as a deterministic runtime identity, `any_view` with
  its position rules, assertions, and type switch, and `dyn Interface` with
  witness dispatch, dyn-compatibility diagnostics, and forwarding slots that let
  `dyn I` satisfy `I`.

M5a adds managed values — visibility, slices, and lifecycle:

- one package/public rule for reflection, ordinary field reads and writes,
  `offset_of`, and both named and positional aggregate construction, so no path
  can expose a field another path hides;
- slices, `[]T` and `[]mut T`, as a two-word borrowed view: literals with hidden
  backing storage, slicing and reslicing arrays and slices, nil, bounds,
  `len`, `foreach` including by reference over `[]mut T`, and the sequence and
  iteration members that let generic code accept one. A constant a runtime index
  or slice needs storage for materializes once into a shared read-only global,
  while a constant index still folds;
- lifecycle hooks: a record customizes `drop`, customizes or disables
  `try_clone`, and receives a generated recursive field-wise `try_clone` that
  cleans up a partially built temporary in reverse order, plus a `clone`
  generated from it;
- ownership as dataflow over a per-procedure control-flow view. Every managed
  local drops exactly once on fallthrough, `return`, `break`, and `continue`,
  interleaved with explicit `defer` in one reverse registration order; `move`,
  `drop`, and `exchange` are compiler special forms over a storage location;
  binding and assignment copy by cloning and drop what they replace; a `move`
  parameter or receiver transfers, and returning a borrowed managed owner
  clones. A hidden flag is emitted only where the analysis left a value
  conditionally live;
- storage modifiers: `manual` ownership, and `static` and `thread_local`
  duration with constant initialization, module-level storage, and thread-local
  teardown at normal return;
- `Allocator` and `Allocator_Error` as compiler-owned types, with `new`,
  `new_clone`, and `free` over the C runtime and explicit failure reporting;
- copy-cost warnings at the four copy sites, configurable with `-copy-cost=N`,
  which stay silent for a managed parameter borrow, a scalar, and a temporary.

M5b adds the two provenance analyses that consume those lifecycle facts. They
share one control-flow view and one event stream, but answer different questions
and fail with different diagnostics:

- root provenance follows every borrow carrier — `^T`, `[]T`, `[]mut T`,
  `any_view`, `dyn`, and parameter access — from its creation to the last use of
  any copy, across branches and through an overwrite that ends only the value
  that was overwritten. A place is a root plus a normalized projection path, so
  distinct struct fields and provably distinct constant ranges carry independent
  loans while dynamic indices, union subjects, opaque dereferences and
  user-defined addressing overlap conservatively. Reading, writing, moving,
  dropping, freeing, assigning, exchanging, or calling an `inout self` operation
  on a borrowed root is rejected with the root, the borrow's creation, the
  conflicting operation, and the later use that keeps it live;
- temporaries get the lifetimes design.md gives them — the complete expression,
  or the complete statement inside a control-flow header — and a borrow of a
  local, a temporary, a slice literal, or a parameter binding cannot be returned,
  while a static, materialized or freshly allocated root can;
- result-provenance summaries record, per result, which borrowed parameters,
  static storage, or fresh allocation it may name. They are collected by
  rebuilding each body read-only and solving to a whole-program fixed point, so
  forward and mutually recursive declarations settle identically whatever the
  source order, and a direct call — across a package or a generic instance —
  substitutes its own arguments. A call through a procedure value has no summary,
  so its result derives from every borrowed argument and loses fresh-allocation
  identity;
- `free` takes any pointer whose provenance proves it is an allocation base,
  consumes it, and rejects every alias that survives;
- region provenance gives allocator values a region identity, propagates it into
  allocation roots and owning results constructed with an allocator argument,
  rejects such an owner stored in longer-lived static storage, verifies
  `@(allocator_reset)` transitively, and carries the effect in the procedure type
  so an indirect call keeps it. `free_all` is accepted when nothing survives the
  reset — not when everything was already freed — and lowers to the provider's
  reset entry.

design.md's [What is not checked](design.md#what-is-not-checked) list is the
deliberate boundary and stays that way: a borrow stored in a global, a record
field, or callback state, a retained argument, `rawptr`/`[^]T`/unknown `^T`,
`core:unsafe`, and cross-thread transfer are the programmer's responsibility, and
each keeps a fixture proving it still compiles.

M6a begins the runtime. A versioned C seed — allocation, failure, panic frames,
text, and scalar formatting — is compiled beside the generated LLVM and found
next to the compiler unless `-runtime=<dir>` replaces it:

- an `Allocator` is one pointer to one `loke_rt_allocator_v1` record carrying
  provider state, canonical region identity, the four callbacks, and a
  `.Panic`/`.Trap` failure policy. Copying the handle preserves region identity,
  and `mem.default_allocator()` names the system-heap provider that `new`,
  `new_clone`, `free`, `free_all`, and every generated clone route through;
- `base:` and `core:` are implicit roots beside the compiler that an explicit
  `-collection` entry replaces rather than collides with, so `base:runtime`,
  `base:meta`, `core:mem`, `core:fmt`, `core:os`, and `core:unsafe` import with
  no flags. `core:os` is ordinary Loke source over a foreign block, which is the
  proof that the foreign system works: the executable's C entry is `wmain`, so
  the runtime converts the UTF-16 argument vector to cached UTF-8 once before the
  initial thread attaches, and `os.args` is a read rather than a conversion;
- every defined runtime fault is a classified panic instead of one trap.
  `-panic=unwind` registers a logical frame per procedure with cleanup and
  replays each active frame's live cleanup newest-first before terminating;
  `-panic=abort` registers none; a panic raised while unwinding aborts at once;
  and an allocator's `.Trap` policy bypasses both. Normal thread detach drops
  managed thread-local storage, and a panic does not;
- `string` is an immutable owning UTF-8 value over shared, atomically counted
  storage; a literal is a constant over static zero-terminated bytes; assignment
  shares and only `clone` copies. `string_view` and `cstring_view` borrow, and
  the same M5b analysis that follows slices follows them. Byte and rune
  operations, subranges, concatenation, comparison, rune iteration with byte
  offsets, and the validating conversions with optional-ok results are all
  available, as are `[^]T` and the `core:unsafe` surface;
- `..T` packs any mix of explicit arguments and `..slice` spreads into one
  read-only slice, forwards a sole compatible spread untouched, and takes part in
  overload ranking with the fixed-over-variadic tie-breaker intact. The
  call-scoped `..any_view` carries mixed types without letting the slice or an
  element escape;
- `type_info_of` maps every live `typeid` to stable `runtime.Type_Info` metadata
  and returns nil for the zero id and for a forged one, and
  `#location`/`#caller_location` produce constant `runtime.Source_Code_Location`
  values;
- formatting is coherent per concrete `typeid`: the compiler generates one
  formatter per printable type, a package may write `format` for a type it owns,
  and `core:fmt`'s `print`/`println`/`eprint`/`eprintln` dispatch through that
  one table. A program that wants the sink itself takes `fmt.stdout()` or
  `fmt.stderr()` and writes with `fmt.format_to`.

- `[dynamic]T` and `map[K]V` are complete four-word managed values. The all-zero
  header is empty, allocator-unbound and constant, so a file-scope, `static` or
  `thread_local` container needs no code before `main`; `make` binds a container
  to a selected allocator even when the result is empty; a `T via provider`
  declaration chooses the allocator its destination is built with, and is
  rejected on a value with no destination allocation to select; and copy, move,
  `drop`, `exchange`, revival and panic cleanup are exact through the versioned
  container helpers and one generated operation table per concrete type;
- a dynamic array runs its whole operation set. Literals, `make`, indexing and
  indexed assignment, slicing, `len` and `cap`, and `append` (values, `..slice`
  spreads, or both), `insert`, `pop`, `remove`, `remove_unordered`, `clear`,
  `resize`, `reserve` and `shrink` — each with a `try_` form that returns the
  error instead of applying the allocator's failure policy. The operations are
  contributed *members*, so `xs.append(1)` is an ordinary method call and generic
  code finds the same ones. A failed allocation or element clone leaves the
  container bit-for-bit unchanged, and every view and element pointer it hands
  out ends at the first operation that may move its storage.

- a map is an open-addressed table with an opaque per-table seed, so iteration
  order is unspecified by construction. Literals, a read of `m[key]` that never
  inserts, the comma-ok form, `key in m`, an inserting place through field and
  index chains (`m["Dana"].x = 7` inserts a zero and assigns), the non-inserting
  `m.find(key)`, `try_insert`, `remove`, `clear`, `reserve` and `shrink` all
  run. A key needs a **coherent** `==` and `hash` pair that is either built in or
  inherent to the key's own package: a caller-local `extend` never enters the
  frozen operation table, so one map keeps one policy in every package it travels
  through.

- both containers iterate. A dynamic array yields value-and-index like a slice
  and `&value` names the element in place; a map is design.md's two-name
  exception, where the first of two names is the key, not a counter — a key
  binding borrows the stored key rather than copying it, and `&key` is rejected
  because map keys are immutable. Both contribute the same
  `Element`/`Iterator`/`iter`/`next` members a user type declares by hand, so
  generic code sees exactly what direct iteration does. A loop holds a
  whole-container loan for its entire duration *including across the back edge*,
  so a write, a growth or an end of what it walks is rejected from inside the
  body even when only the next iteration would see it;

- both format recursively through the coherent formatter table (`[1, 2, 3]`,
  `[key = value]`), `st.to_runes()` builds a `[dynamic]rune` whose capacity is
  the exact rune count and which releases its partial buffer if the allocation
  fails, and `unsafe.raw_data([dynamic]E)` hands back the current data pointer
  with no length, no capability and no further lifetime checking.

- `mem.Arena` and `mem.Scratch` are local allocator regions. The control block
  is address-stable, so moving the owner never changes its record address or its
  region identity — a provider is move-only for the same reason. An `Arena` may
  be laid over a caller's fixed buffer (`mem.Arena(buffer[:])`), which puts a
  dynamic array's backing storage in the current frame and makes the arena a
  borrow of that buffer for as long as it lives. The provider-backed
  `mem.Arena(parent)` and `mem.Scratch(parent)` forms default their parent to
  `mem.default_allocator()`; `mem.try_arena` and `mem.try_scratch` report parent
  allocation failure explicitly. A child provider keeps its parent region live.
  `free_all` on a region this body
  created needs no `@(allocator_reset)` promise and is *reusable*: the region
  works again afterwards. What it rejects is a surviving dependant — an owner
  backed by that region, or a borrow of one — and only of that region: two
  arenas are two regions. An owner cannot be returned from, or stored past, the
  region backing it, and a wrapper may return the provider owner but not a bare
  handle to it. "Surviving" is M5a's definite liveness rather than lexical scope,
  so an explicitly dropped owner stops blocking — while one dropped on only some
  paths keeps blocking, because it may still need its cleanup on the others.

- a compile-time procedure may use containers as temporaries. The evaluator runs
  the same operations the backend emits, from the same operation code, bounded by
  the same step and memory limits — and a container cannot escape into the
  generated program, because design.md gives it exactly one constant value, the
  empty one. What is deliberately unspecified at runtime is rejected rather than
  approximated: a map's iteration order, and a capacity, which is a property of an
  allocation that compile-time storage does not have.

M7 makes the output a release build and opens the C boundary in both
directions:

- `-opt=none|minimal|size|speed|aggressive` selects the optimization level on
  the one `clang` call that already consumed the generated IR. Behaviour is the
  claim, so the whole `tests/run` and `tests/trap` corpus runs at every level and
  must produce identical output. `LOKE_ARCH`, `LOKE_OS`, `LOKE_ENDIAN`,
  `LOKE_BUILD_MODE`, `LOKE_DEBUG`, `LOKE_OPTIMIZATION_MODE`, `LOKE_VENDOR` and
  `LOKE_VERSION` are predeclared, so `when (LOKE_OS == .Windows)` needs no
  import;
- every attribute design.md defines is either implemented or diagnosed. One
  table maps each to the positions it may appear in and the value it takes, so a
  typo, an unknown namespace, a misplaced attribute, a duplicate and a wrong
  value shape are each their own error rather than silence;
- `@(packed)` and `@(align=N)` lay a record out byte-exactly, and `size_of`,
  `align_of`, `offset_of` and runtime type info all agree with what LLVM
  computes. Alignment is tracked per place, so a nested access through a packed
  value stays unaligned and `&packed.field` is rejected while the whole value's
  address stays valid;
- `proc "c"` and `proc "stdcall"` use the Windows x64 C classification, verified
  against clang rather than derived: a 1-, 2-, 4- or 8-byte aggregate in one
  integer register, every other one behind a pointer, `sret` for a large result,
  and `_Bool` as `i1 zeroext` with byte-sized storage. The `loke` convention is
  untouched, because its lowering has no external partner to agree with;
- `foreign import` and `foreign` blocks declare C procedures and globals.
  Members are ordinary package symbols, so visibility, overloads and calls need
  no special path; `@(link_name)` renames, `@(default_calling_convention)` sets
  the block default, `@(by_ptr)` passes a pointer, and `@(c_vararg)` emits a real
  varargs call with the C default promotions. Libraries, `system:` names and
  `nasm`-assembled `.asm` inputs join the link, and a missing file, a missing
  assembler and an unresolved link name are three different diagnostics;
- `@(export)` emits a procedure or global under its own symbol for a C consumer,
  with whole-program collision checking that names both declarations, and
  `-build-mode=obj` produces one relocatable object with no entry, whose runtime
  and foreign references its C host supplies at the final link.

Requires Odin and LLVM (`winget install LLVM.LLVM`); `clang` is found through
`LOKE_CLANG`, the standard Windows LLVM installation, or `PATH`.

```
odin build src -out:lokec.exe
lokec.exe examples/hello.loke -o hello.exe && hello.exe
lokec.exe tests/pkg/diamond -o diamond.exe          # a directory is one package
lokec.exe app -collection core=vendor/core -define:DEBUG=true
lokec.exe app -opt=speed -o app.exe                 # -O2 on the one clang call
lokec.exe tests/obj/lib.loke -build-mode=obj        # one object for a C host
lokec.exe tests/pkg/catalogue -collection base=base       # the interface catalogue
lokec.exe examples/hello.loke -parse-only
lokec.exe examples/hello.loke -dump-ast
lokec.exe tests/layout/types.loke -check-layout
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
```
