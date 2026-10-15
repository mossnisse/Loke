# Differences from Odin and design motivations

This non-normative document explains Loke's design decisions and tradeoffs.
[design.md](design.md) defines the language, [grammar.md](grammar.md) its syntax,
and [open-questions.md](open-questions.md) the unresolved choices. API contracts
belong in [standard-library.md](standard-library.md); release history is in
[CHANGELOG.md](CHANGELOG.md).

| Topic | Start here |
| --- | --- |
| Ownership and cleanup | [Borrow checking](#local-borrow-checking), [assignment](#value-semantic-assignment), [panics](#panics-run-lexical-cleanup) |
| Types and errors | [Zeros](#zeros-that-are-values), [records](#structs-declare-parentheses-describe), [fallibility](#typed-fallibility) |
| Procedures and callbacks | [Methods](#methods-interfaces-and-operator-overloading), [captures](#capture-literals), [callable views](#borrowed-callable-views) |
| Compilation and configuration | [Compile time](#one-language-at-compile-time), [providers](#build-selected-services-and-explicit-runtime-state) |
| Simpler language surface | [Removed or narrowed features](#removed-or-narrowed-features) |
| Values and operations | [Overflow](#signed-overflow-panics), [slicing](#mutable-slicing-is-written-mut-alohi), [text](#slicing-text-keeps-its-panic) |
| Syntax and layout | [Syntax choices](#changed-syntax), [formatter](#formatting) |
| Library and compiler decisions | [Library APIs](#standard-library-api-choices), [compiler audit](#compiler-architecture-audit-2026-09-28) |

## Added features compared to Odin

### Local borrow checking

The procedure-local checker catches invalidated views and escaping local
borrows without lifetime annotations. Inferred [result contracts](design.md#procedure-result-contracts)
track which arguments or allocator regions a result depends on, including the
field carrying a borrow. That gives ordinary code useful precision without a
whole-program lifetime type system.

Inferred callback types preserve those contracts. A written `proc(...) -> T`
type erases them and uses conservative dependencies instead; converting back
cannot recover precision. Raw pointers, foreign calls, stored borrows, and
cross-thread lifetimes still require programmer discipline.

Lifecycle and formatting hooks contribute to [global write effects](design.md#global-write-effects):
cleanup may legitimately restore global state, but must not invalidate a live
borrow. Copy hooks cannot write globals because copies can be inserted or
elided in many contexts and their count is unspecified.

A result's [region provenance](design.md#allocator-regions-and-region-provenance)
follows the callee's body, not its signature: an allocator a constructor takes
but never uses backs nothing, so resetting it while the result is live is
accepted. The signature reading would let a constructor start using its
allocator without its callers changing, but it rejects programs that are
safe, and the checker already infers the rest of the result contract from the
body. A call it cannot follow keeps the signature reading.

### One temporary-lifetime rule

How long a temporary lives once depended on what viewed it: a slice literal's
backing array lived until its scope ended, a temporary erased into a local
`any_view` did so only when its lifecycle was trivial, and a capture literal
stored straight into a `dyn proc` local ended with its statement and made the
next call an error. The [one rule](design.md#temporaries-and-procedure-boundaries)
is C++'s and Rust's for a reference a declaration binds: a temporary that a
local's value borrows along a syntactic path lives until the block ends, and
is dropped there with the locals.

The path is syntactic so that when a drop hook runs never depends on what the
borrow checker infers; a reader sees the extension in the statement itself.
Calls end the path because a call's result says what it borrows only through
an inferred contract, and keeping every argument alive in case the result
borrows it would delay drops that nothing needs. A literal's fields do not
extend either, though Rust's do: they can be added later without breaking a
program.

Loke goes one step past C++ and Rust and extends through an assignment to a
whole local too. The temporary still ends with the block holding the
assignment, and a statement runs once per entry to its block, so the storage
stays bounded; a `for` update and a deferred statement, which rerun in one
scope, are the exceptions. That keeps assigning a fresh `any_view` or slice
literal to an existing local working as it did. The cost is that a managed
temporary bound this way drops at the end of the block rather than of its
statement, the drop a named local would have had.

### Threads the language can start

`core:thread` moves an argument into a new thread and checks its borrows with
`@(escape=static)`. Static text can travel; a slice of a local cannot. Several
arguments travel as one record, avoiding untyped callback state.

`Mutex(T)` owns its protected value, and its guard lends an `inout` result.
Keeping lock and data together makes the borrow follow the lock's lifetime.
Dropping an unjoined thread joins it, so the thread cannot outlive its handle.

The global-write warning catches spawned entries that write shared globals.
It is a warning because it cannot establish whether the writes happen only
before spawning or after joining. The [memory model](design.md#concurrency-and-the-memory-model)
defines the synchronization guarantees.

### Child processes

A child process needs explicit choices about argument quoting, handle
inheritance, environment, and waiting. `core:process` searches a bare program
name on `PATH`, quotes arguments, and restricts inherited handles to the
requested standard streams. Those choices prevent ambient process state from
silently changing which program runs or which resources it receives.

Dropping a `Child` closes handles without waiting or killing. A separate process
may be intended to outlive its parent; silently blocking or destroying its work
would be surprising. See the [process contract](standard-library.md#coreprocess).

### Managed lexical storage

Owning values release storage at scope exit. `unsafe.forget(move(value))`
explicitly suppresses cleanup for one value; `static` and `thread_local` select
storage duration without creating another type.

File-scope and static owners have no automatic shutdown order: their cleanup
could depend on other globals or running threads. Use a lexical owner for
observable cleanup, or `exchange` to extract a static value while leaving a
live replacement. Thread-local owners do have an endpoint and drop on normal
thread return, in reverse initialization order.

### An owner for one value

[`Box(T)`](design.md#owned-values) gives one allocated value the same ownership
rules that a dynamic array gives many: cleanup, region tracking, copying, and
read-only borrowing. It is copyable when its payload is; last-use transfer
avoids unnecessary clones and copy-cost diagnostics expose the rest.

A library record over `rawptr` cannot express the same contract. It would admit
a null zero, hide borrows carried by its payload, and need the checker to
recognize payload projection separately. A built-in box makes those properties
part of the type. It occupies one address, as does an optional box.

Raw allocation remains available as `unsafe.new` and `unsafe.free`. Checked
ownership uses `Box(T)`, so the result's type says who releases it.

The type is `Box(T)` and its constructor `box(value)`, as `Shared(T)` and
`Weak(T)` are types and `shared(value)` a constructor. Every predeclared generic
type is capitalised and nothing else is, so a reader can tell a type from a
call. When one lower-case name was both, `box(x)` was a type or an allocation
depending on whether `x` named a type, and the compiler needed a rule for each
handle to decide which.

### Zeros that are values

`{}` means a usable zero: an empty view, invalid type id, default allocator,
or empty weak handle. `nil` means an absent raw address. A non-null type has no
valid zero, so `^T`, procedure values, `dyn` views, `any_view`, `cstring_view`,
`Box(T)`, and `Shared(T)` cannot be null. Absence is represented by `Option`.
The non-null types split into references, which are borrows and checked as
such, and owning handles, which are owners. Calling them all references would
make an owning handle look like a borrow; the shared name is what the zero rule
and the `Option` niche need.

This moves the null check to the conversion from an unchecked address rather
than every dereference. It also avoids a nullable reference inside an optional
reference having two representations of absence. The freed null representation
lets `Option(^T)` and `Option(Box(T))` occupy one word.

The cost is explicit construction: records containing references have no `{}`,
and globals cannot initialize a reference from a runtime address. A second
non-null pointer type would instead make every API choose between two pointer
families for a distinction `Option` already expresses.

### Required fields

A representable zero need not be meaningful for a particular field.
`@(required)` prevents a literal from omitting that field and prevents implicit
construction of the record's zero.

Requiring every field in every literal would discard useful zero filling.
A record-wide prohibition on `{}` would still allow a literal to omit the
specific invalid field. A field-level requirement covers both problems while
remaining opt-in. A file handle needs no such mark: its zero is a valid closed
state.

### Conditional patterns

`if (case ...)` and `for (case ...)` abbreviate a switch over one variant.
For a fallible stream, `for (case .some(entry) = next() or_return)` combines
error propagation and end detection without an extra switch body.

The parser lowers these headers to the switch they describe, preserving its
ownership, scope, and control-flow rules. Nested patterns, multiple cases, and
header initialization are omitted to keep the abbreviation small.

### Updating a payload in place

`case .some(&mut node):` exposes the payload as a writable place. Without it,
an update would require exchanging the union for an empty value, consuming it,
and assigning the result back. The spelling matches mutable `foreach` bindings
and `&mut` expressions.

The binding retains the subject's borrow and tracks its fields separately.
This permits checked cursor walks without overlooking invalidation of another
borrowed field. A second mutable path into an owning chain still requires a
different representation, such as indices into a slot array.

Generated box lifecycle operations recurse. Long linked chains may need an
iterative drop hook to avoid exhausting the stack.

### Field bindings in a case

A payload is often a record, and binding it whole leaves selection or
destructuring as the next step. Destructuring a borrowed payload clones it, so
`case .add(pair): left, right := pair;` over a place copied both boxes and
everything under them. `case .add(left, right):` binds the fields as a
`foreach` header binds an element's: borrowed over a place, `&mut` leaves
included, and transferred over a temporary, as consuming destructuring does.
A recursive union, such as a syntax tree a compiler written in Loke walks, is
where this pays most.

It stays one level, a variant and its record's fields, so patterns still do
not nest. One binding still names the whole payload, as one `foreach` binding
names the whole element, so the arity of a pattern decides which it means.

### Storage modifiers instead of storage attributes

`static` and `thread_local` are declaration modifiers because they determine
lifetime and cleanup. Removing one can reset state on every call or invalidate
a returned borrow. Attributes such as `@(link_name)` describe other properties;
they do not choose storage duration. Cleanup suppression belongs to the
per-value `unsafe.forget` operation.

### No `stack` modifier, and no heap-promoted locals

Lexical locals stay in their stack frame. Automatically moving a large local
to the heap would hide an allocation and a failure path behind an ordinary
declaration. A `stack` modifier would then exist only to undo that policy.
Programs needing a large heap allocation can use an owning value. Oversized
stack frames can still overflow.

### Value-semantic assignment

Copying a dynamic array or map produces an independent value; pointers and
`Shared(T)` make sharing explicit. Strings share immutable storage. Implicit
copying keeps generic assignment uniform and lets records gain owning fields
without breaking every caller.

The cost is possible allocation. [Last-use transfer](design.md#last-use-transfer)
avoids a clone when an eligible local is finished, and copy-cost diagnostics
report allocating copies and large inline copies that remain. Borrow-related
exclusions keep this optimization conservative.

A copy hook must preserve the source's value, since an eligible copy may become
a move. Otherwise adding a later read could change an earlier assignment's
meaning. A duplicate that intentionally differs belongs in a named operation,
not a copy hook. Analysis order and generated moves are documented under
[Ownership, lifecycle, and provenance](compiler-architecture.md#ownership-lifecycle-and-provenance).

### Panics run lexical cleanup

Managed resources need a defined answer when execution fails. Under `unwind`,
a panic runs the faulting thread's live owners and `defer`s. A file's `drop`,
for example, closes its handle. It does not run package shutdown hooks or unwind
other threads.

`abort` exists for builds that cannot afford unwind machinery; it runs no
cleanup. Neither strategy permits catching a panic. The choice changes cleanup
on termination, not program validity. See [Panics and unwinding](design.md#panics-and-unwinding).

### Methods, interfaces, and operator overloading

Methods attach behavior to types without putting procedure declarations in
their data representation. An explicit `self` parameter distinguishes instance
methods from type-level procedures and exposes the receiver's parameter mode.

Structural interfaces serve generic constraints; named `slot` requirements also
provide runtime dispatch through `dyn` views. Expression requirements remain
static-only. Operators, indexing, iteration, and lifecycle hooks use the same
lookup and overload rules as other calls.

Extensions affect implicit lookup only inside their declaring package. Generic
bodies use definition-site lookup, and map key equality and hashing must be
inherent to the key type. Those limits prevent an import or caller-local
extension from changing existing code or corrupting a shared map's policy.

### One language at compile time

Ordinary procedures execute when a constant context requires their result.
They keep ordinary types, loops, mutation, and reflection rather than introducing
an untyped macro language. `$` names specialization inputs, `::` binds constants,
`when` selects source, and static `foreach` expands typed code; no single marker
silently moves arbitrary runtime work into compilation.

File and environment access belong in explicit build inputs. Ambient compiler
I/O would make evaluation depend on the machine instead of the source and build
configuration. A runtime call with constant arguments remains a runtime call.

User lifecycle hooks are excluded from evaluated paths. Running them correctly
would require reproducing runtime copies, moves, cleanup, and their order;
getting that wrong could make compile-time and runtime results disagree. See
[Compile-time phases](design.md#compile-time-phases).

### Build-selected services and explicit runtime state

The final build selects one default allocator and one logging provider.
Per-import configuration would require separately instantiated packages, with
rules for duplicated globals, initialization, symbols, and public type identity.
That is too much machinery for selecting services.

Request-specific allocators, log fields, clocks, cancellation, and other state
remain ordinary values. An ambient context pointer on every call would change
every ABI and require installation, derivation, and thread-propagation rules.
It would also pass the caller's current environment, not a callback's captured
environment.

Generic callback APIs instead accept a procedure or a record with `call`, checked
by `interfaces.Callable`. Captures remain typed and can borrow without allocation.
For one non-generic callback type, use a borrowed callable view.

### Capture literals

A [capture literal](design.md#capture-literals) abbreviates an ordinary record,
its fields, and its `call` method. Captures are initialized when the literal is
created. Keeping them in a clause after the signature makes ownership and escape
visible without reading the body.

Unmarked captures follow bindings: a place copies, while a temporary or explicit
move transfers. Borrowing is written. A borrowing default would silently share
state and constrain the source's later use; captures do not have the call-scoped
lifetime that makes ordinary parameter borrowing convenient. Copying a captured
owner can allocate, just as copying that owner into a local can.

The main rejected alternatives were:

- **Capture statements inside the body:** they appear to run on every call,
  hide the callable's layout and lifetime, and need rules for conditional or
  unreachable captures.
- **Inferred receiver modes:** a body edit could change which callback APIs
  accept the literal. The current plain `self` matches the library's callable
  constraint; mutable and consuming callable designs remain
  [open](open-questions.md#what-a-capture-literals-call-cannot-do).
- **A structural environment plus code pointer:** it would expose captures in
  type identity and make calls indirect. An ordinary generated record keeps
  generic calls direct and optimizable.
- **New generic parameter syntax:** `interfaces.Callable` and its associated
  result type reuse existing constraints rather than giving `proc(...)` a
  different meaning when a `$` appears inside it.

`capture` is contextual after a procedure literal's signature, preserving its
use as an ordinary identifier elsewhere.

### Borrowed callable views

A [`dyn proc` view](design.md#borrowed-callable-views) gives heterogeneous
callbacks one non-generic type. It holds data and code pointers and borrows its
target. Generic `Callable` parameters permit direct, inlinable calls; a view
trades that specialization for one signature and indirect dispatch.

There is only one call slot, so a separate witness table would add a load
without adding capability. A procedure value occupies the data word itself,
with a shared adapter, so converting a procedure does not borrow the local
variable that happened to hold it.

Conversion from a procedure or capture literal is implicit because the
destination fixes the complete call signature and capability. Converting a
named record stays explicit: it can expose roles other than calling. Temporary
targets follow the [one temporary-lifetime rule](#one-temporary-lifetime-rule),
so a literal stored straight into a `dyn proc` local lives until the block
ends.

Making every procedure value carry an environment was rejected. It would widen
thin procedure pointers, disrupt C callbacks, and require either owned
environments with allocation and lifecycle rules or borrowed environments with
lifetime tracking on every procedure value. Capture records can still allocate
when they copy owning fields; the decision avoids requiring a heap environment
merely to represent a callable.

### Typed fallibility

`Option(T)` represents absence and `Result(T, E)` represents failure. Each is
one ordinary union value that can be stored, passed, or returned. Named variants
remain unambiguous even when success and failure have the same payload type.

[Typed fallibility](design.md#typed-fallibility) recognizes declared union shape,
not privileged type names. This replaces special trailing-status rules while
letting library unions use `or_else` and `or_return`.

### Leaving from `or_else`

`or_else continue`, `or_else break`, and `or_else return value` cover the
common case of an absent value that ends a step, without a nested switch or
`if (case ...)`. They are the statements themselves in the fallback position,
not new expressions, so they keep the statements' rules and cleanups. A loop's
header cannot use `break` or `continue` this way: it is evaluated outside the
body, so whether it leaves the loop or an enclosing one would be a new rule.

### The failure operand of `or_return`

Before the failure operand, changing an error's domain was a method call to the
left of the operator that consumed it, `f().map_error(App_Error.io) or_return`,
which read as "convert, then maybe return" although conversion matters only on
the path that returns. `map_error` rebuilt the result on success, `ok_or` built
its error on every call, and an enum argument to `ok_or` needed its type
because `ok_or` infers it. Writing the error to the right of `or_return` puts
it on the failure path only, and lets `.name` resolve against the procedure's
error type, which has already chosen the union.

Wrapping stays explicit: each site names its variant. Alternatives that removed
the name were rejected:

- **Declared wrapping**, `@(wraps)` on a variant, makes the conversion implicit
  at the site and visible only at the union.
- **Inferring the variant from a unique payload type** breaks every distant
  `or_return` that relied on it when a second variant of that type is added.
- **Matching variant names to error types**, `io` to `io.Error`, gives names a
  meaning they have nowhere else; a rename or an import alias would change
  behavior.
- **A conversion interface like Rust's `From`** is implicit and needs coherence
  rules for who may declare a conversion.

The operand is a postfix expression after a postfix operator, so binary
operators still apply to the payload: `f() or_return + 1` keeps its meaning. The
cost is that a member of a bare `or_return`'s payload needs parentheses,
`(f() or_return).len()`; nothing in the repository wrote the unparenthesised
form, and the diagnostic suggests the parentheses.

### `Status(E)`

A procedure that only fails returned `Result(Unit, E)`, so the empty type
appeared in every such signature and every body ended in `return .ok;`.
`Status(E)` is a fallible union of its own shape rather than a second name for
`Unit`, which [A `()` unit type](#a--unit-type) rejected. A parametric alias,
`Status :: Result(Unit, $E)`, would keep one type, so `map_error` and generic
code over `Result` would work unchanged, but a type alias takes no parameters.
The cost is that a generic procedure over `Result($T, $E)` does not accept a
`Status(E)`. `Outcome` was the alternative name; `Status` was kept although it
can be misread as a process exit status.

A body whose success carries nothing may reach its end, which returns that
success. Every failure in such a procedure is written explicitly, so the end
has one meaning, as in a procedure with no result. `Result(Unit, E)` is not
covered, so a generic `Result($T, E)` body cannot change meaning with its
instance.

### `errdefer`

`defer if (failed)` left the flag to the programmer, who had to set it on every
failure path. `errdefer` runs when the procedure returns its failure variant,
decided by the returned value's tag, so `return .err(e)` and returning a saved
outcome behave alike. Its spelling follows Zig: one reserved word, found by
search, shaped like `defer`. Unlike Zig's, it also runs during panic unwinding:
it exists to undo incomplete work, a panic leaves work as incomplete as a
failure return does, and `defer` already runs there. Binding the error, Zig's
`errdefer |err|`, is left for later.

Once a success return has walked past an `errdefer`, it is retired: a panic in
an older cleanup does not bring it back. Scope exit is one LIFO traversal, and
an action it passed is behind it, as with the ordinary scope exit that already
discards an `errdefer`. Running it then would undo work after the newer
cleanups that depended on that work had already run.

### A fallible `main`

`or_return` needs a fallible result, so a `main` returning nothing or an `i32`
ended every program that could fail in a switch, and examples that printed the
error forgot the status. A `main` returning `Status(E)` reports the
failure the way a formatted panic reports its arguments, after cleanup, and
exits 1. The success arm carries nothing because there is nowhere for a value
to go.

### One result

A procedure returns at most one value. Several results form an anonymous record
and use the same destructuring as other records. That removes separate rules
for result lists and implicitly initialized named-result locals.

Labeled result names participate in type identity: `(width: int, height: int)`
is not `(height: int, width: int)`. Keeping the same identity when a record is
stored or returned prevents field-name changes from silently reinterpreting it.

### Records without field names

Unlabeled records serve results whose names callers would immediately discard
through destructuring. They are structural records with positions instead of
names, not a separate tuple model.

Only destructuring and positional construction access their fields; there is
no `.0` selector. `(T)` remains grouping, so an unlabeled record needs at least
two fields. A labeled record can implicitly lose its names, but the reverse
conversion and conversion between different labels are absent. All fields must
be labeled or all unlabeled. See [Anonymous records](design.md#anonymous-records).

### Structs declare, parentheses describe

A struct is nominal and belongs to a package. That ownership supports private
fields, hooks, `move_only`, and changes to field order without changing outside
callers. An anonymous record describes a structural value without those rights.

Combining the two would either weaken encapsulation or make every returned pair
a declaration. Instead, `struct` declares a type and parentheses describe one.
Inline anonymous `struct { ... }` types and `distinct` over anonymous records
would add nominal identities without useful ownership, so they are rejected.

### Ordered anonymous records

Sorting by `(priority, id)` would otherwise need a comparator. An anonymous
record has no encapsulation to protect, and its field order is its identity, so
lexicographic order is the only one it can mean. A struct may reorder its
fields, so it keeps writing its own `<`.

The first unequal field decides, rather than the first field where either
operand is less. A record of one float then orders exactly as the float does,
NaN included, and the four operators need only each field's `==` and `<`, as
`interfaces.Ordered` provides. A field whose type declares its own comparison
makes the record unordered. Comparing that field by the built-in operator would
contradict its type, and calling the type's operators would make record order
run user code; that can come later if programs need it. See
[Comparison operators](design.md#comparison-operators).

### Distinct types

A `distinct` type inherits comparisons but no other operators by default.
Comparisons cannot produce a value with the wrong dimension; arithmetic can.
`delegate` exposes a chosen set of underlying operators so a unit type can
permit addition without also permitting meaningless multiplication. This costs
some explicit declarations while keeping representation and meaning separate.

### One pattern grammar, flat declarations

Binding forms use subsets of one pattern grammar: names and `_`, writable
`&mut` leaves, static `$` leaves, and groups that descend into record fields.
`foreach` supports nested groups because adapters may wrap the yielded value.
A switch case takes one flat list over its payload's fields.
Declarations stay flat: a nested value the program constructed can be unpacked
in another statement, without adding recursive declaration and cleanup rules.

## Removed or narrowed features

### Generics are not ABI surface

Generic declarations have no runtime representation and cannot themselves be
exported or passed as procedure values. Only concrete instantiations reach ABI
lowering. A foreign wrapper exposes a concrete signature, keeping generic
specialization separate from the binary interface.

### Colon annotations on inferred generic bindings

`x: $T: Shape` had no specified constraint semantics. Parameter patterns such
as `[]$Element` already describe shape, and `where` clauses filter candidates.
Rejecting the extra colon avoids accepting an annotation that checks nothing;
explicit generic parameters such as `$T: type` keep their ordinary annotation.

### Floating generic arguments use representation identity

A floating generic argument is identified by its converted IEEE-754 encoding.
Positive and negative zero can behave differently, and code can inspect NaN
payloads. Numeric equality would merge observable distinctions and cannot even
identify a NaN with itself. [Generic argument identity](design.md#generic-argument-identity)
uses representation recursively through aggregates; ordinary numeric comparisons
keep their usual meaning.

### Constraint entailment in overload resolution

Constraints decide whether a candidate is viable; structural specialization
decides which viable candidate wins. A tie remains an ambiguity.

Ordering candidates by logical constraint strength would require normalization,
interface expansion, and entailment rules just to select a refinement
automatically. Explicitly naming the refinement keeps overload resolution
predictable without that second ordering system.

### Statement labels and multi-level breaks

`break` and `continue` target the innermost loop. A switch selects and is not a
break target. Multi-level exits use a helper return or an explicit loop condition,
keeping control flow structured without labels.

### `package main` shows its fields

Nothing imports an executable's root, so package-private fields there protect
nothing, yet they hid every field from printing: a first program's
`fmt.println(Point{1, 2})` printed `Point{}`. Making `main` unimportable and its
fields public by default fixes that without a second printed form per type.
Declarations keep the package default, because a public extension exports a
name into its package's scope.

### File-private visibility

The package is the encapsulation boundary. `@(private)` means package-private;
`@(private="file")` would add another visibility level and rules for interacting
with public defaults. Code needing an independent boundary belongs in another
package.

### Standard free aliases

`f(x)` uses lexical lookup; `x.f()` uses receiver lookup. Special aliases such
as rewriting `len(x)` to `x.len()` would duplicate spellings and need exceptions
to stop mutating receiver borrows from hiding in free-call syntax.

Built-in types keep ordinary contributed members such as `len`, `cap`, and
`hash`. Even a fixed array's `x.len()` evaluates its receiver; unevaluated
operands belong to operations such as `size_of`.

### `mem.` spellings of the allocation built-ins

Allocation built-ins have one spelling in the universe. A duplicate `mem.make`
or `mem.drop` would add no capability; fallible allocation is already available
through the corresponding `try_` operation.

### `fallthrough`

A switch case stops automatically. Multi-value cases cover shared choices;
shared procedures cover shared work. `fallthrough` would add control-flow and
cleanup exceptions to reintroduce an accidental behavior the switch avoids.

### Named-result initializers

Results are values supplied by `return`, not implicit locals initialized on
procedure entry. A result initializer resembling a parameter default would
attach similar syntax to a different trigger and complicate initialization.

### Reflection beyond fields and enum values

`fields_of` and `enum_values_of` cover data shape used by serialization and
bindings. Reflecting procedures, parameters, requirements, and attributes would
need more descriptors and lookup rules without a demonstrated consumer.
Additional reflection can be introduced when an actual tool needs it.

### Associated interface members use expressions

`T.NAME -> Type;` is an expression requirement. Associated types use the same
form, `T.Element -> type;`, whose result is necessarily compile-time known.
A separate associated-constant declaration grammar adds little to that model.

### Headless switch

An `if`/`else if` chain already selects among unrelated conditions. Requiring
a switch subject avoids a second construct with the same purpose.

### `default:` switch arm

`default:` names the fallback arm clearly; `case:` remains accepted. Reserving
`default` avoids ambiguity with a declaration at the end of an arm, where
`default: int = 0;` would otherwise also be valid syntax.

### Compiler-defined domain types

Complex numbers, quaternions, and matrices belong in libraries because records
and overloads can express them. SIMD remains built in because its semantics
include target vector operations that a record cannot promise.

### Owning type erasure

`any_view` and `dyn` borrow their payloads. An owning erased value would also
need allocation, alignment, clone/drop dispatch, region tracking, and rules for
borrows across moves. Keeping those out makes dynamic dispatch usable without
silently allocating. Closed owning sets use unions; an open owning abstraction
needs an explicit storage and lifecycle contract.

### User-defined implicit conversions

User-defined conversions are written at the call site. Otherwise an import or
an overload could silently select runtime conversion work, requiring ranking
and chaining rules to contain the effect. Even a special case limited to
unfixed literals adds those interactions for little saved text.

Built-in implicit conversions remain, including owner-to-view borrowing. Their
meaning depends on the source and destination types, not imported conversion
code.

### A read-only-data attribute

Constants materialize as shared read-only storage when runtime indexing,
slicing, or an address requires it. They already provide immutability and
process lifetime, so a separate `@(rodata)` attribute would duplicate them.
The cost is an explicit [materialization](design.md#materialization) rule:
constants are not exclusively compile-time objects, and all uses share one
backing object.

### No octal escapes

Octal escapes added an ambiguous byte-versus-character spelling. Loke's former
`"\377"` encoded the Unicode character `ÿ`, rather than one byte `0xFF`.
`\x` already spells bytes and `\u` characters, so octal escapes are rejected
and the diagnostic points to those alternatives.

### Sized boolean types

Loke has one byte-sized `bool`. Foreign boolean typedefs bind as their actual
integer representation and convert in a wrapper. That handles conventions such
as true being `-1` without pretending every foreign boolean is a wider Loke bool.

### Unchecked union extractions

A union is inspected by exhaustive switch or checked `value.as(.variant)`,
which returns an optional copy. Move-only payloads need a switch. Reading an
inactive payload as an owner could manufacture a container header and later
free an invalid address, so no unchecked extraction is part of ordinary syntax.

Raw representation work remains in `core:unsafe`. The open type set of
`any_view` has a separate checked, panicking extraction; neither form guesses
the active payload.

### Nominal conformance declarations

Structural interfaces need no `implements` registry. A declaration with no
semantic force would only repeat `static_assert(Interface(Type))` while implying
nominal membership. Giving it force would require a different design for
coherence, generic conformance, and witness construction.

### A `()` unit type

`Unit :: struct {}` already represents the empty result payload in
`Result(Unit, E)`. A second spelling for a zero-sized type is unnecessary;
`()` is not a type.

### Reviving a variable without a write

A full assignment revives a dead variable; `unsafe.forget` consumes a live
value without cleanup. A separate unsafe operation that marks dead storage live
would mainly let callers bypass conditional drop tracking. It has no demonstrated
use that justifies pretending unwritten storage contains a value.

### Hand-written package header files

A public-signature file maintained beside the implementation would duplicate
every public declaration. `lokec -doc` already derives the API from source.
A future compatibility tool could generate and compare manifests; it should
not require authors to maintain another set of declarations.

## Changed features

### Reading a carrier under a read-only reborrow

A read-only reborrow prevents writes through another path, but need not prevent
another read. Permitting recognized read-only uses allows `slice.equal(xs, xs)`
without weakening exclusivity. A mutable reborrow still excludes other reads,
which could observe a partially updated value.

### Each required result is asked about

`@(require_results)` checks each result stored in a local, not merely whether
the variable is ever read. Overwriting an unexamined error must not become valid
because an earlier value was examined. The check reports results no path reads;
values explicitly constructed by the caller do not represent an ignored call
result.

### Unchecked operations need the import

`core:unsafe` is the visible review boundary for operations that discard
lifetime or initialization guarantees. The file using unchecked pointer
conversions, C-pointer access, `---`, or `@(initialized=...)` must import it.
Converting to raw storage alone does not grant checked access back into it.

A file-level gate makes these operations searchable without adding an unsafe
expression language. `base:` packages are exempt because they implement runtime
facilities and cannot import `core:`. Generated traversal checks bound an
initialized prefix, but cannot prove those slots contain valid values.

### Formatting and logging sinks are `dyn` views

`fmt.Writer` and `log.Logger` are borrowed `dyn mut` views. Records implement
their write slot and keep ordinary type and borrow checks, avoiding raw state
pointers in user-facing adapters.

A formatter uses the sink during its call. A logger provider lends static
storage for process lifetime. Neither requires an owned closure, and neither
view has a null state.

### A checked pointer prints its referent

Every other checked view prints what it views, and a box prints its payload. A
`^T` printing its address made a map loop with one binding print addresses.
A checked pointer is never null, so it prints the value; an unchecked address,
which may be null or dangling, still prints as an address.

### Generated printed forms say what they print

Generated formatting distinguishes values that would otherwise look identical:

- Finite floats include a fraction or exponent, so a printed integer and float
  do not share the same spelling.
- Strings and runes inside aggregates are quoted and escaped, preserving
  element boundaries. A string printed alone remains plain text.
- An anonymous record prints its fields without repeating its type.

Struct formatting includes only public fields because one generated form serves
all packages. A type wanting a different representation declares `format`.
See [String format printing](design.md#string-format-printing).

### Explicit overload groups

Named groups make the overload set visible while each implementation keeps an
ordinary callable name. Ambiguity is diagnosed rather than settled by declaration
order. Methods and operators follow the same resolution rules.

### `+` concatenates strings at runtime

Runtime `+` keeps short text expressions convenient, allocating through the
default allocator. Each concatenation copies its operands, so repeated growth
can be quadratic. Use `String_Builder` for loops or allocator selection.
Copy-cost diagnostics do not measure concatenation's allocation cost.

### No enum arithmetic or bitwise operators

Enum values can have gaps, so arithmetic or bitwise operations can produce a
non-member. Enums remain comparable and ordered; `Bit_Set(Enum)` represents
flag sets, and explicit integer conversion supports representation-level work.

### Closed enums and payloadless unions

Enums are closed sets, allowing exhaustive control flow to guarantee a matching
arm. `Enum.from_int` validates membership and returns an `Option`; foreign or
wire values remain integers until validated. An enum without a zero member has
no zero value.

Payloadless union variants use bare names. A type name cannot accidentally become
a payloadless variant, so Odin-style `union { int, string }` is diagnosed instead
of silently changing meaning. The older `name:` spelling remains accepted.

### Signed overflow panics

Signed arithmetic panics when the mathematical result cannot fit. This catches
bad sizes and bounds while keeping behavior independent of optimization level.
The cost is an overflow check where the compiler cannot prove the range.

Unsigned arithmetic stays modular for hashing and bit manipulation. Named
`math.wrapping_*` operations request signed wrapping, and `checked_*` operations
return an `Option`. Shifts remain bit operations and atomic arithmetic keeps its
hardware read-modify-write semantics. See [Integer overflow](design.md#integer-overflow).

### Integer conversions keep the value

Integer conversion preserves the value or fails, whether the operand is a
literal or a runtime variable. Keeping only low bits for runtime values would
make a refactor from constant to variable change behavior silently.

`math.wrap` names truncation and `math.to` offers a checked optional conversion.
Those explicit operations also make wrapping arithmetic possible without
relying on lossy ordinary casts.

### Signed SIMD lanes follow the scalar rule

Replacing a scalar kernel with SIMD should not change overflow behavior.
Signed vector arithmetic therefore checks lanes and panics if any overflows;
wrapping operations remain available by name. Reductions fold through the scalar
checked operation so they agree with the loop they replace. This costs checks
but preserves the numerical contract across optimization strategies.

### Signed shifts stay bit operations

Shifts build masks and pack representations. Bits shifted out are discarded,
including the sign bit, and every count has a defined result. Treating a shift
as checked multiplication would reject useful expressions such as `i64(1) << 63`.

Signed `x << n` equals multiplication by a power of two only when that product
fits. Explicitly separating bit operations from checked arithmetic keeps both
uses predictable.

### Generated `hash` follows generated `==`

A record already compares field by field without a written `==`, so requiring a
written `hash` before it could be a map key cost a hand-written pair for every
key type. The inherent-pair rule exists so one policy holds across packages; a
generated member is inherent, and a structural hash is coherent with structural
equality by construction. A part with its own `==` must bring its own `hash`,
which the generated one calls, so the pair stays coherent at every depth.

### `in` is a comparison, not an additive operator

`in` produces a Boolean, so it shares comparison precedence. Giving it additive
precedence would regroup `x in values + extra` as `(x in values) + extra`, making
the apparent collection expression mean something else. Ranges bind between the
two, as Swift's do, so `c in 'a' ..= 'z'` tests a range while `0 ..< n + 1`
still ends at `n + 1`; no grouping the move changed had a meaning before,
because each put a `bool` at a range's end.

### Comparisons do not chain

`a == b == false` looks like a chain but a left-associative reading means
`(a == b) == false`. Requiring parentheses or an explicit `&&` avoids that
ambiguity for both equality and ordering comparisons.

### Field order stays inside the declaring package

Positional construction or destructuring of an imported struct would make
field reordering silently swap values at outside call sites. Requiring names
outside the owning package preserves encapsulation. Anonymous records remain
positional because their field order participates in structural identity.

### Diverging procedures belong to the declaration

`-> !` lets calls such as `panic` satisfy any expected result position and lets
the checker recognize paths that cannot return. Divergence belongs to the
declaration rather than the procedure-value type: propagating it through values
would require a subtyping rule without an established use.

### The allocation built-ins follow the `try_` convention

`make`, `box`, and other policy-following forms apply the allocator's failure
policy. Their `try_` counterparts return a failure value. Keeping that convention
across built-ins and libraries makes error handling visible in the name without
forcing every allocation into a separate panic wrapper.

### `main` may return an `i32` status

Returning a status from `main` allows normal scope cleanup before the process
exits. `os.exit` terminates immediately and skips cleanup. An `i32` status matches
the process interface and avoids silently narrowing a wider integer.

### `assert` and `panic` print values after the message

A compile-time message plus value arguments can report the failing state
without first allocating a formatted string. Formatting writes directly to the
error stream. `assert` evaluates those arguments only on failure, keeping an
expensive diagnostic expression off the successful path.

### An iterator's yield mode follows from `next`

`next` already determines the item type and whether iteration owns or borrows
it. Reading that information from the signature avoids a redundant `Yield`
descriptor that could disagree. An owned pointer element remains an owned
element; yielding a borrow of it requires another reference level.

### A map's mutable lookup is the marked one

`find` returns a read-only optional reference and `find_mut` a mutable one.
This follows the same convention as `^mut`, `[]mut`, and `iter_mut`: the spelling
that can write is visibly marked.

### Mutable slicing is written `&mut a[lo:hi]`

`a[lo:hi]` is read-only; `&mut a[lo:hi]` is mutable. The destination type does
not select the capability or change which slicing overload runs. This matches
`&x` and `&mut x` and makes mutation visible at the call site.

Consequently, `fmt.println(primes[1:4], total(primes[:]))` can use both read-only
slices in one call. It needs no intermediate binding to change a slice's type.
Parenthesize a mutable slice before selecting a member:
`(&mut a[:]).indexed()`.

### A string literal receiver is a static `string_view`

A literal's storage is static and needs no owner. Member lookup treats it as
a `string_view`, so `"hello".bytes()` can lend static bytes without creating
a temporary owning string. Extensions declared only on `string` do not change
that receiver type.

### Map element mutation

Whole-element assignment `m[key] = value` may insert because it supplies the
complete value. Reading or modifying a field requires an existing entry and
panics if it is missing. Automatically inserting a zero for partial mutation
would make behavior depend on whether the element type has a meaningful zero.
`find`, `find_mut`, and `find_or_insert` provide explicit alternatives.

### Container insertion takes its element like an initialization

Insertion follows initialization: a temporary or `move(x)` transfers; a borrowed
place copies. Always borrowing would exclude move-only elements, while a `move`
parameter would require explicit moves even for simple values.

Fallible insertion uses the same rule. On failure it drops an argument it took;
an explicitly moved source is already dead. Returning the element inside the
error would disrupt the shared allocator-error type. A caller needing to retain
the value on allocation failure can reserve capacity before moving it.

### `string` borrows as `string_view`

Implicit conversion lets a read-only text API accept owners, substrings, and
literals through one signature. It is a validated, allocation-free borrow.
The reverse conversion must acquire ownership and is explicit through `.copy()`.

### Slicing text keeps its panic

A text slice must preserve UTF-8: a bound inside a code point panics. Rounding
silently would return different text, while an opaque index type would burden
every ordinary byte offset with a conversion.

Text and rune searches, and `rune_offsets()`, locate code-point boundaries.
Raw byte searches can locate continuation bytes: `strings.index_byte("é", 0xA9)`
returns `.some(1)`, but `strings.try_slice("é", 0, 1)` returns `.none`.
Use `try_slice`, `floor_boundary`, or `ceil_boundary` for untrusted byte offsets;
`prefix_runes` expresses a limit in scalar values. See [Boundaries](standard-library.md#boundaries).

### String ownership and concurrency

Immutable strings can share storage, so reference counting is atomic. The
allocator must separately support the thread performing the final drop; that
transfer obligation remains with the programmer. A `string_view` borrows text
without sharing ownership.

### Allocation failure

Copies, container growth, and string concatenation can allocate implicitly.
Because those expressions have no error-result slot, the allocator selects a
failure policy. Recoverable allocation uses `try_` operations.

A hidden sticky error flag would not identify which implicit operation failed.
An explicit result or termination is preferable to continuing with a silently
truncated value. The policies are defined under [Allocation failure](design.md#allocation-failure).

## Changed syntax

### Statement termination

Semicolons terminate statements unless their outermost form ends in a block.
This keeps termination independent of line breaks without requiring a redundant
semicolon after a procedure body.

Calling a procedure literal immediately requires parentheses:
`VALUE :: (proc() -> int { return 7; })();`. Otherwise a following statement
beginning with `(` could be mistaken for a call on the preceding declaration.

### `transmute` is a procedure in `core:unsafe`, not an operator

Bit reinterpretation uses `unsafe.transmute(T, value)`. Types are already call
arguments, so a separate operator would add a keyword and precedence rule.
The import also exposes a trust boundary: a bit pattern valid for the source
need not represent a valid destination value.

### Parenthesized control-flow headers

Parentheses separate a control-flow header from its body. A uniform boundary
avoids special parsing rules for composite literals in conditions.

### Slice literals state their capability

`[]T{...}` produces a read-only slice and `[]mut T{...}` a mutable one.
Inferring mutability from surrounding context would make the written type fail
to describe the value.

### No uniform call syntax

Free calls use lexical lookup and receiver calls use methods or contributed
built-in operations. An unrelated free procedure never acquires a method spelling
through an import. See [Standard free aliases](#standard-free-aliases).

### `foreach`

`foreach` marks traversal; `for` handles ordinary repetition. A bare
`for (key in counts)` is rejected because it resembles a mistyped traversal.
The explicit membership loop is `for ((key in counts))`.

Switch has no competing traversal or header-binding form, so
`switch (key in counts)` needs no extra parentheses. Payload bindings belong
in its cases.

## Features kept close to Odin

### Standard output is binary

Writing `\n` produces that byte, without Windows text-mode translation to
`\r\n`. Formatting and direct stream writes therefore agree even when output
is redirected. The runtime configures process streams at startup; an object
build leaves stream configuration to its host.

### `defer`

Managed owners handle resource lifetimes, but not every cleanup is an owner's
destruction. `defer` can restore state, roll back a partial operation, or publish
completion on every exit without introducing a resource type for one statement.

The library uses it: `Once` publishes completion or poisoning, shared ownership
releases its allocation even if a payload drop panics, and process spawning
cleans up native handles. It follows the same panic-strategy limits as other
lexical cleanup.

### Foreign declarations

Foreign bindings keep external symbol names and ABI types, then expose ordinary
Loke wrappers where useful. Staying close to Odin's declaration model makes
bindings easier to port, while explicit foreign-string and nullable-pointer
types keep ownership and representation promises visible.

## Formatting

`lokec -fmt` ([src/formatter.odin](src/formatter.odin)) settles the layout
`core/` already used, and changes whitespace only. The rules:

- **Line breaks are the author's.** It never joins or splits a line, and a run
  of blank lines becomes one. Wrapping at a width was rejected: it is most of a
  formatter's code, and a renamed identifier would re-flow its neighbours in a
  diff.
- **Tabs, one per enclosing bracket** opened on an earlier line, however many
  opened together. A `case` sits at its `switch`'s level, and a line that
  continues an unfinished statement outside any `(` or `[` goes one deeper. A
  file-scope `when` body stays at column zero when written there, as `core/`'s
  long platform blocks are.
- **Spacing between tokens** is one space after a comma, around `::`, `:=`,
  assignment, comparison, logical, range, and arrow operators, and none inside
  brackets, before `,`, `;`, `)`, and `]`, or after a prefix operator. An
  arithmetic or bitwise operator written with no space on either side stays
  tight, because `core/` writes `a*b + c*d` by precedence; one written with a
  space on either side gets one on both.
- **Extra spaces inside a line are kept.** `core/` aligns field types and
  trailing comments with them. Only the leading indentation is recomputed.

It works on the real lexer's tokens rather than printing the syntax tree:
keeping the author's breaks leaves nothing for a tree printer to decide, and a
token stream cannot lose or reorder syntax. The parser still runs, so a file
that does not parse is refused, and each result is lexed again and must hold
the input's tokens exactly, or the formatter reports an internal error instead
of writing. tests/corpus_test.odin keeps `core/` and `base/` formatted and
formats every program corpus to a layout that formats to itself.

Possible refinements are recorded in [open-questions.md "Formatting"](open-questions.md#formatting).

## Standard-library API choices

Public contracts live in [standard-library.md](standard-library.md). The package
boundaries and API shapes follow a few common choices:

- **Files and process state are separate.** `core:fs` owns files; `core:os` owns
  process state. There is one spelling for opening a file.
- **I/O errors own scalar data.** An operation enum and native code avoid
  allocating or borrowing diagnostic text. Public constructors let callers
  implement streams without exposing the error's fields.
- **Formatting avoids a builder dependency.**
  `builder.append(fmt.to_string(allocator, ...))` provides formatted append
  without making every `fmt` importer also depend on `core:strings`.
- **Directory iteration streams borrowed names.** Walkers avoid allocating a
  name at every step; callers retaining entries copy them. An explicit loop
  distinguishes failure from end of input.
- **Joining takes a slice.** A variadic would absorb trailing allocator
  arguments or prevent a preceding default allocator from being omitted.
- **Case conversion is ASCII-only.** Full Unicode mapping requires tables and
  a defined contract. The owning result already permits text length to change;
  locale rules must not depend silently on process state.
- **Float widths have separate names.** `sqrt` takes `f64` and `sqrt_f32` takes
  `f32`. Overloading both would make an unfixed literal ambiguous; converting
  through a wider result can round twice.
- **Random generators are explicit values.** Every `core:random` procedure
  takes a generator `inout`, as `core:io` takes a stream. A package-owned
  default would double the API with generator-free overloads and give the
  library hidden state. A program that wants a global declares
  `rng: thread_local random.Xoshiro256;`.
- **A generator is move-only.** Copying one copies its future: both copies
  draw the same values. The classic case is a generator handed to a thread and
  then used again by its spawner. `split` and `from_state(rng.state())` make the
  second stream explicit.
- **An unseeded generator seeds itself.** The alternatives were a zero value
  that acts as seed 0, which gives every `thread_local` generator the same
  stream, and no zero value at all, which would take the zero value away from
  every record that holds a generator. Reading entropy happens on a draw, never
  on import. The cost is one predictable branch per draw: an all-zero
  xoshiro state is otherwise unreachable.
- **xoshiro256++ is the generator.** It is fast, passes BigCrush and
  PractRand, needs only 64-bit operations, and has jumps for disjoint parallel
  blocks; Julia and Rust's `SmallRng` use it. MT19937 has 2.5 KB of state,
  fails linearity tests, and seeds poorly from small seeds. xorshift128+ has
  weak low bits. Linear congruential generators fail statistical tests outright.
- **PCG64 is numpy's DXSM variant.** The second generator exists for
  `advance`, which moves a stream any distance in 128 steps, and for matching
  another tool's output. numpy's `PCG64DXSM` mixes the state before stepping,
  with the 64-bit multiplier, and is the published reference users can
  check against; Go's `math/rand/v2` PCG uses a full 128-bit multiplier and
  mixes after stepping, so the two disagree. The older XSL-RR output is not
  offered: O'Neill replaced it with DXSM after it was shown to correlate
  across closely related streams.
- **Counting distributions follow numpy.** `unit` is numpy's `next_double`
  bit for bit, so porting `random_poisson` and `random_binomial` step for step
  gives algorithms with decades of use and a reference to compare against, and
  a fixed draw accounting to specify. BTPE is long, but inversion alone costs
  draws in proportion to the mean, and the beta-recursion alternative takes
  about `2 log2(trials)` gamma draws per value.
- **`geometric` counts failures, not trials.** Its support then starts at 0,
  as `poisson` and `binomial` do, and as C++'s `geometric_distribution` and
  Rust's `rand_distr` count. numpy counts trials, which is this value plus one.
- **Counts are `u64`.** A count is never negative, so the type carries what a
  panic would otherwise check, and a mean or trial count above 2^63 still has a
  result type.
- **`gamma` below shape 1 uses Marsaglia and Tsang's boost.** The same paper's
  method for a shape of at least 1, with one extra `open_unit` power, keeps one
  algorithm for every shape; numpy instead uses a separate rejection sampler
  there.
- **`sample` rearranges in place.** Partial Fisher–Yates needs no allocation,
  works on any element type, and leaves the unchosen elements behind the
  sample. Floyd's algorithm, which picks indices from a range without
  materializing it, needs a set and waits for a caller.
- **`Weighted` is an alias table.** Vose's construction is linear and draws in
  constant time, against a cumulative table's logarithmic binary search. The
  construction order is specified, so a table's picks replay from a seed.
- **Seeding never reads the clock.** Processes started together share a clock
  reading and often a process-ID range. The documented idiom is to draw a seed
  with `secure_u64`, record it, and seed with `from_seed`.
- **OS entropy panics instead of returning an error.** The system generator does
  not fail on a supported system, as Go 1.24's `crypto/rand` also concludes.
  Continuing with predictable bytes would be worse than stopping. A `Status`
  would put an `or_return` on every seed for an error no caller can handle, and
  a new `io.Operation` would break exhaustive switches over it.
- **Draw mappings are specified.** A seeded program's output is behavior a
  reader can depend on, so how each procedure maps draws to values is part of
  its contract, not an implementation detail. The ziggurat tables are constants
  rather than computed at startup, so most normal and exponential values do not
  depend on the C library at all.

## Compiler architecture audit (2026-09-28)

The audit of `b2cc712` and its follow-up favored enforcing existing phase
boundaries over introducing another IR or splitting the compiler into packages.
The current contracts are in [compiler-architecture.md](compiler-architecture.md).
Two labels remain useful to the regression cases citing this review:

- **A1:** compile-time construction obeys an element budget; large runtime
  literals do not require eager constant construction.
- **A5:** speculative checks use `committing(c)`, and assertions detect changes
  to registries that must remain unchanged during a probe.

The other lasting choices are shared lifecycle/provenance reset identities,
one walk building their related graphs, and exhaustive specialized query walkers
instead of a universal child traversal. Each avoids duplicating facts or visiting
positions that a particular analysis should ignore. Implementation details belong
with the [semantic architecture](compiler-architecture.md#semantic-architecture);
historical fix lists and test counts are available in Git history.
