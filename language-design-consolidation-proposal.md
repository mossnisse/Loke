# Loke language consolidation proposal

Status: proposal

This document proposes a coherent set of changes to `design.md`, `grammar.md`,
and the compiler, covering product types, multiple results, and error
handling. It is concrete enough that examples and costs can be judged
together. Nothing here is normative until it replaces the relevant text in
`design.md` and `grammar.md`.

This is a candidate for the evaluations in
[`language-refinement-strategy.md`](language-refinement-strategy.md), not an
approved implementation roadmap. In particular, retaining anonymous unions
and giving `Result` a successful zero value remain alternatives to the
strategy's preferred candidates. Those decisions need evidence before
adoption. The provenance prerequisites below apply whichever value model wins.

## Summary

1. Loke has records, but no separate tuple type.
2. An anonymous record, `(field: Type, ...)`, is the lightweight product type
   for temporary groups of values. A named `struct` stays the default for
   public API types and values with behavior.
3. Records have both field names and declaration order. Named and positional
   construction use the same record; eligible records also support flat
   positional destructuring.
4. Calls use the same positional-then-named slot matching as record literals,
   but a call's arguments are never materialized as a record value.
5. A procedure returns zero or one value. Multiple related values become
   fields of a record.
6. **New: union variants may be named.** A named-variant union is an ordinary
   sum type with a designated zero variant, may repeat a payload type across
   variants, and is read with the existing `.name` selector.
7. `Option(T)` and `Result(T, E)` become ordinary generic unions declared in
   `base:`, not compiler-owned type families. Both are inline values and never
   imply allocation or boxing.
8. `or_else` and `or_return` operate on `Option`/`Result` values, not on a
   trailing result whose type is interpreted contextually as status. A stored
   operand is not implicitly consumed; `move` requests ownership transfer.
9. The `manual` storage modifier is removed. Lexical owners clean up
   automatically; `drop`, `move`, resource-specific `into_raw`, and an
   explicit unsafe `forget` cover manual control.
10. Manual allocation through `new`/`free` is untouched — it's a separate
    concern from declaration cleanup policy.
11. `inout` parameters, receivers, and place results remain as they are today.
12. Values remain values regardless of where they live (inline, owning
    allocation, or behind a pointer). `impl` and generics stay available for
    every type category — no primitive/object split.
13. Wrapping a borrow in a record or union preserves its root and region
    dependencies. This is a prerequisite for migrating producers, not a later
    improvement or special behavior of `Option`/`Result`.

## 1. One product model: records

### 1.1 Named records stay nominal

```odin
Point :: struct {
	x, y: f64,
}
```

`Point` owns its `impl` blocks, lifecycle hooks, and formatting. Another
struct with the same fields is a different type. Named records stay the
default for exported inputs/results, domain concepts, values with invariants
or inherent methods, and anywhere a name helps diagnostics.

### 1.2 Anonymous records replace the proposed tuple family

An anonymous record is an exact structural product type — the current
named-result shape, but the names are fields of one value:

```odin
(key: string_view, value: int)
```

`struct` stays reserved for a nominal declaration site; `Entry :: (key:
string_view, value: int)` is an alias for the structural type, not a new
nominal one. Identity is the ordered sequence of field names and types, so
field order matters and two anonymous records with the same fields in
different order are different types.

The initial form is deliberately restricted: every field is named and public;
fields compare exactly, with no width subtyping; `using`, private fields, and
layout attributes are not permitted; an anonymous record has no declaration
site and so no inherent `impl` block; copy/move/drop/equality/reflection/
formatting are derived structurally from its fields. Code that needs any
excluded facility names a struct instead — this keeps anonymous structural
types from creating an ownership or coherence problem for methods.

This is not a second tuple category: it reuses struct field selection,
layout, lifecycle, reflection, literals, and generics. There is no positional
type such as `(int, string)` with only numeric field names.

```odin
entry: (key: string_view, value: int) = {key="port", value=8080};
```

Braces were considered for the type (`{key: string_view, value: int}`) but
would make `{}` mean block, value, and type at once, and read badly in a
signature like `proc() -> {x: int}`. Parens reuse syntax Loke already has for
named results.

**A nonempty parenthesized type is a record if and only if it is labelled.** Otherwise
`-> (x: int)` is ambiguous between a one-field record and a parenthesized
single result — exactly the position where the combined product migration
(section 13) removes the old named-result spelling. So: `(name: T, ...)` is
always a record type at any arity, including one; `(T)` is always grouping;
there is no unlabelled anonymous record type.

The empty product `()` is the zero-sized unit type with one value, also
written `()`. See open decision 5 for its layout/ABI status.

### 1.3 Construction is both positional and named

```odin
Point{1, 2}
Point{x=1, y=2}
Point{1, y=2}
```

Rules: a positional initializer fills the next unfilled field; a named
initializer fills that field by name; positional entries precede named ones;
a field fills only once; a nonempty purely positional literal supplies all
fields; omitted fields (when any initializer is named) get their zero value;
expressions evaluate left to right. The empty literal `{}` requests the whole
record's zero value under the existing default-value rule.

Mixed literals are accepted deliberately: calls must permit mixing (e.g.
`create_window("Loke", width=1280)`), calls and literals share the matcher, so
forbidding it in literals only would be an arbitrary asymmetry.

### 1.4 General record destructuring replaces result-only destructuring

```odin
entry := read_entry() or_return;
key, value := entry;
```

Two or more bindings destructure a record. A single binding receives the
whole value; use field selection to read a one-field record's field. The
record must have exactly as many directly declared fields as bindings, and
every field must be visible at the use site. Private fields are not filtered
out, and `_` does not bypass visibility. Promoted fields are not flattened.

Bindings follow declaration order and may be `_`. Destructuring is flat for
now. The same eligibility and ownership rules apply to declarations,
assignments, and `foreach`, for named and anonymous records:

```odin
point := Point{1, 2};
x, y := point;

foreach (key, value in table.entries()) { ... }
```

#### Destructuring an owning record

Since `move` cannot consume a single field, destructuring needs a rule for
owning fields, based on the operand's category. Evaluate the operand once:

- **Destructuring a place clones.** `x, y := point` copy-initializes each
  binding from `point`, which stays live and drops normally. Owning fields
  clone through their lifecycle hooks; the copy-cost diagnostic applies.
  Each retained field must be copyable. This projects fields; it does not
  invoke the containing record's copy hook or construct a second whole record.
- **Destructuring a temporary consumes.** `key, value := read_entry() or_return`
  moves retained fields into their bindings without cloning. The containing
  record must have only generated field-wise lifecycle behavior: neither a
  custom `hook(copy)` nor a custom `hook(drop)`. Its fields may have custom
  hooks or be move-only, because each field transfers as a whole value.
- **`move` selects consumption from a place.** `key, value := move(entry)`
  has the same eligibility rule as a temporary and marks `entry` dead as a
  whole. Existing borrow checks must permit that move.
- **`_` discards a field.** It clones nothing from a place. In a consuming
  form, discarded fields drop exactly once in reverse declaration order;
  retained fields become the bindings' cleanup responsibility.

The consuming restriction is deliberate. A resource record can own a handle
through its own drop hook even when all its fields are plain integers.
`_, _ := move(resource)` must not bypass that hook. Bind and drop the whole
resource, or call an ordinary consuming `into_parts`/`into_raw` method whose
implementation preserves the type's lifecycle contract. Adding such a method
does not waive the restriction inside its body. A record with custom hooks
can still be inspected through visible fields or a cloning destructure.

Prepare retained fields in declaration order before publishing bindings.
Assignment uses the existing multiple-assignment rule: prepare values and
destinations before writing any destination. If cloning or preparation fails,
clean up initialized temporaries and, for a consuming operand, any remaining
fields exactly once. Existing destinations are unchanged by failed preparation;
explicit moves and earlier expression side effects are not rolled back.

Consequently, binding a payload and then destructuring the new place can
clone owning fields; destructuring the original temporary or `move(entry)`
does not. Diagnostics must expose that difference, as in section 8.3.

