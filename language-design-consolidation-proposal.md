# Loke language consolidation proposal

Status: discussion draft

This document proposes one coherent resulting language after applying the
principles in [`language-refinement-strategy.md`](language-refinement-strategy.md).
It is deliberately concrete so that examples, interactions, and costs can be
evaluated together. Nothing here is normative until it replaces the relevant
rules in [`design.md`](design.md) and [`grammar.md`](grammar.md).

## Summary of the proposal

The proposal makes these choices:

1. Loke has records, but no separate tuple type.
2. An anonymous record, written `(field: Type, ...)`, is the lightweight product
   type for temporary groups of values. A named struct remains the normal public
   API type.
3. Records have both field names and declaration order. Named and positional
   construction are two ways to initialize the same record, not two kinds of
   value.
4. Calls use the same ordered-and-named slot-matching rule as record literals,
   but a call's arguments are not materialized as a record value.
5. A procedure returns zero or one value. A record carries several success
   values.
6. `Option(T)` represents absence and `Result(T, E)` represents failure. Both
   are inline values and never imply allocation or boxing.
7. `or_else` and `or_return` operate on `Option` and `Result`, not on a trailing
   result whose type is interpreted contextually as status.
8. The `manual` storage modifier is removed. Lexical owners are cleaned up
   automatically; `drop`, `move`, resource-specific `into_raw`, and an explicit
   unsafe `forget` cover manual control.
9. `manual` allocation through `new`/`free` remains a separate low-level
   facility. Removing the `manual` declaration modifier does not remove manual
   allocation.
10. `inout` parameters, receivers, and place results remain. Their non-null,
    exclusive, call-bounded contract is not replaced by nullable, storable
    pointers in this proposal.
11. Values remain values regardless of whether they live inline, own backing
    allocation, or are reached through pointers. `impl` and generics remain
    available for every type category, with no Java-style primitive/object
    split.

The proposal is intentionally conservative about `inout` and aggressive about
multiple results and `manual`. Those decisions follow semantic cost rather than
surface symmetry.

## 1. One product model: records

### 1.1 Named records remain nominal

A named struct declaration creates a distinct nominal type, as it does today:

```odin
Point :: struct {
	x, y: f64,
}
```

`Point` owns its inherent `impl` blocks, lifecycle hooks, coherent formatting,
and other behavior. Another named struct with the same fields is a different
type.

Named records should remain the default for:

- exported procedure inputs and results;
- domain concepts;
- values with invariants;
- values with inherent methods or lifecycle hooks; and
- values whose name improves diagnostics or documentation.

### 1.2 Anonymous records replace the proposed tuple family

An anonymous record is an exact structural product type. It reuses the current
named-result shape, but the names are fields of one value rather than local
result variables:

```odin
(key: string_view, value: int)
```

The `struct` keyword is intentionally absent. It remains on a named declaration
such as `Entry :: struct {...}` because that spelling creates a nominal type
with a declaration site and inherent behavior. In contrast,
`Entry :: (key: string_view, value: int)` would be an alias for the structural
anonymous record.

Its identity is determined by the ordered sequence of field names and field
types. Field order participates because it determines positional construction,
destructuring, and layout. Two anonymous records with the same fields in a
different order are different types.

The initial form is deliberately restricted:

- every field is named and public;
- fields are compared exactly; there is no width subtyping;
- `using`, private fields, layout attributes, and padding fields are not
  permitted;
- an anonymous record has no declaration site and therefore cannot have an
  inherent `impl` block or lifecycle hook; and
- copy, move, drop, equality, reflection, and formatting behavior is derived
  structurally from its fields where the corresponding operation exists.

Code that needs any excluded facility names a struct instead. This prevents
anonymous structural types from creating an ownership or coherence problem for
methods.

This is not a second tuple category. It reuses struct field selection, layout,
lifecycle recursion, reflection, literals, and generic type arguments. The
language does not add positional types such as `(int, string)` whose elements
have only numeric names. Parentheses carry the compact type shape; contextual
record values continue to use braces:

```odin
entry: (key: string_view, value: int) = {key="port", value=8080};
```

