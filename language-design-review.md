Loke language design review — 21 September 2026
================================================

Loke's main complexity is in the interaction between features, rather than in the number of keywords. Its strongest simplification opportunity is to make ordinary refactorings preserve meaning: adding a field, introducing a local variable, annotating a result, or choosing between two equivalent callbacks should not unexpectedly change borrowing or dispatch.

My recommendation is to preserve value semantics, deterministic cleanup, explicit ownership transfer, structural interfaces, and typed errors, while regularizing parameters, overloads, callback contracts, and iteration. Put most additional expressiveness into a small number of library operations. Do not add a general effect system, nominal conformance, or a second exception mechanism to solve these problems.

This review is based on repository revision `d7c0dc8`, the normative design and grammar, relevant compiler modules, the standard library, examples, and diagnostic fixtures. I built a fresh compiler, checked 23 small probe programs, and executed six of them. These are targeted observations, not a full conformance audit; I did not run the full test suite. The alternative designs below were evaluated analytically, not implemented or benchmarked. No compiler or specification changes were made.

**What is already earning its complexity**

Several decisions should survive a simplification:

| Existing choice | Why it helps |
| --- | --- |
| One procedure result, with records for multiple values | Avoids a separate multiple-return mechanism and composes with containers and generics. |
| `Option`, `Result`, `or_return`, and `or_else` | Makes failure ordinary data while keeping propagation compact. |
| Explicit overload groups and definition-site generic lookup | Gives a reader a bounded candidate set and prevents imports from silently changing generic behavior. |
| No user-defined implicit conversions | Avoids conversion chains, surprising allocations, and difficult overload explanations. |
| Automatic cleanup plus explicit `move` | Makes ordinary resource management concise and transfers visible. |
| Read-only and mutable views | Expresses access intent without duplicating runtime representations. |
| Ordinary procedures at compile time | Reuses the language instead of introducing a macro or metaprogramming language. |
| Closed enums and tagged unions | Supports useful exhaustiveness errors. Enum representation control remains valuable for interop. |
| Explicit allocators and build-selected services | Avoids hidden dynamic context inherited through unrelated calls. |
| Existing diagnostic notes for borrow conflicts and interface failures | Already explains causes substantially better than a generic “invalid program.” |

These choices are described in [the design](C:/code/loke/design.md:3004), [interfaces](C:/code/loke/design.md:2628), and [compile-time evaluation](C:/code/loke/design.md:3209).

**Observed complexity and refactoring surprises**

1. **The meaning of an ordinary parameter depends on the contents of its type.**

An ordinary `value: T` parameter is a callee-local value for a trivial type, but aliases caller storage when `T` is managed. Explicit `borrow T` and ordinary method receivers alias caller storage regardless.

This probe is rejected with L0526:

```odin
Point :: struct { n: int }

ref :: proc(value: Point) -> ^int {
    return &value.n;
}
```

Adding an unrelated `label: string` field to `Point` makes the same procedure compile. The managed field changes the lifetime meaning of the parameter, even though the returned pointer still names `n`.

That is a substantial learning and maintenance cost. “Does this helper return a reference to its argument?” should be answerable from the signature, without recursively classifying every field. Moving a helper between a method and a free procedure should also be predictable.

Source: [parameter semantics](C:/code/loke/design.md:4071), [receiver forms](C:/code/loke/design.md:2001).

2. **Expected results participate in overload selection, and explicit modes are a late tie-breaker.**

I verified this program prints `1 2`:

```odin
integer :: proc(x: int) -> int { return 1; }
real    :: proc(x: f64) -> f64 { return 2.0; }
pick    :: proc{integer, real};

inferred := pick(7);
typed: f64 = pick(7);
fmt.println(inferred, typed);
```

The type annotation selects a different implementation. It does not merely validate or convert the result of the original call.

A second probe prints `1`:

```odin
ordinary  :: proc(x: int) -> int { return 1; }
consuming :: proc(x: move $T) -> int { return 2; }
pick      :: proc{ordinary, consuming};

value := 7;
fmt.println(pick(move(value)));
```

The non-generic ordinary overload wins before the rule favoring a consuming parameter is reached. The move still consumes the argument; this is a dispatch surprise, not a failure to move it.

The library already pays for this interaction: `Small_Array` adds a one-element copying overload to keep it structurally level with its consuming overload. This is evidence of language complexity leaking into API implementation.

Sources: [overload ranking](C:/code/loke/design.md:2137), [Small_Array overload workaround](C:/code/loke/core/container/small_array.loke:139).

3. **Callback types expose declaration identity and lose useful information under ordinary composition.**

