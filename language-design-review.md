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
3. An implicit `[dynamic]T` to `[]T` conversion, matching `string` to `string_view`. *Done:* a read-only view only; `[]mut T` stays explicit. It borrows the array like `x[:]`, an exact overload still wins over it, and a generic `[]$T` parameter binds through it.
4. Global aliasing: a value parameter must not change during the call. *Done, by checked write effects (design.md "Global write effects"):* the hole was wider than value parameters. A `[]T` view, a local view, and a `self: ^` result of a global all dangled when a callee wrote the global; only the same-body case was caught. Each procedure now has an inferred set of the globals it may write, including through its callees, computed over the whole program before provenance runs. A call counts as a write to each of them while its arguments are borrowed, so the ordinary L0512 conflict reports it ("`cache` cannot be modified by `first` here"). A call through a procedure value reaches every procedure of a compatible type that is used as a value, and a `dyn` call every witness built for that slot. Writes are whole-root, so a callee bumping one scalar field of a global conflicts with a view of another field. Still unchecked, and listed in design.md: writes through a pointer stored in a global, by foreign code, or by implicitly called hooks.

2. **Resolve overloads from inputs; let explicit ownership modes select before structural tie-breakers.**

Keep the conversion vector, explicit groups, and “constraints filter, never rank” rule.

Remove destination-result filtering from candidate selection. Select from arguments and call syntax, then validate the result against its destination. In the example above, `typed: f64 = pick(7)` would report an incompatible `int` result and suggest `pick(f64(7))` or an explicitly named member. A type annotation would no longer silently choose another algorithm.

For `move(x)`, prefer viable consuming candidates before non-generic/default/variadic specificity. Fall back to an ordinary parameter when there is no viable consuming candidate, preserving useful calls that accept an owned temporary. Unmarked places continue to reject consuming parameters; unmarked temporaries can retain the documented ordinary-mode preference.

This removes the reason for API shims whose only purpose is to defeat a higher-ranked tie-breaker. It also makes the move marker's dispatch role explainable in one sentence.

Do not sum conversion scores, guess numeric widths, or add constraint entailment to compensate. Ambiguity remains a useful, understandable error.

**Follow-up analysis of proposal 2 (21 September 2026)**

The first half is right as written and nearly free. The second half has the right aim, but it moves the case nothing in the tree exercises and keeps the one the library works around. Probes were compiled with a fresh `lokec` at `6bbc752`. To measure migration, a throwaway build of the resolver reported every call whose selection a rule change would alter, over the 534 programs in `tests/` and `examples/`; a second throwaway build implementing the alternative below ran the full test suite. Neither is committed.

*Destination filtering is unused, and inconsistent where it acts.* Removing it changes the selection of no call in the corpus. With `pick` as above:

- `takes_f64(pick(7))` picks `real`. Give `takes_f64` a second overload, making it a group `outer`, and `outer(pick(7))` fails with L0392: only a plain callee passes its parameter type down. Adding an overload breaks calls nested in its arguments.
- `typed: f64 = pick(7)` gives `2`, but `f64(pick(7))` gives `1`.
- It implements overloading by return type alone, which the design rules out. This compiles and prints `1 2`:

```odin
as_int :: proc(s: string_view) -> int { return 1; }
as_f64 :: proc(s: string_view) -> f64 { return 2.0; }
parse  :: proc{as_int, as_f64};

a: int = parse("x");
b: f64 = parse("x");
```

Removing it deletes `candidate_result_fits` and the `expected` parameter of `resolve_overload` and `resolve_operator`. Compound assignment already has the diagnostic this needs: when the selected `+` does not fit, it reports L0417, "`+` produces `X`, which cannot be assigned back to `Y`". The one addition is a note of that kind on L0310 for a call through a group. `s: string = pick(7)` today says only "cannot initialise `string` with `int`", and without the filter `typed: f64 = pick(7)` would say the same, naming neither `integer` nor the fact that a destination never selects. A declaration-site check for members that differ only in their result is not needed: every call through them is an ambiguity that lists both.

*The mode half fixes the direction nothing uses.* Preferring a consuming candidate for a written `move(x)` ahead of tie-breakers 1–4 changes no selection in the corpus. It does fix the review's example, and this default-argument variant, where `b(move(w))` currently picks `ordinary` because `consuming_d` would omit a default:

```odin
ordinary    :: proc(x: int) -> int { return 1; }
consuming_d :: proc(x: move int, y: int = 0) -> int { return 2; }
b :: proc{ordinary, consuming_d};
```

The `Small_Array` shim exists for the other direction. Without `append_one_copied`, `values.append(Copied{1})` — a temporary, with no marker — reaches `append_moved` through the variadic tie-breaker, because the ordinary-mode preference comes last. The proposal keeps that preference last for unmarked temporaries, so the shim stays; "removes the reason for API shims" does not hold for the one shim that exists.

Sending unmarked temporaries to the ordinary member has costs of its own:

- `shared(make_res(1))` with a `move_only` `Res` fails inside `base/runtime` with L0363, "`Res` has no field or member `try_clone`": the temporary is sent to `shared_from_clone`. `move(make_res(1))` is rejected with L0497, so the only working spelling binds a local first.
- With a copyable payload, `shared(Tracked{1})` clones the temporary and then drops the original. `lib_shared` counts that drop.
- Generic code dispatches by instantiation. In a generic `fill(values: inout Small_Array($T, 4), make: proc() -> T)`, `values.append(make())` reaches the copying member for a copyable `T` and the consuming one for a move-only `T`, whose copying members `where is_copyable(T)` removes from the group. With the `+100` copy hook, one source line stores `101` for one instantiation and `1` for the other.

The design already states the rule that avoids all three. [Container insertion](C:/code/loke/design.md:917): "a temporary or `move(x)` transfers into the container, and a borrowed place is copied." [A `move` parameter](C:/code/loke/design.md:4147): a temporary "owns its value already … so there is nothing for a marker to announce." Only in a group does the marker also select ([line 4155](C:/code/loke/design.md:4155): "only a written `move` reaches a consuming member of a group"), and there its two jobs disagree on exactly the arguments where no marker can be written.

*Alternative: ownership selects, not the marker.* Replace tie-breaker 5 with one rule and apply it after the conversion vector, before tie-breakers 1–4:

> An argument that owns its value — a temporary or `move(x)` — prefers a `move` parameter. A borrowed place cannot reach one.

It stays a preference, so an owned argument still reaches an ordinary parameter when no consuming member is viable, and it stays out of the conversion vector. Receivers follow it too: a consuming receiver given an owned receiver ranks exact, like a plain `self`, instead of one rank below it, so the same step decides.

With both changes in the experimental build, the review's example prints `2`, `b(move(w))` picks `consuming_d`, `shared(make_res(1))` compiles and runs, the generic `fill` stores `1` for both instantiations, and each annotated `pick(7)` reports L0310 instead of selecting `real`. Deleting `append_one_copied` then leaves all 20 tests that use `Small_Array` unchanged, in output and diagnostics.

