# Known gaps

Divergences between the specification documents and the shipped implementation,
with a minimal reproduction for each. A gap leaves this file when the
implementation matches the specified behavior — not when the spec is reworded
to match a bug, unless the rewording is the intended fix.

## Gaps

### Dense SVD can return successful factors containing infinity and NaN

[`core:math/dense`](standard-library.md#coremathdense) promises an orthonormal
`U` and `V` for a successful SVD, but a finite column with a representable
singular value can produce non-finite vectors:

```loke
package main;
import "core:fmt";
import "core:math/dense";
main :: proc() {
    a := dense.Matrix(f64).from_rows([2][1]f64{{1e308}, {1e308}});
    switch (dense.svd(a.view())) {
    case .ok(s): fmt.println(s.singular_values(), s.u(), s.v());
    case .err(e): fmt.println(e);
    }
}
```

This prints `[1.4142135623730951e308] [[inf], [nan]] [[1.0]]`, although the
left singular vector can have both components `1/sqrt(2)`. The shared
Householder builder in [qr.loke](core/math/dense/qr.loke) forms
`alpha - beta` and `beta - alpha` without rescaling; these overflow even
when `beta` is finite. The SVD does not validate the resulting reflectors
or vectors before returning `.ok`. Found in the dense review on 2026-10-30,
at both default and speed optimization. Define and implement a scaled
reflector construction, and ensure non-finite intermediate factors cannot
escape as a successful decomposition. Cover large and subnormal finite
inputs in the QR, eigenvalue, and SVD tests that share this builder.

### Dense eigenvalue and SVD deflation can discard large off-diagonal entries

The [dense eigendecomposition and SVD](standard-library.md#coremathdense)
can report success after discarding an off-diagonal entry far larger than
rounding error:

```loke
package main;
import "core:fmt";
import "core:math/dense";
main :: proc() {
    a := dense.Matrix(f64).from_rows([2][2]f64{{1e308, 1e307}, {1e307, 1e308}});
    switch (dense.symmetric_eigen(a.view())) {
    case .ok(e): fmt.println(e.values(), e.vectors());
    case .err(e): fmt.println(e);
    }
    b := dense.Matrix(f64).from_rows([2][2]f64{{1e308, 1e307}, {0, 1e308}});
    switch (dense.svd(b.view())) {
    case .ok(s): fmt.println(s.singular_values(), s.u(), s.v());
    case .err(e): fmt.println(e);
    }
}
```

The eigenvalues print as `[1e308, 1e308]` with identity eigenvectors; they
should be near `9e307` and `1.1e308`. The SVD likewise returns two `1e308`
singular values and identity vectors, so its reconstruction loses `b[0, 1]`
entirely. In [eigen.loke](core/math/dense/eigen.loke) and
[svd.loke](core/math/dense/svd.loke), the rounding test first forms
`t = abs(d0) + abs(d1)`, which overflows to infinity. Then `t + abs(e) == t`
holds for every finite `e`. Found in the dense review on 2026-10-30, at
both default and speed optimization. Specify and implement overflow-safe
deflation and shift calculations, preserving reproducibility, and test
scaled matrices whose decompositions remain representable.

### Dense Hermitian eigensolver validates the ignored imaginary diagonal

[`symmetric_eigen`](standard-library.md#coremathdense) says that the
imaginary parts of diagonal entries are not read, but rejects NaN or
infinity in those parts:

```loke
package main;
import "core:fmt";
import "core:math";
import "core:math/dense";
main :: proc() {
    C :: math.Complex(f64);
    a := dense.Matrix(C).filled(1, 1, C.from_components(2, math.F64_NAN));
    switch (dense.symmetric_eigen(a.view())) {
    case .ok(e): fmt.println(e.values());
    case .err(e): fmt.println(e);
    }
}
```

This prints `No_Convergence` instead of `[2.0]`.
[eigen.loke](core/math/dense/eigen.loke) tests `finite(x)` before dropping
the diagonal's imaginary part. Found in the dense review on 2026-10-30, at
both default and speed optimization. Drop that part before validation and
extend the existing ignored-diagonal test, which only uses a finite
imaginary value, to NaN and infinity.

### Dense LU condition estimation loses well-conditioned tiny matrices

[`Lu.reciprocal_condition`](standard-library.md#coremathdense) can report
zero for a scalar matrix, whose condition number is exactly one:

```loke
package main;
import "core:fmt";
import "core:math/dense";
main :: proc() {
    a := dense.Matrix(f64).from_rows([1][1]f64{{1e-309}});
    switch (dense.lu(a.view())) {
    case .ok(f): fmt.println(f.reciprocal_condition());
    case .err(e): fmt.println(e);
    }
}
```

This prints `0.0` instead of a value near `1.0`. The estimator in
[factor.loke](core/math/dense/factor.loke) solves for an unscaled inverse
vector; `1/1e-309` overflows to infinity, so its final reciprocal is zero.
This makes a uniformly scaled, well-conditioned system appear singular.
Found in the dense review on 2026-10-30, at both default and speed
optimization. Track solve scaling through the inverse-norm estimator and
combine it with the original norm without overflowing; add scale-invariance
regressions, including scalar and scaled identity matrices.

### Geometry closest points produce NaN for a triangle with two equal corners

[`core:math/geometry`](standard-library.md#coremathgeometry) treats a
triangle of no area as the segment its corners span, but two equal first
corners can produce NaN instead of the nearest point:

```loke
package main;
import "core:fmt";
import "core:math/geometry";
import "core:math/linalg";
main :: proc() {
    V :: linalg.Vector3(f64);
    a := V.from_components(0, 0, 0);
    c := V.from_components(2, 0, 0);
    p := V.from_components(1, 1, 0);
    triangle := geometry.Triangle3(f64).from_points(a, a, c);
    q := triangle.closest_point(p);
    fmt.println(q.x, q.y, q.z, triangle.distance(p));
}
```

This prints `nan nan nan nan`; the closest point is `(1, 0, 0)` and the
distance is `1`. In [simplex.loke](core/math/geometry/simplex.loke), the
first edge-region test accepts `d1 = d3 = 0` and divides by `d1 - d3`
before reaching the degenerate-triangle fallback. The shared helper also
breaks `Triangle2.closest_point` and both triangles' distance procedures.
Found in the geometry review on 2026-10-30, at default optimization and at
`-opt=speed -cpu=x86-64-v3`. Handle zero-length edges before the region
divisions, and test every placement of repeated vertices in both dimensions.

### Geometry intersection can turn a NaN-empty box into a nonempty box

The [geometry box contract](standard-library.md#coremathgeometry) makes a
box with a NaN corner empty, but intersection can discard that NaN:

```loke
package main;
import "core:fmt";
import "core:math";
import "core:math/geometry";
import "core:math/linalg";
main :: proc() {
    V :: linalg.Vector3(f64);
    B :: geometry.Aabb3(f64);
    box := B.from_min_max(V.splat(0), V.splat(1));
    empty := B.from_min_max(V.from_components(math.F64_NAN, 0, 0), V.splat(1));
    fmt.println(empty.is_empty(), empty.intersection(box).is_empty(), box.intersection(empty).is_empty());
}
```

This prints `true false true`: intersecting an empty set produces a
nonempty box in one operand order. Both `Aabb2.intersection` and
`Aabb3.intersection` in [box.loke](core/math/geometry/box.loke) call vector
`min` and `max` without checking emptiness. Those select their second
argument when either argument is NaN. Found in the geometry review on
2026-10-30, at default optimization and at
`-opt=speed -cpu=x86-64-v3`. Preserve an empty operand before computing
the corners, and cover NaNs in either corner and operand in 2D and 3D.

### Geometry triangle casts recover edge signs but can still miss a shared edge

[`cast` against triangles](standard-library.md#coremathgeometry) promises
that a ray through an edge shared by two triangles hits at least one, but
both can miss with finite `f32` inputs whose nonzero coordinates are normal:

```loke
package main;
import "core:fmt";
import "core:math/geometry";
import "core:math/linalg";
main :: proc() {
    V :: linalg.Vector3(f32);
    T :: geometry.Triangle3(f32);
    size := f32(1e-24);
    a := V.from_components(0, 0, 0);
    b := V.from_components(size, 0, 0);
    c := V.from_components(size, size, 0);
    d := V.from_components(0, size, 0);
    ray := geometry.Ray3(f32).from_origin_direction(
        V.from_components(size*0.5, size*0.5, 1), V.from_components(0, 0, -1));
    fmt.println(geometry.cast(ray, T.from_points(a, b, c), f32(0), f32(2)) != .none,
                geometry.cast(ray, T.from_points(a, c, d), f32(0), f32(2)) != .none);
}
```

This prints `false false`, although the ray meets the shared diagonal at
`t = 1`. In [ray.loke](core/math/geometry/ray.loke), the edge products
underflow to zero. `edge_sign` recomputes their signs with the exact
predicate, but leaves the numeric weights `u`, `v`, and `w` unchanged;
their zero sum then rejects both triangles. Found in the geometry review
on 2026-10-30, at default optimization and at
`-opt=speed -cpu=x86-64-v3`. Recompute usable edge values and the resulting
determinant, distance, and barycentric coordinates in a wider or scaled
representation when the ordinary products vanish. Cover shared edges and
interiors at small and large scales.

### Geometry sphere and circle queries confuse overflow with containment

The [geometry solids](standard-library.md#coremathgeometry) can classify
an outside point as inside even when the coordinates, radius, and correct
distance are all representable:

```loke
package main;
import "core:fmt";
import "core:math/geometry";
import "core:math/linalg";
main :: proc() {
    V :: linalg.Vector3(f32);
    sphere := geometry.Sphere(f32).from_center_radius(V.splat(0), 1e20);
    p := V.from_components(2e20, 0, 0);
    fmt.println(sphere.contains(p), sphere.distance(p), sphere.closest_point(p) == p);
}
```

This prints `true 0.0 true`; the point is outside, its distance is about
`1e20`, and its closest point is near `(1e20, 0, 0)`. The squared distance
and squared radius in [sphere.loke](core/math/geometry/sphere.loke) both
overflow to infinity, so `at_most` accepts their equality. The circle
procedures and squared-radius overlap tests in
[intersects.loke](core/math/geometry/intersects.loke) use the same
unscaled comparison. Underflow can similarly turn distinct small values
into equal zeros. Found in the geometry review on 2026-10-30, at default
optimization and at `-opt=speed -cpu=x86-64-v3`. Scale floating-point
distance comparisons and norm calculations while retaining exact integer
arithmetic; add large and small finite-input regressions.

### Optimized linalg SIMD and scalar transforms can disagree bit for bit

[`core:math/linalg`](standard-library.md#coremathlinalg) promises the same
result bits for its SIMD and scalar formulas. On this Windows x86-64 host,
the existing deterministic regression fails with speed optimization:

```powershell
.\lokec.exe tests/run/lib_linalg_lanes.loke -opt=speed -o tests/tmp/linalg-lanes.exe
.\tests\tmp\linalg-lanes.exe
```

It prints `FAIL a 3 x 3 times a vector is the scalar form` and omits
`all lane checks passed`. The three printed finite-result bit patterns still
match the expected file. The failing loop covers 4,000 deterministic vectors
and matrices, including NaNs, infinities, and signed zeros. Adding diagnostic
printing inside that loop made the failure disappear, so its exact operands
and cause have not yet been isolated; a NaN-bit difference is a hypothesis,
not an established diagnosis. Found in the linalg merge review on 2026-10-30.
Keep the regression and its bitwise comparison until the discrepancy is
understood; do not replace its expected output with the failing result.

### Linalg perspective can overflow with finite projection coefficients

[`core:math/linalg`](standard-library.md#coremathlinalg) accepts finite positive
near planes and finite far planes beyond them, but its direct product can
overflow before division even when the final coefficient is representable:

```loke
package main;
import "core:fmt";
import "core:math/linalg";
main :: proc() {
    p := linalg.Matrix(f32, 4, 4).perspective(1, 1, 10, 1e38, .Zero_To_One);
    fmt.println(p[2, 3]);
}
```

This prints `-inf` instead of a value near `-10`: `far*near` overflows before
division by `near - far`. The other depth ranges and the left-handed variants
use the same products. Found in the linalg merge review on 2026-10-30.
An overflow-safe evaluation order needs to be specified and tested across
CPU and optimization levels, preserving the package's reproducibility contract.

### Linalg Euler extraction loses finite non-unit quaternions at extreme scales

[`to_euler`](core/math/linalg/api.loki) accepts non-unit quaternions, but
squares their components without rescaling:

```loke
package main;
import "core:fmt";
import "core:math";
import "core:math/linalg";
main :: proc() {
    q := math.Quaternion(f64).from_components(1e200, 0, 1e200, 0);
    first, second, third := linalg.to_euler(q, .ZYX);
    fmt.println(first, second, third);
}
```

This prints `0.0 nan 0.0`; replacing both `1e200` components with `1` gives
`0.0 1.5707963267948966 0.0`, the same rotation. Intermediate squares overflow
and the subsequent products produce NaN. Found in the linalg merge review on
2026-10-30. Rescale finite nonzero inputs before these products, with
regressions for large and small scales and every Euler order.

### A bit cast of a `typeid_of` constant has no compile-time value

[`unsafe.transmute`](design.md#unsafetransmute) promises compile-time
bytewise conversion for admitted scalar shapes, and a constant bit cast now
builds a `typeid` from an integer, but not the reverse for a symbolic type:

```loke
package main;
import "core:unsafe";
X :: unsafe.transmute(u64, typeid_of(int));
main :: proc() {}
```

It reports `L0688`, "`unsafe.transmute` has no compile-time meaning from
`typeid` to `u64`". The same cast where the program runs gives the number.
A `typeid_of(T)` constant has no number until emission freezes the numbering
(`freeze_typeids`), so `const_storage` in
[src/check_builtin.odin](src/check_builtin.odin) treats it as unfoldable.
Found while fixing constant `typeid` bit casts on 2026-10-30. Folding it needs
type numbers fixed before constants that depend on them are evaluated, or the
spec to exclude symbolic `typeid` constants; see
[Comparing a forged `typeid` constant](open-questions.md#comparing-a-forged-typeid-constant).

### Storing one element of a local slice view in a loop is rejected

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a store
replace what one place held, so the copy of `s[0].head` taken in one
iteration no longer holds the storage the next store puts there. Through a
slice parameter this is now accepted, but through a local view of two or
more elements it is not:

```loke
package main;
Node :: struct { value: int }
Counted :: struct { head: ^mut Node, tail: ^mut Node, count: int }
local_view :: proc() {
    a := Node{1}; b := Node{2}; c := Node{3}; d := Node{4};
    arr := [2]Counted{{&mut a, &mut b, 0}, {&mut c, &mut d, 0}};
    s := &mut arr[:];
    for (round := 0; round < 2; round += 1) {
        h := s[0].head;
        h^.value = 1;
        s[0].head = s[0].tail; // L0641, should be allowed
    }
}
main :: proc() {}
```

A local view's loan names a range of `arr`, so `publish_replaces` in
[src/borrow.odin](src/borrow.odin) never finds the one place a store into an
element replaces, and the store only joins. A one-element view compiles.
Found while fixing stores through slice parameters on 2026-10-30; the
parameter fix (`prov_view_element` in
[src/cfg_provenance.odin](src/cfg_provenance.odin)) gives a view parameter's
element at a constant index slots of its own, which a local view's range
loan could do as well.

### A borrow a call stores through a pointer argument is not reborrowed by a later copy

[Retaining a borrow](design.md#retaining-a-borrow) says a callee may write an
`@(escape=stored)` argument's borrows into any compatible mutable destination
it receives, and [Weakening and reborrows](design.md#weakening-and-reborrows)
makes a carrier copied out of storage a reborrow of the carrier stored there.
After such a call, a copy out of the destination is not linked to the
argument, so two mutable paths to `r^` are used together:

```loke
package main;
Node :: struct { value: int }
Counted :: struct { head: ^mut Node, tail: ^mut Node, count: int }
relink :: proc(p: ^mut Counted, @(escape=stored) n: ^mut Node) { p^.head = n; }
caller :: proc(p: ^mut Counted, @(escape=stored) r: ^mut Node) {
    relink(p, r);
    h := p^.head;
    r^.value = 1; // should be L0641: `h` may copy `r`
    h^.value = 2;
}
main :: proc() {}
```

This compiles. Writing `p^.head = r` in `caller` instead is rejected. Found
while fixing stores through slice parameters on 2026-10-30. A call's stored
argument should publish into each compatible destination as a store does,
with the copy linked to the slots it may land in.

### A whole record stored through a parameter joins into the parameter

[Weakening and reborrows](design.md#weakening-and-reborrows) lets a carrier be
used beside one copied from a sibling field. Storing a whole record through a
pointer to a local now links each copied carrier to where it lands, but
through a parameter the store also joins into the parameter itself, so a copy
of one field holds the loans of every field:

```loke
package main;
Node :: struct { value: int }
List :: struct { head: ^mut Node, tail: ^mut Node }
sibling :: proc(@(escape=stored) p: ^mut List, @(escape=stored) q: ^mut List) {
    p^ = q^;
    x := p^.head;
    y := q^.tail; // L0641, should be allowed: `x` copies `q^.head`
    x^.value = 1;
    y^.value = 2;
}
main :: proc() {}
```

`caller_replaces` in [src/borrow.odin](src/borrow.odin) does not replace
caller slots for a record store, so `publish_into_loan` keeps joining such a
store into the parameter. The same body over a pointer to a local compiles.
Found while fixing whole-record stores on 2026-10-30. Replacing the record's
carrier slots, as the one-field store through a parameter now does, would
close it.