These procedures have identical written signatures and identical result dependencies:

```odin
a :: proc(x, y: []int) -> []int { return x; }
b :: proc(x, y: []int) -> []int { return x; }
```

Nevertheless, `type_of(a) == type_of(b)` prints `false`.

Inside this helper, `callback := a` compiles:

```odin
choose :: proc(flag: bool, input: []int) -> []int {
    local := [1]int{7};
    callback := a;
    return callback(input, local[:]);
}
```

Changing only the callback declaration to:

```odin
callback := a if flag else b;
```

produces L0526. The conditional falls back to a plain procedure signature, which conservatively lets the result borrow `local`, although neither branch does.

The inference is useful, but its representation makes harmless composition lose information. Exporting `type_of(some_implementation)` also turns details of that implementation's body into a public lifetime contract.

Sources: [procedure result contracts](C:/code/loke/design.md:4756), [contract compatibility implementation](C:/code/loke/src/proc_contracts.odin:41).

4. **Iteration combines a good default with several exceptional mechanisms.**

Borrowing elements by default is a good choice. Move-only elements remain readable, and routine traversal does not clone collections.

The complications are around that default:

- The binding pattern chooses the traversal mode.
- Compiler-recognized adapters carry that mode back to a root expression.
- Storing an adapter changes its available mutation behavior.
- `Element`, `Iterator`, `Item`, `Yield`, and mutable iterator counterparts describe overlapping aspects of the protocol.
- A single record binding receives pointer fields; destructuring can instead bind their pointees.
- Nested destructuring exists in loop headers but not ordinary declarations.
- Immutable yields can outlive iterator advancement when rooted in the source, whereas mutable yields end before the next step.

I verified that the first form below compiles and the second is rejected with L0457:

```odin
foreach (&value, index in values.indexed()) {
    value += index;
}
```

```odin
view := values.indexed();
foreach (&value, index in view) {
    value += index;
}
```

The diagnostic asks for `Element`, `Mut_Iterator`, and `iter_mut`. A user who merely extracted an expression into a local has to understand compiler-generated iterator types to interpret it.

Sources: [iteration protocol](C:/code/loke/design.md:2245), [stored adapters](C:/code/loke/design.md:2360).

5. **Copying and allocator policy interact with the history of a variable.**

A declaration can have a persistent allocation policy, while its current value carries a different allocator after a move. Copy assignment into a live destination uses its bound allocator; reviving a dead destination uses the declaration policy. Strings and shared owners instead retain their allocation and prohibit `via`.

Each individual rule has a rationale. Together, they require answering “where will this assignment allocate?” from both the declaration and the destination's history.

This also makes automatic cloning an observable failure site, requiring prepare-before-write behavior, partial-construction cleanup, allocation failure policies, and copy-cost diagnostics across many syntactic contexts.

This is not automatically a reason to remove copying: it buys meaningful value semantics. It is a reason to evaluate copying and allocator simplification together, rather than deleting `via` in isolation.

Sources: [assignment](C:/code/loke/design.md:3511), [declaration policy after move/drop](C:/code/loke/design.md:3108), [allocation failure](C:/code/loke/design.md:5445).

6. **The checker has visible precision thresholds that can reject valid code.**

I checked the following with arrays of eight and nine elements:

```odin
choose :: proc(input: []int) -> []int {
    local := [1]int{2};
    values: [9][]int = {};
    values[0] = input;
    values[8] = local[:];
    return values[0];
}
```

The nine-element version is rejected because array element provenance is merged. The equivalent eight-element version compiles. The compiler correctly includes a precision-limit note; that existing diagnostic deserves credit.

The problem is predictability, not a missing message. Other public budgets include aggregate depth, carrier-path count, and constant map keys. The map-key budget is shared across maps in a procedure, so unrelated additions can affect precision elsewhere.

Larger limits would postpone these boundaries without removing them. A design should provide ways to express a small, precise dependency without requiring an ever larger analysis budget.

Sources: [minimum provenance precision](C:/code/loke/design.md:4619), [existing precision diagnostics](C:/code/loke/src/precision.odin:19).

7. **Some essential operations are expressible only with disproportionate ceremony.**