| Cost | Evidence or consequence |
| --- | --- |
| Changed dispatch | 27 calls in the corpus, all temporaries or constants passed to `Small_Array.append`/`insert`, `shared`, or `try_shared`, now move in instead of copying. The full suite fails exactly two programs: `lib_small_array` prints `1` instead of `101` (no clone), and `lib_shared` loses the drop of the cloned-from temporary (`1 1`, `2 0`, `2` become `0 1`, `1 0`, `1`). No `tests/err` fixture changes. |
| Refactoring | Extracting a temporary argument into a local makes it a place, so the call moves to the copying member. Extraction already turns a transfer into a copy for an initialization or an insertion; here it also changes which member runs. |
| Receivers | Over `use :: proc{look, take}` with `look(self)` and `take(self: move)`, `make_box().use()` changes from `look` to `take`. No such group exists in the corpus. |
| Compiler | The counter's definition ([overload.odin:419](C:/code/loke/src/overload.odin:419)), its place in [`tie_break`](C:/code/loke/src/overload.odin:530), and [one receiver rank](C:/code/loke/src/overload.odin:252). The fallback ambiguity note ([line 711](C:/code/loke/src/overload.odin:711)) should again name specialization, as it did before `6bf78d9`. |
| Library | Delete `append_one_copied` ([small_array.loke:139](C:/code/loke/core/container/small_array.loke:139)) and reword the selection comment above `append_moved`. |
| Specification | The tie-breaker list, the [`move`-parameter paragraph](C:/code/loke/design.md:4155), [receiver forms](C:/code/loke/design.md:2032), and [shared construction](C:/code/loke/design.md:5531), where "`shared(value)` clones" then holds for a borrowed value only. |

What it gives up: the member no longer follows from the written marker alone. It follows from whether the argument is a place, which is visible in the same expression.

Found on the way, independent of the rule:

- `shared(r)` for a move-only *place* fails with the same L0363 inside the runtime. `shared_from_clone` and `try_shared_from_clone` lack the `where is_copyable(T)` bound that `Small_Array`'s copying members have. Verified on a local replica: with the bound, the call fails at the call site, and the note on the consuming member says to write `move(...)`.
- Built-in `[dynamic]T` insertion clones where [Container insertion](C:/code/loke/design.md:917) says it transfers. Counting a copy hook, with a fresh array per case: `append` of a temporary clones once, of `move(x)` once, of a place twice (into the variadic pack, then into the array), and `insert` of a temporary or `move(x)` once. A local initialized from a temporary and `m[key] = temporary` clone nothing. The `101` in `lib_small_array` matches the built-in only because both copy.

Sources: [overload resolution](C:/code/loke/src/overload.odin:565), [destination filter](C:/code/loke/src/overload.odin:595), [tie-breakers](C:/code/loke/design.md:2179), [Small_Array groups](C:/code/loke/core/container/small_array.loke:219), [shared construction](C:/code/loke/base/runtime/shared.loke:68).

*Recommendation.*

1. Remove destination filtering as proposed, with the L0310 note for a call through a group.
2. Instead of moving only the written-`move` preference, replace tie-breaker 5 with the ownership rule, make it the first tie-breaker, apply it to receivers, and delete the `Small_Array` shim.
3. Separately, since neither is a rule change: add `where is_copyable(T)` to the two `shared` clone members, and fix the extra clone in built-in insertion.

*Decision (21 September 2026).* Adopted as recommended.

1. Selection reads only the arguments. *Done:* `resolve_overload` and `resolve_operator` no longer take a destination type. A call through a group records the members it chose among, and an L0310 on its result notes the member the arguments selected and any member whose result would fit. Nothing in the corpus changed dispatch; `tests/err/overload_destination` pins the new errors.
2. Ownership replaces tie-breaker 5 and runs first. *Done:* an argument that owns its value counts against a candidate that does not consume it, compared before arity, defaults, and specialization, which move down to 2–5; a consuming receiver ranks exact for an owned receiver. `tests/run/overload_ownership` pins each case above. The one-element copying member of `Small_Array.append` stays, for a reason the analysis missed: through the variadic `append_copied`, a borrowed place is copied twice, into the pack and then into its slot (`1 202` against `1 102` with the `+100` hook). No test appended a place with a copy hook, so the 20-test comparison could not see it. Its comment now gives that reason instead of the dispatch one, and `lib_small_array` pins both halves: a temporary is not copied, a place is copied once.
3. The `shared` bound and built-in insertion's extra clone. *Done:* `shared_from_clone` and `try_shared_from_clone` require `is_copyable(T)`, so `shared(token)` of a move-only place fails at the call (`tests/err/lib_shared_gates`). Built-in `append`, `insert`, `try_insert`, `find_or_insert`, and dynamic literals move a temporary or `move(x)` in and copy a borrowed place or spread element once (`tests/run/container_insert_ownership`). A failed copy of a pack element makes `try_append` return the error and leave the array unchanged (`tests/run/append_pack_clone_failure`).

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

**Follow-up analysis of proposal 3 (21 September 2026)**

The diagnosis holds, but the proposal bundles four changes of different worth. The join and the written form are worth doing; structural identity is not. Probes were compiled with a fresh `lokec` at `753a28f`.

*Only the conditional loses a contract.* The review's `choose` still fails with L0526, and `type_of(a) == type_of(b)` is still `false`. Every other composition keeps the destination's contract and checks after inference that the source fits: assignment, arguments, returns, fields, containers, and generic forwarding. `callback := a; callback = b;` compiles, and so does `callback: A = a if flag else b;` with `A :: type_of(a)`. Without an expected type, [`unify_operands`](C:/code/loke/src/check_expr.odin:1942) erases both branches to their plain signature ([design.md](C:/code/loke/design.md:4787)).

*Structural identity should not be adopted.* Loke already has structural compatibility: a declaration substitutes for another whenever its bounds fit. What the proposal adds is structural identity, which has two costs:

- It cannot be decided when identity is used. Contracts are inferred after every body is checked ([`analyze_program_provenance`](C:/code/loke/src/borrow.odin:933)), but identity is used during checking: `static_assert(A != B)` passes, `when (A == B)` selects its `else` branch, generics instantiate per type, and overloads rank by it. Identity would have to wait for an inference that needs the checked program.
- If it could be decided, identity would depend on bodies. Editing `b` to return `y` would flip `A == B`, change which `when` branch compiles, and split an instantiation. That is the refactoring instability the review sets out to remove.

Nothing needs it either: `type_of` of a procedure appears nowhere in `base`, `core`, or `examples`.

*The join is sound and cheap.* Two bodies with the same result type have summaries of the same shape ([`new_result_provenance`](C:/code/loke/src/borrow.odin:716)), so their union is element-wise with the existing merge helpers. Every call through a contract reads it through [`call_contract_declaration`](C:/code/loke/src/proc_contracts.odin:119) and `result_summary`. A join can therefore be one synthesized contract symbol whose members are the branches' declarations, flattened and sorted so that `b if g else a` has the same type:

- `result_summary` returns the members' union.
- The fixpoint records each member as a dependency of the caller.
- The type printer, the typeid key, and L0645 list the members.

A branch with a plain type still gives the plain type.

*The written form does not work today.* `Chooser :: proc(input: []int, @(escape=none) scratch: []int) -> []int` is the body-independent bound the proposal recommends. Passing the unannotated `a` to it fails with L0310, because escape levels only rise under conversion ([design.md](C:/code/loke/design.md:4809)) and `a`'s unwritten `result` is above `none`. Every implementation must repeat the annotation. The conditional then works already, because the plain signature keeps escape levels.

Instead, let an inferred contract discharge a written `none`: a procedure whose summary never names a parameter converts to a type that marks it `@(escape=none)`, checked after inference like L0645. `stored` and `static` stay written-only, since retention is never inferred. Since proposal 1's decision, an owned argument no longer makes a result borrow it: through plain types, `f(i + 1, view)` and `g(string("xy"), view)` both stay usable. Only view and pointer parameters need the annotation, so the concern in proposal 1's "Callback results" row no longer applies.

*Usage.* A throwaway build compiled the 497 programs in `tests` and `examples`, with the `base` and `core` code they import:

- No conditional unifies two different contracts.
- 11 calls go through a plain procedure type whose result may borrow. All are in tests written for this feature (`m5b_escape_levels`, `m5b_aggregate`, `proc_borrow_contracts`, `m5b_trust_boundary`, `m5b_escape`).
- No library callback returns a borrow of an argument.

