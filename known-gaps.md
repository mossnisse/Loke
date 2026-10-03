# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

## Gaps

### Temporary and unwinding drops are not write effects

[design.md "Global write effects"](design.md#global-write-effects) counts a
`hook(drop)` as a call wherever a value is dropped. The compiler counts drops
at scope exit, `drop`, assignment, a `move` parameter's return, and `clear` or
a shrinking `resize`, but not a temporary dropped at the end of its statement
(including a discarded `pop` or `remove` result) or a drop during panic
unwinding. This program is accepted and reads freed storage:

```odin
package main;
import "core:fmt";

cache: [dynamic]int;
Guard :: move_only struct { active: bool }
impl Guard {
    release :: hook(drop) proc(self: inout Guard) {
        if (self.active) { cache.clear(); cache.shrink(); }
    }
}
look :: proc(g: Guard) {}
main :: proc() {
    cache = [dynamic]int{42};
    view := cache[:];
    look(Guard{true});    // the temporary drops here; should be L0512
    fmt.println(view[0]);
}
```

The provenance walk has no point where a temporary's drop happens; the emitter
decides that. Unwinding cleanup is modeled only by the lifecycle pass.