| Task | Current obstacle | Smallest useful direction |
| --- | --- | --- |
| Pass a stateless comparator to sorting | An ordinary `proc(int, int) -> bool` fails `Comparator` because it has no `call` method. Verified L0444. | Adapt procedure values to the callable protocol, or supply a library overload. |
| Compare using a captured threshold | Procedure literals cannot capture. A local record, fields, an `impl`, and a `call` method are needed. | First improve callable interoperability; later consider explicit capture sugar over those same records. |
| Wrap a parsing error in an application error | A wrapper procedure and explicit target type are required by `map_error`. | Infer nested procedure type parameters and consider callable variant constructors. |
| Insert a move-only value without panicking, keeping it if full | `Small_Array(Token, N).try_append` does not exist. Verified L0363. | Return the rejected element alongside the error. |
| Split mutable storage at a runtime position | Complementary ranges over an `inout` fixed array are conservatively overlapping. Verified L0511. | A checked `split_at_mut` library boundary, with a narrow trusted implementation. |
| Iterate directory entries and propagate I/O failure | `Directory_Reader.next` returns `Result(Option(Entry), Error)`; it is not a `foreach` iterable. Verified L0456. | Document a compact ordinary loop before adding a fallible iteration construct. |
| Store heterogeneous owned implementations | `dyn` only borrows. Open ownership needs an explicit owner and callbacks. | Start with a concrete move-only owning pointer library type; design owning erasure only when an application needs it. |
| Return an owner together with views into itself | Ordinary root provenance does not express a generally movable self-referential owner. | Store offsets/ranges and derive views when needed; do not add self-referential lifetime machinery for this alone. |
| Work with slices of different logical regions in a large aggregate | Provenance merging can introduce unrelated dependencies. | Return/pass the needed view separately and expose simple public callback bounds. |
| Retain multiple mutable iterator yields | The protocol ends each loan before advancement. | Use indices/handles, or a purpose-built API that establishes disjointness. Do not assume every user iterator yields a new element. |

Sources: [sort comparator](C:/code/loke/core/slice/slice.loke:21), [noncapturing procedures](C:/code/loke/design.md:4031), [map_error](C:/code/loke/base/runtime/runtime.loke:126), [Small_Array consuming operations](C:/code/loke/core/container/small_array.loke:188), [directory reader](C:/code/loke/core/fs/fs.loke:647), [mutable iteration loans](C:/code/loke/design.md:2448).

The compiler's comparator and capture diagnostics are already clear. The missing piece there is an ergonomic way to write the intended program, not more elaborate rejection.

**Errors that do not currently become compile errors**

These cases should be distinguished by policy instead of placed in one “make the checker stronger” bucket.

| Case | Observation | Appropriate response |
| --- | --- | --- |
| A certainly nil dereference followed by a later non-nil assignment | Compiles; execution panics. The later write suppresses the whole-body nil diagnostic. | Diagnose definite nil at the use, without requiring general non-null proofs. |
| A required result is overwritten after an earlier value of the same variable was read | Compiles. Result checking tracks whether the name was read, not whether this particular result was observed. | A targeted unused-result warning on overwriting that value. Explicit discard stays legal. |
| Ignored custom `@(failure=err)` union | Compiles unless it also has `@(require_results)`. | Make the distinction clear; prefer `Result` for error APIs. Do not make every optional container result mandatory. |
| Integer narrowing | A `u16` value of 256 converted to `u8` prints 0. | Keep specified wrapping behavior; provide a named checked conversion for validation. |
| Missing map keys, nil values from parameters, invalid UTF-8 boundaries | Generally runtime checks, with some constant cases diagnosed earlier. | Keep checked/nontrapping alternatives discoverable. Do not force every access through a proof. |
| Inconsistent hash/equality, invalid custom ownership hooks, wrong initialized-element counts | Programmer obligations; some violations can cause undefined behavior. | Keep these as implementation obligations of low-level abstractions, with focused tests and clear contracts. |
| Thread transfer involving a thread-affine allocator or drop hook | Not compiler-verified. | Explain that atomic reference counts do not make the whole lifecycle thread-safe. Avoid a new trait/effect system without real concurrency use cases. |
| Unselected `when` branches and uninstantiated generic paths | Their semantic errors can remain latent. | Exercise build configurations and generic examples. Checking every discarded platform branch would defeat conditional compilation. |

The first two can be reproduced by these small fragments:

```odin
p: ^int = nil;
fmt.println(p^);
value := 42;
p = &value;             // suppresses the current whole-body nil diagnostic
fmt.println(p^);
```

```odin
r := fail();
_ = r;                 // acknowledges this result
r = fail();            // this new result is never read
```

The nil program built successfully and then exited with a nil-pointer panic. The overwrite program passed checking.

Sources: [nil diagnostic implementation](C:/code/loke/src/nil_uses.odin:1), [require_results semantics](C:/code/loke/design.md:5860), [numeric conversion](C:/code/loke/design.md:325), [unchecked obligations](C:/code/loke/design.md:4832), [initialized capacity](C:/code/loke/design.md:4881).