The benefit is prospective, so the change should stay small.

| Cost | Evidence or consequence |
| --- | --- |
| Join | A synthesized contract symbol with its members, the union in `result_summary`, member dependencies in [`prov_note_summary_dependency`](C:/code/loke/src/cfg_provenance.odin:3119) and `prov_has_direct_body`, and the members in the type printer, typeid key, and L0645. About 100 lines. |
| Join semantics | A variable initialized from a conditional has the join type, so a later assignment of a procedure outside it reports L0645, as `callback := a; callback = c;` already does. Today it accepts any procedure of the signature. No corpus program does this. Nobody can write the join type; messages show it as `a \| b`. |
| Written form | [`proc_escape_weakens_to`](C:/code/loke/src/semantic.odin:953) allows `result` to `none` from a contract-bearing source, [`record_proc_contract_check`](C:/code/loke/src/proc_contracts.odin:41) records it, and `check_proc_contracts` rejects a summary that names the parameter. About 30 lines. Whether an implementation fits a published type then depends on its body, as it already does for a `type_of` contract. A group whose members differ only in a callback parameter's escape levels could become ambiguous; none exists. |
| Diagnostics | L0645 names the parameter that breaks the bound. An L0526 through a plain type gets a note at the call: its type states no bound, so the result may borrow any argument, and `@(escape=none)` on that parameter would exclude it. Both run after inference, where summaries exist; a type printed during checking cannot show them. |
| API documentation | There is no documentation generator, so there is nothing to mark. |

*Recommendation.*

1. Keep declaration identity; do not make contract types structural.
2. Let an inferred contract satisfy a written `@(escape=none)`, and recommend written signatures for public callback types. `type_of` remains for bounds the written form cannot express, such as one field of an argument or an allocator region.
3. Join contracts at a conditional instead of falling back to the plain signature.
4. Name the parameter in L0645 and add the plain-call note to L0526. Skip the documentation marker.

Items 2–4 are independent. Item 2 matters most to libraries; item 3 meets the acceptance row "select between callbacks with identical bounds".

*Decision (21 September 2026).* Adopted as recommended.

1. Declaration identity stays: `static_assert(A != B)` still holds for two declarations with equal bounds.
2. An inferred contract meets a written `none`. *Done:* `proc_escape_weakens_to` lets `result` convert to `none` from a contract-bearing source, and `check_proc_contracts` rejects the conversion with L0645 when the summary may return that parameter ("the result of `second` may borrow `b`, which … marks `@(escape=none)`"). An unannotated `a` now passes as `Chooser`, alone or through `a if flag else b` with `Chooser` expected. `tests/err/m5b_escape_levels` pinned the old rule with `honest`, which never returns `scratch` and now converts; it now pins a plain source (still L0310) and a source that returns `scratch` (L0645).
3. A conditional joins contracts. *Done:* the join is a synthesized contract whose members are the branches' declarations, flattened and sorted, printed `[result contract: a | b]`. `result_summary` returns the members' union entry by entry, so field paths and allocator regions stay precise, and the fixed point depends on each member. The review's `choose` compiles; a join with a branch that returns `local` still reports L0526, and assigning a procedure outside the join reports L0645.
4. Diagnostics. *Done:* L0645 notes which parameter the source may return that the contract excludes, and notes every member of a joined contract. An L0526 whose borrow was created in the arguments of a call through a plain type notes that call, its type, and `@(escape=none)`. No documentation marker.

`tests/run/proc_contract_joins` pins the joins (including nested, reordered, forwarded, field-path, and allocator-region cases) and the written form; `tests/err/proc_borrow_contracts` pins the new errors and notes.

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

**Follow-up analysis of proposal 4 (22 September 2026)**

The aim holds and follows from the first three decisions. But the operation the proposal introduces already exists, its header rule cannot hold both ways, and the loan it relies on — "the source stays exclusively borrowed for the view's actual lifetime" — is not what the checker enforces today, even in a header. Probes were compiled with a fresh `lokec` at `3a165dc` and run where they compiled. Usage was counted over `tests/`, `examples/`, `base/`, and `core/`, where every `foreach` header fits on one line.

*Iteration loans have holes today.* Each program below compiles, and design.md already rejects it, so these are conformance gaps rather than open rules:

```odin
values := [dynamic]int{1, 2, 3};
foreach (&x in values) {
    values.append(4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20);
    x = 99;      // writes the freed buffer
    break;
}
fmt.println(values[0], values.len());   // 1 20
```

- A loop binding is its own root ([cfg.odin:748](C:/code/loke/src/cfg.odin:748)). The source's loan is kept live by the iterator's next step, so without the `break` the append is L0512; with it, nothing keeps the loan live while `x` is used. The lending form has the same gap: `&item` names the source ([cfg_provenance.odin:1903](C:/code/loke/src/cfg_provenance.odin:1903)) but `inner := item[:]` does not, so `values.clear()` before reading `inner[0]` compiles and reads freed memory. `Small_Array` shows it through `iter_mut` too. design.md: the loan "lasts for the whole statement" ([foreach statement](C:/code/loke/design.md:3718)), and the source "cannot be mutated or invalidated while the traversal, or a pointer taken from it, is live" ([Borrowing iteration](C:/code/loke/design.md:2459)).
- Nothing written through a `[]mut` carrier is checked: [`prov_place_of`](C:/code/loke/src/cfg_provenance.odin:1706) has no place for an index through a slice. In `bump :: proc(xs: []mut [dynamic]int)`, `foreach (&x in xs) { inner := x[:]; xs[0] = {}; inner[0] = 99; }` compiles, and the IR drops the element's buffer before the store through `inner`. Without a loop, `x := &mut xs[0]; inner := x^[:]; xs[0] = {}; inner[0] = 99;` compiles too; over a local it is L0511.
- Not specific to iteration: an `append`, `clear`, or whole assignment inside a loop that loops is not checked against a borrow used after the loop. `p := &mut values[0]; for (i := 0; i < 1000; i += 1) { values.append(i); } p^ = 99;` compiles and leaves `values[0]` at 1. The invalidation reaches the loop head through the back edge, block entry ORs it in ([borrow.odin:1341](C:/code/loke/src/borrow.odin:1341)), and the live-loan walk then skips the loan at the append itself ([borrow.odin:964](C:/code/loke/src/borrow.odin:964)). A write or an `inout` argument in the same position is caught. This is also what lets design.md's own `first = &item` example read freed memory after a later loop of appends.

A stored mutable view is exactly a loan that has to outlive the iterator's steps, so these repairs come first, as proposal 1's miscompile did. The review's open question — whether sibling mutable views such as `left := source[0:3]; right := source[1:4]`, or `copy := xs`, are separate loans — sits next to the carrier gap and is still open; both forms still compile.

*The mutable view exists; the adapter drops it.* Slicing a mutable place gives `[]mut T` ([design.md](C:/code/loke/design.md:684)), and a `[]mut T` is already iterable by reference as a plain value: from a local, a value parameter, a call's result, or a by-value argument of a generic function bounded by `Mutable_Iterable`. The capability is lost where an adapter wraps it:

```odin
view := values[:];
foreach (&v in view) { v += 1; }   // compiles
back := values[:].reversed();
foreach (&v in back) { v += 1; }   // L0457: `Reversed([]mut int)` needs `Mut_Iterator` and `iter_mut`
```

`Reversed([]mut int)` already names the capability, so no `mutable()` operation is needed. The adapter has to keep what its source's type has.

*A user-defined view cannot be a mutable value.* `Row :: struct { cells: []mut int }` implements the protocol as design.md specifies, with `iter_mut :: proc(self: inout Row)`. `foreach (&c in row)` is then L0358 for a value parameter and L0359 for `Row{storage[:]}`, although the capability is in the field's type. `[]mut T` escapes the place requirement only because slices are special-cased ([iterate.odin:775](C:/code/loke/src/iterate.odin:775)).

