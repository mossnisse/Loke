# Geometry library plan

Status: implemented, 2026-10-30, every milestone
([Milestone 1 results](#milestone-1-results),
[Milestone 2 results](#milestone-2-results),
[Milestone 3 results](#milestone-3-results),
[Milestone 4 results](#milestone-4-results),
[Milestone 5 results](#milestone-5-results)), after its questions were
settled the same day ([Settled questions](#settled-questions)).
[`core:math/geometry`](standard-library.md#coremathgeometry) documents what
has shipped. This document specifies a
`core:math/geometry` package of shapes, exact predicates, and the queries
between them, the first item of the linear algebra plan's
[Later work](linear-algebra-plan.md#later-work), which waited for the vector
API to settle. It does not change the language contract. The authorities it
builds on are [Floating-point operators](design.md#floating-point-operators),
[Generic data types](design.md#generic-data-types),
[where clauses](design.md#where-clauses),
[Ownership is visible](standard-library.md#ownership-is-visible),
[`core:math/linalg`](standard-library.md#coremathlinalg), and the
[linear algebra library plan](linear-algebra-plan.md), whose
[Element types](linear-algebra-plan.md#element-types),
[Degenerate inputs are explicit](linear-algebra-plan.md#degenerate-inputs-are-explicit),
and [Determinism](linear-algebra-plan.md#determinism) carry over unchanged.

## Goal and scope

`core:math/linalg` gives points, directions, and transforms, but no shapes:
nothing says whether a ray hits a box, which side of a plane a point is on,
or whether three points turn left. Every program that needs one of those
writes its own, and the hand-written versions are where the classic
robustness bugs live: a ray that slips between two triangles sharing an edge,
a box test that misses when a direction component is zero, a convex hull that
loops forever on nearly collinear points, a frustum built for the wrong clip
depth.

Rendering (culling, picking, ray tracing), games and physics (broad phase,
overlap and contact tests), CAD and meshing (orientation and in-circle
tests), GIS and mapping (polygons, point in polygon, hulls), 2D vector
graphics and plotting (bounds, hit testing), and robotics (distances and
clearance) all need the same small core. As with `linalg`, the strongest
reason to put it in the standard library is that two libraries can then pass
a box, a ray, or a plane to each other as it is.

The package serves those domains together, under the rules `linalg` already
follows, and adds one of its own:

- every result is the same bits on every machine, CPU level, and optimization
  level, and at compile time;
- conventions that differ between domains (clip depth, fill rule, the range of
  a ray) are explicit arguments, never defaults;
- a degenerate input (a zero direction, collinear points that define no
  plane) returns `Option` rather than a silent zero or NaN;
- **no test decides with a tolerance the caller did not give.** The
  orientation and in-circle predicates are exact for `f32` and `f64`, and the
  other tests are exact for the values they compute, stated per test.

Out of scope: spatial structures (bounding volume hierarchies, grids,
k-d trees), meshes and half-edge structures, curves and surfaces (Bézier
flattening, NURBS), Boolean operations on polygons, geodesy on the ellipsoid,
and contact generation for a physics solver. Each can be built on this
package and is listed in [Later work](#later-work).

## Design decisions

### Ordinary records over `linalg` vectors

```loke
Aabb2 :: struct($T: type) where interfaces.Numeric(T) { min, max: linalg.Vector2(T) }
Aabb3 :: struct($T: type) where interfaces.Numeric(T) { min, max: linalg.Vector3(T) }

Circle :: struct($T: type) where interfaces.Numeric(T) { center: linalg.Vector2(T), radius: T }
Sphere :: struct($T: type) where interfaces.Numeric(T) { center: linalg.Vector3(T), radius: T }

Segment2 :: struct($T: type) where interfaces.Numeric(T) { a, b: linalg.Vector2(T) }
Segment3 :: struct($T: type) where interfaces.Numeric(T) { a, b: linalg.Vector3(T) }

Triangle2 :: struct($T: type) where interfaces.Numeric(T) { a, b, c: linalg.Vector2(T) }
Triangle3 :: struct($T: type) where interfaces.Numeric(T) { a, b, c: linalg.Vector3(T) }

Ray2 :: struct($T: type) where interfaces.Numeric(T) { origin, direction: linalg.Vector2(T) }
Ray3 :: struct($T: type) where interfaces.Numeric(T) { origin, direction: linalg.Vector3(T) }

Plane :: struct($T: type) where interfaces.Numeric(T) { normal: linalg.Vector3(T), offset: T }

Frustum :: struct($T: type) where interfaces.Numeric(T) { planes: [6]Plane(T) }
```

Shapes are records with public fields and no padding beyond their vectors',
so an array of boxes or triangles can be handed to a foreign API as it is.
Each named 2D and 3D type follows `linalg`'s named vectors: a generic
`Aabb(T, N)` would need a vector type chosen by `N`, which
[Named vectors, generic matrices](linear-algebra-plan.md#named-vectors-generic-matrices)
already rejected for the vectors themselves. The two dimensions share private
generic helpers, so the code is not written twice.

`Aabb` is the name graphics, physics, and Ericson's *Real-Time Collision
Detection* use; `Box` would collide with the owning handle
[`Box(T)`](design.md#owned-values) in reading. An oriented box (`Obb3`) and a
capsule are left for a caller ([Later work](#later-work)).

### Every solid is closed

A box contains its faces, a sphere its surface, and a triangle its edges, so
two shapes that touch intersect, and `contains` is true on the boundary.
That is the convention of the collision literature and the only one under
which an overlap test between closed sets has an exact answer. An integer
rectangle is the same closed set: `Aabb2(i32){min = {0, 0}, max = {3, 3}}`
contains the 16 lattice points from `(0, 0)` to `(3, 3)`. A pixel rectangle
with an exclusive maximum is a different contract, left out
([Settled questions](#settled-questions)).

`min` and `max` are corners, not a center and extents: a center-extents form
cannot represent every box of float corners exactly, and the corners are what
the slab test and overlap tests read. A box with `min.x > max.x` (or `y`, or
`z`) is empty. For a `Real` `T`, `Aabb3(T).empty()` is `min = +inf`,
`max = -inf`, the identity of `union`, so a bound is accumulated from it
without a first-point special case. An integer type has no infinity, so its
boxes start from `from_point` or `from_points`, which returns `Option` for an
empty slice. `is_empty` is `!(min <= max)` component-wise, so a box with a NaN
corner is empty and contains nothing.

### Planes and their sign

A plane is the points `p` with `dot(normal, p) == offset`, and
`signed_distance(p)` is `dot(normal, p) - offset`, positive on the side the
normal points to. It is a Euclidean distance only for a unit normal, which
every constructor that takes a direction (`from_point_normal`, `from_points`,
`Frustum.from_matrix`) establishes; they return `.none` when the normal does
not normalize. A literal `Plane(T){normal = n, offset = d}` is taken as
written. The form `dot(n, p) + d == 0` was the alternative; `offset` reads as
the plane's distance from the origin along its normal, without a sign to
remember.

### Rays take their range

A ray is `origin + t * direction`. The direction need not be a unit vector,
and every `t` is in units of its length, so a segment `a`, `b` is the ray from
`a` with direction `b - a` over `[0, 1]`. Each ray query takes the range it
searches, `t_min` and `t_max`, as required arguments: a renderer starts past
the surface it left, a picking ray ends at the far plane, and a line is
`[-inf, inf]`. A default of `[0, inf]` would hide the self-intersection bug
every ray tracer meets first.

- **Ray and box** is the slab test of Williams et al. (2005) with the
  reciprocal direction computed once, `Ray3.inverse_direction()`, so a test
  over many boxes multiplies rather than divides; a zero component gives an
  infinite reciprocal and an unbounded slab.
  The NaN from `0 * inf` (an origin on a slab plane, a direction along it) is
  dropped by choosing each slab's near face by the reciprocal's sign and
  letting a NaN lose both comparisons, and the far distance is widened by
  `2*gamma(4)` of the larger end's magnitude, from Ize's (2013) `gamma(3)`
  bound on each distance ([Milestone 3 results](#milestone-3-results)), so a
  box that the exact ray touches is never missed. The test is
  conservative by design: bounding volumes are where a false miss loses a
  hit and a false hit costs one more test
  ([Settled questions](#settled-questions)).
- **Ray and triangle** is the watertight test of Woop, Benthin, and Wald
  (2013): the ray is sheared to the `+Z` axis, and each edge function is
  recomputed in `f64` (for `f32`) or with the exact orientation predicate (for
  `f64`) when it is exactly zero. A ray through an edge or a vertex shared by
  two triangles of a mesh hits at least one of them, which Möller-Trumbore
  cannot promise. It returns the distance and the barycentric coordinates.
- **Ray and sphere** solves the quadratic in the form of Haines et al.
  (2019), which takes the discriminant from the distance of the center to the
  ray rather than from `b^2 - 4ac`, so a small sphere far from the origin does
  not lose its hit to cancellation.
- **Ray and plane** divides by `dot(normal, direction)` and returns `.none`
  when that is zero, the ray parallel to the plane.

### Frustums take their clip depth

`Frustum(T).from_matrix(clip: Matrix(T, 4, 4), depth: linalg.Depth_Range)`
extracts the six planes of `clip = projection * view` (Gribb and Hartmann,
2001), normals inward, so a point is inside when every `signed_distance` is
non-negative. The side planes are the same for every convention; the near and
far planes are not, which is why the range is required, as for `linalg`'s
projections ([Projections and clip depth](linear-algebra-plan.md#projections-and-clip-depth)):

| `Depth_Range` | Near | Far |
| --- | --- | --- |
| `.Negative_One_To_One` | `row3 + row2` | `row3 - row2` |
| `.Zero_To_One` | `row2` | `row3 - row2` |
| `.One_To_Zero` | `row3 - row2` | `row2` |

A projection with an infinite far plane gives a far plane with a zero normal.
It is stored as normal 0 and offset -1, which every point is inside, so the
culling tests need no special case. `from_matrix` returns `.none` when another
plane's normal does not normalize, which no valid projection gives.

Culling a sphere or a box against a frustum is conservative: it answers
"outside" only when the shape is outside one plane. A box near a frustum's
corner can be outside the frustum but inside every plane; that false
"inside" is the standard trade-off, documented, and an exact test is the
separating-axis test, a later addition.

### Exact predicates

```text
Sign :: enum { Negative, Zero, Positive }

orient2d :: proc(a, b, c: linalg.Vector2($T)) -> Sign;    // Positive: a, b, c counterclockwise
orient3d :: proc(a, b, c, d: linalg.Vector3($T)) -> Sign; // Positive: d below the plane through a, b, c, counterclockwise from above
incircle :: proc(a, b, c, d: linalg.Vector2($T)) -> Sign; // Positive: d inside the circle through counterclockwise a, b, c
insphere :: proc(a, b, c, d, e: linalg.Vector3($T)) -> Sign; // Positive: e inside the sphere through a, b, c, d with orient3d Positive
```

Each returns the sign of a determinant of its inputs: exactly, for `f32` and
`f64`, as if computed in real arithmetic. A hull, a triangulation, a
point-in-polygon test, or a segment intersection test built on them cannot
contradict itself, which is the failure that Kettner et al. (2008) show for
the floating-point formulas: points judged collinear one way and not another,
hulls with a dent, Delaunay flips that never terminate.

The implementation is Shewchuk's adaptive method (1997): the determinant is
computed in floating point with an error bound, and only when the result is
within the bound is it recomputed with more exact terms, up to exact
expansion arithmetic. The common case costs about as much as the plain
formula. Shewchuk's method needs exactly what
[Floating-point operators](design.md#floating-point-operators) guarantees:
rounding to nearest with ties to even, no flushing of subnormals, and no
contraction or reassociation, so its expansions are exact on every machine
Loke runs on. It needs the error-free transforms `core:math/repro` keeps
private, Knuth's two-sum and Dekker's product, which need no `fma`; the
package has its own copy rather than a new public API in `repro`.

- **`f32`** inputs are lifted to `f64` and run the `f64` method. No
  intermediate of degree five or less in `f32` values overflows or underflows
  in `f64`, so the predicates are exact over the whole finite range of `f32`,
  which milestone 1 checks at the ends of the range.
- **`f64`** predicates are exact when no intermediate product overflows or
  falls below the normal range: for `insphere`, a degree-five determinant,
  coordinates whose differences lie roughly between `2^-200` and `2^200`,
  and wider for the lower degrees. Milestone 1 derives and documents each
  range. Scaling the inputs by a power of two,
  which changes no sign, would extend it to every finite input, at a cost
  ([Settled questions](#settled-questions)).
- **Integer** inputs compute the determinant directly, which is exact while
  it does not overflow; an overflow panics, as for the scalar arithmetic.
- **A user `Real` type** gets the plain formula, whose sign is that of the
  computed value; exactness is a property of the float formats, not of the
  interface.
- **A NaN or infinite coordinate** gives a sign that is the same on every
  machine but means nothing; the predicates do not check, since the check
  would cost as much as the common case.

`Sign` is shared by the four, rather than an `Orientation` enum per
predicate, because the meaning of "positive" differs per predicate anyway and
is stated on each.

### Element types

[Element types](linear-algebra-plan.md#element-types) carries over: a member
that needs only `interfaces.Numeric` arithmetic is generic over it, so integer
boxes, rectangles, and lattice geometry get every operation their arithmetic
supports, exactly; a member that needs a square root, a division whose
fraction matters, or a degenerate-input check is bounded by `linalg.Real(T)`,
so a dual number gets the derivative of a distance or a ray's hit time with
no change to the package.

`Numeric`: box construction, `union`, `intersection`, `contains`, `intersects`
between boxes, `expand`, `center` times two (`min + max`), `size`, the
`distance_squared` of a point to a box, the orientation predicates, and the
signed area of a polygon times two.

`Real`: everything that divides or takes a root: closest points, distances,
ray queries, planes, frustums, spheres' tests, centroids.

### Polygons are slices

A polygon is `[]linalg.Vector2(T)`, its vertices in order and the last edge
closing back to the first, not a record: polygons come from files, from
tessellators, and from other libraries as arrays of points, and a slice
borrows them without a copy. A procedure that produces points writes them into
caller storage and returns how many it wrote, with an allocating convenience
beside it ([Ownership is visible](standard-library.md#ownership-is-visible)).

- `signed_area(polygon)` is positive for counterclockwise vertices. Each term
  is the cross product of two edges from the first vertex, in vertex order,
  which keeps the area of a polygon far from the origin accurate.
- `winding_number(polygon, p) -> Option(int)` is Sunday's crossing test
  (2001) with each side test an exact `orient2d`, so it is exact for `f32`,
  `f64`, and integers, and a point on the boundary, where the number is not
  defined, is reported as such: `.none`
  ([Milestone 4 results](#milestone-4-results)).
- `contains(polygon, p, rule: Fill_Rule)`, with
  `Fill_Rule :: enum { Nonzero, Even_Odd }` required: SVG and PostScript
  default to the first, many GIS formats and the PDF `f*` operator use the
  second, and a self-intersecting polygon differs between them. The boundary
  is inside, as for every solid.
- `convex_hull(points, out) -> int` is Andrew's monotone chain (1979) with an
  exact `orient2d`: counterclockwise from the lexicographically smallest
  point, collinear points dropped, duplicates allowed. The form that writes
  into `out` sorts `points` in place, as its `[]mut` parameter shows; the
  allocating form sorts a copy.
- `is_convex(polygon)` and `is_simple(polygon)` are exact, the second
  quadratic and documented as such.

### Transforming shapes

- `transform_box(m: Matrix(T, 4, 4), box: Aabb3(T)) -> Aabb3(T)` is Arvo's
  method (1990): the bounds of the transformed corners, from the products of
  each matrix element with the box's minimum and maximum, without forming
  the eight corners. It is the tight box of the transformed box, not of the
  shape inside it.
- `transform_plane(m, plane) -> Option(Plane(T))` maps through the inverse
  transpose of the linear part, `linalg.normal_matrix`, and renormalizes;
  `.none` when `m` has no inverse.
- A sphere or a circle transforms only under a similarity, which the package
  cannot check, so it has no transform: the caller moves the center and scales
  the radius it knows.

### Determinism

[Determinism](linear-algebra-plan.md#determinism) carries over: every formula
is specified in its evaluation order, there is no `fma` and no `hypot`, and
the `Real` slots for `f32` and `f64` are `math.sqrt` and `core:math/repro`. The
predicates add nothing: an adaptive predicate's path depends only on its
inputs, so its result, and the time it takes, are the same everywhere. A
procedure that calls no foreign procedure is evaluated at compile time with
the same result, which covers the predicates, the boxes, and the frustum
extraction; whatever reaches `math.sqrt` does not fold, as in `linalg`.

## Proposed API

Sketches in the [standard-library](standard-library.md) style; constraints and
receiver modes are omitted. "Real" means members bounded by `linalg.Real(T)`.
Every group, like `linalg.approx_equal`, is one name over the shapes it
applies to.

```text
Aabb2/3(T), any Numeric T:
  from_corners(a, b)                 // sorts each component
  from_point(p); from_points([]V) -> Option
  is_empty; contains(p); contains(box)
  union(box), union(p) (grow), intersection(box)    // an empty box for disjoint ones
  expand(amount: T)                  // every face out by amount
  size -> V; doubled_center -> V     // max - min, min + max
  corner(index) -> V                 // bit i of index selects max on axis i
  distance_squared(p) -> T
Real:
  empty()                            // min +inf, max -inf
  center -> V; closest_point(p); distance(p)
  surface_area, volume (Aabb3); perimeter, area (Aabb2)

Circle, Sphere, Real:
  contains(p); closest_point(p); distance(p)         // 0 inside

Plane, Real:
  from_point_normal(p, n) -> Option; from_points(a, b, c) -> Option
  signed_distance(p); project(p) -> V; flip()
  intersection_point(a, b, c: Plane) -> Option(Vector3)   // the one common point

Segment2/3, Triangle2/3, Real:
  closest_point(p); distance(p); distance_squared(p)
  closest_points(segment, segment) -> (s: T, t: T)   // Ericson 5.1.9
  Triangle3: normal -> Option; area; barycentric(p) -> Option(Vector3)
  Triangle2: contains(p)                             // exact orient2d, boundary inside

Ray2/3, Real:
  at(t) -> V; inverse_direction() -> V
  cast(ray, shape, t_min, t_max) -> Option(T)        // box (conservative), sphere, plane
  cast(ray, triangle, t_min, t_max) -> Option(Triangle_Hit(T))   // t, u, v; watertight

intersects(a, b) -> bool, the closed-set overlap, Numeric where it can be:
  box-box, box-point; Real: sphere-sphere, sphere-box, sphere-plane, box-plane,
  circle-circle, circle-box, segment2-segment2 (exact), triangle3-box (separating axes)

Frustum, Real:
  from_matrix(clip, depth: linalg.Depth_Range) -> Option
  contains(p); intersects(sphere); intersects(box)   // conservative, see above

Predicates, f32, f64, integers, and any Numeric T:
  Sign :: enum { Negative, Zero, Positive }
  orient2d(a, b, c); orient3d(a, b, c, d); incircle(a, b, c, d); insphere(a, b, c, d, e)

Polygons over []Vector2(T):
  signed_area_doubled (Numeric); signed_area, centroid -> Option (Real)
  winding_number(polygon, p) -> Option(int); contains(polygon, p, rule: Fill_Rule)
  convex_hull(points: []mut, out: []mut) -> int; convex_hull(points, allocator) -> [dynamic]
  is_convex; is_simple

Transforms, Real:
  transform_box(m, box); transform_plane(m, plane) -> Option
```

## Milestones

Ordered by how much the later parts build on the earlier ones:

1. **Exact predicates.** Done ([Milestone 1 results](#milestone-1-results)).
   `Sign`, `orient2d`, `orient3d`, `incircle`, and
   `insphere` for `f32`, `f64`, integers, and the plain formula for other
   types, with the expansion arithmetic they need. Everything exact later in
   the package is built on these, so they are first, with their tests against
   exact arithmetic.
2. **Shapes and point queries.** Done
   ([Milestone 2 results](#milestone-2-results)). `Aabb2`, `Aabb3`, `Circle`, `Sphere`,
   `Plane`, `Segment2`, `Segment3`, `Triangle2`, and `Triangle3`; their
   construction, `contains`, `closest_point`, and distances; box algebra; and
   the overlap tests between boxes, spheres, circles, and planes.
3. **Rays, culling, and transforms.** Done
   ([Milestone 3 results](#milestone-3-results)). `Ray2`, `Ray3`, and `cast` against
   boxes, spheres, planes, and triangles; segment and triangle closest
   points and overlap with boxes; `Frustum` for each `Depth_Range` and its
   culling tests; `transform_box` and `transform_plane`.
4. **Polygons.** Done ([Milestone 4 results](#milestone-4-results)).
   Signed area, centroid, winding number, `contains` with a
   `Fill_Rule`, convex hull, `is_convex`, and `is_simple`.
5. **Measured performance.** Done ([Milestone 5 results](#milestone-5-results)).
   Benchmarks of ray-box and ray-triangle casts,
   frustum culling, and the predicates' fast and exact paths over arrays,
   against hand-written loops, then `Simd` inside an operation only where it
   wins without changing a result bit, as
   [linalg's milestone 4](linear-algebra-plan.md#milestone-4-results) did.

Each milestone ships its `api.loki`, a [`standard-library.md`](standard-library.md)
section and package-layout line, a `CHANGELOG.md` line, and the tests below.

## Validation

`tests/run/lib_geometry*.loke` with `.expected` files, in the CPU-level corpus
(`tests/cpu_test.odin`), following
[Standard-library verification](compiler-architecture.md#standard-library-verification):

- **Predicates against exact arithmetic.** Integer-valued `f64` inputs scaled
  by powers of two, so the exact determinant is computable in integer
  arithmetic in the test; the near-degenerate grids of Kettner et al. (2008),
  points `ulp` apart near a line, a circle, and a sphere, where the plain
  formula is known to give wrong and inconsistent signs; inputs at the ends
  of each documented `f64` range and across the whole `f32` range; and the
  symmetries every predicate has exactly (swapping two points negates, a
  cyclic shift keeps, translating by a power-of-two grid keeps).
- **Consistency.** A convex hull of random and of grid points agrees with the
  brute-force hull from `orient2d` on every triple; a winding number agrees
  with the sum of signed crossings; a point on a shared edge of a
  triangulation is inside both triangles and has winding number 1 in the
  union.
- **Watertightness.** Rays aimed at the shared edges and vertices of a
  triangulated sphere and a grid, at many angles and at `f32` and `f64`: every
  ray hits at least one triangle. Rays along box faces, edges, and corners,
  and with zero direction components: no box the exact ray touches is
  missed.
- **Closest points and distances** against brute force over the shape's
  boundary, and the closed-set boundary cases (touching boxes, tangent
  spheres, a point on a face) bit for bit.
- **Frustums.** For each `Depth_Range`, `linalg`'s `perspective` and
  `orthographic`, both handednesses, and an infinite far plane: the eight
  corners of the view volume are on its planes within a stated tolerance,
  points just inside and outside are classified correctly, and the extracted
  near and far planes match the projection's.
- **Degenerate inputs.** Zero directions, coincident points, collinear
  triangles, zero-length segments, empty boxes, NaN corners and radii, and
  empty polygons, each with its documented `Option` or result.
- **Element types.** Every test at `f32` and `f64`; `i32` and `i64` boxes and
  predicates, an overflowing predicate panicking; and a dual number through
  `distance`, `cast`, and `closest_point`, whose derivative part is checked
  against the analytic derivative.
- **Determinism.** Results printed as bit patterns, the same at every
  optimization and [CPU level](compiler-guide.md#cpu-levels) and when folded
  at compile time.

## Settled questions

Settled on 2026-10-30, each as recommended; the sections above carry the
decisions.

1. **The package's place**: `core:math/geometry`, beside `linalg` and
   `dense`. Geometry is not only math to its users, but its dependencies are
   `linalg`, and its siblings are where a reader looks. A top-level
   `core:geometry` was the alternative.
2. **Ray-box conservativeness**: the widened slab test, which never misses a
   box the exact ray touches. The slab test as computed can miss a box the
   ray grazes by an ulp; a caller wanting the exact entry distance of a hit
   box computes it with `cast` against the box's faces.
3. **`f64` predicates over every finite input**: documented exactness ranges
   for now. Scaling by a power of two when an input is outside them would
   cost a branch on every call but leave no input inexact, and it can be
   added later without changing a result inside the ranges.
4. **Half-open integer rectangles**: none. `Aabb2` is closed for every `T`,
   and a `Rect` with an exclusive maximum for pixels and UI belongs with the
   image and UI code that needs it, whose conventions (`width` and `height`
   or a corner) differ again.
5. **Shapes beyond the listed ones**: oriented boxes, capsules, and cylinders
   wait for a caller ([Later work](#later-work)), rather than joining
   milestone 3 for physics now.

## Later work

- Oriented boxes and capsules, with the separating-axis tests between them
  (Gottschalk et al., 1996) and the closest points of capsules.
- Bounding volume hierarchies built over `Aabb3`, with deterministic
  construction, and a uniform grid for 2D broad phase.
- Welzl's minimal enclosing circle and sphere, with a seeded `core:random`
  generator so the result is reproducible.
- Delaunay triangulation and constrained triangulation over the exact
  predicates, and polygon Boolean operations.
- Bézier curves: evaluation, subdivision, bounds, and flattening to a
  polyline with a stated tolerance.
- Lane-wise batch queries over structure-of-arrays boxes, measured against
  the milestone 5 benchmarks.

## References

- Andrew, A. M. (1979). Another efficient algorithm for convex hulls in two
  dimensions. *Information Processing Letters* 9(5).
- Arvo, J. (1990). Transforming axis-aligned bounding boxes. *Graphics Gems*.
- Ericson, C. (2005). *Real-Time Collision Detection*. Morgan Kaufmann.
- Gribb, G. and Hartmann, K. (2001). Fast extraction of viewing frustum
  planes from the world-view-projection matrix.
- Haines, E., Günther, J., and Akenine-Möller, T. (2019). Precision
  improvements for ray/sphere intersection. *Ray Tracing Gems*, chapter 7.
- Ize, T. (2013). Robust BVH ray traversal. *Journal of Computer Graphics
  Techniques* 2(2).
- Kettner, L., Mehlhorn, K., Pion, S., Schirra, S., and Yap, C. (2008).
  Classroom examples of robustness problems in geometric computations.
  *Computational Geometry* 40(1).
- Shewchuk, J. R. (1997). Adaptive precision floating-point arithmetic and
  fast robust geometric predicates. *Discrete & Computational Geometry* 18(3).
- Sunday, D. (2001). Inclusion of a point in a polygon.
- Williams, A., Barrus, S., Morley, R. K., and Shirley, P. (2005). An
  efficient and robust ray-box intersection algorithm. *Journal of Graphics
  Tools* 10(1).
- Woop, S., Benthin, C., and Wald, I. (2013). Watertight ray/triangle
  intersection. *Journal of Computer Graphics Techniques* 2(1).

## Milestone 1 results

Done 2026-10-30: `core/math/geometry` with the four predicates, and
`tests/run/lib_geometry_predicates.loke`, in the CPU-level corpus, and
`tests/trap/geometry_orient_overflow.loke`. The test compares each predicate
with the exact determinant of integer coordinates, computed in the test in
`i128` by cofactor expansion of the raw rows, over 3000 configurations each:
random ones, and points on a line, a plane, a circle, or a sphere, spread
over most of the bits and moved by one unit or not at all. Each is checked at
`f64`, at `f32`, and scaled by powers of two to the ends of the documented
`f64` range and across the `f32` range, subnormals included. It also checks
Kettner et al.'s grid of 65536 points ulps from the line through `(12, 12)`
and `(24, 24)`, where the plain formula gets 11492 signs wrong and the
predicate none; that each permutation of the points changes the sign by its
parity; and that a nearly degenerate call of each predicate, which reaches
its exact path, folds at compile time to the run-time sign. The output is the
same at `-opt=minimal`, `speed`, `size`, and `aggressive` and at both CPU
levels. Thirteen planted bugs each fail it: each exact path returning
`.Zero`, each error bound set to zero, a dropped component in the sum and in
the scaling of an expansion, a wrong error term in the exact product, a sign
in the exact `insphere`, and `f32` skipping the `f64` path.

Decided while implementing:

- **Two stages, not four.** Shewchuk's predicates add two intermediate
  stages between the floating-point filter and the exact determinant, which
  shorten the exact path's work. The exact path here goes straight to the
  determinant: its result is the same exact sign, it is reached only near a
  degenerate configuration, and the intermediate stages, most of Shewchuk's
  code, are for milestone 5 to measure.
- **The exact determinant is of the raw coordinates.** The predicate's points,
  with a column of ones (and the lifted column for the in-tests), form one
  larger determinant, expanded along a column into the pairwise minors
  `p.x q.y - q.x p.y`. No coordinate difference then has to be exact, so the
  exact path needs nothing the first stage does not.
- **The `f64` ranges** follow from requiring that no product of `k`
  coordinates or differences, `k` being the predicate's degree, overflow or
  fall below the normal range: a coordinate of magnitude at least `2^-m` is a
  multiple of `2^-(m+52)`, and `k(m + 52)` must stay within 1022.
  `orient2d` is exact for magnitudes in `[2^-450, 2^450]`, `orient3d` in
  `[2^-280, 2^300]`, `incircle` in `[2^-200, 2^220]`, and `insphere` in
  `[2^-150, 2^180]`. The same requirement holds for every `f32` input in
  `f64`, whose degree-five products stay above `2^-745`.
- **The bound is `Numeric` and `Ordered`, not `Real`**: a sign needs only
  arithmetic and comparison, so integers and user ordered types get the
  predicates, with no square root anywhere.
- **`insphere`'s exact path holds its expansions in one record of about
  120 KB**, in that procedure's frame only, so the common path's frame stays
  small. Threads get the operating system's default stack, 1 MB on Windows,
  and `core:math/dense` already uses 80 KB on its workers.

## Milestone 2 results

Done 2026-10-30: the shapes of milestone 2, with
`tests/run/lib_geometry_shapes.loke`, in the CPU-level corpus, and
`tests/trap/geometry_empty_box.loke` and `geometry_negative_radius.loke`. The
test checks:

- box algebra at `i32`, `f32`, and `f64`: sorting corners, empty boxes
  reversed and with a NaN corner, `union`'s identity, a point box, disjoint
  and touching intersections, the measures, and a center near the largest
  float;
- the closed-set boundaries exactly: a box's faces, an integer circle's
  boundary, a sphere's surface and the next float past it, touching boxes,
  circles, spheres, and planes, and a box and a plane through its corner;
- each Voronoi region of a triangle, and closest points of 300 random
  triangles against a sampled triangle of 861 points, none nearer by more
  than `1e-12`, each closest point inside by its barycentric coordinates;
- degenerate shapes: a segment of no length, triangles of no area and of one
  point, collinear points with no plane, parallel planes;
- a dual number's derivative of the sphere, box, segment, triangle, and plane
  distances against `(p - q).x/|p - q|`;
- that the triangle's and segment's closest points, three planes' point, and a
  box distance fold at compile time to the run-time bits.

Its output is the same at `-opt=minimal`, `speed`, `size`, and `aggressive`
and at both CPU levels. Fifteen of sixteen planted bugs fail it; the
sixteenth, a degenerate triangle's fallback skipping one of its three edges,
is equivalent: when the corners are collinear, the other two edges always
cover the span. The fallback keeps all three for a triangle that rounding
alone makes degenerate.

Decided while implementing:

- **Constructors for every shape.** A literal from another package must name
  its fields ([Struct literals](design.md#struct-literals)), as `linalg`'s
  vectors found, so each shape has one: `from_min_max` (as given) beside
  `from_corners` (sorted), `from_center_radius`, `from_normal_offset`, and
  `from_points`.
- **More of the boxes need only `Ordered`.** `closest_point`,
  `distance_squared`, and the four measures clamp, compare, and multiply, so
  integer boxes get them exactly; only `empty`, `center`, and `distance` need
  `Real`.
- **An empty box has no nearest point.** `closest_point`, `distance_squared`,
  and `distance` panic for one, since any answer would be a point outside it;
  `contains`, `intersects`, `union`, and the measures each have an answer and
  give it.
- **A negative or NaN radius panics.** It describes no set a caller meant, as
  reversed bounds do for `math.clamp`, and treating it as empty would make
  `contains` with `r*r` silently true.
- **`Triangle2.closest_point` returns a point the exact `contains` accepts**,
  rather than Ericson's barycentric combination, which is an ulp off for some
  inside points.
- **A box and a plane** are compared by the two corners farthest apart along
  the normal, each corner's distance computed from the corner, rather than by
  the center and the projected extent, which round twice; the test is then
  exact for integers.
- **`intersects` has no box-point member**: `contains` is that test, and one
  name for it is enough.

## Milestone 3 results

Done 2026-10-30: rays and `cast`, the closest points of two segments, the
segment and triangle overlap tests, `Frustum`, `transform_box`, and
`transform_plane`, with `tests/run/lib_geometry_rays.loke`, in the CPU-level
corpus. The test checks:

- ray-box casts against an exact rational slab test on 36,000 random integer
  rays and boxes, scaled by powers of two at `f64` and `f32`, over four
  ranges, with zero direction components and their `-0` forms, in 2D and 3D,
  and both forms of the call; and rays along faces and edges, through and
  past corners, from inside, behind the box, and with no direction;
- that the widening reaches a box an ulp away and not one `2^-40` away;
- ray-sphere casts of a unit sphere `10^9` away, on and off the axis, and of
  a tiny one, where the textbook discriminant cancels, and 2,000 random casts
  whose hits are on the surface and whose misses pass outside it;
- 12,000 rays at the vertices, edges, and diagonals of a height-field grid
  and of a closed latitude-longitude sphere, at `f64` and `f32`, each
  crossing the surface rather than grazing it, every one hitting a triangle;
  random rays through chosen barycentric coordinates; and a ray outside an
  edge by less than the rounding of its edge function, `2^-51`, at both
  types;
- segment pairs against Cormen et al.'s test in integers on small
  coordinates at `f64` (including `2^-400` and `2^400`), `f32`, and `i32`,
  and against `i128` orientations on near-collinear points `2^50` apart;
  segments against boxes, against the exact slab test over `[0, 1]`;
  triangles against integer boxes, against their distance by alternating
  projections; and the closest points of segments against a sampled grid;
- frustums for every `Depth_Range`, both handednesses, perspective,
  orthographic, and an infinite far plane, with and without a view matrix:
  the view volume's eight corners on their planes within `1e-12`, each
  face's center inside and outside by `1e-6`, the near and far planes the
  projection's, and culling inside, touching, outside, and the documented
  conservative case;
- transformed boxes equal to the bound of their corners through
  `transform_point` bit for bit at `f64`, `f32` (whose `transform_point` is
  the `Simd` form), in 2D, and for integers; transformed planes holding
  their moved points and sides;
- a dual number's derivative of the plane, sphere, box, and triangle casts,
  and compile-time folds of a box cast, a triangle cast, and a transformed
  box to the run-time bits.

Its output is the same at `-opt=minimal`, `speed`, `size`, and `aggressive`
and at both CPU levels. All 36 planted bugs fail it, among them a
Möller-Trumbore ray-triangle test, which leaks at shared edges, and an exact
edge-function sign left out, which a ray outside an edge by less than its
rounding catches.

Decided while implementing:

- **The slab widening is symmetric.** The proposal's `far*(1 + 2*gamma(3))`
  holds for positive distances; a line's range reaches negative ones, where
  scaling `far` up narrows it. The far end is widened by `2*gamma(4)` of the
  larger magnitude of the two ends instead, which covers each end's
  `gamma(3)` error relative to itself and the widening's own rounding. An
  entry at `+inf` or an exit at `-inf`, a zero direction component with the
  origin outside its slab, is a miss, and each slab's near face is chosen by
  the reciprocal's sign, as Williams et al. do, so an origin on a face with
  the ray along it bounds nothing for either sign of zero.
- **A box and a ball are solids**: a ray starting inside one meets it at
  `t_min`, as the closed-set convention gives. A plane and a triangle are
  surfaces.
- **The reciprocal is an argument of `cast`**, `cast(ray,
  ray.inverse_direction(), box, t_min, t_max)`, rather than a second ray
  type.
- **`Triangle_Hit` holds all three barycentric coordinates**, as
  `barycentric` returns them, rather than `u` and `v`.
- **The watertight test takes only the sign of its exact recomputation**,
  `orient2d` of the sheared corners, which lifts `f32` to `f64` as Woop et
  al. do; the computed edge values stay the barycentric weights. Their swap
  of the x and y axes for a negative direction keeps the winding for
  backface culling, which `cast` does not do; without culling it negates
  every edge function and the determinant together, so it is left out.
- **Segment overlaps are exact for floats**: a 2D segment and a box by its
  line's `orient2d` against the four corners, and a 3D one in the three
  coordinate projections, which are its cross-product separating axes. A
  triangle and a box compare their projections as computed, exact for
  integers only: an edge's separating axis there has the triangle on both
  sides of a line through no input point.
- **`closest_points` returns the parameters `(s, t)`**, and segments gained
  `at(t)`, rather than returning the two points.
- **The frustum tests are members of `intersects`**, documented as
  conservative, and `Frustum` has `from_planes`. Its planes are in the order
  left, right, bottom, top, near, far.
- **`transform_box` needs only `Ordered`**, as the milestone 2 boxes did, and
  has a 2D form for 3 x 3 transforms. Its bound is exactly that of
  `transform_point`'s corners, which the test checks, and an empty box stays
  empty. `transform_plane` takes a normal of any length.
- **2D rays cast against boxes and circles only**; segments and triangles in
  the plane wait for the polygon milestone's needs.

## Milestone 4 results

Done 2026-10-30: the polygon procedures of milestone 4, with
`tests/run/lib_geometry_polygons.loke`, in the CPU-level corpus. The test
checks:

- convex hulls of 120 point sets, random, on a small grid with repeated and
  collinear points, on a circle, and within an ulp of one line, at `f64`,
  `f32`, and `i32`, against the brute-force hull of the points in no flat or
  solid triangle of three others, each hull strictly convex and
  counterclockwise from the lexicographically smallest point, and both forms
  of the call alike; and hulls of no points, one repeated point, collinear
  points, and a square's grid;
- winding numbers of random points in 200 random polygons against the summed
  angles their edges subtend, and both fill rules against them; every vertex
  on the boundary; points within ulps of a quadrilateral's diagonal, whose two
  triangles' winding numbers add to the quadrilateral's and agree on which
  points are on the diagonal; a pentagram, a square wound twice, a clockwise
  square, rays through vertices and along edges, and empty, one-point, and
  integer polygons;
- areas exact for a polygon `10^8` from the origin, a clockwise one, and an
  integer one, and centroids of a square, a triangle, an L, a clockwise
  square, a polygon of no area, and one far out;
- convexity and simplicity of hand-made polygons: straight vertices, a notch,
  a spike, rectangles with a slit, three points folding back, a pentagram, a
  bowtie, two squares sharing a corner, a vertex on another edge, a repeated
  first vertex, and a thin triangle `2^50` across; of random star-shaped
  polygons and hulls, and of hulls with two vertices swapped;
- a dual number's derivative of the area and the centroid, and compile-time
  folds of an area, a centroid, a winding number, `is_simple`, and
  `is_convex`.

Its output is the same at `-opt=minimal`, `speed`, `size`, and `aggressive`
and at both CPU levels. Twenty of 22 planted bugs fail it. The other two are
equivalent: a side test of zero in the crossing count never reaches it, since
such a point is on the boundary and returned before, and `is_simple`'s check
for a repeated vertex is also found by the edges around it, but stays as the
precondition of the turning-back test. Three planted bugs that first passed
showed checks that were not needed, which are gone: `is_convex`'s test for a
path with no turn (a closed path on one line turns back), `is_simple`'s fold
test at the first vertex (another pair always finds it), and the lower
chain's restriction to points below the line from the first sorted point to
the last.

Decided while implementing:

- **`winding_number` returns `Option(int)`**, `.none` on the boundary, which
  is how the boundary is "reported as such"; `contains` counts it inside.
- **A ring does not repeat its first vertex.** Formats that close a ring
  that way, GeoJSON among them, give a zero-length edge, which `is_convex`
  and `is_simple` reject; the caller drops the last vertex. Straight
  vertices are allowed in both.
- **`is_convex` counts the turns of `x`'s direction**: with every turn the
  same way, the edges go around once exactly when the sign of `b.x - a.x`
  changes twice around the polygon, which tells a convex pentagon from a
  pentagram with comparisons alone.
- **The hull's upper chain takes only the points above the line from the
  first sorted point to the last**, plus the first point to close it. The
  textbook chain can hold lower-hull points in the upper chain for a while
  and needs room for `2n`; with the split, `out` needs only `n`, as the
  documented contract says. A planted bug removing the split overruns it.
- **`convex_hull` sorts with `slice.sort_by`**, lexicographically by `x` then
  `y`, and is the one polygon procedure that does not fold at compile time.

## Milestone 5 results

Done 2026-10-30. `bench/geometry.loke` times, each over 1024 operands, a ray
cast against a box with and without the inverse direction given, against a
triangle, a frustum culling boxes and spheres, and each predicate on random
points, which its filter decides, and on points exactly on a line, plane,
circle, or sphere, which reach its exact path. Beside them are the plain tests
written by hand: the slab test without its widening, Möller and Trumbore's
ray-triangle test, the frustum test inline, and each predicate's formula
without its filter. Its hashes of every result bit, in
`bench/geometry.expected`, are the same at both CPU levels, and each
hand-written form that decides the same inputs hashes as the package's, so
`perf.ps1` checks on every run that no result changed.
`tests/run/lib_geometry_lanes.loke`, in the CPU-level corpus, checks the box
and triangle casts against the scalar formulas they replaced, bit for bit, at
`f32` and `f64` over 8000 rays each, most of them aimed at a box's corner or
center or a triangle's corner or edge on a grid, with infinities, NaNs,
signed zeros, and subnormals among the coordinates and the range, and folded
at compile time. Seven of eight planted bugs fail it; the eighth makes the
exit's comparison inclusive, which changes only the sign of a zero exit, and
the cast returns the entry. Every earlier `lib_geometry` test gives the same
output at every optimization and CPU level tried.

What changed:

- **An `f32` box cast computes its three slabs in `Simd(f32, 4)` lanes**,
  each lane one axis with `slab`'s operations in its order, the fourth
  computed and dropped, and the entry and exit then narrowed axis by axis as
  before. Without a given inverse, the inverse is computed in the lanes too.
  LLVM compiled the scalar choice of each axis's near face, by the sign of
  the inverse, to a branch, which a random ray mispredicts half the time; a
  lane-wise select is never a branch.
- **The triangle cast permutes the axes once** rather than indexing the
  direction and the corners by the run-time axis `kz`. Each index carried a
  bounds check whose panic formats the index, and the triangle cast was
  the slowest of the casts. It is not a `Simd` change, and it
  computes the same values.

What stayed, and why:

- **`f64` box casts.** `Simd(f64, 4)` is two registers at `x86-64`. The lane
  form was 20 to 25% faster at `-opt=speed` but 13% slower at
  `-opt=aggressive` and 64% slower at `-opt=size`.
- **The predicates' filters.** `orient3d`'s three terms and their magnitudes
  in lanes were 22% faster at `x86-64` and 9 to 11% slower at `x86-64-v3`
  with `-opt=speed`, and 27 to 33% slower at `-opt=aggressive`. `incircle`'s
  were slower at both CPU levels, by 9 and 22%. `orient2d`'s test of the
  products' signs written as values rather than branches was 2 to 4%
  slower.
- **`slab_hit` without branches**, its tests combined into one condition,
  was 35% slower than its branches, which predict well apart from the hit
  itself.
- **Frustum culling** runs within 13% of the hand-written loop at `x86-64`
  and 26% at `x86-64-v3`, and was not changed.

The best of several runs, in nanoseconds an operation, at `-opt=speed` on the
development machine, a six-core Intel processor, the two builds run
alternately. "Before" is milestone 4's package under the same benchmark; "by
hand" is the hand-written loop.

| Operation | `x86-64` before | `x86-64` after | `x86-64-v3` before | `x86-64-v3` after | By hand, `x86-64` |
| --- | --- | --- | --- | --- | --- |
| Box cast, `f32` | 10.97 | 7.46 | 13.71 | 10.97 | 2.62 |
| Box cast, inverse given, `f32` | 10.85 | 6.22 | 10.79 | 8.53 | |
| Box cast, `f64` | 11.45 | 10.97 | 10.26 | 10.15 | |
| Triangle cast, `f32` | 29.23 | 18.74 | 26.48 | 18.16 | 4.34 |
| Triangle cast, `f64` | 34.98 | 27.40 | 31.97 | 25.72 | |
| Frustum and box, `f32` | 5.01 | | 2.44 | | 4.42 |
| Frustum and box, `f64` | 5.05 | | 4.67 | | |
| Frustum and sphere, `f32` | 2.65 | | 2.43 | | |
| `orient2d`, filter | 6.70 | | 6.56 | | 1.72 |
| `orient2d`, exact | 77.3 | | 74.7 | | |
| `orient3d`, filter | 10.63 | | 10.42 | | 3.57 |
| `orient3d`, exact | 376 | | 335 | | |
| `incircle`, filter | 7.1 | | 6.96 | | 4.0 |
| `incircle`, exact | 877 | | 836 | | |
| `insphere`, filter | 17.9 | | 14.1 | | 9.93 |
| `insphere`, exact | 3956 | | 3840 | | |

At `-opt=aggressive` the `f32` box cast went from 8.89 to 7.48 ns, and with
the inverse given from 7.26 to 10.57; at `-opt=size`, from 10.70 to 12.02
and from 10.92 to 11.11. The triangle cast was faster at every optimization
level, at `-opt=size` from 52.6 to 19.3 ns. The decisions were taken at
`-opt=speed`, as for [linalg](linear-algebra-plan.md#milestone-4-results).

The figures move with code placement. The hand-written `incircle` loop, whose
code did not change, ran 18% faster in every build after the change than
before it, and the `f32` box cast with the inverse given took 6.2 ns in one
build and 10.9 in another that differed only in `orient3d`. So a decision
needed an effect at both CPU levels and was checked at `-opt=aggressive`
and `-opt=size`.

The distance to the hand-written forms is mostly not the robustness the
package adds. LLVM compiles the hand-written box loop four rays at a time,
which it cannot do across the package's cast with its branches. The
predicates' plain formula has no branch to predict. And the `f64` filter of
`orient2d` is not inlined into its callers: LLVM inlines the exact path,
whose one caller it is, into the filter, which then costs 1265 against the
inliner's threshold of 225. Loke has no attribute that keeps a procedure out
of line or marks it cold
([Keeping a cold path out of line](open-questions.md#keeping-a-cold-path-out-of-line)).
Each package case is a loop over slices, as the hand-written ones are: a loop
indexing `[dynamic]` arrays reloaded their headers after every store, which
cost the package's box casts about a third of their time.

A compiler bug found and fixed in the same change, with a regression test in
`tests/run/lib_simd.loke`: a typed constant scalar splatted into a vector,
`zero: Simd(T, 4) = T(0)` in a generic body, kept its scalar type and value,
and reached LLVM as a scalar constant of the vector's type, which Clang
rejected.