There is also an acceptance inconsistency worth resolving before extending borrow checking. Direct overlapping slices of an array are rejected:

```odin
values := [4]int{1, 2, 3, 4};
left := values[0:3];
right := values[1:4];
left[1] = 10;
right[0] = 20;
assert(left[1] == 20);
```

Introducing an intermediate mutable slice makes the equivalent accesses compile and run:

```odin
values := [4]int{1, 2, 3, 4};
source := values[:];
left := source[0:3];
right := source[1:4];
left[1] = 10;
right[0] = 20;
assert(left[1] == 20);
```

The implementation propagates existing loans when reslicing a carrier, whereas direct array slicing creates a new projected loan. This is observable evidence, not a claim that this particular program corrupts memory. The specification needs to settle whether sibling mutable views are independent exclusive loans or permitted aliases within one loan. If independent exclusivity is intended, this is a conformance gap. If aliasing is intentional, the description of exclusivity needs to state it. Do not make the rule stricter accidentally while calling it a compiler cleanup.

Source: [slice provenance construction](C:/code/loke/src/cfg_provenance.odin:1889), [capabilities](C:/code/loke/design.md:4635).

**Combinations evaluated**

The unit of simplification should be a coherent set of rules. The following ratings describe likely tradeoffs, not measured compiler size or performance.

| Combination | What changes together | Complexity effect | Expressiveness and ergonomics | Judgment |
| --- | --- | --- | --- | --- |
| A. Diagnostic and library improvements only | Better nil/result messages, callable adapter, recoverable insertion, split helper, documentation | Small core change; existing semantic interactions remain | Immediate benefits with little migration | Good first delivery, insufficient as the whole answer |
| B. Regularize the existing value language | A plus uniform parameter borrowing, input-based overload selection, explicit-mode preference, structural callback bounds, ordinary mutable adapter values | Removes several context/history dependencies; implementation work is meaningful | Preserves everyday copying, cleanup, methods, and readable iteration | Recommended direction |
| C. Explicit allocating copies | B plus requiring `clone` or `move` for allocating owner copies, allocator choice on values rather than persistent declaration policy | Can remove implicit allocation failure from many assignment/construction sites and simplify destination allocator history | More visible cost, but more annotations in record construction, error handling, and ordinary data manipulation | Worth a separate experiment, not an isolated breaking change |
| D. Lifetime/invalidation checking with weaker alias restrictions | Uniform borrowing plus allowing more concurrent read/write aliases, while still tracking owner death and reallocation | Potentially simpler alias model; region and escape analysis still needed | Easier low-level algorithms, but read-only references cease to imply stable contents and existing guarantees change | Viable different design; do not adopt as an incidental relaxation |
| E. Maximum static contracts and abstraction | Add explicit lifetimes, effect/purity checking, nominal conformance, general closures, owning erasure, fallible loops | Substantial language and diagnostic growth | Solves more cases, with a much larger conceptual budget | Poor fit for the stated objective |

Some dependencies matter particularly:

- Removing exclusivity while keeping the claim that borrowing is indistinguishable from copying is not coherent. Alias-visible mutation can reveal the difference. Combination D must explicitly redefine that promise.
- Removing implicit allocating copies without improving move ergonomics and recoverable insertion makes resource-oriented code more cumbersome. These changes should be evaluated together.
- Keeping all current copy behavior while deleting `via` mostly relocates allocator policy; it does not remove the hard assignment rules.
- Capture syntax without a common callable convention leaves records, procedure pointers, error mappers, and closures as separate API families.
- General fallible iteration does not by itself solve readers whose yielded views borrow the iterator's own reusable buffer. Error propagation and lending lifetime are separate issues.
- Returning rejected move-only input in an error makes that error move-only. The current `map_error` is explicitly limited for move-only error parameters; such an insertion API must work with ordinary consuming switches first, rather than assume every existing combinator already supports it.

For combination C, the concrete policy I would test is: trivial values and shared immutable handles still copy normally; potentially allocating owner copies require `clone`, `try_clone`, or `move`. Locals still require explicit `move`; no last-use heuristic changes ownership silently. Allocator-selecting construction replaces persistent declaration policy, and a copied value is constructed with an explicit or default allocator. This is a real reduction, but it changes the feel of Loke. Port the existing examples and a resource-heavy program before choosing it.

**Concrete proposals, in priority order**

1. **Give ordinary Loke parameters one read-only borrowing meaning.**