Using `{key: string_view, value: int}` for the type would be possible in a type
context, but it would make braces mean a block, a composite value, and a type.
It would also produce visually awkward signatures such as
`proc() -> {x: int} { ... }`. The labelled parenthesized form avoids those
collisions and reuses syntax Loke already has for named results.

The empty anonymous product is `()`. It is the zero-sized unit type and has one
value, also written `()`. This avoids a separate predeclared `unit` name.

### 1.3 Construction is both positional and named

A record's fields are ordered and named. Its literal may initialize them
positionally, by name, or with positional entries followed by named entries:

```odin
Point{1, 2}
Point{x=1, y=2}
Point{1, y=2}
```

The matching rule is:

1. A positional initializer fills the next unfilled field.
2. A named initializer fills the field with that name.
3. Positional initializers must precede named initializers.
4. A field may be filled only once.
5. A purely positional literal supplies all fields, as today.
6. A literal containing a named initializer may omit fields; omitted fields
   receive their zero values, as today.
7. Initializer expressions are evaluated from left to right in source order.

Allowing `Point{1, y=2}` is not essential, but it makes calls and record
construction use the same visible matching rule. If mixed record construction
is found to reduce readability, it can be rejected without changing the product
model.

### 1.4 General record destructuring replaces result-only destructuring

Once procedures no longer produce a special list of results, multiple bindings
can consistently mean positional destructuring of one record:

```odin
entry := read_entry() or_return;
key, value := entry;
```

The record must have exactly as many directly declared visible fields as there
are bindings. Fields are bound in declaration order. A binding may be `_`.
Destructuring is flat in the initial design; nested patterns can be considered
separately.

The same rule applies to declaration, assignment, and value `foreach` bindings.
It is not limited to anonymous records:

```odin
point := Point{1, 2};
x, y := point;

foreach (key, value in table.entries()) {
	...
}
```

This generalizes the record destructuring that `foreach` already performs
instead of adding tuple-specific patterns.

## 2. Calls use record-like matching, not argument records

### 2.1 Shared matching rule

A procedure parameter list is an ordered list of named slots:

```odin
create_window :: proc(
	title: string,
	x: int = 0,
	y: int = 0,
	width: int = 854,
	height: int = 480,
	monitor: ^Monitor = nil,
) -> Result(^mut Window, Window_Error) {
	...
}
```

A call fills those slots using the same positional-then-named algorithm used by
record literals:

```odin
window := create_window("Loke", width=1280, height=720) or_return;
```

The common compiler concept is a **slot matcher**:

- positional values fill the next unfilled slot;
- a name selects one slot directly;
- positional values precede named values;
- duplicate fills are errors; and
- supplied expressions evaluate left to right.

After supplied arguments are bound, omitted parameter defaults evaluate once in
parameter order. A record has zero-filled omitted named fields instead. This is
a deliberate policy difference after a shared matching operation, not a second
matching algorithm.

### 2.2 Why a call does not construct a record value

Although parameter lists resemble product records, call arguments should not be
made into a first-class runtime datatype. Parameters can have properties that
ordinary record fields cannot:

- `inout` is a call-bounded alias to caller storage;
- `move` consumes a caller binding;
- a variadic parameter receives a call-scoped pack;
- defaults are declaration code evaluated only when omitted;
- a managed value parameter is a non-owning call borrow rather than an owning
  record field; and
- the ABI may pass each parameter independently in registers or indirectly.

Materializing an argument record would either change those semantics or create
a special record whose fields are not ordinary values. It would also risk
making parameter names part of procedure type identity, so merely renaming a
parameter could break procedure-value compatibility.

Therefore:

- parameter names and defaults remain declaration metadata;
- procedure type compatibility continues to use parameter types, modes,
  variadic shape, effects, results, and calling convention—not parameter names;
- calls through a procedure value supply the complete parameter list and do not
  acquire defaults from an erased declaration; and
- there is no general `Arguments(F)` type or automatic forwarding of an
  argument record in this proposal.

An application can define an ordinary options struct when arguments genuinely
need to be stored, forwarded, versioned, or assembled incrementally:

```odin
Window_Options :: struct {
	x:       int,
	y:       int,
	width:   int,
	height:  int,
	monitor: ^Monitor,
}

create_window :: proc(title: string, options: Window_Options = {})
	-> Result(^mut Window, Window_Error) {
	...
}
```

That distinction is useful: call syntax handles invocation convenience, while a
record is real data with storage and lifecycle.

## 3. Procedures return one value

### 3.1 Result shape

A procedure returns either no value or one value:

```odin
log_message :: proc(text: string_view) {
	...
}

measure :: proc(values: []f64) -> Statistics {
	...
}
```

Several related values are fields of a record:

```odin
Statistics :: struct {
	minimum: f64,
	maximum: f64,
	mean:    f64,
}
```

An internal helper may use an anonymous record:

```odin
split_once :: proc(text: string_view, separator: rune)
	-> Option((before: string_view, after: string_view)) {
	...
}
```

The backend may still classify and return record fields in multiple registers.
“One value” is a source-level rule, not a requirement to materialize a temporary
record or change an efficient ABI.

### 3.2 Named result locals are removed

Named result variables and bare returns that implicitly move them are removed.
A procedure with a result writes `return expression;`; a procedure without one
may write `return;`.

This deletes the interaction among named results, definite initialization,
multiple results, and `or_return`. Code that benefits from incremental
construction declares an ordinary local:

```odin
stats: Statistics;
// initialize `stats` along the required control-flow paths
return stats;
```

## 4. `Option(T)` and `Result(T, E)`

### 4.1 They are inline values

`Option(T)` and `Result(T, E)` are standard generic value types. They do not
allocate, box, use dynamic dispatch, or turn `T` into an object. Their lifecycle
is the ordinary recursive lifecycle of their payload fields.

Conceptually, their representations are:

```odin
Option(T) ~= struct {
	value:   T,
	present: bool,
}

Result(T, E) ~= struct {
	value: T,
	error: E,
}
```

The fields are not public API. Construction and inspection use canonical
members. An absent `Option` contains the zero value of `T` and `present=false`.
A failed `Result` contains the zero value of `T` and a non-nil error. `E` must
be a nil-status error type, preserving Loke's existing convention that `nil`
means success.

This representation is a starting contract, not a promise that padding or ABI
classification can never be optimized. What must be guaranteed is inline
storage, no hidden allocation, exact lifecycle behavior, and the ability to
represent `some(nil_pointer)` separately from `none`.

For a successful operation with no payload, the success type is the empty
anonymous product `()`:

```odin
Result((), Error)
```

It has no fields, ownership, or runtime behavior.

### 4.2 Compact contextual constructors

Repeating the complete generic type at every return site is too cumbersome.
Where an expected `Option` or `Result` type is available, an implicit selector
names its associated constructor:

```odin
return .some(value);
return .none();
return .ok(value);
return .err(error);
```

This extends Loke's existing contextual `.Member` expression from enum members
to a closed set of associated constructors. The expected type supplies the
complete `Option(T)` or `Result(T, E)`; the constructor name still determines
one behavior. It is the same kind of contextual construction as a typeless
composite literal `{...}`.

The compact form requires a complete expected type:

```odin
result: Result(Entry, Error) = .ok(entry); // OK
result := .ok(entry);                     // ERROR: `E` has no context
```

When no expected type exists, the explicit form remains available:

```odin
Result(Entry, Error).ok(entry)
Option(string_view).none()
```

For `Result((), E)`, `.ok()` constructs the unit success directly. There is no
empty payload argument.

An anonymous product payload stays compact at both construction sites:

```odin
parse_entry :: proc(line: string_view)
	-> Result((key: string_view, value: int), Error) {
	...
	return .ok({key=key, value=value});
}
```

Inspection is through ordinary methods, a type switch if these types expose
their variants, or the two control-flow operators below. Public access must not
permit observing the inactive zero payload as if it were present.

### 4.3 `or_else`

For `Option(T)` or `Result(T, E)`, `or_else` produces a `T`:

```odin
port := config.get("port") or_else 8080;
data := fs.read_bytes(path) or_else [dynamic]u8{};
```