## 2. Calls use record-like matching, not argument records

### 2.1 Shared matching rule

```odin
create_window :: proc(
	title: string,
	x: int = 0,
	y: int = 0,
	width: int = 854,
	height: int = 480,
	monitor: ^Monitor = nil,
) -> Result(^mut Window, Window_Error) { ... }

window := create_window("Loke", width=1280, height=720) or_return;
```

The shared **slot matcher**: positional values fill the next unfilled slot; a
name selects one slot directly; positional precedes named; duplicate fills
are errors; expressions evaluate left to right. Omitted parameter defaults
evaluate once, in parameter order, after supplied arguments are bound — a
record instead zero-fills omitted named fields. That's a policy difference on
top of the same matching step, not a second algorithm.

### 2.2 Why a call does not construct a record value

Parameters have properties ordinary record fields don't: `inout` is a
call-bounded alias to caller storage; `move` consumes a caller binding; a
variadic parameter receives a call-scoped pack; defaults are declaration code
evaluated only when omitted; a managed-value parameter is a non-owning borrow;
the ABI may pass each parameter independently. Materializing an argument
record would change those semantics, or risk making parameter names part of
procedure type identity (so renaming a parameter could break compatibility).

So: parameter names/defaults stay declaration metadata; procedure type
compatibility uses types, modes, variadic shape, effects, results, and
calling convention — never names; calls through a procedure value supply the
full parameter list and get no defaults from an erased declaration; there is
no general `Arguments(F)` type or automatic argument forwarding.

An application can still define an ordinary options struct when arguments
need to be stored, forwarded, or assembled incrementally — that's real data
with storage and lifecycle, distinct from call syntax:

```odin
Window_Options :: struct { x, y, width, height: int, monitor: ^Monitor }

create_window :: proc(title: string, options: Window_Options = {})
	-> Result(^mut Window, Window_Error) { ... }
```

## 3. Procedures return one value

```odin
log_message :: proc(text: string_view) { ... }
measure :: proc(values: []f64) -> Statistics { ... }
```

Several related values become fields of a record:

```odin
Statistics :: struct { minimum, maximum, mean: f64 }
```

An internal helper may use an anonymous record instead:

```odin
split_once :: proc(text: string_view, separator: rune)
	-> Option((before: string_view, after: string_view)) { ... }
```

"One value" is a source-level rule — the backend may still classify and
return record fields in multiple registers; nothing forces a materialized
temporary or a worse ABI.

**Named result locals and bare `return` are removed.** A procedure with a
result writes `return expression;`; one without writes `return;`. This
deletes the interaction among named results, definite initialization,
multiple results, and `or_return`. Code that builds a result incrementally
declares an ordinary local instead:

```odin
stats: Statistics;
// initialize `stats` along the required control-flow paths
return stats;
```

## 4. Named union variants

Named variants let section 5 reuse the union representation and lifecycle
model. Their grammar, construction, and inspection rules still need explicit
ownership semantics.

### 4.1 The problem

Loke's discriminated unions already have a runtime tag, exhaustive switching,
generics, recursive lifecycle, reflection, and comparison — `Option ::
union($T: type) {T}` already works. But variants are identified by payload
**type**, so `Result(int, int)` would collapse into one variant, and no
variant can be named. A payload-less variant can't be named either, which is
why unions need a separate nil state for "no variant." Naming variants
removes both restrictions with one rule, for any user union.

### 4.2 The rule