*Two mechanisms say "mutable", and `&` reads one.* "Element bindings" says an `&` leaf must land on a `Yield_Mutable` location, but the `&` path never reads `Yield`: it asks for `Mut_Iterator`, `iter_mut`, and `next -> Option(^mut Element)` ([iteration_mutable.odin:54](C:/code/loke/src/iteration_mutable.odin:54)). An iterable whose iterator declares `Yield :: Yield_Mutable` can be read, and `&` over it is L0457. An iterator declaring `Yield :: (key: Yield_Borrowed, value: Yield_Mutable)` can be read through `iter`, and `key, &value` through `iter_mut` is L0456, since one `^mut Element` cannot be a record. So `Yield_Mutable` has no effect, and a mutable record yield — which `indexed()` over a mutable traversal is — cannot be written by a user or synthesized by the compiler. A header gets one only by discarding the adapter ([`peel_resolved_adapter`](C:/code/loke/src/iteration_adapters.odin:10)) and binding a counter beside the element.

*The proposed header rule contradicts itself.* In `foreach (&v, i in values.indexed())`, either `values.indexed()` keeps meaning `values[:].indexed()`, and the header grants what `view := values.indexed()` lacks, or the header form stops compiling.

*Usage.* Eleven `&` headers reach through an adapter or view: nine in `tests/run` and two in error fixtures. `examples`, `base`, and `core` contain no `&` header at all. No program stores an adapter over a mutable view, and `Mutable_Iterable` has one user, a test. As with proposal 3, the benefit is prospective.

*Alternative: the capability comes from the source's type, and `&` reads `Yield`.*