The fallback is evaluated only for `none` or `err`. For a failed `Result`,
`or_else` deliberately discards the error as it does today. Code that needs the
error inspects the `Result` explicitly.

`or_else` no longer interprets the last component of an arbitrary procedure
result as status.

### 4.4 `or_return`

`or_return` unwraps the success payload or returns failure from the innermost
procedure:

```odin
parse_request :: proc(text: string_view) -> Result(Request, Error) {
	header := parse_header(text) or_return;
	body := parse_body(text) or_return;
	return .ok(Request{header, body});
}
```

For an operand `Result(T, E1)`, the enclosing procedure must return
`Result(U, E2)` and `E1` must be assignable to `E2`. On failure, `or_return`
constructs the enclosing result's `.err(error)` and returns it. On success, the
expression has type `T`.

For an operand `Option(T)`, propagation is valid only from a procedure returning
`Option(U)`; absence returns its `.none()` value.

There is no implicit conversion from `Option` absence to a `Result` error.
Code supplies the error explicitly through an ordinary method such as
`option.ok_or(error)`.

### 4.5 Standard producer changes

Each operation receives one stable type and behavior:

```odin
value.(T)       // T; traps on a union mismatch
value.as(T)     // Option(T); never traps for mismatch

table[key]      // V/place; one indexing policy
table.get(key)  // Option(V); non-inserting value lookup
table.find(key) // Option(^mut V); non-inserting mutable lookup

array.pop()     // Option(T)
iterator.next() // Option(Element)
```

Validating conversions return `Option(T)` when invalidity carries no useful
information and `Result(T, E)` when it does.

### 4.6 Receiving values

The common receiving path immediately unwraps through propagation:

```odin
entry := parse_entry(line) or_return; // `entry` has the payload type
fmt.println(entry.key, entry.value);

key, value := entry;                  // optional flat record destructuring
```

A fallback also produces the payload directly:

```odin
port := config.get("port") or_else 8080;
```

Code that needs to inspect the error retains the `Result` value and uses its
ordinary query and checked-access members:

```odin
result := parse_entry(line);
if (result.is_ok()) {
	entry := result.value();
	use(entry);
} else {
	report(result.error());
}
```

`value()` traps if called on `err`, and `error()` traps if called on `ok`; the
guard makes the intended state visible and lets an optimizer remove a repeated
test. A future result-pattern form may improve explicit branching, but is not
required for the initial value model.

## 5. Cleanup, stack storage, and removal of `manual`

### 5.1 Three independent questions

The current `manual` spelling is easy to confuse with allocation, but these are
separate properties:

1. **Inline location:** where the fixed-size representation of a variable lives.
2. **Backing allocation:** whether the value owns separately allocated storage
   and which allocator provided it.
3. **Cleanup policy:** whether scope exit automatically invokes `drop`.

`manual` controls only question 3. It does not force heap allocation today.
A lexical variable's inline representation lives in its stack frame whether it
is managed or manual. A `[dynamic]T` header may live on the stack while its
backing elements come from the heap, an arena, or a caller-provided buffer.
`new(T)` is the operation that creates a separately allocated `T` and returns a
pointer to it.

The proposal keeps these distinctions and removes the `manual` declaration
modifier.

### 5.2 Ordinary lexical owners always clean up

Every live owning lexical variable registers automatic cleanup:

```odin
file := fs.open(path) or_return;
// `file` is an inline local value and is dropped at scope exit.
```

Early cleanup remains explicit:

```odin
drop(file); // releases the resource and marks `file` dead
```

Ownership transfer remains explicit:

```odin
destination := move(source);
consume(move(destination));
```

Conditional liveness continues to ensure that a moved or explicitly dropped
binding is not dropped again at scope exit.

### 5.3 Resource-specific ownership escape is preferred

An owning wrapper that transfers responsibility to foreign or lower-level code
should normally expose a consuming conversion:

```odin
raw := move(file).into_raw(); // consuming receiver; `file` becomes dead
foreign_adopt(raw);
```

The `into_raw` implementation moves the resource state out or makes its local
owner inert before its automatic cleanup runs. The inverse `File.from_raw(raw)`
is an unsafe or otherwise explicitly checked constructor that establishes one
owner again.