Make `value: T` and an immutable receiver mean the same thing for all types. Keep `inout T` for exclusive mutation and `move T` for ownership transfer. Deprecate `borrow T` as a redundant spelling once migration is available.

Under this rule, both versions of the `Point` example have the same behavior. A scalar can still be passed in a register when doing so is unobservable. If a procedure returns its argument's address, lowering must preserve the caller's storage and enforce its lifetime; this is a semantic requirement, not permission to return the address of a register spill in the callee.

Foreign calling conventions retain their explicit ABI rules. The proposal concerns ordinary Loke calls.

The migration cost is real: some presently trivial parameters acquire borrowing relationships, and some aliasing calls may need adjustment. But it removes a recursive managed/trivial distinction from source-level reasoning and unifies methods with free helpers. It does not require changing assignment semantics.

**Follow-up analysis of proposal 1 (21 September 2026)**

The problem is real and more serious than described above, but the proposed rule is the more expensive of two uniform rules. This follow-up recommends the other one. Probes were compiled with a fresh `lokec` at `d7c0dc8` and run where they compiled.

*The current rule is miscompiled.* With the `label: string` field added, the `Point` example does not merely compile — it returns a dangling pointer:

```odin
Point :: struct { n: int, label: string }
ref :: proc(value: Point) -> ^int { return &value.n; }

p := Point{7, string("x")};
r := ref(p);
fmt.println(r == &p.n);  // false
fmt.println(r^);         // garbage
```

The checker treats a managed `value: T` as the caller's storage, but the emitter passes it by value, since only `inout` and `borrow` cross as pointers. The same happens for `proc(values: [4]string) -> []string { return values[:]; }`. A generic `first :: proc(values: [2]$E) -> ^E { return &values[0]; }` compiles (and dangles) while instantiated only with `string`, then fails with L0526 once an `int` instantiation is added, and the diagnostic does not name the instantiation.

The rule came from commit `2f13596` (14 September). Its motivating case, `free_view(bag: Bag) -> []int { return bag.items[:]; }`, views heap storage the caller owns and is sound. Extending the rule to the parameter's own inline bytes is not. This needs fixing under any rule.

A second, separate hole: a file-scope owner passed to a managed `value: T` parameter is handed over as a bitwise copy of its header. If the callee assigns that global, the old buffer is dropped (`loke_rt_v1_dyn_drop(ptr @loke.g.g, ...)` in the IR) while the parameter still points at it — a use-after-free with no diagnostic. The probe printed the right value only because the freed block had not been reused.

Sources: [lifetime classification](C:/code/loke/src/abi.odin:43), [ABI classification](C:/code/loke/src/abi.odin:29), [parameter roots](C:/code/loke/src/cfg_provenance.odin:370).

*What proposal 1 solves.* Adding a field never changes a parameter's meaning. Generic helpers behave the same for every instantiation. A method and a free procedure behave the same, and `borrow T` becomes redundant. Large trivial aggregates could be passed without copying.

*What proposal 1 costs.*

| Cost | Evidence or consequence |
| --- | --- |
| Calling convention | Any parameter a result may borrow must be passed by pointer. Either every `value: T` goes by pointer (scalars through memory in debug builds and through procedure values; most pinned IR fixtures in `tests/ll` and `examples/*.ll` change), or lowering follows the result contract, which needs adapter thunks when a procedure converts to a plain procedure type. "When doing so is unobservable" leaves this choice open. |
| Callback results | Through a plain procedure type, a returned view is assumed to borrow every borrowed argument. Today trivial parameters are excluded. Verified: `cb_str(string("xy"), view)`'s result ends with the statement, while `cb_int(i + 1, view)`'s result can be used later. Under the proposal the `int` case breaks too, so every scalar parameter of a written callback type returning a borrow needs `@(escape=none)`. Proposal 3 does not help written plain types. |
| New conflicts | `add(x, bump(inout x))` compiles for an `int` today and is already rejected with L0511 for a managed record. The `int` form would become an error. Rare. |
| Global aliasing | The hole above widens to every type: a callee that writes a global it was passed sees its parameter change, and a union payload bound in a `switch` could then be read as the wrong variant. |
| Specification | Parameter table, ownership-rule table, receiver forms, `inout` results, the procedure-boundary paragraph, escape levels (now legal on every parameter), and foreign `borrow` parameters, which move to `@(by_ptr)`. `base/`, `core/`, and `examples/` have no explicit `borrow T` parameters; only tests use them. |

*Alternative: uniform in the other direction.* A value parameter is a shallow copy that owns nothing: its own bytes end with the call, and everything the argument owns or points to keeps the caller's lifetime. That is what the emitter already does.

