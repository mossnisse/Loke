# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### A failed file unlock is forgotten before the native lock is released

The [file-locking contract](standard-library.md#file-locking) gives each
`fs.File` one lock and makes `unlock` release it. In
[fs.loke](core/fs/fs.loke), `File.unlock` instead clears `self.locked` before
calling the fallible `unlock_handle`. If that call fails while leaving the
native lock held, a retry answers success without attempting the release;
`check_lockable` also admits another acquisition, and `close` skips its
explicit unlock.

Minimal fault-injection reproduction: in an isolated copy of `core:fs`, make
the first `unlock_handle` call return
`.err(io.make_error(.Interrupted, .Unlock))` before calling `UnlockFileEx`,
then run:

```loke
package main;
import "core:fmt";
import "core:fs";
main :: proc() {
    owner := fs.create("unlock-repro.bin") or_else panic("open");
    other := fs.open_read("unlock-repro.bin") or_else panic("open");
    _ = owner.lock(.Exclusive);
    _ = owner.unlock(); // injected failure: the native lock is still held
    _ = owner.unlock(); // reports success without retrying the native call
    fmt.println(other.try_lock(.Exclusive) or_else false);
}
```

This prints `false`. Calling `unlock_handle(self.handle) or_return` before
clearing `self.locked` makes the retry release the lock and prints `true`.
Both outcomes were verified with the injected failure; no native unlock
failure was observed in the ordinary filesystem tests. Preserve the lock
state on failure and add a regression that injects a failed release.
Found reviewing `cf74b6e2` on 2026-10-30.

### Storing one element of a local view resliced from itself is rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a store
replace what one place held. A local view whose definitions are each a borrow,
or a constant reslice of another such view, now replaces the one element it
names, but a view resliced from itself does not:

```loke
package main;
Node :: struct { value: int }
Counted :: struct { head: ^mut Node, tail: ^mut Node, count: int }
self_resliced :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3}; d := Node{4}; e := Node{5}; f := Node{6};
    arr := [3]Counted{{&mut a, &mut b, 0}, {&mut c, &mut d, 0}, {&mut e, &mut f, 0}};
    s := &mut arr[:];
    s = &mut s[1:];
    for (round := 0; round < 2; round += 1) {
        h := s[0].head;
        h^.value = 1;
        s[0].head = s[0].tail; // L0641, should be allowed
    }
}
main :: proc() {}
```

`publish_view_of` in [src/borrow.odin](src/borrow.odin) relates a view to the
range its borrow lends from each definition of the slot, wherever it stands,
so a definition that reslices the slot itself refers back to itself and the
view's start counts as unknown. Telling the two definitions apart needs the
view's start tracked per program point, like the loans a slot holds. When the
reslice runs inside the loop, the store may name several places and rejecting
it is correct. Found while closing the resliced-view case on 2026-10-30.

### Recursive directory creation visits prefixes removed by normalization

The [`core:fs` path contract](standard-library.md#corefs) says that only the
elements remaining after native normalization are looked up. Recursive
directory creation instead visits each written prefix before Windows can
normalize the complete path. In a fresh working directory:

```loke
package main;
import "core:fmt";
import "core:fs";
main :: proc() {
    _ = fs.create_directories("normalization-repro/skipped/../made");
    fmt.println(fs.exists("normalization-repro/skipped") or_else false);
}
```

This prints `true`: `skipped` is created even though normalization removes
it from the final path. If `skipped` is an existing file, the operation fails
before creating `made`, although the normalized destination has no such
component. `create_directories` in [fs.loke](core/fs/fs.loke) calls
`ensure_directory` for each prefix of the original string. The new
[normalization test](tests/run/lib_fs_link_normalization.loke) uses an
existing directory junction, so it does not reveal these extra operations.
Found reviewing `d3cb447a` on 2026-10-30. Either document prefix processing as
an exception to the blanket normalization guarantee, or normalize ordinary
paths before recursive creation while preserving the extended-length path
rules. Cover a missing and a file-valued component canceled by `..`.

### A storing call rejects a named read-only reborrow

[Weakening and reborrows](design.md#weakening-and-reborrows) says that copies
of a read-only reborrow extend its loan without suspending the read-only
carrier itself. Passing such a copy to a
[`stored` parameter](design.md#retaining-a-borrow) is legal:

```loke
package main;
Node :: struct { value: int }
Holder :: struct { head: ^Node }
sink :: proc(value: int) {}
keep :: proc(p: ^mut Holder, @(escape=stored) n: ^Node) { p^.head = n; }
caller :: proc(p: ^mut Holder, @(escape=stored) r: ^mut Node) {
    read: ^Node = r;
    keep(p, read); // L0641, should be allowed
    sink(p^.head^.value);
}
main :: proc() {}
```

This compiled before `bb65c244` and is rejected by that commit.
`prov_reborrow_retained` in [cfg_provenance.odin](src/cfg_provenance.odin)
links `read` to the destination with `passes_on` left false, so the call's
own use of its read-only argument conflicts with the stored copy. Ordinary
copies in `prov_reborrow` set `passes_on` for read-only sources. Apply the
same rule to retained copies, and cover a named read-only reborrow as well
as the implicit weakening of a mutable argument. Found reviewing `bb65c244`
on 2026-10-30.

### Loading a stored named read-only copy loses its mutable source

[Weakening and reborrows](design.md#weakening-and-reborrows) keeps the mutable
source of a read-only reborrow suspended through copies, including copies
stored through a pointer and subsequently loaded:

```loke
package main;
Node :: struct { value: int }
Holder :: struct { head: ^Node }
sink :: proc(value: int) {}
caller :: proc(p: ^mut Holder, @(escape=stored) r: ^mut Node) {
    read: ^Node = r;
    p^.head = read;
    h := p^.head;
    r^.value = 1; // should be L0641: h still reborrows r
    sink(h^.value);
}
main :: proc() {}
```

This compiles both before and after `bb65c244`. Its new
`prov_slot_reborrows_mutable` in
[cfg_provenance.odin](src/cfg_provenance.odin) only recognizes an immediate
mutable source. Here the stored slot derives from `read`, which is read-only,
so `prov_reborrow_loaded` leaves the load's copies pending and the later use
of `h` does not keep `r` suspended. Resolve the transitive reborrow ancestry
when activating loaded read-only copies, including named intermediates.
Found reviewing `bb65c244` on 2026-10-30; this remains outside the direct
mutable-to-read-only store covered by that commit's regression cases.
