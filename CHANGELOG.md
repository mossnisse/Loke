# Changelog

User-visible changes to the language, the compiler, and the standard library.
Each release's section is its GitHub release notes. A change lands under
**Unreleased**, and a break also gets an upgrade note under **Breaking
changes**. [releasing.md](releasing.md) has the version policy and the release
checklist.

## [Unreleased]

### Breaking changes

- A value [`unsafe.take`](design.md#uninitialized-capacity) reads out keeps the
  [allocator regions](design.md#allocator-regions-and-region-provenance) it was in, as one `exchange`
  reads out does. It had none the analysis could name, so returning such a value from an arena of the
  frame, or storing it in the caller's storage or a global, compiled and read freed memory. These are
  now `L0592` and `L0536`. Upgrade by keeping the arena alive for as long as the value. In the other
  direction, `Small_Array.pop` and `remove` of an owning element, and any such `unsafe.take`, no longer
  report `L0537` against an unrelated arena that ends first.
- A procedure with a `$` parameter before a runtime one keeps its [result
  contract](design.md#procedure-result-contracts). `pick($T: type, view: []int) -> []int` lost the
  borrow on its result, so dropping or writing the owner while the result was live compiled and read
  freed storage. The same mistake hid what such a body stores in or returns from its arguments, and
  which allocator region its result is in. These are now `L0511`, `L0512`, `L0513`, `L0537`, `L0536`,
  or `L0646`, as they are with the `$` parameter written last. Upgrade by ending the result's use
  first, or by writing `@(escape=stored)` on a parameter the body keeps.
- A `foreach` over the iteration protocol counts as the calls it makes: `iter`, `next` at each step,
  and the iterator's drop ([Global write effects](design.md#global-write-effects)). So a `next` that
  writes or reads a global under a live mutable pointer of it is now `L0512` or `L0511`, and a procedure
  with such a loop has those effects. It compiled and aliased the global. Upgrade by ending the
  pointer's use before the loop, or by not touching the global from the iterator.
- A load through a pointer to a field reads that field ([Places and overlap](design.md#places-and-overlap)).
  After `h := &mut r^.b`, `x := h^.to` holds what `r^.b.to` holds, so a program that stored a carrier
  there and went on using it beside `x` is now `L0641`. It compiled, as the load read the first field
  instead, and held two mutable paths to one place. Upgrade by finishing with one before using the other.
- What a callee draws from a provider reached through a viewed record's carrier is in that provider's
  region ([Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)),
  whether or not the record also owns one. So `build(holders[:])` over a `Holder` with a `^mut mem.Arena`
  field is now `L0537` if that arena ends while the result lives. It compiled and read freed memory.
  Upgrade by keeping the arena alive for as long as the result.
- A result drawn from a provider received in a variadic pack, or through a slice of pointers to
  providers, is in the region of the arenas it was given
  ([Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)),
  and a task using one reserves it ([Allocators and tasks](design.md#allocators-and-tasks)). So
  `build(&mut arena)` over `build :: proc(arenas: ..^mut mem.Arena)` is now `L0537` if `arena` ends
  while the result lives, and the task is `L0732` beside a use of that arena's allocator. Both
  compiled and read freed memory. Upgrade by keeping the arena alive for as long as the result, and
  by giving the task an arena of its own.
- A pointer a call returned reaches what the call's result dependencies say, as
  [Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)
  requires, where it named nothing. Two unsound programs are now rejected. An owner stored through
  such a pointer, or a user `operator([])`'s, is held against a reset of its region (`L0537`), and an
  owner built by a provider reached through one, whether `held.get()` stored in a local or
  `pick(&mut arena)`, ends with that provider (`L0592`). Both compiled and read freed memory. Upgrade
  by keeping the region alive for as long as the owner is used.
- `delegate` sees what it forwards wherever that is written
  ([Delegating operators](design.md#delegating-operators)), so an overload of the distinct type
  declared after the block is now the redeclaration `L0420`, as one written ahead of it already was.
  Upgrade by removing the `delegate` of that operator or the overload.
- What is wrong with a declaration is reported wherever the first question about it came from. A
  declaration first reached from a speculative check, such as a generic parameter's type, kept its
  answer and lost its report, so it compiled, or stopped with the internal `L0405`. A `$` parameter's
  own type is also checked where it is declared rather than at the first instance
  ([Generics](design.md#generics)), so a generic nothing instantiates may now report `L0306`. Upgrade
  by fixing the reported declaration.
- A distinct slice or pointer with a `format` of its own is lent while it is printed, as that `format`
  may write through it ([Weakening and reborrows](design.md#weakening-and-reborrows)). So
  `fmt.println(d, d)` over such a type is now `L0641`, where it compiled. Upgrade by printing it in two
  statements.
- A task using a provider through a pointer it received reserves that provider
  ([Allocators and tasks](design.md#allocators-and-tasks)), so using its allocator in the parent or
  another task before the join is now `L0732`. Upgrade by giving the task an arena of its own.
- A generic union whose `@(zero=)` payload has no zero is `L0423` when a record names the instance in
  its own fields, as it is elsewhere
  ([Zero values and `@(zero=)`](design.md#zero-values-and-zero)). Upgrade by designating a payload
  with a zero.
- A generic block's member takes only the attributes its kind allows, so `@(require_results)` on one
  naming a constant is `L0607`, as it is in any other block
  ([Attributes](design.md#attributes)). Upgrade by removing the attribute.
- `or_else break` and `or_else continue` in a static `foreach` body are `L0455`, as any `break` or
  `continue` that would target the expansion is
  ([Static `foreach` expansion](design.md#static-foreach-expansion)). Over a value with no elements the
  body compiled; with elements the exit was `L0368`, even in a runtime loop. Upgrade by testing the
  value and handling the failure in the body, or by moving the loop into it.
- A foreign block's rules are checked where they were let through
  ([Foreign system](design.md#foreign-system)). A global written `x: T = ---;` is `L0625`, as the
  grammar says a foreign variable has no initializer; `a, b: i32 = ---, 1;` compiled and dropped the
  `1`. `@(link_name="")` is `L0608`; it compiled and emitted a symbol with no name.
  `@(c_vararg) a, b: ..` is `L0627`; it compiled with `b` unbound. A
  `@(default_calling_convention)` that is not `c` or `stdcall`, including `""`, is `L0618` at the
  attribute, where before it passed on a block with no procedure to report it on. Upgrade by
  removing the `= ---`, the empty attribute or the extra name, and by writing a convention the
  compiler accepts.
- Attributes on `impl` members and foreign declarations are checked as the
  [attribute categories](design.md#attribute-categories) say, with `L0607`. On a member of a
  body-local `impl`, `@(public)`, `@(private)`, `@(export)` and `@(link_name)` are rejected as on any
  local; they compiled and did nothing. `@(export)` on a foreign declaration is rejected; it compiled
  and emitted nothing. A member of a generic `impl` now has its attributes checked as any other
  member's, so an unknown or misplaced one, or `@(test)` or `@(cpu_dispatch)`, no longer passes
  silently. `@(cpu_dispatch)` on an `impl` member or a foreign declaration is `L0607` rather than
  `L0739`. Upgrade by removing the attribute.
- A body-local `impl` whose subject names no type, such as `impl x` on a variable or `impl nope`,
  is now `L0406`, as at file scope. It compiled, and its members were never checked. Upgrade by
  removing the block or naming the type.
- A member of a generic `impl` that is not a constant, a procedure, or an associated type, such as
  `impl G($T) { x: int = 0; }`, is now `L0406`, as in any other block. It compiled and the member
  was dropped. Upgrade by removing the member, or moving the field to the record.
- `string.from_runes` now takes one value argument, by position or named `runes`, as `string.from_utf8`
  takes one by position or named `bytes` ([string type conversions](design.md#string-type-conversions)).
  Any other name, a spread and `inout` were accepted and ignored, and are now `L0561`. Upgrade by
  passing the slice by position.
- A static `foreach` binding and the names of an expanded case now take the checks of any local
  ([Variable declarations](design.md#variable-declarations)). `x := 7; foreach ($x in 0..<2)` and
  `variant := 7; ... case $variant(p):` are `L0305`, also over an empty iterable; `foreach ($a, $a
  in R)` and `case $s(s):` over a payloadless variant are `L0304`. They compiled, and the last name
  bound won. Upgrade by renaming the binding.
- A static `foreach` over a record binds as the runtime form does
  ([Destructuring](design.md#destructuring)). Over another package's nominal record, `$a, $b` is now
  `L0708`; it compiled and relied on a field order that package may change. A padding field no
  longer counts, so over `struct { a: int, _: [4]u8, b: int }`, `$a, $b` now compiles, and each name
  takes the field it names. Upgrade by binding the whole value and selecting its fields by name.
- `break` or `continue` in a `defer` inside a static `foreach` body is `L0455` however many elements
  the iterable has ([Static `foreach` expansion](design.md#static-foreach-expansion)). Over an empty
  iterable it compiled, and otherwise it was `L0368`, "only valid inside a loop", even inside one.
  Upgrade by deleting it, since a deferred statement cannot leave its construct.

- A file-scope `when` now waits for a branch that may shadow a predeclared name it reads, directly or
  through a declaration ([when statement](design.md#when-statement)). A condition that read a
  predeclared `string` and took one branch, while another `when` declared `string`, now reads that
  declaration and may take the other. One whose own branch declares the name is now `L0389`, where it
  compiled and read the predeclared name. Upgrade by renaming the declaration in the branch.
- A `distinct` type that declares one half of `==` and `hash` is now `L0586` as a part of a map key,
  as it already was as the key itself ([Maps](design.md#maps)). With `D :: distinct S` declaring a
  coarser `==`, `map[Holder]int` over `struct { d: D }` paired it with `S.hash`, and two keys that
  compared equal could both be stored; a lone `hash` on `D` was silently ignored. Upgrade by declaring
  both on `D`, or neither.
- `typeid_of(T).hash(seed)`, alone or within a record or array, is now `L0341` in compile-time
  evaluation ([`type` and `typeid`](design.md#type-and-typeid)). It folded to the nil `typeid`'s hash,
  which no run of the program computes. Upgrade by hashing at run time.
- A move-only field or element of a temporary, as a `spawn` argument or receiver, is now `L0728`
  ([Spawn statements](design.md#spawn-statements)). It compiled, and the task read storage the
  parent had already dropped. Upgrade by binding the temporary to a local declared before the
  block, and lending that.
- A managed place as the replacement of `exchange` is now `L0501`
  ([Exchange](design.md#exchange)). `exchange(inout a, b)` on a `[dynamic]int` stored `b`'s bits
  unmoved, so both owned one allocation and the program corrupted its heap. Upgrade by writing
  `move(b)`, or `b.clone()` to keep it, as a part such as `h.items` must.
- A map's `find_or_insert`, `try_insert` and `remove`, a `sort` or `reverse_sort`, and a `switch` on
  a value now count the code of the program they run
  ([Inferred effects](design.md#inferred-effects)). With `p := &mut counter` still in use, a
  `hook(drop)` of the map's element or key, an `operator(<)` of the sorted element, or an
  `operator(==)` of the switched type that writes `counter` is now `L0512`; each compiled, and a hook
  clearing a global left a live view dangling. Upgrade by ending the borrow before the operation.
- Every task of a `parallel` block now reserves what a `thread_local` owner's `hook(drop)` uses when
  its thread exits ([Globals while tasks run](design.md#globals-while-tasks-run)). A hook that
  allocates through an `Allocator` read from a global makes a block of two tasks `L0732`, where it
  compiled and both could use that region at once. Upgrade by having the hook use its owner's
  allocator, or by giving each task what it needs rather than a `thread_local` owner.
- An instance of a generic operator is held to the operator's shape
  ([Operator declarations](design.md#operator-declarations)), so `operator(==) proc(a, b: V($T)) -> int`
  is now `L0416` where an instance is made. It compiled, and `a == b` was an `int`. Upgrade by giving
  the operator the result its symbol takes.
- `delegate` of a symbol is now `L0420` when a block of the distinct type declares an overload of it
  with the type in any operand position, not only the first
  ([Delegating operators](design.md#delegating-operators)).
  `impl W { delegate(*); r :: operator(*) proc(s: f64, w: W) -> W { ... } }` compiled. Upgrade by
  writing every overload of that symbol by hand.
- A `slot` whose written `self` type is not the interface's subject is `L0442`
  ([Interface bodies](design.md#interface-bodies)). `slot f: proc(self: int) -> int;` in
  `interface($T: type)` compiled and was never met. Upgrade by writing the subject, or no type.
- A slot written with a calling convention is met only by a method with that convention
  ([Interface bodies](design.md#interface-bodies)). `slot f: proc "c" (self) -> int;` was met by a
  Loke method and not by a `proc "c"` one. Upgrade by removing the convention from the slot, or by
  giving the method the one the slot names.
- `dyn I` over a slot written `proc(self, other: Self)` is now `L0463`
  ([Dyn compatibility](design.md#dyn-compatibility)), as `proc(self: Self, other: Self)` already was.
  It compiled and misread `other` at run time. Upgrade by taking the other value through a `dyn I`
  view or a concrete type, or by keeping the interface static-only. A slot with no parameters no
  longer crashes the compiler when viewed: it is `L0442` and `L0463`.
- The parser now rejects four shapes [grammar.md](grammar.md) never admitted. A capture clause with
  no body, `T :: proc() capture(y);`, is `L0259`: it compiled and dropped the clause, so `y` need not
  have existed; write a procedure type with no clause. `-> !` on a procedure type in result position,
  `f :: proc() -> proc() -> ! { ... }`, is `L0257`, as it is elsewhere: calls through it never
  diverged, so remove the `!`. A parenthesized slice, `&mut (a[1:2])`, is `L0357`, as `&(a[1:2])` is:
  drop the parentheses for mutable slicing. Attributes on an empty statement, `@(x) ;` in a body, are
  `L0206`, as at file scope: they applied to nothing, so remove them.
- An extension `operator([]=)` no longer takes a store that built-in indexing answers
  ([Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution)):
  with `impl [3]int { set :: operator([]=) ... }`, `a[0] = 1` now writes the element, as a read
  already ignored an extension `operator([])`. Upgrade by calling the procedure by name.
- `@(export)` on a member of a generic `impl` block is now `L0438`
  ([`@(export)`](design.md#export)). It compiled and exported nothing. Upgrade by removing it, or by
  exporting an ordinary procedure that calls the member.
- A slice or field of a user unary, `operator([])` or `operator([:])` result is now `L0513` when
  used after its statement, as one of a binary operator's already was
  ([Temporaries and procedure boundaries](design.md#temporaries-and-procedure-boundaries)).
  `first((-m)[:])` compiled and read the temporary after it was dropped. Upgrade by binding the
  result to a local first.
- A carrier bound by destructuring, as `out, n := holder`, now reaches what the field's carrier
  points at, so an owner stored through it counts against a later reset or a local region, as
  through `out := holder.output` (`L0536`, `L0537`,
  [Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)).
  It compiled and left the owner dangling. Upgrade by keeping the allocator's region alive as long
  as the destination.
- Comparing records at compile time when a part has no compile-time comparison, such as a
  `typeid_of` against a forged `typeid`, is now `L0341`, as comparing those parts alone is
  ([Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)). It folded to
  "different". Another part that differs still answers it. Upgrade by comparing at run time.
- A map's `iter_mut` is now a mutable borrow of the map, as a dynamic array's is
  ([By-reference iteration](design.md#by-reference-iteration)), so reading the map while an
  entry is still in use, or taking a second iterator, is now `L0511`. It compiled, though the
  loan was meant to be exclusive. Upgrade by finishing with the entry before using the map
  again.
- A task whose call passes one callback to several arguments, as in
  `both :: proc(f: proc(out: ^mut ^int), a, b: ^mut ^int) { f(a); f(b); }`, is now `L0730` when
  the callback leaves a borrow of `thread_local` storage in either
  ([Borrows crossing between tasks](design.md#borrows-crossing-between-tasks)). Only the first
  argument used to be checked, and a procedure value that may be either of two only as the
  first. Upgrade by not returning that borrow across the task.
- An unfixed integer too large for a float no longer meets an unfixed float
  ([Number literals](design.md#number-literals)): `(1 << 2000) + 1.5` is now `L0352`. It compiled,
  reading the integer as `0`. A comparison, as in `(1 << 2000) > 1.5`, still orders the exact values.
  Upgrade by writing a value a float can hold.
- A distinct type converts only as written in more places
  ([Distinct types](design.md#distinct-types)): `r: rawptr = P(&n)` with `P :: distinct ^int` is now
  `L0310`, and `S("a") + view` and `S("a") == T("b")` with distinct strings are `L0354`. `a && b` on
  a `distinct bool` is `L0318`, as `!a` was `L0317`. `d: D = 1 << n` with `D :: distinct int` is
  `L0310`, as `D(1) << n` was `L0318`. Upgrade by writing the conversion.
- A constant zero divisor lane of an integer vector is now `L0319`
  ([Lane-wise operators](design.md#lane-wise-operators)), in `v / 0`, `v % Z` and `v /= 0`, as a
  scalar's is. They compiled and panicked at run time. Upgrade by removing the division.
- `-C` and `~C` on a constant vector are now constants ([Lane-wise
  operators](design.md#lane-wise-operators)), so `v << -C` with a positive `C` is `L0356` and
  `-C` overflowing a lane is `L0397`. They compiled and panicked at run time. Upgrade by removing
  the negative count.
- `Simd(inout f32, 4)` and `Range(inout int)` in value position, as in `size_of`, are now `L0681` and
  `L0689`. They compiled and ignored the mode. Upgrade by removing it.
- Only a scalar of the lane type splats, constant or not
  ([SIMD vectors](design.md#simd-vectors)): `v: Simd(f32, 4) = N` with `N : i64 : 3`, and
  `f32_vector + i32(1)`, are now `L0310`. They compiled, converting the constant. Upgrade by writing
  the lane type, `f32(N)`.
- An array literal's key must have an integer or rune type, as an index does
  ([Fixed arrays](design.md#fixed-arrays)): `[2]int{C.B = 1}` with an enum `C` is now `L0362`.
  Upgrade by writing `int(C.B)`.
- A constant zero divisor of a rune is `L0319` ([Integer operators](design.md#integer-operators)):
  `r % 0` and `r /= 0` compiled and panicked at run time.
- A map named only inside a `Box`, as in `p: Box(map[f64]int)`, now has its key checked: a key
  that cannot be hashed is `L0586` where the map type is named ([Maps](design.md#maps)). It
  compiled. Upgrade by keying the map by a hashable type.
- A destructuring assignment to a destination that would view or splat its field, such as
  `v, n = record` with a `string` field and a `string_view` `v`, is now `L0310`
  ([Destructuring](design.md#destructuring)). It compiled, and wrote the field's bytes past the
  destination. Upgrade by assigning that field by name.
- A provider received through a `move` parameter is now a region of the procedure, as a local one
  is: returning what it backs is `L0592`, and ending it while something it backs is live is `L0537`
  ([Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)).
  Replacing a provider through a `&mut` loop element or case binding also ends its region, as through
  a pointer, and `return` is `L0537` when a panic in it would end a region under an older owner,
  however its value is evaluated. These compiled, and read freed memory. Upgrade by ending the owner
  first.
- A `defer` or `errdefer` reading a local that is dead where a later statement may panic is now
  `L0500`, as it is at an exit ([defer statement](design.md#defer-statement)). It compiled, and read
  a moved or unset value during the unwind. Upgrade by giving the local its value before the
  `defer`.
- `source_location(<entity>)` takes a variable or a procedure, as
  [its section](design.md#source_location-or-source_locationentity) says; naming a type, a
  constant, a package, or a built-in is now `L0573`. Upgrade by naming a variable or a procedure.
- A `make` length, capacity, or reservation is an `int`, so a distinct integer is now `L0579`.
  Upgrade by converting it: `make([dynamic]int, int(count))`.
- `unsafe.transmute` of a type written where the value goes is now `L0688`, where an empty target
  type accepted it as a zero-sized value. Upgrade by passing a value.
- `-define` of an integer that names no variant of a `build_config`'s enum default is now `L0388`,
  rather than making a value that is no member of the enum. Upgrade by passing a variant's value.
- `f16` at a foreign boundary, directly or as a record's field, is now `L0619`: the Win64 C ABI
  does not classify it ([Foreign-ABI-safe types](design.md#foreign-abi-safe-types)). Upgrade by
  passing an `f32`, or by passing a `^f16`.
- A struct's or union's attributes are now written on its declaration, and `move_only` is
  the attribute `@(move_only)`, no longer a reserved word
  ([Attributes](design.md#attributes)). Attributes in the type, and `move_only struct`, are
  now `L0750`. Upgrade by running `lokec <file or directory> -migrate`:

  ```
  Header :: struct @(packed) { ... }             // before
  @(packed) Header :: struct { ... }             // after

  @(public) Window :: move_only struct @(thread_affine) { ... }
  @(public, move_only, thread_affine) Window :: struct { ... }

  Generic :: struct($N: int) @(align=N) { ... }
  @(align=N) Generic :: struct($N: int) { ... }
  ```

- An owner built from a provider inside a `Shared` payload may not outlive any strong handle holding
  it, which is now `L0537`, and one built from it or through a local pointer to a provider may not be
  returned, which is now `L0592`; `some_map.try_insert` on a map holding providers ends their regions, also
  `L0537` while an owner backed by one is live; and `clone()` of a type holding a `hook(copy)` taking
  `self: ^` borrows its receiver, so its result may not outlive it (`L0526`, `L0512`). Upgrade by
  ending the owner first, or by giving the hook a value `self`.
- A declared `Iterator` or `Mut_Iterator` that disagrees with `iter` or `iter_mut`, or a declared
  `Item` that disagrees with `next`, is now `L0694` whether or not anything looks it up, and in
  whatever order the members are declared ([Iteration protocol](design.md#iteration-protocol)).
  Upgrade by correcting the declaration or removing it.
- A generic procedure ending with `---` is now `L0630`, as a plain one is. It compiled while uncalled.
  Upgrade by giving it a body or removing it.
- `box(d, pick(&mut d))`, whose allocator operand writes the managed place being boxed, is now
  `L0511`, as the same two operands of a call are ([Evaluation order](design.md#evaluation-order)).
  It compiled, and cloned freed memory. Upgrade by evaluating the allocator first.
- `sync.Atomic(T)` of a union that only has `Option`'s shape is now `L0662`
  ([`core:sync`](standard-library.md#coresync)). Upgrade by using `Option(^T)`.
- `@(required)` with `@(initialized)` on one field is now `L0691`, and `@(require_results)` on an
  interface is `L0607`. Neither had any effect. Upgrade by deleting the attribute.
- `lokec` takes at most one of the options that select what a run does, such as `-fmt`, `-doc` and
  `-dump-ast`, and a second is a usage error. Before, the first in an internal order won silently.
- `string` -> `string_view` no longer applies to a distinct type on either side, as the
  [conversion list](design.md#implicit-type-conversions) says and as `distinct [3]int` -> `[]int`
  already did not. `s: string_view = Name("abc")` with `Name :: distinct string` is now `L0310`.
  Upgrade by writing the conversion: `string_view(string(name))`.

- A `union` or `enum` is now written only as the value of a constant declaration, as a
  `struct` already was ([Unions](design.md#unions),
  [Enumerations](design.md#enumerations)). `f :: proc(k: enum { A, B })`, `field: union { a:
  int, none }`, `[size_of(enum { A, B })]u8`, and `distinct enum { A }` are now `L0717`.
  `-migrate` cannot rewrite these, since each needs a name. Upgrade by declaring the type,
  or with an [anonymous union](design.md#anonymous-unions) `(a: int | none:)` for a union
  whose identity need not be nominal. A generic argument no longer reaches the
  [success shorthand](design.md#success-returns) through an inline definition, because
  there is none.
- A read-only copy of a carrier that comes to hold a reborrow of a mutable one later in a loop
  is now a reborrow of it too ([Weakening and
  reborrows](design.md#weakening-and-reborrows)). This compiled, and read `x` through `y` while
  it wrote `x` on the second time round, and is now `L0641`, as are the same with a field, a
  record, a view, a literal, a call's result, a spawned argument, or a load through a pointer:
  `r: ^int = other; for (i := 0; i < 2; i += 1) { y := r; x^ = 1; z := y^; r = x; }`.
  Upgrade by ending the use of the copy before the write.
- An `assert` or `panic` report now holds what each argument prints until it has printed
  the last ([Built-in procedures](design.md#built-in-procedures)), so a later argument
  cannot write it. `assert(false, "m", p, grow(p))` with `p: ^mut Node` compiled when `Node`
  held a borrow, and printed the changed value, and so did the same with a slice of such
  records and with `bump(p^.value)` or `bump(&mut x)` writing what `p` reaches. Each is now
  `L0641` or `L0511`. Upgrade by evaluating the argument into a local first.
- A copy now holds what its source holds across the reads of its `hook(copy)`, and a copy
  last-use transfer makes a move counts as the
  [global effects](design.md#global-write-effects) say.
  `t := Tagged{&mut counter}; u := t;` compiled though the hook read `counter` while handed
  a mutable pointer to it, and a `u := t;` that was `t`'s last use added no read to the
  procedure's effect. Each is now `L0511`. Upgrade by ending the use of the borrow before
  the copy, or with `move(t)`, which runs no hook.
- A call given a read-only carrier now uses the mutable carriers stored behind it, as a
  callee may write through them
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).
  `y: ^int = l^.a; write(l); z := y^;` with `write :: proc(p: ^Pair) { p^.a^ = 1; }` compiled
  with a live read-only copy of what the call writes, whatever the call's body did, and so
  did the same with a read-only view, a record holding one, or an indirect call. A method
  taking `self: ^` was already rejected. Each is now `L0641`. Upgrade by reading through the
  copy before the call.
- A store through a pointer redefined later in a loop now lands where that definition
  points too. `p := &mut r^.a; for (...) { p^ = other; y := r^.b; other^ = 1; y^ = 2;
  p = &mut r^.b; }` compiled with `y` and `other` live mutable paths to one place from the
  second iteration on, and is now `L0641`. Upgrade by keeping the pointer on one place in
  the loop, or by ending the use of the copy first.
- A carrier stored through carriers is now a reborrow wherever it is read back from.
  `t := s; t[0].to = other; x := s[0].to; other^ = 1; x^ = 2;` compiled with two live
  mutable paths to `other`, and so did the same stored through a pointer to an element, a
  view in a record, or a view behind a pointer, and `d^.append(Link{other})` followed by a
  read, `remove`, or `pop` through `d`, with `insert`, a spread, or a map's `try_insert`
  or `find_or_insert` alike. Each is now `L0641`. Upgrade by ending the use of the copy
  before using what it copies.
- Passing a record by value now uses what its carriers point to, as passing the carrier
  does ([Weakening and reborrows](design.md#weakening-and-reborrows)). `copy :=
  holder.links[0].to; take(holder); copy^ = 1;` compiled with two live mutable paths to
  one place, whatever `take` did with them, and so did the same through a nested record,
  a union, a method taking `self: Holder`, an indirect call, or a moved record. Each is now
  `L0641`. Upgrade by ending the use of the copy before the call.
- A read-only argument to a task now keeps what it borrows through a mutable carrier
  read-only borrowed until the join, and a carrier loaded out of a field is lent as one
  passed by name is ([Task borrows and the join](design.md#task-borrows-and-the-join)).
  `parallel { spawn read(carrier); carrier^ = 1; }` compiled with a data race, as did
  a read-only copy of the carrier, a view, or a record holding one, and
  `parallel { spawn write(link^.to); spawn write(link^.to); }` compiled with two tasks
  writing one place. Each is now `L0641`. Upgrade by writing after the join, or by
  giving the task what it writes alone.
- A record stored through a view parameter, and a carrier stored through a pointer to
  a local that holds one, now copy what they hold as a carrier stored alone does
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). After
  `links[0] = Link{carrier}; held := links[0].to;`, using `carrier` and `held` compiled
  with two live mutable carriers to one place, and so did `links[0] = links[1];` before
  a call given `links`, and `pointer^ = carrier; held := pointer^;`. Each is now
  `L0641`. Upgrade by ending the use of one before the other, or by replacing the
  place that holds the copy.
- A repeated array element's copy hook now counts its reads after the initializer
  is evaluated ([Fixed arrays](design.md#fixed-arrays),
  [Global write effects](design.md#global-write-effects)), with what the initializer
  and earlier elements hold in use. `[2]Tagged{0..=1 = Tagged{&mut counter}}` with
  `Tagged`'s hook reading `counter` compiled. It is now `L0511`. Upgrade by building
  the elements one at a time, or by not borrowing what the hook reads.
- A place destructure now counts the reads of the copy hooks of the fields it clones
  ([Destructuring](design.md#destructuring),
  [Global write effects](design.md#global-write-effects)), not those of the containing
  record's hook, which never runs. `tag, _ := pair` with `tag`'s hook reading `counter`
  compiled while `p := &mut counter` was in use, whatever `pair`'s own hook read. It
  is now `L0511`. Upgrade by destructuring before taking the borrow, or by ending the
  borrow first. A discarded field no longer counts, so `_, text := pair` is accepted
  there, where it was `L0511` when the discarded field's hook read the global.
- A [parametric alias](design.md#parametric-aliases)'s body may not hold a
  `distinct` type at any depth. `Alias :: Option(distinct $T);` compiled and denoted
  an `Option` of a new type that no other spelling names; it is now `L0744`, as
  `Alias :: distinct Option($T);` already was. Upgrade by declaring the distinct type
  by name, or a generic `struct` or `union` for a new type in each application.
- An alias selected from a type declared in a generic body now counts as what it
  names ([One result](design.md#one-result),
  [Success returns](design.md#success-returns)), as a bare one does. With
  `impl Local { Outcome :: Result(T, int); Payload :: T; }`, `-> Local.Outcome`
  with `return;` compiled and is now `L0326`, reaching its end is `L0365`, and
  `-> Result(Local.Payload, int)` with `return x;` is `L0310`. Upgrade by writing
  `return .ok;` or `return .ok(x);`. `Local.Outcome` for `Result(Unit, T)` keeps
  its bare return.
- A question about a record's lifecycle no longer loses a hook written after it
  ([Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types)).
  A generic record's `where T == int` on a `hook(copy)` after
  `helper :: proc(self) where is_copyable(G(T))` left `G(string)` with a copy and a
  `helper`. It now has neither, so `b := a;` is `L0503` and `a.helper()` is `L0363`.
  Upgrade by writing `move(a)`, or a bound that the instance meets. A body-local
  record's hook now counts from the record's declaration, so a copy made before the
  block runs `hook(copy)`, `L0507` can report it, and a destructure there is `L0508`.
  Upgrade by binding the whole value. A block in a `when` whose condition names a
  constant declared after the record is `L0488` once the record has been used. Upgrade
  by declaring the constant first, or by moving the use after the block.
- An `assert` or `panic` report now holds a mutable pointer to plain data until it has
  printed ([Built-in procedures](design.md#built-in-procedures)). After
  `p := &mut x;`, `assert(ok, "stop", p, write_through(p))` compiled, and printed what
  the later argument left. It is now `L0641`, as `fmt.println(p, write_through(p))`
  already was. Upgrade by calling it first: `done := write_through(p);`.
- An `inout` receiver reached through a pointer or slice is now a borrow of that
  place ([Weakening and reborrows](design.md#weakening-and-reborrows)). After
  `p := &mut m; entry := p^.find_or_insert(3, 7);`, `p^.clear()` before a read of
  `entry` compiled and read the cleared map. It is now `L0641`, as is any use of `p`
  that reaches the place while `entry` is in use, and the same goes for a
  user method's `self: inout` result. So is an argument using the receiver:
  `d^[0].find_or_insert(grow(d), 7)` wrote into the storage `grow` had moved, and
  `d^.append(d^.len())` is now rejected as `a.append(a.len())` already was. Upgrade
  by reading the argument into a local first. What `p^.pop()` or `p^.remove(key)`
  hands back now also keeps the loans the element held.
- What is stored through a `&mut` binding of a user's iterator now reaches the
  storage the iterator may lend from
  ([By-reference iteration](design.md#by-reference-iteration)). With a source holding
  `values: []mut Ro`, `foreach (&mut list in source) { list.head = &c; }` left the
  array behind `values` not knowing of the borrow, so `node := lists[0].head;
  c.value = 5; _ = node^.value;` compiled. It is now `L0511`. Upgrade by ending the
  use of what was stored before the write. The borrow no longer lands in `values`
  itself, which was never where it went, so `c.value = 5; again := source.values;`
  compiles, where it was rejected.
- A call can no longer be left both a mutable carrier and a copy of it
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). After
  `links[0] = links[1];` or a call that may copy between elements,
  `poke_both(&mut links[:]);` compiled when neither carrier was used afterwards,
  and the callee could write through both. It is now `L0641`, however the
  arguments reach the two: through a view, a pointer, `inout`, a receiver, by value,
  or one through each of two arguments, which depended on their order. A second call
  to a copying procedure counts, as only its signature is known there, so
  `duplicate(links); duplicate(links);` and `duplicate(links); touch(links);` are
  rejected. Reordering leaves each carrier in one place, and the compiler's own
  operations other than sorting use nothing, so `swap` and `len` stay allowed. Upgrade
  by replacing one of the two first, as `links[1] = Link{&mut z};`, or by using each
  through its own call: `first := links[0].to; first^ = 1;`.
- A value printed through a mutable call result is now held until printing ends
  ([Built-in procedures](design.md#built-in-procedures)).
  `fmt.println(m.find_or_insert(3, 7)^, clearing(inout m))` compiled and read the
  value after `clear` emptied the map. It is now `L0511`, and the same goes for a
  `panic` or `assert` report. A read of the source, as `m.len()` there, stays
  allowed. A second call taking the source mutably is rejected whether or not it
  writes, so `fmt.println(a.slice()[0], a.slice()[1])` on an `inout` `slice` is
  `L0512`. Upgrade by binding the view first: `view := a.slice();`.
- An owner moved by a swap or sort now keeps its region
  ([Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)).
  After `items[1] = fmt.to_string(arena.allocator(), 42);`, swapping or sorting a
  view of `items`, or calling `slice.reverse`, `slice.sort`, or a procedure that
  does, then `return items[0]` compiled and returned a value from the dropped arena.
  It is now `L0592`. Upgrade by allocating the result in an allocator that outlives
  the procedure.
- A call now keeps borrowed what the storage it is handed holds
  ([Values that contain borrows](design.md#values-that-contain-borrows)). After
  `holders := [1]Holder{Holder{values[:]}}; view := holders[:];`, `drop(values)`
  before `print_rows(view)` compiled and the call read the dropped array. It is now
  `L0512`, as is the same through `first(holders[:])`, a pointer to a record or to
  a slice, a view held in a record, and a write to what is held. A call that reads
  nothing counts, so `view.len()` there is rejected as `holders.len()` already was.
  Upgrade by ending the call before the drop or write, or by replacing what the
  element holds first. A slice literal now follows the same rule, so
  `drop(values); again := view;` on its view compiles, where it was rejected.
- A mutable carrier held in a [slice literal](design.md#slice-literals)'s hidden
  array is now checked as one in a named array is
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). Taking two
  mutable copies of one element, using a carrier stored in an element while a copy
  of it is in use, and using two elements after a call that may copy between them
  all used to compile, and are now `L0641`. Upgrade by ending one use before the
  next, as for a named array.
- An assignment counts as reordering its targets only when each value names a
  target's own place ([Evaluation order](design.md#evaluation-order)), not when
  their source text matches. `links[next()], links[next()] = links[next()],
  links[next()]` used to count, whichever elements the calls named, so a caller
  could keep one mutable carrier in two places; it now reports `L0641` there.
  Upgrade by evaluating the indices first. `links[0], links[1] = links[ 1 ],
  links[ 0 ]`, once rejected for its spacing, is now accepted.
- A store or call that may leave what a place held no longer ends the borrow held
  there ([Places and overlap](design.md#places-and-overlap)). A second `&mut c`
  stored at an index that is no constant, in a loop, or through a
  `foreach (&mut x in xs)` binding used to compile beside a first one still in use,
  and is now `L0511` or `L0641`. A call given `inout held` while `held` may still
  hold a borrow left by an earlier `@(escape=stored)` argument whose root has ended
  used to compile and hand the callee ended storage, and is now `L0513`
  ([Retaining a borrow](design.md#retaining-a-borrow)). Upgrade by giving each
  element its own borrow, or by declaring what is stored before what holds it, so
  it outlives every use.
- A parametric alias with a `$` name inside a nested call that computes a type,
  `Alias :: Option(Identity($T))`, is now `L0742` at its declaration
  ([Parametric aliases](design.md#parametric-aliases)). It used to be accepted, and
  a pattern written through it could never match (`L0392`). Upgrade by writing the
  type the call computes where the `$` name stands, as `Option($T)`.
- A result written through an alias declared in a generic body now depends on a
  generic argument as the same result written out does
  ([One result](design.md#one-result)). `Outcome :: Result(T, E)` as a result used
  to allow a bare `return;` in the instance where `T` is `Unit` and an implicitly
  wrapped `return value;` beside an error payload, each now `L0326`, `L0365`, or
  `L0310` as for `Result(T, E)`. Upgrade by writing `return .ok;` or
  `return .ok(value);`.
- A call is now `L0511` when its callee may read a global a mutable borrow of it
  is still live across
  ([Global write effects](design.md#global-write-effects)). Passing `&mut counter`
  to a procedure that names `counter`, directly, through a callee, in a
  `hook(drop)`, `hook(convert)`, or `hook(copy)` it runs, or through a procedure
  value or `dyn` call that may reach such a procedure, used to compile, and the
  callee read through a name while the caller's borrow was meant to be exclusive.
  A read-only borrow beside such a call is still accepted, as is a mutable borrow
  whose last use came before it. The effect names whole globals, so `&mut g.a`
  beside a callee reading `g.b` is rejected too. Upgrade by ending the mutable
  borrow before the call, passing the value the callee reads as an argument, or
  having the callee read through its parameter instead of the global's name.
- A write into a parameter no longer hides the allocator it received there
  ([`@(allocator_reset)`](design.md#allocator_reset)). After `if (flag) { maybe =
  .some(allowed); }` on `maybe: inout Option(Allocator)`, `free_all(maybe or_else
  allowed)` used to compile though the payload may still be the caller's; it is now
  `L0538`, as a record's field, a `switch` binding, and `.as` are. A write on every
  path is rejected too, as these facts do not follow control flow. Upgrade by
  resetting the marked allocator itself.
- A borrow stored through a slice literal's slice is now seen
  ([Slice literals](design.md#slice-literals)). After `view := []mut []int{{}};
  view[0] = values[:];`, `drop(values)` used to compile while `view[0][0]` read the
  dropped array, and a hooked element's `hook(drop)` read it at the end of the block;
  both are now `L0512`, and an element holding a local that ends first is `L0513`.
  Upgrade by replacing the element before ending what it borrows, or by ending the
  source after the literal's block.
- An `assert` or `panic` report now borrows what it prints
  ([Built-in procedures](design.md#built-in-procedures)), as `fmt.println` does.
  `panic("stop", values[0], consume(move(values)))` used to print freed memory and
  is `L0512`; `panic("stop", p, change(inout p))` is `L0511`; and a printed value's
  `format` that writes a global the report holds is `L0512`. A value printed through
  a view, as `s[0]`, now keeps what the view names in use for the report and for
  `fmt.println` alike, so `fmt.println(s[0], grow(inout values))` is `L0511`. Upgrade
  by evaluating the later argument into a local first.
- A call that moves or copies carriers within the storage an argument reaches is
  now seen ([Values that contain borrows](design.md#values-that-contain-borrows)).
  After `exchange(&mut links[:])` over a fixed array or `share(&mut pair)` between
  fields, each carrier there kept what it held before the call, so a copy
  `held := links[0].to` still allowed writing what it now pointed at; that is now
  `L0512`, `L0511`, or `L0641`, whether the store is in a body, a generic instance,
  another package, a call through a procedure value, or a built-in `swap`, `sort`,
  or `reverse_sort`. After a call that may leave a mutable carrier in two places,
  using both is `L0641`, as is using one after another call passing them, as for
  the same store written out. Upgrade by ending the use of what was rearranged
  before changing its target, or by reading the carriers before the call.
- What is stored through a `foreach` loop's `&mut` binding is now seen in the
  source ([By-reference iteration](design.md#by-reference-iteration)). A carrier
  stored as `list.head = &mut c`, or an owner stored as
  `item = fmt.to_string(arena.allocator(), 42)`, used to stay in the binding, so
  `c` could be written, or `arena` dropped, while a later `lists[1].head` or
  `items[0]` still held it; these are now `L0511`, `L0641`, `L0537`, or `L0536`
  like the same store through `lists[i]`. Upgrade by ending the use of what was
  stored before changing what it points at, or by keeping the source apart from
  it.
- A generic record's hooks are now checked as a non-generic record's are. A wrong
  signature (`L0488`), a duplicate role (`L0488`), a `hook(copy)` on a `move_only`
  record or on an instance a field makes move-only (`L0488`), a written allocator
  default (`L0489`), a `hook(drop)` on a generic union (`L0488`), a member named
  `clone` or `try_clone` (`L0487`), and a malformed `hook(convert)` (`L0411`) used to
  be accepted, and with two drop hooks the second silently won. A hook in an `impl`
  block on another package's generic record used to be accepted and never run, and
  is now `L0486`. Upgrade by giving the hook its fixed signature, removing the
  duplicate, moving the hook to the record's own package, or bounding a copy hook
  with `where is_copyable(T)` so that it is left out of the instances it cannot
  serve.
- A record with `hook(drop)` and no `hook(copy)` must now say how it is copied
  ([Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types)):
  `L0747` at its declaration. It used to get a generated field-wise copy, which
  released twice what the hook released, or left a long chain's copy recursing
  through the chain. A record that a move-only field already makes move-only
  writes it too, a generic record decides once for all of its instances, and a
  declaration wrapped directly in `defer` is held to the same rule. A record
  declared in a generic procedure answers for each instance, whichever is
  instantiated first. The new `@(fieldwise_copy)` is `L0748` beside `move_only`,
  `hook(copy)`, or a move-only field, and `L0749` on a record with no drop hook.
  Upgrade by writing
  `Handle :: move_only struct { fd: int }` for a record that is never copied or
  whose copy would be wrong, by declaring a `hook(copy)`, or by writing
  `Key :: struct @(fieldwise_copy) { bytes: [dynamic]u8 }` where copying each field
  is right. `thread.Ring(T)` now says `move_only`, as its fields already made it.
- The `any_view` type is gone, with its implicit conversion, the explicit
  `any_view(value)`, and its storage diagnostic `L0462`; `any_view` is now an
  unknown name (`L0306`). `dyn` is the one type-erased view. A `..dyn I`
  parameter still views each argument implicitly
  ([Variadic parameters](design.md#variadic-parameters)), and the printers
  take `..dyn fmt.Formattable`. `base:runtime`'s `Type_Kind` loses `Any_View`,
  so `Dyn` and every later member move down by one. Upgrade an `any_view`
  parameter that prints its value to `..dyn fmt.Formattable` or to a
  `dyn fmt.Formattable` made with `(dyn fmt.Formattable)(&value)`, one that
  stands for a closed set of types to a union, and one whose type is known
  where the call is written to a `$T` parameter; and recompile code that
  stored `Type_Kind` values as numbers.
- Runtime type inspection is gone: the checked extractions `view.(T)` and
  `view.as(T)` on an `any_view`, a switch over an `any_view`'s type, and a
  type such as `case int(n):` or `case f32, f64:` as a case value
  ([switch statement](design.md#switch-statement)). `.(` is now `L0225`, a
  type case in a switch is `L0426`, and a type switch over a `dyn` value is
  still `L0466`. A union is still read with `value.as(.name)` and its switch.
  Upgrade each inspection by what it stood for: hold a closed set of types in
  a union and switch on its variants, take a type known where the call is
  written as a `$T` parameter, or add an interface slot for the behavior and
  call it through a `dyn` view.
- A C variadic parameter is written `@(c_vararg) args: ..`, with no type,
  rather than `..any_view`, which is now `L0627`; a bare `..` without the
  attribute is `L0627` too ([`@(c_vararg)`](design.md#c_vararg)). Upgrade by
  deleting `any_view` from each such parameter. `assert` and `panic` now take
  any printable value after the message by a rule of their own rather than as
  an `any_view`, so a value with no printed form, such as a capture literal, is
  `L0310` ([Built-in procedures](design.md#built-in-procedures)).
- The printers in `core:fmt` (`print`, `println`, `eprint`, `eprintln`,
  `format_to`, `concat_to`, `format_to_with`, `to_string`), `core:log`'s
  `debug`, `info`, `warning`, `error`, and `at`, and `io.write_formatted` and
  `write_formatted_line` take `..dyn fmt.Formattable` rather than
  `..any_view` ([Printed forms](standard-library.md#printed-forms)).
  A call that lists its arguments is unchanged and prints the same. Upgrade a
  procedure that spreads its own `..any_view` arguments into them by declaring
  that parameter `..dyn fmt.Formattable`.
- `Status(E)` is now `Result(Unit, E)`, declared as the parametric alias
  `Status :: Result(Unit, $E);` rather than a union of its own
  ([Typed fallibility](design.md#typed-fallibility)). A procedure generic over
  `Result($T, $E)` now takes a `Status`, and `Status.map_error` is
  `Result.map_error`. A `Status` type's name, in a `typeid`, reflection, or a
  diagnostic, is now `Result(Unit, E)`, and a non-generic `Status` body that
  returns a failure payload directly is reported by `L0310` as one returning
  neither the result nor its `Unit` payload. Upgrade by updating expected
  output that names `Status(...)`; by removing one of two overloads that take
  `Status(E)` and `Result(Unit, E)`, which are now one type; and by writing a
  generic `impl Status($E)` as `impl Result(Unit, $E)`, now an extension of
  `Result`.

- A union variant whose payload is `Unit` now prints as `.name`, as a
  payloadless one does, so a successful `Result(Unit, E)` prints `.ok` rather
  than `.ok(Unit{})` and `Option(Unit)` prints `.some`
  ([Printed forms](standard-library.md#printed-forms)). A two-variant
  union of a `Unit` variant and a non-null reference, such as
  `Result(Unit, ^T)`, now stores no tag, as `Status(^T)` already did, so it is
  one address and a nullable C pointer at a foreign boundary
  ([Representation](design.md#representation)). Upgrade by updating expected
  output that contains `(Unit{})`, and any code or binding that relied on such
  a union's size.

- A public type's private method no longer meets an interface slot, in any
  package, so an importer can no longer call it by declaring an interface
  with a slot of its name and calling that from a bound generic procedure or
  a `dyn` view ([Interface bodies](design.md#interface-bodies)). The same holds
  for a private associated constant that a requirement such as
  `T.Element -> type` would find. Private types and every type in a
  `package main` are unchanged. A bound that relied on such a method now
  fails with `L0444`, whose note names the private method. Upgrade by marking
  the method `@(public)`, if meeting the interface is meant to be part of the
  type's API, or by passing a private wrapper type instead.

- For the same reason, a public type's private `format` no longer decides how
  it prints: the type prints by the generated default in every package, its
  own included, as an explicit `dyn fmt.Formattable` view does
  ([Printed forms](standard-library.md#printed-forms)). Code in its
  package can still call the method directly. Upgrade by marking `format`
  `@(public)` to keep the custom form. Private types and every type in a
  `package main` are unchanged.

- A store through a carrier that the same multiple assignment reassigns, as
  `p^.head` in `p, p^.head = &mut y, p^.tail`, is now checked where the
  carrier pointed before the statement, where the store lands
  ([Evaluation order](design.md#evaluation-order),
  [Values that contain borrows](design.md#values-that-contain-borrows)).
  Before, the checker took it to go through the new value, so writing the
  storage a copy of `x.head` still pointed at compiled; it is now rejected
  with `L0511`, and a reborrow of the old target still in use after the
  statement now conflicts with the store (`L0641`). Upgrade by ending the
  borrow first, or by splitting the statement: `p^.head = v; p = q;` stores
  through the old `p`, `p = q; p^.head = v;` through the new one.

- The same holds when the reassigned carrier is a field or the whole record
  that holds it, as `holder.pointer` in
  `holder.pointer, holder.pointer^.head = &mut y, holder.pointer^.tail` or
  `holder` in `holder, holder.pointer^.head = Outer{&mut y}, ...`, or when it
  is loaded through a pointer an earlier target replaces. A destructuring
  assignment that reads the record it writes, as `r.second, r.first = r`,
  now keeps the values the record held before the statement. Code that
  relied on the old reading is now rejected with `L0511`
  ([Evaluation order](design.md#evaluation-order)). Upgrade as above, by
  splitting the statement in the order you mean.

- A loop that copies `s[k].head` out of a slice parameter, stores
  `s[k].tail` into it at a variable index, and uses the copy after the store
  is now rejected with `L0641`, as it already was through a pointer that may
  name either of two places
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). The next
  iteration's copy of `tail` can alias the copy still in use. Upgrade by
  finishing with the copy before the store.

- `lokec` needs LLVM/Clang 18 or later, now stated in
  [Getting started](readme.md#getting-started). The runtime's processor check
  for [CPU levels](compiler-guide.md#cpu-levels) uses compiler-rt's
  detection, which knows the levels from Clang 18; with an older Clang every
  build fails compiling `runtime/cpu.c` with `invalid cpu feature string for
  builtin`. Upgrade LLVM, for example with `winget upgrade LLVM.LLVM`.

- A call that may store an `@(escape=stored)` argument into a mutable
  destination it was also given, as `relink(p, r)`, now makes a carrier later
  copied out of that destination, as `h := p^.head`, a reborrow of the
  argument, so using `r` while `h` is still in use is rejected with `L0641`,
  as it is after storing `p^.head = r` directly
  ([Retaining a borrow](design.md#retaining-a-borrow),
  [Weakening and reborrows](design.md#weakening-and-reborrows)). Before, it
  compiled, and two mutable paths to one node were used together. Upgrade by
  finishing with the copy before using the argument again, or by taking the
  copy after the argument's last use.

- A read-only copy of a borrow stored through a pointer, as `h := p^.head`
  after `p^.head = r` with `head: ^Node` and `r: ^mut Node`, now keeps `r`
  from being written until `h`'s last use, as a read-only reborrow taken
  directly does; so does a call that stores `r` into such a destination
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). Before,
  writing through `r` while `h` was still used compiled. Upgrade by moving
  the copy's last use before the write, or by taking the copy after it.

- The same holds when what was stored is a named read-only reborrow, or a
  copy of one: after `read: ^Node = r; p^.head = read; h := p^.head;`, or
  `keep(p, read)` with an `@(escape=stored)` parameter, writing through `r`
  while `h` is still used is rejected with `L0641`
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). Before, it
  compiled. Upgrade as above: move `h`'s last use before the write, or take
  the copy after it.

- A carrier copied out of a record stored whole through a pointer, as
  `x := p^.head` after `p^ = q^`, now reborrows the carrier it was copied
  from, so copying `q^.head` again while `x` is still in use is rejected with
  `L0641`, as storing `p^.head = q^.head` already was
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). Before, it
  compiled, and two mutable pointers to one node were used together. Upgrade
  by finishing with the copy before copying the source again, or by copying
  through the destination only.

- A loop that keeps a copy of what an earlier iteration stored into an element
  of a slice parameter, as `s[0].head = s[1].tail; s[1].tail = s[2].tail;`
  repeated, is now rejected with `L0641`, as the same loop over a local array
  already was ([Weakening and reborrows](design.md#weakening-and-reborrows)).
  Upgrade by restructuring the loop as for the local array.

- The floating-point environment is specified: rounding to nearest, ties to
  even, subnormals kept, and non-stop exceptions, on every thread a program
  starts ([Floating-point operators](design.md#floating-point-operators)).
  The specification used to suggest installing trapping through the target's
  environment; floating-point results computed in any other environment are
  now unspecified. Upgrade foreign code that Loke calls and that changes the
  rounding mode, flush-to-zero, or exception masks by restoring them before
  it returns to Loke, for example by saving the state with `fegetenv` and
  restoring it with `fesetenv`. A C host calling into Loke needs no change.

- A compound assignment through a pointer, as `h^.count += 1`, while a
  borrow of the same place, as `count := &h^.count`, is still in use is now
  rejected with `L0641`, as a plain store already was
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). Before, it
  compiled, and the read-only borrow saw the place change. Upgrade by
  finishing with the borrow first, or by updating through it when it is
  mutable.

- A view of a lent `foreach` element over a source reached through a pointer
  now borrows that source, as
  [Borrowing iteration](design.md#borrowing-iteration) requires. Changing the
  source while such a view is still in use is now rejected; before, it
  compiled, and growing the container could leave the view dangling:

  ```loke
  grow :: proc(items: ^mut [dynamic]string) {
      kept: string_view = "";
      foreach (item in items^) { kept = item; }
      items.append(strings.copy("more"));   // now L0641
      fmt.println(kept);
  }
  ```

  Upgrade by finishing with the view before changing the source, or by
  keeping a copy, such as `kept_copy := strings.copy(item);`.

- A pointer to a lent `foreach` element over a source reached through a
  pointer now borrows that source even when the element holds borrows of its
  own, as a `string_view` does. Returning it past the source's end is now
  rejected with `L0526`; before, it compiled and the pointer dangled:

  ```loke
  first_slot :: proc(items: ^[1]string_view) -> ^string_view {
      foreach (item in items^) { return &item; }
      panic("empty");
  }
  escaped :: proc() -> ^string_view {
      values := [1]string_view{"hello"};
      return first_slot(&values);   // now L0526
  }
  ```

  Upgrade by returning a copy of the element, or by keeping the source alive
  for as long as the pointer is used.

- Changing a container reached through a mutable pointer during its own
  `foreach`, as `items.append(item)` inside `foreach (item in items^)` with
  `items: ^mut [dynamic]int`, is now rejected with `L0641`, as it already was
  for a local container
  ([Borrowing iteration](design.md#borrowing-iteration)). So is changing it
  through a pointer to that pointer, as `p^.append(item)` inside
  `foreach (item in p^^)` with `p: ^mut ^mut [dynamic]int`, or inside
  `foreach (item in p^^[:])`. Before, these compiled, and growing the
  container could leave the loop reading freed memory. Reading the container
  and changing its other fields in the loop still compile. Upgrade by
  collecting the changes in the loop and applying them after it, or by
  iterating over indices.

- A view of, or pointer into, a container reached through a pointer copied
  out of another, as `view: []int = p^^[:]` or `element := &p^^[0]` with
  `p: ^mut ^mut [dynamic]int`, or `holder.items^[:]` with
  `holder: ^mut Holder`, now keeps that outer pointer suspended while it is in
  use, as a view through one pointer already did
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). Changing the
  container through it, as `p^.append(1)`, is now rejected with `L0641`;
  before, it compiled, and the view could be left reading freed memory.
  Reading through the pointer still compiles beside a read-only view. Upgrade
  by finishing with the view before changing the container.

- Indexing through a pointer to a fixed array, as `p[0].a.x` with
  `p: ^[1]Outer`, now tracks the element and fields it reads. Before, the read
  could be matched to a different field of the array's element type, so using
  a view of a local after it ended could compile:

  ```loke
  Inner :: struct { x: string_view, y: string_view }
  Outer :: struct { b: string_view, a: Inner }
  main :: proc() {
      kept: string_view = "";
      {
          source := strings.copy("dangling");
          arr := [1]Outer{{"static", {source, "y"}}};
          p := &arr;
          kept = p[0].a.x;
      }
      fmt.println(kept);   // now L0513
  }
  ```

  Upgrade by keeping the viewed storage alive for as long as the view is
  used, or by keeping a copy.

- A mutable pointer copied out through a pointer parameter now keeps the
  place it was copied from suspended while the copy is in use
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). Using that
  place, or the whole pointer, meanwhile is now rejected with `L0641`; before,
  it compiled, leaving two mutable paths to one value, and growing a container
  through one could leave the other reading freed memory:

  ```loke
  grow :: proc(p: ^mut ^mut [dynamic]int) {
      copy := p^;
      p^.append(1);   // now L0641
      copy.append(2);
  }
  ```

  So is `list^.head^.value = 2` beside `node := list^.head` with
  `list: ^mut List`. The pointer's other fields, as `list^.count`, and
  storing a new pointer into the place, as `list^.head = other`, still
  compile. Upgrade by finishing with the copy before using the place again,
  or by using the place instead of a copy.

- Borrowing a variable that holds a mutable pointer, as `&mut held`, now uses
  that pointer, so it waits for the last use of a mutable reborrow of it.
  `both(held, &mut held)`, which hands a callee a pointer and a pointer to the
  variable holding it, and `other := &mut held` while `copy := held` is still
  in use, are now rejected with `L0641`
  ([Weakening and reborrows](design.md#weakening-and-reborrows)); before,
  they compiled, leaving two mutable paths to one container. Upgrade by
  passing the pointer once, or by finishing with the copy first.

- A store through a pointer read out of another local pointer, as
  `p^^.a^.value = 3` with `p := &mut held` and `held := &mut pair`, or out of
  an element reached through a pointer, as `p[0].a^.value = 3` with
  `p := &mut pairs`, now reads `p^^.a` or `p[0].a` on the way, so it waits for
  the last use of a copy of it, as `node := p^^.a`, and is rejected with
  `L0641` while that copy is in use
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). Before, it
  compiled, leaving two mutable paths to one value; reading the same place
  was already rejected. Upgrade by finishing with the copy first, or by
  storing through the copy.

- A `switch` payload binding of a mutable pointer over a place now waits for
  the last use of a mutable copy of the pointer stored there, as
  [Switch ownership](design.md#switch-ownership) requires: the binding names
  that pointer. Using `next` after `copy := cur^.next` beside
  `case .some(next):`, while `copy` is still in use, is now rejected with
  `L0641`, and so is the same over a local, as `copy := held` beside
  `switch (held) { case .some(viewed): ... }`. Before, it compiled, leaving
  two mutable pointers to one node in use:

  ```loke
  relink :: proc(cur: ^mut Node) {
      switch (cur^.next) {
      case .some(next):
          copy := cur^.next;
          next^.value = 1;   // now L0641
          switch (copy) { case .some(c): c^.value = 2; case .none: }
      case .none:
      }
  }
  ```

  Upgrade by using the binding instead of a copy, or by finishing with the
  copy before using the binding again.

- A mutable pointer stored behind a read-only parameter, as `head` in
  `Holder :: struct { head: ^mut Node }` read through `h: ^Holder` or
  `p: ^^Holder`, is now reborrowed by a copy of it, as one behind a mutable
  pointer already was
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). A second
  copy while the first is in use, as `b := h^.head` after `a := h^.head`, is
  now rejected with `L0641`; before, it compiled, leaving two mutable
  pointers to one node in use. Upgrade by finishing with one copy before
  taking the next, or by using one copy for both.

- A `switch` over a place reached through a pointer now borrows the place
  while a payload binding is in use, as one over a local already did
  ([Switch ownership](design.md#switch-ownership)). Writing the payload
  through any pointer to it meanwhile is rejected with `L0511`: a store, a
  mutable borrow, an `inout` argument, handing a mutable pointer that reaches
  it to a call, or a mutable copy of such a pointer, as `q := h` or
  `Wrap{h}`, just as `q := &mut l` is beside a binding of `l.first`. Writing
  beside the payload still compiles, as `h^.count += 1` or
  `bump(&mut h^.count)` does, and so does writing through a
  borrow of another field taken before the switch, held in a record, or chosen
  by a condition, as `count^ = 1` for `count := &mut h^.count` or
  `bump_side(Side{&mut h^.count if flag else &mut h^.count})`. Before, the
  rejected writes compiled, and the binding went on reading a payload that
  had been replaced:

  ```loke
  peek :: proc(h: ^mut Holder) -> int {
      switch (h^.first) {
      case .some(node):
          clear(h);   // now L0511: `clear` may write `h^.first`
          return node^.value;
      case .none:
      }
      return 0;
  }
  ```

  Upgrade by finishing with the binding before the write or copy, by copying
  what the case needs out of the payload first, or by copying the pointer
  read-only, as `q: ^Holder = h`, when the copy only reads.

- A `&mut` case binding over a place reached through a pointer now borrows
  its payload exclusively while it is in use, as one over a local already did
  ([Switch ownership](design.md#switch-ownership)). In
  `switch (h^.first) { case .some(&mut m): ... }`, storing into `h^.first`,
  reading it, or handing `h` to a call while `m` is still used is rejected
  with `L0641`; before, nothing was checked, so `h^.first = .none` could
  replace the payload `m` still named. Two `&mut` field bindings of one
  payload stay separate places. Upgrade by finishing with the binding before
  the access, or by making the access through the binding.

- Handing a pointer to a call, or copying it into storage, now uses every
  mutable pointer reachable through it, so `touch(list)`, `q := list`,
  `q: ^List = list`, or `Holder{list}` while `node := list^.head` is still in
  use is rejected with `L0641`
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). A pointer to
  a local, as `list := &mut l`, was exempt from the call rule, and `touch`
  could write through `list^.head` while `node` still pointed at the same
  node; a copy was exempt everywhere, though only a later use of it through
  `list^.head` was rejected. Upgrade by finishing with the copy of
  `list^.head` before the call or copy, or by passing that copy instead.

- A later load through a parameter now sees what the body stored through it,
  as one through a pointer to a local does
  ([Values that contain borrows](design.md#values-that-contain-borrows)).
  Using a carrier while a copy of it the body stored through a parameter is
  still in use is now rejected with `L0641`; before, it compiled, and could
  build a cycle that a write through it then broke under a live payload
  binding:

  ```loke
  Node :: struct { value: int, back: ^mut Holder }
  Holder :: struct { first: Option(^mut Node), count: int }
  make_cycle :: proc(@(escape=stored) h: ^mut Holder, @(escape=stored) n: ^mut Node) -> int {
      n^.back = h;
      h^.first = .some(n);       // now L0641: `n^.back` still holds a copy of `h`
      switch (h^.first) {
      case .some(node):
          node^.back^.first = .none;
          return node^.value;
      case .none:
      }
      return 0;
  }
  ```

  So is a borrow of a place a pointer the body stored through a parameter
  points at, as `right := &p^.right` beside `left := &mut p^.left` after
  `p^.left.next = &mut p^.right`. Upgrade by finishing with the stored copy
  before using its source again, or by storing the carrier itself instead of
  keeping a second one.

- The fields of `fmt.Fixed` and `fmt.Padded` are now private, as
  [`core:fmt`](standard-library.md#corefmt) already documented them. Reading
  `p.value` or `p.width` or writing a `fmt.Fixed{...}` literal is rejected;
  make the wrappers with `fmt.fixed`, `fmt.pad_left`, `fmt.pad_right`, and
  `fmt.zero_pad`, and keep the wrapped value yourself if you need it again.

- `core:random`'s distributions now compute their `exp`, `log`, `pow`, and
  `sqrt` with `core:math/repro`, so a seeded generator gives the same values
  on every machine and CPU level, and the distributions run at compile time
  ([Distributions](standard-library.md#distributions)). The algorithms and
  draw orders are unchanged, but a value whose C library result was not
  correctly rounded changes in its last bit, and with it any decision that
  bit made: on one machine, about one `log_normal` value in 200. A count from `poisson`, `binomial`, or `geometric` that changes
  shifts every later draw. Two ziggurat table entries also moved by an ulp,
  which changes a `normal` or `exponential` value far more rarely. Upgrade
  replays and saved sequences recorded from a distribution by recording them
  again; a program that needs the old values must keep its own copy of the
  old procedure. The distributions that call these functions on every value
  are slower, `beta` by Jöhnk's method most, from 13 to 205 ns; `normal` and
  `exponential` are not.
- A member `as` in an `impl` of a generic union is now `L0409`, as in an `impl` of any other union
  ([Inspecting a union](design.md#inspecting-a-union)). It compiled and no use could reach it, since
  `u.as(.a)` selects the built-in. Upgrade by renaming it.
- A public constant in a generic extension is no longer exported under its package
  ([Methods and implementation blocks](design.md#methods-and-implementation-blocks)): `ext.K` is now
  `L0335`. With `impl lib.Holder($T) { @(public) K :: size_of(T); }` it took its value from whichever
  instance came first. Upgrade by exporting an ordinary constant, or a procedure of the block.
- The fields of a built-in array, slice, dynamic array, range or map iterator are private
  ([Iteration protocol](design.md#iteration-protocol)): `it.index` is now `L0471`. Writing
  `x.iter().index` let safe code read outside the array and segfault. Upgrade by calling `next`.
- What a `foreach` step owns no longer outlives the step
  ([Element bindings](design.md#element-bindings)): a pointer to the `indexed()` counter, or to the
  record one name receives over a map or an `indexed()` loop, is `L0526` when returned and `L0513`
  when kept past the step. `foreach (e in xs.indexed()) { return &e; }` compiled and left a dangling
  pointer. Upgrade by copying what the step binds, or by keeping `e.value`, which the source owns.
- `foreach ((p, q), &mut c in t)` that takes apart an owned part with a custom `hook(copy)` or
  `hook(drop)` is `L0508`, as in a loop with no `&mut` leaf
  ([Destructuring](design.md#destructuring)). It compiled and the hook never ran. Upgrade by binding
  the part whole.
- A group member no longer wins for taking an argument as a `$` parameter
  ([Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution)).
  With `plain(x: int)` and `gen($x: int)`, `pick(1)` called `gen`, because the ownership tie-breaker
  counted the literal against `plain`; it now calls `plain`. Upgrade by calling `gen` by name where
  it was the one meant.
- A capture is a binding, so `capture(true = 1)` and `capture(nil = 7)` are now `L0700`, as
  `true := 1` is ([Predeclared names](design.md#predeclared-names)), and `capture(_ = 41)` is
  `L0716`, since `_` binds nothing ([Capture literals](design.md#capture-literals)). They compiled,
  and in the body the name read the capture. Upgrade by renaming the capture.
- A replacement for a bundled package given with `-collection` can no longer write an
  [`@(intrinsic)`](design.md#intrinsic) declaration that states what nothing checks. A written type,
  as in `Arena: int : ---;`, a `where` clause, and `operator(...)` or `hook(...)` around the procedure
  are `L0734`. A receiver with no type but not named `self`, as in `proc(this)` or `proc(self, other)`,
  is `L0736`. An unknown or misplaced attribute on the block's `impl` is reported like any other. All
  compiled, unchecked, and `-doc` showed them. Upgrade by writing the declaration as the bundled
  package's source does.

### Added

- [`core:container`](standard-library.md#corecontainer) has
  [`Priority_Queue(T, C)`](standard-library.md#priority-queues) with `Min_Queue(T)` and `Max_Queue(T)`,
  which always hand back the most urgent element under a comparator stored in the queue, and
  [`Deque(T)`](standard-library.md#deques), a growable double-ended queue that extends a dynamic array's
  names with `prepend` and `pop_front`. Both hold move-only elements and have fallible forms.
- [`core:slice`](standard-library.md#heaps) has `make_heap`, `push_heap`, `pop_heap`, `sift_heap_top`,
  and `is_heap` over a slice the caller owns, and the comparators `Ascending(T)` and `Descending(T)`.
- [`core:checksum`](standard-library.md#corechecksum) has `Crc(T, P)`, an incremental CRC of any
  catalogue parameter set checked at compile time, with `Crc32`, `Crc32c`, and `Crc64`. Its zero
  value is the checksum of no bytes, and it is an `io.Writer`.
- [`core:encoding/binary`](standard-library.md#coreencodingbinary) reads and writes binary
  formats: a bounded `Reader` over a borrowed slice, whose failed operations change nothing and
  report an offset, with subrecords and lengths checked before they are used, and a `Writer(W)`
  of typed fields into any `io.Writer`.
- `core:io` has `Slice_Writer`, a [bounded byte sink](standard-library.md#bounded-byte-sink) over a
  caller's slice, and `Buffer_Writer.bytes_mut`, to patch a finished buffer in place.
- `core:endian` has `load` and `store`, a field of a byte slice in a named order, for every
  type `is_fixed_width` accepts, floats included
  ([Fields of a byte slice](standard-library.md#fields-of-a-byte-slice)).
- `core:math` has `to_bits` and `from_bits`, a float's exact IEEE-754 encoding in each width
  without `core:unsafe` ([`core:math`](standard-library.md#coremath)), and
  [Floating-point operators](design.md#floating-point-operators) now promises that moving a
  float keeps its encoding.
- `@(move_only)` applies to a union too, which could be move-only only through a move-only
  payload before ([`@(move_only)`](design.md#move_only)).
- `lokec -migrate` rewrites what an earlier release accepted into what this one does, in a
  file or a directory's `.loke` files, and leaves everything else as written;
  `-migrate-check` lists the files it would change
  ([Common options](compiler-guide.md#common-options)).
- [`@(fieldwise_copy)`](design.md#fieldwise_copy) keeps the generated field-wise
  copy of a record with a `hook(drop)`, for a hook that adds a step each value
  needs once.
- A `..dyn I` parameter takes any value whose type satisfies `I`, viewing
  each argument where it is or in a temporary that lives through the call, so
  `total(square, Circle{1})` needs no `(dyn I)(&...)` per argument
  ([Variadic parameters](design.md#variadic-parameters)). A `dyn I` argument
  is passed as it is, an untyped constant is viewed at its default type, and a
  move-only place stays usable after the call. Only the elements of a read-only
  `..dyn I` pack convert; a `dyn` local, an ordinary `dyn` parameter, and a
  `..dyn mut I` pack still take an explicit conversion.
- `variants_of` takes an enum as well as a union, listing each member as a
  `meta.Variant` with the payload `Unit` and its declaration index, so one
  generic loop names the alternatives of either; a member's value stays with
  `enum_values_of` ([Compile-time reflection](design.md#compile-time-reflection)).
  `variants_of` of any other type is still `L0451`.
- A type alias may bind `$` names, which an application supplies in order of
  first appearance: `Io_Result :: Result($T, Io_Error);` makes
  `Io_Result(int)` the type `Result(int, Io_Error)`, with no identity of its
  own, and `Buf :: [$N]u8;` takes a constant
  ([Parametric aliases](design.md#parametric-aliases)). The body's names
  resolve where the alias is declared. A parameter written through one,
  `r: Io_Result($T)`, infers and ranks as its expansion. A misplaced or
  doubly bound `$` name, a `distinct` or computed body, a self-reference, a
  local alias, and an `impl` over an alias's applications are rejected with
  `L0741` to `L0746`.
- [Minimum provenance precision](design.md#minimum-provenance-precision)
  now guarantees that a pointer chosen among borrows by branches or
  reassignment keeps at least 8 places of each storage apart, and 64 in all,
  so a write to another field beside a borrow through it is portable.
  `lokec` used to keep 8 in all, so four choices from `s` and five from `t`
  rejected a write to another field of `s`; it now compiles. Past the limits,
  the rejection still names them. A pointer that may point into more than one
  storage may be taken to point at each of its places in every one, and a
  rejection this causes now says the borrow *may* cover the place and names
  that limit.

- An implicit selector or typeless literal argument whose generic parameter
  type names the procedure's `$` parameters is typed after the other arguments
  have inferred them, so `value_or(x, .some(y))` against
  `proc(value: $T, fallback: Option(T) = .none)` compiles, as do
  `same(Color.Red, .Green)` and `second(1, {2, 3})`
  ([Arguments typed after inference](design.md#arguments-typed-after-inference)).
  Arguments still run in written order. A waiting argument binds nothing, so
  one that is the only binder of a `$` name is still rejected (`L0385`, now
  naming the unbound parameter), and in a procedure group it takes no part in
  choosing the member, whose parameter then checks it.

- `core:math` has the
  [integer bit operations](standard-library.md#integer-bit-operations)
  `count_ones`, `leading_zeros`, `trailing_zeros`, `rotate_left`, and
  `rotate_right`, for every integer type, signed or unsigned. Zero has as
  many leading and trailing zeros as its type has bits, a rotation takes any
  `int` count modulo the width, a constant argument gives a constant, and
  each is one LLVM intrinsic at every optimization level.

- `core:math` has the
  [integer bit operations](standard-library.md#integer-bit-operations)
  `bit_width`, `reverse_bits` (LLVM's `bitreverse`), `is_power_of_two`,
  `next_power_of_two`, and `checked_next_power_of_two`, for the same types.
  The power-of-two operations read the value, so zero and every negative
  value are no power of two and round up to 1. A `next_power_of_two` that
  does not fit its type panics as checked arithmetic does, or is a
  compile-time error where it is computed at compile time, and the checked
  form returns `.none` there.

- `core:container` has
  [index sets](standard-library.md#corecontainer-index-sets), sets of the
  indices `0 ..< cap` held one bit each: `Index_Set(N)` inline,
  `Dynamic_Index_Set` from an allocator, and `Index_View` and
  `Index_View_Mut` over the caller's words. They set, clear, and test single
  indices and ranges, count, search for the next present or absent index,
  combine in place, iterate present indices, and store to and load from a
  byte form fixed independently of the host's byte order. Membership is
  also `i in set`, and `Dynamic_Index_Set`'s `try_init` and `try_resize`
  return an `Allocator_Error` instead of following the allocator's failure
  policy, leaving the set unchanged when they fail.

- Compile-time evaluation runs a [capture literal](design.md#capture-literals),
  so a constant may be computed by a procedure that makes one and calls it,
  directly or through an `interfaces.Callable` parameter, including writes
  through a `&mut` capture
  ([Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)).
  The literal stays a runtime value: a constant's value cannot be or hold one,
  and a `dyn proc` view of one is still rejected, both with `L0341`.

- A [repeatable math benchmark](bench/math_compare/README.md#reproduce) comparing
  UCRT and reproducible functions with seeded, grid, and dependent inputs.

- A block comment starting with `/**` is a
  [doc comment](design.md#doc-comments), for documentation longer than a
  line. Its text drops the indentation its lines share, so it needs no `*` on
  each line; `/***` and `/**/` stay ordinary comments:

  ```loke
  /**
  	Files, directories, and file metadata.

  	A native error number reaches a caller only through `io.native_code_of`.
  */
  package fs;
  ```

  A `/**` comment written before this release is now shown by `-doc` and
  hover, and is warned about with `L0260` when it documents nothing. The
  bundled packages write their doc comments longer than a line this way, and
  `api.loki` shows them as `/* */` blocks.

- `fs.File.set_size` truncates or extends an open file, so a log can be cut
  back to its last whole record after a crash, through its append handle
  too; `fs.File.metadata` describes the open file, its size included, without
  moving the position. `io.Operation` gains `Set_Size`
  ([Opening and file I/O](standard-library.md#opening-and-file-io)).

- `fs.File.read_at` and `write_at` read and write at an offset in one call,
  and `read_exact_at` and `write_all_at` loop until the whole buffer has
  moved, for files read and written in place by page
  ([Positional I/O](standard-library.md#positional-io)).

- `fs.File.lock`, `try_lock`, and `unlock` take an advisory shared or
  exclusive lock on a whole file, held by the handle and released by `close`,
  `drop`, or the program ending, so a store can insist on one writer. A
  failed `unlock` keeps the lock, so a retry releases it.
  `io.Operation` gains `Lock` and `Unlock`
  ([File locking](standard-library.md#file-locking)).

- `fs.replace_atomic` and `fs.replace_atomic_text` replace a file so that a
  reader, or the program after a crash or power loss, sees either the whole
  previous file or the whole new one, and on success the new one is durable
  ([Atomic replacement](standard-library.md#atomic-replacement)).

- `math.floor_div` and `math.floor_mod` divide any integer type rounding the
  quotient toward negative infinity, where `/` and `%` truncate toward zero,
  so `math.floor_div(-1, 16)` is `-1` and `math.floor_mod(-1, 16)` is `15`.
  For a power-of-two divisor, `x >> n` and `x & (2^n - 1)` already give the
  same results ([Integer operators](design.md#integer-operators)).
- `core:encoding/json` parses strict RFC 8259 JSON into an immutable document
  of borrowed views, keeping member order, repeated keys, and exact number
  spellings, and writes JSON through a caller's buffer into any `io.Writer`,
  compact or pretty. Every failure is a returned error with a byte offset,
  including malformed, oversized, or deeply nested input and running out of
  memory ([`core:encoding/json`](standard-library.md#coreencodingjson)).
- `io.Buffer_Writer` is an owning, growable byte sink that satisfies
  `io.Writer`, for output assembled in memory before it is published
  ([Byte buffer](standard-library.md#byte-buffer)).
- `strconv.try_parse_f64` and `fmt.try_spell_f64` report a failure to create
  the "C" numeric locale as a `Backend_Error` where `parse_f64` and printing
  panic, and `fmt.try_spell_f64` spells a float into a fixed buffer without a
  sink or an allocation.
- `-cpu=x86-64-v2` and `-cpu=x86-64-v3` build for a higher x86-64
  microarchitecture level, for the program and the runtime alike, and the
  executable checks the processor at startup, exiting with status 3 on one
  without the level. `x86-64` stays the default. At `x86-64-v3`, `math.fma` is
  one instruction, with the same result. An object build makes the same check from a
  static constructor, before its C host's `main`, and the host can check first
  with `loke_rt_v1_cpu_supports`
  ([CPU levels](compiler-guide.md#cpu-levels)).
- `math.fma_is_instruction()` is true where `math.fma` is one instruction,
  so that an `if` can choose an algorithm by it. `core:math/repro` does: at
  `x86-64-v3` its exact products come from the instruction, with the same
  results, and its functions take up to a third less time, `asin` 29%, `pow`
  21%, and `hypot` 31% less ([`core:math`](standard-library.md#coremath)).
- `@(cpu_dispatch="x86-64-v3")` marks a procedure that a build for a lower
  CPU level also emits for the named one, with every procedure it calls
  directly; a call runs that copy on a processor with the level, which the
  runtime checks once per process, and the results are the same either way.
  `core:math/repro`'s `f64` functions but `sqrt` are marked, so a baseline
  executable runs them with the FMA instruction where the processor has it,
  most near a fifth faster there. `LOKE_DISPATCH_CPU=x86-64` keeps a run on
  the build's own code ([`@(cpu_dispatch)`](design.md#cpu_dispatchstring),
  [CPU levels](compiler-guide.md#cpu-levels)).
- `@(cold)` marks a rarely called procedure, which is never inlined into its
  callers, so their frames stay small, and the path to a call to it is laid
  out as unlikely. `core:math/repro`'s fixed-point slow paths are marked:
  `hypot` takes 13.4 ns rather than 17.9, `pow` 55.2 rather than 58.4, and
  `tan` 51.1 rather than 53.1, with the same results
  ([`@(cold)`](design.md#cold)).
- `core:math/repro` holds correctly rounded elementary functions, whose
  results are the same bits on every machine, CPU level, and optimization
  level, and at compile time: `exp`, `log`, `log2`, `log10`, `pow`, `sqrt`,
  `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, and `hypot` in both
  widths, and `complex_abs` and `quaternion_abs`, the magnitudes of
  `math.Complex` and `math.Quaternion`, the second rounded once where
  `q.abs()` rounds three times
  ([`core:math/repro`](standard-library.md#coremathrepro)).
- `repro.RESULTS_VERSION` and `random.SEQUENCE_VERSION` name the versions of
  `core:math/repro`'s results and of the values a seeded `core:random`
  generator gives; each changes with any of them, so a replay or a lockstep
  peer can record them and refuse a recording that would diverge
  ([Version policy](releasing.md#version-policy)).
- `examples/lockstep.loke` is a lockstep simulation: a fixed timestep, an
  input log, `core:math/repro` and `core:random`, and a hash of a canonical
  serialization that is the same on every CPU level and optimization level,
  with a replay from the seed and from a snapshot and the versions a
  recording carries ([Examples](examples/README.md)).
- An export, or any procedure Loke defines with a foreign calling convention,
  runs in Loke's floating-point environment when a C host or library calls
  it with another rounding mode, flush-to-zero, or unmasked exceptions, and
  restores the caller's on return; so do `loke_rt_v1_program_init` and the
  thread-local drops `loke_rt_v1_thread_detach` runs. With `-debug`, a call into foreign code
  that returns with the environment changed panics, naming the procedure
  ([Floating-point operators](design.md#floating-point-operators)).
- `core:math/linalg` has fixed-size vectors and matrices with the same bits
  everywhere: `Vector2(T)` to `Vector4(T)` and `Matrix(T, R, C)` of any
  shape, column-major with column vectors, for any `interfaces.Numeric(T)`;
  `solve`, `inverse`, rotations, `rotate` over `math.Quaternion(T)`, and
  `perspective`, `orthographic`, `look_at`, and `look_to` with their `_lh`
  forms, for a `linalg.Real(T)` such as `f32`, `f64`, or a user type. Every
  projection takes its clip-space `Depth_Range`, degenerate input returns
  `Option`, and `approx_equal` takes both tolerances. The quaternion
  procedures convert to and from matrices (`quaternion_from_matrix`), Euler
  angles in an explicit `Euler_Order`, and rotation vectors, and add
  `quaternion_between`, `nlerp`, and `slerp`. Vectors have `angle_between`,
  `project`, `reject`, and `reflect`, and a 4 x 4 transform has
  `inverse_affine`, `normal_matrix`, and `project_point`. `linalg.Scalar(T)`
  is a real or complex number type, with an associated `T.Real`, which
  `f32`, `f64`, and `math.Complex` of any `Real` meet. At `f32`,
  `transform_point`, `transform_direction`, and a 3 x 3 `m * v` compute in
  `Simd` lanes with the same bits; `bench/linalg.loke` measures the batch
  operations ([`core:math/linalg`](standard-library.md#coremathlinalg)).
- `core:math/dense` has matrices whose size is known at run time, of real or
  complex elements, with the same bits everywhere: an owning column-major
  `Matrix(T)`, `View(T)` and `View_Mut(T)` over a matrix or a foreign buffer
  in either order, with blocks, transposes, conjugate transposes
  (`adjoint()`), and column and row splits that the borrow checker keeps
  apart; products and element-wise operations, each with an `_into` form that
  never allocates; triangular solves, `lu` with `reciprocal_condition`,
  `cholesky`, Householder `qr` with `Q` applied without forming it, `solve`,
  `inverse`, `least_squares`, `symmetric_eigen` for symmetric and Hermitian
  matrices, `svd` with a minimum-norm `solve` and `rank`, and the Frobenius,
  1-, and infinity norms, for any `linalg.Scalar` element. Eigenvectors and
  singular vectors have a fixed sign, so two machines give the same vectors.
  Numerical failures are one `dense.Error`.
  `f32` and `f64` products run a `Simd` kernel and `lu` and `cholesky` are
  blocked around it, and the products, `lu`, and `cholesky` take an optional
  thread pool, with the same bits either way; `bench/dense.loke` measures
  them ([`core:math/dense`](standard-library.md#coremathdense)).
- `core:math/geometry` has the exact predicates `orient2d`, `orient3d`,
  `incircle`, and `insphere`, which return the sign of their determinant
  exactly for `f32` and `f64` coordinates, by Shewchuk's adaptive method, and
  for integers that do not overflow; and closed shapes over `linalg`'s
  vectors, `Aabb2`, `Aabb3`, `Circle`, `Sphere`, `Plane`, `Segment2`,
  `Segment3`, `Triangle2`, and `Triangle3`, with box algebra, `contains`,
  closest points, distances, barycentric coordinates, and `intersects`
  between boxes, circles, spheres, and planes, exact for integers; and
  `Ray2` and `Ray3` with `cast` against boxes (conservative, never missing
  one), circles, spheres, planes, and triangles (watertight), the closest
  points of two segments, exact `intersects` between segments and between a
  segment and a box, triangles against boxes by separating axes, `Frustum`
  extraction for each `linalg.Depth_Range` with conservative culling, and
  `transform_box` and `transform_plane`; and polygons as slices of vertices,
  with `signed_area`, `centroid`, `winding_number`, `contains` under a
  required `Fill_Rule`, `convex_hull`, `is_convex`, and `is_simple`, exact
  for `f32`, `f64`, and integers. An `f32` box cast computes its three slabs
  in `Simd` lanes with the same bits; `bench/geometry.loke` measures the
  casts, frustum culling, and the predicates against hand-written loops
  ([`core:math/geometry`](standard-library.md#coremathgeometry)).
- `core:time` has time zones: `local_zone()`, the zone the system's clock
  shows, with Windows' own rules and history, read on each use; `fixed_zone`;
  and `now_local()`. `Zone.offset_at` and `Zone.to_local` convert an
  instant, `Zone.resolve` says whether a wall-clock time is `unique`, in a
  `gap`, or in an `overlap`, with the offsets on each side, and `Zone.at`
  picks an instant with a `Choice`: `Compatible`, RFC 5545's and Temporal's,
  `Earlier`, `Later`, or `Reject`
  ([Time zones](standard-library.md#time-zones)).
- A `core:time` `Zone` prints what it holds rather than `Zone{}`: a fixed
  zone its offset, `+05:30` or `Z`, and the system zone `local`
  ([Time zones](standard-library.md#time-zones)).

- The warning `L0740` reports a public declaration that names a private one
  of its package where an importer would have to name it too: a private type
  in a public procedure's parameter or result types, a public field, a type
  alias, or a constant's type, as `Fill` in `[]Fill` or `Option(Fill)`, and
  any private declaration in a public `where` clause. A procedure group's
  private members, defaults, array lengths, and a `package main` are not
  reported ([Private names in public declarations](design.md#private-names-in-public-declarations)).
  `core:math/linalg`'s `Converts`, the bound of the conversion hooks, is now
  public, and `time.styled` writes its bound out instead of naming a private
  procedure.

### Changed

- `find_or_insert`, `try_find_or_insert` and `try_insert` on a map of unmanaged elements, such as the
  counting idiom on a `map[int]int`, push no unwind frame.
- Slicing a `string` or a `string_view` tests only the bytes at its bounds, in constant time, rather
  than validating the whole range, since the text is already valid UTF-8. `rest = rest[1:]` over
  256 KB took 145 s and now takes under 0.2 s. A bound inside a sequence still panics.
- Comparing a fixed array of more than 8 elements or 64 bytes generates a loop rather than a few
  instructions per element, so `[4096]u8 == [4096]u8` is about 40 lines of IR, down from about 16,400.
- [design.md](design.md) is shorter and no longer specifies the library, with no
  change to what a program means.
  [standard-library.md](standard-library.md) now specifies printing, `core:slice`,
  `core:container`, `core:simd`, `core:sync`, `core:mem`'s regions, and the
  interface catalogue. Provenance tracking rules moved to the
  [Analysis guarantees](design.md#analysis-guarantees) appendix, and
  [Inferred effects](design.md#inferred-effects) states once how the effects are
  computed. The `Type_Kind` listing no longer names the deleted `Any_View`.
- A procedure returning a fallible union whose success carries `Unit`, such
  as `Result(Unit, E)` or `Option(Unit)`, may now reach the end of its body or
  use `return;` to succeed, as one returning `Status(E)` may, when the result
  as written makes the payload `Unit`. A body generic over `Result(T, E)` still
  writes `return .ok;` in an instance where `T` is `Unit`, and its `return;`
  is `L0326` with a note saying why ([One result](design.md#one-result)).
- The specification no longer lists an implicit conversion from a variant's
  payload to its union, which the compiler never had and `L0352` rejects
  ([Implicit type conversions](design.md#implicit-type-conversions)). It now
  says what a procedure type's runtime member table holds: its parameters,
  then its result, as nameless entries ([`type` and
  `typeid`](design.md#type-and-typeid)). The iteration protocol spells
  `iter`'s receiver `self: ^`, as the catalogue's `Iterable` does, and says a
  plain `self` also meets it ([Iteration protocol](design.md#iteration-protocol)).
- Elements of a view at different constant indices are now different places
  wherever it is known where the view starts: in a view parameter, and in a
  local view borrowed from a range or resliced from one by a constant. So
  `&mut xs[0]` leaves `xs[1]` usable, and a switch over `xs[0].first` allows a
  store into `xs[1].first`
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). An index
  that is no constant, or a copy of the view, may still name any element.
- Checking is faster: front-end time fell 3-16% on the examples and
  benchmarks taking over 30 ms (`bench/workspace` 184 to 162 ms,
  `examples/corpus_runner.loke` 249 to 228 ms), compiler peak working set
  2-7%, and language-server operations on `bench/workspace` 6-12%.
  Provenance summaries no longer rebuild a body none of whose callees'
  summaries changed, and the per-body analysis arenas no longer lock on every
  allocation. Diagnostics are unchanged.
- A thread that finds a `sync.Once` action, or a `sync.Lazy(T)`'s `init`,
  still running now blocks after a short spin instead of spinning until it
  finishes, so slow setup no longer costs every waiting thread a processor
  ([Atomic operations and Once](standard-library.md#atomic-operations-and-once)). With
  24 threads on 6 processors waiting on 6 ms setups, CPU time fell from about
  1.3 s to 0.17 s, about what the setups themselves take. It needs no new
  link library.
- A bare `where` bound grants its declaration the associated constants that
  met the interface, as it grants slots, in the signature, the other bounds,
  the body, and a record's fields, and grants the slots of an application the
  interface composes on that application's subject, so a `linalg.Scalar(T)`
  bound reaches `T.Real` and `linalg.Real`'s slots on it in any package
  ([Interface bodies](design.md#interface-bodies)). An associated constant
  requirement such as `T.Real -> type` is now met, when the applying package
  sees no such member, as a slot is: by an inherent member whatever its
  visibility or an extension in the interface's package. An application that
  was false for that reason alone, as `linalg.Scalar(f64)` was outside
  `core:math/linalg`, is now true, in a `when` condition too.
  `core:math/dense` no longer declares its own `Real` for `f32`, `f64`, and
  `math.Complex`, and the methods `Lu.reciprocal_condition`,
  `Symmetric_Eigen.values`, `Svd.singular_values`, `Svd.rank`,
  `Svd.solve_into`, and `Svd.solve` restate `where linalg.Scalar(T)`, which
  their records already require.
- A `typeid_of(T)` constant is specified to have no number during
  compilation: bit casting one with `unsafe.transmute`, or comparing one with
  a `typeid` built from a bit pattern, is a compile-time error where a
  constant is required (`L0688`, `L0341`) and is evaluated when the program
  runs elsewhere. Comparing two `typeid_of` constants still folds. This is
  the compiler's existing behavior
  ([`type` and `typeid`](design.md#type-and-typeid)).
- A NaN result's sign and payload are unspecified, and can differ between
  optimization and CPU levels, at compile time, or when the optimizer swaps
  the operands of `+` or `*`
  ([Floating-point operators](design.md#floating-point-operators)).
  `core:math/linalg`'s same-bits promise now excepts which NaN a NaN result
  is.
- `core:fs` is documented to pass paths to Windows as given: an ordinary path
  is normalized before any link in it is followed, so
  `local/junction/../x` names `local/x`, while an extended-length `\\?\`
  path is not normalized ([`core:fs`](standard-library.md#corefs),
  [Filesystem operations](standard-library.md#filesystem-operations)).
- `core:math/repro`'s `sin`, `cos`, and `tan` are proved correctly rounded for
  every `f64` argument, against the published hard-to-round cases of
  Lefèvre, Ly, and Zimmermann (ARITH 2026) and CORE-MATH, with the same
  results; the probe checks them on the hardest of those cases
  ([`core:math/repro`](standard-library.md#coremathrepro)).
- `core:math/repro`'s `exp` takes 14 ns rather than 19, and `pow` 55 rather
  than 60, with the same results: their shared kernel's dependency chain is
  about a third shorter. `log`, `log2`, and `log10` take 1 to 4 ns less per
  call the same way, and about 5 ns less in a chain of dependent calls, and
  `pow` 4 ns less again for its own logarithm.
- `core:math/repro`'s `f32` functions are faster, with the same results:
  `sin_f32`, `cos_f32`, `tan_f32`, and `pow_f32` try a single-`f64`
  approximation first, as the others already did, and every `f32` rounding
  decision lost a mispredicted branch. `sin_f32` takes 27 ns rather than 61,
  `tan_f32` 30 rather than 88, `pow_f32` 35 rather than 92, and `exp_f32` 14
  rather than 20.
- `core:math/geometry`'s predicates are faster where their floating-point
  filter decides, with the same results: their exact paths are `@(cold)`, so
  the filter is inlined into its callers. `orient2d` takes 2.7 ns rather than
  6.9, `orient3d` 5.9 rather than 10.5, `incircle` 6.3 rather than 7.2, and
  `insphere` 16.7 rather than 17.9.
- `math.sqrt` and `math.sqrt_f32` are the processor's square root instruction
  rather than a call to the C library: as correctly rounded, about as fast,
  and with a compile-time value, so `ROOT :: math.sqrt(2.0)` is a constant
  ([`core:math`](standard-library.md#coremath)).
- `math.floor`, `ceil`, `trunc`, and `round`, in both widths, have
  compile-time values, and are SSE4.1's rounding instruction from
  `x86-64-v2` rather than a call to the C library, with the same exact
  results.
- `math.mod` and `math.mod_f32` have compile-time values, so
  `PHASE :: math.mod(7.5, 2.0)` is a constant; at run time they are still
  the C library's `fmod`, which is exact.
- Every Clang command now passes the CPU level's `-march` and
  `-ffp-contract=off`, the runtime's C sources included, whose default let
  Clang fuse `a*b + c` once a level has FMA. `-print-toolchain` prints both
  flags, for a C host compiling the runtime itself.
- An optimized build links the runtime as LLVM bitcode, optimized together
  with the program, when `lld-link.exe` is installed beside Clang, as the LLVM
  installer puts it; `-print-toolchain` reports this as `lto=yes`. The
  benchmarks run 2 to 9 percent faster and their executables are 5 to 30
  percent smaller, for 6 to 12 percent longer optimized builds (a third
  longer for the smallest). `-opt=none` builds, `-runtime=<dir>` builds, and
  machines without lld-link link machine code as before
  ([Common options](compiler-guide.md#common-options)).
- Under `-panic=unwind`, a procedure publishes to its unwind frame only the
  locals its cleanups read, and a procedure that registers no cleanup keeps
  no frame, live flags, or env at all. The other locals' addresses no longer
  reach the runtime, so the optimizer keeps them in registers:
  `bench/dense.loke` runs 14 percent faster, most of the difference
  `-panic=abort` makes.
- The runtime entries that end the program are declared `cold noreturn`, in
  the generated module and in `runtime/loke_rt.h` (`LOKE_RT_FAILURE`), and the
  branch to a checked operation's panic carries weights saying it is not
  taken. This states what LLVM inferred; no benchmark changed measurably.
- A procedure that registers no cleanup no longer calls the runtime to pop an
  unwind frame it never pushed each time it returns. The call survived
  optimization and inlining, so every such procedure paid for it; a small
  floating-point kernel ran about a third faster without it.
- `lokec` checks and emits about a fifth faster, with the same output: the
  front end takes 14 to 33 percent less time on the examples and benchmarks,
  and `loke-lsp` answers an edit about a sixth sooner. Ownership analysis
  keeps its scratch memory between procedures instead of returning it to the
  system, and creates its tables only when it fills them; the borrow solver
  visits only the loans an event releases; the lexer matches an operator by
  its first byte.
- A release's `lokec.exe` and `loke-lsp.exe` are built with Odin's `-o:speed`,
  which makes the compiler two to three times faster still; `test-all.ps1
  -Full`, the gate CI runs, tests that build. The quick gate and
  [Building from source](readme.md#building-from-source) keep the default,
  which builds in about a second rather than a minute.
- The test harness ends a launch still running after five minutes, with every
  process it started, and fails its case, so a stalled program no longer
  hangs `test-all.ps1` until CI's job limit
  ([Testing and verification](compiler-architecture.md#testing-and-verification)).
  The processes `lokec` and the harness start, clang and test executables
  among them, now inherit only their standard handles, so one child no
  longer keeps another's output open.

- A value whose bits are not a representation of its type, a `bool` other
  than 0 or 1, an enum value naming no member, a null `^T`, or a union tag out
  of range, and a read of storage that holds no value, such as an unwritten
  part of `x: T = ---`, are now specified as undefined behavior by every
  unchecked route, and the specification lists which types have such patterns
  and which do not. Every 32-bit pattern is a `rune`, so a compile-time
  `unsafe.transmute(rune, ...)` of a surrogate or out-of-range code point now
  folds instead of being rejected. Every pattern is also a `typeid`: an id no
  type has compares unequal to every real one, prints as its number, and
  answers the `Invalid` entry from `type_info_of`, while an `any_view` whose
  id names no type is invalid
  ([Invalid representations](design.md#invalid-representations)).
- `L0399` for a dependency name that two manifests require as different
  directories now says that a `-collection` for the name chooses one directory
  for the whole program, which is how a shared dependency is vendored
  ([Projects](compiler-guide.md#projects)).
- A borrow of a place reached through a pointer, as `&mut h^.count` or
  `h^.items[:]`, now reborrows the pointer for that place only, so another
  field stays usable while the borrow is in use: `h^.total += 1` beside
  `count := &mut h^.count` now compiles, as it does for a local. So does a
  field reached through a pointer to that pointer, as `p^^.total` beside
  `&p^^.count`, and another field inside a `foreach` over a field reached
  through a pointer, as `h^.count = item` in `foreach (item in h^.items)`.
  Copying the pointer, or passing it to a procedure, still conflicts with the
  borrow ([Weakening and reborrows](design.md#weakening-and-reborrows)).

- `fs.read_directory` now documents its contract: entries come in the
  filesystem's own, unspecified order, `.` and `..` are never yielded, and a
  directory changed during the walk is not snapshotted, so an entry added,
  removed, or renamed meanwhile may be yielded, missed, or yielded under both
  names, without failing the walk
  ([Filesystem operations](standard-library.md#filesystem-operations)).
- `core:fs` now documents how a link behaves until symbolic links are
  supported: `metadata` and a directory entry classify a junction or a
  directory link as a `Directory` and a file link as a `File`, and
  `Kind.Other` is reserved. Opening, reading, writing, and enumerating go
  through the link to its target, while `remove`, `remove_directory`,
  `rename`, and `replace_atomic` act on the link itself and leave the target
  as it was
  ([Filesystem operations](standard-library.md#filesystem-operations)).
- `fs.rename` now returns only once the rename is durable, and
  `fs.File.flush` is documented as making written data durable, which it
  already did.

- `core:math` now documents that its transcendental functions (`pow`, `exp`,
  `log`, `log2`, `log10`, `hypot`, the trigonometric functions, and their
  `_f32` twins) are not deterministic: one executable can give different last
  bits on another machine, because the C library picks its algorithm by the
  processor's features, and an optimized build can fold a constant call with
  the compiling machine's library. Avoid them where results must agree bit for
  bit, as in lockstep simulation
  ([`core:math`](standard-library.md#coremath)).
- Compile-time evaluation reuses the storage it releases, which no longer counts
  against its 64 MB limit (`L0342`)
  ([Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)).
  A `core:math/repro` call that takes its slow path now uses 1.2 to 5.6 MB
  rather than 4.7 to 24 MB, so one constant can fold eight or more such calls,
  and a compile-time `math.fma` uses about a third of what it did.

### Fixed

- A body's analysis no longer grows with blocks times slots times loans: a block keeps what changed
  in pages it shares with its neighbors, and each row of loans once. So 2000 branches that each borrow,
  which took a minute and ran out of memory at three times that, take under a second, and a chain of
  4000 reborrows went from 28 s to under a second.
- A protocol `next` that hands back its element runs no copy of it, so a `foreach` over one, or its
  `copied()`, no longer counts the element's `hook(copy)` reads ([Global write effects](design.md#global-write-effects)).
- A load through a pointer to a field leaves the other fields alone
  ([Places and overlap](design.md#places-and-overlap)), so `y := &mut h^.d; y^.clear();` no longer
  conflicts with itself, and a store to `r^.a` no longer conflicts with a read through `&mut r^.b`.
- A generic instance's name stops at the same limit as any other
  ([Printed forms](standard-library.md#printed-forms)), where one deep enough printed tens of KB.
- `L0740` asks a generic parameter's type with the arguments before it bound, so a private type passed
  to `$V: identity_type(T)` where `T` is `type` is reported
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- A conversion uses no allocator, so tasks that each call `receive` on a `core:thread` channel no longer
  report `L0732` ([Allocators and tasks](design.md#allocators-and-tasks)).
- An `impl` subject may compute with an operator a later block declares, which was `L0318` then `L0406`
  ([Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution)).
- A pointer a call read out of a parameter reaches only the field the call read, and each field of a
  returned record only what that field was given, where both reached the siblings' targets too. So a
  reset that spares the other field no longer reports `L0537`
  ([Procedure result contracts](design.md#procedure-result-contracts)).
- `delegate` no longer depends on which signature comes first when a signature's constant needs an
  operator, which was `L0420` naming an operator that was declared
  ([Delegating operators](design.md#delegating-operators)). A constant may also call a procedure
  group declared after it, which was the "compiler defect" `L0350`
  ([Explicit procedure overloading](design.md#explicit-procedure-overloading)).
- `L0740` reads a generic type's value argument as a value and a group's members in the group's own
  block, so `Vec(size_of(Priv))` no longer warns and a private type in `Box(int)`'s group member is
  reported whatever another block of `Box` declares
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- A program can export any name outside the reserved prefix, as the names the compiler generates all
  step aside for it ([`@(export)`](design.md#export)), where some of them failed in clang with
  `L0403`.
- A misplaced token is one report: the parser no longer takes an `impl` block for a procedure's body,
  so `impl proc() { }` is the block on a procedure type [the grammar](grammar.md#source-files)
  says it is, and a `return` value it could not read is not reported again.
- A type's name stops at `...` past about 4 KB ([Printed forms](standard-library.md#printed-forms)),
  so a chain of aliases each naming the last twice compiles and prints at any depth, where a value of
  one forty deep never finished.
- A generic union whose `@(zero=)` payload has no zero is `L0423` when an instance's body names it,
  which went unreported ([Zero values and `@(zero=)`](design.md#zero-values-and-zero)). A public type
  with a private `format` prints by the generated form, which only reads, so printing one twice no
  longer reports `L0641`.
- What a procedure draws from a provider it reaches through a parameter is in the argument's region
  ([Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)),
  where it was in an unknown one, so another region ending no longer counts against it, and declaring
  an arena beside the result compiles.
- `impl R(int, 0)` over `R :: struct($T: type, $V: T)` compiles, where a constant argument whose type
  an earlier argument decides was the "compiler defect" `L0350`
  ([Generics](design.md#generics)). So does a distinct slice or pointer printed twice, when the
  compiler generates its `format`.
- An array type whose length names a constant that failed reports only that constant, not also
  `L0350`.
- `L0537` names the local whose cleanup ends a region, rather than calling its declaration a reset,
  and says "may" where the region limit is why
  ([Minimum provenance precision](design.md#minimum-provenance-precision)).
- `L0412` asks for `value.clone()` or `value.try_clone()`, which exist, rather than `clone(value)`.
- A `delegate` no longer fails with `L0420` when the operator it forwards is declared later in the
  package, when the underlying type's own `delegate` is, or when a constant a signature needs uses
  the operator ahead of the block ([Delegating operators](design.md#delegating-operators)).
- A local declared in a deferred block is dropped when a panic is the only exit that runs the block
  ([What the unwind runs, and what it does not](design.md#what-the-unwind-runs-and-what-it-does-not));
  with no normal exit it leaked and its `hook(drop)` never ran.
- A `switch` takes one view of its subject rather than one per case. A case binding nothing takes
  none, so an enum `switch` of 6000 `return` cases compiles in under a second where it crashed the
  compiler, and a union `switch` binding a payload in each of 3000 cases takes under a second rather
  than more than a minute.
- A body too large to analyze stops with `error: out of memory` rather than an internal index error
  ([known gap](known-gaps.md#a-body-of-thousands-of-borrows-is-slow-then-runs-out-of-memory)).
- A chain of procedure or map aliases that each name the previous one more than once compiles in time
  linear in its depth; every question about what a type holds took time exponential in it, at 5 to 6
  s for 20 aliases and without end for 48. The printed name of such a type is still exponential in
  its depth ([known-gaps.md](known-gaps.md#a-types-printed-name-doubles-with-each-alias-naming-the-previous-one-twice)).
- A map named as a generic record's argument is checked where it is named, whether or not a field
  holds it ([Maps](design.md#maps)). `Shared(map[f64]int)` reported `L0586` inside
  `base/runtime/shared.loke`, with an `L0308` there as well; now it reports `L0586` at the argument.
- `L0740` reads what a `where` clause holds as values: a literal's index, as `IDX` in
  `[2]int{IDX = 1}`, and a parameter's default in a procedure type
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- `-api` and `-doc` show a private type a generic procedure's result names when a plain parameter has
  the same name, as in `proc(T: int, v: $U) -> T`. A plain parameter's name is in no type's scope, but
  the listing took it for that parameter and left the declaration out.
- A `switch` case binding that spells a literal, as in `case .a(true):`, no longer binds the name after
  its `L0700` ([Predeclared names](design.md#predeclared-names)). `true` in the case body stays the
  literal, where it read the payload and reported a false mismatch.
- A pointer from a user `operator([])` is treated as the call's result it is, and no longer as pointing
  wherever the receiver's carriers do. A store through one, where the operator returned another
  argument, was blamed on the receiver's target, so a reset with that target live was rejected (L0537).
- A bad `-define` no longer hides a bad `-collection`: both are reported in one run.
- A field's name used as a key of a record literal no longer counts as a mention of what that name
  declares. `Vec :: [size_of(Cfg{Vec = 2})]$T` was rejected as defined in terms of itself (L0745), and an
  interface `slot` with such a key named after its subject as not dyn-compatible (L0463).
- A constant `/` or `%` no longer folds to a wrong value when the divisor passes about 10,000 bits
  and the dividend is half as long again, as in `((1 << 40000) + 1) / ((1 << 13000) + 7)`.
- Compile-time evaluation no longer stays charged, against its memory limit, for what a float-to-integer
  conversion or a float literal's rounding built along the way, or for a second copy of a typed
  integer result already in range.
- A foreign global whose type does not resolve, such as `foreign lib { x: Nope; }` or a generic
  `x: G;`, reports it as `L0306` or `L0431` at the type. It stopped the build with an internal `L0405`
  naming `<invalid>` and no location.
- A foreign binding of an exported procedure that returns a record or a pointer no longer gets a false
  `L0600`: `@(link_name="z") f :: proc(a: i32) -> P ---;` and `@(export, link_name="z") g :: proc "c"
  (a: i32) -> P {...}` are one type ([`@(export)`](design.md#export)).
- A bad `@(default_calling_convention)` is reported once, at the attribute, not at each procedure that
  inherits it.
- A foreign member that is neither a `---` procedure nor a variable, such as `X :: 1;` or a record, has
  an `L0625` that says what a foreign block declares, not that a global has no initializer. A broken
  `x := ---;` reports only the parser's `L0235`.
- The language server resolves a name in three more places: an operand of an assignment through
  `operator([]=)`, such as `val` in `box[key] += val`; a member of a group under `operator`, as in
  `operator(<) proc { reversed }`; and an `else when` condition in a procedure. Hover and definition
  found nothing there, references left the use out, and rename refused.
- `box(nil)`, `try_box(nil)`, `unsafe.new(nil)` and `unsafe.try_new(nil)` are `L0310`, as `x := nil` is,
  and `b: Box(^int) = box(nil)` says `nil` is not a value of `^int`. Each crashed the compiler with no
  diagnostic.
- An untyped payload takes the payload type the context expects, as an initialization does
  ([Owned values](design.md#owned-values)): `b: Box(u8) = box(1)`, `Box(f32) = box(1.5)` and
  `Box(string_view) = box("abc")` compile. They were `L0310`.
- `try_box`, `unsafe.new` and `unsafe.try_new` take an expected payload type from an expected
  `Result(Box(T), Allocator_Error)`, `[^]T` or `Result([^]T, Allocator_Error)`, as `box` does from
  `Box(T)`. `r: Result(Box(N), Allocator_Error) = try_box({1, 2})` was `L0376`.
- A diagnostic on `unsafe.new` or `unsafe.try_new` names the call rather than a box: `` `new` takes a
  runtime value `` and "this unsafe allocation cannot copy it".
- [`@(export)`](design.md#export) on a procedure in a file-scope `impl` block now emits the symbol
  under its own name or `@(link_name)`. It was emitted internally, so a C host failed at link.
- `string.from_utf8`, `string_view.from_utf8`, `cstring_view.from_bytes` and `string.from_runes` take
  a fixed or dynamic array of their element type, as a read-only `[]T` parameter does
  ([Implicit type conversions](design.md#implicit-type-conversions)). `string.from_utf8(bytes)` over a
  `[3]u8` was `L0561`.
- `unsafe.string_view(pointer, length)` with a length wider than 64 bits that does not fit panics
  ([string type conversions](design.md#string-type-conversions)). It truncated, so an `i128` of `-2^64`
  gave an empty view.
- `unsafe.string_view(pointer, 1.5)` reports the length once, where it reported `L0353` and `L0569`.
- An operator overload taking a vector is now found where no built-in lane-wise operation exists
  ([Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution)):
  `m * v`, `v + m`, `a + b` on two vector types, and `%` on float lanes were `L0686` with a matching
  overload, though `v += m` found it.
- `y: Simd(f32, $M)` where `$M` is not bound is now `L0437` naming `$M`, and an invalid `Simd(...)`
  inside `Box(...)` or a composite literal no longer also says ``unknown type `Simd` ``.
- `v <<= -1` on an unsigned vector reports `L0352` once, as `v << -1` does, and not `L0356` as well.
- A negative `Simd` lane count now says that it is negative, and a zero one that a lane count is a
  power of two from 1.
- A static `foreach` takes any compile-time slice, as
  [Static `foreach` expansion](design.md#static-foreach-expansion) says: `K :: ARR[:]`,
  `K :: []int{1, 2}` and a `[]int{1, 2}` literal were `L0454` unless written `ARR[:]` in the header.
- A note in a static expansion shows every element
  ([Static `foreach` expansion](design.md#static-foreach-expansion)). `fields_of(T).indexed()` and a
  record said `<value>`, an enum member its number, and a rune its code point; they now say `name`,
  `Point{1, "p"}`, `Red` and `'a'`. A string is quoted, and a rune in a generic instance's name
  prints as one.
- `open(..a).handle(..b)` compiles ([Union argument expansion](design.md#union-argument-expansion)):
  a spread in the callee's receiver reported `L0305` for `dispatch$payload`, a name the program
  never wrote.
- A diagnostic in binding an expanded case's copy names its variant, as one in its body does
  ([Per-variant switch cases](design.md#per-variant-switch-cases)).
- A generic type's `format` whose `where` bound fails leaves that instance the generated form
  ([Printed forms](standard-library.md#printed-forms)). `fmt.println(G(int){1})` was `L0444` when
  `format` required `T == string`.
- A report (`assert`, `panic`) counts only a `format` its printed form calls
  ([Global write effects](design.md#global-write-effects)). A `distinct` type's wrapped `format`, a
  private field's, and a `dyn` view with no `format` slot were a false `L0512` when that `format`
  wrote what the report held.
- A `distinct` type that declares neither `==` nor `hash`, over a type that declares both, can be a
  map key, satisfies `interfaces.Hashable`, and has that `hash` as a member
  ([Maps](design.md#maps)). `map[D]int` was `L0586`, though `D` already compared by that `==` and a
  record holding a `D` keyed a map by that pair.
- The same error reported several times from one position, as each instance of a generic procedure
  does, now prints once with each instance as a note, also when another error at that position fell
  between the repeats. Errors at one position now print narrowest first.
- A diagnostic's caret line counts characters, so a mark after or across non-ASCII text in a string
  or comment stands under what it marks.
- A member whose `where` bound fails is out of the instantiation on more paths
  ([where clauses](design.md#where-clauses)). A conversion hook no longer stops the compiler with
  `L0405` or joins an `L0391` ambiguity; a procedure group on a generic extension can name one where
  it was `L0395`; `x.f()` on an extension's explains why with the note an inherent block's has; and
  a method or interface slot supplied by two crossed generic blocks no longer counts it.
- A conversion hook of a name two crossed generic blocks both supply is found
  ([Conversion hooks](design.md#conversion-hooks)). `G(int, int)(3)` was `L0373`.
- A body-local `format` or `hash` after a use that generated one now says so: `L0409` reads "already
  has a generated member", with a note to write the block before that use.
- `L0740` reads more of what a public declaration writes
  ([Private names in public declarations](design.md#private-names-in-public-declarations)). It now
  warns about a private name that a block's `$` name had hidden from every later declaration; a
  procedure constant's written type; the application of a parametric alias in a generic `impl`; a
  field written after `_`, as in `_, a: Fill`; a private type nested deeper than eight levels in a
  constant's type; and a private group member in a block whose package declares the same name
  publicly. It reports `impl ^Name`'s members under `Name` and no longer warns about them when
  `Name` is a private type, and names any other subject as written, as `[]Point.spread`.
- `L0740` no longer warns about a type named in an array length, as `[size_of(Hidden)]int`, or `_`
  padding as a field, and a selection such as `Box(int).Inner` now reads `impl Box(int)`'s member
  when `impl Box(string)` declares one of the same name.
- `-api` now shows a struct field written after `_`, as in `_, a: int`.
- A `typeid` no longer depends on the order types were declared or requested in when two types differ
  only in a procedure type's `@(escape=...)` or `@(cross_thread)`, in the package a `Range(T)` or
  iterator's `T` comes from, in which procedure or expansion declares a local generic or a local type,
  in where an in-place `distinct` is written, in a `typeid_of` inside a value argument, or in which
  package an iteration adapter was made for.
- `typeid_of(Nope)`, `fields_of(Nope)`, `enum_values_of(Nope)` and `variants_of(Nope)` report an
  unknown name once, not again as `L0451` "needs a type", and `type_of([]Nope)` reports it once.
- A file-scope `when` condition now waits for what it reaches, not only for the names it writes
  ([when statement](design.md#when-statement)). `N :: size_of(Handle); when (N == 8)` with `Handle`
  from another `when` compiles, where it was `L0315`, and a record's field type, a procedure's
  signature or body, and a procedure literal in the condition behave the same.
- `-api` and `-doc` show an `impl` block written through a private alias of a public type, whose
  members importers can call, with the alias marked private
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- `-api` no longer fails with `L0405`, and `-doc` no longer prints a cut head, for a struct whose
  `where` clause holds a brace.
- An interface file writes the import that only an attribute's value qualifies a name with, and no
  import for a member spelled like one, as `Wrapper{}.sub.n`. It shows a private constant that an
  array literal's key names, and a field's attributes without `public` or `private` wherever they
  are written ([Interface files](compiler-guide.md#interface-files)).
- `L0260` no longer warns about a doc comment on a field or variant of a type written under a
  pointer, array, slice, map, procedure signature or type application
  ([Doc comments](design.md#doc-comments)).
- The editor's documentation command shows a package's interface for a file of that directory the
  check did not load, rather than the root package's.
- `-check-layout` no longer overwrites and deletes the `-o` output: its probe is a temporary named
  `<name>.layout.exe`. A bare output name, which every build without `-o` has, no longer fails it
  with `L0405`, and `-g` no longer writes a PDB for the probe.
- `-check-layout` also compares `string`, `string_view`, `cstring_view`, `[^]T`, `typeid`, `Simd` and
  `dyn` values with LLVM's layout, as it says it does for every type.
- `lokec x.loke -g -emit-ll` no longer leaves `x.natvis` behind, and `-g` links an output whose path
  holds a comma, which failed with `L0403`.
- `foreign import k "system:kernel32.LIB"` links `kernel32`: the `.lib` and `.a` suffixes are
  recognized in any case, and `-lkernel32.LIB` failed the link.
- The cached runtime objects now follow the value of `INCLUDE` and the upgrade of a clang found on
  `PATH`, either of which reused the old objects. A link that loses the race to install a set no
  longer waits two seconds, and neither does one that finds a damaged set in place.
- `spawn read(make().items);`, `spawn show(make_list()[0]);` and `spawn make().part.read();` no
  longer give the task storage the parent drops as the statement ends: the task gets its own copy
  of the field or element ([Spawn statements](design.md#spawn-statements)). It could read freed
  memory, an empty string, or a value after its `hook(drop)` ran.
- A widened place as a `spawn` argument, as in `foreach (i in 0..<n) { spawn show(items[i]); }` with
  a smaller union's elements, now reaches its own task. Every task read the one temporary the
  widening shared, so all saw the loop's last element.
- A warning from a `parallel` block's executor expression no longer gets the note about the
  executor's type.
- A `spawn` under a replaced `core:thread` with no `Task_Scope.start`, or that does not load
  `core:unsafe`, is now `L0727` where it was an internal backend error `L0405`.
- A map's `clear`, and a sequence's `clear` and `resize`, no longer count as using an unknown
  allocator region for a `hook(drop)` of what they discard. Two tasks each clearing a map of their
  own were `L0732` ([Allocators and tasks](design.md#allocators-and-tasks)).
- A union aligned past 16 bytes, such as one holding a `Simd(f32, 8)`, now has the layout the
  checker reports. LLVM aligned its storage to 16, so `size_of` and `align_of` disagreed with the
  code, and copying an array of records holding one overran its storage and crashed.
- A constant of an all-payloadless union with a written alignment above its tag's, such as
  `@(align=8) U :: union { a:, b: }`, now compiles; clang rejected the initializer.
- A foreign binding of any name the runtime or the generated module declares or defines, such as
  `loke_rt_v1_frame_pop`, now refers to that one; only a few such names did, and the others
  failed with `L0403`, clang's "invalid redefinition of function".
- An owned `foreach` leaf can be moved beside lent and `&mut` ones, as
  [Element bindings](design.md#element-bindings) says: `move(i)` of an `indexed()` counter and
  `foreach (&mut a, s in t) { take(move(s)); }` with `s` owned by `next` were `L0690`.
- `reversed()` over a map or text runs the `iter_reverse` the program supplies
  ([Iteration adapters](design.md#iteration-adapters)); it was `L0460`.
- An `&mut` leaf after a `_` padding field of a record `Item` takes that field's mode, not the
  padding's; it was `L0457` ([Destructuring](design.md#destructuring)).
- `foreach (a, b in ints)` reports that `int` is not a record, not that it has 0 fields and needs
  "1 or 0 parts" (`L0459`).
- `delegate` now covers what [Delegating operators](design.md#delegating-operators) says it does:
  `+` on a distinct `string` or `string_view`, which failed in clang with `L0403`; `<<` and `>>`, which
  were `L0420`; the operators of a distinct `Simd`, also `L0420`; an overload with the underlying type
  in any operand position, such as `f64 * V` or `operator(in)`; a generic overload; the built-in
  operation beside a user overload that mentions the type; and an overload's parameter defaults.
- A generic `operator([])`, `operator([]=)` or `operator([:])` declared outside an `impl` block is
  found ([Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution)),
  where `a[0]` was `L0362`.
- A user unary `-` or `~` no longer shadows the built-in one on a `Simd` type
  ([Operator lookup and overload resolution](design.md#operator-lookup-and-overload-resolution)), as a
  binary overload already did not.
- A `caller_location()` default on an operator reports the expression that used it, not the
  declaration ([`caller_location()`](design.md#caller_location)).
- `@(deprecated)` and `@(require_results)` take effect on an operator declaration, and a deprecated
  operator warns where an expression uses it as well as where it is called by name.
- An operator taking `self: ^` accepts a pointer operand, as its named call does; `p + v` was `L0310`.
- Comparing a type whose inherent `==` is in a group that is not `@(public)` gets the same message as
  one with a single overload (`L0355`).
- An operator with a `$` parameter is `L0416` where it is declared
  ([Operator declarations](design.md#operator-declarations)). Using one crashed the compiler.
- `foreach` over a temporary whose `iter` takes a plain `self` now drops the temporary when the
  statement ends, as `make_source().iter()` already did; it was never dropped
  ([Temporaries and procedure boundaries](design.md#temporaries-and-procedure-boundaries)).
- `foreach` over a string, map, dynamic array or fixed array in a packed struct now reads it
  with `align 1`; it claimed natural alignment, which is undefined behavior in the generated code
  ([`@(packed)`](design.md#packed)).
- A `^mut T` works as a `map[^T]V` key. `p in m`, `m[p]`, `m[p] = v` and `map[^T]V{ p = v }` compiled
  it as a `string_view` and failed in clang with `L0403`.
- A map literal keeps one set of slots for all its entries, so a 300-entry `map[int]L` with a 5 KB `L`,
  or a 30000-entry `map[string]string`, no longer overflows the stack at `-opt=none`.
- A deferred assignment on a panic's unwind now drops the value it replaces where that value is
  live, reads whether it is, and leaves the new value to be dropped
  ([Assignment statements](design.md#assignment-statements)). The old value could leak, a hook
  could run on a value already dropped, and the replacement could leak.
- `-copy-cost` no longer warns of a copy of a move-only type, beside the error that it cannot be
  copied, or by size of a `string` or `Shared(T)`, whose copy only retains
  ([Copy-cost diagnostics](design.md#copy-cost-diagnostics)).
- A procedure type's printed form names `..` and `@(by_ptr)`, so assigning a C-variadic or
  by-pointer foreign procedure to a plain type no longer reports two identical types (`L0310`).
- `type_info_of(typeid_of([^]T)).bits` is the pointer width whichever use interned `[^]T`
  first; it was 0 when the type was first written out.
- An application whose composition has arguments that do not resolve is false, as
  [Interface bodies](design.md#interface-bodies) says: `Inner(T, T.N)` in `Outer(T)` made
  `static_assert(!Outer(int))` an `L0408`, and `Callable(C, proc(n: C.Arg) -> int)` an `L0306`.
- An interface that composes itself is false however it does so. Looking up an associated constant
  or a slot through one overflowed the compiler's stack, and `Bad(T) || Bad(T)`, or a composition
  repeated at each level, ran for hours.
- A bare bound grants what its composition requires when the interface names what it composes by a
  name only it can see, when a composed `Callable` has another subject, as in
  `Callable(T.Fn, sig)`, and when that `Callable`'s signature names an associated constant.
- An export whose link name starts with `loke.` stays external, and a procedure or global the
  compiler would give that same name takes another, so `@(export, link_name = "loke.host_api")`
  links and `"loke.p.helper"` beside `helper :: proc()` compiles
  ([`@(export)`](design.md#export)).
- Exporting `wmain` from an executable or a test build is now `L0635` rather than clang's
  redefinition error, and a foreign binding of `wmain` there refers to the entry
  ([`@(export)`](design.md#export)).
- A debugger shows an instance's argument as written, `wrap.[]int` rather than `wrap.$5b$5dint`.
- `if (case 1 = x) y;` and its `for` form report the missing `{` (`L0213`) rather than ending the
  compiler with no diagnostic.
- A variable declaration in a control-flow header takes attributes, as
  [grammar.md](grammar.md#statements) has it: `if (@(tag) y := 1; y > 0) { }` was a cascade of errors.
- One malformed construct is one diagnostic in `for ()`, `return );`, `S :: struct(1) { }`,
  `x := (1 2);`, `move(1 2)` and `if (x := 1) { }`. A header's declaration that fails stops at the
  header's `)`, so `for (x: ) { a(); } b();` keeps its body and what follows it, and deeply nested
  blocks report the depth limit alone rather than hundreds of stray `}`.
- A foreign import's path is decoded as an import's is, so `"sys\x74em:kernel32.lib"` names a system
  library rather than a file with a backslash in its name.
- An array length holding composite-literal arguments, `[g([g([1]int{})]int{})]int{}`, parses once
  per level; each level used to double the time, so 22 of them in 250 bytes took 18 seconds.
- A procedure literal inside a result type's array length or generic arguments has its body:
  `f :: proc() -> [g(proc() -> int { return 2; })]int { ... }` was `L0253`.
- A procedure body or group where only a type is grammatical, as in `x: proc { a };` and
  `struct { a: proc() { } }`, is `L0210`, not `L0350` calling it a compiler defect.
- A record type field's `=`, `inout`, `move` and `..` errors no longer advise declaring a `struct`,
  whose fields have none of them either.
- A store's receiver is a place, so `m["a"][1] = 5` and `o[0][1] = 5` with an `inout` `operator([])`
  compile when the element has an `operator([]=)`, as their `+=` forms did
  ([Indexing and slicing](design.md#indexing-and-slicing)).
- A receiver is checked once per check of its call. A procedure literal or a `dyn proc` argument in
  a receiver no longer fails in clang, in `h[f(proc() -> int {...})][0] = 5` and its `+=` and multiple
  assignment forms, and in `f(proc() -> int {...}).unbox()`, `.copy()` and `mk(g).foo()`. A chain of
  calls to methods named like a text operation no longer doubles its checking time per link.
- `s.byte_len()` finds a file-scope `s` declared after the procedure that calls it, as `s.len()` did.
- A default sees a `self` written in its own group: `proc(self, x: int = self.n)` and
  `proc(self, x := self.n)` ([Default values](design.md#default-values)).
- `b[0] += n` through `operator([]=)` reads a scalar variable `n` before `operator([])` runs
  ([Evaluation order](design.md#evaluation-order)).
- A constant keeps its destination's type in a multiple assignment with a setter however it is
  spelled, so `small[0], x = math.PI, 2` and `Small.N` compile. A setter's value and indices take
  their parameter's type as context, so `paint[0] = .Blue` compiles.
- `g[0], y = record` works when `g` has only an `operator([]=)`
  ([Destructuring](design.md#destructuring)).
- A file-scope `source_location()` reports no procedure, whichever body reaches it first.
- `@(escape=...)` on a procedure type's parameter in a generic record is exempt in a binding with no
  borrow, as it is on a method's: `Foo(int)` for `cb: proc(@(escape=none) x: T)` no longer reports
  `L0648`.
- `defer r := must();` reports a required result it never reads (`L0698`).
- A repeated constant `case` of a struct type is `L0367`.
- These report what is wrong rather than `L0350` "compiler defect" or a backend error: a type
  containing itself declared in a body (`L0364`), `[?]T` outside a composite literal (`L0384`), an
  unbound `[$N]T` (`L0437`), and `x: fmt.Nope(int)` (`L0306`). A failed component of an anonymous
  record reports once.
- One mistake reports once: `@(align=n)` with a variable `n` is `L0341` alone, and `a, b := bad_name`
  is `L0315` alone. A compound assignment whose operator does not apply is `L0318` whatever the right
  side is, where a mismatched one was `L0310`.
- A declared `Simd`, unsuitable as a type, is `L0306` rather than a request for the predeclared
  constructor's arguments, and `$n := 5` says that a `$` parameter writes its type.
- `&mut p^.items[:]` passed where a `[]T` is wanted now suspends nothing through the carrier, as
  on a local and as `&mut p^.items` does; it was a false `L0641`
  ([Weakening and reborrows](design.md#weakening-and-reborrows)). A conflict on such a slice is
  also reported once, naming the carrier.
- An `f16` prints its own shortest spelling, as `f32` and `f64` do: `f16(0.1)` prints `0.1`
  rather than `0.099975586` ([Printed forms](standard-library.md#printed-forms)).
- An enum value no member names, reached through `unsafe.transmute`, prints as its number at the
  enum's own width and signedness: an `enum u64` holding all ones prints `18446744073709551615`
  rather than `-1`, and an `enum i128` no longer prints only its low word
  ([Printed forms](standard-library.md#printed-forms)).
- Compile-time evaluation matches a run in more places
  ([Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)).
  `xs.append(..view)` added nothing, so a `static_assert` could pass on the wrong length, and
  `xs.append(1, ..view)` was `L0341`. A zero `string_view` compared unequal to `""`. A single name
  over a lent `indexed()` reported a nil pointer at `r.value^`, and `&mut` over a slice expression,
  as in `(&mut arr[:]).indexed()`, and a write through one, as in `(&mut arr[:])[0] = 1`, were
  `L0341`. A local type, or `_: int;`, gave only `L0311`. A non-scalar `assert` argument reported
  `L0341` in place of the assertion, reading a box emptied by `unsafe.take` gave only `L0311`, and
  the seed of `hash` ran after its receiver's `or_return` had left.
- Compile-time evaluation stopped at the memory limit after about 1000 appends, 800 map inserts, or
  800 reads of an 800-element constant table. A growing container no longer copies its contents at
  each insertion, and a read makes only the element it selects, so the step limit now comes first.
- A procedure with many spawn sites keeps a window for each. Past 64 in one body, the last
  site's window never closed, so a write after its join was a false `L0731`
  ([Globals while tasks run](design.md#globals-while-tasks-run)).
- `@(escape=...)` on a parameter whose record names itself now asks whether the record carries
  a borrow once its fields are known, so a record whose carrier field comes after the procedure
  field is no longer a false `L0648` ([`@(escape=<level>)`](design.md#escapelevel)).
- Storing an allocator handle in a field and then storing another over it no longer changes the
  first handle's own region, which was a false `L0538` when the second came from a parameter
  ([Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)).
- `L0731` and `L0641` say "may" and name the limit when an array's merged elements caused them,
  and an allocator parameter past the 64th now names that limit on its `L0538`
  ([Minimum provenance precision](design.md#minimum-provenance-precision)).
- Borrow checking no longer takes minutes on a recursive union with many alternatives, or a
  body with a thousand loans of one place, and a body's memory no longer grows with the square of
  its locals.
- A panic while a record's `hook(drop)` empties an `@(initialized)` field drops what the count still
  names ([Uninitialized capacity](design.md#uninitialized-capacity)). The unwind used the count from
  before the hook, so it dropped the elements the hook had already taken a second time.
- A panic from one element's drop, when an `or_return` leaves a variadic call's operands, leaves the
  other staged elements to the unwind. They used to leak.
- The generated copy of a fixed array of owning elements is one loop. It emitted each element's code
  separately, so copying a `[20000]Value` of owning fields wrote a `.ll` of about 60 MB.
- A union's zero value is its designated variant with a zero payload at compile time too
  ([Zero values and `@(zero=)`](design.md#zero-values-and-zero)). `R{} == R{m = .none}` folded to
  `false`, `Option(int){} == .none` failed with `L0341` in compile-time code, `case .a(p)` on a zero
  `U` bound a `p` with no value, a compile-time `.hash` of one differed from the run-time hash, and a
  zero union whose payload has a `hook(drop)` or `hook(copy)` escaped the `L0341` every other such
  value gets.
- A constant `==` or `!=` on records with an `@(initialized)` count outside `0 ..= N` is `L0343`, as
  [Uninitialized capacity](design.md#uninitialized-capacity) has equality panic, whichever operand
  holds that count. It folded to unequal, and an evaluated comparison looked only at the smaller count.
- A valid map named only inside a `Box`, as in `x: Option(Box(map[u16]int)) = .none;`, compiles. It
  used to fail with internal `L0405`, "a map key operation was not resolved during checking".
- `pointer[0:length]` on a C pointer panics for a negative `length`, as
  [string type conversions](design.md#string-type-conversions) says. The slice used to come out with
  that length, so its later bounds checks passed and an index read out of bounds.
- `unsafe.raw_data` of a temporary `[dynamic]T` drops the array when the full expression ends, as the
  same call on a `string` does, rather than leaking it and never running its elements' `hook(drop)`.
- A global larger than 4096 bytes passed by pointer, as `g.peek()` with `self: ^` or `set(inout g)`,
  compiles. It used to fail in clang with `L0403`.
- A variadic pack with a spread among other operands, as `sum(1, ..big[:])`, panics with
  "variadic argument pack is too large" past 256 KiB
  ([Variadic parameters](design.md#variadic-parameters)). It used to overflow the stack and lose
  buffered output.
- A default argument can select from a parameter to its left, as `x: int = a.n`, whichever way that
  parameter passes. It used to fail in clang with `L0403`, or read the enclosing call's `a` in a
  recursive procedure.
- `math.count_ones(nil)`, the other bit counts and values, `math.rotate_left(nil, 1)`,
  `math.wrap(T, nil)`, and `unsafe.transmute(T, nil)` report `L0310`. They used to crash the compiler
  with no diagnostic.
- `try_make([dynamic]u8, allocator=my_allocator)`, as [Owners and drop](design.md#owners-and-drop)
  writes it, compiles: `make` and `try_make` take their allocator by name, and no other argument.
- `source_location(greet).procedure` is `greet`, and a variable's is the procedure declaring it,
  empty for a global. It used to be the procedure asking, beside the line of another declaration.
- A broken destination type in `unsafe.transmute` or `math.wrap`, and a `make` length that does not
  convert to `int`, report once rather than twice.
- A compile-time `unsafe.transmute` counts what it builds against the evaluator's memory limit, and
  builds one integer per scalar rather than several per byte: a compile-time loop over a 4 KB array
  peaks at 26 MB rather than 109 MB.
- Arithmetic over a runtime choice of constants takes the type its context gives
  ([Conditional expression](design.md#conditional-expression)):
  `y: u8 = (1 if c() else 2) + 1`, with `*`, unary `-` and `~`, or at a `u8` argument, reached clang
  and failed `L0403`. `("a" if c() else "b") + "c"` is a `string`, and comparing such a string works;
  both failed in clang too. A left shift gives its unfixed operand the type expected, even with a
  runtime choice, or a rune: `r: rune = 1 << n` was `L0310`. A runtime choice as a shift count is an
  `int`, where `a << (1 if c() else 2)` was `L0356`.
- A comparison accepts operands either of which is assignable to the other, as
  [Comparison operators](design.md#comparison-operators) says: `p == r` with a `^int` and a `rawptr`,
  and a labelled record against the unlabelled one with its field types, were `L0354`.
- `pp[i]`, with `pp` a pointer to a C pointer, indexes through the C pointer. It reached clang and
  failed `L0403` ([C pointers](design.md#c-pointers)).
- `&mut a[lo:hi]` slices any mutable array place ([Slices](design.md#slices)): an element of a C
  pointer, a map element, or an `inout` `operator([])` result was `L0359` or `L0477`.
- A field a box's payload promotes beats the box's own member, as a declared one does:
  `box(Outer{...}).clone` with a `using` field holding `clone` was `L0408`
  ([Owned values](design.md#owned-values)). `b(args)` finds `call` through a box and then a pointer,
  as `b.call(args)` does, where `Box(^T)` was `L0320`
  ([Calling a value](design.md#calling-a-value)).
- An array literal is checked by what it lists, not its length
  ([Fixed arrays](design.md#fixed-arrays)): `x := [1 << 33]u8{1}` crashed the compiler, and
  `a: [2000000]u8 = {1500000 = 1}` was `L0361`, though only a `[?]T` has its length set by its keys.
- `D([dynamic]int{})` and `M(map[int]int{})` convert an empty container literal to a distinct type,
  which was `L0373` ([Distinct types](design.md#distinct-types)).
- A condition that cannot be `bool`, as in `1 if 5 else 2`, is reported once rather than twice.
- A distinct type over a union stores its variants as the union does. Its tag used to overwrite the
  payload, so `D.a(9)` read back as `.a(0)` and a reference payload was corrupted. `==` on such a
  type now compiles rather than failing in clang, and a constant comparison tells two variants with
  equal payloads apart. A `switch` over one takes variant cases and must cover them
  ([Distinct types](design.md#distinct-types)).
- A union variant that is itself rejected no longer adds an `L0423` about the union's `@(zero=)` or
  `@(failure=)`, which were judged against the variants left over.
- The `L0425` for a bare payload variant advises `.name(value)`, with its dot, and the one for a
  call to a payloadless variant no longer offers a bare name.
- `([dynamic]T).sort(inout values)` and a sort taken as a procedure value, `f := ([dynamic]T).sort`,
  now sort. Both compiled to an empty body and left the values alone, and neither got `L0651` for
  an element with no `<`.
- `T(v)` of an implicit view or splat is now that conversion written out. `string_view(s)`,
  `([]int)(list)`, `([]int)(array)`, and `Simd(f32, 4)(x)` failed in clang with `L0403`, and
  `(^T)(owner)` of a box read freed memory; they now borrow as the implicit forms do, including a
  temporary a local borrows ([Type conversion](design.md#type-conversion)).
- `([4]int).len(a)` is now constant, as `a.len()` is.
- A `value: T` parameter of a container operation is now a copy site: `m.find(big)` and a map key in
  `m.try_insert(big, 1)` warn `L0507` as `f(big)` does.
- An argument that already failed no longer also reports `L0501` for a `move` parameter.
- A `@(c_vararg)` procedure in a procedure group now takes its variadic arguments, where a call
  through the group said the procedure took too many
  ([`@(c_vararg)`](design.md#c_vararg)).
- A `switch` case stops testing its values at the first match, as the compile-time evaluator did
  ([switch statement](design.md#switch-statement)): `case f(1), f(2):` no longer calls `f(2)` when
  `f(1)` matched.
- `break` and `continue` no longer drop a temporary or a loop's initial declaration twice.
- `return inout x` no longer zeroes the place it hands back.
- A destructuring assignment widens a field to a wider union destination, instead of storing it with
  the wrong tag.
- A temporary in an `else if` initial statement, a `switch` case value or a union argument expansion
  arm is no longer dropped on the paths that did not make it.
- A `switch` drops a subject or case value it produced, such as a call's result.
- Values above 4096 bytes: destructuring one, `errdefer` over a `Result` holding one, comparing or
  switching on a constant one, a large constant holding a pointer, and an iterator record holding
  one no longer segfault or fail in clang (`L0403`).
- A panic now drops a local that every normal exit moves out, under the `unwind` strategy
  ([What the unwind runs, and what it does not](design.md#what-the-unwind-runs-and-what-it-does-not)).
  It was skipped unless some exit left it live.
- A last-use copy stays a clone when a deferred statement that only a panic runs reads the source
  ([Last-use transfer](design.md#last-use-transfer)). It read the emptied source.
- `L0698` no longer reports a required result in code nothing reaches, as after an `if` whose
  branches both return.
- Under `-g`, a parameter whose size is not 1, 2, 4, or 8 bytes shows its value in a debugger, not
  a wrong pointer to it, and same-named types, from two packages or two procedures, each show their
  own layout. A later such type is named `Name$<n>` in the debugger.
- An unresolved type in a foreign signature no longer adds an `L0619` about `<invalid>`, or about a
  zero-sized record, to its `L0306`.
- Checking a record that holds a foreign procedure type taking that record no longer nearly doubles in
  time with each level of records it shares: 24 levels took 7.5 seconds, and now take under a tenth of one.
- The compiler no longer waits a timer tick of about 15 ms on each child it launches.
- An owner built from a provider inside a `Shared` payload is now checked: one built from
  `held.get().allocator()` that outlives `held` is now `L0537`, and returning it is `L0592`. Both
  compiled and read a dead region ([Shared ownership](design.md#shared-ownership)). The same goes for
  an owner built through a local pointer to a provider (`p := &arena; ... via p.allocator()`).
- A generated `clone` of a type holding a `hook(copy)` that takes `self: ^` now borrows what it clones,
  as that hook's own type does. Its result could keep a dangling pointer to the original.
- `some_map.try_insert(key, elem)` now ends the regions of a provider it may replace, as `m[key] = elem`
  does. An owner backed by the replaced provider read freed memory.
- `indexed()` over a map, iterated by reference, now says to count with a variable rather than suggesting
  a mutable view a map does not have.
- A package file with no `package` clause no longer draws `L0328` against an empty name beside the
  `L0202` it already reports.
- `spawn total = work();` where `total` is a capture of the enclosing capture literal now reports
  `L0728`. It crashed the compiler.
- In a `@(cpu_dispatch)` copy, a `foreach`'s `iter` and `next`, a `hook(drop)` at a scope's end, and a
  part's own `==` now reach copies for the level too. They ran as written, which gave the same
  results more slowly ([@(cpu_dispatch)](design.md#cpu_dispatchstring)).
- A program may bind `loke_rt_v1_cpu_dispatch`, or export a name spelling `loke.cpu_dispatch.v3.state`,
  beside a dispatched procedure. Either was a redefinition that clang rejected.
- Editor completion no longer offers `move_only` as a keyword.
- Editor completion lists the members of another package's enum or union named as `other.Color.`,
  and of an alias of its enum, which came back empty. It no longer offers a name two `using` fields
  promote, since selecting it is `L0703`.
- A record containing itself through two `using` fields no longer hangs selector checking or
  editor completion. The program still fails with `L0364`.
- Rename now refuses an associated type the compiler looks up by name (`Element`, `Iterator`,
  `Mut_Iterator`, `Item`), and a member named by an interface requirement under any expression form
  or in a result, binding, or slot type. Renaming one broke `foreach` or the interface with no warning.
- An adapter stored over a mutable view that owns something now holds a clone of it, and one over a
  mutable view that cannot be copied borrows it read-only. The source and the view each dropped the
  same value, which freed it twice ([Iteration adapters](design.md#iteration-adapters)).
- A static `foreach` over `copied()` now yields the elements. It yielded zeros.
- `foreach (p, i in source.indexed())` over a `next` lending a record now binds the counter. It read
  the record's parts as the pair's, and then garbage.
- A `next` may lend through a named record, as [Yield modes](design.md#yield-modes) allows. It was `L0456`.
- `Iterator`, `Mut_Iterator`, and `Item` now derive in whatever order a type's members are declared,
  and on a `distinct` name from its own members. A member that is not a receiver of the protocol's
  shape no longer derives one, and `Item :: 5` on a type with no `next` is no longer `L0694`.
- `x := move y;` now reports `L0228`. It crashed the compiler.
- A call of a generic procedure ending with `---` is now `L0630` rather than an internal `L0405`.
- `indexed()`, `copied()`, and `reversed()` over a value, iterator, or element larger than 4096
  bytes now compile, and so does `foreach` over one taken by value. Each failed with `L0403`.
- A `-runtime` directory that exists but cannot be listed now says so in `L0551`, rather than
  calling the directory empty.
- Editor completion now shows the type of `LOKE_OS` and the other `LOKE_*` enum constants before
  any code reads them.
- The note that more than 64 local allocator regions merged now ends, as the other precision
  notes do, with how to avoid the limit.
- An enum's own `==` and `<` are now the ones used, as a struct's are ([Operator lookup and
  overload resolution](design.md#operator-lookup-and-overload-resolution)): `x == y` ignored its
  own `==` at the top level while `[2]E` used it. A generated `hash` no longer stands beside an
  enum's own `==` or `hash`, so `Hashable(E)` agrees with `map[E]int`. Editor completion no longer lists the generated `hash`
  on a built-in type, as it never did on a record; `x.hash(seed)` still compiles.
- `E.A.hash(0)`, or `E.A.m()` with `self: ^`, no longer fails with `L0405`: an enum member is a
  constant, and is materialized as one.
- A layout measured in a discarded overload probe is measured again: `size_of(S)` printed 0 and
  `L0364` was lost when a `where` bound measured `S`. `L0364` also reaches a record field or a
  procedure's parameter type past the maximum, with a location and before the backend.
- `@(zero=)` on unions that reach each other no longer depends on which is declared first: the
  payload is judged once every record has its fields ([Zero values and
  `@(zero=)`](design.md#zero-values-and-zero)).
- `lokec <root directory> -fmt`, and any other run that writes no executable, no longer asks for
  `-o`. `lokec .` at a drive root, and `lokec D:`, ask for `-o` or use the resolved name, instead
  of writing `C:\.exe` or `D:.exe`.
- A `@(test)` may use a local type or capture literal with a file-scope generic, a formatter or
  a `dyn` view, and an ordinary build of the package, or of an importer of it, still compiles. It
  failed with `L0405`. An ordinary build also leaves out those instances and their `static` and
  `thread_local` locals ([Test procedures](design.md#test-procedures)).
- `-migrate` refuses a record written inside another's attributes with `L0752` instead of crashing,
  and no longer joins neighbouring words, as in `union@(zero=a) where`, when it takes attributes out.
  An attribute list's trailing comma stays, and a comment between two attributes is refused.
- Selecting a logging provider without `core:log` reports `L0660` at the selection, once, without a
  second `L0659`.
- `-dump-ast` labels a `for` statement's post statement `(post ...)`, so `for (f();;)` and
  `for (;;f())` no longer print alike.
- An untyped constant whose address is taken gets storage for each type it is used at, as
  [Materialization](design.md#materialization) says. With `X :: 300`, the same `double` global
  served every use, so a method on a `distinct int` read its bits as an integer. `&X` is now a `^T`
  of the pointee the context asks for or the constant's default type, not `^untyped int`, so
  `p: ^int = &X` compiles.
- A slice of a constant array reached through a run-time index, `MIX[i][:]`, uses the constant's
  read-only storage, where it was `L0477`. `&nil` is now `L0357` where it reached the backend.
- `E.values()` and `E.from_int(...)` inside `E`'s own member values, directly or through another
  constant, are `L0324`. They saw no members, so `B = E.values().len()` silently gave 0.
- A box or a box clone refused for memory reports the size asked for even when dropping the payload
  allocates, and a panic while undoing a refused box clone still drops what was staged.
- `core:log`'s `Level` is called `log.Level` in diagnostics, where `Log_Level` named nothing a
  program could write.
- An atomic operation on a pointer now stays a pointer in the generated code, where it went
  through an integer that hid it from LLVM's alias analysis.
- A `loke.project` found by walking up from the input is read once. A dependency that required it
  back read it a second time and repeated its diagnostics.
- The provenance note for a merged path names both depth limits, 4 aggregate projection steps and
  8 through a written alias, as
  [Minimum provenance precision](design.md#minimum-provenance-precision) asks.
- A swap with a temporary now leaves each carrier in one place in a branch, in a loop, and through
  a view parameter, as [Weakening and reborrows](design.md#weakening-and-reborrows) says.
  `if (flip()) { held := links^[0]; links^[0] = links^[1]; links^[1] = held; }` was `L0641` at
  each read after it, and a copy out of a place the swap filled conflicted with the temporary
  even when done before the temporary's next use. A carrier redefined or replaced after a copy
  also ends what was taken from its old value when both came out of one view. Checking is far
  faster on bodies with many such stores: 300 swaps in branches took over a minute and now take
  under a second.
- A report's arguments may name one place whatever it holds, as printing only reads
  ([Built-in procedures](design.md#built-in-procedures)): `assert(false, "m", p^, p^)`,
  `assert(false, "m", s[0], s[1])`, and `assert(false, "m", h.p, h.p)` were `L0641` where
  the value held a mutable carrier.
- A call to `len` or `cap` only reads, as
  [Weakening and reborrows](design.md#weakening-and-reborrows) says. `y: []Pair = s;
  n := s.len(); z := y[0].n;` was `L0641` where `Pair` held a borrow, and so was the length
  of a dynamic array beside a copy out of it, read-only or mutable, or a read-only view of
  it. What the receiver holds must still last for the call.
- A pointer into one element of a view parameter leaves the others free, as naming that
  element does ([Places and overlap](design.md#places-and-overlap)). `p := &mut s[0];
  x := p^.to; y := s[1].to; x^ = 1; y^ = 2;` was `L0641`, and so was the same stored through
  `p`, two such pointers, and what `keep(&mut s[0], other)` may leave, read from `s[1]`.
- Two values removed from a local dynamic array or map can be live together:
  `x := d.remove(0); y := d.remove(0); x^ = 1; y^ = 2;` was `L0641`, though the same through
  a pointer compiled and neither leaves the container anything of what it hands out.
- A conversion of a slice or pointer to plain data to a read-only carrier, as
  `(dyn Shape)(box)` or `(^int)(carrier)`, now only reads a mutable carrier, as an
  implicit one does, so two such views may be live together
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- A carrier loaded out of a place and passed as a `stored` argument no longer conflicts
  with itself in that call. `keep(l, m^.to); x := l^.to; x^ = 2; m^.to^ = 1;` was
  `L0641` at the call, though `x` is done by the last statement
  ([Retaining a borrow](design.md#retaining-a-borrow)).
- A swap of carriers written with a temporary through a pointer or view, `held :=
  links[0]; links[0] = links[1]; links[1] = held;`, no longer conflicts with itself,
  and copies out of elements reordered whole through a view parameter no longer
  conflict ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- A failed interface bound no longer calls a private constant, or a private
  procedure without a receiver, a private method. `L0444` now says the type has no
  such method, as neither could meet the slot if it were public
  ([Interface bodies](design.md#interface-bodies)).
- Comparing or hashing a zero-length array no longer counts its element's `==` or
  `hash`, which never run ([Global write effects](design.md#global-write-effects)).
  `a == b` on `[0]Clears` reported `L0512` under a view of what `Clears`'s `==`
  writes, as did a record or union holding one. What the comparison requires of the
  element's `==` is unchanged.
- A public type's private `format` no longer counts as a call printing may make
  ([Interface bodies](design.md#interface-bodies),
  [Global write effects](design.md#global-write-effects)), as printing uses the
  generated default. `panic("stop", data[0], Hidden{1})` and `fmt.println(Hidden{1})`
  under a view of `data` reported `L0512` when that method wrote `data`, as did any
  print or report of another type once such a method existed.
- A constant generic parameter whose type applies its own alias, generic type, or
  interface again, as `$V: Alias(T, 0)` beside `Alias :: Record($T, $V);`, now reports
  the instantiation limit (`L0436`) instead of overflowing the compiler's stack, and
  a limit first reached in a probe no longer uses up the report.
- Completion lists a pointer's or box's members at `r.size` when `size` is a method
  called through it ([Language server](compiler-architecture.md#language-server)),
  where it offered nothing.
- A `hook(drop)` or `hook(copy)` is no longer silently skipped when something asked
  about its record first
  ([Lifecycle hooks and resource types](design.md#lifecycle-hooks-and-resource-types)).
  This covers `is_copyable(H)` or a value made before a body-local `impl H`, a generic
  record's member bound evaluated before a later member, and a file-scope `when`
  asking before the block is declared. A hook whose own bound asks and fails is left
  out, where it failed in the backend with `L0405`.
- Storing a mutable carrier back through its `foreach (&mut x in xs)` binding,
  `list.head = list.head`, or replacing it with one read from below,
  `list.next = list.next^.next`, no longer reports `L0641`, and neither does a later
  copy out of another element after `xs[0].next = xs[0].next^.next` on a view parameter
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- Reordering carrier fields through a view parameter, as
  `links[0].to, links[1].to = links[1].to, links[0].to;`, no longer reports `L0641`,
  and what a reordering left can be copied again afterwards in a view parameter, a
  pointer's fields, or after a `swap` of a named array
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- A call that copies between elements at variable indices of a view of a local
  array, in the scope of the arena an element's owner is in, no longer reports
  `L0536`, as that leaves the array nothing new.
- A generic record's `hook(drop)` bound by a `where` clause that an instance fails
  is left out of that instance, whose parts still drop
  ([where clauses](design.md#where-clauses)). It failed in the backend with `L0405`.
- A generic record may recurse through a [parametric
  alias](design.md#parametric-aliases) of a reference to it however the two are
  reached first: `Link :: ^Node($T)` with a `Link(T)` field in `Node` reported a
  false `L0436` for `Link(int)` unless `Node(int)` had been resolved already. A
  record that contains itself by value through an alias is now `L0364`, as it is
  written out.
- A [parametric alias](design.md#parametric-aliases) can bind a constant whose
  type an earlier argument decides: `Alias :: Value($T, $V)` over
  `Value :: struct($T: type, $V: T)` reported an internal `L0405`, and now
  `Alias(int, 3)` is `Value(int, 3)`. An alias can also bind a constant argument
  of a `dyn` interface, as `dyn Window($N)`, which was bound as a type, and a
  generic parameter type that does not resolve is reported at the alias.
- `free_all` of a field read off a temporary record, as in `(Pair{allowed, other}
  if flag else Pair{allowed, other}).a`, is no longer `L0538` for the region its
  sibling `.b` is in.
- An element of a slice literal replaced through its slice no longer keeps what it
  borrowed before, so `view[0] = Read{{}}; drop(values);` is no longer `L0512` after
  `view := []mut Read{Read{values[:]}};`.
- Dropping a zero-length array, as an empty slice literal's backing, no longer
  counts as running its element type's `hook(drop)`, so `[]Clear{}` beside a borrow
  of a global that hook writes is no longer `L0512`.
- A carrier repointed between choices, as `p` in `p := s; ...; p = t; ...`, now
  counts its places against only the storage it names there however many
  definitions of it, or blocks between them, the procedure has. Past 63
  definitions or 256 blocks, a place of `t` still counted against `s`, so a
  disjoint write was `L0641` although each storage was within its eight places
  ([Minimum provenance precision](design.md#minimum-provenance-precision)).
- A reslice in a loop that never moves a local view's start, as
  `s = &mut s[:2]`, now leaves the view's constant elements apart, so `s[1]`
  beside a live `&mut s[0]` is no longer `L0641`. A loop that moves the start,
  as `s = &mut s[1:]`, stays rejected.
- Printing only reads a mutable pointer to plain data, and a mutable slice or pointer
  held in a field, element, or through a pointer, so `fmt.println(held.items,
  len_of(held.items))`, `fmt.println(p, p)`, and `assert(ok, "stop", held.p, held.p)`
  are no longer `L0641`. A read-only parameter reads a field the same way, so what it
  returns no longer keeps a read of the field out
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- Local views reslicing each other in a loop no longer lose where they start when
  one begins short, as `s := base[:1]; t := base[:];` with `s = t[:]` and
  `t = s[:2]` in the loop, so `s[1]` beside a live copy out of `s[0]` is no longer
  `L0641` ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- A dynamic array's first 8 elements are now told apart by a constant index, as a
  fixed array's are ([Minimum provenance precision](design.md#minimum-provenance-precision)).
  `node := lists[0].head; other := lists[1].head;`, directly or through a fresh
  `&mut lists[:]`, was `L0641` as each element stood for all of them; and with it
  `&mut d[0]` beside a use of `d[1]`, and a write of `y` while only
  `links[0]`, built from `&mut x`, is in use. `insert`, `remove`,
  `remove_unordered`, `swap`, the sorts, and any call that moves carriers join
  what the elements hold.
- A mutable carrier held by an element is now usable through a `foreach` loop's
  `&mut` binding, as in `foreach (&mut list in lists) { list.head^.value = 3; }`,
  and `&mut list` may be taken there. Any use of it was `L0641`, as the binding
  counted as a copy of the carrier, and using the binding as a use of that
  copy's source. It now names the element
  ([By-reference iteration](design.md#by-reference-iteration)), and a copy out of
  it reborrows the stored carrier, over a view as well, where the copy used to
  keep only the view's borrows.
- `free_all` of an allocator unwrapped by `or_else` from an unmarked
  `Option(Allocator)` parameter, as in `maybe or_else allowed`, is now
  `L0538`, as the same reset through a `switch` was. Only the fallback's
  region was checked for the `@(allocator_reset)` promise, so an allowed
  fallback hid the payload's reset; a field of an `or_else` result, as in
  `(maybe or_else Holder{allowed}).allocator`, was likewise missed
  ([Allocator regions and region provenance](design.md#allocator-regions-and-region-provenance)).
- A slice literal's elements keep what their drop hooks read borrowed until
  the end of the block, where the hidden array drops them, as an extended
  `&T{...}` temporary's do. After `view = {};` overwrote the slice, `drop` of
  a value an element viewed was accepted, and the hook then read it; and a
  hook's write to a global at the block's end went unchecked against a live
  borrow of it ([Slice literals](design.md#slice-literals)).
- A variadic pack built from separate arguments is now in the allocator
  regions of its elements, so a `parallel` block whose task reserves an arena
  reports the parent passing a list from that arena to a variadic callee that
  clones it by naming the arena, not "an allocator region this procedure
  cannot tell apart from it". A pack whose elements reach no allocator is in
  none, rather than in an unknown region when no other argument has one
  ([Allocators and tasks](design.md#allocators-and-tasks)).
- A panic after a destructuring declaration, as `low, high := pair;`, runs the
  `defer` the procedure registered first again. Binding each field that holds
  no cleanup of its own cleared the frame's first registration
  ([What the unwind runs, and what it does not](design.md#what-the-unwind-runs-and-what-it-does-not)).
- Checking a procedure whose analysis needs more than one GiB of scratch
  memory no longer stops the compiler with `a procedure body's analysis
  outgrew its scratch arena reservation`; the analysis arenas grow past their
  first reservation again.
- A place borrowed through a pointer that was repointed between choices, as
  `p` in `p := s; q := &mut p^.left.a; p = t; q = &mut p^.right.a;`, now
  counts only against the storage the pointer names where the place is
  taken, so four places of `s` and five of `t` no longer reject a write to
  another field of `s` naming the eight-place limit (`L0641`)
  ([Minimum provenance precision](design.md#minimum-provenance-precision)).
- `container.words_for_bits` and `container.bytes_for_bits` no longer
  overflow for capacities near the largest `int`, and `Index_Set(N)` can be
  instantiated at that boundary
  ([`core:container` index sets](standard-library.md#corecontainer-index-sets)).
- A store into one element of a local view replaces its contents however many
  constant reslices of the view come before it; nine or more were rejected
  with `L0641`
  ([Values that contain borrows](design.md#values-that-contain-borrows)).
- Storing a carrier through a slice parameter at a variable index, as
  `s[k].head = s[k].tail`, no longer rejects a borrow of another field of the
  same or another element kept beside it in a loop (`L0641`)
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- A local view that a branch only shortens, as
  `if (flag) { s = &mut s[:2]; }`, and a fresh view of a whole dynamic array,
  as `s := &mut d[:]`, now keep their elements at different constant indices
  apart, so `&mut s[0]` leaves `s[1]` usable; both were rejected with `L0641`
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- A carrier copied out of one element of a local view, as `s[0].head`, no
  longer suspends the carriers stored in its other elements, so copying
  `s[1].head` beside it compiles, as it already did out of the array itself
  and through a view parameter (`L0641`)
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- A public constant with no written type in a generic `impl` now warns
  `L0740` when its value's type is private, as it does in a non-generic
  `impl`: at the declaration when the value names none of the block's `$`
  names, otherwise once from the instances
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- A public type alias in a generic `impl` now warns `L0740` when its target
  names a private type, as it does in a non-generic `impl`, including a
  private alias of a public type and a target such as `Pair(T, Corner)` that
  names the block's `$` names
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- `L0740` now also reads a type alias written with its type, as
  `Inner: type : Corner`, in a generic `impl`, and an alias, anywhere, that
  selects a private type member from an instance, as `Box(T).Hidden` or
  `Box(int).Hidden` does
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- In a generic `impl`, `L0740` now also reads the target of an alias whose
  written type is an alias of `type`, as `Inner: Meta : Corner` for
  `Meta :: type`, or a `$` name that an instance binds to `type`; selects a
  private member alias written as a slice, pointer, array, or map type, as
  `Box(T).Hidden` for `Hidden :: []T`; and follows a chain of member aliases
  however long it is, where it stopped after eight
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- `L0740` now reads parametric aliases as it does other aliases: a public one's
  target, as `Public_Result :: Result($T, Hidden)`, and a private one applied in
  a public declaration, as `consume :: proc(x: Hidden_Result($T))`. It also reads
  the members of a block written through a private alias of a public type, as
  `impl Short` for `Short :: Point`, which it used to take for a private type's
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- `L0740` now reads a selection of a generic `impl`'s private member that is a
  type only in an instance, as `Box(T).Hidden` for `Hidden: T : Point` in
  `Box(type)` or for `Hidden :: type_of(T{})`, in a public alias with or without
  a written type, a constant's written type, a method's signature, or a group's
  member. A selection such as `Box(type).Hidden`, which names no `$` name, is read
  at its declaration
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- `L0740` now reads such a selection in every instance, where it stopped after a
  declaration's first, so `Item(T, Holder(T, V).Hidden)` warns for `Hidden: T : V`
  when `Holder(int, 0)` is instantiated before `Holder(type, Point)`, as it did
  the other way round
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- `L0740` no longer reads a generic method's own `$` names by what its block or
  package means by those names, which warned for `Item(T, Holder(T, V).Hidden)`
  in `make :: proc(self, $T: type, $V: T)` when the package also declared `T` and
  `V`. It now reads a type past a plain parameter of the same name, which hides
  nothing a type names, so `proc(Corner: int) -> Corner` warns for a private
  `Corner`
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- `L0740` now reads a selection such as `Twin(Bag(T).Inferred, int)`, for a member
  that is a type only in an instance, wherever a generic declaration writes it: a
  generic record's public field or variant, a generic procedure's signature, in a
  method's own `$` names too, a parametric alias's target, and a generic interface's
  requirement. Each is read in the instances the build creates, as a generic
  `impl`'s own declarations already were
  ([Private names in public declarations](design.md#private-names-in-public-declarations)).
- Editor completion no longer offers a type's generated `format` where a use
  could not call it, on a public type with a private `format`, and shows a local
  extension's `format` rather than the generated one it hides
  ([Language server](compiler-architecture.md#language-server)).
- `time.local_zone` on Windows no longer panics for a zone set without a
  registry key, as `SetTimeZoneInformation` can leave it, and a zone whose
  dynamic daylight saving is disabled keeps its fixed annual transitions
  instead of showing standard time all year; it reads the zone's own rule,
  as Windows' clock does
  ([Time zones](standard-library.md#time-zones)).

- `fs.create_directories` creates only the directories of the path Windows
  normalizes its argument to, so `a/skipped/../made` no longer creates
  `skipped`, nor fails when `skipped` is a file; an extended-length `\\?\`
  path is still walked as written
  ([Filesystem operations](standard-library.md#filesystem-operations)).
- An implicit selector given to a generic procedure's `$` parameter whose type
  names no `$` parameter, as `.Fast` to `run :: proc($mode: Mode, x: $T)`,
  now takes that type, as an ordinary parameter's argument does
  ([Implicit selector expression](design.md#implicit-selector-expression)).
  Before, it was rejected with `L0385`.

- A store into one element of a local slice view at a constant index, as
  `s[0].head = s[0].tail` with `s := &mut arr[:]` or a constant reslice
  `t := &mut s[1:]`, now replaces what that element held, so a loop that
  copies `s[0].head` before the store compiles, as it does through a slice
  parameter ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- Such a store also replaces what the element held when the view was resliced
  from itself before the loop, as `s = &mut s[1:]`; it was rejected with
  `L0641`. Resliced inside the loop or in one branch only, `s[0]` may name
  several elements, and the store is still rejected
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- After `p^ = q^` through a pointer parameter, a copy of one carrier, as
  `p^.head`, no longer holds the loans of the record's other carriers, so
  `q^.tail` stays usable beside it
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- Passing an existing mutable carrier to an `@(escape=stored)` parameter
  beside an `inout` destination, as `keep(inout d, r)`, is no longer
  rejected with `L0641` at the call itself
  ([Retaining a borrow](design.md#retaining-a-borrow)).
- Passing a named read-only reborrow to an `@(escape=stored)` parameter, as
  `keep(p, read)` after `read: ^Node = r`, is no longer rejected with
  `L0641` at the call; what the call stores extends the reborrow, so `r`
  stays unwritable while it is used
  ([Weakening and reborrows](design.md#weakening-and-reborrows),
  [Retaining a borrow](design.md#retaining-a-borrow)).
- `core:math/linalg`'s `perspective` and `perspective_lh` compute their depth
  coefficients from `far/(far - near)` and `near/(far - near)`, so a finite
  near and far whose product overflows or underflows, such as 10 and 1e38 at
  `f32`, no longer give an infinite or zero coefficient
  ([`core:math/linalg`](standard-library.md#coremathlinalg)).
- `core:math/linalg`'s `orthographic` and `orthographic_lh` compute a row from
  the halves of its bounds when their sum or difference overflows, so finite
  bounds such as 2e38 and 3e38 at `f32` no longer give an infinite or zero
  coefficient where the value is representable, a subnormal one included
  ([`core:math/linalg`](standard-library.md#coremathlinalg)).
- `core:math/linalg`'s `to_euler` divides a finite non-unit quaternion at an
  extreme scale by its largest component magnitude first, so
  `(1e200, 0, 1e200, 0)` gives the angles of the unit `(1, 0, 1, 0)` instead
  of a NaN ([`core:math/linalg`](standard-library.md#coremathlinalg)).
- `core:math/dense`'s `svd` and `symmetric_eigen` scale a matrix near
  overflow or among the subnormal numbers by a power of two first, so they
  no longer return infinite or NaN factors, discard an off-diagonal element
  near overflow, or hang. An eigenvalue or singular value too large for the
  type is reported as `.No_Convergence`, and matrices in range keep their
  bits ([`core:math/dense`](standard-library.md#coremathdense)).
- `core:math/dense`'s Householder reflector no longer overflows for a column
  near the largest finite value, and keeps `Q` orthonormal for a subnormal
  column ([`core:math/dense`](standard-library.md#coremathdense)).
- `core:math/dense`'s `symmetric_eigen` no longer rejects a NaN or infinite
  imaginary part on a Hermitian matrix's diagonal, which it does not read
  ([`core:math/dense`](standard-library.md#coremathdense)).
- `core:math/dense`'s `Lu.reciprocal_condition` no longer reports a
  well-conditioned matrix of tiny or huge scale as singular; multiplying the
  matrix by a power of two leaves the estimate unchanged
  ([`core:math/dense`](standard-library.md#coremathdense)).
- `core:math/geometry` gives a triangle with two equal corners the closest
  point and distance of the segment its corners span, where it returned NaN;
  `intersection` of a box with a NaN corner is empty in either operand
  order; a ray through an edge two triangles share hits one of them for
  small and large triangles too, whose edge functions are now recomputed in
  `f64` when they underflow or overflow; and `f32` and `f64` circle and
  sphere `contains`, `closest_point`, `distance`, overlap tests, and `cast`
  no longer treat a point as inside, or miss or invent a hit, when their
  squares overflow or underflow
  ([`core:math/geometry`](standard-library.md#coremathgeometry)).
- `unsafe.transmute` to `typeid` works in constants:
  `unsafe.transmute(typeid, u64(999999))` is a constant that keeps its number
  for every bit pattern, and casting it back to an integer folds too
  ([`unsafe.transmute`](design.md#unsafetransmute),
  [Invalid representations](design.md#invalid-representations)). Before, it
  reported `L0688`.
- A store through a pointer parameter whose record has a single carrier
  field, as `p^.head = replacement`, ends the old borrow in that field, as it
  already did for records with several, and reading a plain field beside such
  a carrier is no longer taken as a use of it
  ([Values that contain borrows](design.md#values-that-contain-borrows)).
- A store into one element of a slice parameter at a constant index, as
  `s[0].head = s[0].tail`, replaces what that field held instead of joining
  into the parameter, so a borrow of another field beside it is accepted, also
  in a loop ([Weakening and reborrows](design.md#weakening-and-reborrows)).
- Storing a whole record through a pointer to one place replaces the carriers
  it held, so a copy of a field taken before the store no longer conflicts
  with one taken after it
  ([Values that contain borrows](design.md#values-that-contain-borrows)).
- A rejection caused by a pointer that may point at more than eight places of
  one storage, which the analysis then takes to point at a place they share,
  says the reborrow *may* cover the place and names the limit, as
  [Minimum provenance precision](design.md#minimum-provenance-precision)
  requires.
- `core:math/linalg` preserves exact `lerp` and `slerp` endpoints, including
  signed zero; `angle_between` returns zero for a zero vector even when its
  dot product is negative zero; and `to_rotation_vector` chooses the same
  axis for both signs of an exact half-turn quaternion
  ([`core:math/linalg`](standard-library.md#coremathlinalg)).
- A fixed array type around a procedure literal, such as
  `[1]proc(x: int) -> int{one}` written for an array of procedures, reports
  only its parse error, not also `L0350`, the compiler-defect report; name
  the procedure type to write such an array.
- `examples/lexer.loke` lexes the wrapping operators `+%`, `-%`, `*%`, and
  their compound assignments, which it read as two tokens each, so it agrees
  with `lokec -dump-tokens` again on a source that uses them.
- A typed constant scalar splatted into a SIMD vector, as
  `zero: Simd(T, 4) = T(0)` in a generic body or `Simd(f32, 4) = f32(0.5)`,
  folds to the vector constant as an untyped one does. It reached the backend
  as a scalar constant of the vector's type, and Clang rejected the module.
- A `where` bound checked while an earlier file of a package resolved its
  signatures found the slot's member resolved in that file's place, so
  `self` in an `impl f32` block took the type being instantiated: the bound
  failed and the block's body was rejected. Whether a package compiled
  depended on how its files sorted.
- A generic record's value parameters bind in a procedure's parameter pattern
  as its type parameters do, so `rows :: proc(m: M($R, $C)) -> int` compiles;
  before, every call reported `` `$R` is not bound here ``
  ([Specialization](design.md#specialization)).
- A member of a generic `impl` that adds generic parameters of its own works
  as an operator, as `operator(*) proc(left: M(R, C), right: M(C, $K))`, as a
  conversion hook generic over its source, now specified in
  [Conversion hooks](design.md#conversion-hooks), and when called through its
  type, as `M(2, 3).times(a, b)`. File-scope generic operators are found too.
  Before, such operators and hooks were never found, and a malformed one
  went unreported; it now gets the concrete declaration's `L0416` or `L0488`.
- An arithmetic operator that does not apply because the type's inherent one is
  not `@(public)` now says so, as ordering already did, including when an
  interface requirement fails for a type declared in a package that exports
  nothing by default.
- An implicit selector such as `.First` or `.circle(r)` passed to a generic
  procedure takes its type from a parameter whose written type names none of
  the procedure's `$` parameters, as it does for an ordinary procedure;
  before, it reported `L0385`
  ([Implicit selector expression](design.md#implicit-selector-expression)).
- A procedure group declared before its members in a generic `impl` drops a
  member that a failed `where` bound excludes, as one declared after them
  always did; before, every call through it was ambiguous
  ([where clauses](design.md#where-clauses)).
- A member of an instantiated generic block can be called at compile time
  before the checker reaches the block: its `where` clause no longer reports
  `L0433`, and a user operator such as an `inout` subscript, `g[i] = x`, no
  longer runs unchecked and fails with `` `self` is not compile-time storage ``
  ([Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)).
- `Status` and `try_make` are listed among the [predeclared names](design.md#predeclared-names), which they have always been, and the VS Code grammar now highlights them as such. The specification also records `@(cross_thread)` in [procedure-type compatibility](design.md#procedure-type) and that a pooled task runs on a worker rather than a thread of its own.
- A mutable borrow through a pointer passed to a read-only parameter is
  checked as read-only even when an index on the way calls something that
  writes, so `peek(&mut both[idx(&mut n)]^.count)` beside `&both[0]^.count`
  compiles, as it does with `&`
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).

- Three read-only uses through a pointer beside a borrow reached through it
  are now accepted, as they are for a local
  ([Weakening and reborrows](design.md#weakening-and-reborrows)): a `switch`
  binding of another field, as `switch (h^.first)` beside `&h^.count`; a
  mutable borrow weakened to a read-only parameter, as `peek(&mut h^.count)`,
  though a call in its index, as `bump(q)` in `peek(&mut h^.cells[bump(q)])`,
  still writes what it writes; and a pointer copied out to a read-only destination, as `look(p^)` or
  `held: ^Holder = p^` beside `&p^^.count`.

- A store through a pointer to a local place, as `list^.head = list^.tail`
  with `list := &mut l`, now replaces what that field held, as `l.head = ...`
  does, so the pointer stored there before is no longer in use. Copying
  `list^.tail` again after storing it into `head` now compiles, through two
  pointers or a constant element too. A store into one field through a
  pointer no longer counts as a store into the others, so the same store
  repeated in a loop through a pointer that may name either of two locals
  compiles as well, though such a store still keeps what each place held
  ([Values that contain borrows](design.md#values-that-contain-borrows)).

- A store through a pointer parameter, or a pointer loaded out of one, as
  `p^^.head = p^^.tail` with `p: ^mut ^mut List`, now lands in the caller
  storage it names and replaces what that field held, instead of counting as
  a store into `p` itself. Repeating it in a loop beside a borrow of another
  field, as `count := &p^^.count`, now compiles, as does copying
  `p^^.head` again after storing over it, and a borrow through `p^^.head`
  no longer conflicts with a write through `p^^.tail`. A store through a
  slice parameter still counts as one into the parameter
  ([known-gaps.md](known-gaps.md)).

- `return nil;` in a procedure returning an `Option(^T)` no longer suggests
  `.some(nil)`, which is an error of its own since `nil` is not a `^T`. The
  diagnostic now says so and suggests `.none`.
- `strconv.parse_f64` now rounds a spelling with more than 768 significant
  digits correctly: the C library ignored every digit past the 768th, so
  `"9007199254740993." + 760 zeros + "1"` read as 2^53 instead of 2^53 + 2.
  It also no longer allocates a copy of the text.
- Returning a view of a switch payload bound over a place, as in
  `case .owned(text): return text;` with a `string_view` result through a
  borrowed receiver, is no longer rejected with `L0526`: the binding names
  the subject's storage ([Switch ownership](design.md#switch-ownership)).
  Returning such a view also no longer clears the payload the subject still
  owns.

- A view of, or a pointer to, a lent `foreach` element can now be returned
  through the borrowed parameter it came from, as in
  `foreach (item in d.items) { return item; }` with `d: ^Doc`, or over a
  `[]string` parameter. Both were rejected with `L0526`
  ([Borrowing iteration](design.md#borrowing-iteration)).

- A copy of a lent `foreach` element of a slice, as
  `foreach (item in values) { return item; }` with `values: []string_view`,
  now keeps only the element's own borrow, as `values[0]` does
  ([Procedure result contracts](design.md#procedure-result-contracts)). Using
  such a copy after the sliced array ended, or after changing the slice, was
  rejected even when the view was of static text.

- A result read through a pointer or slice parameter now depends only on the
  fields it reads, as
  [Procedure result contracts](design.md#procedure-result-contracts)
  requires. With `Pair :: struct { a: string_view, b: string_view }`, the
  result of `return values[0].a;` over `values: []Pair`, or of `return p.a;`
  over `p: ^Pair`, no longer counts as depending on `b`, also when the
  procedure only forwards to another one that reads `a`. Using it after
  storage only `b` viewed had ended was rejected with `L0513`.

- Calling a read-only method through a mutable pointer, as `items.len()` with
  `items: ^mut [dynamic]int`, is no longer rejected with `L0641` while a
  read-only reborrow of the pointer is in use: such a call only reads, which
  [Weakening and reborrows](design.md#weakening-and-reborrows) allows.
  Reading through a pointer to such a pointer, as `p^^[0]` or `p^.len()` with
  `p: ^mut ^mut [dynamic]int`, while a read-only reborrow of `p` is in use is
  no longer rejected either, nor is taking another read-only borrow through
  the pointer, as `first, second := &items^[0], &items^[1];` or a second
  `items^[:]`.

- A field returned by a `self: ^` method, as
  `first :: proc(self: ^) -> string_view { return self.a; }`, now depends
  only on that field of the receiver, as it already did through a `p: ^Pair`
  parameter
  ([Procedure result contracts](design.md#procedure-result-contracts)).
  Using `values[0].first()` after storage only `b` viewed had ended was
  rejected with `L0513`, and so was using `make_pair(...).first()` after the
  statement, even when `a` was static text.

- A field of an element of an array or record literal, as `values[0].a` after
  `values := [2]Pair{{"static", source}, {"x", other}}`, no longer depends on
  what its sibling field borrows when a later element holds a borrow too
  ([Minimum provenance precision](design.md#minimum-provenance-precision)).
  Using it after `source` ended was rejected with `L0513`.

- A field read two loads below a parameter, as `return d.pair.a;` with
  `Deep :: struct { pair: ^Pair, other: string_view }` and `d: ^Deep`, now
  depends only on that field, as one load below already did
  ([Procedure result contracts](design.md#procedure-result-contracts)). Using
  the result after storage only `other` or `pair.b` viewed had ended was
  rejected with `L0513`.

- Walking a list over a `next: Option(^mut Node)` field in a loop, as
  `switch (cur^.next) { case .some(next): cur = next; case .none: return; }`,
  is no longer rejected with an `L0641` that named no variable: loading
  `cur^.next` again leaves nothing reborrowed from the value the last pass
  loaded ([Weakening and reborrows](design.md#weakening-and-reborrows)).

- A mutable pointer copied out of a place on each pass of a loop, as
  `node := list^.head;` in a `for` body with `list := &mut l`, and the same
  list walk through a pointer to a local, as `cur := &mut first`, are no
  longer rejected with `L0641`: loading the place again starts afresh, so the
  copy the last pass made no longer counts
  ([Weakening and reborrows](design.md#weakening-and-reborrows)).

- Fields two pointers away from a parameter are now told apart as a local's
  are: `p^^.tail^.value += 5` and `p^^.count += 1` beside
  `node := p^^.head`, with `p: ^mut ^mut List`, compile, and so does copying
  another field, as `other := cur^.other`, beside a binding of
  `case .some(next):` over `cur^.next`. Both were rejected with `L0641`.

- A parametric alias whose body refers more than once to another alias no longer takes exponential
  time to check ([Parametric aliases](design.md#parametric-aliases)):
  `B :: Pair(C($T), C($T)); C :: Pair(B($T), B($T));` hung instead of reporting `L0745`, and a valid
  chain of 24 such aliases took seconds. A cycle longer than 64 aliases now reports `L0745` too.
- A `$` parameter's default can name an earlier parameter in its type across calls
  ([Default values](design.md#default-values)): with `$N: int, $A: [N]int = [N]int{}`, `f(2); f(3);`
  rejected the second call, as the type was read once.
- A `$` name in a type application's constant argument that is unbound, or bound to a type, is now
  `L0437`: `v: Vec($N);` stopped with an internal `L0405` and no span.
- A rejected generic signature now reports its first error, not a deprecation warning that came
  before it.
- `f(nil)` for `f :: proc($v: $I)` now says `nil` has no type to infer `$I` from, and a named argument
  no parameter of a generic procedure takes now says `no parameter named` or `is given twice` rather
  than a count of arguments.

- A `distinct` type may declare `hook(convert)` from a source its underlying type also converts
  from: `R` and `D :: distinct R`, each with one from `bool`, was a false `L0488`
  ([Conversion hooks](design.md#conversion-hooks)). Two hooks from one source on `distinct int` are
  now `L0488` where they are written, instead of `L0391` at the first use.
- A `distinct` fixed array has `clone` as well as `try_clone`
  ([Distinct types](design.md#distinct-types)): `a.clone()` was `L0363`.
- Copying a `[0]T` no longer counts `T`'s `hook(copy)`, so what that hook reads no longer gives a
  false `L0511` ([Global write effects](design.md#global-write-effects)).
- Asking whether a deeply nested record is copyable, and copying one, no longer takes time
  exponential in its nesting.
- A conditional expression whose operands need a destination type, such as `.A if c else .B`, now
  takes one through a procedure group, a generic and a method, as it did in a plain call, and waits
  for inference as they do
  ([Arguments typed after inference](design.md#arguments-typed-after-inference)); each was `L0385`.
- A group member with no parameter for an argument no longer hides another member's parameter type
  because it is generic. `g(1, .A)` was `L0385` with `f(x: int, m: Mode)` and `h(x: $T)` in `g`.
- An `inout` argument no longer makes a member viable through a conversion an `inout` parameter
  refuses, so `g(inout y, 1)` with `y: []mut int` selects the member that takes `[]mut int`; it was
  an `L0391` ambiguity with one that takes `[]int`.
- A rejected group member now names a missing or extra `inout`, where it said "argument 1 is `int`
  where `int` is wanted". It advises `move(...)` only for a place of the right type, where a
  temporary or a wrong type was told to write it too.
- A failed overload's reasons are now worded only when they are reported. A call through a group of
  128 members checks in about half the time.
- `r or_return .Bad` on a place no longer warns that it clones `r` when only the success is copied:
  an `or_return` replacement leaves the error where it is
  ([Operator ownership](design.md#operator-ownership)). `L0507` now names the success's cost.
- `find() or_return undefined_name` on a failure that carries nothing now reports the unknown name.
  The operand is checked as the replacement it must be, and "carries no error to map" is a note on
  a value that does not fit ([The failure operand](design.md#the-failure-operand)).
- A procedure literal assignable to the failure payload type is an `or_return` replacement, as any
  other such value is: with `F :: proc() -> int`, `res() or_return proc() -> int { return 1; }` was
  `L0322` ([The failure operand](design.md#the-failure-operand)).
- A `case` of a union `switch` that repeats a variant or names none no longer reports its body again:
  `case .nope(z): return z + 1;` added `L0352` for `z`, bound at the union type.
- `lokec -fmt` no longer indents these one level too deep: the list items after a wrapped item, the first line after a wrapped
  `case` header or `@(...)` attribute, and a `{` that starts its own line, which now lines up with its `}`. Every later line of
  a wrapped `where` clause now sits at the same level, and a bracket after a multi-line raw string or block comment indents from
  where its line began. `f(/* name */ x)` stays as written instead of becoming `f( /* name */x)`.
- A capture literal written with the same text as one enclosing it, such as `proc() capture(x)` in
  the body of `proc() capture(x)`, compiles; it was `L0305`, naming the literal's header
  ([Capture literals](design.md#capture-literals)).
- `capture(n = nil)` is `L0310`, as `n := nil` is; it was `L0306`, "unknown type `n`".
- A `switch` with no cases over a `union {}` is exhaustive, as one over an `enum {}` is, so no return
  need follow it ([Exhaustive switch](design.md#exhaustive-switch)). It was `L0365` in a procedure
  with a result.

## [0.9.0] - 2026-10-27

### Breaking changes

- A replacement for a bundled package given with `-collection`, such as a
  `core:mem` of a project's own, must now declare each public name the
  compiler supplies to that package with
  [`@(intrinsic)`](design.md#intrinsic); one it leaves out is `L0737`. Upgrade
  by copying those declarations from the bundled package's source, or from its
  `api.loki`.

- A `thread.Mutex` guard kept past a `parallel` block's join, while a task of
  the block borrows the mutex, is now rejected with `L0733`
  ([Releasing before the join](design.md#releasing-before-the-join)): a task
  locking that mutex could never finish, and the join would wait forever. For
  example, `held := total.lock(); parallel { spawn add(&total); }` no longer
  compiles. Upgrade by dropping the guard before the block, or by locking
  inside a scope that ends before it.

- `thread.Receiver(T).iter` now borrows the receiver (`self: ^`), and the
  iterator receives through it. Before, the iterator pointed at the channel
  alone, so its receiver could drop, closing the receiving side, while the
  iterator could still receive: a send then failed, or a receive waited
  forever. Dropping a receiver while its iterator is still in use is now
  rejected with `L0512`. Upgrade by keeping the receiver alive until its
  iterator ends.

- `thread.Guard(T)`, the guard `Mutex.lock` returns, is now
  [`@(thread_affine)`](design.md#thread_affine), since Windows requires the
  thread that took the lock to release it. Moving or lending a guard to a
  thread `thread.spawn` starts, or across a `parallel` block's task boundary,
  reports `L0724`; for example, `thread.spawn(release, move(guard))`. Upgrade
  by locking on the thread that uses the guard and dropping it there.

- `exchange` now returns the previous owner with its allocator region instead
  of an unknown one. Returning an arena-backed owner extracted with `exchange`
  from a procedure that ends the arena reports `L0592`; for example,
  `return exchange(inout items, {});` where `items` came from a local arena.
  Upgrade by allocating the returned owner from an allocator that outlives the
  procedure, or by cloning it into one before returning.

- Owners written through a mutable borrow of array storage, or through a
  stored read-only pointer that reaches a mutable carrier, now retain their
  destination's storage identity and allocator dependencies. Premature resets
  report `L0537`; for example, `fill(a, &mut owners[:]); free_all(a); use(owners);`
  can no longer pass checking. Upgrade by putting `owners` and its uses in an
  inner block and calling `free_all(a)` after that block's cleanup, or by
  explicitly dropping the dependent owners before resetting their region.

- Borrowed switch payloads in anonymous storage now preserve callee writes,
  and payloads extracted with `unbox` or `as` retain their carrier targets.
  Unsafe arena-backed owner escapes report `L0536`. Owners written into slice
  literal backing arrays also retain allocator dependencies, so premature
  resets report `L0537`, including after copying an owner out. Upgrade by
  allocating retained owners from a region that outlives their destination,
  and resetting it after dependent owners have been cleaned up.

- Stored success payloads, owner-to-view conversions, and copies of slice
  literals now preserve carrier storage identity when invalidating targets
  after writable calls. Unsafe arena-backed owners escaping through these
  paths report `L0536`. Upgrade by allocating retained owners from a region
  that outlives their destination.

- Writable-call target invalidation now follows box payloads, map keys and
  values, and literal slice and dynamic-array elements. Unresolved payload
  targets also preserve known destinations' lifetime constraints, so owners
  backed by received allocators cannot escape to globals through those paths.
  Unsafe stores report `L0536`. Upgrade by allocating retained owners from a
  region that outlives their destination.

- Indirect carrier loads now retain unresolved alternatives from every possible
  source. Calls that may overwrite carrier-valued storage also invalidate stale
  target facts, including through nested wrappers and variadic arguments.
  Arena-backed owners escaping through these paths now report `L0536`. Upgrade
  by allocating retained owners from a region that outlives their destination;
  use read-only access to the carrier itself for calls that only inspect it.

- Writes through borrowed payloads now preserve old borrows in every possible
  destination, and reading an unresolved global carrier retains its target
  uncertainty alongside earlier known targets. Dangling uses report `L0513`;
  escaping arena-backed owners report `L0536`. Upgrade by replacing the borrow
  in each destination before its source ends and allocating retained owners
  from a region that outlives their storage.

- Borrowed switch payload writes now check the subject's storage lifetime and
  preserve stored borrows after the case ends. A carrier with both known and
  unresolved targets also keeps the owner-escape restriction. Unsafe stores
  report `L0647`, `L0513`, or `L0536`. Upgrade by storing only borrows and owners
  that outlive the subject, or resolve the destination before storing.

- Allocator resets now account for owners lending temporary views or erased
  arguments, including temporaries extended by a local and deferred cleanup
  order. Borrowed switch payloads reached through known carriers also preserve
  their region dependencies. Unsafe resets report `L0537`; escapes through an
  unresolved carrier remain `L0536`. Upgrade by resetting after dependent
  owners are cleaned up, and evaluate resets before creating dependent views.

- Allocator resets now account for consumed switch payloads, received `move`
  parameters, and owned arguments held during evaluation. Writes through borrowed
  switch payloads also retain their region dependencies in the subject. Unsafe
  resets report `L0537`, and stores through borrowed bindings into longer-lived
  storage report `L0536`. Upgrade by dropping dependent owners before resetting,
  evaluate resets before constructing dependent arguments, and allocate stored
  payloads from an allocator that outlives their destination.

- Union widening, deeply nested indirect logical copies, propagated errors,
  and directly returned map-literal keys now preserve their allocator-region
  dependencies. Unsafe resets report `L0537` and returns from local arenas
  report `L0592`, including through error mappers and widened error domains.
  Upgrade by dropping dependent values before resetting their region, and
  allocate returned payloads and keys from an allocator that outlives them.

- Indirect calls returning logical copies now retain borrowed inputs' allocator
  regions, and map index assignment retains the inserted key's region. Unsafe
  resets and escapes now report `L0537` or `L0536`, as their direct-call and
  map-method equivalents already did. Upgrade by dropping every retained copy
  and map before resetting its region, or by using an allocator that outlives
  the destination.

- Explicit string clones, generated copies retaining shared storage, and
  `Shared`/`Weak` handles now keep their backing allocator regions. Resetting
  those regions while a retained owner is live reports `L0537`, and escaping
  owners report `L0536` or `L0592`. Copies, downgrades, upgrades, and fallible
  constructors preserve these checks. Upgrade by resetting the allocator
  after every dependent handle or logical copy has been dropped, or by using
  an allocator that outlives them. Allocating clones still use the destination
  allocator for their new storage.

- A `parallel` task that may write a borrow of its own `thread_local` storage
  back through a mutable argument, or through a read-only one that reaches a
  mutable carrier, such as a `[]^mut ^int` or a variadic `..^mut ^int`,
  directly or through a callback of any type,
  including a callable view or one with an inferred contract, is now rejected
  with `L0730`, as is a task handed such a borrow that a call on the parent left
  in its variable. So is a task's result that a callback called through a plain
  procedure type or a `dyn proc` view may return such a borrow in. A procedure
  passed by name for a callback is judged by what it writes back itself, and by
  what it leaves for a result read back from it, not by every procedure of its
  type. A procedure whose result may hold a `thread_local` borrow one of its
  callbacks leaves no longer converts to an inferred contract (`type_of`) whose
  result does not (`L0645`). Upgrade by keeping that borrow inside the thread
  that owns the storage, or by writing back a value whose storage remains live
  after the join.

- An owner a call leaves through a read-only carrier that reaches a mutable
  one now keeps its allocator's region, as one left through a `^mut T`
  parameter does: through a variadic `..^mut T`, or a `^Box` whose field is
  `^mut T`, written directly, through a local copy of the carrier such as
  `alias := outs` or `alias := box if flag else box`, or through a value
  built from it such as `b := box^` or a field set by `pair.out = box^.out`,
  a later `free_all` of that region while the owner is live is
  `L0537`. One left through a pointer the caller holds, or through such a
  record, is written through a pointer, so from a local arena it is `L0536` at
  the call, as `p^ = make(...)` already was. Upgrade by passing `&mut owner`
  itself, or by allocating from an allocator that outlives the owner.

- An owner written through a pointer held in a local, such as `p := &mut out`
  or `box := Box{&mut out}`, now keeps its allocator's region in `out`, by
  `p^ = make(...)` or by a call such as `fill(allocator, p)`. A later
  `free_all` of that region while `out` is live is `L0537`, including from an
  `@(allocator_reset)` parameter's allocator, as passing `&mut out` directly
  already was. Upgrade by resetting the region after the owner's last use, or
  by allocating from an allocator that outlives it.

- An owner written through a pointer to file-scope, `static`, or
  `thread_local` storage held in a local, such as `p := &mut held` followed
  by `p^ = make(..., allocator)` or `fill(allocator, p)`, is now `L0536` when
  its region is one the procedure received, as assigning to `held` directly
  already was; for a region it created, the message now names that storage.
  Upgrade by allocating what such storage keeps from an allocator that
  outlives it.

- Each operand of a variadic pack now lends as one argument of its type does,
  so a mutable carrier passed by name is reborrowed for the call, and
  `fill(out, out)` for `fill :: proc(outs: ..^mut int)` is `L0641`, as
  `two(out, out)` with two `^mut int` parameters already was. Upgrade by
  passing the carrier once, or by calling once per carrier.

- `-doc` and hover show only [doc comments](design.md#doc-comments), line
  comments that start with `///`, and no longer the `//` comments above a
  declaration, so a `//` note for maintainers can stand beside one. A `///`
  that documents nothing, such as one in a body, is the warning `L0260`. The
  bundled packages' usage comments are now `///`, and their spec citations and
  implementation notes are no longer shown. Upgrade by writing the comments
  meant for a declaration's users with `///`:

  ```loke
  // before
  // The number of bytes in `text`.
  byte_count :: proc(text: string_view) -> int { return text.len(); }
  // after
  /// The number of bytes in `text`.
  byte_count :: proc(text: string_view) -> int { return text.len(); }
  ```

- A variable cannot be `@(public)`: one at file scope, with `static` or
  `thread_local`, or in a foreign block is `L0338`. A public-default file or
  foreign block leaves its variables package-private, so an importer naming one
  gets `L0336`. `os.args` is now a constant, and every use of it reads as
  before. Upgrade by exporting a procedure in the variable's place:

  ```loke
  // before
  @(public)
  verbose: bool;
  // after
  verbose: bool;
  @(public)
  is_verbose :: proc() -> bool { return verbose; }
  @(public)
  set_verbose :: proc(on: bool) { verbose = on; }
  ```

- A carriage return in a source file must be followed by a newline. A lone one,
  inside a comment or a raw string too, is `L0115`, reported at the first in
  each file; it used to be whitespace, which numbered lines differently from
  an editor. Upgrade by saving the file with LF or CRLF line endings, and by
  writing a carriage return a raw string held as `"\r"`.

- Unsigned `+`, `-`, `*`, and unary `-` panic when the result does not fit, as
  signed arithmetic does: `u32(3) - u32(5)` stops the program with `unsigned
  integer overflow` instead of giving 4294967294. Unsigned SIMD lanes and the
  integer `simd.reduce_add` and `reduce_mul` are checked too, and a constant
  that overflows is `L0397`. Upgrade code that wraps on purpose, such as a hash
  or a random number generator, to the new wrapping operators, and code that
  tested a byte range by subtraction to comparisons:

  ```loke
  // before
  hash = (hash ~ u64(b)) * FNV_PRIME;
  is_digit := c - '0' < 10;
  // after
  hash = (hash ~ u64(b)) *% FNV_PRIME;
  is_digit := c >= '0' && c <= '9';
  ```

  Generic code over `interfaces.Integral` that writes the constant `T(0) - T(1)`
  no longer compiles for an unsigned `T`; test
  `math.wrapping_add(a, T(1)) == T(0)` for -1.

- A negative signed shift count panics with `negative shift count` instead of
  being read as a count beyond the width, so `1 << k` for `k := -1` no longer
  answers 0. A constant negative count of a signed type, or a constant SIMD
  count with a negative lane, is `L0356`, as an unfixed one already was. Upgrade by keeping the count non-negative, or by
  shifting by `math.wrap(uint, count)` where the old reading was meant.

- `fs.Metadata.modified` is an `Option(time.Time)` instead of an `i64` of
  nanoseconds since the Unix epoch, and `.none` where the filesystem keeps no
  such time, which used to read as 0. Code comparing it with a number is
  `L0354`. Upgrade by unwrapping it and comparing times, or by asking for the
  count:

  ```loke
  // before
  if (info.modified > cutoff_nanoseconds) { ... }
  // after
  modified := info.modified or_else time.Time{};
  if (modified.unix_nanoseconds() > cutoff_nanoseconds) { ... }
  ```

- An extension comparison on an anonymous record no longer replaces a built-in
  one: a structural type counts as built-in for operator shadowing, as `[2]int`
  does. An extension `==` or `!=` on a record whose fields are all comparable,
  and an extension `<`, `<=`, `>`, or `>=` on one whose fields are all ordered,
  is now never chosen, with no diagnostic. One the language does not define,
  such as `<` on a record with a union field or `==` on one with a slice field,
  is still chosen. Upgrade by declaring a struct for a record that needs its
  own comparison, or by calling the procedure by name:

  ```loke
  // before: picked the extension
  impl Span { same :: operator(==) proc(a, b: Span) -> bool { ... } }
  if (a == b) { ... }
  // after
  if (Span.same(a, b)) { ... }
  ```

- `LOKE_BUILD_MODE` has a third value, `.Test`, for a test build, so a switch
  over it that names every value without a `case:` is not exhaustive
  (`L0366`). Upgrade by adding `case .Test:`, or `case:` for the builds the
  switch does not care about.

- `sync.Atomic(T)`'s and `thread.Mutex(T)`'s `value` fields are
  [`@(synchronized)`](design.md#synchronized): outside their packages they are
  reached only with exclusive access. A read through a read-only `^Atomic(T)`,
  a value parameter, or a read-only binding is `L0722`, and a read through the
  owner while it is lent read-only is `L0511`, since an atomic operation
  through that loan may be writing it. Upgrade by calling `load()`, or by
  reaching the atomic through `^mut`:

  ```loke
  // before
  peek :: proc(hits: ^sync.Atomic(int)) -> int { return hits.value; }
  // after
  peek :: proc(hits: ^sync.Atomic(int)) -> int { return hits.load(); }
  ```

- `thread.spawn` checks the argument it moves to the new thread
  ([Concurrency and the memory model](design.md#concurrency-and-the-memory-model)).
  One that holds or reaches a `@(thread_affine)` type is `L0724`; one reaching
  a `dyn` or `any_view` the call did not make is `L0725`, since the erased type
  cannot be checked; and an owner backed by an allocator the spawning
  procedure received is `L0726`. A borrow of `thread_local` storage was already
  rejected and now says why. Upgrade by passing the concrete value, converting
  it to the view at the call, or building the owner with the default
  allocator:

  ```loke
  // before
  start :: proc(allocator: mem.Allocator) {
      jobs: [dynamic]Job via allocator = {};
      worker := thread.spawn(run, move(jobs));
  }
  // after
  start :: proc() {
      jobs: [dynamic]Job = {};
      worker := thread.spawn(run, move(jobs));
  }
  ```

- `parallel` and `spawn` are contextual keywords at the start of a statement
  ([Keywords](grammar.md#keywords)). A statement that begins with a composite
  literal of a type named `parallel` followed by a selector or a call, such as
  `parallel{1}.run();`, now parses as a `parallel` block and is `L0261`; so is
  `parallel(T){1}.run();`. Every other use of the name, `parallel(pool);` and
  `x := parallel{1};` among them, means what it did. Upgrade by
  parenthesizing the literal:

  ```loke
  // before
  parallel{1}.run();
  // after
  (parallel{1}).run();
  ```

- Assigning a record that holds an allocator handle but no owner to a field
  now keeps the handle's allocator region, as assigning the handle itself
  does. An owner allocated with it can no longer outlive that region; for
  example, `state.handle = Handle{arena.allocator()};` followed by
  `return make([dynamic]int, 1, state.handle.allocator);` reports `L0592`.
  Upgrade by allocating the returned owner from an allocator that outlives
  the procedure.

- An owner a call leaves through a `^mut` pointer stored in a record now keeps
  its region when the call receives that record through a held `^mut`
  pointer, as it does when the argument is `&mut record`. Resetting the region
  while the owner is live reports `L0537`; for example,
  `pointer := &mut outer; fill(pointer, allocator); free_all(allocator);`
  followed by a use of what `outer.pointer` points at. Upgrade by finishing
  with the owner before the reset.

### Added

- The release zip includes `editors/`, so the VS Code extension that starts
  `loke-lsp` can be built from the bundle.
- [`@(intrinsic)`](design.md#intrinsic) declares a name the compiler supplies
  to a bundled package in that package's source, with a `---` body, so its
  signature and doc comment appear in `-doc` and `api.loki`. `core:mem`,
  `core:unsafe`, `core:sync`, `core:log`, `core:math`, `base:runtime`, and
  `base:meta` now declare every public name the compiler gives them: `mem.Arena`
  and its constructors, `unsafe.transmute`, `math.wrap`, `log.Level`, and the
  rest, which `-doc` and the interface files used to leave out. The compiler
  checks each declaration against what it supplies (`L0734` to `L0737`).
  `Name :: ---;` without the attribute is `L0262`.
- `sync.Lazy(T)` makes a value on the first `get` and shares it with every
  later caller, on any thread. Its value is synchronized storage, so tasks may
  make it on first use where a `Once` action writing a global is rejected;
  what `init` writes is still checked, and the value is checked as a channel
  item is: process-lifetime borrows, no `thread_local` borrow, nothing
  `@(thread_affine)`. See
  [Atomic operations and Once](standard-library.md#atomic-operations-and-once).
- [Structured concurrency](design.md#structured-concurrency): a
  `parallel { ... }` block runs each `spawn`ed call on a thread of its own and
  waits for all of them on every way out of the block, a panic included. A
  task may borrow the caller's locals, which stay lent to it until the join,
  and `spawn result = call;` hands its result back through a local declared
  before the block. A spawned call may take a variadic pack, which belongs to
  the task, as `spawn total = sum(1, 2, 3);` does; an element copied from a
  place the parent keeps is shared with the task (`L0729`). The compiler rejects a task that shares something
  writable (`L0729`), writes or reaches through a global while tasks run
  (`L0731`), hands a `thread_local` borrow across (`L0730`), or uses an
  allocator another task may be using (`L0732`). `examples/parallel.loke`
  sorts and sums with them. A program with a `parallel` block depends on
  `core:thread` without importing it.

- `spawn` may call a procedure value, as in `spawn result = f(x);` where `f`
  is a parameter, a local chosen at runtime, or a field
  ([Spawn statements](design.md#spawn-statements)). The parent evaluates the
  value before the arguments and the task keeps it. The task checks take the
  effects of every procedure of its type the program uses as a value, and a
  rejection names the ones that cause it. A foreign procedure value is still
  not spawned (`L0728`).

- `spawn` may call through a `dyn` view converted at the spawn, as in
  `spawn r = (dyn Shape)(&s).area(2);` or through a callable view's `call`
  ([Spawn statements](design.md#spawn-statements)). The view is checked as
  the call's receiver argument, so what it views is borrowed until the join,
  shared read-only or lent exclusively by a `dyn mut` view, and must be able
  to cross to the task. A view that arrives erased, as a parameter or stored
  local, is rejected (`L0729`). A rejection for a global names each type
  filling the slot that writes or reaches it.

- `thread.Monitor(T)` is a mutex whose holder can wait for the guarded value
  to reach a state ([Monitors](standard-library.md#monitors)).
  `monitor.lock_when(ready)` sleeps until `ready` answers `true` for the
  value and returns the guard still holding the lock; dropping a guard on
  which `get` was called wakes the waiters to ask again, and one used only
  through `read` wakes no one. `close` ends every wait whose condition is
  false, returning `.none`, while a closed monitor can still be drained.
  A `Monitor_Guard` is thread-affine, as a `Guard` is.

- `thread.Ring(T)` is a bounded queue from one sender to one receiver whose
  `try_send` and `try_receive` poll without locking or allocating, for a
  thread that must not wait ([Rings](standard-library.md#rings)). `split` makes
  its only `Ring_Sender` and `Ring_Receiver`; each operation needs its
  endpoint `inout`, so two tasks cannot share one, and both endpoints are
  `@(wakes_on_drop)`. `examples/mixer.loke` takes its commands from a ring.

- `parallel (&pool) { ... }` runs a block's tasks on a `thread.Pool`, a fixed
  set of persistent workers, instead of a thread each
  ([Parallel blocks](design.md#parallel-blocks),
  [Pools](standard-library.md#pools)). A worker joining a block of its pool
  runs the block's queued tasks, and their pooled descendants, meanwhile, so
  nested fork/join work finishes even with one worker. Such a join counts as
  writing the `thread_local` storage those tasks write, so a borrow of it the
  parent holds across the join is rejected with `L0512`.
  `examples/mixer.loke` opens a pooled block per audio buffer.

- `thread.Channel(T)` is a bounded queue between tasks
  ([Channels](standard-library.md#channels)). `channel.split()` makes the
  first `Sender` and `Receiver` together, `fork` adds endpoints, and a side
  closes when its last endpoint drops or at `close`. `send` waits for room and
  `try_send` does not; both hand an item back in `Unsent` when they fail.
  `receive` and `try_receive` take items in FIFO order, and
  `foreach (item in receiver)` receives until the stream ends.
  `examples/channels.loke` builds a worker pipeline.

- [`@(wakes_on_drop)`](design.md#wakes_on_drop) marks a struct or union whose
  drop may wake threads waiting on what it borrows; `thread.Guard`,
  `thread.Monitor_Guard`, and the channel endpoints carry it. A value that is,
  holds, or reaches one and is kept past a `parallel` block's join, while a
  task of the block may borrow the same storage, is rejected with `L0733`:
  for example, a sender declared before the block while a task drains its
  channel ([Releasing before the join](design.md#releasing-before-the-join)).

- Three attributes declare thread facts, so the compiler names no concurrency
  type or procedure. [`@(synchronized)`](design.md#synchronized) marks a field,
  or a file-scope or `static` variable, whose package synchronizes every access
  to it (`L0721` elsewhere). [`@(thread_affine)`](design.md#thread_affine) on a
  struct or union keeps its values, and everything holding or reaching one, on
  the thread that made them. [`@(cross_thread)`](design.md#cross_thread) on a
  `move` parameter that is also `@(escape=static)`, or on one of procedure
  type, makes a user-written thread wrapper checked and warned about as
  `thread.spawn` is (`L0723` on any other parameter). It is part of the
  procedure type.

- `xs.split_at_mut(mid)` on a `[]mut T` returns two mutable halves,
  `(left: []mut T, right: []mut T)`, usable at once and checked as one
  reborrow of `xs`, so `left, right := xs.split_at_mut(xs.len() / 2);`
  works ([Splitting a mutable slice](standard-library.md#splitting-a-mutable-slice)).
  It also runs at compile time.
- `xs.chunks_mut(n)` on a `[]mut T` yields consecutive mutable chunks of `n`
  elements, which stay usable after the loop advances and after it ends while
  `xs` stays suspended ([Chunks of a mutable slice](standard-library.md#chunks-of-a-mutable-slice)).
  A length below one panics.

- `lokec <dir> -api` writes each package's interface file, `api.loki`, in its
  directory: the public API as Loke source, each declaration after its doc
  comment, written `//`, and without a body, with a file-scope `when` kept whole so the file
  is the same on every target. A private declaration that a shown one names,
  such as a private type a public procedure returns or the members of a public
  overload group, is shown after a comment saying it is private. `-api-check`
  writes nothing, lists the files `-api` would change, and exits 1 if there are
  any. No compilation reads an interface file. Every package in `core/` and `base/` has one checked in, and
  the test suite checks that each is current; to use a package, read its
  `api.loki`. See compiler-guide.md "Interface files".
- `math.fma(a, b, c)` and `math.fma_f32` compute `a*b + c` with a single,
  correct rounding, the same with every C library. The compiler never fuses a
  written `a*b + c`, so this is the way to ask for it. See
  standard-library.md "`core:math`".
- The wrapping operators `+%`, `-%`, and `*%`, with `+%=`, `-%=`, and `*%=`,
  keep the low bits of an integer sum, difference, or product, signed or
  unsigned, and never panic. They bind as `+`, `-`, and `*` do, apply lane by
  lane to integer SIMD vectors, and can be declared with `operator(...)` and
  forwarded with `delegate`. `math.wrapping_add`, `wrapping_sub`, and
  `wrapping_mul` remain as their procedure forms. See design.md "Integer
  overflow".
- Test procedures: `@(test)` marks a file-scope procedure that takes no
  parameters and returns nothing or a fallible union such as `Status(E)`, so
  `or_return` works in a test. `lokec <package> -test` builds the root
  package's tests into `<input>.test.exe` and runs each in a process of its
  own, so a panic or failed `assert` ends only its test. It prints `ok` or
  `FAIL` for each, with a failing test's output and location, and exits 1 when
  one fails. The executable also runs one test by name. A test is checked in
  every build but emitted only in a test build, and no code may call it
  (`L0616`); its signature rules are `L0615`. `-build-mode=test` builds the
  executable without running it. See design.md
  [Test procedures](design.md#test-procedures) and compiler-guide.md
  [Running tests](compiler-guide.md#running-tests).

- Success returns: in a procedure returning a fallible union, `return value;`
  builds the success variant when `value` is not the whole result, so
  `return n;` means `return .ok(n);` in a `Result(int, E)` and
  `return .some(n);` in an `Option(int)`. `return;` returns a success that
  carries nothing, as in `Status(E)`. Failures stay written as `.err(e)`, `nil`
  is never wrapped, and a body whose result names a generic argument with a
  failure payload, such as `Result(T, E)`, still writes `.ok(value)`. See
  design.md [Success returns](design.md#success-returns).
- Anonymous unions: `(found: int | missing:)` is a union with no declaration,
  identified by its ordered labels and payload types as an anonymous record is
  by its fields. It is built, switched over, compared, and printed as a named
  union is, and serves as a `Result`'s error type, which `or_return .label`
  wraps into. It carries no attributes, so it has no zero value and is never
  fallible. A trailing `|` is accepted. See design.md
  [Anonymous unions](design.md#anonymous-unions).
- Widening by label: an anonymous union converts implicitly to one that has
  each of its alternatives, with the same label and payload type, in any order.
  A bare `or_return` therefore propagates a helper's smaller error set into a
  larger one, and declarations, assignments, arguments, returns, comparisons,
  and explicit conversions accept it too. A place is copied as any copy into
  its destination is, a last use or a temporary transfers, and the
  diagnostic for a union that does not widen names the alternative it lacks.
  See design.md [Widening by label](design.md#widening-by-label).
- Expanded switch cases: `case $variant(payload):`, the last case of a switch
  over a union, stands for one case per variant no earlier case names. Its body
  is checked once per variant, so a payload lacking what the body uses is a
  diagnostic naming that variant, and `variant` is a compile-time
  `meta.Variant` with the label, the payload type, and the index. A payloadless
  variant binds `Unit{}`. `variants_of(T)` returns a union's descriptors in
  declaration order. See design.md
  [Per-variant switch cases](design.md#per-variant-switch-cases).
- Union argument expansion: `handle(..event)` over a union calls `handle` with
  the active payload as the argument named by its label, so a procedure group
  dispatches by label, `(left: int | right: int)` included. Every variant is
  checked, a place lends its payload and a temporary or `move` gives it up,
  and the call's value is the selected call's. See design.md
  [Union argument expansion](design.md#union-argument-expansion).
- Structural patterns: a generic parameter may bind `$` names inside an
  anonymous record or union, as in `proc(found: (some: $T | none:))` and
  `proc(pair: ($A, $B)) -> (B, A)`. A record pattern needs its labels in
  order, and an unlabelled one takes a labelled record by position. A union
  pattern takes an argument whose alternatives it has, in any order, and binds
  each payload by its label. See design.md
  [Specialization](design.md#specialization).
- `fmt.zero_pad(value, width)` pads an integer with zeros after its sign, so
  `zero_pad(7, 3)` prints `007` and `zero_pad(-7, 3)` prints `-07`; a `+`
  from a type's own `format` is a sign too, and a `rune` is rejected. It returns
  a `Padded(T)` like `pad_left`, honours the call's base, and builds forms such
  as `15.10.2026` from `core:time`'s accessors. See standard-library.md
  [`core:fmt`](standard-library.md#corefmt).
- `is_union(T)`: a compile-time `bool` built-in that is true for a union,
  named or anonymous. A generic procedure with an expanded case or a union
  argument expansion can bound `where is_union(E)`, so a non-union argument is
  reported at the call instead of inside the instance. See design.md
  [Built-in procedures](design.md#built-in-procedures).
- `examples/orders.loke` checks orders against a stock list with anonymous
  unions: an error set per helper, widened by label into the caller's, and a
  labeled layer kept with `or_return .order`.
- `loke-lsp.exe`, a Language Server Protocol server shipped beside `lokec.exe`.
  It publishes the diagnostics `lokec` reports for open documents, including
  unsaved edits and the packages they import. It also answers hover,
  go-to-definition, document symbols, completion, signature help, find
  references, and rename from the checked program. After an edit it rechecks
  only from the first package the edit reached. Formatting a document gives
  the layout `lokec -fmt` writes, and the `loke.documentation` command
  returns the page `lokec -doc` prints, both from unsaved text. See
  [Language server](compiler-guide.md#language-server).
- `editors/vscode`, an extension for VS Code and VSCodium that highlights Loke
  source and starts `loke-lsp`. See [its README](editors/vscode/README.md).
- `core:random`: the xoshiro256++ generator `Xoshiro256`, seeded from a `u64`,
  a saved state, or the operating system, with `split` and `jump` for parallel
  streams. It provides integer ranges, floats, booleans, `bernoulli`, `fill`,
  `shuffle`, `choose`, and ziggurat `normal` and `exponential`. `fill_secure`
  and `secure_u64` read the operating system's secure generator. A seeded
  generator gives the same values in every release. See
  [`core:random`](standard-library.md#corerandom) and `examples/dice.loke`.
- `core:random`: a second generator, `Pcg64` (numpy's PCG64DXSM), with
  `advance` to move a stream any distance. New distributions `log_normal`,
  `gamma`, `beta`, `chi_squared`, `student_t`, `geometric`, `poisson`, and
  `binomial`; `Weighted`, an alias table that picks indices in proportion to
  weights; and `sample`, which draws elements without replacement.
- `core:time`: `now`, a monotonic `Tick`, and `sleep`; `Duration`, printed in
  a short form such as `1h30m` or `153ms`; `Time`, an instant in Unix
  nanoseconds; the calendar types `Date`, `Time_Of_Day`, `Date_Time`, and
  `Offset_Date_Time`, with ISO weeks and month arithmetic; and ISO 8601 and
  RFC 3339 text, printed through `fmt` and read back by `parse_time` and its
  siblings, in the extended or basic format. A leap second reads as second
  59 wherever the UTC minute is 59, and a duration's fraction counts in full
  however long it is. See [`core:time`](standard-library.md#coretime) and
  `examples/timestamps.loke`. Time zones are not included yet.
- `examples/corpus_runner.loke` reports on stderr how long the run took and
  which case was slowest.

### Changed

- A `dyn` view that arrives erased, as a parameter or a stored local, may now
  be passed to a task or go through a spawned call
  ([Sharing with tasks](design.md#sharing-with-tasks)), and so may a value
  holding one passed to `thread.spawn`. It is checked through every type the
  program converts to its interface application: a read-only view is
  rejected with `L0729` if one of them reaches a mutable carrier, however the
  view is passed, and any view with `L0724` if one is thread-affine, and
  both diagnostics name that type. A call through it takes the effects of
  every type filling its slot. An `any_view` or `dyn fmt.Formattable` that
  arrives erased is still rejected.

- A read-only `dyn` view stored in a global no longer rejects every task that
  reads through it ([Globals while tasks run](design.md#globals-while-tasks-run)).
  It reaches what each type the program converts to its interface application
  reaches, so a registry of views of plain records, or a callable view
  holding a procedure, may be read while tasks run. A view that may view a
  mutable carrier, a `dyn mut` view, or a capture literal with a `&mut`
  capture is still rejected with `L0731`, which now names that type, as is a
  `dyn fmt.Formattable`, whose witnesses printing builds later.

- Removed `concurrency-proposal.md`, since structured concurrency is built.
  The ring algorithm and its validation moved to
  [The ring algorithm](standard-library.md#the-ring-algorithm), and the
  undecided extensions to
  [Later concurrency extensions](open-questions.md#later-concurrency-extensions).

- Narrowed concurrency milestone 10
  to start with procedure values using the existing task machinery, followed
  by erased callable data and per-call effect precision. Clarified the spike's
  coverage and the validation required before each step ships.

- `L0729` for a view that arrived erased no longer says to move it into the
  task, which hides its captures just the same (`L0725`): it suggests the
  concrete value or a conversion at the call. For a callable view made at
  the call that reaches a `&mut` capture, it suggests moving the callable
  through a generic `Callable` parameter, since the view only borrows it.

- Global write, reach, and allocator-use effects are now per call
  ([Global write effects](design.md#global-write-effects)). A call passing a
  procedure for a parameter its callee calls, directly or through another
  helper, takes that procedure's effects instead of those of every procedure
  of its type the program uses as a value; so does a call through a local
  that may hold only some procedures, and a `dyn` view converted where it is
  called runs only its concrete type's method or the procedure it holds. So
  `spawn r = apply(step, 1);` is accepted while the program elsewhere calls
  `apply(tally, 1)` with a `tally` writing a global, and so is a borrow of
  that global kept across `apply(step, 1)`. A task rejected for a global now
  names the callback that writes or reaches it and the parameter it was
  passed for, as in "`apply` may call `tally` for `f`", and one through a
  view converted at the spawn names the method or capture literal it runs.
  A `dyn proc` parameter or local is followed the same way: given a view
  converted from a named procedure or a capture literal, a call takes only
  that procedure's or the literal's effects, so `apply(step, 1)` with
  `apply :: proc(f: dyn proc(n: int) -> int, n: int)` is accepted as a task
  beside a serial `apply(tally, 1)`.

- Revised the deferred [ring proposal](standard-library.md#the-ring-algorithm)
  to recommend a spare-slot SPSC queue with bounded indices, separate closure
  flags from hot index cache lines, and require target validation before a
  wait-free claim.

- Revised the unimplemented [concurrency proposal](standard-library.md#corethread):
  paired channel setup and explicit endpoint duplication, monitor shutdown
  contracts, a bounded join-check specification, and a deferred polling-only
  ring. The delivery plan separates compute pools from real-time handoff.

- Compiler provenance now saturates target and allocator-region facts by
  replaying frozen per-body operations. Checked call inputs retain argument
  order and delayed receiver captures; final borrow, reset, cleanup, and task
  events are built once after those facts settle.

- Edited the [language specification](design.md#contents) for clarity and
  concision, separating rules from exceptions and consolidating repeated
  explanations. Language behavior, section headings, and examples are unchanged.

- Revised the structured concurrency proposal
  to check transfers in both directions, global aliases, and allocator cleanup,
  and to handle worker failures explicitly after joining. The proposed syntax
  is now `spawn result = call;`, initially limited to dead outer locals and
  statically known callees. Task-start failure, cancellation-aware shutdown,
  and pool progress have explicit contracts and staged implementation plans.
  This remains a design proposal; accepted language behavior is unchanged.

- Revised the structured concurrency proposal again after a
  follow-up review.
  It closes two race holes (pool helping against thread-local borrows, and
  plain reads of shared atomics), copies plain arguments into tasks, specifies
  `chunks_mut`, lets tasks log and print, and records the open
  thread-contract questions. Still a proposal only.

- Made the structured concurrency proposal
  ready for implementation.
  It declares synchronized state with `@(synchronized)` and thread-crossing
  parameters with `@(cross_thread)` instead of recognizing names, defines the
  new effect summaries and the lowering onto `core:thread`, and plans five
  milestones with their spec, compiler, and test changes. Accepted language
  behavior is unchanged.

- The language server's `loke.documentation` command answers with the
  interface file `-api` writes for the document's package, instead of the
  `-doc` Markdown page for its root. The VS Code extension's **Loke: Show
  Interface**, formerly **Show Documentation**, opens it as a Loke document,
  and the extension treats an `api.loki` as Loke without the server checking
  it.
- `lokec -doc` writes its code blocks as ` ```loke ` rather than ` ```odin `,
  as hover already did, and so does every Markdown file in the repository. The
  VS Code extension highlights a ` ```loke ` block in a Markdown file's source.
- Any reserved word may name a member: a field, an enum member, a union
  variant, a record type's label, an `impl` member, or an interface `slot`,
  so `token.type`, `Kind.default`, `.map`, `a.union(b)`, and the associated
  type `Thing.map` in an annotation are accepted; a keyword still never names
  a local, a parameter, or a file-scope declaration.
  `dynamic`, `hook`, `operator`, `via`, and `where` are contextual keywords,
  ordinary names outside their own positions; `[dynamic]T` is always a dynamic
  array, so a length named `dynamic` is written `[(dynamic)]T`. Rename in the
  language server can now rename a member to or from a reserved word. See
  grammar.md [Keywords](grammar.md#keywords).
- An `impl` on an anonymous record or union, naming the shape or an alias of
  it, is specified as an extension: it reaches every spelling of the shape in
  its package and no other package's method lookup, and cannot add a hook. A
  hook on an anonymous record now says that no package declares it and suggests
  a struct. See design.md
  [Methods and implementation blocks](design.md#methods-and-implementation-blocks).
  Anonymous unions, new in this release, follow the comparison rule of the
  upgrade note under **Breaking changes**: an extension `==` or `!=` on one
  whose payloads are all comparable is never chosen, and its built-in equality
  compares by label and payload.
- A union argument expansion over a place whose selected member takes its
  payload by `move` now says the call is written `..move(...)`, rather than
  numbering an argument the call does not write.
- Removed completed review reports and their documentation references.
- A statement the parser cannot finish, such as `value.` or `call(first, `,
  is still checked so editors can see its names and types; its syntax error
  stays the only diagnostic it produces. A missing name after `.` is no longer
  also reported as a missing member.
- `-fmt` on a line holding many statements, `-doc` and hover documentation
  for files with many documented declarations, and programs declaring many
  procedures of the same shape no longer take time quadratic in their size.
  A compile-time `sort` is a merge sort charged against the evaluation step
  budget, so sorting thousands of constants stays fast.
- Global write effects settle by revisiting only the callers of a procedure
  whose set grew, so a long call chain declared caller first no longer
  compiles in quadratic time.
- An expression built on a parenthesized one counts that operand's depth
  against the nesting limit, so `((x.a.a ... ).a.a ... )` deeper than it is
  `L0222` instead of a stack overflow while checking.
- `slice.min` and `slice.max` copy only the element they return, instead of
  every improving candidate. `Bit_Set` and `Enum_Array` iteration no longer
  rebuilds the member table at every step, `Small_Array` queries no longer
  copy the whole array, and `strings.repeat` of empty text returns at once
  for any count.

### Fixed

- `xs.split_at_mut(mid)` and `xs.chunks_mut(n)` reborrow `xs` as it was
  evaluated before the argument
  ([Splitting a mutable slice](standard-library.md#splitting-a-mutable-slice)). An
  argument that rebinds `xs`, as `replace(inout xs, other)` may, made the
  compiled program split the new slice instead; compile-time evaluation was
  already right.
- A `dyn` slot call through a view that is not a named local, such as
  `(dyn Shape)(&s).area(scale = 2)`, a field, a call's result, or a generic
  receiver, is checked as one through a local is
  ([Borrowed dynamic interface values](design.md#borrowed-dynamic-interface-values)).
  Named arguments bind by the slot's parameter names, as they do in
  `(dyn Shape).area(view, scale = 2)`; they were rejected (`L0392`, `L0371`). A mutating slot may be called on a `dyn mut` view converted in
  place, so a task may call one, as in
  `spawn r = (dyn mut Shape)(&mut s).grow(1);`; it was `L0359`. Naming a
  mutating slot through a read-only view is the capability error `L0643`, and
  a name no slot has is `L0467`, as through a local; both were a missing
  member (`L0363`).
- A borrow or region error found in the body of a generic instance, such as
  a library's, names the call that selected the instance
  (`while instantiating ...`), as the checker's errors there already did.
- A task may make, drop, and upgrade `Shared(T)` and `Weak(T)` handles the
  default provider backs, as it may a `Box(T)`. Dropping a handle was taken to
  free in an unknown region, since the handle frees through the allocator it
  reads back from its control block, so a second such task was rejected
  (`L0732`). A handle now frees in its own region, and one an arena backs
  still reserves that arena, as does what its payload's drop hook allocates.
- A case binding over a subject reached through a pointer, as in
  `switch (p^)` or `switch (holder.slot)` on a `^Holder`, names the subject's
  storage, so `return &value` from such a case is accepted when the subject is
  the caller's, as [Switch ownership](design.md#switch-ownership) specifies.
  It was rejected as a borrow of the binding (`L0526`).
- The join check (`L0733`) tells two parameters, or a parameter and a global,
  apart by type: a kept channel or ring endpoint, or a guard, no longer
  conflicts with a task borrowing a parameter whose storage cannot hold, lie
  within, or reach what it borrows. An audio loop taking
  `commands: move thread.Ring_Receiver(Command)` beside
  `voices: []mut Voice` and rendering `voices` in tasks is accepted
  ([Releasing before the join](design.md#releasing-before-the-join)).

- A spawned call through a `dyn` slot returning the worker's `thread_local`
  storage, as in `spawn answer = (dyn Getter)(&number).get();` where `get`
  returns `&counter`, is now rejected (`L0730`), as through a procedure value.

- A spawned call's temporaries belong to its task, as
  [Spawn statements](design.md#spawn-statements) says: `spawn a =
  count(make_bag());` with a managed parameter, `spawn b = make_bag().size();`
  with a `self: ^` receiver, and a `self: ^` slot of a view converted at the
  spawn are no longer rejected (`L0513`) at the join. A result borrowing such a
  temporary is still rejected.

- A `dyn` slot taking `self: ^` is given the viewed value, so a result
  borrowing it no longer borrows a view converted in place:
  `p := (dyn Pointing)(&h).at(); p^` is accepted.

- A procedure literal called where it is written, as in
  `(proc() { cache.clear(); })()`, now counts its global writes like any
  call through a procedure value: a borrow of the global kept across the
  call is rejected (`L0512`), and so is spawning it while tasks run
  (`L0731`). Its writes were missed, so both were accepted.

- An exit from a `parallel` block that a loop reaches before a `spawn` written
  below it now joins the tasks an earlier iteration started, as the checks
  see it: what those tasks borrow is still lent there, and a pooled block's
  `thread_local` effect applies there. `if (i == 1) { x = 5; return; } spawn
  read(&x);` in a loop is rejected with `L0512`, as it is with the exit below
  the spawn.

- A task's `thread_local` writes are no longer treated as the parent's: a
  borrow of a `thread_local` variable the parent holds across a `spawn`, or
  across the join of a block without a header, whose task writes that
  variable is accepted. The task writes its own thread's copy. A procedure
  whose bare block's task writes `thread_local` storage no longer counts as
  writing it either.

- The join check (`L0733`) counts only what a marked value itself borrows, not
  what a field beside it in an enclosing record borrows, also after the record
  converts to a distinct type: `Pair{first.lock(), &second}` kept past a block
  whose task locks `second` is accepted. A generic record whose type argument
  is marked still counts everything it borrows, since it may hold such a value
  where no field shows it.

- A `parallel` block directly inside another no longer reports `L0305` for
  the hidden scope local both blocks declare, which no source can name.

- Writing an allocator handle through a pointer, as in `pointer^ = arena.allocator();`,
  no longer reports `L0536`: a handle is not an owner, so only owners written
  through a carrier are checked against storage the body cannot name.

- A call that writes one field of a record argument now leaves its allocator
  regions at that field alone, through `inout` and through a mutable pointer.
  Returning another field afterwards no longer reports `L0592`.

- A container a call allocates into a record argument no longer lends its
  allocator region to the elements stored in it. Returning a static string
  from a `[dynamic]string`, map, or `Box` field that the call made from an
  arena no longer reports `L0592`.

- A call that copies one field of a record argument into another, through
  `inout` or a mutable pointer, now gives the copy only that field's
  allocator regions. Returning the copied field no longer reports `L0592`
  when the record also holds an unrelated arena handle.

- An owner extracted with `exchange` keeps its own allocator, so resetting an
  unrelated arena while it is live no longer reports `L0537`.

- Unwrapping a fallible box into a local now preserves its payload's carrier
  field paths, so calls no longer confuse read-only and writable sibling fields
  and spuriously reject later local writes with `L0536`.

- Read-only calls receiving an `or_else` success payload now preserve the
  parameter's weakened capability, avoiding spurious `L0536` errors on later
  writes to local storage. Fallbacks retain the same capability checks.

- Recursive owning containers containing carriers no longer make analysis grow
  unbounded carrier-position paths when repeatedly wrapping a moved value.
  Both target-storage paths and carrier-position paths now converge within the
  existing conservative projection budget.

- Taking a known local address no longer inherits uncertainty from carriers
  stored inside that local. Implicit `or_return` exits now discard abandoned
  argument temporaries before local cleanup, matching explicit returns while
  preserving the propagated error's dependencies.

- Returning a scalar computed from an arena-backed temporary, or continuing
  after a diverging conditional branch, no longer reports a spurious allocator
  lifetime error. Destructured declarations and assignments now use each
  field's copy plan and destination allocator while preserving logical copies
  of borrowed or shared storage.

- A transferred initializer with an unevaluated `via` containing a temporary
  allocator no longer triggers a compiler assertion or gains a dependency on
  that unused policy. A later copy still evaluates the declaration's policy.
- Independent implicit copies into static storage no longer fail owner-escape
  checks against the source allocation replaced by the copy. Retained logical
  copies still keep their source dependencies.

- Implicit union-widening copies in declarations and assignments now use the
  destination allocator for copied storage, allowing the source region to reset
  after its owners end. Logical copies still retain their source dependencies.

- Procedures with matching container or record result contracts can again
  substitute for one another without a spurious `L0645`. Backing allocations
  and payload fields are checked independently; mismatched fields still fail.
- Allocator handles held in managed records or shared payloads no longer
  incorrectly block `free_all` with `L0537`. Their provider must still outlive
  their use. Switch payload and field bindings preserve the same handle/owner
  separation as successful unwrapping, avoiding spurious `L0536` stores.
- Unboxing no longer retains the released box allocation's region. Implicit
  union payload copies and `as` copies use the destination allocator for new
  storage, while strings and other retained payload allocations keep their
  source regions. Independent copies no longer cause spurious `L0537` resets.

- Shared payloads containing allocator handles and `Result` success records
  with owning error types no longer incorrectly report `L0536` for a handle
  backing an owner. Actual payload owners and error allocations retain their
  escape and reset checks, including after unwrapping or cloning.
- Generated clones of nested arrays, maps, and boxes distinguish the source
  container's allocation from retained element storage. A clone containing
  only independent elements no longer incorrectly blocks resetting the source
  allocator with `L0537`.

- Unwrapping a fresh record from `Option` or `Result`, or copying it from a
  temporary record field, no longer treats an `@(escape=static)` allocator
  handle as backing the record itself and incorrectly reports `L0536`.
  Moved records retain their own escape contracts through the same operations.
- Managed records with only unmanaged fields again obey a moved parameter's
  escape contract. Storing one in caller-owned storage without
  `@(escape=stored)`, or in static storage without `@(escape=static)`, reports
  `L0536`, including through locals, nested records, and returned values.
  Use the appropriate annotation when retention is intended. Allocator-handle
  fields remain separate from the record's own dependency.
- A whole-record store no longer treats an allocator handle's region as
  backing the record's owners. A record containing an `@(escape=static)`
  handle and an owner built with `mem.default_allocator()` can enter static
  storage in one assignment, as separate field writes already could. This
  also works through writable arguments, forwarding calls, local records,
  and returned records, including nested fields; owners still keep their
  own regions for escape and reset checks.
- A call that leaves only an allocator handle in a record holding owners, such
  as `set_allocator(allocator, &mut state)` writing `dst^.alloc = allocator`
  into a file-scope `state: State { items: [dynamic]int, alloc: Allocator }`,
  is no longer `L0536` for an owner escaping, directly or through a pointer
  held in a local. Assigning `state.alloc = allocator` was already accepted.
  Nor is one that also leaves an owner from an allocator that outlives the
  storage, as `dst^.items = make([dynamic]int, 2, owner_allocator)` beside the
  handle does, directly or through a procedure forwarding `dst`.
- A write through one field of a local record is no longer taken for a write
  into the caller's storage because another field holds a parameter's
  carrier: with `pair := Pair{box^.out, &mut local}`, an owner written
  through `pair.local^` from the caller's arena is no longer `L0536` at the
  call.
- A borrow written back below a provenance budget's cut, or stored through a
  carrier whose destinations a budget merged, no longer gets a definite
  `L0646`, `L0647`, or `L0730`. The message now says the value *may* be
  stored there or *may* reach the task, and a note names the limit, as
  [Minimum provenance precision](design.md#minimum-provenance-precision)
  requires. A merged stored value likewise *may* borrow the storage named.
  Below a cut or a recursive type, a write-back no longer lands in what a
  read-only pointer names, so replacing a recursive child's `view: ^int`
  with a `thread_local` borrow is no longer `L0647` when the old `view` named
  static storage.
- A `[]mut T` appended or inserted into a container that is used afterwards is
  no longer `L0641`. The operation's own read of its argument counted as a use
  of the carrier it had just stored, so `held.append(b)` followed by any use of
  `held` was rejected, and `chunks_mut`'s chunks could not be collected.
- One composite literal can no longer hold two mutable views of one carrier:
  `Pair{xs, xs}` and `Pair{&mut xs[:1], &mut xs[1:]}` for `xs: []mut int`
  were accepted, though [Weakening and reborrows](design.md#weakening-and-reborrows)
  makes each element a reborrow of `xs`. They are now `L0641`, as two such
  call arguments already were. Use `split_at_mut` for two halves. A record
  holding a mutable carrier is lent as the carrier is, so
  `Outer{Inner{xs}, Inner{xs}}`, `Outer{inner, inner}`, and `take(inner, inner)`
  for `Inner :: struct { a: []mut int }` are `L0641` too. The reborrow lasts
  until the literal is built, so a later element may not use the carrier
  either: `Pair{xs, write(xs)}` and `Wrapped{Inner{xs}, xs[0]}` were accepted
  and are now `L0641`.
- A carrier suspended by a read-only reborrow can be copied into another
  read-only carrier, as [Weakening and reborrows](design.md#weakening-and-reborrows)
  allows: `v1: []int = xs; v2: []int = xs;`, the same through assignment
  (`v1 = xs; v2 = xs;`), and two `Views{xs}` literals while both are live
  were `L0641`.
- A literal element that a later element writes keeps the read-only reborrow
  it held: with `view := View{xs}`,
  `held := Snapshot{view, replace(inout view.a, other)}` let `xs` be written
  while `held.first.a` still viewed it. That write is now `L0641`.
- A stored `any_view(xs)` borrows `xs`, as the implicit conversion does:
  `v = any_view(xs); xs = ys;` was accepted while `v` was live, and `v` then
  saw `ys`. It is now `L0512`.
- Two `any_view`s of one slice field, `v1: any_view = held.items;` and
  `v2: any_view = held.items;`, may be live together, as two of a slice
  local already could; the second was `L0641`.
- A local initialized or assigned from an explicit `any_view(make())` or
  `(dyn proc())(proc() capture(&mut n) { ... })` extends the temporary to the
  end of the block, as the implicit conversion does. Using the local was
  `L0513`.
- An identity conversion around an explicit erasure,
  `any_view(any_view(make()))` or `(dyn proc())((dyn proc())(...))`, extends
  the temporary as the single conversion does; using the local was `L0513`.

- `lokec -doc` no longer shows the members of a type private to the package,
  which no importer can reach, such as the 28 members of `core:time`'s `Text`
  and `Scanner`. A private declaration a shown one names is shown, marked
  private, such as the procedures behind `thread.spawn` and `fmt.Padded`'s
  `Fill`. It no longer shows the body of an operator or hook, such as
  `operator(<) proc(left, right: Date) -> bool { ... }`, the `//` comments
  inside an enum, a union, or a signature, or a field's `@(public)`, and a
  foreign block's members show its calling convention and result
  requirement.
- `lokec -doc` documents generic records and generic `impl` blocks. A generic
  struct's public fields were missing, so `container.Bit_Set` printed as an
  empty struct, and no member of a generic `impl` appeared, such as any of
  `Bit_Set`'s methods.
- `is_copyable(expression)` no longer moves out of its operand.
  `is_copyable(move(value))` emitted no move but left `value` dead, so its
  drop never ran and a later use was `L0500`. Its operand is now unevaluated,
  as `size_of`'s is.
- `process.output` ends the child as soon as reading its stderr fails, instead
  of first reading stdout to its end, which a child holding stdout open never
  lets happen.
- The standard logger holds a lock for each record, so records logged from
  different threads no longer split each other's lines. Spawning a thread that
  logs no longer warns `L0707` about the logger's storage.
- `strconv.parse_f64` and float formatting in `core:fmt` use a fixed "C"
  numeric locale. After foreign code set a decimal-comma locale,
  `parse_f64("1.5")` returned `1.0` and `fmt` printed `1.5` as `1.,5`. If the
  C library cannot create that locale, printing or parsing a float panics.
- `path.join` puts exactly one separator at each boundary, however many
  either part supplies, so joining onto an extended-length `\\?\` path, which
  `clean` leaves verbatim, no longer doubles it into an `Invalid_Path`.
- Complex division scales subnormal operands up first, so a quotient such as
  `s/(2s + s i)` is `0.4-0.2i` instead of `0.5+0.0i`. `Quaternion.inverse` of
  a quaternion with a subnormal largest component keeps its finite and zero
  components instead of turning them into infinities and NaNs.
- `term.begin_raw` saves the console mode after claiming raw mode rather than
  before, so a scope closing concurrently cannot leave the console raw after
  both scopes close.
- standard-library.md "Fixed-capacity arrays" describes `Small_Array`'s consuming
  `try_append` and `try_insert`, which drop the element on a capacity
  failure, instead of saying there are none.
- The operators a `delegate` generates are found from other packages, as
  hand-written ones are (design.md "Delegating operators"): `a + b` on an
  imported `distinct` type with `delegate(+)` was `L0318`. A `delegate` in an
  extension block still applies only in the package that declares it, as the
  block's other members do.
- `delegate(-)`, `delegate(+)`, and `delegate(~)` over a number generate the
  unary form as well as the binary one, so `-a` on a `distinct f64` with
  `delegate(-)` negates instead of being `L0392`.
- `swap`, `sort`, and `reverse_sort` on a `[]mut T` work during compile-time
  evaluation, rearranging the storage the slice views, as they do at run time.
  They were rejected with L0341, though an element assignment through the same
  slice was accepted. `slice.reverse` and `random.shuffle` now run in a constant
  initializer too.
- A compile-time `sort` or `reverse_sort` uses an element's own `<`
  (standard-library.md "Sorting slices"), as the runtime call does, rather than being
  rejected with L0341.
- A compound assignment through `operator([]=)` reads an index naming a
  scalar variable before its right operand, and a multiple assignment before
  any write (design.md "Evaluation order"): `grid[i] += bump(inout i)` wrote
  to the element `bump` moved `i` to. A literal value in a multiple assignment
  through a setter takes its destination's type, so `grid[0], x = 1, 2` with
  `i32` destinations is no longer `L0310`.
- An allocator argument a procedure never uses no longer backs its owning
  result (design.md "Allocator regions and region provenance"): returning
  `ignore(arena.allocator())` from the arena's scope was `L0592`. A call
  through a procedure value or a `dyn` slot still counts every allocator
  argument.
- A bundled package keeps its compiler-contributed members however an import
  reaches it: `import "core:Strings"` on Windows, or another `-collection`
  name for the bundled root, reported unknown library members. A package's
  key now spells its directory as stored, and `base` and `core` win a tie
  between collections sharing a root.
- A compile-time `foreach` binds a borrowed element in place, as at run time,
  so `&x` inside it is the element's address (design.md "Borrowing
  iteration"). It used to be a copy's.
- A `meta.Field` descriptor's `get` and `pointer` run at compile time; a
  constant computed through `field.get(&value)` was `L0344`.
- A defined built-in operation is never replaced by a user overload (design.md
  "Operator lookup and overload resolution"): `2 << n` with a signed `n`, and
  `+` over a `string` and a `string_view`, called a user `operator(<<)` or
  `operator(+)` declared for those operands.
- A local operator declaration shadows the package's for the rest of its
  block and is not seen outside it. It used to join the package's set, so
  both it and the outer one applied, in and after its block, and every use
  was `L0391`.
- An owned scalar `foreach` leaf or consuming case binding is dead after
  `move` or `drop` (`L0500`), as an owned local is; only managed ones were.
- A consuming switch's payload binding can be returned by value: returning a
  move-only `value` from `case .held(value):` was `L0502`.
- A procedure that writes an owner through a local pointer or slice set from
  a writable parameter, as `alias := dst; alias^ = make(..., alloc)` does,
  leaves it in the caller's argument with its allocator's region, so
  resetting that allocator while the argument is live is `L0537`. The write
  used to be invisible to the caller.
- A `meta.Field` descriptor's `get` and `pointer` take one positional value
  argument: `field.get(bogus = inout &value)` was accepted, and is now `L0371`
  or `L0370`.
- A record holding an instance whose `hook(copy)` its `where` clause excludes
  is move-only whichever was asked about first (design.md "where clauses"),
  so copying it is `L0503` rather than a runtime abort.
- A callback assigned in place of one whose result borrows a global must
  borrow no other global (design.md "Procedure result contracts"):
  `f := get_a; f = get_b;` with `get_b` returning `&b` let a later write to `b`
  pass while `f()`'s result still pointed at it. It is now `L0645`.
- A link that builds the bundled runtime's prebuilt objects waits up to two
  seconds for another process, such as a virus scanner, to release the new
  files before installing them. It used to give up at once, so that link and
  the next compiled the runtime sources again.
- `examples/lexer.loke` lexes `errdefer` as a keyword, as `lokec` does; it
  was an identifier.
- `perf.ps1` checks the output of every benchmark run, not only the fastest,
  and that each language-server edit reports an error exactly when it makes
  one. A median of an even number of samples is the mean of the middle two.
  A `-Baseline` that is also the `-Out` file is compared before it is
  replaced. A program or language-server operation that takes longer than
  `-TimeoutSeconds` (300 by default) fails the run instead of stalling it.
  Each record names a hash of the sources it measured, and a figure whose
  sources differ from the baseline's reads `(sources changed)` instead of a
  percentage.
- `perf.ps1` retries removing its work directory while Windows still holds
  an executable that has just run, and warns if it cannot. A failed removal
  used to replace the error that ended the measurement.

## [0.8.0] - 2026-10-13

### Breaking changes

- `or_return` takes an optional failure operand (design.md "The failure
  operand"), so a token that begins an expression after it now begins that
  operand: `f() or_return.len()` reads `.len()` as the operand, where it used
  to select a member of the success payload. Upgrade by parenthesising,
  `(f() or_return).len()`; the diagnostic suggests it. A binary operator after
  `or_return` is unchanged: `f() or_return + 1` is `(f() or_return) + 1`.
- `errdefer` is a keyword (design.md "defer statement"), so a name spelled
  `errdefer` must be renamed.
- The standard library's operations that produce nothing on success return
  `Status(E)` instead of `Result(Unit, E)` (design.md "Typed fallibility"):
  the compiler-defined `try_` container operations (`Status(Allocator_Error)`),
  `Small_Array`'s and `String_Builder`'s `try_` forms, and `fs`, `io`, `os`,
  `process`, and `term` procedures such as `fs.write_text`, `io.write_all`,
  and `File.close`. `or_return`, `or_else`, `switch`, and `== .ok` work on
  both, but code naming the old type, such as a helper taking
  `Result(Unit, io.Error)`, is `L0310`, and the success prints as `.ok`
  rather than `.ok(Unit{})`. Upgrade by writing `Status(E)` for
  `Result(Unit, E)`, and `.ok` for `.ok(Unit{})` or `.ok({})` in a procedure
  returning one.

- A switch case cannot bind `&mut` into storage reached through a packed
  struct (`L0614`, design.md "@(packed)"): `switch (holder.value) { case
  .num(&mut n): ... }` with `holder` packed wrote through a possibly
  misaligned address. An unmarked binding there, or over a field of a packed
  payload record, is a copy, and borrowing it with `&`, an `inout` or borrow
  argument, or a mutating method is `L0614` as `&holder.field` is. Upgrade by
  switching over a local copy and assigning it back:
  `value := holder.value; switch (value) { ... } holder.value = value;`.
- A `foreach` leaf over packed storage follows the same rule (`L0614`,
  design.md "@(packed)"). `foreach (&mut x in holder.arr)` with `holder`
  packed, and `foreach (tag, &mut n in records)` over packed records, wrote
  through possibly misaligned addresses and are now rejected; a read-only leaf
  there is an aligned copy, and `&x` or an `inout` or borrow argument of it is
  rejected as `&holder.field` is. Upgrade by iterating a local copy and
  assigning it back, or by indexing: `holder.arr[i] += 1`.
- A temporary that a local's declaration or whole assignment borrows lives
  until the end of the block holding the statement (design.md "Temporaries and
  procedure boundaries"). `p := &Point{1, 2}`, `items := [dynamic]int{1, 2}[:]`,
  `view: any_view = make_guard()`, and a capture literal stored into a
  `dyn proc` local can now be used on later lines, where they reported
  `L0513`; the borrow may pass through `&`, slicing, a field or element, or an
  implicit view conversion, but not through a call. Two upgrade notes: such a
  temporary is now dropped with the block's locals, so its `hook(drop)` runs
  at the end of the block rather than the statement; and slicing an array
  literal, as in `first([2]int{1, 2}[:])`, no longer outlives its statement
  when a call takes the slice, so keeping that call's result is `L0513`.
  Write a slice literal, `[]int{1, 2}`, which is still extended wherever it
  appears, or name the array.
- The handle types are capitalised like every other predeclared generic type:
  `Box(T)`, `Shared(T)`, and `Weak(T)` (design.md "Owned values", "Shared
  ownership"). Lower-case `box(value)` and `shared(value)` remain the
  constructors and no longer name types, so `x: box(Node)`, `shared(Node)` as
  a type, and any `weak(...)` are `L0713`. Upgrade by capitalising each type
  position: `Option(box(Node))` becomes `Option(Box(Node))` and
  `h: shared(Node) = shared(node)` becomes `h: Shared(Node) = shared(node)`.
  Diagnostics already printed `Shared(T)` and `Weak(T)`, and now print
  `Box(T)` too.
- Printing a `^T` or `^mut T` prints the value it points to, as a `box(T)`
  already did, instead of its address (standard-library.md "Printed forms"), so
  `foreach (entry in m) { fmt.println(entry.key); }` prints the key. Convert to
  `rawptr` to print an address; `rawptr`, `[^]T`, and procedures still print
  addresses.
- A `package main` cannot be imported (`L0719`), and its struct fields are
  public by default (design.md "Exported names"), so a program printing its own
  `Point{1, 2}` sees `Point{x = 1, y = 2}` rather than `Point{}`. Generated
  printing and `fields_of` from another package now show those fields; mark one
  `@(private)` to keep it out. Move code two programs import into a package of
  its own.
- `struct` declares and parentheses describe (design.md "Structs", "Distinct
  types"). A `struct { ... }` type written in place, such as a field's type or
  a generic argument, is now `L0717`: it was a new nominal type at each
  occurrence, equal to nothing, even an identical one beside it. `distinct`
  over an anonymous record, `Tag :: distinct (n: int)`, is `L0717` too.
  Upgrade a nested `position: struct { x, y: int }` to the anonymous record
  `position: (x, y: int)`, which reads and writes the same way
  (`w.position.x`), or declare the struct and name it when it needs private
  fields, hooks, `move_only`, or attributes. Upgrade `distinct (fields)` to a
  `struct` declaration. Inline `enum` and `union` types are unchanged.
- One matching form: the header binding `switch (name in subject)` is
  removed (design.md "Inspecting a union", "any_view type"). A case binds what
  it matches, `case .variant(name):` over a union and `case T(name):` over an
  `any_view` (`case ([]u8)(bytes):` for a composite type; a case that is
  already a type, such as `Option(int)`, names it). A grouped or
  default case reads the subject itself; over a temporary, bind it to a local
  first. `switch (x in set)` is now the membership test, without the second
  pair of parentheses, and the old spelling with an undeclared name is one
  diagnostic (`L0426`) naming the case form. Upgrade by moving the name into
  each single-variant case that uses it.
- A writable binding is spelled `&mut name`, as a mutable address is:
  `foreach (&mut value in items)` and `case .some(&mut node):` (design.md
  "Element bindings", "Switch ownership"). A bare `&name` binding, which read
  as a read-only pointer, is now an error (`L0247` in a `foreach` header,
  `L0367` in a case) naming the new spelling. Upgrade by inserting `mut ` after
  each such `&`; an `&name` in an expression is unchanged.
- A switch's default arm may be written `default:` (design.md "switch
  statement"); `case:` still means the same. `default` is now a reserved
  word: rename a variable, parameter, field, or procedure spelled `default`.
- References are never null and have no zero value: `^T`, `^mut T`,
  procedure values, `dyn I`, `any_view`, `cstring_view`, and `shared(T)`.
  `nil` is now only the null `rawptr` or `[^]T` (`L0310`), a reference is not
  comparable with `nil`, `dyn` views are not comparable at all, and a record
  with a reference field has no `{}` (`L0424`). Write `Option(^T)` with
  `.none` where a reference may be absent, construct records with every
  reference field, and give a global reference the type `Option(^T)`, since
  no address is a compile-time constant. `L0476` and the whole-body nil-use
  diagnostic `L0701` are gone with the null state they reported.
- Dereferences, indirect calls, and `dyn` slot calls no longer test for null.
  Instead, converting a null `rawptr` or `[^]T` to `^T` or `^mut T`, and a
  null `[^]u8` through `unsafe.cstring_view`, panics at the conversion. A
  foreign binding that types a parameter or result `^T` or `cstring_view`
  promises it is never NULL; one whose C side may pass NULL now uses
  `Option(^T)`.
- `core:log`'s published logger is `selected: Option(Logger)`; a logging
  provider is still a factory returning `Logger`.

- `nil` is no longer a value of a slice, `string_view`, `typeid`,
  `Allocator`, `Allocator_Error`, or `weak(T)` (`L0310`), and slices no
  longer compare with `nil`. Each of these types' zero is written `{}`, as for
  every other type, so write `xs: []int = {}` and `buffer: []mut u8 = {}`,
  and test emptiness with `xs.len() == 0`. `{}` at a slice type, formerly
  `L0479`, is the empty view.
- `type_info_of` is total: the zero `typeid` and an unknown id answer the
  entry whose kind is `Invalid` instead of `nil`. Test `info.kind ==
  .Invalid` where code tested `info == nil`.
- Generated printed forms changed, and standard-library.md "Printed forms"
  now specifies them. A float always shows a fraction or an exponent:
  `fmt.println(1.0)` prints `1.0`, not `1`, and exponents are bare, `1e21`
  and `1e-7` rather than `1e+21` and `1e-07`. A string or rune inside an
  aggregate prints quoted and escaped, `["a b", "c"]` rather than `[a b, c]`,
  and an anonymous record prints `(x = 1, y = "s")` rather than
  `(x: int, y: string){x = 1, y = s}`. A string printed on its own is
  unchanged. Update output a program or test compares against; a type that
  needs the old spelling declares its own `format`.

- An owner made from a temporary provider, as
  `make([dynamic]int, 0, 1, mem.Arena.init().allocator())`, cannot outlive
  the statement that made the provider (`L0537`); it used to be accepted and
  then used through a freed control block. Keep the provider in a local.
- A `defer free_all(allocator)` of the region backing the value being
  returned is `L0537`: the caller holds the result before deferred
  statements run. Reset the region elsewhere, or return a value from another
  region.
- `shared(T)` and `weak(T)` carry the borrows their payload holds, so
  `return shared(View{local[:]});` is `L0526` and writing `local` while a
  handle views it is `L0511`, as for the payload itself. Make the payload own
  its data, or keep the handle within the borrow's lifetime.
- A drop hook's writes to globals now also count where a temporary argument
  is dropped, where an expression statement or `_ = value` discards a result,
  and on a panic's unwind path (`L0512`), and a cleanup on that path that ends
  a region an owner still uses is `L0537`. A `defer drop(arena)` registered
  after an owner the arena backs is therefore rejected even when every normal
  exit drops the owner first: a panic in between would unwind the arena
  first. Register such a `defer` before the owners it outlives.
- A pointer to a temporary that holds borrows, as `return &Holder{view};`,
  now borrows the temporary too, so returning or keeping it is `L0526`; it was
  accepted when the temporary held a borrow of caller storage, and the caller
  received a pointer into a dead frame. Store the value in caller-owned
  storage, or return it by value.
- `new`, `new_clone`, `try_new`, `try_new_clone`, and checked `free` are gone,
  and with them `L0514`. A value that needs an allocation of its own is a
  `box(T)`: write `p := box(value)` or `box(value, allocator)` for
  `p := new_clone(value)` and drop the `free`, which the box does at scope
  exit; `try_box` replaces the `try_` forms; a box passes where a `^T` is
  wanted, and `&mut p^` is its `^mut T`. Raw storage that nothing owns is
  `unsafe.new(value, allocator)` or `unsafe.try_new`, which return a `[^]T`,
  released with `unsafe.free`, which now takes that `[^]T` or a `^mut T` and
  reports anything else as `L0493` (design.md "The `unsafe` package").
- An integer conversion `T(v)` keeps the value or panics: a narrowing that
  would lose bits, or a negative value converted to an unsigned type, used to
  keep the low bits silently. A constant that does not fit is `L0712`, typed or
  not, and so is one in compile-time evaluation. `Simd(U, N)(v)` checks each
  lane. Write `math.wrap(T, v)` where the low bits are wanted, `math.to(T, v)`
  to test whether a value fits, and `math.wrapping_add(a, b)` for the old
  signed-wrap idiom `i8(u8(a) + b)`.
- A slice expression `a[lo:hi]` is always a read-only `[]T`. A mutable slice
  is written `&mut a[lo:hi]`, as a mutable pointer is written `&mut x`; the
  destination no longer chooses. Passing `buffer[:]` to a `[]mut T` parameter,
  binding it to a `[]mut T`, or selecting a user `operator([:])` yielding
  `[]mut T` now needs `&mut`, and the error says so: write
  `reader.read(&mut chunk[:])`, `slice.sort(&mut names[:])`,
  `mem.Arena.from_buffer(&mut buffer[:])`. A mutable adapter is
  `(&mut values[:]).indexed()`; `values[:].indexed()` is now read-only. A
  slice erased to `any_view` now holds `[]T`, so `view.([]mut T)` on it fails
  unless it was sliced with `&mut`.
- A required result that a call stores in a local and that no path reads
  before the local is next written or leaves scope is `L0698`, as a binding
  never read was. Before, one read of the name anywhere covered every result
  stored in it. Inspect the result, or discard it with `_ = ...`.
- `x: T = ---` and an `@(initialized = count)` field now need
  `import "core:unsafe"` in the file that writes them (`L0706`), like the
  other unchecked operations: the first leaves reads unchecked, and generated
  copy and drop trust the second's count. Add the import. Generated copy, drop,
  equality, and formatting also panic on a count outside `0 ..= N` instead of
  reading past the array.
- A `hook(copy)` that writes a file-scope, `static`, or `thread_local`
  variable, directly or through a call, is `L0711`: how many copies run is
  unspecified, and such a write could invalidate a live borrow unchecked.
  Keep a count of copies in a `sync.Atomic`, or move the write into a named
  method callers invoke.
- A drop hook's or `format` method's writes to globals now count where the
  hook runs, as an explicit call's do: dropping a value whose `hook(drop)`
  writes a global, or printing a value whose `format` does, while a borrow of
  that global is still in use is `L0512`. Such programs read freed storage.
  End the borrow before the drop or print, or take an owned copy with
  `clone`.
- A procedure type keeps its variadic parameter last, as a declaration does:
  `proc(nums: ..int, tail: int)` is `L0574`. Move the variadic parameter to
  the end.
- A struct field marked both `@(public)` and `@(private)` is `L0332`, as a
  declaration so marked already was; it used to be public. Keep the one you
  mean.
- A foreign binding whose link name an `@(export)` definition also defines
  must declare the same kind and type (`L0600`); a mismatch used to compile
  into a call of the wrong type. Write the binding with the exported
  signature, or drop it and call the definition directly.
- Comparing a struct, array, or union that holds a value of another
  package's type whose inherent `==` is not `@(public)` is `L0355`, in an
  expression or a value `switch`, as comparing that value directly already
  was: field-wise comparison would be a second equality for the type. Ask
  for the operator to be exported, or compare the visible fields by hand.
- A mutable carrier stored through a pointer, as `target.view = source` with
  `target := &mut holder`, is suspended while what holds it is used
  (`L0641`), as one stored directly into `holder.view` already was: appending
  through `source` could leave a pointer taken through `holder.view`
  dangling. Finish using the holder before using the source again.
- A copy of a read-only reborrow, or an element pointer taken through one,
  keeps the mutable source suspended while it is live (`L0641`), as the
  reborrow itself does: `copy := view; source[0] = 9;` was accepted, and an
  append through the source could leave such a pointer dangling. End the
  copy's last use before using the source again.
- A generic argument whose parameter's type names an earlier parameter must
  fit that application's own type: after `Buffer(2, [2]int{1, 2})`, the
  mismatched `Buffer(3, [2]int{3, 4})` is `L0432` (and the same call of a
  procedure finds no overload), where it was accepted. Write an argument of
  the right length.
- A `for` condition that may move or drop a local, as
  `for (ready && consume(move(xs)))` does, leaves it dead in the body and
  after the loop (`L0500`): the condition's effects reached neither. Give the
  local a new value before reading it again.
- A multiple assignment cannot read, in a later destination, a local that an
  earlier destination of the same statement initializes, as in
  `index, xs[index] = 0, 1;` with `index` unset (`L0500`): every destination
  is prepared before any write, so the read saw no value. Initialize the
  local first.
- A `move` parameter of any type is dead after `move` or `drop`, so reading
  a dropped `move` parameter of type `int` is `L0500`, as it is for a local.
  Read the value before consuming it, or assign it a new one first.
- A destructuring `foreach` cannot take apart a record that a protocol
  `next` hands over when that record has a custom `hook(copy)` or
  `hook(drop)`, at any depth of the pattern (`L0508`), as a destructuring
  declaration already could not: the hook was skipped. Bind the whole element
  and read its fields. A record a traversal lends, or copies out of storage,
  can still be destructured.
- An `inout` argument must have exactly the parameter's type (`L0310`). A
  scalar passed to `inout Simd(T, N)` wrote a temporary the caller never saw,
  a `^mut T` passed to `inout ^T` could be overwritten with a read-only
  pointer, and a `[dynamic]T` was accepted by `inout []T`. Declare the
  variable with the parameter's type, or pass a converted copy by value.
- An `inout` argument cannot be a field reached through a packed struct,
  including an element of a packed struct's array, on any call path
  (`L0614`), as a mutating method's receiver already could not: its address
  may be misaligned. Copy the field to a local, pass that, and store it back.
- Converting a typed constant follows the rules for a runtime value of its
  type, so `(^mut int)(EMPTY)` with `EMPTY :: (^int)(nil)` is `L0373`, and an
  unchecked pointer conversion of one needs `core:unsafe`. Only untyped
  constants convert by what their value fits. Declare the constant with the
  type the conversion needs.
- A type nested more than 32 levels deep is checked all the way down, so an
  unsupported component, such as an interface behind 33 pointers, is rejected
  (`L0350`) as it already was at 32.
- A generic `impl` whose subject pattern has concrete parts applies only to
  instances that match them: `impl Box([2]$E)` no longer gives `Box([3]int)`
  its methods, nor `impl Box(Pair(int, $T))` `Box(Pair(bool, int))`. Calls
  that relied on this report `L0363`; write an `impl` whose subject matches.
- A container operation named through its type, as in
  `([dynamic]Choice).resize(inout values, 1)`, or taken as a procedure value,
  meets the same element requirements as the method call: growth needs a zero
  value (`L0424`), and `lookup_value` and the `try_` insertions need a
  copyable element (`L0491`). Use the forms the method call allows.
- A procedure that reaches a `static` or `thread_local` local cannot run in a
  compile-time evaluation (`L0341`): that storage persists between calls, and
  evaluation gave each call a fresh copy. Compute the constant without it.
- A procedure group cannot name a lifecycle or conversion hook (`L0412`), which
  let the group call the hook directly. Use the language operation, such as
  `drop(value)`, instead.
- A `foreach` binding follows the rules for other locals: two bindings with
  the same name are `L0304`, and one that hides an outer local or parameter is
  `L0305`. Rename the binding.
- An empty string slice whose bound falls inside a UTF-8 sequence, such as
  `text[1:1]` of `"é"`, panics, as a nonempty one already did; at compile time
  it is `L0343`.
- Borrow checking takes a value's borrows when it is evaluated, not after later
  parts of the statement run: `a, b = b, a` gives `b` what `a` borrowed, and
  an index or later literal element that changes a pointer no longer hides what
  an earlier read of it borrowed. Programs that returned a local this way are
  rejected (`L0526`).
- A `[]mut T`, `^mut T`, or other mutable carrier passed where a read-only one is
  wanted is reborrowed until the call returns, so a later argument of the same
  call cannot use it (`L0641`): `observe(source, bump(source))` and
  `slice.equal(s, s)` with `s: []mut int` are rejected. Bind a read-only view
  first, as in `view: []int = s`, and pass that.
- An allocator kept in an ordinary record, as in `Holder{arena.allocator()}`,
  keeps its region: an owner allocated `via holder.allocator` cannot outlive
  `arena` (`L0592`). A reset through a selection that may be an unknown or
  default allocator, or one in another parameter's record field, needs that
  allocator's promise too (`L0538`), even when another alternative is an
  `@(allocator_reset)` parameter.
- After a call that may store an `escape=stored` argument into itself, every
  part of the argument may hold what any part borrowed: reading `h.right` after
  `copy(inout h)` stored `h.left`'s borrow of an ended local is `L0513`.
- The result of a call through a procedure value has unknown provenance when no
  escaping argument establishes its root, even if another argument is borrowed
  for the call, so `kept = action(&value)` with an `escape=none` parameter
  cannot store it in `static` storage (`L0647`).
- A map literal whose key borrows a local, as in `map[^int]int{&local = 1}`,
  can no longer escape the local (`L0526`), as an inserted key already could
  not.
- `&p.data[0]` and `p.data[:]` are errors (`L0614`) when `data` is an array
  inside a `@(packed)` struct, as `&p.data` already was: the element may be
  misaligned. Copy the array out first.
- A destination type no longer picks between operator overloads that differ
  in a floating operand: `chosen: f32 = 1.0 + marker` with `f32` and `f64`
  overloads is ambiguous (`L0391`), as the inferred form already was. Write the
  operand's type, as in `f32(1.0) + marker`.
- `return` must match the result's mode (`L0418`): an `inout` result needs
  `return inout place`, and a value result takes no `inout`. An `inout` place
  must also have exactly the result type before any conversion, so returning an
  `inout [N]T` as `inout []T` or an `inout string` as `inout string_view` is
  rejected. These returned a value or the address of a frame temporary.
- A record field of type `type`, or a procedure literal whose signature
  contains `type`, is an error (`L0378`), as a variable or named procedure
  already was. The literal compiled `type` arguments to `0`.
- A `@(require_results)` value bound in an `if`, `for`, or `switch` header and
  never read is an error (`L0698`), as one bound in a block already was. Read
  it, or discard it with `_ = ...`.
- A destructuring declaration with a written type, as in
  `a, b: int = pair`, is an error (`L0308`); the bindings took the fields'
  types and ignored `int`. Write `a, b := pair`. A destructured file-scope or
  static-duration initializer must be a compile-time constant, as a single
  binding's is.
- A run-time scalar splatted into a SIMD vector must be a valid lane, as in a
  scalar assignment: `lanes: Simd(i32, 4) = value` with `value: f32` reports
  `L0310`. It passed the checker and failed in Clang with `L0403`; convert
  the scalar first, as in `i32(value)`.
- An unfixed float no longer converts implicitly to an integer even when it is
  integral, as in `value: int = 1.0` (`L0353`). Write `int(1.0)`, or the
  integer literal `1`.
- `main` with an `inout` result or a foreign calling convention, as in
  `main :: proc "c" ()`, is an error (`L0303`). An `inout i32` result exited
  with an address-derived status; return the status by value from a `loke`
  `main`.
- A parameter other than `self` with no type and no default, as in
  `read :: proc(other) -> int` inside an `impl`, is an error (`L0408`). It
  took the `impl` type; write it, as in `other: Counter`.
- `nil` is not a union value (`L0310`, or `L0373` for `U(nil)`), even for a
  union with `@(zero=name)`. `result == nil` used to compare with the all-zero
  first variant. Name the variant instead: `result == .ok` for a
  `Result(Unit, E)`, `option == .none` for an `Option`.
- A constant zero integer divisor is an error (`L0319`) even when the dividend
  is not constant, as in `value / 0`, `value % 0`, and `value /= 0`. These
  compiled to a run-time panic; remove the division, or divide by a variable.
- An `inout` marker on an argument to a variadic parameter, as in
  `fmt.println("a", inout n)`, is an error (`L0370`). It was accepted and
  ignored; delete the marker, since a variadic pack receives a copy.
- Standard output and standard error are binary on Windows: `fmt.println` and
  panic reports end lines with `\n`, as `term.stdout()` already did, instead of
  `\r\n`. A program whose output must end lines with `\r\n` writes them.
- Allocator lifetime checks reject handles used after their provider ends,
  including handles derived from temporary providers. Bind the provider to a
  local that outlives its handles, allocations, and child providers. `new_clone`
  also rejects escaped or stale borrows hidden in its allocation; keep the
  borrowed source alive or clone an owning value instead.
- Foreign boundaries reject enums without a written backing type, enums backed
  by `i128` or `u128`, and zero-sized records, including nested fields (`L0619`).
  These could use incompatible C layouts or calling conventions. Write the
  backing type matching the foreign declaration, such as `enum i32`; pass
  unsupported types through pointers or an explicit compatible representation.
- Unmatched UTF-16 surrogates in `Raw_Mode.read_key` now return `Invalid_Data`
  for `Read_Key` instead of dropping a high half or producing a non-scalar
  character. Handle this error when processing injected console input. A valid
  following key, its modifiers, and all repeats remain available.
- Generic argument matching now follows cache identity: the converted argument
  type and value. Floating arguments use their exact IEEE-754 encoding,
  including inside aggregates and `dyn` applications. A repeated name requires
  the same converted type and no longer matches `0.0` with `-0.0`; use distinct
  names and a numeric `where` comparison when that equality is intended. NaNs
  with identical encodings now match, and different payloads or signalling bits
  retain distinct instances.
- Colon annotations on inferred generic bindings, such as `x: $T: []int`, are
  rejected (`L0258`); their constraints were silently ignored. Write `x: []int`
  for a fixed element type, `x: []$E` to infer the element, or `x: $T` with a
  `where` bound. Explicit parameters such as `$T: type` are unchanged.
- `get_environment`, `set_environment`, and `unset_environment` reject empty
  names or names containing `=` as `Invalid_Data` before calling the platform.
  An invalid-name lookup previously looked like a missing variable, while
  setters reported `Other`. Validate input names and handle `Invalid_Data`.
- A union's `impl` or `extend` block can no longer declare a member named `as`,
  which is now the compiler-defined `value.as(.name)`. Rename the member.
- An inherent `format` must match `fmt.Formattable`'s concrete slot. Generic
  format methods and methods borrowing or mutating the writer/options arguments
  are now diagnosed. Use `proc(self: ^, writer: fmt.Writer, options: fmt.Options)`;
  plain `self` remains accepted. Previously these could silently use default
  formatting or emit an invalid call.
- Comments inside generic parameter types no longer introduce fictitious `$`
  bindings or hide real ones. Invalid independent defaults that were accepted
  because of comment text are now diagnosed at the declaration. Define the
  referenced name in the declaration's scope or correct the default; a `$name`
  written only in a comment does not declare a parameter.
- Two generic `impl` blocks that both give one instance a member of the same
  name, where neither block is more specialized, make a call of that member
  ambiguous (`L0391`); the first block's member used to win silently. Blocks
  with equal patterns declaring one name twice are an error (`L0409`). Remove
  one member, or make one block strictly more specialized, as
  `impl Pair(int, int)` is than both `impl Pair($A, int)` and
  `impl Pair(int, $B)`.
- A constant or file-scope initializer that builds an array or struct of more
  constant elements than the compile-time evaluator's 64 MB scratch budget
  holds, such as `Table :: [2000000]u8{1};`, is an error (`L0342`); the
  compiler used to fold it one element at a time, taking seconds or running out
  of memory. Leave a zero-initialized global without an initializer
  (`buffer: [2000000]u8;`), or fill a large table at run time.
- Signed SIMD lanes follow the scalar overflow rule (design.md "Lane-wise
  operators"): `+`, `-`, `*`, `/`, and unary `-` panic when any lane
  overflows, and are `L0397` at compile time, where they used to wrap; a
  `MIN / -1` lane panics instead of answering `MIN`. Signed `simd.reduce_add`
  and `simd.reduce_mul` fold left to right through the checked operator and
  panic on an overflowing partial result. Write `math.wrapping_add(a, b)`,
  `wrapping_sub`, or `wrapping_mul` where a kernel means to wrap; they take
  vectors and compile to the plain instruction.
- `slice.Comparator` and the `sort_by_comparator`/`sort_by_procedure` members
  of `slice.sort_by` are removed (standard-library.md "Sorting slices"). `sort_by` is one
  generic procedure taking any `interfaces.Callable(C, proc(left, right: T) ->
  bool)`: a plain procedure, or a record whose `call` method compares, as
  before. Calls are unchanged. Upgrade a `where slice.Comparator(C, T)` bound
  to `where interfaces.Callable(C, proc(left, right: T) -> bool)`.
- A rune constant no longer converts implicitly to a floating-point type
  (`L0353`), and an unfixed rune and an unfixed float no longer meet in an
  operation (`L0354`); `x: f64 = 'a'` used to be `97.0`, and `1.5 + 'a'` folded
  to `1.5`. It still converts to integer types that hold it, as `ch: u8 = 'A'`
  (design.md "Implicit type conversions"). Write `f64('a')`.

### Changed

- Building `lokec` from source needs Odin `dev-2026-10`, up from
  `dev-2025-09` (readme.md "Building from source"); the compiler moved to
  Odin's rewritten `core:os`. What `lokec` compiles is unchanged.
- Compile-time evaluation rejecting a value whose drop or copy runs a
  hand-written `hook(drop)` or `hook(copy)` is now a language rule (design.md
  "Compile-time procedure evaluation") rather than a known gap, and `L0341`
  says so. A folded union constant holding such a record is now rejected too;
  before, evaluating it skipped the hook.
- `:=` and `=` destructuring stays flat by design; only a `foreach` header
  nests (design.md "Destructuring"). A nested group such as `(x, y), b := p`
  is now one diagnostic (`L0207`) saying to destructure in a second step,
  instead of a cascade of expression errors.
- A two-variant union whose other variant has no payload stores a reference
  payload alone, its null address being the payloadless variant (design.md
  "Representation"): `Option(^T)`, and `Option` of a procedure value,
  `cstring_view`, `box(T)`, or `shared(T)`, is one word instead of two, and
  `Option(dyn I)` two instead of three. Code that hard-coded the old
  `size_of` sees the new one.
- Procedure definitions mark reference, pointer-mode, and large-value
  parameters `nonnull` for LLVM.
- A carrier suspended by a read-only reborrow may be read through a field, a
  pointer, or an element, as a slice local could: `held.items[0]` and
  `len_of(held.items)` with `view: []int = held.items` live, `p^` with
  `q: ^int = p` live, and so on. Writes and mutable copies still conflict.
- A mutable slice may still be read while a read-only reborrow of it is live:
  passed to a `[]T` parameter, indexed, measured, resliced read-only,
  traversed by value, or printed. `slice.equal(xs, xs)` with `xs: []mut int`
  no longer fails with `L0641`. Writes and mutable reborrows still conflict.
- The copy-cost warning (`L0507`) reports a copy that may allocate — of a
  container, or of a record with a copy hook — whatever its size, as "this
  binding clones `first`, which may allocate". A copy last-use transfer makes
  a move, a written `.clone()`, and a `string` or `shared(T)` copy are not
  reported. Write `.clone()` to mark an intended copy, or pass
  `-copy-cost=off`.
- A `hook(copy)` must return its source's value, and how many implicit copies
  run is unspecified: last-use transfer skips a copy and the source's later
  drop. A hook that changes the value or counts its calls gets results that
  depend on that choice; make such a type `move_only` with a named method.
  See design.md "Lifecycle hooks and resource types".
- Debug builds preserve outputs ending in `.ll` or `.natvis`, including case
  variants. Deferred locals remain visible at every emitted exit, exported
  names stay literal, and `else if` conditions have their own source locations.
  Debuggers show 128-bit integers and enums as exact `low` and `high` words
  rather than saturating wide enum constants.
- Open questions and unresolved findings now live in
  [open-questions.md](open-questions.md); [comments.md](comments.md) keeps design
  rationale and differences from Odin.
- `Enum.from_int` accepts an argument of any integer type, including a
  `distinct` integer, so `Suit.from_int(code)` works with a `code: int` and a
  `Suit :: enum u8`. A value the backing type can't hold gives `.none`, as any
  other undeclared value does.
- Tutorials assume prior programming experience and focus on Loke's syntax,
  borrowing, and mutation rules. They distinguish runes from displayed
  characters and clarify panic cleanup and generic type inference.
- Assigning or binding a place whose copy allocates, such as a `[dynamic]T` or
  `map[K]V`, copies it again, from the destination's `via` or the default
  allocator; 0.7.1 rejected it (`L0504`). A copy at a local's last use is a
  move instead, so `b := a` costs nothing when `a` is not used afterwards
  (design.md "Last-use transfer"). Every program 0.7.1 accepted means the same.
- Under `-g`, a debugger shows each local only inside the block that declares
  it, so two loops that each declare `i` no longer show two `i`s at once.
- Under `-g`, the PDB carries natvis rules, so Visual Studio and WinDbg show a
  string's text, a map's entries, and an `any_view`'s value. A map's debug type
  is named `map$<n>` so the rules can match it, `string`'s is `string$` because
  WinDbg ignores natvis for a type named `string`, and `-keep-temps` keeps the
  `.natvis` file.
- Under `-g`, a debugger shows the value a `dyn` view points at. Each witness
  table is a `witness$<n>` global in the PDB, and a `dyn` type is named
  `dyn$<n>` so the natvis rules can match it.
- Under `-g`, the cleanup a block runs on exit has the line of its closing
  `}`, and a `for` loop's condition and update, and a `foreach` loop's step,
  have the loop header's line, rather than the last statement's.
- Under `-g`, a deferred statement has its own line when the scope exit runs
  it, rather than the exit's.
- `-doc` opens a package's page with the comments above its `package` clauses,
  shows a public struct field's comments, and adds a page for each package of
  the project the root imports. A declaration or package clause with
  attributes now gets the comment above them; it used to get none.

### Added

- `or_return` takes a failure operand, evaluated only when the operand fails
  (design.md "The failure operand"). A value of the procedure's error type
  replaces the error, `strconv.parse_int(text) or_return .Not_A_Number`; any
  other operand is a mapper called with it, `parse(text) or_return describe`;
  and `.name` resolves against the procedure's error type, so a variant with a
  payload wraps the error, `fs.read_text(path) or_return .io`. It replaces
  `.map_error(...) or_return` and `.ok_or(...) or_return` at propagation sites.
- `Status(E)`, a fallible union whose success carries nothing, in
  `base:runtime` with a `map_error` (design.md "Typed fallibility"). A
  procedure whose result is such a union, including `Status(E)` and a `main`
  returning one, may end without `return .ok;` (design.md "One result").
- `errdefer`, a `defer` that runs only when the procedure returns its failure
  variant, by `or_return` or `return`, and during panic unwinding unless a
  success return has already passed it (design.md "defer statement"). It needs
  a fallible result (`L0720`).
- `or_else` accepts a fallible union whose success carries nothing and yields
  `Unit`, as `or_return` does (design.md "or_else expression").

- A switch case binds a record payload's fields: `case .add(left, right):`
  (design.md "Inspecting a union"). Over a place the fields are borrowed and
  nothing is cloned, `&mut left` binding one field as a writable place apart
  from its siblings; over a temporary they transfer into their bindings, and a
  `_` field drops when the case ends (design.md "Switch ownership"). The
  payload must be a record that the destructuring rules let the case take
  apart, and the form works in `if (case ...)` and `for (case ...)` headers
  too.
- An anonymous record whose fields are all ordered is ordered
  lexicographically (design.md "Comparison operators"), so
  `[dynamic](priority: int, id: int)` sorts without a comparator and such a
  record satisfies `interfaces.Ordered`. The first unequal field decides, by
  its own `<`. A field whose type is not ordered, or declares a comparison
  operator of its own, leaves the record unordered, and the `L0355` or `L0651`
  error names that field.
- `main` may return a fallible union whose success carries nothing, such as
  `Result(Unit, E)`, so it can use `or_return` (design.md "Program entry and
  exit"). A failure is printed to standard error as `error: ` and its payload,
  after `main`'s cleanup and anything already printed, and the exit status is
  1; success exits 0.
- A struct, union, or anonymous record that keeps its generated `==` gets a
  generated `hash`, so `map[Point]int` needs no hand-written pair for
  `Point :: struct { x, y: int }` (design.md "Maps"). It exists when every
  field or payload is hashable, a part with its own `==` counting when it also
  has its own `hash`, which the generated one calls. Such a type satisfies
  `interfaces.Hashable` and has a `hash(seed)` member. A key that is still
  rejected (`L0586`) now names the field or variant that is not hashable.
- An `or_else` fallback may leave: `entry := table.find(name) or_else continue;`,
  `or_else break`, and `or_else return value` run that statement on failure,
  with its cleanups, and the expression yields the success payload (design.md
  "or_else expression"). They follow the statement's rules, so they need a loop
  or may not leave a `defer`, and a loop's own header cannot use the loop forms
  (`L0718`).
- `x in r` tests a value against a `Range(T)` (design.md "Ranges"), at run
  time and in compile-time evaluation, and range operators now bind between the
  comparisons and addition (design.md "Operator precedence"), so
  `c in 'a' ..= 'z'` reads as it is written and `0 ..< n + 1` still ends at
  `n + 1`. A written range takes its endpoint type from a typed element, so
  `ch in 'a' ..= 'z'` tests a `u8`, and two unfixed endpoints take the type of
  an expected `Range(T)`. No program that compiled before changes meaning:
  every grouping the move affects had a `bool` endpoint, which a range rejects.
- Anonymous records may leave their fields unlabeled, `(int, bool)` (design.md
  "Anonymous records", "One result"), so a procedure that hands back several
  values no longer names them: `divmod :: proc(a, b: int) -> (int, int)`,
  `q, r := divmod(17, 5)`. An unlabeled record has at least two fields, is
  taken apart by destructuring and built by positional literals, prints as
  `(3, 2)`, reflects with empty field names, and is a different type from any
  labeled record. A labeled record converts implicitly to the unlabeled record
  of its field types (design.md "Implicit type conversions"), so a library can
  name its results without imposing the names on callers; nothing converts
  back, between two sets of names, or inside a procedure type. A record's
  fields are all labeled or none (`L0254`). The unlabeled-result error `L0238`
  is gone.
- `dyn proc(parameters) -> Result` is a borrowed view of anything callable with
  that signature (design.md "Borrowed callable views"), the short form of
  `dyn interfaces.Callable(...)`, so one non-generic parameter, field, or array
  holds procedures, capture literals, and callable records alike. A procedure or
  a capture literal converts to it implicitly where one is expected; a named
  callable record converts explicitly, `(dyn proc(...))(&record)`. Converting a
  procedure borrows nothing, and a capture literal is borrowed where it is, so a
  temporary one ends with its expression. `f(args)` calls through the view,
  checked as a call of the signature, inferred result contract included, and
  what a view holds meets that contract and the signature's escape levels as a
  conversion to it would (`L0645`). A `$` in the signature binds from a
  procedure or capture literal passed to it. `dyn mut proc` and a non-Loke
  calling convention are `L0463`, and an interface composing `Callable` is not
  dyn-compatible.
- Capture literals (design.md "Capture literals"): a procedure literal lists
  what it captures after its signature, as in `proc(a, b: int) -> bool
  capture(limit, &cfg = self.config, &mut count, move(buffer)) { ... }`. A
  plain name copies, `&` and `&mut` borrow, `move(name)` transfers, and
  `name = value` captures any value or, after `&`, any place. The literal is a
  value of a body-local record whose `call` is its body, so it is called as
  `f(args)`, passes to anything `interfaces.Callable`, and its borrows are
  checked as a record's are. `capture` is a keyword only in that position.
  Naming an enclosing local without capturing it is still `L0374`, now with a
  note offering the three modes; the clause's own rules are `L0259` and
  `L0716`.
- A value whose type has a `call` method is called like a procedure:
  `x(args)` is `x.call(args)` (design.md "Calling a value"), reached through
  a pointer or a box as `x.call` is. A field named `call` does not count, and
  calling such a record is `L0320` with a note saying so.
- `interfaces.Callable(C, Signature)` holds for a procedure that converts to
  the procedure type `Signature`, and for a type whose `call` method takes a
  plain `self` and otherwise matches it, calling convention and reset effects
  included (standard-library.md "Standard interface catalogue"). `C.Result` names what
  the call returns, and is `L0408` when a `call` returns nothing or two
  disagree. A bound, bare or composed by another interface, lets the body
  write `c(args)`, reaching a `call` method its package could not otherwise
  see. `Result.map_error` now takes any such callable, so a record
  can map an error.
- `if` and `for` take one switch case as their header (design.md
  "Conditional patterns"): `if (case .some(entry) = table.find(key)) { ... }
  else { ... }`, and `for (case .some(entry) = reader.next() or_return)`,
  which reads a stream until the first value that does not match. Each means
  the switch it abbreviates, so ownership and `break`/`continue` are the
  switch's.
- `@(required)` on a struct field makes every literal supply it (design.md
  "Required fields"). The struct then has no zero value, so `T{}`, an
  uninitialized global, a `make` length, and `resize` reject it too.
- A payloadless union variant may be written as a bare name:
  `union { none, some: T }` (design.md "Unions"). `name:` still works. A bare
  name that is a type in scope, as in Odin's `union { int, string }`, is
  rejected (`L0422`) rather than read as a payloadless variant.
- `strings.try_slice`, `floor_boundary`, `ceil_boundary`, and `prefix_runes`
  cut text at an offset from outside the program without risking the panic a
  slice through a code point raises.
- `math.wrapping_add`, `wrapping_sub`, and `wrapping_mul` take two vectors of
  one `Simd` type with integer lanes, and wrap each lane.
- `mem.Failure_Policy` and a `policy` argument on `mem.Arena.init`,
  `Arena.from_buffer`, `Scratch.init`, `try_arena`, and `try_scratch` select
  `.Trap` for a region: its allocation failures then abort without unwinding
  (design.md "Allocation failure"). `.Panic` remains the default, and a
  trapping default allocator is a factory returning such a region.
- `fmt.fixed(value, digits)` prints a float with a fixed number of fractional
  digits, and `fmt.pad_left`/`fmt.pad_right(value, width)` pad any printable
  value to a width in runes, so `fmt.println(fmt.pad_left(fmt.fixed(x, 2), 8))`
  prints an aligned column (standard-library.md "`core:fmt`").
- `io.from_native_code(native_code, operation)` turns a platform error number
  into an `io.Error` (standard-library.md "Shared I/O contract"). `core:fs`,
  `core:os`, `core:process`, and `core:term` now share its one table, so a
  Windows error that one of them reported as `Other` now gets the code the
  others give it; `core:term` alone still reads error 6 as `Not_A_Terminal`.
- `case .name(&mut binding):` binds a union payload as a writable place when the
  switch subject is a writable place, which the case borrows exclusively
  (design.md "Switch ownership"). An `Option(box(T))` field is updated in
  place, and a `^mut` cursor walks a chain by storing `&mut node.next` back
  into itself, so a linked list's tail append and in-place removal need no
  `exchange` or unchecked code.
- `Option` of `^T`, `^mut T`, a foreign procedure pointer, or `cstring_view`
  is foreign-ABI-safe, lowered to the nullable C pointer: a binding whose C
  side may pass or return NULL now writes `Option(^T)` rather than `[^]T` or
  `rawptr`. `sync.Atomic(Option(^T))` is an atomic pointer that starts as
  `.none`.
- `box(T)` owns one value in an allocation of its own, as `[dynamic]T` owns a
  run of them (design.md "Owned values"). `box(value, allocator)` and
  `try_box(...)` build one; `b^`, field selection, indexing, and methods reach
  the payload with the box's capability; a box lends `^T` implicitly and
  `&mut b^` explicitly; copying clones the payload; `move(b).unbox()` hands it
  out. A box is one address, has no zero value, and makes recursive types such
  as `Tree :: struct { left, right: Option(box(Tree)) }` ordinary owned values.
  Reflection reports it as the new `runtime.Type_Kind.Box`.

- `check_session_incremental` reuses checked dependency prefixes for stable
  static import graphs and falls back to a full check for discovery, conditional
  selection, or provider changes. `session_check_stats` reports rechecked/reused
  packages and retained semantic/checkpoint bytes; repeated edits reclaim old
  state. See [Incremental checking](compiler-architecture.md#incremental-checking).
- `invalidate_session` lets compiler-service clients expire snapshots and
  emission readiness after external file or project changes. The next batch
  check rebuilds the whole program; an incremental check revalidates every
  input before reusing a checkpoint, under documented
  [invalidation rules](compiler-architecture.md#invalidation-rules).
- Compiler sessions accept in-memory source overlays, including new unsaved
  packages, and expose read-only snapshot queries for symbols, types,
  definitions, references, signatures, and diagnostics. Queries retain partial
  results on erroneous programs and reject stale handles after edits or checks.
  See [compiler-architecture.md "Snapshots and queries"](compiler-architecture.md#snapshots-and-queries).
- Reusable compiler sessions own build configuration and compilation state,
  support repeated whole-program checks and in-memory LLVM emission, and back
  the existing `lokec` command-line pipeline. See
  [compiler-architecture.md "Reusable batch sessions"](compiler-architecture.md#reusable-batch-sessions).
- `core:math` adds `wrap(T, value)`, a compiler-known conversion that keeps an
  integer's low bits, and `wrapping_add`, `wrapping_sub`, `wrapping_mul`,
  `checked_add`, `checked_sub`, and `checked_mul` for signed and unsigned
  integers.
- `try_append`, `try_insert`, and `try_find_or_insert` accept a move-only
  element from a temporary or `move(...)`, as `append` does, instead of
  rejecting it with `L0491`; a failed insertion leaves the container unchanged
  and drops the element. `Small_Array` gains the same consuming `try_append`
  and `try_insert`. A borrowed place is still copied, and kept on failure.
- `lokec <file> -dump-tokens` prints the file's tokens, one `lo hi Kind` line
  each with the byte span, and stops after lexing.
- `examples/lexer.loke` is the compiler's lexer written in Loke. It prints a
  file's tokens as `-dump-tokens` does, and agrees with it token for token, or
  lexes every `.loke` file beneath a directory and prints the totals.
- `core:process` starts child processes: `spawn` takes a `Command` naming the
  program, its arguments, an inherited or replaced environment, a working
  directory, and whether each standard handle is inherited, the null device,
  or a pipe; `Child` has `wait`, `kill`, `id`, and the pipes, and `run` spawns
  and waits. A name is found on `PATH` only, each argument reaches the child as
  given, and the child inherits its three standard handles and nothing else.
  `io.Operation` gains `Spawn`, `Wait`, and `Kill`. `output` runs a command
  and collects its status, stdout, and stderr, reading both pipes at once; it
  closes a piped stdin, and a failed read ends the child and returns the error.
- `examples/corpus_runner.loke` is the compiler's corpus harness written in
  Loke: it compiles each case, a file or a package directory, runs it, and
  compares its output, or under `-diagnostics` and `-syntax` checks what its
  errors say, or under `-ir` checks the shapes its LLVM IR holds and, when
  `lokec -print-toolchain` finds clang, that LLVM assembles it, running a case
  per processor at once.
- `thread.processor_count` answers how many threads can run at once.
- `value.as(.name)` reads one union variant without a `switch`: it yields
  `Option(P)` holding a copy of the payload when `name` is active, and `.none`
  otherwise, so `shape.as(.circle) or_else 0` works.
- `fmt.Formattable` is the structural interface used by printing. Custom and
  compiler-generated `format` methods support generic constraints and borrowed
  `dyn fmt.Formattable` views; mixed variadic arguments keep their existing API.
- Six tutorial lessons cover borrowing and lifetimes, compile-time evaluation,
  allocator use, resource ownership, default allocator providers, and reflection
  with custom formatting. The core route reaches a command-line tool before
  generics; examples remain executable tests, without learning exercises.
- `lokec -g` emits debug information at any `-opt` level: each procedure, its
  parameters and locals with their types, and the line of each statement, so a
  debugger can set a source breakpoint, show a Loke call stack, and inspect
  locals. An executable gets a `.pdb` beside it, and a panic in it prints each
  Loke frame, newest first, with its procedure, file, and line.
- `lokec -fmt` rewrites a file, or a directory's `.loke` files, in one layout:
  tabs by nesting, the author's line breaks, and one space where the rules put
  one (comments.md "Formatting"). It changes whitespace only and refuses a file
  that does not parse. `-fmt-check` lists the files it would change and exits 1,
  for CI.
- `lokec -doc` prints a package's public API as Markdown: each public
  declaration's signature, without procedure bodies or private struct fields,
  and the comments directly above it. It needs no `main`, and documents a
  standard-library directory such as `core\strings` as the package importers see.
- A `loke.project` file at or above the input lists `require <name> <path>`
  lines, and each name becomes a collection, so `import "shapes:area";` builds
  without `-collection` flags. Dependencies' own `loke.project` files are read
  too; one name naming two directories is an error, and `-collection` overrides
  a name (compiler-guide.md "Projects").
- `lokec -debug` sets `LOKE_DEBUG` to `true`; it used to be `false` always.
- A fixed array `[N]T` converts implicitly to a read-only `[]T` of its
  elements, as a `[dynamic]T` already did, so `total(primes)` needs no
  `primes[:]` (design.md "Fixed arrays").
- `Option.ok_or(error)` turns an absent value into a `Result` failure, so
  `settings.lookup_value("port").ok_or(Config_Error.Missing_Port) or_return`
  replaces a `switch` (design.md "Changing error domains").
- `fmt.concat_to(w, ...)` writes its arguments with nothing between them, for a
  `format` method that prints `(3, 4)`.

### Fixed

- A case binding over a place names the payload in the subject's storage, as
  design.md "Switch ownership" says, instead of a copy of it: `&binding` in
  `switch (v) { case .pair(p): ... }` pointed into a compiler-made stack copy,
  so it did not compare equal to a pointer into `v`. Compile-time evaluation
  now aliases the subject the same way.
- `L0690`, for `move` or `drop` of a borrowed case binding, suggested the
  removed header binding `switch (name in move(...))`; it now suggests
  `switch (move(...))`.
- A temporary borrowed by `&`, by slicing, or by a view conversion is dropped
  when its statement ends (design.md "Temporaries and procedure boundaries").
  A literal such as `&Tracked{1}` or `[dynamic]Tracked{...}[:]` passed to a
  call, and a dynamic array a call returned and the statement sliced, were
  never dropped.
- A literal read through a field or element by value is dropped when its
  statement ends, as a call's result already was (design.md "Temporaries and
  procedure boundaries"). `y := Pair{make(3), make(4)}.b` copied `b` and
  never dropped the pair, and a literal of constants such as
  `Pair{Tracked{5}, Tracked{6}}.b` was folded away with its drop hooks.
- A file-scope `when` condition can name the predeclared type constructors
  (design.md "when statement"): `size_of(Simd(f32, 4))`, `size_of(Range(int))`,
  and `size_of(Box(int))` reported `L0389`, saying the name was not declared,
  and left the branch's declarations unresolved.
- A type's own `<` or `==` declared as a procedure group counts as its own
  (design.md "Comparison operators", standard-library.md "Sorting slices"). A sort orders by a
  grouped `<`, and a grouped `==` compares the type wherever it is nested and
  as a map key; both used to fall back to the built-in operators. Another
  package may compare a part by its `==` when the group is `@(public)`, as for
  a single procedure.
- A constant that compares a record or array holding a scalar `distinct` part
  with its own `==` uses that `==`, as the same comparison at run time does.
  `[1]Loose{1} == [1]Loose{2}` used to fold structurally.
- A procedure's result keeps the borrows of globals its body put in it, so
  writing that global, directly or through a call, while the result is in use
  is `L0512` (design.md "Global write effects"). It used to compile.
- A `defer` registered after an owner its allocator backs is rejected only
  where a statement between them can panic (design.md "Panics and
  unwinding"): a statement of plain scalar operations, unsigned arithmetic,
  and a `drop` that runs no `drop` hook no longer counts as an unwind point.
- A `hash` or `==` the language calls implicitly (a map operation on a key,
  a structural `==`, a generated `hash`) now counts toward global write
  effects, so one that writes a global still borrowed is `L0512` (design.md
  "Global write effects").
- A failing `or_return` drops what a call holds and the expression's
  temporaries newest first together, and drops a variadic call's arguments
  staged so far, which used to leak.
- A `distinct` type that declares neither `==` nor `hash`, such as
  `Tag :: distinct int`, was a map key without satisfying
  `interfaces.Hashable` or having a `hash` member (design.md "Maps"). It now
  has its wrapped type's `hash`.
- Compile-time evaluation of `m.find_or_insert(key, elem)` and
  `m.try_insert(key, elem)` evaluated `elem` after `key` failed an
  `or_return`, so an assertion there stopped the build. It now leaves first,
  as the program does at run time.
- An `or_return` that failed after a call's earlier arguments were made leaked
  them: `show(make_tracked(), maybe or_return)` returned without dropping the
  `make_tracked()` temporary. Such an exit now drops what the call already
  holds.
- A variable initialised with a parenthesised type definition, such as
  `E := (enum { a, b });` or `D := (distinct int);`, no longer declares a type
  named by the variable: only a constant declaration names a type (design.md
  "Structs"). It is now `L0378`, a type stored in a variable, and a struct
  written that way is `L0717`. Upgrade by writing `::` for the declaration.
- `-g -o name.natvis` builds again with MSVC 14.51 (Visual Studio 18), whose
  linker failed with LNK1104 when the natvis rules and the executable shared a
  path. The rules now go to `name.natvis.natvis`, where `-keep-temps` keeps
  them.
- A `dyn` slot call whose receiver is not a named local, such as
  `view_of().touch()`, now writes whatever the slot's methods may write
  (design.md "Global write effects"), so a borrow of a global they write is
  `L0512` there too.
- A distinct procedure type converts implicitly to and from the procedure type
  it wraps, as design.md "Implicit type conversions" lists; it used to need a
  written conversion either way (`L0310`).
- A procedure type written as a result, as in
  `make :: proc() -> proc(n: int) -> int { ... }`, ends at its signature
  (grammar.md "Procedures"). The body used to be read as a procedure literal
  in the result, reported as a compiler defect (`L0350`).
- A generic parameter can no longer be named `true`, `false`, or `nil`
  (`L0700`), whether written `$name`, inside a parameter's type, or in a
  generic `impl` subject. Before, `proc($false: int)` made `false` in its body
  mean the argument.
- A file-scope `when` condition whose array literal is keyed by a name, as in
  `[3]bool{SLOT = true}`, waits for a later branch that declares the name
  instead of reporting it unknown.
- A struct literal naming a field its type lacks reports only that error when a
  constant, array size, or `when` condition reads it. Before, compile-time
  evaluation added an internal error (`L0405`) for the same literal.
- The `typeid` of a type declared inside a generic procedure no longer depends
  on the order that procedure's instances were made in.
- When waiting on clang, NASM, or the layout probe fails, `lokec` reports an
  error instead of treating the child as having exited successfully.
- `os.get_environment` no longer misreads a value that another thread empties
  during the call as missing or as a stale error. standard-library.md no longer
  claims that Windows removes a variable set to the empty string: it stays
  present and empty, as the library already reported.
- When a boxed value's drop panics part way, the unwind still drops its
  remaining fields and returns the box's allocation.
- A type name written with thousands of selectors (`T.a.a.a...`) is reported
  as nesting too deeply (`L0222`) instead of overflowing the compiler's stack.
- `fs.read_directory`, and spawning a child through `process.spawn`, `run`,
  or `output`, report a failed scratch allocation as `Out_Of_Memory` instead of
  panicking, as standard-library.md's shared I/O contract promises.
- `thread.spawn` that cannot create a thread still drops the argument it was
  given, and frees its start block, before panicking.
- When the final `shared(T)` handle's payload drop panics, the shared block is
  still returned to its allocator during the unwind.
- `perf.ps1` refuses a `-Repeat` below 1, which PowerShell's inclusive
  ranges turned into extra runs, and removes its temporary directory when a
  build, run, or output check fails.
- The test harness counts `lokec.exe` stale after an edit to `src/subprocess`
  too, not only to `src/*.odin`.
- `lokec -fmt` and `-fmt-check` on a directory list its files instead of
  matching a pattern built from its name, so a directory named like `fmt[one]`
  is no longer reported clean while holding unformatted files.
- `lokec` closes each child process it waits on (clang, NASM), and closes the
  first pipe's write end when making the second fails, so neither leaks a
  handle.
- A panicking element drop hook no longer leaks the rest of a container.
  Dropping a whole dynamic array or map now keeps it registered for the unwind
  and takes each element out before its hook runs, as `clear` already did, so
  the unwind drops every element still owed exactly once. This also covers an
  element's own parts and a container nested in another. A map entry whose key
  hook panics keeps its value for the unwind; before, the unwind dropped that
  key a second time. A dynamic array now drops its elements last first, as
  `clear`, fixed arrays, and `Small_Array` already did.
- `process.run` and `Child.wait` on Windows return a child's exit code
  reinterpreted as `i32`, as documented, instead of panicking when its top bit
  is set: an exit code of `0xffffffff` is `.ok(-1)`.
- `source_location`, `caller_location`, `type_info_of`, `type_of`,
  `typeid_of`, `fields_of`, `enum_values_of`, `unsafe.raw_data`,
  `unsafe.string_view`, and `unsafe.cstring_view` reject a named or `inout`
  argument (`L0371`, `L0370`), as every other built-in does (design.md
  "Parameters").
- `shared(value)`, `slice.clone`, `strings.copy`,
  `String_Builder.copy_string`, `finish`, and `fmt.to_string` apply the
  allocator's failure policy when allocation fails: a `.Trap` allocator now
  aborts without unwinding, and the report names the refused size, as for
  every built-in allocation (design.md "Allocation failure").
- `strconv.parse_i64("-0")` and `parse_int("-0")` return `.ok(0)` instead of
  panicking.
- A call through a `dyn` slot checks each argument's written mode:
  `view.update(value)` for an `inout` parameter is now `L0370`, as in any
  other call, instead of writing the caller's variable; a stray `inout` or
  `..` is rejected too (design.md "Parameters").
- A file-scope `when` condition using `offset_of(T, field)` no longer reports
  the field name as an undeclared dependency (`L0389`) (design.md
  "Conditional compilation").
- A static `foreach` binding may no longer be `$true`, `$false`, or `$nil`
  (`L0700`), as no other declaration may (design.md "Predeclared names").
- Compile-time evaluation no longer skips a record's `hook(drop)` or
  `hook(copy)`: a value whose drop or copy would run one is now an error
  (`L0341`) where evaluation makes it, until the evaluator runs hooks
  (design.md "Compile-time procedure evaluation"). Previously a reached
  `drop` of such a value evaluated as if it had no hook.
- A lone `..` spread of a `[dynamic]T` or `[N]T`, as in `sum(..xs)`, passes
  the `[]T` it views instead of failing in LLVM (`L0403`) (design.md
  "Variadic parameters").
- `return inout m[key]` returns the existing map entry, and `return inout
  g[i]` uses a user `operator([])`'s `inout` overload; both were rejected with
  `L0418` (design.md "`inout` results").
- A decimal literal negated twice, `-(-1.000000059604644775390625000001)`,
  narrows to `f32` or `f16` with the same single rounding as the literal
  itself, and an exponent far outside the range, such as
  `1e-9223372036854775808`, rounds to zero (or overflows) instead of giving
  `1.0` or taking minutes to compile (design.md "Unfixed constants").
- Compile-time evaluation runs user operators, delegated ones included, and
  accepts a local constant such as `N :: 3` in the evaluated procedure; both
  were rejected (`L0341`, `L0311`) (design.md "Compile-time procedure
  evaluation").
- Under `-panic=unwind`, a panicking drop hook no longer runs a cleanup
  twice or skips one (design.md "What the unwind runs, and what it does
  not"):
  - an assignment whose old value's drop hook panicked dropped that value again
    and aborted; the old value is now dropped after the replacement is
    stored, and with several destinations a value still waiting for its write
    is dropped too;
  - `clear()` on a dynamic array or map, and a shrinking `resize`, dropped the
    finished elements again and aborted; each element now leaves the container
    before its hook runs, the last first;
  - a record, fixed-array, or slice literal whose later element panicked never
    dropped the parts already built; each built part is now dropped.
- A multiple assignment with an `operator([]=)` destination,
  `grid[0], grid[1] = 11, 22`, called only the last setter and dropped the
  other writes. Each destination is now written, after every value and then
  every destination's receiver and indices are evaluated (design.md
  "Evaluation order").
- A map literal whose value changed the variable its key read, as in
  `{key = exchange(inout key, next).len()}`, lost the key's borrow, so
  dropping what the key viewed was accepted while the map was still in use.
  It is now `L0512`.
- A packed field read through a `foreach` binding, a field descriptor's
  `get`, or the in-place comparison of a large packed record was loaded as if
  naturally aligned; it is now loaded unaligned, as every other packed field
  access is (design.md "@(packed)").
- An edit to a `runtime/` C source that kept its size and modification time
  linked the stale cached runtime objects; the cache now names each source by
  a hash of its contents. When a link cannot use the cache, the reason is in
  `runtime/prebuilt/last-failure.txt`.
- The release gate rejected a `known-gaps.md` whose `## Gaps` section was
  `None.`, since it looked for a `## Not gaps` heading that no longer exists.
- `any_view(x)` was accepted and then emitted as a scalar cast that clang
  rejected; it is now the implicit conversion written out (design.md
  "any_view type"). Erasing a `type` value into an `any_view`, by either
  spelling, compiled and crashed at run time; it is now `L0378`.
- A procedure literal with a `where` clause was reported as a compiler defect
  (`L0350`); it is now `L0433`, since a literal is never generic (design.md
  "where clauses"). A literal with a `$` parameter reported "unknown type"
  for each use; it is now one `L0431` saying a generic procedure is not a
  value. Named procedures and literals share these checks.
- A procedure can compute a type, as design.md "`type` and `typeid`"
  describes: `Index_Type :: proc($Count: uint) -> type` is accepted, every
  call is evaluated by the compiler, and the result names a type in a
  constant (`Index :: Index_Type(1000);`) or directly where a type is written
  (`small: Index_Type(10)`). Such a procedure is never emitted; using it as a
  procedure value is `L0378`. It used to be rejected at its signature.
- `math.wrap` of a vector folds at compile time, lane by lane, as design.md
  "Type conversion" says; a compile-time path that reached one used to stop
  with `L0341`.
- A static `foreach` body with a `break` or `continue` that targets the
  expansion (`L0455`) is still checked, so its other errors and copy-cost
  warnings are reported; only the `L0455` was.
- A declaration that copies a place into a `via` destination, such as
  `copy: [dynamic]int via arena.allocator() = list`, reports a use of an
  allocator already moved or dropped (`L0500`). It compiled, and the program
  failed at run time allocating from the dead allocator.
- A chained associated type such as `S.Iterator.Item` is accepted in every
  type position, as design.md "Iteration protocol" uses it; it parsed only
  inside generic arguments. A chain that names no associated type is `L0306`.
- A type written `x.Name` where `x` is not an imported package, such as
  `box.Allocator`, is `L0306` naming the qualifier; it was `L0350`, the
  compiler-defect diagnostic. A `box(value, allocator)` whose allocator came
  out of such a signature no longer crashes the compiler.
- A by-value `foreach` over an array or dynamic array of mutable carriers,
  such as `[2]fmt.Writer` or `[dynamic]^mut int`, no longer rejects using the
  element with `L0641` naming an empty source. The element is the stored
  carrier, and a copy of it, kept even past the loop, reborrows the container's
  carrier as a copy of `ptrs[i]` does.
- A temporary argument whose borrow the result keeps, as the arena in
  `make(..., mem.Arena.init().allocator())`, lives through its complete
  expression; it was dropped right after the call, and the program used a
  freed allocator.
- A generic record's `hook(copy)` bound by a `where` clause that an instance
  fails crashed the backend with `L0405`; the instance is now move-only, as
  design.md "where clauses" specifies.
- `move(x)` evaluates at compile time instead of reporting that the expression
  has no compile-time meaning.

- `examples/lexer.loke` checks a source BOM before UTF-8 validation, matching
  `lokec`'s `L0002` diagnostic even when later bytes are invalid, and reports
  `L0003` at the first invalid UTF-8 sequence instead of always at byte 0.
- Comparing or `switch`ing on a record that contains itself by value reports
  `L0364` instead of crashing the compiler with a stack overflow.
- Nested procedure-literal arguments, as `sink(proc() { sink(proc() { ... }); });`,
  are parsed once each; time and memory grew exponentially with the nesting.
- An owned `foreach` leaf is a local of its step: `move` or `drop` on it
  cancels the step's drop, which used to run again on the inert value left
  behind, and a use after the move is `L0500`. A part a record `Item` hands
  over owned stays owned beside lent siblings, so `move(owned)` is no longer
  rejected with `L0690`.
- A struct, array, or union comparison, a value `switch`, and compile-time
  evaluation compare a part whose type declares its own `==` with that
  operator; it was compared field by field. Such a part also makes its
  container comparable, so a struct holding a record whose `==` compares a
  `[dynamic]` field is no longer rejected with `L0355`.
- A constant union whose payload holds a pointer to literal storage, such as
  `label: Label = .text("hi");`, and a combined `@(packed, align=N)` record
  holding one, now compile at file scope, as `static` values, as named
  constants, and in slice literals. They failed with an internal `L0405`.
- A file-scope `thread_local` has one instance per thread, and each thread's
  managed ones drop when it returns, together with its procedure-local
  `thread_local` values, in reverse order of package path, file path, and
  source position. File-scope ones were one global every thread shared, and
  never dropped.
- A generic parameter whose type names an earlier parameter, as `$V: [N]int`
  does, checks each application's or call's argument against that
  application's own `N`. The first application's type was reused, so a later
  valid `Buffer(3, [3]int{...})` was rejected.
- A copy in a `defer` becomes a move of its source only when no exit the
  `defer` runs at reads the source again. One exit that qualified moved the
  source at every exit, so code after the block saw it empty.
- A deferred assignment drops its destination's old value at each exit where
  that value is live. When one exit's path had already moved or dropped the
  destination, the old value was skipped at every exit, and leaked.
- A multiple assignment whose later destination moves an earlier one, as in
  `held, xs[take(move(held))] = Res{2}, 5;`, leaves the earlier one live
  after the statement; it was rejected as moved.
- A branch that ends in `panic` or a call to a `-> !` procedure no longer
  counts as reaching the code after it, so a local initialized on every
  other path is not rejected there with `L0500`.
- A deferred statement can read a scalar local that the procedure returns,
  as in `defer fmt.println(value); return value;`; returning it was taken
  as a move and the read was rejected with `L0500`.
- Using a managed `move` parameter after moving or dropping it reports that it
  was already moved, dropped, or released, rather than that it has no value
  yet.
- Replacing a map entry's value, by `m[key] = value`, `try_insert`, or a
  map literal's repeated key, stores the new value before the old one drops.
  An old value whose drop hook panicked stayed in the map and was dropped a
  second time by the unwind, which aborted it.
- A generated `clone` or `try_clone` whose copy hook panics part-way drops
  the parts it already copied, without running the incomplete result's own
  drop hook; they leaked. A fixed array's copied elements and an
  `@(initialized)` field's copied prefix are dropped the same way.
- A value handed to a container's `insert`, `find_or_insert`, or `try_insert`
  is dropped when the operation panics before the container holds it, as an
  out-of-range `insert` index or a key's `hash` or `==` that panics does; it
  leaked. The copy `try_insert` and `find_or_insert` stage for a borrowed
  value is dropped the same way.
- A drop hook that panics while a record or a fixed array is dropped, the
  record's own or a part's, leaves the parts not yet dropped to the unwind,
  which drops them in the same reverse order without running the panicking
  hook again; they leaked. The same holds for an `@(initialized)` field's
  live elements.
- `new_clone` and `try_new_clone` of an owned temporary, as in
  `new_clone(build())`, drop the temporary at the end of the expression; it
  was neither moved into the clone nor dropped.
- A deferred statement drops the owned temporaries it creates when it
  finishes, on a normal exit and during a panic's unwind; a temporary whose
  part it addressed, as in `defer fmt.println(build().items[0]);`, leaked.
- A drop hook that panics during an explicit `drop(value)` runs once: the
  unwind no longer replays it on the same value, which panicked again and
  skipped the remaining drops.
- A panic while a map literal inserts an entry, in the key's `hash` or
  clone, or in dropping an entry it replaces, drops the value being inserted;
  only the map built so far was dropped.
- A map literal used directly as the map of `key in` or an index read, as in
  `1 in map[int]Res{1 = Res{7}}`, is dropped at the end of its expression; it
  was never dropped.
- A borrowed element of a map literal is cloned through the map's allocator,
  including a declaration's `via` provider, as a dynamic-array literal's is; it
  used the default allocator.
- A variadic call with a `..` spread releases its pack's stack storage at the
  end of its full expression, so calling it in a long loop no longer overflows
  the stack. A managed pack without a spread keeps its cleanup flags in the
  entry block.
- Converting a pointer that is nil at run time to `dyn I` yields the nil view:
  it compares equal to `nil`, and a slot call through it panics. The view kept
  the concrete witness, so the call ran the method on a null receiver.
- A variant constructor of a union larger than 4096 bytes, taken as a
  procedure value as in `construct := Value.big;`, returns through caller
  storage like any large result; it failed with `L0403`.
- Extracting a value larger than 4096 bytes from an `any_view`, with
  `view.(T)` or `view.as(T)`, builds; it loaded the payload as an LLVM
  aggregate and failed with `L0403`.
- Sorting elements larger than 4096 bytes, with `.sort()` or
  `slice.sort_by`, and using such a key in a map, pass each element or key to
  the `<`, comparator, `hash` or `==` procedure as that procedure expects;
  sorting crashed with an access violation, and a large key with its own `hash`
  failed with `L0403`.
- Hashing a fixed array larger than 4096 bytes, as `key.hash(seed)` or as a
  map key, builds; it read the array as an LLVM aggregate and failed with
  `L0403`.
- A generated clone or drop of a `@(packed)` struct loads and stores its
  fields, and the elements of its array fields, with `align 1`; the emitted
  LLVM promised each field type's alignment.
- Default formatting of a `@(packed)` struct passes each byte-aligned field
  to its formatter as an aligned copy, and reads an `@(initialized)` count
  with `align 1`; the emitted LLVM promised the field type's alignment.
- Viewing a `string` or `[dynamic]T` field of a `@(packed)` struct as a
  `string_view` or `[]T` reads its header with `align 1`; the emitted LLVM
  promised the header's natural alignment.
- `==` on a struct that is both `@(packed)` and `@(align=N)` compares only the
  live prefix of an `@(initialized)` array, as on other structs, and builds
  when a field is larger than 4096 bytes; it compared discarded capacity, and
  the large case failed with `L0403`.
- `unsafe.transmute` between two types larger than 4096 bytes, such as
  `[1024]u64` to `[2048]u32`, builds; it stored the source's address as an
  aggregate and failed with `L0403`.
- `unsafe.transmute` between a pointer and a non-integer type of the same
  size, such as `[8]u8` or `f64`, builds; it emitted an invalid `ptrtoint` or
  `inttoptr` and failed with `L0403`.
- A call inside a parameter default, as in `b: int = identity(a)`, reads the
  parameters to the default's left; the build failed with `L0403`. A written
  argument no longer reads the parameter a call has just bound, so
  `return countdown(a + 1, a);` inside `countdown` passes its own `a`, not
  `a + 1`.
- A `foreach` whose only `$` bindings are inside a group, as in
  `foreach (($first, $second) in PAIRS)`, expands at compile time; it ran as
  a runtime loop, so `static_assert(first == 7)` reported `L0341`.
- Named arguments to an overloaded group or a method, as in
  `group(second = f(), first = g())`, are evaluated in written order, then
  the omitted defaults; they ran in parameter order.
- An omitted `$` argument whose parameter type is itself generic, as in
  `identity :: proc($N: $I = 3) -> I` called as `identity()`, binds that type
  from its default; it reported `L0437`.
- A generic method in a generic `impl` whose `where` bound names its own
  parameters, as in `echo :: proc(self, value: $U) -> U where size_of(U) > 0`,
  is checked when a call instantiates it; the block's instantiation reported
  `L0315` for `U`.
- A call returning `inout T`, and a user `operator([])` returning one, are
  places in compile-time evaluation too, so `pick(inout x) = 9;` can be folded;
  it reported `L0341`.
- Indexing a value with a user `operator([])` during compile-time evaluation
  calls the operator, with every index; it read the operand's fields instead.
- A multiple assignment that inserts several keys into one map, as in
  `m[1], m[2] = 10, 20;`, keeps every write when evaluated at compile time; only
  the last survived.
- `@(require_results)` on an associated or method procedure group applies to
  calls through it, such as `Box.group(1)`, as it did for a free group.
- A variadic spread is evaluated before the default of a fixed parameter it
  skips, as in `use(..spread())` for
  `use :: proc(first: int = mark(1), rest: ..int)`.
- A compile-time `foreach` over a range whose high endpoint is far below its
  low one runs no iterations; it ran when the distance did not fit an `i64`.
- A map literal evaluated at compile time evaluates each entry's key before
  its value, as at run time.
- `key in m` evaluates the key before the map.
- A call of a procedure literal inside parentheses, as in
  `(proc() -> int { return 7; }())`, parses; it reported `L0219`.
- A trailing comma after an untyped receiver, as in `proc(self,)`, parses; it
  reported `L0237`.
- A map literal keeps each constant key's value separate for borrow checking,
  so reading `values[1]` of `map[int]^int{1 = incoming, 2 = &local}` no longer
  counts as borrowing `local`.
- `&p.pointer.value` is accepted when `pointer` is a field of a packed struct:
  the address is in the pointer's target, not the packed record. Elements of an
  array in a packed struct are loaded and stored unaligned, and an `any_view`
  of an unaligned packed place views an aligned copy.
- A fixed-array literal accepts designated elements by index and index range,
  as in `[?]string{0 = "Raven", 3..=5 = "Frog"}`, after any positional ones;
  omitted elements are zero. They reported `L0372`.
- An index or slice bound wider than 64 bits into a slice, dynamic array, or
  string is checked at its full width: a `u128` index of 2^64 panics instead of
  reading element 0.
- A floating literal converted to `f32` or `f16` rounds its exact decimal value
  once: `f32(1.0000000596046448)` is the next float above 1.0, not 1.0. An
  unfixed expression such as `16777217.0 - 16777216.0` is computed before an
  `f32` destination rounds it, giving 1.0 rather than 0.
- A compound assignment such as `box[i] += v` on a type with
  `operator([])` and `operator([]=)` but no `inout` index reads through the
  one and writes through the other, evaluating the receiver and indices once.
  It reported `L0419`.
- A required result bound in a selected `when` branch and read after it is
  accepted; it reported `L0698` before the read was checked.
- A destructured file-scope, `static`, or `thread_local` binding starts with
  its field of the constant record and is initialised once: `a, b := Pair{1, 2}`
  at file scope gave both zero, and a local `a, b: static = ...` was rebuilt on
  every call.
- A local `static` or `thread_local` initializer is evaluated at compile time,
  as a file-scope one is, so `n: static int = answer();` works. It reported
  `L0506`; a run-time initializer now says what has no compile-time value.
- A `_` record field is unnamed padding that keeps its storage, as grammar.md
  "Records" says: `struct { first: u8, _: [7]u8, last: u8 }` is 9 bytes with
  `last` at offset 8. The field was dropped from the layout. Positional
  literals, destructuring, and `foreach` patterns skip it.
- A cycle through a qualified associated constant, as in
  `impl Item { Count :: Item.Count; }`, reports `L0324`. It was accepted, and
  using the constant failed in the backend with `L0405`.
- A constant array, struct, or union converts to its own type and between a
  distinct type and its underlying one, as in `Wrapped(BASE)` and
  `Choice(CHOSEN)`. They reported `L0373`.
- An explicit conversion of a typed integer constant keeps its low bits, as at
  run time: `u8(i32(300))` is 44. It reported `L0373`. An unfixed constant
  such as `u8(300)` must still fit.
- `a == b` with `a: ^mut T` and `b: ^T`, and `a if flag else b`, weaken the
  mutable pointer to `^T` (design.md "Comparison operators"). They reported
  `L0354`.
- A user `operator([:])` gives its endpoints their expected type, so
  `box[.Start:.End]` resolves the implicit selectors. It reported `L0385`.
- A built-in index may be a rune, as in `xs[index]` for `index: rune`
  (design.md "Fixed arrays"). It reported `L0362`.
- A field, an index, or a built-in method applied to a parenthesized
  `or_return`, as in `(items() or_return).len()`, reads the payload. It used to
  emit a nil check on the carrier itself, and LLVM rejected the IR.
- `nil` passed where a generic parameter must infer its type, as in `f(nil)`
  for `f :: proc(x: $T)`, says `nil` has no type to infer it from, instead of
  "`$T` is not bound here" in an instance named `f(<invalid>)`.
- A file-scope `when` condition that names a type only through an anonymous
  record's field, as in `size_of((a: Later))`, waits for the branch declaring
  it instead of reporting the name unknown.
- A diagnostic on a line that is not valid UTF-8 shows each run of bad bytes as
  U+FFFD instead of echoing them, so diagnostics are always UTF-8 text.
- A temporary made in an operand that may not run (the right of `&&` or `||`,
  a conditional expression's arm, an `or_else` fallback) is dropped only when
  it was made. `count == 5 && name() == "x"` released a `string` that was never
  written when `count` was not 5, and crashed.
- A program can import both `core:fs` and `core:thread`: the two declared
  `CloseHandle` with different types, which failed with `L0600`.

- Provider lifetime checks follow nested and recursive record/container types
  without dropping dependencies beyond eight levels. Handles remain usable
  after moving a provider or resetting it with `free_all`.
- Allocations preserve the borrows stored in their pointees, including through
  helper procedures and `try_new_clone`, while retaining field precision and
  the allocation-base provenance needed by checked `free`.
- Foreign ABI checks reuse completed type checks within a traversal, avoiding
  exponential work on shared record types while preserving cycle handling and
  deferred signatures.
- Fixed arrays with copy hooks generate linear-size failure cleanup instead of
  quadratic cleanup, avoiding compiler stalls on large arrays.
- Invalid index conversions stop before bounds checking, avoiding cascading
  diagnostics. Generic field errors include every instantiation's context,
  repeated causes print once, value arguments use readable spellings, and long
  instantiation names are abbreviated.
- The terminal contract now specifies control-character values for Ctrl+letter
  keys, with regressions for Ctrl+C, Ctrl+I, and Ctrl+M.
- `path.volume` includes the server and share in extended UNC roots, so
  `base` and `directory` stop at the share and `fs.create_directories` begins
  below it. Extended paths remain unchanged by `clean`.
- Windows path errors 161 and 267 now normalize to `Invalid_Path` consistently
  in process and filesystem operations, retaining their native error numbers.
- A bare payload variant passed to a call that is itself being called, as in
  `pick(.io)(3)`, is rejected (`L0425`) as it is anywhere else; it compiled to
  a wrong value.
- A plain value read out of a container backed by a local arena, such as
  `return ys[0];` for a `[dynamic]int`, can be returned directly; it was
  rejected (`L0592`) as if it were backed by the arena, while the same value
  bound to a local first was accepted.
- The runtime objects `lokec` caches beside itself are rebuilt when the C
  build that made them changes, such as a new `LOKE_CLANG`, a reinstalled
  clang, or different MSVC or Windows SDK headers; they used to be reused
  whenever they were newer than the runtime sources.
- Several builds running at once after the runtime changed no longer fail at
  the link with `could not open .../runtime/prebuilt/.../alloc.o`: each
  runtime build keeps its own cached set, which is never replaced while
  another build may read it. The old `runtime/prebuilt/<mode>` directories are
  no longer used and can be deleted.
- A deferred `drop(arena)` or `free_all(arena.allocator())` is checked at each
  exit with the owners live at that exit. An owner of the region still live at
  one exit was missed when another exit, such as an early `return` after
  `drop(xs)`, had it dead; the reset is now reported (`L0537`).
- A procedure whose allocator-region facts take many passes to settle, such as
  a loop assigning a long chain of allocator handles in reverse order, keeps
  one analysis graph in memory instead of one per pass: a 128-handle chain
  used 100 MB of scratch and now uses under 1 MB.
- Tutorial examples reject negative time components and report overflowing
  expense totals as input errors. The command-line tutorial accepts long
  category names without panicking; its output now uses one space between
  names and amounts. Checked examples cover these cases and integer limits.
- A variable or composite literal whose type's layout is past the maximum
  size, such as `c: [9223372036854775807]int;`, is an error (`L0364`) where it
  is written; it was accepted, or with `= {}` never finished compiling.
- A zero value of a large array is written whole: a global
  `buffer: [16777216]u8;` compiles in a fraction of a second instead of 44, and
  a local `a := [1000000000]int{1};` compiles instead of crashing the compiler.
  A literal too large to fold is built at run time.
- An instance that two crossed generic `impl` blocks both apply to is valid
  while their shared member is not called; it used to be rejected as soon as
  the instance existed.
- A more specialized generic `impl` block supplies its member even when it is
  registered after the instance exists, as a `when` block can be; the
  general block's member is dropped from that instance, body unchecked.
- `lokec` no longer keeps a CPU core busy while it waits for clang, so several
  builds run side by side finish sooner instead of starving each other.
- A diagnostic whose span runs past its first line, such as a `switch` missing
  a case, no longer underlines a trailing `//` comment on that line.
- A generic record instance first reached by a hypothetical check, such as an
  overload member whose signature names it, keeps its field errors: a later use
  reports them, instead of the compiler crashing or failing internally.
- A generic `impl` subject with a nested pattern, as in `impl Box([]$E)` or
  `impl Box(Box($E))`, applies to the instances it matches; it applied to none.
  A name bound twice, as in `impl Pair($T, $T)`, needs both arguments equal.
- A method whose receiver shares a parameter group with a generic parameter,
  as in `proc(self, value: $U)` or `proc(self, values: ..$U)`, is callable; the
  receiver used to be matched against `$U`.

- A local read in the declaration that introduces it, as in `x := x + 1;`, is
  an error (`L0500`) instead of reaching the backend as an internal failure.
- A compile-time call of a procedure whose body has errors reports that the
  body has errors (`L0344`) instead of an internal failure. This includes a
  `where` or interface predicate, which no longer runs such a body even when the
  errors are in a branch it would not take.
- A constant whose initializer reported an error, such as a literal naming a
  field the record lacks, is not evaluated, instead of failing internally.

- A diagnostic names a file relative to the working directory, with `/`, when
  the program is a directory or a note points into `base:` or `core:`; it used
  to print the whole path, mixing `/` and `\`.
- Inserting a `string_view` key into a `map[string]V` says that an inserted
  key must be an owned `string`, and suggests `.copy()`; it used to report a
  failed lookup.
- A case label that fails to parse, such as `case ..< 0:`, is one diagnostic;
  it used to be six, including a missing `return` for the enclosing procedure.

### Documentation

- design.md "Types with no zero value" names the **non-null types**: the
  references, which are borrows, and the owning handles `box(T)` and
  `shared(T)`, which are owners. It no longer calls `shared(T)` a reference,
  and the `Option` niche in "Representation" now cites the list that names
  `box(T)`.
- The `greeting` and `keys` examples declare a fallible `main` and exit with
  status 1 when they report a failure; they used to exit 0. Examples, the
  command-line tutorial, and the standard library name a `case .err(...)`
  binding `error` rather than after the success value it is not.
- [Language specification](design.md) corrects mutable slice/map-pointer syntax,
  recoverable map allocation, capture initialization, unsigned checked arithmetic,
  and the status of grapheme support. Shortens repeated examples and explanations,
  clarifies `for` versus `switch` membership syntax, and completes the fallible
  operator ownership table.
- [Compiler architecture](compiler-architecture.md) is shorter and organized
  around the pipeline, semantic contracts, source map, and contributor workflow,
  followed by the session APIs. Corrects package boundaries and tool-dependent
  test coverage, and adds the missing query/overlay files to the source map.
- [Design rationale](comments.md) is organized around a topic index and shorter
  explanations of current choices. Cuts obsolete migration inventories and
  resolved implementation reports; corrects slicing, UTF-8 boundaries, cleanup,
  allocation, and switch rationale. The spec and container tutorial also clarify
  raw byte offsets and explicit mutable slicing.
- [Contributor instructions](AGENTS.md) scope coordinated updates and regression
  tests to behavior changes, define documentation checks, and clarify compiler
  rebuilds and local full-gate use. Detailed test commands move to
  [Testing and verification](compiler-architecture.md#testing-and-verification).
- [Standard library](standard-library.md) adds a task index and usage examples,
  corrects UTF-8 byte-search boundaries, allocator selection, resource
  lifecycles, package ordering, finite-float round trips, and fallible string
  allocation descriptions. Rationale, compiler support, testing guidance, and
  planned APIs move to their owning documents.
- [Releasing](releasing.md) uses one version-selection table and a shorter
  checklist. Shared compatibility rules explicitly apply to current releases;
  failed workflows distinguish retries from unpublished source fixes, and
  published tags remain immutable.
- Removed separate language-generation labels from the specification, guides,
  roadmap, and source comments. Releases identify the specification at their
  own tag; runtime ABI versioning is unchanged.
- [readme.md](readme.md) now leads with installation and a checked first
  program. Detailed compiler options and C-host linking instructions live in
  [compiler-guide.md](compiler-guide.md). Collection overrides and executable
  location are clarified, and the library overview links to the full API docs.
  Release bundles include the Markdown documentation and tutorials, and the
  release verification checks their local document links.
- The [tutorials](tutorials/README.md) explain non-null references and omitted
  fields that have no zero value, document nullable C pointers and their
  `Option` ABI, and repair the initialization cross-reference. Checked examples
  cover required reference fields, optional fields, and nullable C results.
- [comments.md](comments.md#signed-shifts-stay-bit-operations) records why
  signed `<<` stays modular rather than checked, and
  [design.md](design.md#integer-operators) now says `x<<1` equals `x*2` only
  when the product fits.
- [open-questions.md](open-questions.md#language-design-review-2026-10-03)
  records a language-design review with prioritized proposals, compiler probes,
  and tradeoffs for ownership, safety, expressiveness, performance, and syntax.
- [design.md](design.md#distinct-types) states that a distinct type keeps its
  underlying type's comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`) while
  inheriting no other operator, as the compiler already behaved; arithmetic
  still needs `delegate` or a forwarding overload. A procedure constant ends at
  its body's `}`, so calling the literal in place is written
  `VALUE :: (proc() -> int { return 7; })();` ([grammar.md](grammar.md#declarations)).
- [design.md](design.md) qualifies ownership and last-use transfer summaries,
  groups argument modes under parameter semantics, and makes copy-cost warnings
  explicitly optional. It distinguishes parameter storage from carried borrows
  and procedure-type effects from inferred global writes.
- [comments.md](comments.md) separates current rationale from design history and
  compiler notes, explains borrow-checking terms, and corrects stale pointer,
  map, and `Option` descriptions. Callable proposals are in
  [open-questions.md](open-questions.md#callable-records-procedures-and-closures).
- Stale open questions are removed or corrected against the current compiler
  and tutorials. The completed compiler audit is recorded in
  [comments.md](comments.md#compiler-architecture-audit-2026-09-28), with its
  regression citations updated.
- [tutorials/](tutorials/README.md): nine pages that teach Loke from installing
  it to a program in several packages and a call into C. The test suite builds
  and runs every program on them and checks what the page says it prints.
- A release attaches `perf.json`: compile time, compiler memory, and executable
  size for every example, and the run time of the programs in `bench/`.
  `perf.ps1` produces it and compares it with an earlier one.
- [releasing.md](releasing.md) states what a version promises before and
  after 1.0, where upgrade notes go, and the release checklist.

## [0.7.1] - 2026-09-27

The first published release: the language specified by
[design.md](design.md) and [grammar.md](grammar.md), implemented by `lokec` with
no open entries in [known-gaps.md](known-gaps.md).

### Language

- Value semantics with visible ownership: strings, dynamic arrays, and maps are
  managed values with language-defined copy, move, and cleanup, and a copy that
  may allocate is written, never implied.
- Borrows, lifetimes, and places checked by the compiler, without Rust-style
  complete memory safety; explicit `unsafe` marks the trust boundary.
- Records, enums, unions, and methods; operators and indexing defined by
  records; interfaces used both as generic bounds and as erased `dyn` views.
- Monomorphized generics with `where` bounds, compile-time execution, and
  conditional compilation, in place of a preprocessor or macro system.
- Errors as values with `or_return`, `or_else`, and optional-ok, plus panics
  with unwinding.
- Allocators and regions, threads and atomics with a defined memory model, SIMD
  vectors, and C interoperability through the C ABI and C-compatible types.

### Compiler

- `lokec` checks a program or a package directory and builds an executable or
  object through LLVM IR and Clang, at five optimization levels (`-opt=none` to
  `-opt=aggressive`).
- Package imports, `-collection name=path` roots, foreign imports including
  NASM `.asm` sources, `-emit-ll`, `-check-layout`, and `-print-toolchain`.
- Diagnostics with stable codes (`L0001` onwards) and source spans.

### Standard library

- `base:` `runtime`, `meta`, and `interfaces`.
- `core:` `mem`, `unsafe`, `sync`, `simd`, `thread`, `fmt`, `strconv`,
  `strings`, `cstrings`, `encoding/utf16`, `endian`, `math`, `slice`,
  `container`, `log`, `io`, `path`, `fs`, `term`, and `os`, specified in
  [standard-library.md](standard-library.md).

### Platform and limits

- Windows x64 only. Building programs needs LLVM/Clang and the MSVC build tools
  with the Windows SDK; building `lokec` itself needs Odin `dev-2025-09`.
- The release is a zip of `lokec.exe` with the `base/`, `core/`, `runtime/`,
  and `examples/` trees it finds beside itself; unzip it anywhere.
- Not yet available: a package manager, a language server, debug information,
  and Linux or macOS targets ([future-plans.md](future-plans.md)).