- `&value.n` and `value.fixed[:]` are rejected for every `T`, so both `Point` versions behave the same.
- `value.items[:]` and `string` to `string_view` keep the caller's root for every `T`, so the `2f13596` case still compiles.
- `borrow T` and `self` remain the one way to hand out the argument's own storage, visible in the signature. A method moved out of an `impl` becomes a `borrow T` procedure, and L0526 can suggest that.
- No ABI or performance change, no callback regression, the global hole does not widen, and the miscompile is fixed.
- It follows the ownership rule, "borrowed wherever a borrow is indistinguishable from a copy": address identity is exactly where a borrow and a copy differ.

Its costs: provenance must split a managed value parameter into an own-bytes root and an owned-storage root. A view that comes back through a user method on a field, such as `b.stack.view()`, is conservatively own-bytes unless result contracts learn the same split; writing `borrow` works around it. `borrow` stays in the language.

*Recommendation.*

1. Fix the miscompile first. The smallest stopgap is passing managed value parameters by pointer, which makes the current specification sound without changing it.
2. Adopt the shallow-copy rule instead of proposal 1. It meets the acceptance rows "add a managed field" and "move a helper between method and free-procedure form" (with `borrow T` as the equivalent signature) without the calling-convention and callback costs.
3. Decide global aliasing separately. At minimum, list it under [What is not checked](C:/code/loke/design.md:4832).

*Decision (21 September 2026).* Neither rule above, but the stricter end of the second: **a `value: T` parameter is a value for every `T`, and reference behaviour is written in the type.** No borrow of a value parameter outlives the call — neither its own bytes nor storage a managed owner holds — so `trim(s: string) -> string_view` becomes `trim(s: string_view) -> string_view`. Planned steps:

1. Value parameters never lend; this also fixes the miscompile. *Done:* the checker treats every `value: T` as callee-local, a call keeps a managed argument borrowed only until it returns, and implicit `string` to `string_view` conversions now borrow their source (previously unchecked, which let a local `string` escape as a dangling view).
2. Receivers: plain `self` becomes a value; view-returning methods declare `self: ^Self`, with method syntax taking the address implicitly. Remove `borrow T` in favour of `^T`. *Done:* `impl` blocks have no `Self` type, so the receiver is written `self: ^Type` or the short `self: ^`, like `self: inout`. `Type.method(&value)` also works, and a method value stores as `proc(self: ^Type)`. An interface slot or the `iter` protocol written `self: ^` is also met by a value `self`, which lends less. The standard library needed six methods changed (`Small_Array.span`/`view`/`iter`/`iter_reverse`, `Enum_Array.iter`, `String_Builder.view`) plus `Iterable`, `Reverse_Iterable` and `Cloneable`. Slicing storage reached through a pointer (`p.items[:]`, `slot^[:]`) was previously unchecked; it now borrows what the pointer names, which turned a documented gap in `tests/pkg/m5b_aggregate` into an error.
3. An implicit `[dynamic]T` to `[]T` conversion, matching `string` to `string_view`.
4. Global aliasing: a value parameter must not change during the call.

2. **Resolve overloads from inputs; let explicit ownership modes select before structural tie-breakers.**

Keep the conversion vector, explicit groups, and “constraints filter, never rank” rule.

Remove destination-result filtering from candidate selection. Select from arguments and call syntax, then validate the result against its destination. In the example above, `typed: f64 = pick(7)` would report an incompatible `int` result and suggest `pick(f64(7))` or an explicitly named member. A type annotation would no longer silently choose another algorithm.

For `move(x)`, prefer viable consuming candidates before non-generic/default/variadic specificity. Fall back to an ordinary parameter when there is no viable consuming candidate, preserving useful calls that accept an owned temporary. Unmarked places continue to reject consuming parameters; unmarked temporaries can retain the documented ordinary-mode preference.

This removes the reason for API shims whose only purpose is to defeat a higher-ranked tie-breaker. It also makes the move marker's dispatch role explainable in one sentence.

Do not sum conversion scores, guess numeric widths, or add constraint entailment to compensate. Ambiguity remains a useful, understandable error.

3. **Make callback contracts structural and preserve them through composition.**

Two callbacks with the same signature and dependency bounds should have the same relevant callback contract regardless of which declaration supplied it.

A conditional should join dependency bounds. If both branches return only the first argument, the conditional keeps that bound. If one returns the first and the other returns the second, its result may borrow either. The existing dependency representation already needs this conservative set behavior; expose it consistently rather than falling immediately to “all arguments.”

Retain direct-call inference. For public callbacks, promote written signatures using existing `@(escape=none)` where they suffice:

```odin
Chooser :: proc(input: []int, @(escape=none) scratch: []int) -> []int;
```

That states a stable bound independently of an implementation body. Keep richer inferred bounds for cases the written form cannot express; do not discard them merely to simplify type printing.

Diagnostics should display the effective relationship, such as “the result may borrow input only,” and identify where a conversion erased it. A `type_of` alias that exports an inferred implementation contract should make that visible in generated API documentation.

This is significant compiler work, particularly around recursive inference and type interning. It is still a simplification of the language users must reason about, and requires no new lifetime syntax in the first iteration.

4. **Make mutable iteration adapters ordinary values.**

A temporary and a stored view with the same type should support the same operations.

Introduce or expose an explicit mutable-view operation whose type carries the capability through adapters. For illustration only, the surface could look like:

```odin
view := values.mutable().indexed();  // proposed API, not current Loke
foreach (&value, index in view) {
    value += index;
}
```

The source stays exclusively borrowed for the view's actual lifetime. Passing or returning the view follows ordinary provenance rules. Existing compact header syntax can lower to the same operation; it should not grant a capability unavailable to the corresponding stored value.

Also reduce duplicated protocol declarations where signatures determine them: a unique `iter` result determines `Iterator`, and its unique `next -> Option(Item)` determines `Item`. Diagnose inconsistent declarations rather than maintaining independent sources of truth. This must be based on signatures, not speculative execution of method bodies.

I would retain borrowing-by-default and initially retain `Yield`. Replacing all yields with explicit pointer payloads would remove machinery, but it makes normal array/map loops more cumbersome and loses the strongest ergonomic improvement in the current iteration design. Conversely, promising to move all current adapters into ordinary library code is premature: mixed borrowed/owned record yields currently depend on compiler support.

5. **Unify callable APIs before adding general closures.**

First accept ordinary procedures wherever a matching stateless callable is expected. A library overload or wrapper is the smallest initial change; a language-wide synthesized `call` adapter is justified if several APIs need it. Calls and interface matching must respect parameter modes and calling conventions.

Then improve generic inference through procedure parameter/result types. This directly removes the repeated target type from error mapping.

Consider first-class union variant constructors as ordinary factory callables. Together, these two improvements could make this possible:

```odin
value := parse(text).map_error(App_Error.parse) or_return;
// proposed form; current Loke needs App_Error and a wrapper procedure
```

Ownership must remain the same as direct variant construction. A move-only payload must not silently acquire a copy. This proposal is not an implicit conversion between error domains: the intended variant is still named.

Only after that common callable model works should explicit capture syntax be considered. Lower it to the existing local record plus `call` method, with explicit copy/borrow/move captures, ordinary lifetime checks, and no implicit heap allocation. Keep escaping erased ownership a separate decision.

This sequence buys useful ergonomics at each step and avoids designing a full closure runtime before simple procedure callbacks work everywhere.

6. **Fill library gaps with operations that encode intent and ownership.**

The most valuable additions are small:

- A consuming insertion variant returning `Result(Unit, Rejected(T, E))`, where the failure owns the rejected input. The receiver is unchanged on failure, and the caller can retry, store, or explicitly discard the input. Use a distinct name if needed to keep failure behavior unambiguous.
- `split_at_mut`, with one runtime bounds check and a narrow trusted implementation establishing two disjoint views. It may need a small compiler-recognized contract to preserve disjointness through the return; a library signature alone does not establish that proof. Do not require a general inequality solver to recognize complementary ranges.
- A concrete move-only owning allocation wrapper, conventionally `Box(T)` or `Owned(T)`, retaining its allocator and dropping its payload. Keep low-level `new/free` for code that deliberately wants manual allocation. A returned `^mut T` alone does not communicate cleanup responsibility.
- A checked numeric conversion for validation, while keeping explicit wrapping conversions available.
- A documented fallible streaming loop, without new control-flow syntax.

The streaming idiom can already keep EOF, errors, and entry lifetime separate:

```odin
for (;;) {
    next := reader.next() or_return;
    switch (move(next)) {
    case .some(entry):
        process(entry);  // finish using borrowed fields before the next next()
    case .none:
        return .ok;
    }
}
```

This example belongs inside a compatible Result-returning helper. If processing must continue after iteration, put the loop in a helper or use a simple completion flag. Add a dedicated fallible `foreach` only if real code shows that this pattern dominates enough to justify another protocol.

Keep `Result(Option(T), E)`: its three states are not accidental type complexity. EOF is different from failure.

7. **Improve certainty and explanations without demanding proofs of good behavior.**

