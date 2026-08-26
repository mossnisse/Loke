# M7 implementation plan — release builds and foreign interop

## Context

M6b is implemented. Every language construct design.md defines
now compiles and runs, over a versioned C runtime, through one textual-LLVM
path that ends in a single `clang` invocation. **M7** is the last v1 milestone:
it makes that output a *release* build, completes the layout and ABI surface
([B15](compiler-plan.md#b15-abi--layout)), and opens the boundary in both
directions — Loke calling C, and C calling Loke
([B16](compiler-plan.md#b16-llvm-backend-release),
[B17](compiler-plan.md#b17-linking--object-emission)).

The normative sections are [Foreign system](design.md#foreign-system),
[Foreign-ABI-safe types](design.md#foreign-abi-safe-types),
[Calling conventions](design.md#calling-conventions),
[Parameter semantics and ABI lowering](design.md#parameter-semantics-and-abi-lowering),
[Layout and ABI attributes](design.md#layout-and-abi-attributes),
[Attributes](design.md#attributes),
[Build configuration](design.md#build-configuration), and
[Program entry and exit](design.md#program-entry-and-exit).

Three facts about the current tree shape the plan. Foreign syntax parses but
reaches no semantic phase at all — a foreign block falls out of the top-level
dispatch into `L0350`, and its members are never collected as symbols. A
calling-convention spelling is already interned into the procedure type and
already governs type compatibility, but any procedure that carries one is
gated. And `src/layout.odin` says in its own header that it models the natural
layout only; `@(packed)` and the foreign ABI are M7's.

## Scope

### In M7

| Area | Contents |
|---|---|
| Release output | Optimization modes, `LOKE_*` build constants, `exe`/`obj` build modes, and a corpus that must agree at every optimization level |
| Attributes | One validation table over every attribute design.md defines, plus `@(deprecated)` and `@(require_results)` |
| Record layout | `@(packed)` with unaligned access and non-addressable fields, `@(align=N)` on structs, and `-check-layout` over both |
| Calling conventions | `"c"` and `"stdcall"` on procedure declarations, types, and values; the Windows x64 classification of parameters and results; `@(by_ptr)`; `@(c_vararg)` |
| Foreign-ABI safety | One predicate with per-type reasons, applied to foreign parameters, results, globals, exported declarations, and procedure-pointer compatibility |
| Foreign system | `foreign import` of libraries and assembly, foreign blocks of procedures and globals, `@(link_name)`, `@(default_calling_convention)`, and the linker arguments they produce |
| Export | `@(export)` on procedures and globals, symbol-collision checking, object output, and the documented foreign-thread attach/detach entry |
| `core:os` | `os.args` and `os.exit` as ordinary Loke source over a foreign block — the program model design.md's entry/exit section requires |

### Deferred after M7

MIR and the no-LLVM debug backend; debug builds and debug information
(PDB/DWARF); non-Windows
targets; incremental and parallel compilation; shared-library build mode;
extension attributes (`@(compiler.*)`, `@(link.*)`); and the standing v1 trust
boundaries.

### Moved to M8

Two blocks of design.md surface are deliberately not in M7 and belong to
[M8](compiler-plan.md#c-milestones):

- **`Simd(T, N)`.** A real vector type — lane-wise operators, scalar splat,
  whole-vector comparison, constant lane indexing, and a `core:simd` — is a
  self-contained addition that nothing in the language, runtime, or standard
  packages depends on. It is the only part of the ABI surface that can be
  dropped without leaving another feature half-built. The public `Type_Kind`
  already reserves its member, so adding it later still moves no runtime ABI
  version.
- **The library types.** `String_Builder`, `C_String`, `Small_Array(T, N)`,
  `Bit_Set`/`Enum_Array`, `Complex`/`Quaternion`, `Little_Endian`/`Big_Endian`,
  slice sorting, `Logger`/`core:log`, and
  `shared(T)`/`weak(T)`/`Atomic(T)`/`core:sync`. All but the last group are
  ordinary Loke source over facilities that already exist. The last group needs
  **compiler atomic intrinsics** the compiler does not have, which want their
  own memory-model fixtures rather than a corner of the ABI milestone.

Both are language-visible surface design.md specifies, so M7 completing leaves
v1 short of the whole document by exactly these two entries and no others.

## Decisions

| Area | Choice | Why |
|---|---|---|
| Two ABI worlds | The `loke` convention keeps LLVM's own first-class-aggregate lowering, unchanged. Only foreign conventions get a compiler-written Windows x64 classification. | design.md makes `loke`'s classification implementation-defined and requires only that every caller and callee compiled for the same target agree — which one LLVM and one triple already guarantee. A second classifier for `loke` would be work with no observable consequence; the C ABI is the only one with an external partner. |
| Win64 classification | An aggregate whose size is 1, 2, 4, or 8 bytes is passed in one integer register of that width, loaded from a byte-exact temporary. Every other aggregate is passed as a pointer to caller-owned temporary storage. A result follows the same size rule, with a hidden first pointer argument (`sret`) for every other size. Scalars, pointers, and `cstring_view` pass as themselves. A direct C `_Bool` parameter or result is LLVM `i1 zeroext`; its stored representation, including a record field or global, occupies one byte. A fixed array is rejected as a top-level parameter or result. On Windows x64 `"stdcall"` is accepted as the source-level convention but lowers to the same machine convention as `"c"`, as clang does. | This is the whole Win64 rule for the foreign-ABI-safe subset, and the subset is what keeps it small: no classification of mixed-class eightbytes or register-pair returns. Keeping the direct Boolean signature distinct from its byte-sized storage matches clang rather than confusing LLVM value types with C object representation. |
| ABI-safety predicate | One `foreign_abi_safe(type) -> (bool, reason)` reused by foreign parameters, results, and globals, by exported declarations, and by procedure-pointer compatibility. Its diagnostic names the member path that made the type unsafe, not just the outermost type. | The rule is recursive, so a struct four fields deep is the case that actually needs the message. One predicate also means the exported and imported directions cannot drift. |
| `int` is not C `int` | No check. The diagnostic surface is documentation: design.md already states that nothing at the boundary can detect it. | A binding that writes `int` where the C side means `int32_t` is type-correct in both languages; inventing a heuristic warning would fire on every correct `ptrdiff_t` binding. |
| Foreign declarations | A foreign block's members are collected as ordinary symbols in the same top-level pass as declarations. What differs is that they have no body, carry a link name, a library, and a convention, and emit an LLVM `declare`. | Name resolution, visibility, overload ranking, and call checking then need no foreign-specific path — only emission and the ABI-safety check do. |
| Library resolution | `foreign import x "name.lib"` resolves relative to the importing file; a `system:` prefix passes the bare name for the linker's own search path. Every active foreign import in the compiled program joins the existing `clang` command, deduplicated, in a deterministic order. `.s`/`.S` are handed to clang; `.asm` requires `nasm` on `PATH` and is diagnosed by name when it is missing. | [A7](compiler-plan.md#a-big-decisions) keeps the linker external, and one command already exists for the seed runtime. An assembler *search* is more than design.md's example needs. |
| Attributed LLVM layout | `@(packed)` and `@(align=N)` use one byte-exact aggregate representation derived from `src/layout.odin`: explicit byte arrays represent every internal and tail-padding gap, and a logical-field-to-LLVM-index map keeps GEPs on the source field. The representation is used for the attributed record and transitively for every struct that contains an over-aligned value by value; arrays then inherit the padded element size as their stride. A packed record uses LLVM `<{ ... }>` around those explicit components. | LLVM struct types cannot carry a requested ABI alignment. Storage-site `align` can guarantee a base address but cannot change a containing record's field offsets or an array's stride, so explicit padding is the only way for nested and combined `@(packed, align=N)` shapes to agree with Loke layout. Unattributed containment graphs keep their existing LLVM spelling. |
| Alignment at use sites | A helper emits the Loke alignment at `alloca`, global, heap/container allocation, load, store, and both sides of `memcpy`. Places also carry their effective guaranteed alignment: entering a packed field lowers it to 1 for every nested access. `&value.field` on a packed field is a checker error; the address of the whole value stays valid. | Explicit padding fixes offsets and stride; site-local alignment fixes storage and optimizer promises. Tracking effective place alignment prevents `packed.outer.inner` from accidentally regaining the inner type's natural alignment. |
| Release output | `-opt=none\|minimal\|size\|speed\|aggressive` maps respectively to `-O0`, `-O1`, `-Os`, `-O2`, and `-O3` on the single `clang` invocation that already consumes the `.ll`. `-Ofast` is not used because it changes floating-point semantics. [A5](compiler-plan.md#a-big-decisions)'s separate `opt`/`llc` split is not taken. | Clang runs the same optimization pipeline on textual IR. The claim M7 makes is behaviour preservation, and that is a testing obligation rather than a pipeline one. |
| Optimization safety | The emitter emits no `nsw`, `nuw`, or `noalias`, and every defined fault already calls the runtime instead of inheriting poison. The whole `tests/run` and `tests/trap` corpus runs at all five optimization modes and must produce identical stdout, failure status, and checked trap output. | Wrapping arithmetic is design.md's rule, so the absence of `nsw` is a semantic requirement rather than an oversight — and the differential corpus is the cheapest thing that would catch its reintroduction. |
| Build constants | `LOKE_ARCH`, `LOKE_OS`, `LOKE_ENDIAN`, `LOKE_BUILD_MODE`, `LOKE_DEBUG`, `LOKE_OPTIMIZATION_MODE`, `LOKE_VENDOR`, and `LOKE_VERSION` are predeclared universe constants. Their enum types are ordinary `base:runtime` source bound through `src/stdlib.odin`'s existing identity binding. | `when (LOKE_OS == .Windows)` must work with no import, because an implicit selector resolves against the constant's own type — while the enum stays a nameable type for code that wants to pass one. |
| Build modes | `exe` validates package `main`, emits the C entry, and asks clang to link the generated module, the seed runtime, assembly objects, and imported libraries. `obj` accepts any root package, skips executable validation, emits no `main`, and runs `clang -c` on the generated `.ll` alone. The resulting `.obj` deliberately retains references to the seed runtime and foreign symbols; its C consumer supplies the runtime C sources (or a compatible prebuilt runtime) and libraries at the final link. Assembly imports are built and joined only by `exe`; an `obj` build that contains one diagnoses that the final consumer must compile and link it separately. | Object output is one relocatable compiler module, not a disguised final link. This avoids a duplicate `main` and avoids the impossible `clang -c a.ll runtime/*.c -o one.obj` shape while making the runtime ABI dependency explicit. A shared library still needs an export table and a separate distribution decision, so it remains deferred. |
| Debug selection | M7 has no `-debug` option and predeclares `LOKE_DEBUG=false`. A later debug-build milestone must introduce the option, debug information, and any debug-mode facilities together before the constant can become true. | This keeps `LOKE_DEBUG` truthful under design.md's definition instead of claiming that debug information is enabled when none exists. Source can still branch on the required predeclared constant in a release build. |
| Attribute discipline | One table: attribute name → allowed positions, value shape, duplicate policy. An unknown bare name, an unknown namespace, a misplaced attribute, and a wrong value shape each get their own diagnostic. Every namespaced extension attribute is an error naming its namespace. | Attributes are currently parsed and mostly ignored, so a typo is silent. After M7 every attribute design.md defines is either implemented or deliberately absent, which is what makes silence indefensible. |
| `@(export)` / `@(link_name)` | Both replace the mangled `@loke.p.<pkg>.<name>` with the written symbol, checked for collisions across the whole program and against the reserved `loke_rt_` prefix. An exported procedure must declare a foreign calling convention and an ABI-safe signature. | Two exported declarations agreeing on a name is a link-time failure with no source location; the compiler owns the whole symbol table and can say which two declarations they were. |
| `@(c_vararg)` | The signature keeps `..any_view` notation, but it is a checker-only exception rather than permission to pass any Loke value. At each direct call, every concrete variadic argument must satisfy the foreign-ABI predicate; a top-level fixed array, managed value, erased value, or other unsafe type is rejected at that argument. The call emits a true LLVM varargs call, classifies safe aggregates, performs C default promotions (`f32` → `double`; `bool`, enums, and integers narrower than `i32` → `i32`), and builds no slice. A spread is rejected because it either erases the concrete types or has a runtime argument count that LLVM call syntax cannot express. | design.md says the compiler passes each original concrete argument. Call-site validation closes the `..any_view` hole, and rejecting spreads keeps every emitted vararg statically typed and counted. LLVM's Win64 backend performs the required floating-register duplication once it sees a true variadic call. |
| `@(deprecated)` / `@(require_results)` | `@(deprecated)` is procedure-declaration metadata producing a warning at every use site. `@(require_results)` is declaration metadata producing an error at each implicitly discarded result; a procedure-group attribute applies after overload selection, and a foreign-block attribute is copied to every procedure member. An explicit `_ = call()` remains accepted. None participates in procedure-type compatibility. | The metadata belongs to the selected declaration or enclosing policy, not the structural procedure type. Propagating the two enclosing forms implements every position design.md lists without making otherwise identical signatures incompatible. |
| Foreign-block visibility | `@(public)` and `@(private)` on a foreign block supply the visibility default for its members, with a member's own attribute taking precedence and contradictory attributes diagnosed. | A foreign block is a declaration container, so collecting its members as ordinary symbols must not lose the block-wide visibility policy design.md promises. |
| Compile-time foreign | A foreign procedure cannot be called on an executed compile-time path, and has no body to run in any case. | [B10](compiler-plan.md#b10-compile-time-evaluation-engine)'s sandbox already forbids it; M7 adds the fixture that proves the message names the foreign declaration. |
| Foreign trust boundary | Unchanged. Retention of a pointer, `cstring_view`, or `inout` argument by foreign code is not checked. M5b's rules apply up to the call and stop there. | design.md's [what is not checked](design.md#what-is-not-checked) list is a v1 decision, not a gap M7 closes. |
| `core:os` | Freeze `os.Args` as a process-lifetime, read-only zero-sized view and `os.args: Args` as its zero value. It supports `len`, indexing, and iteration; indexing returns an owning UTF-8 `string`. Executable entry becomes `wmain(i32, ptr)`, calls a versioned runtime initializer that converts the incoming UTF-16 argument vector to cached UTF-8 before attaching the initial thread, then calls Loke `main`. Two foreign-safe runtime getters expose count and one `cstring_view`; `core:os` implements the view and copying conversion as ordinary Loke source over that foreign block. `os.exit` is also ordinary source and needs no compiler knowledge: the process dies inside the call, so no cleanup runs by construction. | This freezes the previously missing public shape, preserves Loke's UTF-8 invariant on Windows, and keeps imports free of automatic package initialization: startup belongs to the executable runtime, while the library layer is ordinary Loke. An object build emits neither `wmain` nor argument initialization because its foreign host owns startup. File handles remain ordinary post-v1 library work. |
| Diagnostics | Reserve L0601–L0635: build and driver L0601–L0605, attributes L0606–L0612, record layout L0613–L0617, conventions and foreign ABI L0618–L0630, export and linking L0631–L0635. L0636–L0638 went to the deferred-`Simd`, text, and map-address messages. L0639 onwards is left for M8 and [transitive provenance](provenance-plan.md). | M6b's reservation ended at L0600 and its last used code is L0595. |

## Steps

Each step ends with a built compiler and a green existing corpus. No construct
is ungated in a step that does not also install its checking.

### 1. Release output, build configuration, and attribute discipline

- Add `-opt=` and `-build-mode=exe|obj` to the driver and map the five named
  optimization modes exactly as recorded above. Add the `LOKE_*` predeclared
  constants and the `base:runtime` enums behind them; `LOKE_DEBUG` is present
  and false, and `-debug` remains an unknown option until a real debug build is
  implemented.
- Make the corpus harness accept an extra flag set from the environment, and run
  `tests/run` and `tests/trap` at `none`, `minimal`, `size`, `speed`, and
  `aggressive`. Compare stdout and exit status for run cases and stdout,
  nonzero status, and any checked trap output for trap cases.
- Add the attribute validation table over every attribute design.md defines,
  including the ones later steps implement — each of those reports its own
  "recognized, not yet implemented" diagnostic rather than being ignored or
  falling into `L0350`. Implement `@(deprecated)` and `@(require_results)`,
  including procedure-group policy. Validate the shape and placement of
  foreign-block visibility and required-result attributes here, but leave their
  member propagation behind the foreign-block gate until step 4.

**Exit:** every optimization level produces identical program output over the
whole corpus; `when (LOKE_OS == .Windows)` and `build_config` coexist with no import;
an unknown, misplaced, duplicated, or badly shaped attribute is one exact
diagnostic; a deprecated procedure warns on calls and value uses; and a
discarded required result errors whether the policy came from the procedure,
or its group. A valid foreign-block policy is recognized but still reports the
step-specific implementation gate.

### 2. Record layout attributes

- Implement `@(packed)` and `@(align=N)` in `src/layout.odin`; permit their
  combination, raise rather than lower the natural requirement when `N` is
  smaller, and reject the address of a packed field.
- Add the byte-exact LLVM aggregate builder and logical-to-physical field-index
  map. Insert explicit internal and tail padding for attributed records and for
  every containing struct whose natural LLVM layout would otherwise disagree;
  keep every unaffected type's existing LLVM spelling.
- Add the site-local alignment helper and effective-place-alignment tracking.
  Apply them at `alloca`, global and static definitions, heap/container
  allocation, loads, stores, and both operands of `memcpy`; once an access
  enters a packed field, every nested access stays alignment 1.
- Extend `tests/layout` with packed, over-aligned, combined, nested, and array
  combinations. Check field offsets and array stride through both runtime type
  information and `offset_of`, and pin logical field GEPs in `tests/ll`.

**Exit:** `-check-layout` agrees with LLVM for every attributed struct; a packed
field's address is rejected with its own diagnostic; an over-aligned value is
correctly aligned in local, static, global, fixed-array, dynamic-container, and
containing-record storage; nested packed access never asserts excess alignment;
and the generated IR is byte-identical to M6b's for every containment graph
unaffected by a layout attribute.

### 3. Calling conventions and the Windows x64 C ABI

- Accept `"c"` and `"stdcall"` on procedure declarations, types, literals, and
  values; reject every other spelling by name. Ungate the checker's
  convention-bearing procedure path.
- Implement the classification: register-sized aggregates, indirect aggregates
  through byte-exact caller temporaries, `sret` results, direct `_Bool` as
  `i1 zeroext`, `@(by_ptr)` parameters, and `@(c_vararg)` calls with C default
  promotions. Implement the ABI-safety predicate and apply it to every
  parameter, result, global, procedure-pointer signature, and concrete C
  variadic argument that crosses; reject every C-vararg spread.
- Verify each classified shape against clang's own IR for the equivalent C
  declaration, including `_Bool` parameters/results/record fields and variadic
  aggregates, and pin the comparison as `tests/ll` fixtures. The comparison is
  over ABI signatures, attributes, sizes, alignments, and offsets rather than
  requiring an unrelated internal LLVM record name or spelling to match.

**Exit:** for every foreign-ABI-safe shape, lokec's parameter and result
lowering matches what clang emits for the equivalent C declaration; a
non-ABI-safe type names the member path that made it unsafe; a convention
mismatch between a procedure value and its target is still rejected by the
existing type compatibility rule; an unsafe or spread C variadic argument is
rejected at that argument; `"stdcall"` and `"c"` have the same Win64 machine
lowering but remain distinct source procedure types; and `loke`-convention IR
is unchanged outside the attributed-layout containment graphs from step 2.

### 4. Foreign imports, blocks, and linking

- Collect foreign block members as ordinary symbols in the top-level pass;
  resolve `@(link_name)` and `@(default_calling_convention)`; emit `declare` for
  procedures and `external global` for variables. Propagate block-wide
  visibility and `@(require_results)` metadata before ordinary member checking,
  while letting an explicit member visibility override the block default.
- Resolve foreign import paths, add every active one to the link command,
  deduplicated and deterministically ordered, and handle assembly inputs.
- Confirm the analysis boundary: a foreign call registers no cleanup and no
  unwind frame, borrows end at the call, and a compile-time path that reaches a
  foreign procedure is rejected naming the declaration.

**Exit:** a program calls a real C library and an assembled routine and runs; a
missing library, a missing assembler, and an unresolved link name are three
distinct diagnostics; and a foreign declaration participates in ordinary name
resolution, visibility, and overload ranking with no foreign-specific path. A
public foreign block exposes every unoverridden member, and its required-result
policy is observable after overload selection and through a procedure group.

### 5. Exported symbols, object output, and `core:os`

- Implement `@(export)` on procedures and globals over the existing mangling,
  with whole-program collision checking and the reserved runtime prefix.
- Split executable validation, entry emission, and final linking from module
  emission. In `obj` mode accept a non-`main` root, emit neither `main` nor
  `wmain`, invoke `clang -c` on only the generated `.ll`, retain runtime and
  foreign references as unresolved symbols, and diagnose an assembly import
  with the final-consumer instruction recorded above.
- Link that object into a C program together with the seed runtime sources. The
  C host attaches its thread, calls an exported procedure, detaches, and owns
  the process entry; verify with `dumpbin /symbols` or LLVM's equivalent that
  the Loke object itself defines no entry symbol.
- Add the versioned runtime argument initializer/getters, change executable
  startup to `wmain`, and write the frozen `core:os.Args`, `args`, and `exit`
  layer over their foreign block. Check UTF-16-to-UTF-8 conversion, zero and
  multiple arguments, indexing, iteration, and prove that `os.exit` runs no
  `defer`, drop, or thread-local cleanup. Record the exact `Args` surface and
  executable-startup ABI in `design.md` in this step.

**Exit:** C code calls exported Loke code and gets the right answer; two
declarations claiming one symbol name a source location each; an exported
declaration with a non-ABI-safe signature or the `loke` convention is rejected;
the `.obj` contains no compiler-generated entry and links only when its host
supplies the runtime; and `os.args` reports the process arguments as valid UTF-8
through its specified view API.

### 6. Audit and documentation

- Audit every M7 construct against the checker, evaluator, provenance,
  lifecycle, formatter, and layout hooks the earlier milestones own. Retire the
  remaining gates and prove one diagnostic per previously gated construct.
- Confirm that no `L0350` reachable from valid source remains except the
  documented compile-time `foreach` limit and `Simd(T, N)`, which reports its
  own M8 diagnostic rather than "not compiled yet in this milestone".
- Update `design.md`, `readme.md`, and the M7 record in `compiler-plan.md` as
  implementation lands; document each deviation beside the mechanism it changed.

**Exit:** the verification below passes from a clean build at every optimization
level, and every deferred item is listed in one place with the reason it waits.

## Verification

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
./lokec.exe examples/hello.loke -o hello.exe -opt=speed
./hello.exe
```

Milestone spot checks:

- The whole `tests/run` and `tests/trap` corpus produces identical observable
  results at `-opt=none`, `minimal`, `size`, `speed`, and `aggressive`; the last
  mode is `-O3`, never `-Ofast`.
- Every `LOKE_*` constant is readable from `when` and from `build_config`-free source
  with no import, and each reports the selected target/build value;
  `LOKE_DEBUG` is always false because M7 accepts no debug build.
- A packed struct's fields load and store unaligned, its field address is
  rejected, and its size, alignment, and offsets agree with LLVM; an
  over-aligned struct has the right internal padding, tail padding, containing
  field offset, fixed-array stride, and alignment in every storage duration and
  inside a dynamic container. A nested access through a packed aggregate stays
  alignment 1.
- For each foreign-ABI-safe parameter and result shape, the emitted signature
  matches clang's for the equivalent C declaration: register-sized aggregates,
  indirect aggregates, `sret` results, scalar and stored `_Bool`, `@(by_ptr)`,
  and `@(c_vararg)` promotions and aggregates. A managed or spread variadic
  argument is rejected before emission.
- A non-ABI-safe foreign parameter, result, global, or exported signature names
  the member path that made it unsafe. A generic declaration, an interface, and
  a managed container are each rejected at the boundary.
- A program links and calls a real C library, an assembled routine, and a
  `system:` library; a missing library, missing assembler, and unresolved link
  name are distinct diagnostics.
- A C program links a Loke object and calls an exported procedure after the
  documented thread attach, supplying the seed runtime at that final link. The
  object itself has no `main`/`wmain`, accepts a non-`main` root package, and two
  declarations claiming one symbol are diagnosed with both locations.
- A foreign block's public/private default and required-result policy reach all
  applicable members, an explicit member visibility overrides the default, and
  a procedure-group `@(require_results)` is enforced after overload selection.
- `os.args` handles zero and multiple non-ASCII Windows arguments through its
  frozen view API and returns valid UTF-8 strings; an object host receives no
  compiler-owned argument initialization.
- `os.exit` runs no `defer`, no drop, and no thread-local cleanup; a normal
  return from `main` still runs all three.
- A compile-time path reaching a foreign procedure is rejected with the
  compile-time stack and the declaration named.
- Borrow, region, lifecycle, and panic behaviour are unchanged across every new
  construct: a foreign call ends the borrows it was given and registers no
  cleanup.

## Deliberate shortcuts

### Earlier shortcuts M7 repays

| Earlier shortcut | M7 replacement |
|---|---|
| Foreign syntax parses and falls out of the top-level dispatch into `L0350` | Foreign imports, blocks, globals, and calls as ordinary symbols with a checked ABI |
| A procedure carrying a calling convention is gated | `"c"` and `"stdcall"` with real Windows x64 classification |
| `src/layout.odin` models the natural layout only | `@(packed)` and `@(align=N)`, proved against LLVM |
| Attributes are parsed and silently ignored | One validation table, and every attribute design.md defines implemented or explicitly absent |
| One unoptimized `clang` invocation | Five precisely mapped optimization modes, distinct executable/object pipelines, and a differential corpus |
| The program model has no way to read arguments or exit | `core:os` over a foreign block |

### Shortcuts retained after M7

The v1 trust-boundary set is unchanged: stored borrows, unsafe provenance loss,
foreign retention, hidden user-record aliases, and cross-thread transfer stay
unchecked. Closing the record and global halves of that list is
[its own plan](provenance-plan.md), because it changes what the borrow checker
is rather than what this milestone builds. The annotated typed AST still lowers directly to textual LLVM; MIR
waits for a second consumer. Debug builds and debug information, shared-library output, extension
attributes, non-Windows targets, and the two blocks listed under
[Moved to M8](#moved-to-m8) are all deferred, none of them in a way that changes
the pipeline shape.

## Assumptions

- Windows x64 remains the only code-generation target, so "the target C ABI" is
  one concrete ABI throughout and needs no abstraction over a second one.
- M6a's runtime allocator ABI, public Loke layouts, and frozen `Type_Kind`
  ordering are unchanged inputs. The `Simd` member stays reserved and unused, so
  M8 can fill it without moving a runtime ABI version.
- LLVM and clang are the release toolchain; `nasm` is required only by a program
  that imports a `.asm` file.
- The `loke` calling convention's lowering stays LLVM's, so no existing IR,
  fixture, or emitted signature changes except where an attribute or a
  containing attributed value requires byte-exact layout.
- The Windows executable entry may use `wmain`; the seed runtime owns the
  UTF-16-to-UTF-8 cache for the process lifetime, while an object host owns its
  own startup and does not receive that cache implicitly.