This is clearer than changing the cleanup policy of every variable that happens
to hold a `File`.

### 5.4 `unsafe.forget(move(value))`

For the rare generic case, `core:unsafe` provides a compiler special form:

```odin
unsafe.forget(move(value));
```

It has these exact semantics:

1. The operand must be a live lexical value and must be written with `move`.
2. Ownership is consumed from the source binding, which becomes dead.
3. No `drop` hook is invoked for the consumed value.
4. The operation returns no value.
5. It does not move storage to the heap, extend a stack lifetime, or preserve an
   address into the stack.

When `value` is an inline plain value, the stack bytes simply disappear with the
frame and forgetting it has no useful effect. When it is a dynamic array, the
small header remains stack storage but its backing allocation is intentionally
not released. When it is a file, the OS handle is intentionally not closed.

Most uses of `forget` are therefore either a deliberate leak or the final step
of a handoff whose recipient has already taken responsibility.

Critically, this is invalid:

```odin
value := Large_Record{};
foreign_retain(&mut value);
unsafe.forget(move(value)); // does not make `&value` valid after return
```

The foreign code retained an address into the current stack frame. Suppressing
`drop` cannot extend that frame. If data itself must outlive the frame, allocate
it with `new`, place it in a longer-lived owner, or copy it into storage owned by
the recipient.

### 5.5 Manual allocation remains pointer-based

`new` and `new_clone` continue to return allocation-root pointers requiring
`free`, allocator reset, or transfer into an owning wrapper:

```odin
pointer := new(Item) or_return;
pointer^.initialize();
free(pointer);
```

This is manual allocation, not a manual local variable. The pointer is a value
in the stack frame; the `Item` it names is in allocator-provided storage.

The language should use distinct terminology in the final specification:

- **automatic owner** for a value with lexical cleanup;
- **allocation root** for storage returned by `new`/`new_clone`; and
- **forgotten owner** only when cleanup was explicitly suppressed.

Avoid using “manual” for both declaration cleanup policy and allocation roots.

### 5.6 Raw inline storage is a separate unsafe abstraction

Removing `manual` does not by itself solve partially initialized fields or
custom containers that need raw element storage. If real implementations need
it, add a narrowly scoped `unsafe.Maybe_Uninit(T)` or raw-storage facility with
explicit initialize, take, and destroy operations.

Do not use `forget` as uninitialized-storage machinery, and do not add a broad
`Manual(T)` wrapper merely to recreate the removed modifier in every type
position. The concrete custom-container cases should determine the smallest
unsafe primitive.

## 6. `inout` remains a call capability

### 6.1 Why it remains

`inout T` means more than “the ABI passes a pointer.” It says:

- the argument is non-null;
- it denotes an assignable caller-owned place;
- the call has exclusive mutable access;
- the access is visibly requested at the call site;
- ordinary use is bounded by the call; and
- mutation or replacement may invalidate borrows derived from the whole owner.

Replacing it with `^mut T` would make every mutating procedure accept a nullable,
storable address and would move retention and escape correctness toward the
unchecked boundary. That may be an acceptable lower-level language, but it is
not merely removal of redundant syntax.

This proposal therefore retains:

```odin
sort_in_place :: proc(values: inout [dynamic]int) {
	values.sort();
}

sort_in_place(inout values);
```

Method syntax continues to supply the receiver borrow:

```odin
values.sort();
```

### 6.2 Interaction with product records and calls

An `inout` parameter is a call slot, not a field of an argument record:

```odin
copy_into :: proc(
	destination: inout Buffer,
	source: []u8,
	offset: int = 0,
) -> Result((), Error) {
	...
}

copy_into(source=bytes, destination=inout buffer) or_return;
```

This is one reason calls only reuse record-style matching rather than construct
an actual record value.

### 6.3 `inout` results remain provisionally

Place-returning indexing and user-defined mutable projections currently use
`inout` results. They remain in this proposal because replacing them with
`^mut T` would change a place expression into a nullable first-class value and
would require different assignment and address-taking rules.

They should receive a focused later review. That review is independent of
removing `manual`, multiple results, or trailing status.

## 7. No primitive/object split