Use a small forward analysis to diagnose an actually definite nil at a use. Unknown calls and possible writes make the state unknown. Do not reject a pointer merely because it might be nil, and do not add a mandatory nullable/nonnullable type hierarchy for this.

Track individual required-result writes well enough to warn when a result is overwritten or leaves scope unread. Reading it or explicitly discarding it remains sufficient. The checker should not try to prove that the programmer responded correctly to every possible error.

Prefer user-level explanations over compiler protocol names:

```text
Cannot mutate through this stored iteration view.
The view borrows values for reading; it was created here.
Create a mutable view before applying indexed().
```

For bounded provenance, lead with “the compiler cannot distinguish these dependencies,” then explain the possible lifetime conflict and the restructuring that preserves precision. The existing budget note is useful; it should not be buried under a message suggesting a definite dangling reference.

For overloads, show the relevant failed argument or mode and the surviving candidates first. Conversion vectors are valuable detail, but should not be the first thing a programmer must decode.

8. **Keep low-cost features that prevent verbose workarounds; defer additions without consumers.**

Keep `defer`. Automatic drop handles resources, but restoring a plain variable, balancing instrumentation, and observing a cleanup error are still natural scope-exit actions. Requiring a bespoke resource type for each would move complexity into user code.

Keep enum syntax alongside unions. Integer representation, validation, and foreign declarations are useful distinctions; forcing everything through a payloadless union would recover little.

Keep structural interfaces and `static_assert(Interface(T))`. A nominal `implements` registry would add coherence and conditional-conformance questions without solving the concrete callback problems above.

Keep the small `hook(convert/copy/drop)` boundary. These operations affect language semantics; ordinary protocol methods handle most other customization already.

Do not remove switch header bindings solely because branch-local bindings now exist. Grouped cases and consuming subject bindings need a replacement story; otherwise a syntax deletion simply creates temporaries, clones, or more branches. Prefer branch-local payload names in examples, and improve the diagnostic for the `switch (name in expression)` membership ambiguity.

Keep compile-time evaluation hermetic. File/network access during compilation, declaration-generating macros, purity effects, and general owning type erasure should each arrive with a concrete program that the current model cannot reasonably express.

**Delivery order and acceptance criteria**

Start with combination A and the semantic inconsistencies: preserve the probe cases as focused regression tests when changes are implemented, settle mutable subview aliasing, improve diagnostic wording, add a stateless callable path, and specify recoverable consuming insertion.

Then implement the core of B in separate changes: uniform parameter semantics; overload selection; callback contract joins; ordinary mutable views. Update the design, examples, and migration guidance for each. Do not mix a compiler conformance repair with a new language rule.

The acceptance checks should measure refactoring stability:

| Change to a program | Desired result |
| --- | --- |
| Add a managed field to a record | Its existing ordinary parameter signatures keep their lifetime meaning. |
| Move a helper between method and free-procedure form | Equivalent signatures preserve borrow behavior. |
| Introduce a local for an adapter | Capability and traversal behavior stay the same. |
| Add a destination type annotation | It validates the chosen call instead of choosing another implementation. |
| Select between callbacks with identical bounds | Their shared dependency information survives. |
| Write `move(x)` where a consuming overload is available | Dispatch follows the explicit mode before incidental generic/variadic preferences. |
| Run out of capacity during recoverable insertion | The caller can recover the move-only input. |
| Add an unrelated non-borrowing field or local | No change to provenance precision should be caused by it. |
| Exceed a documented analysis budget | The error identifies loss of precision and a practical way to express the dependency. |

Finally, test combination C on the existing examples and a real application before deciding whether explicit allocating copies fit Loke. Count required source changes and inspect common expressions; do not infer ergonomic cost from a shorter ownership chapter alone.

Documentation needs a consistency pass alongside this work. For example, [the standard-library implementation record](C:/code/loke/standard-library-plan.md:1042) still describes limitations that later design sections or compiler work superseded, and [the directory-reader comment](C:/code/loke/core/fs/fs.loke:285) still says managed-element iteration is rejected. [The procedure-boundary discussion](C:/code/loke/design.md:4742) also describes default parameter storage as callee-local without the managed-owner exception specified in the parameter section and observed in the probes. Such contradictions make an already subtle language harder to learn and can lead to designing around restrictions that no longer exist.

The most useful target is a language where the common explanation is short: parameters borrow, explicit modes communicate mutation and transfer, assignments have the documented value behavior, adapters are values, and callback types state usable contracts. Preserve deliberate low-level escape routes and runtime checks; spend the complexity budget on making ordinary correct programs straightforward.
