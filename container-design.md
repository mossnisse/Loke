# Queue containers for `core:container`

**Status: proposal, not implemented.** Nothing here is part of the
[standard library](standard-library.md) yet. Implementing it moves the API text
to `standard-library.md` and the rationale to `comments.md`, and retires this
file.

`core:container` has fixed-capacity arrays, enum sets and arrays, and index
sets, but nothing that hands back the most urgent element or a queue's oldest.
Programs fall back on `remove(0)`, which shifts the whole array, or on private
heaps. This document adds two general-purpose types and the algorithms under
them:

| Addition | Package | For |
| --- | --- | --- |
| `Priority_Queue(T, C)`, `Min_Queue(T)`, `Max_Queue(T)` | `core:container` | Taking the most urgent element next: schedulers, event simulation, best-first search, top-k, k-way merge |
| `Deque(T)` | `core:container` | First in, first out, and work at both ends: breadth-first search, work lists, sliding windows, undo history |
| `make_heap`, `push_heap`, `pop_heap`, `sift_heap_top`, `is_heap` | `core:slice` | A heap in storage the caller already has, such as a `Small_Array` |
| `Ascending(T)`, `Descending(T)` | `core:slice` | The comparators most orderings need, for sorting and heaps alike |

The members and examples here were compiled and run against the compiler at
commit `990612d0` in a throwaway prototype. The exceptions are the variadic
`append` and the copying `prepend`, which repeat `Small_Array`'s procedure groups.
[What the prototype found](#what-the-prototype-found) lists what that turned up,
including two compiler bugs, one since fixed.

- [Choosing a container](#choosing-a-container)
- [Shared conventions](#shared-conventions)
- [`Priority_Queue`](#priority_queue)
- [Heap algorithms in `core:slice`](#heap-algorithms-in-coreslice)
- [`Deque`](#deque)
- [What the prototype found](#what-the-prototype-found)
- [Alternatives not taken](#alternatives-not-taken)
- [Later containers](#later-containers)
- [Implementation plan](#implementation-plan)
- [Open questions](#open-questions)

## Choosing a container

| Need | Use |
| --- | --- |
| A sequence that grows and shrinks at its end | `[dynamic]T` |
| The same, with a small fixed bound and no allocation | `Small_Array(T, N)` |
| Add at one end, remove at the other; work at both ends | `Deque(T)` |
| Always take the most urgent element | `Priority_Queue(T, C)` |
| The same, with no allocation or in a caller's buffer | `core:slice` heap algorithms over a `[]mut T` |
| Pass items between threads | [`thread.Channel`](standard-library.md#channels), [`thread.Ring`](standard-library.md#rings) |
| Look up by key | `map[K]V` |
| Sets of enum members or small indices | `Bit_Set(E)`, [index sets](standard-library.md#corecontainer-index-sets) |

`Deque` and `thread.Ring` are both ring buffers and share nothing else. `Ring`
is a bounded communication primitive between two threads: it is move-only, has
no zero value, uses atomics, and never grows. `Deque` is an ordinary local
value that grows, copies when its elements do, and has no thread-safety of its
own.

## Shared conventions

Both types follow what the library's other owning containers do, so that a call
reads the same as on `[dynamic]T`.

- **Fallible forms.** `push`, `append`, `reserve`, and the rest follow the
  allocator's [failure policy](design.md#allocation-failure). Each `try_` form
  returns `Status(Allocator_Error)` and leaves the container unchanged, under
  the [`try_` convention](standard-library.md#errors-are-values).
- **Element ownership.** Insertions are procedure groups, as on
  [`Small_Array`](standard-library.md#fixed-capacity-arrays): a borrowed place is
  copied, and a temporary or `move(x)` transfers. Under
  [container insertion](design.md#container-insertion), a failed `try_` form
  drops an element it took. A caller who must keep the element reserves first
  and then inserts, which cannot fail for want of space.
- **Move-only elements.** Held in full. Members that copy an element are bound
  on `is_copyable(T)` and are absent from a move-only instance. As for every
  container, the [sequence interfaces](standard-library.md#standard-interface-catalogue)
  then do not apply.
- **Borrowed elements.** Insertion parameters are `@(escape=stored)`, so an
  element may carry a borrow and the container then carries it too, under
  [values that contain borrows](design.md#values-that-contain-borrows).
- **Absence.** `pop` and its relatives return `Option(T)`, and a peek returns
  `Option(^T)`. An empty container is not an error.
- **Programmer errors panic.** An index out of range panics, as an array index
  does, and a negative capacity panics, as in `Dynamic_Index_Set.init`.
- **Capacity is reusable.** `clear` drops the elements and keeps the storage,
  and only `shrink` gives storage back. A queue reused across searches or
  frames stops allocating once it has reached its largest size.
- **Allocators.** A zero value binds the default allocator when it first needs
  storage. `init` and `try_init` select another, as `Dynamic_Index_Set` does.
  [`via`](design.md#assignment-statements) governs a clone into the variable; it
  does not bind the storage of a record's dynamic-array field, so `init` is how a
  record container is placed in an arena.

## `Priority_Queue`

```loke
Priority_Queue :: struct($T, $C: type)
	where interfaces.Callable(C, proc(left, right: T) -> bool) { /* private */ }

Min_Queue :: Priority_Queue($T, slice.Ascending(T));
Max_Queue :: Priority_Queue($T, slice.Descending(T));
```

```loke
jobs: container.Min_Queue(int) = {};
jobs.push(5);
jobs.push(2);
jobs.pop();   // .some(2)
```

### Ordering

The comparator is the one [`slice.sort_by`](standard-library.md#sorting-slices)
takes, called `less`. It must define a strict weak ordering of the queued
elements. `pop` returns an element that no other queued element is `less` than,
so a queue drains in an order `sort_by` could produce with the same comparator:
**the smallest first**. A largest-first queue uses `Descending` or a comparator
written the other way around. C++ and Rust default to largest-first; this follows
Loke's own sort.

**Equal elements come out in an unspecified order**, which need not be arrival
order and may change between versions. A caller who needs one writes a tie
breaker into the element, usually a sequence number:

```loke
Order :: (deadline: i64, sequence: u64);

By_Deadline :: struct {}
impl By_Deadline {
	call :: proc(self, left, right: Request) -> bool {
		return Order{left.deadline, left.sequence} < Order{right.deadline, right.sequence};
	}
}
```

[Ordered anonymous records](comments.md#ordered-anonymous-records) compare
lexicographically, so a tie breaker costs no comparator logic. When the element
itself is such a record, `Min_Queue` needs no comparator at all.

A comparator that is not a strict weak ordering, or a NaN under `Ascending(f32)`,
gives an unspecified order and nothing worse, as for `sort_by`: every element is
still in the queue exactly once, and each operation still terminates. A panicking
comparator leaves the same state, since sifting only swaps elements; no element is
lost or dropped twice, though the order afterwards is unspecified.

### Comparators

The comparator is part of the queue's type and is stored in it. A heap's order is
only meaningful under one comparator, so tying the two together rules out
pushing with one and popping with another. It also calls the comparator directly,
makes a stateless one zero-sized, and lets the borrow checker protect what the
comparator reads:

```loke
cost := [4]int{9, 1, 5, 3};
less := proc(left, right: int) -> bool capture(&cost) { return cost[left] < cost[right]; };
Less :: type_of(less);
nodes := Priority_Queue(int, Less).init(move(less));
nodes.push(0);
cost[0] = 2;      // L0511: `cost` is borrowed by the queue, which is used below
nodes.push(1);
```

Changing a key while it is queued would silently corrupt a heap; here it is a
compile error for as long as the queue is live. A program whose keys must change
keeps the key in the element and pushes a new entry, as
[the A* example](#best-first-search) does.

Each kind of callable works, with these differences:

| Comparator | Example type | Zero value of the queue | Named in a file-scope record |
| --- | --- | --- | --- |
| Library | `Ascending(int)` | yes | yes |
| Named record | `By_Deadline` | when its fields have one | yes |
| Procedure | `proc(left, right: T) -> bool` | no, `init` is required | yes |
| Capture literal | `type_of(less)` | no | no: [no signature can name it](design.md#capture-literals) |
| [Borrowed view](design.md#borrowed-callable-views) | `dyn proc(left, right: T) -> bool` | no | yes, and it carries its borrow |

A queue whose comparator has no zero value has no zero value either, and `= {}` is
a compile error (`L0424`) rather than a queue with no comparator to call. A type
that is not a comparator is rejected where the queue type is named (`L0444`).
A move-only comparator makes the queue move-only, as for any record.

### Members

```loke
Priority_Queue(T, C).init(less: move C, capacity := 0, allocator := mem.default_allocator()) -> Priority_Queue(T, C)
Priority_Queue(T, C).try_init(less: move C, capacity := 0, allocator := mem.default_allocator())
	-> Result(Priority_Queue(T, C), Allocator_Error)
Priority_Queue(T, C).from_items(items: move [dynamic]T, less: move C) -> Priority_Queue(T, C)

container.priority_queue($T: type, less: move $C, capacity := 0, allocator := mem.default_allocator())
	-> Priority_Queue(T, C)
```

The free `priority_queue` infers the comparator type, which spares binding
`type_of(less)` to a name first: `priority_queue(int, move(less))`. Its result
carries the comparator's borrow, as the `init` result does. A stateless comparator
is spelled `{}`, as in `Max_Queue(int).init({}, 64)`.

| Member | Cost | Meaning |
| --- | --- | --- |
| `len()`, `cap()`, `is_empty()` | O(1) | As on a dynamic array. |
| `peek() -> Option(^T)` | O(1) | The element `pop` would return, lent until the queue next changes. |
| `push(value)`, `try_push(value)` | O(log n) amortized | Adds an element. |
| `pop() -> Option(T)` | O(log n) | Removes and returns the first element. Never allocates. |
| `push_pop(value) -> T` | O(log n) | As `push` then `pop` with one sift. Never allocates, so it works on a full queue. Keeps the k largest with a `Min_Queue` of k elements. |
| `update_top(change) -> bool` | O(log n) | Runs `change(inout top)` and restores the order, or is false when empty. |
| `retain(keep)` | O(n) | Drops each element for which `keep(item)` is false, then rebuilds. Cancelling requests is the usual use. |
| `reserve(n)`, `try_reserve(n)`, `shrink(min)`, `try_shrink(min)`, `clear()` | as on a dynamic array | Capacity, as on a dynamic array. |
| `from_items(items, less)` | O(n) | Takes over an array and its allocator and orders it; much faster than pushing each element. |
| `into_items(self: move) -> [dynamic]T` | O(1) | The elements in unspecified order, with the storage. |
| `into_sorted(self: move) -> [dynamic]T` | O(n log n) | The elements in `pop` order, in place. |
| `view() -> []T`, `iter()` | O(1) | Read every element, in unspecified order. |
| `format` | O(n) | Prints as an array, in unspecified order. |

The queue is `Iterable` but not a `Sequence`, because an index into a heap means
nothing a caller could use. No member exposes an element mutably except
`update_top`, which is what keeps the order correct: it cannot be forgotten, as a
separate "re-sift" call could be. The generated copy clones the elements and the
comparator. There is no `==`, and the compiler already rejects one as not
comparable, which is right, since two equal queues can have different layouts.

The representation is a `[dynamic]T` and a `C`, with no `core:unsafe` at all, and
no hooks. It sifts by [`swap`](standard-library.md#swapping-elements), so it needs
neither a zero value nor a copy of `T`. Its layout is deliberately unspecified:
it is a binary heap today, and a measured wider one could replace it.

### Examples

#### Best-first search

The open set holds duplicates, and a popped entry worse than the best known
distance is stale and skipped. This is simpler than decrease-key, needs no
position table, and stays as a good default:
[later containers](#later-containers) keeps the indexed form for a caller who
measures a need for it.

```loke
Open_Entry :: (f: int, g: int, node: int);

shortest_path :: proc(graph: [][]Edge, start, goal: int) -> Option(int) {
	best := make([dynamic]int, graph.len());
	foreach (&mut distance in best) { distance = 1 << 62; }
	best[start] = 0;

	open: container.Min_Queue(Open_Entry) = {};
	open.push(Open_Entry{heuristic(start, goal), 0, start});

	for (;;) {
		switch (open.pop()) {
		case .none:
			return .none;
		case .some(entry):
			if (entry.g > best[entry.node]) { continue; }   // stale
			if (entry.node == goal) { return .some(entry.g); }
			foreach (edge in graph[entry.node]) {
				g := entry.g + edge.cost;
				if (g < best[edge.to]) {
					best[edge.to] = g;
					open.push(Open_Entry{g + heuristic(edge.to, goal), g, edge.to});
				}
			}
		}
	}
}
```

#### A request scheduler

A move-only element with owned contents, a tie breaker, an allocation failure
reported to the caller, and a queue held in a file-scope record:

```loke
@(move_only) Request :: struct { deadline: i64, sequence: u64, body: [dynamic]u8 }

Scheduler :: struct {
	waiting: container.Priority_Queue(Request, By_Deadline),
	next_sequence: u64,
}

impl Scheduler {
	submit :: proc(self: inout, deadline: i64, @(escape=stored) body: move [dynamic]u8) -> Status(Allocator_Error) {
		self.next_sequence += 1;
		return self.waiting.try_push(Request{deadline, self.next_sequence, move(body)});
	}

	next :: proc(self: inout) -> Option(Request) { return self.waiting.pop(); }
}
```

#### Top k, and merging sorted runs

```loke
largest :: proc(values: []int, k: int) -> [dynamic]int {
	kept: container.Min_Queue(int) = {};   // its top is the smallest kept
	kept.reserve(k);
	foreach (value in values) {
		if (kept.len() < k) { kept.push(value); } else { _ = kept.push_pop(value); }
	}
	return move(kept).into_sorted();
}
```

A k-way merge keeps one `Run` per input, ordered by its next value. `update_top`
advances the winning run and restores the order in one sift, rather than a pop
and a push:

```loke
heads.update_top(proc(top: inout Run) capture(&mut out, &mut exhausted) {
	out.append(top.data[top.at]);
	top.at += 1;
	exhausted = top.at == top.data.len();
	if (exhausted) { top.at -= 1; }   // the comparator must still read a valid head
});
if (exhausted) { _ = heads.pop(); }
```

## Heap algorithms in `core:slice`

The queue is built on these, and they are public because a heap is also useful in
storage no queue owns: a `Small_Array`, an arena block, a record's fixed array, or
a stream's bounded window. This is the same layering as `Index_Set` and its views.

```loke
make_heap     :: proc(values: []mut $T, less: $C)          // order the whole slice, O(n)
push_heap     :: proc(values: []mut $T, less: $C)          // the last element joins the heap before it
pop_heap      :: proc(values: []mut $T, less: $C)          // the first element moves to the last place
sift_heap_top :: proc(values: []mut $T, less: $C)          // restore the order after the first element changed
is_heap       :: proc(values: []$T, less: $C) -> bool

Ascending  :: struct($T: type) where interfaces.Ordered(T) {}   // callable: left < right
Descending :: struct($T: type) where interfaces.Ordered(T) {}   // callable: right < left
```

Each requires `interfaces.Callable(C, proc(left, right: T) -> bool)`, and each
borrows its comparator for the call, retains nothing, and allocates nothing, as
`sort_by` does. An empty slice is a no-op. A fixed-capacity queue needs nothing
else:

```loke
open: container.Small_Array(int, 64) = {};
less := slice.Ascending(int){};

open.try_append(value) or_return;
slice.push_heap(open.slice(), less);

slice.pop_heap(open.slice(), less);
top := open.pop();
```

Here the layout is specified, because the storage belongs to the caller: a binary
heap in array order, with the first element first in the comparator's order, and
each element's parent at `(i - 1) / 2`. Readers coming from C++ should note the
direction: `std::make_heap` puts the largest first, and these put first what
`sort_by` would.

`Ascending` and `Descending` live in `core:slice` so that `slice.sort_by(values,
slice.Descending(int){})` works too, and `core:container` imports `core:slice`.

## `Deque`

```loke
Deque :: struct($T: type) { /* private */ }
```

```loke
frontier: container.Deque(int) = {};
frontier.append(seed);
for (;;) {
	switch (frontier.pop_front()) {
	case .none:
		return;
	case .some(at):
		foreach (next in neighbours(at)) {
			if (visit(next)) { frontier.append(next); }
		}
	}
}
```

### Naming

The names extend a dynamic array's, rather than introducing `push_back`:
`append` and `pop` at the end, and `prepend` and `pop_front` at the start. Generic
code that accepts `[dynamic]T` therefore accepts a `Deque(T)`, and replacing one
with the other when `remove(0)` shows up in a profile changes only the type and
that one call.

For a copyable element, `Deque(T)` satisfies `Iterable`, `Reverse_Iterable`,
`Mutable_Iterable`, `Sequence`, `Mutable_Sequence`, and `Growable_Sequence`. A
move-only element leaves it the three iteration interfaces, under the
[usual rule](standard-library.md#standard-interface-catalogue).

### Members

```loke
Deque(T).init(capacity := 0, allocator := mem.default_allocator()) -> Deque(T)
Deque(T).try_init(capacity := 0, allocator := mem.default_allocator()) -> Result(Deque(T), Allocator_Error)
```

The zero value is an empty, usable deque.

| Member | Cost | Meaning |
| --- | --- | --- |
| `len()`, `cap()`, `is_empty()` | O(1) | As on a dynamic array. |
| `append(values)`, `try_append(values)` | O(1) amortized | Add at the end. The copying `try_` form takes several values and adds all or none. |
| `prepend(value)`, `try_prepend(value)` | O(1) amortized | Add at the start, one at a time, so the order is never in question. |
| `pop() -> Option(T)`, `pop_front() -> Option(T)` | O(1) | Remove from either end. Never allocate or move other elements. |
| `first()`, `last() -> Option(^T)` | O(1) | Lend an end, read-only. |
| `first_mut()`, `last_mut() -> Option(^mut T)` | O(1) | Lend an end, mutably. |
| `x[i]`, `x[i] = v`, `at(i) -> ^T` | O(1) | Indexed from the first element. `x[i]` reading copies, so a move-only element reads through `at`. |
| `insert(i, value)`, `remove(i) -> T` | O(min(i, n - i)) | Moves whichever side is shorter. |
| `retain(keep)` | O(n) | Keeps order, and drops each element for which `keep(item)` is false. |
| `reserve(n)`, `try_reserve(n)`, `shrink(min)`, `try_shrink(min)`, `clear()` | as on a dynamic array | Capacity, as on a dynamic array. |
| `as_slices() -> (front, back: []T)` | O(1) | The elements in order, as up to two runs; `back` is empty unless the ring has wrapped. For bulk copies and I/O. |
| `as_slices_mut() -> (front, back: []mut T)` | O(1) | The same, writable. |
| `make_contiguous() -> []mut T` | O(n) when wrapped | Rearranges in place so that one slice holds everything. Never allocates. |
| `iter()`, `iter_reverse()`, `iter_mut()`, `iter_mut_reverse()` | O(1) | Traverse from either end. `foreach` borrows, as for an array. |
| `==` | O(n) | Equal lengths and equal elements in order, regardless of where the ring starts. |
| `format` | O(n) | Prints as an array, in order. |

There is no `x[a:b]`, because a range may not be contiguous; `as_slices` and
`make_contiguous` say what is actually available. Copying clones the elements in
order into a new ring from the destination's allocator, and dropping releases them
first to last.

### Representation

```loke
Deque :: struct($T: type) {
	@(private) storage: [dynamic]T,    // length always 0: the ring is its capacity
	@(private) head: int,              // the slot of the first element
	@(private) count: int,             // how many are live
	@(private) allocator: Allocator,   // where a larger ring comes from
}
```

The live elements are in slots `head`, `head + 1`, and so on, wrapping at
`storage.cap()`. Everything else is
[uninitialized capacity](design.md#uninitialized-capacity). Because the array's
length is zero, the compiler's cleanup of the field releases the allocation and
touches no element, and `hook(drop)` and `hook(copy)` own the elements.

A `[dynamic]T` is the right holder rather than a bare `[^]T`, because
[a `[^]T` field carries no provenance](design.md#values-that-contain-borrows).
With `[dynamic]T` and the `@(escape=stored)` insertion parameters, a borrow
stored in an element is tracked (keeping `&local` in an outer deque past
`local`'s end is `L0513`), an allocator reset still sees the storage, and
zero-sized elements need no special case. Reads and transfers must also keep
that provenance, through the [slot views below](#lending-elements).

Elements move in and out with [`unsafe.write` and `unsafe.take`](design.md#uninitialized-capacity).
The order of updates is the one that section requires: write and then lengthen,
shorten and then drop, so `count` is accurate wherever a panic can unwind from.
The deque must arrange the remaining element cleanup itself, as described
under [Cleanup during unwinding](#cleanup-during-unwinding).

**Growing** allocates the new ring first, then moves the elements across in order
and installs it, so a failed allocation leaves the deque exactly as it was, and
the moves themselves cannot fail. The allocator is recorded in a field because
growth must allocate before releasing and a dynamic array does not expose its own
([open question](#open-questions)). Capacity doubles with a small minimum; the
exact growth policy is implementation-defined, as it is for a dynamic array.

**`make_contiguous`** slides the back run up against the front run, then rotates
the now-contiguous run with `swap`, so no step reads a slot holding no value.

### Cleanup during unwinding

The backing array's length is always zero. Its generated cleanup releases the
allocation but cannot find the live elements, and a drop hook that panics is
not invoked a second time. Updating `count` before dropping an element prevents
a double drop; it does not by itself release the rest.

One private `drain` routine removes elements from the front until `count == 0`.
For each element it saves the slot index, advances `head` with wraparound, and
decrements `count` before taking the element through `slots_mut` and dropping
it. Thus the remaining live range is accurate before any user drop hook runs.
On completion it resets `head` to zero and keeps the allocation.

`clear` registers a deferred drain before starting the ordinary drain, and the
drop hook calls `clear`:

```loke
clear :: proc(self: inout) {
	defer self.drain();
	self.drain();
}

release :: hook(drop) proc(self: inout) { self.clear(); }
```

After a normal drain the deferred call has nothing left to do. If an element's
drop raises the first panic under `unwind`, it drains the remaining elements
in queue order before generated field cleanup releases the allocation. This
holds for explicit `drop`, normal scope exit, and `clear`, including a wrapped
ring. A [second panic during unwinding](design.md#panic-during-unwinding) aborts
immediately; neither that case nor the `abort` strategy promises a full drain.

### Lending elements

Both lending an element and moving one out must preserve provenance. `first`,
`at`, and `as_slices` lend the deque's storage; `pop`, `pop_front`, and `remove`
transfer an element whose own fields may borrow something else. A pointer or
element rebuilt from raw storage has
[unknown provenance](open-questions.md#public-borrow-contracts-should-stand-on-their-own).
A first prototype that returned one compiled a use after `pop_front` without
complaint. Taking a borrowed element directly through `unsafe.raw_data` also
allowed the removed value to outlive its source.

Every lending and removal path therefore goes through private read-only or
mutable slot views. Each lends the whole capacity through a plain procedure
type, whose
[result derives from every borrowed argument](design.md#procedure-result-contracts):

```loke
@(private)
slots_of :: proc(self: ^Deque(T)) -> []T {
	return unsafe.raw_data(self.storage)[0:self.storage.cap()];
}

@(private)
slots :: proc(self: ^) -> []T {
	reach: proc(self: ^Deque(T)) -> []T = Deque(T).slots_of;
	return reach(self);
}

@(private)
slots_mut_of :: proc(self: ^mut Deque(T)) -> []mut T {
	return unsafe.raw_data(self.storage)[0:self.storage.cap()];
}

@(private)
slots_mut :: proc(self: inout) -> []mut T {
	reach: proc(self: ^mut Deque(T)) -> []mut T = Deque(T).slots_mut_of;
	return reach(&mut self);
}
```

Removal takes through `unsafe.take(self.slots_mut()[at])`, never directly
through `unsafe.raw_data(self.storage)[at]`. A removed element retains what it
borrows, but does not borrow the deque merely because it used to be stored
there. It may outlive the deque when its own sources remain alive.

Growth, shrinking, `make_contiguous`, insertion shifts, and `retain` must
preserve the same element dependencies across their transfers. Keep raw pointer
construction inside the slot-view helpers; use the checked views for element
access, including `unsafe.write` and `unsafe.take`. These private views include
uninitialized slots: bounds checks protect the allocation, while `head` and
`count` still decide which slots may be read or taken and which may be written.

This is the technique `Monitor_Guard.read` already uses. With it, each of these
is rejected with `L0512`, and the indexing inside the deque is bounds-checked as
well:

```loke
p := q.first();     _ = q.pop_front();  use(p);    // the pointer is live
p := q.at(0);       q.clear();          use(p);
a, b := q.as_slices();   q.append(2);   use(a);
foreach (v in q) { q.append(v); }                  // the iterator is live
```

Removal also preserves the lifetime of a borrow carried by `T`:

```loke
out: []int = {};
{
	local := [1]int{42};
	q: container.Deque([]int) = {};
	q.append(local[:]);
	out = q.pop_front() or_else {};
}
use(out); // L0513: `local` has ended
```

Moving `local`'s declaration outside the block makes this valid: `q` may end
before `out` is used. Both cases were checked in standalone probes at
`b35c0bd1`. A cleanup probe at the same commit dropped only the first of three
elements when its drop hook panicked without a deferred drain; with the guard,
all three were dropped once. These checks refine the earlier prototype; the
complete deque and its tests remain implementation work.

## What the prototype found

### Measurements

One run of a `-opt=speed` build on the development machine, at the commit above.
These establish the shape of the costs, not a benchmark baseline, which
`bench/containers.loke` should supply.

| Operation | Result |
| --- | --- |
| `Deque` at constant width 1024: `pop_front` + `append`, 50M rounds | 256 ms, about 5 ns per round |
| `[dynamic]int` with a head cursor and compaction, the same work | 263 ms |
| `[dynamic]int` with `remove(0)`, at width 1024, scaled up from 500k rounds | about 3500 ms, growing with the width |
| `Deque.at`, the lending path, 50M calls | 48 ms, about 1 ns per call: the plain procedure type is optimized away |
| `Min_Queue(int)`: 4M pushes, then 4M pops | 755 ms |
| 64-byte elements: 1M pushes, then 1M pops | 658 ms |

### Compiler bugs

- **A leading type parameter lost a result's borrow. Fixed.** A procedure beginning
  with a `$T: type` parameter dropped the borrow from its result, so `drop(owner)`
  while the result was live compiled and read freed memory. The prototype found it
  because the free `priority_queue` constructor has that shape. `CHANGELOG.md`
  records the fix.
- [**A computed index is refused beside a second read of a mutable slice.**](known-gaps.md#a-computed-index-is-refused-beside-a-second-read-of-a-mutable-slice)
  `less(values[x - 1], values[x])` on a `[]mut T` of non-copyable elements is
  `L0641`, while `less(values[a], values[b])` is accepted. Sifting hits this. The
  prototype reads through a helper taking a read-only `[]T`, which the real
  implementation can keep or drop.

### Language points the implementation relies on

- A `where` bound on the struct rejects a non-comparator where the type is named,
  but [does not make `call` visible](design.md#calling-a-value) inside the
  package's members when the comparator comes from another package. Members hand
  `self.less` to the heap algorithms, which carry their own bound, as
  `slice.sort_by`'s `Ordering` does.
- A generic alias, `Min_Queue :: Priority_Queue($T, Ascending(T))`, works, and can
  be exported and instantiated from another package.
- `hook(copy)` with `where is_copyable(T)` settles the
  [declaration's copy decision](design.md#lifecycle-hooks-and-resource-types) for
  every instance and is simply absent from a move-only one, so one `Deque` serves
  both.
- `exchange(inout self.items[0], move(value))` gives `push_pop` the old top with
  no `unsafe`, and works for a type with neither a copy nor a zero value.

## Alternatives not taken

**A comparator passed to each call**, as C++'s heap algorithms and Go's
`container/heap` do. It frees the queue's type of `C`, but it lets each call name
a different ordering, and the checker can no longer keep what the comparator reads
stable between calls. The `core:slice` algorithms offer exactly this for callers
who want it; the queue does not.

**Ordering only through `Ordered(T)`**, as Rust's `BinaryHeap` with `Reverse`. It
is tidy until the order depends on state, such as a cost table or a configured
direction, and then every ordering needs its own wrapper type. `Min_Queue` gives
the same convenience for the simple case.

**Stored procedure pointers only**, as Odin does. Each comparison becomes an
indirect call, and capturing state needs a user-data pointer outside the borrow
checker. A `dyn proc` comparator offers this where type erasure is what is wanted.

**A dynamic array with a head cursor** for the deque. For plain data it is as fast
(see above), but it is not enough for a general library. The dead prefix is inside
the array's length, so the array's drop and copy would visit elements already
taken: every slot would need an `Option(T)` or a flag, which is what makes it safe
for move-only elements and also what makes it larger. It also never reuses the
front without a compaction, which is a latency spike. `prepend` has no place to go.

**A flag per slot**, as `thread.Ring`'s `Ring_Slot` has. A ring whose slots each
record whether they are live needs no `unsafe.raw_data` and no lending technique,
at the cost of a word per element, which doubles a deque of `int`. `Ring` can
afford it because its capacity is small and fixed. A general queue of small
elements cannot.

**Two stacks**, one per end. It needs no unchecked code at all, but `pop_front`
may then have to reverse half of the other stack: a single pop becomes O(n), and
it may need to allocate, while `pop` promises neither.

**A list of blocks**, as C++ `std::deque`. Its one advantage is that elements do
not move when it grows, and in Loke the borrow checker already forbids holding a
pointer across a growth, so the indirection buys nothing.

**A language built-in.** Nothing here needs the compiler, and the
[package rule](standard-library.md#small-packages-and-explicit-imports) keeps what
needs no compiler out of `base:`.

**Other heaps.** Pairing and Fibonacci heaps win on paper for decrease-key, and
in practice lose to an array heap on cache behaviour. Published measurements of
Dijkstra's algorithm (Chen et al., "Priority Queues and Dijkstra's Algorithm",
2007) find a plain heap with duplicate entries competitive with decrease-key as
well, which is why that is the default recipe here.

## Later containers

Not designed here, and listed so that this design leaves room for them. Each is
worth having in a general-purpose library on its own merits, and they appear in
the suggested order.

| Type | What it adds | Shape |
| --- | --- | --- |
| `Set(T)` | Hash set with `in` and set algebra. | A wrapper over `map[T]Unit` with `T` `Hashable`. A map with a zero-sized value already works. |
| `Ordered_Map(K, V)`, `Ordered_Set(T)` | Sorted iteration, nearest-key and range queries, which `map` cannot offer. | A B-tree, ordered by `Ordered(K)` or a stored comparator exactly as `Priority_Queue` stores one. |
| `Slot_Map(T)` | Stable handles with generation checks, O(1) insert and remove. For graphs and entity tables that would otherwise fight the borrow checker. | Dense or sparse slots, with a `Handle` value type. |
| `Indexed_Priority_Queue` | True decrease-key, for a caller who has measured that duplicates cost too much. | Keys are `0 ..< cap`, with a position table beside the heap, so `set_priority(key, value)` is O(log n). |
| `Small_Deque(T, N)` | A ring with inline storage and no allocation. | As `Deque`, over `[N]T`; see [the open question](#open-questions). |
| `Inline_Array(T, N)` | A small array that spills to the heap. | `Small_Array` plus a `[dynamic]T`. |

**Linked lists are deliberately left out.** Lists lose to arrays on cache behaviour
for nearly all uses, and an owning doubly-linked list has no good expression under
the borrow rules. `Slot_Map` with indices gives the same O(1) unlinking with
checked handles.

Concurrent containers stay in [`core:thread`](standard-library.md#corethread).

## Implementation plan

1. Fix the
   [computed index rejection](known-gaps.md#a-computed-index-is-refused-beside-a-second-read-of-a-mutable-slice),
   or keep the helper that avoids it.
2. Add the heap algorithms and `Ascending`/`Descending` to `core:slice`.
3. Add `Priority_Queue` and its aliases to `core:container`.
4. Add `Deque`.
5. Add `bench/containers.loke`, and measure whether a hole-based sift, which moves
   instead of swapping, is worth its panic handling for large elements.

Each step updates in the same commit:
[`standard-library.md`](standard-library.md) (the task table, the package layout,
and a section under `core:container`), `comments.md` for the rationale above,
`CHANGELOG.md`, and the regenerated `api.loki` files. The final step removes this
file and the [`future-plans.md`](future-plans.md#standard-library-maturity)
pointer to it.

Testing follows
[standard-library verification](compiler-architecture.md#standard-library-verification),
and adds these:

- **Model tests.** Random operation sequences checked against a sorted array
  (queue) and a plain array (deque), crossing every wrap and growth boundary.
- **Ownership.** A move-only element whose drop hook counts: each element is
  dropped exactly once through `pop`, `clear`, `retain`, `push_pop`, `update_top`,
  growth, `into_items`, explicit `drop`, and scope exit. Check a panicking
  comparator under `unwind`. For deque `clear`, explicit `drop`, and normal
  scope exit, make the first or a middle element's drop hook raise the first
  panic: every remaining element must drop once, in queue order, before storage
  is freed. Run with wrapped and unwrapped rings. Separately check that a second
  panic during unwinding aborts without requiring the remaining cleanup.
- **Failure.** A small arena makes every `try_` form fail: the container is
  unchanged and still usable, a borrowed element is untouched, and a moved one is
  dropped.
- **Bad comparators.** A random and an always-true comparator terminate, lose no
  element, and reach no out-of-range slot.
- **Diagnostics.** The `L0512` and `L0511` cases shown above, as `tests/` diagnostic
  cases, so that a compiler or library change cannot quietly unhook a borrow.
  For `pop`, `pop_front`, and `remove`, reject a removed slice or record carrying
  a borrow used after its source ends (`L0513`), and accept the same value
  outliving the deque while its source remains alive. Repeat after growth,
  shrinking, compaction, insertion shifts, and `retain`, with wrapped storage
  where applicable. Also check allocator-region dependencies on removed owners,
  so a reset cannot invalidate a live result.
- **Interfaces.** `static_assert` of each catalogue interface claimed above.

## Open questions

- **A dynamic array's allocator.** `x.allocator` is not a member, which is the only
  reason `Deque` has its own field. An `x.allocator()` query would remove it, and
  would help any library container that replaces its storage. Is the query worth
  having for its own sake?
- **A written borrow contract.** `Deque.slots` goes through a plain procedure type
  because no declaration can say "this result borrows `self`".
  [The written result contract](open-questions.md#public-borrow-contracts-should-stand-on-their-own)
  proposed there would replace the technique here as well as in `Monitor_Guard` and
  `Shared`.
- **Inline ring storage.** `@(initialized = count)` describes a live prefix, not a
  wrapped range. A prototype `Small_Deque` works by naming a field that is always
  `0`, so that the generated copy and drop touch nothing and hooks do the rest, but
  that stretches the attribute's promise that the first `count` elements are the
  values. Either bless this as the way to opt out of generated element handling, or
  give it its own spelling before `Small_Deque` is built.
- **Handing back a refused element.** A failed `try_push(move(x))` drops `x`, as all
  container insertion does. `Ring.try_send` hands the item back instead, because
  there a full ring is routine; an out-of-memory queue is not, and `try_reserve`
  first covers the caller who cares. This design stays with the language rule, but a
  bounded queue, if one is added, should reconsider it.