1. `&` reads the mutable iterator's `Yield`, and an `&` leaf must land on a `Yield_Mutable` part. An iterator behind `iter_mut` that declares no `Yield` lends its `^mut Element`, so every existing one keeps its meaning, and `Mutable_Iterable` requires `Iterator(Self.Mut_Iterator, Self.Mut_Iterator.Item)`, as `Iterable` does. `indexed()` over a mutable traversal is then its ordinary `{value: <source's>, index: Yield_Owned}` yield.
2. A type whose `iter_mut` takes a value `self` is a mutable view: `&` accepts any value of it, as it accepts a `[]mut T` now. `self: inout` still means a container, which needs a mutable place. `Mutable_Iterable` states `iter_mut` as a call requirement rather than a slot, so both receivers meet it; relaxing slot matching instead would let a value receiver meet every `inout` slot and silently drop its writes.
3. `indexed()` and `reversed()` over a mutable view are mutable views, held by value and carrying the source's exclusive loan. Over a container they stay read views. `values[:].reversed()` then stores, passes, and meets `Mutable_Iterable` like `values[:]`.
4. `&` asks the iterable, and no longer reaches through a call to a root. `foreach (&v, i in values.indexed())` becomes a diagnostic naming `values[:].indexed()`, or `xs.slice().indexed()` for `Small_Array`; proposal 7's suggested wording fits it. A map's values are mutated with `foreach (key, &value in table)` — the form `da18abd` dropped, which ["foreach statement"](C:/code/loke/design.md:3715) still shows — as a record yield of the map's own `iter_mut` under item 1. `table.values()` stays a read view.

The rule is then one sentence: an `&` leaf asks the iterable for mutable traversal; a mutable place gives its container's, and any other value gives one if its type is a mutable view.

*Fit with the earlier decisions.*

- Proposal 1 decided that reference behaviour is written in the type. Items 2 and 3 carry that to views and adapters, and read a value receiver as that decision does: it lends only what the value holds, which for a view is its source. A `mutable()` operation would be a second spelling of what `x[:]` already writes in the type.
- Proposal 2 decided that selection reads only the arguments. Item 4 is the same for a loop: the header stops changing what `values.indexed()` means, and whether the iterable is a place decides, as whether an argument is a place decides under the ownership rule. Keeping the re-rooting is the loop's version of destination filtering.
- Proposal 3 made a conditional keep its callbacks' contracts, with the written form as the stable bound. Item 3 makes a local keep its adapter's capability, with `x[:]` as the written form. Its conclusion about prospective benefit applies too, which is why the alternative adds no operation, no stored mutable map view, and no new iterator protocol.
- The difference in kind: proposals 1–3 relaxed or kept borrow checks, and the repairs above tighten them where design.md already requires it. Their migration is unmeasured.

| Cost | Evidence or consequence |
| --- | --- |
| Prerequisites | The three repairs above, and a decision on sibling mutable views. Each rejects programs that compile now. |
| Checker | `check_mutable_protocol_foreach` reads `Yield` and binds a record item; `check_foreach_pattern` allows `&` by descriptor instead of by the counter special case; [`iteration_adapter_member`](C:/code/loke/src/iteration_adapters.odin:51) adds `iter_mut`, and `iter_mut_reverse` for `reversed()`, when the source's `iter_mut` takes a value; the contributed `[]mut T` `iter_mut` takes a value; `peel_resolved_adapter` peels read loops only. Deleted: `direct_mutable_map_values_root`, the map-values branch of `ensure_mutable_iteration_members`, and the stored map view L0457. |
| Emitter | `emit_protocol_foreach` binds a record item with mutable leaves as it binds borrowed ones, and its counter branch goes. The `key, &value` branch of [`emit_map_foreach`](C:/code/loke/src/emit_llvm_iteration.odin:400) has been unreachable since `da18abd` and is the lowering item 4's map form needs. |
| Provenance | An adapter over a mutable view must carry the exclusive loan; today `r := values[:].indexed(); n := values.len();` compiles. A mutable record yield already ends before the next step, because a result carrying a mutable borrow keeps naming the iterator ([cfg_provenance.odin:3180](C:/code/loke/src/cfg_provenance.odin:3180)). |
| Compile-time evaluation | It cannot slice a local, so `cells[:].indexed()` does not evaluate, and the indexed mutable loop in `tests/run/eval_foreach` needs a hand-written counter. |
| Migration | The nine `tests/run` headers, and the fixtures `foreach_elements` (a header expected to compile), `mutable_reverse` (L0460), and `mutable_stored_view` (L0457). A user container with only `iter_mut` loses `indexed()` and `reversed()` under `&`; none exists outside tests. |
| Specification | "Iteration protocol" (the mode rule and the root paragraph), "Iteration adapters" (the stored-adapter paragraph), "Element bindings", "By-reference iteration", and the catalogue's `Mutable_Iterable` and its built-in satisfaction list. |

What it gives up is the short header form. If that costs too much, keep item 4's header form as documented sugar for `values[:].indexed()` and have the stored form's diagnostic name that spelling. Items 1–3 stand without it, compile-time evaluation keeps its loop, and "introduce a local for an adapter" then holds for every spelling except the sugar.

*The declaration half of the proposal.* `Item` is already derived from `next`, and a declared one that disagrees is L0694 ([iteration_yield.odin:156](C:/code/loke/src/iteration_yield.odin:156)). `Iterator` and `Mut_Iterator` could be derived from `iter` and `iter_mut` the same way, saving a line per type and replacing the vague L0456/L0457 a mismatch gets now; that is worth doing only alongside item 1. `Element` should stay written: it is the public element type, and deriving it would tie it to the yield descriptor.

*Found on the way*, independent of the rule:

- design.md says `Small_Array` and `Enum_Array` lend their elements, move-only ones included ([Borrowing iteration](C:/code/loke/design.md:2448), [catalogue](C:/code/loke/design.md:2865)). Both library iterators copy (`next -> Option(T) where is_copyable(T)`), so `foreach` over a move-only `Small_Array` is L0456.
- A comment above `Enum_Array_Iterator.next` offers `&value` ([enum_array.loke:90](C:/code/loke/core/container/enum_array.loke:90)), but `Enum_Array` has no `iter_mut`.
- `Small_Array` has no `iter_mut_reverse`, so `foreach (&v in xs.reversed())` is L0460.
- A read of `values` while a `values[:]` is live reports the same L0511 twice.

*Recommendation.*

1. Repair the three loan gaps first, each as its own change, and settle sibling mutable views with the carrier one. The loop gap is not about iteration and is the most urgent.
2. Adopt items 1–3 instead of a `mutable()` operation.
3. Adopt item 4. Keeping the header form as sugar is the fallback if the short spelling matters more than the acceptance row.
4. Derive `Iterator` and `Mut_Iterator` only together with item 1.
5. Separately, make `Small_Array` and `Enum_Array` lend, or correct design.md.

*Decision (22 September 2026).* Adopted as recommended, starting with the loan repairs.

1. Invalidation inside a loop. *Done:* the solver now keeps a second set of loans, those ended on every path, merged by intersection, and conflict reports skip only those. An invalidation that reaches its own loop head through the back edge therefore still meets the loan the entry path brings. The set ended on some path still drives the carrier rules and `free`. No corpus program relied on the hole; `tests/err/loop_invalidation` pins `append`, `clear`, and whole assignment in a looping body, and design.md's `first = &item` followed by a loop of appends.
2. Loop element loans. *Done:* a lent or mutable loop binding now records the loop's loans of its source, and every access through the binding, and every borrow taken from it, uses them too. So `x` after a `break` keeps the mutable loan live, and `item[:]`, `item.field` views, and `self: ^` results carry the source as `&item` already did. `&x` on a mutable binding still borrows the binding as well, so it ends with the step. Switch payload bindings over a place get the same treatment. No corpus program relied on the hole; `tests/err/loop_element_loans` pins the mutable, lent, escaping-view, and `Small_Array` cases, and a loop whose element's last use precedes the change stays accepted. "foreach statement" said the loan lasts for the whole statement; it now says the loan lasts while the traversal, an element, or anything taken from one is used, which is what the checker does.
3. Mutable carriers, with sibling views settled as **reborrows**. *Done:* any carrier derived from a named mutable carrier — a copy, a reslice, `&mut xs[i]`, a record field it is stored in, or a `foreach` over it — reborrows it, and the source is suspended (L0641) until the last use of the reborrow or of anything reborrowed from that. This extends the existing read-only reborrow of "Weakening and reborrows" (renamed from "Weakening and read-only reborrows") to mutable destinations, and makes the suspension check follow chains, so `x := &mut xs[0]; inner := x^[:]; xs[0] = {}` is rejected through `inner`. The review's `left := source[0:3]; right := source[1:4]` and `copy := xs; …; xs[1] = 8` are now errors, and `foreach (&x in xs)` over a `[]mut` parameter is exclusive, as design.md said. Region providers are not reborrowed by a copy. Storing a carrier into itself suspends nothing. The corpus needed one fixture change: `alias := q` of a `^mut int` followed by `free(q)` now also reports the suspended `q` (`m5b_borrows`). `tests/err/carrier_reborrow` pins the cases and a sequence of reborrows that each end before the source is used again. Two diagnostic duplicates went with it: a `self: ^` receiver no longer records its read twice (the doubled L0511 under "Found on the way"), and one expression gets at most one borrow diagnostic when two rules meet the same mistake.
4. Items 1–4 of the alternative. *Done:* `check_mutable_protocol_foreach` reads the mutable iterator's `Yield` (`Yield_Mutable` when none is declared), binds a record item through its projection, and an `&` leaf must land on a `Yield_Mutable` part (`report_immutable_ref_leaf` names a read-only key, a counter, or a record). An `iter_mut` taking no `inout` receiver makes its type a mutable view that any value of it can be traversed by reference as; the contributed `[]mut T` `iter_mut` takes a value, and `Mutable_Iterable` states `iter_mut` as a call on an `inout` value, with `Iterator(Self.Mut_Iterator, Self.Mut_Iterator.Item)`. `indexed()` and `reversed()` over a mutable view hold it by value, get `iter_mut` (and `iter_mut_reverse` for `reversed()`), and are mutable carriers, so a stored `values[:].indexed()` keeps the exclusive loan that `values[:]` took; a mutable `indexed()` yield ends before the next step like any mutable yield. A `&` header peels an adapter only when it is a mutable view, so `values.indexed()` and `table.values()` under `&` are L0457 with a note naming the explicit spelling. A map is mutated as `foreach (key, &value in table)` through its own `iter_mut`, whose `Yield` is `(key: Yield_Borrowed, value: Yield_Mutable)`; the map-values mutable iterator, `direct_mutable_map_values_root`, and `mutable_foreach_root` are gone, and `emit_map_foreach` binds both loop kinds through one path. Migration: nine `tests/run` headers (`x[:].indexed()`, `xs.slice().indexed()`, `grown[:].reversed()`, `_, &value in table`), `eval_foreach` counts its own steps because compile-time evaluation has no slices of locals, and the fixtures `foreach_elements`, `iteration_and_membership`, `mutable_stored_view`, `mutable_reverse` (its `Source` is now a view, so the missing `iter_mut_reverse` is what L0460 reports), and `readonly_iteration` (`source.reversed()` over a `[]mut` is now a mutable reborrow). `tests/run/mutable_views` and `tests/err/mutable_views` pin the new behaviour. design.md's "Iteration protocol", "Element bindings", "Iteration adapters", "By-reference iteration", and the catalogue now describe it.
5. Derived iterator types. *Done:* `ensure_iterator_members` makes `Iterator` and `Mut_Iterator` the result types of `iter` and `iter_mut` when a type does not declare them, as `Item` already was, and a declared one that disagrees is L0694 naming both types. `Small_Array`, `Enum_Array`, `Bit_Set`, and their iterators no longer declare them. `tests/run/derived_iterator` and `tests/err/iterator_mismatch` pin it.
6. Library lending (recommendation 5). *Done:* `Small_Array_Iterator` declares `Yield_Borrowed` and hands back `^T`, so `foreach` over a move-only `Small_Array` works and no traversal copies; `Enum_Array_Iterator` lends `(key: E, value: ^T)` with the key owned, and `Enum_Array` gained `iter_mut`, so `foreach (key, &value in array)` works as its comment promised. design.md already described both. Four tests that printed a lent value or a `next()` result read through the pointer now; `where_excludes_member` keeps its where-excluded `next` case with an iterator of its own. `tests/run/library_lending` pins it.

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

**Follow-up analysis of proposal 5 (22 September 2026)**

The order is right, and the closure lowering it names is the one [comments.md](C:/code/loke/comments.md:431) already chose. But the middle step is already done, and the first needs no language change for the one API that uses it. The proposal also misses two things. After proposal 1's decision, a mapper that wraps its argument has to consume it. And a record can replace a procedure only where the API fixes the callable's result type. Probes were compiled with a fresh `lokec` at `22d26a4` and run where they compiled. A throwaway tree with items 1 and 2 below, without the diagnostic change, ran the full test suite. Usage was counted over `tests/`, `examples/`, `base/`, and `core/`.

*Inference through procedure types already works.* Since `aaa3ff8` (19 September), a `$` name inside a `proc(...)` parameter type binds from the argument ([generic.odin:811](C:/code/loke/src/generic.odin:811), `tests/run/generic_proc_type_pattern`). With `apply :: proc(x: $T, f: proc(value: T) -> $U) -> U`, `apply(21, double)`, `apply(21, label)`, and a procedure literal all infer `U`. `map_error` is older (`4d6ef7a`, 14 September) and still takes `$F: type` ([runtime.loke:138](C:/code/loke/base/runtime/runtime.loke:138)). Its comment and [Changing error domains](C:/code/loke/design.md:5259) both say the nested parameter is not inferred, and section 7's table repeats it. Writing `f: proc(error: E) -> $F` makes `parse(text).map_error(to_app) or_return` compile and run. Modes are still checked once the pattern binds: a `proc(move Tracked) -> int` passed for `proc(value: T) -> $U` is L0392, naming both types.

*The mapper borrows what it wraps.* After proposal 1's decision, a value parameter owns nothing, so `to_app :: proc(error: Detail) -> App_Error { return .detail(error); }` clones its argument. With a `+100` copy hook, `fail().map_error(App_Error, to_app)` delivers `101`, drops `1`, and warns L0507 at the mapper. A `switch` that consumes the result moves `1` through. A move-only error has no mapper at all: a consuming one is rejected on mode (L0392), and a borrowing one cannot build the variant (L0503). The ponytail note on `map_error` records this, and proposal 6's `Rejected(T, E)` is such an error. `map_error` already passes `move(payload)`, so the fix is the mapper's type, `f: proc(error: move E) -> $F`. In the throwaway tree, `wrap :: proc(error: move Detail) -> App_Error { return .detail(move(error)); }` delivers `1` with one drop. A `move_only` token inside `Full { rejected: Token }` maps and drops once. An enum mapper then writes a `move` that changes nothing at run time.

*A variant constructor is a consuming mapper.* The natural type of `App_Error.parse` is `proc(payload: move Parse_Error) -> App_Error`: a temporary or `move(x)` transfers, as in [direct construction](C:/code/loke/design.md:1522). It fits the consuming `map_error`; today's borrowing one would make it clone. Two limits already hold in the compiler, and both follow from proposal 2's decision. A procedure group is not a value (L0396, "can only be called"), and neither is an uninstantiated generic (L0431), so nothing picks a member from the parameter it is passed to. A constructor value therefore names its union, `App_Error.parse` rather than a `.parse` resolved from the destination, and a generic union names its instance, `Option(int).some`. A stored constructor called with a place needs `move(x)` (L0501, even for an enum), where `App_Error.parse(x)` clones; the difference errs toward no copy. Today `App_Error.parse` without a call is L0425 ([union.odin:356](C:/code/loke/src/union.odin:356)).

*One API takes the `call` convention.* `slice.sort_by(values, less)` is L0444, "has no method `call` with this signature", and so is a procedure literal. `sort_by` is the only API that takes a `call` callable ([slice.loke:21](C:/code/loke/core/slice/slice.loke:21)). In the throwaway tree, `sort_by :: proc{sort_by_comparator, sort_by_procedure}` sorts with plain procedures and literals. The procedure member wraps its argument in a private `Procedure_Comparator(T)` record whose `call` forwards to a `proc(left, right: T) -> bool` field. Record comparators and `dyn slice.Comparator(int)` are unchanged. The wrapper is ordinary Loke, so every analysis applies as written: a procedure comparator that appends to the global being sorted gets the same L0512 as a record comparator.

The cost is the diagnostic. A non-comparator becomes L0392, whose note says only "its `where` bounds are not satisfied". A silent probe returns from [`check_where_clauses`](C:/code/loke/src/generic.odin:1650) before the interface failure is reported. Keeping that failure as the instance's rejection message would restore the missing-`call` wording in the note, for any candidate a bound filters out.

The language-wide alternative is a contributed `call` on every procedure type. It keeps `sort_by` one declaration with its L0444, and lets procedures meet every `call` interface, a user's included. It would be a [`Synth_Kind`](C:/code/loke/src/iterate.odin:49) like `Dyn_Forward`. But a forwarder without a body lacks what the wrapper gets for free: a result summary, which would be the procedure type's contract shifted past `self`, and a place in [global write effects](C:/code/loke/src/global_effects.odin:184), which reads bodies, as an indirect call of that type. The library cannot provide it with an `impl`: `impl proc(left, right: $T) -> bool` is L0406, and an `impl` on a concrete alias works but covers one signature.

*What unification still lacks.* Records already cover the uses the proposal reserves for closures. `$C where Comparator(C, T)` is the static form, and `(dyn slice.Comparator(int))(&order)` sorts through an erased borrow. A body-local `By_Weight { weights: []int }` captures a borrowed slice. But `Comparator` fixes its result as `bool`. A generic API can name a callable's result only by matching a `proc(...)` type, which a record does not have. So neither a record nor a closure lowered to one can be a `map_error` mapper. A convention that covers mappers needs a callable's result type derived from its `call`, as proposal 4's decision derives `Iterator` from `iter`. The proposal does not list this, and nothing needs it until closures do.

*Usage.* `sort_by`: six calls in four tests. `map_error`: three calls, all in `result_map_error`. `call` methods: four records, all in tests. `examples`, `base`, and `core` call neither. The third callback shape is `fmt.Writer` and `log.Logger`, which pair a `proc(state: rawptr, ...)` with its `state` so a handle can be stored without a type parameter; `log` keeps the selected one in a global. Neither a generic nor a borrowed `dyn` expresses that. It is the escaping erased ownership that the proposal keeps separate. As with proposals 3 and 4, the benefit is prospective.

*Alternative: settle the convention, build what has a caller.*

1. `map_error :: proc(self: move, f: proc(error: move E) -> $F) -> Result(T, F)`. The target type is inferred, and the mapper owns the error.
2. `slice.sort_by` accepts a plain procedure through the library member, and the note for a where-filtered candidate names the requirement that failed.
3. A payload variant written `U.name` without a call is a procedure value of type `proc(payload: move P) -> U`.
4. Record the convention for closures. A callable is a value with a `call` method. A procedure meets it through a contributed `call`, and a closure is a body-local record. A variable-result callable's result is derived from its only `call`. Item 2's member stays correct after that, since its more specific pattern wins, and can then be deleted.

```odin
value := parse(text).map_error(to_app) or_return;          // item 1, over a one-line `move` mapper
value := parse(text).map_error(App_Error.parse) or_return;  // item 3, the proposal's form
```

*Fit with the earlier decisions.*

- Proposal 1 decided that a value parameter owns nothing and that reference behaviour is written in the type. Item 1 applies that to the mapper: a mapper that keeps its argument says so with `move`. Item 3's constructor gets the consuming type for the same reason. "Ownership must remain the same as direct variant construction" holds for what `map_error` passes. It cannot hold for a stored constructor given a place; that call is rejected instead of cloning.
- Proposal 2 decided that selection reads only the arguments. Callbacks already agree, since neither a group nor a generic is a value. Item 3 keeps that by requiring the union's name. The `sort_by` group selects by the argument's shape. `map_error` hands an owned payload to a consuming parameter, as the ownership rule prefers.
- Proposal 3 kept declaration identity and recommended written callback types. A comparator returns `bool`, and such procedures share one plain type (`type_of(less_a) == type_of(less_b)` holds), so neither path multiplies `sort_by` instances. A consuming mapper does carry a contract, the region of what it moves (`[result contract: to_app]` in the L0392 above). `map_error` writes its parameter type, so that contract converts to the plain one, as for any written callback type.
- Proposal 4 contributed protocol members to built-in types and derived `Iterator` from `iter`. A contributed `call` and a derived callable result are the same two moves for procedure types and callable records. Item 4 records them for when closures need them. Proposal 4's conclusion, no new operation or protocol for a prospective benefit, is why items 1 and 2 stay in the library.

| Cost | Evidence or consequence |
| --- | --- |
| Library | `map_error`'s signature and comment. `sort_by` becomes a group with about a dozen lines of private wrapper. No compiler change for items 1–2. |
| Migration | Two cases in the throwaway suite changed. `result_map_error` fails to compile until its three calls drop `App_Error` and `to_app` takes `move`; its output is then unchanged. `lib_sort_gates` gets L0392 for L0444. The `tests/ll` sort fixture did not move. |
| Diagnostics | Keep the interface failure as the rejection message, about 20 lines around `instantiate_generic`. Messages about the procedure path name the private member: the L0512 above reads "cannot be modified by `sort_by_procedure(int)`". |
| Constructor values | A `Synth_Kind`, one symbol per union and variant used as a value, a body that builds the variant, [`set_synth_result_summary`](C:/code/loke/src/borrow.odin:803) on the payload, a compile-time evaluation case, and the value-position path that reports L0425 today. About 100 lines. |
| Contributed `call` (item 4, not now) | A `Synth_Kind`, an entry in [`ensure_contributed_members`](C:/code/loke/src/impl.odin:317), a forwarding body, the shifted contract, and the indirect-call effect. About 150 lines. |
| Specification | "Changing error domains" (the example and the inference sentence), "Sorting slices" (a procedure comparator), "Constructing a variant" (item 3), and comments.md's closure paragraph (item 4). |

What it gives up: a mapper spells `move` even for an enum, and until item 4 a record cannot be passed where `map_error` expects a procedure.

*Found on the way*, independent of the rule:

- The stale inference sentence appears in three places: design.md, the `map_error` comment, and section 7's "Infer nested procedure type parameters". The review's revision `d7c0dc8` already contained `aaa3ff8`.
- "A callable object exposes an ordinary method such as `call` or `evaluate`" ([Indexing and slicing](C:/code/loke/design.md:2258)) leaves the name open. A convention needs `call`.
- L0507 on a wrapped value parameter advises "take a pointer or `shared(T)`" ([lifecycle.odin:664](C:/code/loke/src/lifecycle.odin:664)). When the cloned place is a value parameter, the useful advice is to take it `move`.

*Recommendation.*

1. Adopt item 1 now, and fix the stale sentence with it. It is a library change, removes the target type, and gives move-only errors a mapper, which proposal 6 will need.
2. Adopt item 2 with the where-bound note, instead of a contributed `call`.
3. Adopt item 3 after item 1, as its own change: it is the proposal's example, and the one mapper that never clones. If the language should not grow, item 1 alone already gives `map_error(to_app)`.
4. Write item 4 into comments.md's closure paragraph rather than building it. The contributed `call` and the derived result type belong to the closure design.

*Decision (22 September 2026).* Adopted as recommended, starting with item 1.

1. `map_error` infers its target and owns the error. *Done:* the signature is `map_error :: proc(self: move, f: proc(error: move E) -> $F) -> Result(T, F)`. A mapper moves a managed or move-only error into the new variant, so the ponytail note on `map_error` is gone. In design.md, "Changing error domains" drops the written target and the sentence saying it cannot be inferred. "Specialization" now documents procedure-type shapes, which `aaa3ff8` implemented without specifying. `tests/run/result_map_error` drops `App_Error` from its three calls and gives `to_app` a `move` parameter, with unchanged output. It adds a managed error that moves through uncloned, and a move-only error whose token reaches the caller. `tests/err/result_map_error` pins what code written for the old signature gets: L0392 naming the missing `move` for a borrowing mapper, and L0392 for a written target type. Section 7 of this review is left as written.
2. `sort_by` takes a plain procedure. *Done:* `sort_by :: proc{sort_by_comparator, sort_by_procedure}`. The procedure member wraps its argument in a private `Procedure_Comparator(T)` whose `call` forwards to it, so procedures and literals sort, and every analysis applies to the wrapper as written. A group member that a false `where` bound filters out now says which bound. A silent probe records the failing clause on the instance, and the L0392 note gives the interface and its failed requirement ("`No_Comparator` does not satisfy `Comparator(No_Comparator, Opaque)`: `No_Comparator` has no method `call` with this signature"), or quotes any other bound ("its bound `N > 2` does not hold"). A direct call still reports L0444 with its requirement note. design.md's "Sorting slices" and comments.md describe the procedure path. `lib_slice` sorts with a procedure and a literal. `lib_sort_gates` pins the new note and a procedure with the wrong element type. `tests/err/overload_false_bound` pins both kinds of note in user groups.
3. Variant constructors are values. *Done:* outside a call, `U.name` of a payload variant resolves to a synthesized procedure of type `proc(payload: move P) -> U` (`Synth_Kind.Variant_Construct`, one per union and variant), whose body builds the variant from the owned payload. `parse(text).map_error(App_Error.parse)` compiles, and a managed or move-only error moves through without a clone. Compile-time evaluation calls a constructor like any procedure value. It now evaluates a selector naming a procedure, so `Type.method` values work there too. The contextual `.parse` stays an error, and where a procedure type is expected L0425 now says to write `App_Error.parse`. A call through a procedure value that passes a place to a `move` parameter printed "`this parameter` is a `move` parameter"; the fallback is no longer quoted as a name. design.md's "Constructing a variant" documents the constructor, and "Changing error domains" uses it. `tests/run/variant_constructor` and `tests/err/variant_constructor` pin it, and `move_parameter_indirect_place` pins the corrected wording.
4. The convention is recorded, not built. *Done:* comments.md's callback section now states it — a callable is a value with a `call` method — and lists the three steps that complete it: a contributed `call` on every procedure type, a callable's result type derived from its only `call`, which a variable-result API such as `map_error` would need before it could take a record, and closure syntax as a shorthand for the same record and method, which is what would give the first two a caller. A callable that outlives its scope stays separate, and the `rawptr` state of `fmt.Writer` and `log.Logger` is why. design.md's "A callable object exposes an ordinary method such as `call` or `evaluate`" now names `call`.

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

*Recommendation.*

1. Adopt the checked numeric conversion. It is the one bullet with no workaround: a written `To(value)` wraps by specification, so validating input has no spelling at all today.
2. Adopt the streaming loop, as documentation plus one walk written in the idiom. Half of it exists already — `examples/streaming.loke` is the same shape over `file.read` — and the directory reader, the one source that needs it, is described by a comment that is now wrong.
3. Skip recoverable consuming insertion. Check-then-act already covers it and is exact: `Small_Array` documents `space()`/`is_full()` for this, a dynamic array has `try_reserve`, and `contains` precedes `find_or_insert`. `Rejected(T, E)` buys one call instead of two and puts a new move-only error shape into every insertion API.
4. Skip `split_at_mut` until a consumer exists. Nothing in `core` or `base` splits mutable storage — sorting is the runtime introsort — and it cannot be written in the library, since `core:unsafe` has no slice-from-a-pointer member. Two sibling mutable views of one root are also exactly what proposal 4 just made an error, so this would be a hole in a rule three commits old.
5. Skip `Box(T)`. The whole library contains one `new`, inside `shared`. `shared(T)` covers shared ownership and `[dynamic]T` covers arrays, and comments.md's "Owning runtime polymorphism" already holds the question with the list of what a proposal must settle.

*Decision (22 September 2026).* Adopted as recommended: items 1 and 2 built, items 3 to 5 declined with the reasons above.

1. A checked integer conversion. *Done:* `math.to(To, value) -> Option(To)` over `interfaces.Integral` and `interfaces.Ordered`, twelve lines in `core:math` and no compiler change. The check is a round trip plus a sign comparison, because the round trip alone always succeeds between two types of the same width — `i32(-1)` converts to `u32` and back unchanged, and only the sign test rejects it. `Integral` is what excludes floats, whose conversions round rather than wrap; nothing in the body needs its bit operations. design.md's "Type conversion" names it beside the wrapping rule it exists to escape, as the integer twin of `Enum.from_int`, which is the precedent for a validating conversion answering an `Option`. `tests/run/lib_math_bits` pins both same-width rows, both narrowing directions, and the identity case.
2. The fallible streaming loop, documented and written down once. *Done:* design.md's "Streaming a fallible source" states why a `Result(Option(T), E)` source is not an iterable — `foreach` has nowhere to put the error — and gives the loop: `or_return` for the failure, a switch for the end, a borrowed yield used inside the arm, and `switch (move(entry))` for a move-only payload. No new control-flow syntax. `core:fs`'s directory-reader comment loses the claim that `foreach` over a managed element is rejected, which stopped being true when the loop gained ownership of its copy, and points at the section instead. `tests/run/lib_fs.count_entries` is rewritten in the idiom: it returns `Result(int, io.Error)` rather than the three sentinel integers it used to answer with, and its output is unchanged.

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

*Recommendation.*

1. Skip the definite-nil analysis: it is already here. `src/nil_uses.odin` reports L0701 for a local every write of which is `nil`, and any non-nil or opaque write makes the whole body unknown. That is stricter than the proposed forward pass and needs no nullable type hierarchy. What a forward pass would add is a use before a later non-nil write, which is dead code under another name.
2. Skip per-write required-result tracking. L0698 already covers the two shapes a program reaches: a call whose required result is discarded, and a local bound to one and never read. Warning on an overwrite means per-write flow state where one "ever read" bit does now, for a pattern nothing in the library or the corpus writes.
3. Adopt the certainty fix for bounded provenance. The nine-element probe answers "this slice cannot be returned: `local` ends when this procedure returns" — stated as fact about a dependency that exists only because element borrows merged. The note that says so is four lines below, which is what the proposal means by buried.
4. Adopt the overload rewrite, narrowed. The part asking for the failed argument first is already built — proposal 2's resolution did it. What remains is the ambiguity message, whose "conversion vector (2)" and "selection failed at tie-breaker 5" are notations that appear nowhere else a programmer can read.
5. Adopt the binding message. Assigning to a `foreach` binding answers "a value parameter is immutable", naming a construct the program does not contain.

*Decision (22 September 2026).* Adopted as recommended: items 3 to 5 built, items 1 and 2 declined with the reasons above.

1. Certainty under a merged dependency. *Done:* L0526, L0513, L0511 and L0512 take their wording from `state.diagnostic_precision`, which `check_prov_event` already computes before reporting; two merges moved above their report so the conflict messages see the loan's own loss. With precision lost, the nine-element probe now answers "this slice may depend on `local`, which ends when this procedure returns", and the budget notes below it are unchanged. design.md's "Minimum provenance precision" requires this of every budget-caused diagnostic, beside the existing requirement to name the limit, and the row in "Required diagnostics" says so too. The cost is that a genuinely dangling return also reads "may" — the right trade, since the analysis cannot tell the two apart, which is the whole point.
2. An ambiguity a programmer can read. *Done:* `report_ambiguity` prints each maximal candidate's signature instead of its rank vector, and ends with why selection failed in words — that each converts a different argument better than the others, or that none is more specialized — each followed by the two ways out, calling the member by name or spelling the argument types. `vector_text` had no other caller and is gone. design.md's overload section and the requirements table asked for the vector and the tie-breaker number by name; both now ask for the signature and the reason instead.
3. Bindings named as what they are. *Done:* `Immutable_Reason` gains `Loop_Binding`, `Payload_Binding` and `Read_Only_Name`, chosen from the symbol's existing `borrowed_binding` and kind, so a `foreach` binding is told it names the element read-only and pointed at `&` for mutable traversal, a `switch` binding is told the subject still owns that storage, and an interface requirement binding gets a neutral line rather than being called a parameter. A value parameter keeps its message. `tests/err/places` covers the two new ones.

8. **Keep low-cost features that prevent verbose workarounds; defer additions without consumers.**

Keep `defer`. Automatic drop handles resources, but restoring a plain variable, balancing instrumentation, and observing a cleanup error are still natural scope-exit actions. Requiring a bespoke resource type for each would move complexity into user code.

Keep enum syntax alongside unions. Integer representation, validation, and foreign declarations are useful distinctions; forcing everything through a payloadless union would recover little.

Keep structural interfaces and `static_assert(Interface(T))`. A nominal `implements` registry would add coherence and conditional-conformance questions without solving the concrete callback problems above.

Keep the small `hook(convert/copy/drop)` boundary. These operations affect language semantics; ordinary protocol methods handle most other customization already.

Do not remove switch header bindings solely because branch-local bindings now exist. Grouped cases and consuming subject bindings need a replacement story; otherwise a syntax deletion simply creates temporaries, clones, or more branches. Prefer branch-local payload names in examples, and improve the diagnostic for the `switch (name in expression)` membership ambiguity.

Keep compile-time evaluation hermetic. File/network access during compilation, declaration-generating macros, purity effects, and general owning type erasure should each arrive with a concrete program that the current model cannot reasonably express.

*Recommendation.*

1. The six "keep" paragraphs ask for nothing. `defer`, enum syntax, structural interfaces with `static_assert(Interface(T))`, `hook(convert/copy/drop)`, switch header bindings and a hermetic evaluator are all here and none is scheduled for removal. Agreeing costs nothing and builds nothing.
2. Adopt the membership diagnostic. `switch (key in counts)` over a map answers "a type switch needs a union or an `any_view`, found `map[string]int`" under `counts`, and never says that `key in counts` was read as a payload binding or that the membership test is `switch ((key in counts))`. The parser records the header binding already, so the reading is known where the rejection is written.
3. Skip the sweep of examples to branch-local payload names. The same paragraph that asks for it argues the header form must stay; rewriting the examples away from it teaches the form nobody would then find.
4. Of the three documentation contradictions, two are left. The directory-reader comment no longer mentions managed-element iteration. The standard-library record's limits list mostly holds under probe — two names in one `impl` block still collide (L0409), a typeless parameter default is still rejected (L0408), and its `foreach` entry already records that the rejection is gone — but it still says a type in `main` must mark its `read` `@(public)` for `io.read_to_end` to reach it, a "compiler wart worth its own fix" that the fix has since removed: design.md "Interface bodies" reaches a slot through its own lookup, and a probe with a private `read` builds and runs. The other is the procedure-boundary paragraph calling a default parameter binding "callee-local", where the parameter section says a managed owner's storage is the caller's and is shared for the call.
5. The delivery order and the acceptance table are a summary of proposals 1 to 7, not new asks. Each row restates a decision recorded above.

*Decision (22 September 2026).* Adopted as recommended: item 2 built and item 4's remaining contradictions fixed; items 1, 3 and 5 need no change.

1. A membership header that says what it did. *Done:* the L0426 rejection adds a note at the binding when the header was written `name in expression` — the only way a header binding is spelled — saying that the name binds a payload and that the membership test needs the second pair of parentheses. design.md's `switch statement` section requires the note, beside the existing rule about which meaning the header has. `tests/err/switch_cases` covers it.
2. Storage a parameter does not own. *Done:* the procedure-boundary paragraph no longer calls the default binding callee-local. It is a read-only value the callee cannot outlive, and storage a managed owner holds stays the caller's, borrowed for the call — which is what the parameter section and the probes both say, and it keeps the consequence the paragraph exists for: no borrow of it can be returned.
3. A limit that is gone, removed. *Done:* the `@(public)` entry is deleted from the standard-library record's limits. `tests/run/lib_io`'s `Short_Reader` drops its `@(public)` and says why, so the reader the record described is now the regression test for the fix.
4. Found on the way. *Done:* `strings.init` built its result from a local at its last use and so cloned it, which put an L0507 warning from `core:strings` into every program that made a builder — seven of the library tests. It now moves the buffer in.

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