The resulting language does not divide data into Java-like primitives and
objects. It maintains these invariants:

1. A type `T` is the same type whether its value is a local, a field, an array
   element, an allocation reached through `^mut T`, or a payload inside
   `Option(T)` or `Result(T, E)`.
2. Local values have inline fixed-size representations. Managed values may own
   separate backing storage, but their headers remain ordinary values.
3. No method call, interface check, generic instantiation, `Option`, or `Result`
   implicitly boxes a value.
4. `impl` blocks and static interfaces apply to scalar, record, container,
   pointer, and other types under the same lookup model.
5. Generics remain monomorphized and preserve concrete layout.
6. `dyn Interface` remains an explicit borrowed erased view, not an owning
   implicitly allocated object.
7. Heap or region allocation is requested by an operation such as `new`, by a
   container's backing storage, or by an explicit owning pointer type if one is
   later added.

There is still an important value/address distinction, as in C or Rust: `T` is
a value and `^T` is an address. That distinction is useful and does not prevent
either type from participating in `impl` or generic code.

The design must avoid recreating a method split indirectly. A mutable receiver
remains behavior of `T` expressed through its `inout self` mode; it does not
become an unrelated inherent method on `^mut T`. This is another reason to keep
`inout` in the proposed result.

## 8. Worked examples

### 8.1 Configuration parsing

```odin
Entry :: struct {
	key:   string_view,
	value: int,
}

parse_entry :: proc(line: string_view) -> Result(Entry, Error) {
	separator := line.find('=').ok_or(
		Parse_Error.Missing_Separator,
	) or_return;

	value := parse_int(line[separator + 1:]) or_return;
	entry := Entry{line[:separator], value};
	return .ok(entry);
}

load :: proc(lines: []string_view, into: inout map[string_view]int)
	-> Result((), Error) {
	foreach (line in lines) {
		entry := parse_entry(line) or_return;
		into[entry.key] = entry.value;
	}
	return .ok();
}
```

This example has one result per procedure, no trailing status convention, no
named result locals, and no tuple type.

### 8.2 Iterator

```odin
Iterator :: interface($Self: type) {
	Element: type;
	slot next: proc(self: inout Self) -> Option(Self.Element);
}

next :: proc(self: inout Line_Iterator) -> Option(string_view) {
	if (self.done) {
		return .none();
	}
	return .some(self.read_line());
}
```

The loop asks one value whether an element is present; it does not interpret a
final `bool` result specially.

### 8.3 Anonymous product payload

```odin
partition :: proc(values: []int, pivot: int)
	-> (below: int, equal: int, above: int) {
	...
}

counts := partition(values, 10);
fmt.println(counts.below, counts.equal, counts.above);

below, equal, above := counts;
```

If the result becomes part of a public API or needs methods, it should be
promoted to a named struct without changing the product semantics.

### 8.4 Stack value and backing allocation

```odin
buffer: [4096]u8 = {};                     // bytes inline in this stack frame
arena := mem.Arena.from_buffer(buffer[:]); // owner header also inline
values: [dynamic]int via arena.allocator() = {};
values.append(1, 2, 3);                    // backing elements live in `buffer`
```

Removing `manual` changes none of these locations. It only guarantees that
`values` and `arena` perform their normal cleanup when live at scope exit.

### 8.5 Intentional foreign handoff

```odin
socket := net.open(address) or_return;
native := move(socket).into_raw(); // no automatic close remains
foreign_library_adopt_socket(native);
```

If no resource-specific consuming conversion exists:

```odin
foreign_library_adopt_handle(socket.native_handle());
unsafe.forget(move(socket));
```

The second form is visibly unsafe because the compiler cannot prove that the
foreign recipient really accepted the ownership obligation.

## 9. Rejected alternatives in this draft

### Separate positional tuples

Rejected provisionally because `Option`/`Result` remove most multiple-result
uses and anonymous records cover the remaining product values while retaining
names. Adding `(T, U)` would create a second product type with parallel layout,
lifecycle, reflection, formatting, and destructuring rules.

### Calls as first-class argument records