A union declares its variants either all anonymous (today's form) or all
named:

```odin
Value  :: union {bool, i32, f32, string}          // anonymous, unchanged
Option :: union($T: type)     {none:, some: T}    // named
Result :: union($T, $E: type) {ok: T, err: E}     // named
State  :: union {waiting:, ready:}              // named, no payloads
```

**Every named variant declaration contains a colon**, including a payloadless
one such as `none:`. A bare entry is always a type, never a variant name
inferred from lookup failure. Thus `union {A, B}` remains an anonymous union
of types, while `union {A:, B:}` declares two payloadless variants regardless
of whether types named `A` and `B` are in scope. An empty body remains the
existing empty anonymous union. Mixing labelled and unlabelled entries is an
error.

The relevant grammar is:

```ebnf
Union_Variants = Anonymous_Union_Variants | Named_Union_Variants
Anonymous_Union_Variants = Type ("," Type)* ","?
Named_Union_Variants = Named_Union_Variant ("," Named_Union_Variant)* ","?
Named_Union_Variant = Member_Name ":" Type?
```

For a named-variant union: each variant has a name unique within the union
and an optional payload type; two variants **may** share a payload type,
since the name discriminates them; there is **no nil state** — the zero value
is the first declared variant (whose payload type must have a zero value, if
any); an exhaustive `switch` covers every variant with no nil case; reflection
exposes variant names in declaration order. Anonymous-variant unions keep
their current semantics (nil zero value, `case:` for it) unchanged; the two
forms don't mix within one declaration.

Retaining these two semantic forms is a cost to evaluate against one named
variant model for all unions (open decision 1), not a compatibility requirement.

### 4.3 Construction and inspection reuse existing spellings

A variant is selected with the existing implicit selector, generalized from
enum members to union variants:

```odin
result: Result(Entry, Error) = .ok(entry);
option: Option(int) = .none;

Result(Entry, Error).ok(entry)   // explicit form, when no expected type exists
Option(int).none
```

A payloadless variant has no parentheses, like an enum member; a variant
with a payload takes exactly one argument, including when the payload type is
`()`. There are no default arguments or unit-argument omission rules.

Payload construction follows ordinary record-field initialization, not the
non-owning parameter convention of an ordinary call. A place argument clones
the payload and requires it to be copyable; a temporary or `move(value)`
transfers it. Returning `.ok(local)` does not implicitly move `local` inside
the constructor. A move-only payload therefore uses `.ok(move(local))` or a
fresh temporary. Wrapping adds no allocation beyond any payload clone.

Inspection uses the type-switch syntax, with cases naming variants:

```odin
switch (payload in result) {
case .ok:  use(payload);    // narrowed to `Entry`
case .err: report(payload); // narrowed to `Error`
}
```

A case naming several variants, or a default case, leaves the binding at the
union type. A single payloadless variant binds the unit value `()`; it does
not expose nonexistent storage.

#### Ownership of switch bindings

Type narrowing alone does not specify ownership. Union switches, whether
their variants are named or anonymous, use these rules:

- A **place subject borrows**. Its case binding is immutable and non-owning,
  so inspecting a stored `Result(File, E)` does not clone a move-only `File`.
  The subject remains live and must not be mutated, moved, or dropped while
  that borrow is live. Copying or returning the binding uses ordinary borrowed
  value rules; `move(payload)` and `drop(payload)` are errors.
- A **temporary or `move(subject)` consumes**. The selected payload transfers
  whole into an owning case binding. A case binding that retains the union
  type instead owns the whole union. Untransferred ownership drops on every
  exit, including `break`, `return`, and unwinding; no active payload is
  dropped twice. `_` acquires no binding, so the active payload stays owned
  by the switch temporary and drops when the switch exits.

Each switch evaluates its subject once. These rules require lifecycle and
provenance support in addition to case-name resolution; they do not change
inspection of erased `any_view` storage into an ownership transfer.

### 4.4 What the addition costs

The addition needs disjoint named/anonymous variant grammar, a per-union
variant-name namespace using implicit selectors, a zero-value rule, variant
names in reflection, constructor ownership checks, and borrowing/consuming
switch lowering. It also needs a decision about
`active_typeid()`, which can't discriminate two variants sharing a payload
type (open decision 3 — this draft keeps `active_typeid()` for anonymous
unions only, using the switch/reflection as variant identity for named ones).

Checked extraction `value.(T)` / `value.as(T)` still select by type and
remain anonymous-union operations; a named union is read through its switch
or ordinary methods.

## 5. `Option(T)` and `Result(T, E)`

### 5.1 Ordinary library unions

```odin
Option :: union($T: type)     {none:, some: T}
Result :: union($T, $E: type) {ok: T, err: E}
```

Declared in `base:`, not compiler-owned. The wrapper introduces no allocation,
boxing, or dynamic dispatch. Payload copies still follow their ordinary clone
and allocation policies. Lifecycle, equality, formatting, and reflection use
the recursive behavior of a union over its variants. The compiler recognizes
only their roles in `or_else`/`or_return`: no separate lookup path, layout rule,
or construction form for these two types.

Consequences: `E` is unconstrained (enum, integer code, string, struct,
union — the old nil-status requirement on `E` is gone, and with it "nil means
success"); only one payload exists at a time, so a failed `Result` holds no
inactive `T`; the tag is explicit and paid for once, so `Option(^T)`
distinguishes `.some(nil)` from `.none`.

`Option(T)`'s zero value is `.none` (its first variant), satisfying the
constant-zero requirement for file-scope/`static`/`thread_local` owners with
no special case. `Result(T, E)`'s zero value is `.ok(T{})` under the same
rule — well-defined but arbitrary (open decision 4).

A success with no useful payload uses the empty anonymous product:

```odin
Result((), Error)   // construct success with .ok(())
```

This is a payload of type `()`, not a payloadless variant: `.ok()` is an
arity error. By contrast, `Option(int).none` names a variant declared `none:`
and takes no argument list.

### 5.2 Compact contextual constructors

```odin
return .some(value);
return .none;
return .ok(value);
return .err(error);
```

This isn't special-cased for these two types — it's the implicit selector
applied to any union, so a user union gets the same spelling. The compact
form requires a complete expected type, as an implicit selector always does:

```odin
result: Result(Entry, Error) = .ok(entry); // OK
result := .ok(entry);                      // ERROR: `E` has no context
```

An anonymous-product payload stays compact at both sites:

```odin
parse_entry :: proc(line: string_view)
	-> Result((key: string_view, value: int), Error) {
	...
	return .ok({key=key, value=value});
}
```

### 5.3 `or_else`

```odin
port := config.get("port") or_else 8080;
data := fs.read_bytes(path) or_else [dynamic]u8{};
```

The fallback runs only for `.none`/`.err`. For a consumed failed `Result`,
`or_else` drops its error before evaluating the fallback. For a stored place,
the operator leaves the original error live and neither clones nor drops it.
Section 5.7 defines both operand categories. Code that needs to inspect the
error uses a switch. `or_else` no longer treats the last component of an
arbitrary result as status, and needs no separate rule
for multiple payloads — a multi-value payload is one record value, so the
fallback is one ordinary expression at every arity.

### 5.4 `or_return`

```odin
parse_request :: proc(text: string_view) -> Result(Request, Error) {
	header := parse_header(text) or_return;
	body := parse_body(text) or_return;
	return .ok(Request{move(header), move(body)});
}
```

For `Result(T, E1)`, the enclosing procedure must return `Result(U, E2)` with
`E1` assignable to `E2`; on failure `or_return` obtains an owned error by the
copy/transfer rules in section 5.7, constructs the enclosing `.err` without
another clone, and returns it. On success the expression has type `T`. For
`Option(T)`, propagation requires an enclosing `Option(U)` result; absence returns
`.none`. There's no implicit `Option`-absence-to-`Result`-error conversion —
code calls something like `option.ok_or(error)` explicitly.

`main` has no result and can't propagate; a program that wants propagation
keeps fallible work in a helper returning `Result((), E)` and converts
failure to an exit status at the boundary.

The operand is evaluated once. Normal `defer` and cleanup run on propagation;
`or_return` remains invalid outside a procedure or inside a deferred statement.
It returns from the innermost procedure only.

### 5.5 Standard producer changes

```odin
value.(T)       // T; traps on a union mismatch
value.as(T)     // Option(T); never traps for mismatch

table[key]      // V/place; one indexing policy
table.get(key)  // Option(V); non-inserting value lookup
table.find(key) // non-inserting mutable lookup; see below

array.pop()     // Option(T)
iterator.next() // Option(Element)
```

Validating conversions return `Option(T)` when invalidity carries no useful
information, `Result(T, E)` when it does.

Strategy Phase 1a has shipped the arity half of this table under the existing
status protocol: `value.as(T)` and `table.lookup_value(key)` exist today and
return `(T, bool)` rather than `Option(T)`. Adopting this proposal would change
their result *type*, not their names or their trapping behavior — except for
`get`/`lookup_value`, where the shipped name is `lookup_value` and this table's
`get` remains a proposal.

**`find` is unresolved** (open decision 8). `Option(^mut V)` trades a place
result for a nullable, storable address — the same trade section 7 declines
for `inout`. `Option(inout V)` isn't available either, since a mode can't be
written on a field. Either `find` accepts stepping down to a pointer, or it
stays a place-returning operation outside `Option`.

### 5.6 Receiving values

```odin
entry := parse_entry(line) or_return; // `entry` has the payload type
fmt.println(entry.key, entry.value);

key, value := parse_entry(line) or_return; // fields move out of the temporary

port := config.get("port") or_else 8080;

switch (payload in parse_entry(line)) {
case .ok:  use(payload);
case .err: report(payload);
}
```

The initial API uses switches instead of an `is_ok()`/`value()`/`error()`
guard-and-accessor trio. A predicate alone does not establish static permission
to extract a payload. A switch gives that permission in the matching case and
supports both borrowed inspection and ownership transfer (section 4.3).

### 5.7 Ownership of stored and temporary results

Both operators produce a value, never a place alias into their operand. For
borrow-carrier payloads, that value retains the payload's original dependencies
as specified in section 5.8. The operand category determines ownership:

| Operand | Success, either operator | Failure, `or_else` | Failure, `or_return` |
| --- | --- | --- | --- |
| Place `result` | Copy the `T` payload; source stays live | Leave the source untouched, then evaluate fallback | Copy the `E` payload into the returned error; source follows normal scope cleanup |
| Temporary, or `move(result)` | Transfer the `T` payload | Drop the `E` payload before fallback | Transfer the `E` payload into the returned error |

For `Option`, the failure cases have no error payload to copy or drop.
`move(result)` consumes the whole binding before either branch; a plain place
is never implicitly consumed. A moved or temporary wrapper has one active
variant and at most one payload. Consume the payloadless case, or transfer/drop
its active payload, before suppressing wrapper cleanup. Never initialize an
inactive success payload on failure.

Copy requirements are checked statically for every possible branch: a place
operand requires copyable `T`, and `Result` propagation also requires copyable
`E`. `or_else` does not require copyable `E` because it never copies the error.
Normal copy-cost diagnostics, allocator selection, and clone-failure policy
apply. A failed clone leaves the source intact and cleans up its partial result;
it is not silently converted into the operation's `E` failure.

```odin
pending := fs.open(path);              // Result(File, Io_Error)
file := move(pending) or_return;       // no clone; pending is now dead
// A plain `pending or_return` would require copying the move-only File.
```

The fallback is initialized as an ordinary value: a place fallback copies,
while a temporary or explicit `move` transfers. Only the selected branch runs.
A stored result that merely needs inspection uses the borrowing switch rather
than copying its payload to test the tag.

### 5.8 Borrow provenance is a migration prerequisite

The current checked boundary does not follow every borrow stored inside an
ordinary aggregate. Wrapping must not make a previously rejected lifetime
escape compile, nor make a previously checked allocation root impossible to
release. Repair that boundary before routing standard producers through
`Option`, `Result`, or record results.

First demonstrate the rule with existing record syntax:

```odin
View :: struct { bytes: []u8 }

bad :: proc() -> View {
	bytes := [dynamic]u8{1, 2, 3};
	return View{bytes[:]}; // must be rejected, just like returning bytes[:]
}
```

The same rejection must hold after wrapping the result in `.some(...)` or
`.ok(...)`, moving it through a local, or extracting and returning its field.
This is a required change to checking, not a claim that the compiler already
rejects the example.

- Copying a stored pointer, slice, or view preserves the original borrowed
  root. Loading it from a field does not invent a borrow of the wrapper.
- Address-taking and `inout` projections depend on the storage they address.
  Moving an owner transfers its region and contained-borrow dependencies;
  the new owner does not borrow the dead source binding.
- Construction, cloning, movement, destructuring, switch narrowing, fallback,
  and propagation preserve these distinctions through records, fixed arrays,
  unions, and containers. Keep independent fields distinct when known; join
  conservatively where indices or control flow hide that distinction.
- Preserve mutable-borrow exclusivity, allocator-region obligations, and any
  known allocation-base identity needed by checked `free`. Raw conversions
  remain explicit trust boundaries; a wrapper or `forget` does not extend a
  lifetime or prove an unknown address safe.

Phase 4a of `language-refinement-strategy.md` gates the aggregate migration.
Phase 4b must establish usable borrow/retention contracts before the affected
APIs ship through procedure values or package boundaries. Test direct, generic,
and indirect calls, including a helper retaining a view in an `inout`
destination. An unavailable contract requires conservative checking or an
explicit trust boundary. This must work without `Option`-specific checking,
runtime provenance metadata, or boxing.

#### Stored content and container operations

The useful addition from the older
[`provenance-plan.md`](provenance-plan.md) is to describe what happens to
contained dependencies at each operation. A type's ability to contain a borrow
does not mean every value of that type borrows something: an empty container
or `.none` has no element/payload dependencies. An owner can independently
retain an allocator-region dependency even when it has no elements.

| Operation | Required dependency behavior |
| --- | --- |
| Construct, append, or insert | Associate the dependencies of values actually stored with the destination; an unsuccessful operation does not invent an inserted value |
| Replace a known field or the whole value | Replace that destination's old content dependencies after successful value preparation; do not erase dependencies of unrelated fields or surviving copies |
| Read a stored carrier by value | Preserve that carrier's original roots; accessing the slot during the read does not make the returned value borrow the container |
| Take an address or return an entry place | Borrow the container storage being addressed, with its invalidation rules, as well as any dependencies reached through that place |
| Remove or pop an element | Transfer or copy the returned value under the operation's ownership policy, preserving its dependencies independently of the container |
| Clear or drop contents | End the dependencies held only by those contents; independent returned values, copies, and outstanding borrows are not erased |

These rules follow each operation's actual success/failure contract, including
ownership of a supplied value on failed insertion. They do not change cloning,
allocation failure, or invalidation policy. Clearing contents neither resets
the allocator region nor necessarily releases the container's backing storage.
A live entry-place borrow can prevent clearing or removal in the first place.

A prototype may join content dependencies into one set when an index or key
cannot be distinguished statically. With that approximation, removing one
element can leave its dependencies conservatively attached to the container;
it must not clear dependencies belonging to other elements. Full replacement
or clearing can reset the content set, while dependencies of surviving values
remain live. Measure the false rejections before accepting this approximation
as the implementation strategy; do not make "everything ever inserted"
the permanent meaning of a container.

#### Retention into mutable and static storage

Extend result contracts with a separate description of which source arguments
may be retained in which `inout` destination or mutable receiver. Include
contained roots and regions, and retain field distinctions where known. A
direct call substitutes its actual dependencies into those destinations; the
caller checks their required lifetimes. Passing a borrowed argument is not by
itself permission for the callee to store it after the call. A may-retain
summary can conservatively add dependencies; clearing or replacing them
requires proof of that effect.

Procedure values must carry the selected contract, or be checked conservatively
when it is unavailable. The old plan's assumption that every mutable argument
retains every borrowed argument is a fallback to evaluate, not the final
meaning of indirect calls. A resource wrapper can represent ownership transfer;
it does not solve arbitrary borrowed-data retention or excuse lost contracts.

Checked stores into file-scope or `static` storage require dependencies valid
for process duration, unless a checked contract proves a shorter retention
interval. `thread_local` storage instead requires the appropriate thread
duration. A parameter may supply such storage only when its caller-visible
contract establishes that lifetime. Do not reject all parameter-derived stores
unconditionally, or assume a heap allocation can never be freed. Known TLS
roots must not be mistaken for process-duration roots; cross-thread checking
remains a separate boundary.

The checks must cover bare views and nested destination fields, not just
managed owners or assignments to a simple global name. Unknown provenance is
an unchecked boundary, never proof that a stored borrow outlives its destination.
Likewise, loading a pointer from a mutable global does not make its pointee
process-lived merely because the pointer slot has a static address. Without a
usable checked contract, retain the explicit unsafe obligation.

These checks extend the current documented unchecked retention/global-store
boundary. Adopt them with the corresponding specification and fixture changes;
raw addresses, foreign retention, and cross-thread transfer still need explicit
boundary documentation rather than a claim of complete memory safety.

#### Corrections to the older plan

Reuse its motivating programs and analysis-cost concerns, not its complete
implementation checklist. For example, its proposed reclassification of
`store_in_a_record_field` as an error is too broad. This must remain legal:

```odin
Holder :: struct { view: []int }

wrap :: proc(values: []int) -> Holder {
	return Holder{values}; // retains the caller's original borrowed root
}

unwrap :: proc(holder: Holder) -> []int {
	return holder.view;   // does not borrow the callee-local holder binding
}
```

Calls still require the original root to remain live. In contrast, the old
`hidden_alias` example must reject a write conflicting with the stored `^int`
borrow. Under today's capability rules, `^T` is immutable and `^mut T` is
mutable; an aggregate must preserve each contained carrier's capability and
reborrow rules rather than assign one capability to all its fields.

Do not import the blanket `unsafe.forget_provenance` builtin. Prefer existing,
narrow raw conversions and audited resource APIs; any future root-erasure
operation needs separate evidence and must preserve region and ownership
obligations. It is distinct from `unsafe.forget`, which suppresses cleanup.
Also do not adopt the old exclusions on public contracts, its fixed diagnostic
numbers, or its assumption that particular adapters do not exist. The rebased
[`consolidation-provenance-plan.md`](consolidation-provenance-plan.md) covers
these corrections; recheck its source inventory before implementation.

## 6. Cleanup, stack storage, and removal of `manual`

### 6.1 Three independent questions

`manual` is easy to confuse with allocation, but these are separate: (1)
where a variable's fixed-size representation lives (its stack frame,
regardless of `manual`), (2) whether it owns separately allocated backing
storage and from which allocator, and (3) whether scope exit invokes `drop`.
`manual` controls only (3) — it does not force heap allocation. `new(T)` is
the operation that allocates and returns a pointer.

The proposal removes the `manual` declaration modifier and keeps the other
two distinctions. This also leaves the modifier grammar with one axis
(duration: lexical / `static` / `thread_local`) instead of two — reason
enough to keep those as storage modifiers rather than move them to
attributes, since `design.md` already reserves modifiers for storage
duration/address stability/cleanup and attributes for linkage/visibility, and
moving duration there would put initialization/liveness/`move`/`drop`/`via`
rules into a category a portable program may ignore.

### 6.2 Ordinary lexical owners always clean up

```odin
file := fs.open(path) or_return;
// dropped automatically at scope exit

drop(file);              // early, explicit cleanup
destination := move(source);
consume(move(destination)); // ownership transfer stays explicit
```

Conditional liveness still ensures a moved or explicitly dropped binding
isn't dropped again at scope exit.

### 6.3 Resource-specific ownership escape is preferred

```odin
raw := move(file).into_raw(); // consuming receiver; `file` becomes dead
foreign_adopt(raw);
```

`into_raw` moves resource state out (or makes the local owner inert) before
automatic cleanup would run; `File.from_raw(raw)` is the unsafe inverse. This
is clearer than changing the cleanup policy of every `File` variable.

### 6.4 `unsafe.forget(move(value))`

For the rare generic case, `core:unsafe` provides a compiler special form
with exact semantics: the operand must be a live lexical value written with
`move`; ownership is consumed and the source binding becomes dead; no `drop`
hook runs; nothing is moved to the heap or given an extended/stack-preserved
address.

For an inline plain value the stack bytes just disappear with the frame; for
a dynamic array the small header stays on the stack but its backing
allocation is deliberately leaked; for a file the OS handle is deliberately
left open. Most uses are therefore a deliberate leak or the last step of a
handoff whose recipient already took responsibility. It's still invalid to
retain a stack address across a forgotten owner's frame return —
`unsafe.forget` suppresses `drop`, it doesn't extend the frame.

### 6.5 Manual allocation remains pointer-based

```odin
pointer := new(Item) or_return;
pointer^.initialize();
free(pointer);
```

This is manual *allocation*, distinct from a manual *local variable* — the
pointer lives in the stack frame; the `Item` lives in allocator-provided
storage. The spec should use distinct terms: **automatic owner** for
lexical-cleanup values, **allocation root** for `new`/`new_clone` storage,
**forgotten owner** only for explicitly suppressed cleanup — never "manual"
for both cleanup policy and allocation roots.

### 6.6 Raw inline storage is a separate unsafe abstraction

Removing `manual` doesn't solve partially initialized fields or custom
containers needing raw element storage. If real implementations need it, add
a narrowly scoped `unsafe.Maybe_Uninit(T)` with explicit initialize/take/
destroy operations — don't repurpose `forget` for it, and don't add a broad
`Manual(T)` wrapper just to recreate the removed modifier.

## 7. `inout` remains a call capability

`inout T` means more than "the ABI passes a pointer": the argument is
non-null, denotes an assignable caller-owned place, grants exclusive mutable
access, is visibly requested at the call site, is bounded to the call, and
warns that mutation may invalidate borrows from the whole owner. Replacing it
with `^mut T` would make every mutating procedure accept a nullable, storable
address and push retention/escape correctness toward the unchecked boundary —
possibly fine for a lower-level language, but not a redundant-syntax removal.

```odin
sort_in_place :: proc(values: inout [dynamic]int) { values.sort(); }
sort_in_place(inout values);
values.sort(); // method syntax supplies the receiver borrow
```

An `inout` parameter is a call slot, not an argument-record field — one more
reason calls reuse record-style matching without constructing a record:

```odin
copy_into :: proc(destination: inout Buffer, source: []u8, offset: int = 0)
	-> Result((), Error) { ... }

copy_into(source=bytes, destination=inout buffer) or_return;
```

**`inout` results stay, provisionally.** Place-returning indexing and
user-defined mutable projections use `inout` results today; replacing them
with `^mut T` would turn a place expression into a nullable first-class
value with different assignment/address-taking rules. This deserves a
focused later review, tied to `find` (section 5.5) since it's the same
question for a container operation.

**No primitive/object split.** A type `T` is the same type whether it's a
local, a field, an array element, behind `^mut T`, or an `Option`/`Result`
payload. No method call, interface check, generic instantiation, `Option`, or
`Result` implicitly boxes a value — generics stay monomorphized. A mutable
receiver stays behavior of `T` via `inout self`, not a separate method on
`^mut T`.

## 8. Worked examples

### 8.1 Configuration parsing

```odin
Entry :: struct { key: string_view, value: int }

parse_entry :: proc(line: string_view) -> Result(Entry, Parse_Error) {
	separator := line.find('=').ok_or(Parse_Error.Missing_Separator) or_return;
	value := parse_int(line[separator + 1:]) or_return;
	entry := Entry{line[:separator], value};
	return .ok(entry);
}

load :: proc(lines: []string_view, into: inout map[string_view]int)
	-> Result((), Parse_Error) {
	foreach (line in lines) {
		entry := parse_entry(line) or_return;
		into[entry.key] = entry.value;
	}
	return .ok(());
}
```

One result per procedure, no trailing status, no named result locals, no
tuple type. `Parse_Error` is an ordinary enum — no nil member needed, since
the `Result` tag carries success.

`load` retains borrowed keys in `into`. Its call contract must expose that the
backing text must outlive the retained entries; returning `Result` does not
make that retention safe by itself (section 5.8).

### 8.2 Iterator

```odin
Iterator :: interface($Self: type) {
	Element: type;
	slot next: proc(self: inout Self) -> Option(Self.Element);
}

next :: proc(self: inout Line_Iterator) -> Option(string_view) {
	if (self.done) { return .none; }
	return .some(self.read_line());
}
```

The loop asks one value whether an element is present, rather than
interpreting a trailing `bool` specially.

### 8.3 Anonymous product payload and consuming destructure

```odin
partition :: proc(values: []int, pivot: int) -> (below: int, equal: int, above: int) { ... }

counts := partition(values, 10);
below, equal, above := counts; // clones three `int` fields; `counts` stays live
```

```odin
read_document :: proc(path: string_view)
	-> Result((name: string, bytes: [dynamic]u8), Io_Error) { ... }

name, bytes := read_document(path) or_return; // consumes the temporary: no clone

document := read_document(path) or_return;    // contrast: binding first...
name_copy, bytes_copy := document;            // ...then destructuring clones both
```

Both forms are legal and visibly different, under section 1.4; the copy-cost
diagnostic reports the second one.

### 8.4 Stack storage and foreign handoff

```odin
buffer: [4096]u8 = {};
arena := mem.Arena.from_buffer(buffer[:]);
values: [dynamic]int via arena.allocator() = {};
values.append(1, 2, 3); // backing elements live in `buffer`
```

Removing `manual` changes none of these locations; it only guarantees
`values` and `arena` clean up normally when live at scope exit.

```odin
socket := net.open(address) or_return;
native := move(socket).into_raw(); // preferred: no automatic close remains
foreign_library_adopt_socket(native);
```

For a separate handoff when no consuming conversion exists:

```odin
socket := net.open(address) or_return;
foreign_library_adopt_handle(socket.native_handle());
unsafe.forget(move(socket)); // visibly unsafe: compiler can't prove the handoff
```

## 9. Related `design.md` items to resolve alongside this proposal

- **`@(require_results)` should attach to a type, not only a procedure.**
  Once failure is a value, discarding a `Result` is the new silent-error bug,
  with no trailing status left to notice. Allowing the attribute on a type
  declaration lets `Option`/`Result` carry it once instead of annotating
  every fallible procedure in the standard library.
- **The `try_` family should be re-examined.** `append`/`try_append`,
  `reserve`/`try_reserve`, etc. double the container API over a
  failure-policy choice; typed propagation makes the fallible variant cheap
  enough that keeping both spellings needs re-justifying.
  `Small_Array.try_append -> bool` becomes the last bare-`bool` failure in the
  language and should likely become `Result((), Capacity_Error)`.
- **Is `()` a new zero-sized type category, or the anonymous spelling of an
  already-legal empty struct?** `Result((), E)` puts `()` in every
  no-payload fallible signature in the standard library, so this needs an
  answer before the spelling ships (open decision 5).
- **Storage modifiers stay modifiers.** Removing `manual` reduces the
  modifier grammar to one axis and makes it more orthogonal — see section
  6.1 — so `static` and `thread_local` should not move to attributes.

## 10. Mechanism inventory

This is the systematic add/delete accounting the refinement strategy's decision
process requires (see
[`language-refinement-strategy.md`](language-refinement-strategy.md),
"Mechanism inventory"). It generalizes the named-variant cost note in section
4.4 to the whole proposal, and exists to answer one question under the
strategy's design law 5: does this proposal delete more independent semantic
rules than it adds? It is organized by the strategy's nine inventory axes.

### How to read this

Two attribution rules keep the tally honest:

1. **Pre-committed provenance is not charged to this proposal.** "Wrapping a
   checked borrow preserves its obligations" is already an acceptance criterion
   and initial decision of the refinement strategy, and its Phase 4a/4b own it
   *regardless of whether this proposal is adopted*. So the section 5.8
   aggregate-provenance and retention rules are marked **[P4]** and excluded from
   the proposal's net. Only the ownership rules that exist *because* a new
   construct exists (destructure, switch binding, `or_else`/`or_return`) are
   charged here.
2. **Declining a pending proposal counts as an avoided add, not a delete.** The
   tuple family and compiler-owned `Option`/`Result` do not exist today —
   `design.md` states `Option` is an ordinary union that "no language construct
   is aware of." Rejecting them (section 11) is scored as **avoided add**, not
   deletion, so the ledger never takes credit for removing something that was
   never there.

Net symbols: **−** proposal deletes a rule · **+** proposal adds one ·
**=** wash · **[P4]** pre-committed, excluded · **⊘** avoided add.

### Axis 1 — grammar and contextual parsing

| Baseline rule | Proposal | |
| --- | --- | --- |
| Named-result list `-> (x: T, y: T)` as multiple results | deleted; spelling repurposed | − |
| Named-result locals + bare `return;` | deleted (section 3) | − |
| `manual` storage modifier; modifier grammar has two axes | deleted; grammar reduced to one axis (duration) (section 6.1) | − |
| `union { T, U }` — type-list variants only | retained as the anonymous form | = |
| — | anonymous record type `(name: T, …)` at every arity, with "labelled iff record" disambiguation (section 1.2) | + |
| — | named-variant production `Member_Name ":" Type?`, all-named-or-all-anonymous, mandatory colon (section 4.2) | + |
| — | general destructuring in decl/assign/`foreach` (section 1.4) | + |
| — | `()` unit-type spelling (section 1.2) | + |

**Net: wash (≈ −3 / +4).** This axis does *not* net-delete. The adds are more
regular (one record production reused across type/literal/destructure/result
positions), but design law 5 is about rule count, and here it is roughly even.
Do not claim grammar simplification as a win; claim regularity instead.

### Axis 2 — type and value categories

| Baseline | Proposal | |
| --- | --- | --- |
| "Multiple results" as a special result category (not a value) | deleted → one record value (section 3) | − |
| Separate positional tuple family | not introduced (section 11) | ⊘ |
| Compiler-owned `Option`/`Result` type family | not introduced (section 5.1, section 11) | ⊘ |
| Anonymous union with type-discriminated variants | retained | = |
| — | anonymous structural record category (identity = ordered name+type) (section 1.2) | + |
| `Option`/`Result` | added as **library unions** — no new category (section 5.1) | +0 |
| Named-variant union | extends the union category — no new category (section 4.2) | +0 |
| — | `()` unit type — new zero-sized category *or* empty-struct alias (open decision 5) | +? |

**Net: −1 category, +1 category (structural record), +1 unit question.** The
decisive win here is what is *avoided*: `Option`/`Result` and named variants add
**zero** new type categories by reusing unions. That is the proposal's strongest
design-law-5 argument and it lives on this axis, not on grammar.

### Axis 3 — name / member lookup

| Baseline | Proposal | |
| --- | --- | --- |
| Variant extraction by payload type `.(T)` / `.as(T)` | retained for anonymous unions (section 4.4) | = |
| Enum member implicit selector `.name` | generalized to union variants (section 4.3) | + |
| — | per-union variant-name namespace; switch cases resolve by name (section 4.3) | + |

**Net: +1 lookup rule** (variant-name → variant), built on the *existing* enum
implicit-selector infrastructure, so no new resolution *engine* (per the
acceptance criterion that named variants add no lookup path beyond the existing
implicit selector). Because type-based extraction is kept alongside, the lookup
surface grows; it shrinks only if open decision 1 collapses to one union model.

### Axis 4 — argument / literal matching

| Baseline | Proposal | |
| --- | --- | --- |
| Call argument matching (positional/named/defaults/variadic) | folded into one shared **slot matcher** (section 2.1) | − |
| Record-literal field matching (separate) | folded into the same slot matcher (section 2.1) | − |
| — | one policy split on the shared step: defaults (calls) vs zero-fill (records) | + |

**Net: clear net-delete (2 matchers → 1 + 1 policy note).** Cleanest
consolidation in the proposal. Section 2.2's "a call is not an argument record"
preserves parameter modes/ABI without materialization — that is a *retained*
distinction, not a second matcher.

### Axis 5 — lifetime / ownership analysis

| Baseline | Proposal | |
| --- | --- | --- |
| named-result × definite-init × multiple-results × `or_return` interaction | deleted (section 3) | − |
| `manual` cleanup-suppression declaration state | deleted (section 6) | − |
| "nil means success" / `E`-must-be-nil-status constraint | deleted (section 5.1) | − |
| — | consume-vs-clone destructure by operand category (section 1.4) | + |
| — | switch-binding borrow/consume rules (section 4.3) | + |
| — | `or_else`/`or_return` ownership matrix — operand × operator × Option/Result (section 5.7) | + |
| — | constructor payload ownership (place clones, temp/move transfers) (section 4.3) | + |
| — | `unsafe.forget` semantics; `into_raw` convention (sections 6.3–6.4) | + |
| — | aggregate borrow provenance; container-op dependency table; retention-into-`inout`/static contracts (section 5.8) | **[P4]** |

**Net (proposal-attributable): −3 / +5.** This axis is add-heavy — but the
*largest* additions (section 5.8) are **[P4]** pre-committed provenance the
language owes whether or not this proposal ships, so they are excluded from the
proposal's charge. What the proposal genuinely adds is the ownership *matrix for
its own new constructs* (destructure / switch / operators / constructors). That
is real new analysis and the ledger should not pretend otherwise: **this proposal
is a net lifetime-rule ADD, and the honest defense is "each added rule is the
ownership semantics of a construct that deletes an older special case
elsewhere," not "fewer lifetime rules."**

### Axis 6 — compile-time evaluation

| Baseline | Proposal | |
| --- | --- | --- |
| — | implicit-selector construction requires complete expected type at CT (section 5.2) | + |
| — | constructor/destructure checked in generic + CT code (verification table) | + |

**Net: +2 minor rules.** Both are consequences of the selector/record adds, not
independent mechanisms.

### Axis 7 — runtime representation / ABI

| Baseline | Proposal | |
| --- | --- | --- |
| Multiple results → one `loke`-CC LLVM aggregate | unchanged; "one value" is source-level, backend still multi-register (section 3) | = |
| `(T, bool)` status aggregate | superseded by union layout | − |
| — | `Option`/`Result` layout = ordinary union (tag + max payload), no boxing (acceptance criteria) | +0 |
| — | named-variant layout must be measured vs an equivalent anonymous union (acceptance criteria) | + obligation |
| — | `()` ABI status (open decision 5); C-ABI for Option/Result payloads (open decision 12) | +? |

**Net: no new representation mechanism; two open ABI questions + measurement
obligations.** Reuses union layout; the cost is verification, not new machinery.

### Axis 8 — diagnostics

| Baseline | Proposal | |
| --- | --- | --- |
| Contextual "which result is status" for `or_else`/`or_return` | deleted — operates on a value (section 5.3) | − |
| copy-cost diagnostic | reused for cloning destructure (sections 1.4, 8.3) | = |
| — | destructure clone-vs-consume diagnostic (section 1.4) | + |
| — | `@(require_results)` on a type → discard diagnostics (section 9) | + |
| — | provenance rejection diagnostics | **[P4]** |

**Net: −1 / +2.** Roughly even; the deleted contextual rule is the valuable one
(it was a design-law-1 violation — meaning changed by destination).

### Axis 9 — library / compiler special cases

| Baseline | Proposal | |
| --- | --- | --- |
| named-result special handling | deleted | − |
| multiple-results special handling | deleted | − |
| `manual` special handling | deleted | − |
| `E`-must-be-nil-status special constraint | deleted (section 5.1) | − |
| `try_`/non-`try_` container API duplication | targeted for removal (section 9 — flagged, not decided) | −? |
| `Option` deliberately unknown to compiler (0 special cases today) | — | — |
| — | compiler recognizes `or_else`/`or_return` roles (open decision 2) | + |
| — | `@(require_results)` as a type attribute (section 9) | + |

**Net: −4 (firm) / +1–2.** Strongest net-delete axis — *if* open decision 2
resolves **structural** (a recognized two-variant protocol = one general rule).
If it resolves **by-name**, the `+` becomes "two special-cased library types,"
weakening this axis toward −4 / +2 and re-creating exactly the kind of
privileged-type special case the strategy warns against (its Phase 1b requires
operator recognition to identify the intended protocol explicitly, not turn any
unrelated two-variant union into an error result).

### Net tally

| Axis | Proposal-attributable net | Verdict |
| --- | --- | --- |
| 1. Grammar | ≈ −3 / +4 | **wash** — sell regularity, not deletion |
| 2. Type/value categories | −1 / +1, **+0 for Option/Result & variants** | **win** (reuse, no new category) |
| 3. Lookup | +1 (reuses selector infra) | small add |
| 4. Matching | −2 / +1 | **clear win** |
| 5. Lifetime/ownership | −3 / +5 (excl. [P4]) | **net add** — defensible, not deniable |
| 6. Compile-time | +2 minor | small add |
| 7. Representation/ABI | no new mechanism; open questions | neutral |
| 8. Diagnostics | −1 / +2 | wash |
| 9. Special cases | −4 / +1–2 | **win if decision 2 is structural** |

### Conclusion

The proposal **passes design law 5 on the axes it claims to** — matching (4),
special cases (9), and type categories (2, via reuse). It does **not** net-delete
on grammar (1) or lifetime analysis (5); on those it trades old special cases for
new *regular* rules. The correct claim is therefore **semantic compression, not
rule-count reduction** — which is what the strategy privileges (its rule that
semantic compression matters more than token compression).

Do not write "the proposal removes more than it adds" without qualification. The
true statement is: **it removes several destination-sensitive special cases and
one whole matcher, and reuses unions/records to add `Option`/`Result`, named
variants, and structural products with zero new type categories — at the cost of
a larger ownership-rule surface, most of whose weight (section 5.8) is provenance
work the language already owes independently.**

### Two decisions that move the ledger

- **Open decision 1 (one union model vs two).** Collapsing to one named model
  turns axis 3 from `+1` toward a delete (removes type-based extraction + nil
  state) and removes the "two semantic forms" cost on axis 2. Retaining both —
  this draft's concrete choice — is the ledger's biggest un-booked liability.
- **Open decision 2 (`or_else`/`or_return` by-name vs structural).** Structural
  keeps axis 9 a clean net-delete; by-name re-introduces privileged-type special
  cases. This single choice is the difference between the proposal's headline
  claim holding and not holding.

## 11. Rejected alternatives

- **`Option`/`Result` as products with a validity flag.** Constrains `E` to
  nil-status types, keeps an inactive payload alive, needs guard-then-trap
  accessors, and still pays for a tag to distinguish `.some(nil)` from
  `.none`. A union pays for the tag once and honestly.
- **Compiler-owned `Option`/`Result`.** Adds a second lookup/construction
  path for two types instead of reusing the general union mechanism.
- **Separate positional tuples (`(T, U)`).** Would duplicate layout,
  lifecycle, reflection, formatting, and destructuring rules that anonymous
  records already provide, once multiple results are gone.
- **A guard-and-trapping-accessor trio as the primary result API.** A predicate
  does not establish static narrowing. Switches provide scoped access and an
  explicit borrowing/consuming distinction without a separate trapping
  accessor. This does not prohibit ordinary nontrapping predicate methods.
- **Consuming destructuring of records with custom lifecycle hooks.** Field
  transfer cannot account for resource obligations owned by the containing
  record's hook. Use an ordinary consuming conversion for such types.
- **Bare payloadless variant declarations alongside anonymous unions.**
  `union {A, B}` already means a list of types. Requiring `A:`/`B:` for named
  variants makes the distinction syntactic and independent of name lookup.
- **Omitting a unit constructor argument.** `.ok(())` follows the same
  one-payload rule as `.ok(value)`; `.ok()` would need an extra rule that also
  applies to every user union with a unit payload.
- **Forbidding mixed positional/named record literals.** Calls must permit
  `f(a, name=b)`, and calls and literals share one slot matcher, so
  forbidding mixing only in literals is an arbitrary asymmetry.
- **Calls as first-class argument records.** Parameter modes, variadics,
  defaults, call borrows, evaluation order, and ABI classification aren't
  ordinary record-field semantics; the shared slot matcher gets the useful
  regularity without materialization.
- **Replace `inout` with `^mut T`.** Trades a non-null, exclusive,
  call-bounded capability for a nullable, storable address, and would tend to
  move mutable methods onto pointer types.
- **Keep `manual` as a declaration policy.** Automatic cleanup plus `drop`,
  `move`, consuming raw conversions, and unsafe `forget` cover its lexical
  use cases with fewer declaration states — pending validation against real
  custom-container and foreign-ownership code.
- **Make every anonymous record nominal by occurrence.** Two identical
  helper signatures would produce incompatible types, and an anonymous
  result would be hard to reproduce outside its declaration.

## 12. Open decisions

These are adoption decisions, not permission for an implementation to choose
different behavior silently. Until a decision changes the text, the concrete
rules above define this candidate. Record evidence and revise the affected
sections before implementation:

1. Does retaining anonymous unions justify their distinct nil, extraction,
   and reflection rules, or should all unions migrate to one named model?
   This candidate retains both with disjoint syntax and forbids mixing; the
   refinement strategy prefers one model. Compare both before adoption.
2. Should `or_else`/`or_return` be specified by name over the two `base:`
   types, or structurally over any two-variant union with a designated
   failure variant?
3. What replaces `active_typeid()` for a named-variant union whose variants
   may share a payload type — a variant-index accessor, reflection only, or
   restricting `active_typeid()` to anonymous unions?
4. Is `.ok(T{})` an acceptable zero value for `Result(T, E)`, or should a
   named union be allowed a non-first zero variant, or none at all?
5. Is `()` a new zero-sized type category, or the anonymous spelling of an
   already-legal empty struct?
6. Is flat destructuring sufficient? Do ordinary consuming conversions cover
   records excluded by the visibility and custom-lifecycle restrictions?
7. Should anonymous record identity include field names, or only ordered
   field types? This draft includes names to preserve field access.
8. Does `table.find(key)` return `Option(^mut V)`, or stay a place-returning
   operation?
9. Which real implementation case, if any, still needs an undropped inline
   owner after `manual` is removed? That case should shape the unsafe
   raw-storage primitive.
10. Can every foreign ownership transfer expose a consuming `into_raw`,
    leaving `unsafe.forget` a rare last resort?
11. Do `inout` results justify their place-expression semantics
    independently of `inout` parameters and receivers?
12. What exact ABI guarantee should `Option`/`Result` make for C-compatible
    payloads and exported Loke procedures?

## 13. Proposed migration order

The refinement strategy governs adoption. Named variants can be prototyped
without anonymous records, but changing a producer to return a wrapper is not
safe to ship merely because its new syntax and layout work. Provenance,
ownership, and caller migration are gates.

1. Characterize current multiple results, named results, argument matching,
   optional-ok producers, status propagation, `manual`, and `inout`. Include
   move-only values, custom hooks, partial failure, and the current unchecked
   aggregate boundary as baseline cases, not guarantees to retain.
2. Complete the bounded producer-spelling migration in strategy Phase 1a under
   the existing status protocol. This can ship without adopting this proposal;
   keep validating conversions unchanged during that phase. **Done.** `value.(T)`
   is permanently trapping and single-valued, `value.as(T)` is the optional
   `(T, bool)` spelling, `table[key]` is a single-value read, and
   `table.lookup_value(key)` is its `(V, bool)` form. Validating conversions are
   unchanged, and nothing here adopts this proposal.
3. Establish aggregate provenance with existing records and unions (Phase 4a),
   and usable call/retention contracts for affected public and indirect APIs
   (Phase 4b). This work can proceed alongside step 2. It must pass the
   bare-versus-wrapped, container-content, and storage-escape checks in section
   5.8 before value migrations ship. Preserve the valid borrowed-parameter
   cases when migrating the old trust-boundary fixtures.
   The [second implementation plan](consolidation-provenance-plan.md) covers
   this gate and supersedes the historical provenance checklist. **Done.** A
   borrow keeps its obligations inside a record, union, or container; direct,
   cross-package, generic, and indirect calls carry result and retention
   contracts; and retention into process, thread, and caller-owned storage is
   checked at both ends, through `inout` parameters and through pointers alike.
   `wrap`/`unwrap` stayed legal throughout. What remains is precision rather than
   a missing contract: a destination reached through a pointer held in a variable
   records the borrow against the pointer rather than against its pointee.
4. Compare typed fallibility against retaining the status protocol. Resolve
   union identity, zero/default behavior, unit representation, operator
   recognition, and ABI questions together. Record any reversal of the current
   `design.md` decision not to give `Option` a standard-library/operator role.
5. If adopted, implement the selected union rules, unit product, ordinary
   `base:` declarations, constructor ownership, switch borrowing/consumption,
   reflection, and lifecycle support. Test the operator ownership matrix from
   section 5.7, not just calls returning temporary wrappers.
6. Migrate fallible producers, their callers, and `or_else`/`or_return`
   together. Include extraction, lookup, conversions, `pop`, iteration,
   allocation, generated `try_clone`/copy hooks, and library procedures. Delete
   the old optional-ok/status protocol only with that migration. Steps 5–6
   form one adoption change; do not leave two supported propagation protocols.
   If anonymous records are not ready, use named records for multiple payloads.
7. Implement structural anonymous records and general destructuring together
   with migrating procedures to one result and removing named-result locals.
   The labelled-parenthesis rule and removal of its old meaning land in the
   same change. Preserve the single `inout` result form.
8. Validate real manual-storage cases; add consuming raw conversions and
   `unsafe.forget`, plus narrowly scoped raw-storage operations only if needed.
   Migrate those cases and then remove `manual`. Do not remove it before its
   required replacements and cleanup tests exist.
9. Keep `inout` through these changes. Review `find` and place results
   separately; an unresolved lookup contract is not a shipped API. Changes to
   map insertion or clone/failure policy also need their own recorded decision.

Update `design.md`, `grammar.md`, `base`, `core`, examples, and tests in each
vertical change. Steps 5–6 may precede step 7 only after the provenance gates
pass; they do not depend on the anonymous-record spelling. Library wrappers
must not receive privileged provenance treatment to make that order work.

### Provenance implementation constraints

The focused provenance plan should reuse the current control-flow events and
root/region analysis where possible, while preserving the contracts above:

- Compute recursive carrier shapes with a cycle-safe fixed point or equivalent
  algorithm. Encountering an in-progress type is not evidence that it carries
  no borrows; do not finalize a negative result that depends on an unfinished
  cycle. A `Node` record containing both `[dynamic]Node` and `[]int` fields must
  give the same answer regardless of field order or which type is queried first.
- Distinguish a type that can contain borrows from a particular value's live
  dependencies. Preserve separate root, region, and ownership facts through
  copies, moves, and allocator-directed clones.
- Extend the existing summary worklist for retention as appropriate. Public
  and indirect-call contracts must survive the relevant boundary; the current
  compiler's in-memory representation is not a language restriction.
- Measure analysis time, peak memory, slot/loan counts, and false rejections
  on representative programs. The current reaching state grows with control-flow
  blocks times slots times loans. Establish a baseline and an explicit budget
  before expanding it to aggregates; revise dense storage or slot creation if
  needed instead of dropping dependencies to stay within the budget.

Compiler implementation choices do not add runtime provenance metadata or
waive optimization-level tests. The value and cleanup migrations still change
lowering even if provenance checking itself adds no runtime representation.

### Required verification cases

These are tests to add during implementation, not claims that the current
compiler accepts the proposed syntax or implements these rules:

| Area | Required evidence |
| --- | --- |
| Variant grammar and identity | Anonymous `union {A, B}` versus named `union {A:, B:}`, including matching type names in scope; reject mixed lists and unresolved anonymous types; keep `Result(int, int)` variants distinct |
| Unit and payloadless construction | Accept `.ok(())` and `.none`; reject `.ok()`, `.none()`, and wrong payload counts; check explicit and contextual constructors in generic and compile-time code |
| Record destructuring | Place copies versus temporary/`move` transfers; ignored move-only fields do not clone; discarded owning fields drop once; reject consuming records with custom hooks and any destructure hiding private fields |
| Partial failure and assignment | A later failing clone cleans earlier temporaries without writing destinations; an already executed `move` stays consumed; test reverse cleanup and every supported panic strategy |
| Stored result operators | Exercise both tags and every row of section 5.7 with move-only success and error types; count clones/drops and fallback evaluations; reject forbidden copies |
| Switch inspection | Borrow a stored move-only payload without cloning; reject consuming a borrowed binding; consume a temporary or moved union once; cover grouped cases, defaults, `_`, and early exits |
| Root and region provenance | Match bare and wrapped borrow diagnostics through nested records, arrays, unions, and containers; reject local escapes, conflicting mutation, invalidation, and region reset; retain independent-field precision |
| Container content changes | Cover successful and failed insertion, known-field replacement, unknown-index removal, clear, and whole replacement; surviving returned values keep their dependencies; empty containers and `.none` acquire no fictitious payload loans |
| Storage escapes and valid returns | Keep `wrap`/`unwrap` of caller borrows legal; reject retained locals in longer-lived destinations and writes conflicting with stored immutable borrows; distinguish process and TLS durations; unknown provenance is not a checked lifetime proof |
| Procedure boundaries | Preserve declared or inferred dependencies through direct, generic, package, and procedure-value calls; check retention into `inout` destinations and allocation-base identity needed by `free` |
| Recursive analysis and cost | Vary field order and first-query order for recursive carrier types; preserve mixed immutable/mutable capabilities; record solver time, peak memory, and conservative rejections against the agreed budget |
| Cleanup and ABI | Trace constructor, propagation, destructuring, raw-transfer, and `forget` cleanup; measure layout and calling convention changes for managed, unit, and C-compatible payloads |

Run the full `test-all.ps1` matrix at every optimization level for each adopted
vertical change. Compare generated IR and runtime behavior where the change is
intended to affect only source syntax, and record intentional cost or ABI changes.

## Acceptance criteria

- every expression has one stable type and arity;
- each producer has a fixed result contract and mismatch/failure policy;
  payload access through a switch is valid by static narrowing;
- calls and record literals share one diagnosable slot-matching algorithm;
- parameter names stay outside procedure type identity;
- procedures expose at most one result value;
- wrapping and transferring `Option`, `Result`, and record payloads introduce
  no allocation or boxing beyond the payload's ordinary operations; explicit
  and implicit clones retain their documented costs and failure policies;
- named-variant union layout is measured against an equivalent anonymous union
  with the same payloads and number of states;
- named variants add no lookup path beyond the existing implicit selector;
- named and anonymous variant lists are distinguished by syntax, not name
  lookup, and unit payloads obey the ordinary constructor arity rule;
- managed payloads drop exactly once through success, failure, fallback,
  propagation, movement, destructuring, and partial initialization;
- destructuring an owning record clones or consumes per its operand
  category, never leaving a partially moved place, skipping a private field,
  or bypassing a containing record's custom lifecycle hooks;
- stored result operators never implicitly consume their source; borrowed
  switch bindings cannot be moved or dropped as owners;
- bare and wrapped borrows preserve root, region, and call-contract obligations
  through construction, extraction, movement, and return;
- container mutations update the appropriate content dependencies without
  erasing surviving borrows or attaching a synthetic container borrow to a
  loaded carrier; checked retention cannot use unknown provenance as proof;
- recursive provenance results are independent of traversal order, and analysis
  cost and conservative rejections are measured before adopting a shortcut;
- anonymous records create no incoherent inherent behavior;
- removing `manual` changes no stack placement, allocator selection, or
  backing-storage location;
- `forget` cannot be mistaken for a lifetime extension;
- allocation roots still require explicit release or transfer;
- mutable calls retain the existing `inout` capability and borrow
  diagnostics;
- no scalar, record, pointer, or container needs implicit boxing to use
  `impl`, generics, or static interfaces;
- source and generated ABI changes are intentional, measured, and
  documented.