Rejected because parameter modes, variadics, defaults, call borrows, evaluation
order, and ABI classification are not ordinary record-field semantics. The
shared slot matcher obtains the useful regularity without materialization or
making parameter names part of procedure type identity.

### Replace `inout` with `^mut T`

Rejected in this draft because it trades a non-null, exclusive, call-bounded
capability for a nullable, storable address. It would also tend to move mutable
methods from the subject `T` to pointer types, recreating a method-level value/
address split that the unified `impl` model should avoid.

### Keep `manual` as a declaration policy

Rejected provisionally because automatic cleanup plus `drop`, `move`, consuming
raw conversions, and unsafe `forget` cover its observed lexical use cases with
fewer declaration states. This must be validated against custom container and
foreign ownership implementations before removal.

### Make every anonymous record nominal by occurrence

Rejected because two identical helper signatures would produce incompatible
types and an anonymous result would be difficult to reproduce outside its
declaration. Exact structural identity is more useful while remaining bounded
by the restriction that anonymous records cannot own inherent behavior.

## 10. Open decisions

The proposal needs evidence on these points before implementation:

1. Should mixed positional/named record literals such as `Point{1, y=2}` be
   accepted, or should only calls permit mixing?
2. Is flat destructuring sufficient, and is `a, b := record` clear once special
   multiple results are removed?
3. Should anonymous record identity include field names, or only ordered field
   types? This draft includes names to preserve field access and avoid accidental
   compatibility.
4. Should `Option` and `Result` be compiler-owned types or ordinary `base:`
   generic records with compiler-recognized `or_else`/`or_return` roles?
5. Does `Result(T, E)` require exactly the existing nil-status error contract,
   or should it support an arbitrary error type with an explicit success tag?
6. Is `()` sufficiently clear as the empty anonymous product and no-payload
   type, including in `Result((), E)`?
7. Which real implementation case, if any, still requires an undropped inline
   owner after `manual` is removed? That case should design the unsafe raw-
   storage primitive.
8. Can every foreign ownership transfer expose a consuming `into_raw`, leaving
   `unsafe.forget` as a rare last resort?
9. Do `inout` results justify their place-expression semantics independently of
   `inout` parameters and receivers?
10. What exact ABI guarantee should `Option` and `Result` make for C-compatible
    payloads and exported Loke procedures?

## 11. Proposed migration order

1. Characterize current multiple results, named results, argument matching,
   optional-ok producers, status propagation, `manual`, and `inout` behavior.
2. Implement exact structural anonymous records and general record
   destructuring while keeping current multiple results temporarily.
3. Add inline `Option`, `Result`, and the `()` unit product with ordinary
   lifecycle behavior.
4. Give union extraction, map lookup, validation, `pop`, and iteration their
   fixed `Option`/`Result` signatures.
5. Rewrite `or_else` and `or_return` over the new types.
6. Migrate procedures to one result value, using named or anonymous records for
   product payloads; remove multiple and named result semantics.
7. Add resource-specific consuming raw conversions and `unsafe.forget`, migrate
   the few real `manual` declarations, then remove the modifier.
8. Keep `inout` unchanged through those migrations. Review its result form only
   after the rest of the value model is stable.
9. Update the normative specification, grammar, standard library, examples, and
   full test corpus in each vertical change; do not ship two current mechanisms.

## Acceptance criteria

The proposal succeeds only if the resulting implementation demonstrates all of
the following:

- every expression has one stable type and arity;
- calls and record literals share one diagnosable slot-matching algorithm;
- parameter names remain outside procedure type identity;
- procedures expose at most one result value;
- `Option`, `Result`, and product payloads introduce no hidden allocation;
- managed payloads drop exactly once through success, failure, fallback,
  propagation, movement, and partial initialization;
- anonymous records do not create incoherent inherent behavior;
- removing `manual` does not change stack placement, allocator selection, or
  backing-storage location;
- `forget` cannot be mistaken for a lifetime extension;
- allocation roots still require explicit release or transfer;
- mutable calls retain the existing `inout` capability and borrow diagnostics;
- no scalar, record, pointer, or container needs implicit boxing to use `impl`,
  generics, or static interfaces; and
- source and generated ABI changes are intentional, measured, and documented.
