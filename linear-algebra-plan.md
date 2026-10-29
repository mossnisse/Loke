# Linear algebra library plan

Status: milestone 1 implemented, 2026-10-29
([Milestone 1 results](#milestone-1-results)); milestones 2 to 4 are
proposals. This document specifies the `core:math/linalg` package and
outlines a later dense-matrix package; it does not change the language
contract, and
[`core:math/linalg`](standard-library.md#coremathlinalg) documents what has
shipped. The authorities it builds
on are [Library numeric types](design.md#library-numeric-types),
[Generic data types](design.md#generic-data-types),
[where clauses](design.md#where-clauses),
[Operator declarations](design.md#operator-declarations),
[Methods and implementation blocks](design.md#methods-and-implementation-blocks),
[Floating-point operators](design.md#floating-point-operators),
[`core:math`](standard-library.md#coremath), and
[`core:math/repro`](standard-library.md#coremathrepro).

## Goal and scope

`core:math` has scalar functions, `Complex(T)`, and `Quaternion(T)`, but no
vectors or matrices. `Simd(T, N)` is a machine-lane abstraction with
alignment and constant-index rules ([Layout](design.md#layout),
[Lane access](design.md#lane-access)), not an algebra type.

Small vectors and matrices are vocabulary types. Rendering, games, physics,
robotics, CAD, mapping, image processing, plotting and 2D vector graphics,
control and filtering, and curve fitting all need them, and the strongest
reason to put them in the standard library is that two libraries from
different authors can then pass a point or a transform to each other without
converting between their private records. The design therefore serves those
domains together and takes no single program's conventions as defaults:

- every convention that differs between domains (clip depth, Euler sequence)
  is an explicit argument or name, never a silent default;
- shapes are not limited to graphics' 2, 3, and 4: `Matrix(T, R, C)` takes
  any small fixed shape, which state-space models, 6 x 6 spatial inertia,
  and small least-squares fits need;
- element types are not limited to `f32` and `f64`: integer coordinates and
  user numeric types (fixed point, rationals, dual numbers for automatic
  differentiation, intervals) get every operation their arithmetic supports;
- results are bit-reproducible, which simulations, replays, networked
  lockstep, and regression tests all want.

The work is in two packages:

1. `core:math/linalg`: fixed-size values that never allocate. Vectors of 2, 3,
   and 4 components, matrices of any fixed shape, rotations, transforms, and
   projections. This plan specifies it.
2. A later dense-matrix package, for sizes known only at run time:
   allocation, borrowed strided views, and solvers. This plan states its
   boundary and the questions its own plan must settle
   ([Dense matrices](#dense-matrices-a-later-package)).

Out of scope for both: tensors of rank above 2, sparse storage, geometric
algebra, and automatic differentiation itself. Rays, planes, boxes, and
intersection tests belong in a separate geometry package
([Later work](#later-work)).

## Design decisions

### Ordinary records, not SIMD

```loke
Vector2 :: struct($T: type) where interfaces.Numeric(T) { x, y: T }
Vector3 :: struct($T: type) where interfaces.Numeric(T) { x, y, z: T }
Vector4 :: struct($T: type) where interfaces.Numeric(T) { x, y, z, w: T }

Matrix :: struct($T: type, $R, $C: int) where interfaces.Numeric(T), R >= 1, C >= 1 {
	columns: [C][R]T,
}
```

`Vector3(f32)` has the layout of `[3]f32`, 12 bytes with 4-byte alignment,
and `Matrix(f32, 4, 4)` that of `[16]f32`: arrays of them have no padding the
program did not ask for, and they can be handed to a foreign API (a GPU
upload, a C geometry library) as they are. `Simd(f32, 4)` is 16-byte aligned
and allows only constant lane indices, which is the wrong contract for stored
data. The implementation may use `Simd` inside the operations later, without
changing a result bit, if [measurement](#milestones) shows a gain;
[Compiler-defined domain types](comments.md#compiler-defined-domain-types)
is the existing reason these are library types.

### Named vectors, generic matrices

Vectors of 2 to 4 components are the common case in every domain above, and
named fields read as the mathematics does (`p.x`); a fixed array has no `.x`
selectors and the language has no swizzles. `operator([])` adds a runtime
index for axis loops, `v[i]`, and a matrix takes two,
`m[r, c]` ([Indexing and slicing](design.md#indexing-and-slicing)); both
panic outside the shape, as array indexing does.

Matrices have one generic type for every shape. `R` and `C` are value
parameters, so `Matrix(f64, 6, 6)` and `Matrix(f32, 3, 4)` need nothing new,
and a method bound ([where clauses](design.md#where-clauses)) restricts each
operation to the shapes it means: `determinant` and `inverse` only where
`R == C`, `perspective` only for `Matrix(T, 4, 4)`. A failed bound removes
the method from that instantiation, so the type stays usable.

A vector of another length is a column matrix, `Matrix(T, N, 1)`, as in most
numerical libraries. `Matrix(T, N, 1)` and `VectorN(T)` convert explicitly
for `N` from 2 to 4. A generic `Vector(T, N)` beside the named ones was
considered and left out: it would give `N = 3` two vector types with a
conversion between them, which is the interoperability problem the package
exists to remove.

Fixed-size matrices are values and are copied as values; the package is for
sizes where that is cheap. Large or run-time sizes belong in the dense
package, and [Copy-cost diagnostics](design.md#copy-cost-diagnostics) already
flag the mistake.

### Element types

The [`Complex` pattern](standard-library.md#coremath) carries over. Members
that need only `interfaces.Numeric` arithmetic (`+`, `-`, `*`, `/`, `dot`,
`cross`, `length_squared`, products, transpose, the determinant of a matrix of
at most 4 x 4, `rotate`) are generic, so they work for integers and for user
numeric types alike; integer overflow panics as for the scalar.

Members that need a square root, a trigonometric function, or a degenerate
input check (`length`, `normalize`, `inverse`, `solve`, rotation and
projection constructors) are generic too, bounded by an interface the package
declares:

```loke
Real :: interface($T: type) {
	interfaces.Numeric(T);
	interfaces.Ordered(T);
	(value: T) -value -> T;
	(value: f64) T(value) -> T;             // constants such as 0.5 and pi
	slot sqrt:      proc(self) -> T;
	slot sin:       proc(self) -> T;
	slot cos:       proc(self) -> T;
	slot asin:      proc(self) -> T;
	slot acos:      proc(self) -> T;
	slot atan2:     proc(self, x: T) -> T;  // self is y
	slot abs:       proc(self) -> T;
	slot floor:     proc(self) -> T;
	slot ceil:      proc(self) -> T;
	slot round:     proc(self) -> T;
	slot is_finite: proc(self) -> bool;
	slot is_normal: proc(self) -> bool;     // finite, non-zero, full precision
}
```

A slot implementation may be inherent to the type or declared in the
interface's own package ([Runtime polymorphism](design.md#runtime-polymorphism)),
so `linalg` implements the slots for `f32` and `f64` itself, with `math.sqrt`
and `core:math/repro`, and a user type such as a dual number, a fixed-point
value, or an interval supplies inherent methods. Automatic differentiation
through a transform then needs nothing from this package, which is how
Eigen's scalar-type genericity is used in practice. There is one generic
implementation; a specialized `f32` or `f64` block may replace a member later
for speed, as `Complex` does, without changing its result.

Methods need no `_f32` suffix, because the receiver's type selects the
member; constructors that take only scalars are members of the instantiated
type (`Matrix(f32, 4, 4).perspective(...)`), so an unfixed literal never has
to choose a width.

There is no implicit widening or narrowing. One conversion hook,
`from_vector :: hook(convert) proc(v: Vector3($U)) -> Vector3(T)`, bounded by
the requirement `(value: U) T(value) -> T`, converts each component as the
scalar `T(x)` does, so `Vector3(f32)(v)` narrows a `Vector3(f64)`, widens an
integer vector, or reaches a user type through its own hook. A same-type
conversion is the built-in identity, which takes precedence
([Resolving `T(...)`](design.md#resolving-t)). Matrices and their shapes
follow the same rule.

### Storage and multiplication order

- Vectors are column vectors: `m * v` transforms `v`. There is no `v * m`;
  `transpose(m) * v` says it.
- Storage is column-major: `m.columns[c][r]` is row `r`, column `c`, and
  `m[r, c]` reads it in the usual subscript order. `to_array` gives the
  same order flat, which is what OpenGL takes with `transpose = GL_FALSE`,
  what Direct3D and Vulkan shaders read as `column_major`, and what LAPACK
  expects. Row-major consumers transpose once at the boundary.
- `from_rows` lets a constant be written in source as it is printed in a
  textbook; `from_columns` and a literal are the storage order.
- `a * b` applies `b` first: `translation * rotation * scaling` scales, then
  rotates, then translates.
- `format` prints rows.

### Coordinates and rotations

- Angles are radians.
- Right-handed: `cross(X, Y) == Z`, and a positive angle rotates
  counterclockwise when seen from the positive end of the axis. Only the
  camera constructors depend on handedness. The unsuffixed ones build a
  right-handed view space, the convention of mathematics, OpenGL, glTF, and
  robotics; `perspective_lh`, `orthographic_lh`, `look_at_lh`, and
  `look_to_lh` build a left-handed one, looking down `+Z`, for Direct3D's
  traditional convention and engines that follow it. Composing a right-handed
  constructor with a `Z` flip would also work, but the flip goes after the
  view matrix and before the projection, which is easy to get backward.
- Rotations in 3D are `math.Quaternion(T)` with `real` as the scalar part
  (often called `w`). A unit `q` rotates `v` as `q v q*`, an active rotation;
  `q` and `-q` are the same rotation. `a * b` rotates by `b` first, so
  `from_quaternion(a * b)` equals `from_quaternion(a) * from_quaternion(b)` up
  to rounding. A separate unit-rotation type was left out: the existing
  quaternion has the algebra, and a "unit" type cannot keep its invariant
  through rounding. An extension `impl` is visible only in its own package
  ([Methods and implementation blocks](design.md#methods-and-implementation-blocks)),
  so the rotation operations are free procedures, `linalg.rotate(q, v)`, not
  quaternion methods.
- Rotations in 2D are `Matrix(T, 2, 2).rotation(angle)`, or
  `Matrix(T, 3, 3).rotation_2d(angle)` in homogeneous form.
- Euler angles take an explicit sequence, because aerospace, robotics, and
  graphics each use a different one and a default is a guaranteed bug.
  `Euler_Order :: enum { XYZ, XZY, YXZ, YZX, ZXY, ZYX }` names intrinsic
  Tait-Bryan sequences: `quaternion_from_euler(.ZYX, yaw, pitch, roll)` is
  `axis_angle(Z, yaw) * axis_angle(Y, pitch) * axis_angle(X, roll)`, which is
  also the extrinsic sequence read backward. `to_euler` returns the middle
  angle in `[-pi/2, pi/2]` and the others in `[-pi, pi]`; at the middle
  angle's limits (gimbal lock) the third angle is 0 and the first takes the
  whole rotation about the shared axis. Proper Euler sequences (`ZXZ` and the
  like) are added with a caller.

### Projections and clip depth

Clip-space depth is the convention that differs most between graphics APIs,
and a silent default is the classic source of depth-buffer bugs, so every
projection takes it as a required argument:

```loke
Depth_Range :: enum {
	Negative_One_To_One,   // OpenGL without glClipControl
	Zero_To_One,           // Direct3D, Vulkan, Metal, WebGPU
	One_To_Zero,           // reversed depth on any of those
}
```

- `perspective(fovy, aspect, near, far, depth)` and
  `orthographic(left, right, bottom, top, near, far, depth)` map a
  right-handed view space, looking down `-Z` with `+Y` up, to normalized
  device coordinates with `x` and `y` in `[-1, 1]` and `+Y` up, and `z` in the
  chosen range, the near plane at its first value. Vulkan's downward
  framebuffer `y` is a viewport choice, documented with the one-line flip,
  not a fourth convention.
- `perspective` for `.Negative_One_To_One`, with `f = cot(fovy/2)`:

  ```text
  [ f/aspect  0   0                      0                     ]
  [ 0         f   0                      0                     ]
  [ 0         0   (far+near)/(near-far)  2*far*near/(near-far) ]
  [ 0         0   -1                     0                     ]
  ```

  The other two ranges differ only in the third row.
- An infinite `far` is allowed and special-cased to the infinite-far-plane
  limit, since the formula would divide infinity by infinity; with
  `.One_To_Zero` it is the usual infinite reversed projection.
- Invalid parameters are programmer errors and panic, as `math.clamp` does
  for reversed bounds: `fovy` outside `(0, pi)`, a non-positive `aspect` or
  `near`, `far <= near`, or a NaN. No such parameters describe a projection,
  and a value from runtime settings (a field-of-view slider) is bounded where
  it is read; an `Option` would push a check that cannot fail usefully onto
  every caller.
- The `_lh` constructors take the same parameters and `Depth_Range`, and
  differ from the right-handed ones only in the sign of the view-space `z`.
- `look_at(eye, target, up)` and `look_to(eye, forward, up)` build the
  right-handed view matrix whose rows are the side, up, and back vectors.
  Both return `Option`: `.none` when the direction is zero or parallel to
  `up`, the degenerate camera every program meets when looking straight up.

### Degenerate inputs are explicit

- `normalize` returns `Option(V)`: `.none` when the squared length is not
  `is_normal`: below the format's smallest normal, infinite, or NaN. That covers the zero
  vector, vectors whose squares underflow or overflow, and NaN, and leaves
  every other vector within a few ulps of length 1. `normalize_or(v, fallback)`
  spells the common pattern once. Nothing silently returns zero or NaN.
- `inverse` and `solve` return `Option`: `.none` when a pivot is exactly zero
  or the result is not finite. A nearly singular matrix still inverts with
  large entries; the documentation says so rather than inventing a tolerance,
  and `condition_estimate` is a later addition.
- `inverse_rigid` assumes a rotation plus translation and inverts by
  transposition without checking; `inverse_affine` checks only the linear
  part.
- `quaternion_normalize` follows `normalize`; `quaternion_from_axis_angle`
  takes the axis as given, and the documentation shows `normalize(axis)` at
  the call site. `quaternion_between(a, b)` returns `.none` for opposite
  vectors unless given a fallback axis.
- `project_point` divides by `w` and returns `.none` for a zero `w` or a
  non-finite result; `transform_point` and `transform_direction` take `w` as
  1 and 0 and never divide.

### Determinism

Every operation gives the same bits on every machine, CPU level, and
optimization level, and at compile time:

- Each formula is specified in its evaluation order: `dot` is
  `(x*x' + y*y') + z*z'`, a product element is the `dot` of a row and a column
  in index order, and `lerp(a, b, t)` is `a*(1 - t) + b*t`, exact at both
  ends. [Floating-point operators](design.md#floating-point-operators)
  forbid contraction and reassociation, so the written order is the computed
  one.
- `inverse` and `solve` are LU with partial pivoting: the pivot is the
  largest magnitude in the column, the first on a tie, so the elimination
  order is fixed. At 2 x 2 to 4 x 4, `determinant` is the cofactor expansion
  in a fixed order, which is exact for integers.
- For `f32` and `f64`, the `Real` slots are `math.sqrt`, which is correctly
  rounded, and `core:math/repro`'s `sin`, `cos`, `asin`, `acos`, and `atan2`.
  A user scalar type's determinism is its own. Constructors run
  per object or per frame, not per element, so its roughly fourfold cost
  ([Deterministic math functions](open-questions.md#deterministic-math-functions))
  is not on the hot path. `perspective` takes `cot(fovy/2)` as `cos/sin`.
- No `math.fma` and no `hypot`, whose results vary by machine or CPU level.

Vector arithmetic is the plain operators, so this costs nothing where speed
matters, and it removes a class of desynchronization and flaky-test bugs that
a general library would otherwise have to document as a warning.

## Proposed API

Sketches in the [standard-library](standard-library.md) style; constraints and
receiver modes are omitted. "Real" means members bounded by `Real(T)`.

### Vectors

```text
Vector2/3/4(T), any Numeric T:
  from_components(x, y, ...); splat(value: T)
  unit_x(), unit_y(), unit_z(), unit_w()   // as the length allows
  + - (binary), - (unary), * / (component-wise); * (V, T), * (T, V), / (V, T)
  ==, exact and component-wise; [] and []= with a runtime index
  dot, length_squared, distance_squared
  min, max                               // component-wise math.min, math.max
  to_array, from_array, format
  conversion hook from VectorN(U) wherever T(u) converts
  Vector3: cross; extend(w) -> Vector4; xy()
  Vector4: xyz()
  Vector2: extend(z) -> Vector3; perp() -> (-y, x); cross -> T   // the z of the 3D cross

Real:
  length, distance, normalize -> Option(V), normalize_or(fallback)
  lerp(a, b, t), angle_between(a, b)     // atan2(|a x b|, a . b), stable near 0 and pi
  project(onto_unit), reject(unit_normal), reflect(unit_normal)
  abs, floor, ceil, round                // component-wise
```

### Approximate equality

```text
approx_equal(a, b, absolute: T, relative: T) -> bool
```

A procedure group over `T` itself and every vector, matrix, and quaternion
type with a `Real` element. It holds when every component pair satisfies
`|a - b| <= max(absolute, relative * max(|a|, |b|))`: the absolute tolerance
governs near zero, where a relative one means nothing, and the relative one
elsewhere. Both tolerances are required, because no default suits both
metres and nanometres; a negative or NaN tolerance panics; a NaN component is
never equal; equal infinities are. Comparing two rotations, where `q` and
`-q` agree, is written `approx_equal(a, b, ...) || approx_equal(a, -b, ...)`.
An ulp-distance model was left out: it breaks down at zero, which is where
geometric residuals land.

### Matrices

```text
Matrix(T, R, C), any Numeric T:
  splat(value), identity()                     identity where R == C
  from_columns, from_rows, from_array, to_array
  [r, c] and [r, c]=, column(c) -> [R]T, row(r) -> [C]T
  conversion hook from Matrix(U, R, C) wherever T(u) converts
  transpose -> Matrix(T, C, R)
  * (Matrix(T, R, K), Matrix(T, K, C)) -> Matrix(T, R, C)
  * (Matrix, T), * (T, Matrix), +, -, ==
  * (Matrix(T, N, N), VectorN(T)) -> VectorN(T)        for N in 2 ..= 4
  from_vector, to_vector                       Matrix(T, N, 1), N in 2 ..= 4
  determinant                                  where R == C, R <= 4
  trace                                        where R == C
  format

Square transforms, any Numeric T:
  Matrix(T, 4, 4): translation(Vector3), scaling(Vector3), from_quaternion,
                   transform_point, transform_direction, upper_left -> Matrix(T, 3, 3),
                   inverse_rigid
  Matrix(T, 3, 3): from_quaternion, extend -> Matrix(T, 4, 4),
                   translation_2d(Vector2), scaling_2d(Vector2),
                   transform_point_2d, transform_direction_2d

Real:
  inverse -> Option, solve(b: Matrix(T, N, K)) -> Option(Matrix(T, N, K))
  determinant                                  any square size, through LU
  Matrix(T, 4, 4): inverse_affine, normal_matrix -> Option(Matrix(T, 3, 3)),
                   project_point -> Option(Vector3),
                   rotation_x/y/z(angle), rotation(axis, angle),
                   perspective, orthographic, look_at, look_to,
                   and the _lh form of each of those four
  Matrix(T, 3, 3): rotation_x/y/z, rotation(axis, angle), rotation_2d(angle)
  Matrix(T, 2, 2): rotation(angle)
```

### Rotations over `math.Quaternion(T)`

Free procedures, generic over the element type of their typed arguments.

```text
any Numeric T:
  rotate(q, v: Vector3(T)) -> Vector3(T)
      // t := 2*cross(u, v); v + real*t + cross(u, t), for u the vector part
Real:
  quaternion_from_axis_angle(axis, angle)      // (cos(angle/2), sin(angle/2) * axis)
  quaternion_normalize -> Option
  quaternion_from_matrix(Matrix(T, 3, 3))      // Shepperd's method
  quaternion_between(a, b, fallback_axis?) -> Option
  quaternion_from_euler(order, first, second, third); to_euler(q, order)
  quaternion_from_rotation_vector(v); to_rotation_vector(q)   // axis * angle
  nlerp(a, b, t); slerp(a, b, t)               // both take the shorter arc
```

## Dense matrices: a later package

Sizes known only at run time are a different contract: they allocate, they
are borrowed far more than copied, and the work is in solvers rather than in
operators. They get their own package and plan, after `core:math/linalg`
ships. That plan has to settle:

- an owning `Dense(T)` that takes an allocator, and borrowed `View(T)` and
  mutable views with a row stride and a column stride, so that a block, a
  transpose, a row-major foreign buffer, and a column-major one are all views
  without copies;
- shape mismatches as panics (programmer errors), and numerical failure
  (singular, not positive definite, no convergence) as `Result` errors;
- outputs written into caller storage, with allocating conveniences beside
  them, following [Ownership is visible](standard-library.md#ownership-is-visible);
- the first algorithms: products, LU with partial pivoting, Cholesky,
  Householder QR and least squares, then a symmetric eigensolver and the SVD;
- a deterministic reference implementation in fixed order, and whether a
  faster blocked, threaded, or BLAS-backed path is an opt-in separate
  procedure, since it cannot keep the same bits.

## Milestones

Ordered by how foundational each part is, not by a particular program:

1. **Core values.** Done ([Milestone 1 results](#milestone-1-results)).
   The vector types; `Matrix(T, R, C)` with products, transpose, conversions, and
   determinants; `inverse` and `solve`; 2D and 3D transforms;
   `quaternion_from_axis_angle`, `rotate`, `quaternion_normalize`, and
   `from_quaternion`; `perspective` and `orthographic` in all three depth
   ranges and both handednesses; `look_at` and `look_to` and their `_lh`
   forms; and `approx_equal`.
2. **Rotations and geometry helpers.** `quaternion_from_matrix`,
   `quaternion_between`, `nlerp`, `slerp`, Euler sequences, rotation vectors,
   `angle_between`, `project`, `reject`, `reflect`, `normal_matrix`,
   `inverse_affine`, and `project_point`.
3. **Dense matrices**, under their own plan.
4. **Measured performance.** Benchmarks of products, `rotate`, and batch
   transforms against hand-written loops, then `Simd` inside the operations
   only where it wins without changing a result bit.

Each milestone ships its `api.loki`, a [`standard-library.md`](standard-library.md)
section and package-layout line, a `CHANGELOG.md` line, and the tests below.

## Validation

`tests/run/lib_linalg*.loke` with `.expected` files, following
[Standard-library verification](compiler-architecture.md#standard-library-verification):

- **Exact identities**, bit for bit: `identity * m == m`,
  `transpose(transpose(m)) == m`, `cross(X, Y) == Z` and its cyclic
  permutations, zero rotations, `from_rows` against `from_columns` of the
  transpose, `to_array` order, and integer determinants against hand
  results.
- **Approximate identities**, with tolerances stated per test as a small
  multiple of epsilon times the operands' magnitude: `m * inverse(m)` and
  `solve` residuals for well-conditioned matrices of several shapes up to
  6 x 6; rotation matrices orthonormal with determinant 1; `from_quaternion`
  against `rotate`; products of quaternions against products of matrices;
  `quaternion_from_matrix` and `to_euler` round trips for every
  `Euler_Order`, gimbal lock included; `slerp` at its ends and midpoint.
- **Degenerate inputs**: zero, subnormal, huge, infinite, and NaN vectors
  through `normalize`; singular and NaN matrices through `inverse` and
  `solve`; `look_at` with no direction or one parallel to `up`; opposite
  vectors through `quaternion_between`; `project_point` at `w = 0`; every
  projection panic case, and an infinite far plane in each depth range.
- **Clip conventions**: for each `Depth_Range`, a point on the view axis at
  the near plane maps to the range's first value and at the far plane to its
  second; clip `w` is `-z_view`; `+Y` maps to positive NDC `y`; `look_at`
  from `+Z` toward the origin has the identity rotation. Each `_lh` form
  agrees with its right-handed twin applied to the `Z`-mirrored scene.
- **Approximate equality**: each tolerance governing its own regime, at and
  beside the boundary; NaN components; equal and opposite infinities; the
  panics for negative and NaN tolerances.
- **Element types**: every test at `f32` and `f64`; `i32` and `i64` vectors
  and matrices, with an overflowing `dot` panicking; conversions between all
  of them; and two user types in the test, a rational record through the
  `Numeric` members and a dual number through the `Real` ones, whose
  derivative part of `length` and `rotate` is checked against the analytic
  derivative.
- **Determinism**: results printed as bit patterns, the same at every
  optimization and [CPU level](compiler-guide.md#cpu-levels) and when folded
  at compile time, as `tests/repro_test.odin` checks for `core:math/repro`.

## Later work

- A geometry package: `Aabb`, `Ray`, `Plane`, `Sphere`, frustum planes from a
  projection-view matrix, and ray, box, and triangle tests, specified once
  the vector API has settled.
- Lane-wise SIMD math and structure-of-arrays batch transforms, after the
  benchmarks.
- Proper Euler sequences, dual quaternions, and a condition-number estimate.

## Settled questions

Settled on 2026-10-29; the sections above carry the decisions.

- **User scalar types beyond `Numeric`**: the members that need `sqrt` or
  trigonometry are generic over `linalg.Real(T)`, whose slots `linalg`
  implements for `f32` and `f64` ([Element types](#element-types)).
  Specialized `f32`-and-`f64`-only blocks were the alternative; they would
  have left dual numbers and fixed point with arithmetic alone.
- **Complex elements**: `dot` is the bilinear product for every `T`, as
  `Numeric` defines it. Hermitian products need a conjugate, which `Numeric`
  does not have, and belong with the dense package, where complex matrices
  are used.
- **Handedness**: right-handed unsuffixed names, plus `_lh` forms of the four
  camera constructors ([Coordinates and rotations](#coordinates-and-rotations)).
  A required handedness argument was rejected as noise for the right-handed
  majority; right-handed only was rejected because the hand-composed flip is
  easy to place wrongly.
- **Conversion hooks**: one generic hook per type, bounded by the expression
  requirement `(value: U) T(value) -> T`.
- **Short names**: none exported. An alias is the same type, so a program's
  own `Vec3 :: linalg.Vector3(f32);` costs no interoperability, and the
  package avoids a grid of names such as `Vector3f`, `Vector3d`, and
  `Vector3i`.
- **Approximate equality**: public, with both tolerances required
  ([Approximate equality](#approximate-equality)).
- **Projection validation**: panics ([Projections and clip depth](#projections-and-clip-depth)).
- **Two-index subscripts**: the language has them
  ([Indexing and slicing](design.md#indexing-and-slicing)), so `m[r, c]`
  replaces the proposed `m.at(r, c)`.

## Spike results

Done 2026-10-29. `tests/pkg/real_interface` is a cut-down package with `Real`,
`Vector3`, and `Matrix(T, R, C)`, used from a program with `f32`, `f64`,
`i64`, and a forward-mode dual number. It runs, and in optimized IR
`Vector3(f32).length()` through the `sqrt` slot is three multiplies, two adds,
and `llvm.sqrt.f32`, with no call left.

What held as specified:

- A slot implemented by a package-private extension on `f32` and `f64` in the
  interface's package is met for every importer and reached from a generic
  body ([Interface bodies](design.md#interface-bodies)); a user type meets it
  with inherent methods.
- Method bounds by shape (`where R == C`), two-index subscripts, the
  `(value: f64) T(value) -> T` requirement, and degenerate input through
  `is_normal`.

Compiler bugs found and fixed in the same change, each with a regression test
(`tests/run/generic_member_parameters`,
`tests/err/generic_operator_hook_roles`):

- A record's value parameters did not bind in a procedure's parameter pattern,
  so `proc(m: M($R, $C))` could not be called at all.
- An operator or conversion hook with generic parameters of its own was never
  found, and a malformed one went unreported; a generic member could not be
  called through its type (`M(2, 3).times(a, b)`). This blocked the matrix
  product `Matrix(T, R, C) * Matrix(T, C, $K)` and the generic conversion hook,
  which [Conversion hooks](design.md#conversion-hooks) now specifies.

What the package must allow for:

- **Extensions on the floats are `@(private)`.** A public extension is exported
  under the package's name, so `sqrt` on both `f32` and `f64` would be two
  exports of one name. Private ones still meet the slot.
- **Literals from another package name their fields**
  ([Struct literals](design.md#struct-literals)):
  `linalg.Vector3(f32){x = 1, y = 2, z = 3}`. Each vector type gets
  `from_components(x, y, z)` as `Complex` has, and the question of a
  positional opt-in is in
  [Positional literals for vocabulary records](open-questions.md#positional-literals-for-vocabulary-records).
- **A program's alias names an instantiation**, `Vec3 :: linalg.Vector3(f32);`;
  a generic one, `Vec :: linalg.Vector3;`, is rejected, which is
  [Parametric aliases](open-questions.md#parametric-aliases).
- **A user scalar declared in `package main` marks its operators `@(public)`.**
  `Numeric`'s expression requirements are checked in the interface's package,
  so a private inherent `+` does not meet them there, while `Real`'s slots are
  met by private methods. The diagnostic now says so; the asymmetry is in
  [Visibility in slot and expression requirements](open-questions.md#visibility-in-slot-and-expression-requirements),
  and the documentation of `Real` shows the attribute.

## Milestone 1 results

Done 2026-10-29: `core/math/linalg`, with `tests/run/lib_linalg` and
`tests/trap/linalg_*`. Every check in [Validation](#validation) is there
except the rotation round trips, Euler sequences, `slerp`, and
`project_point`, which are milestone 2. The output is the same at every
optimization level and at both CPU levels `tests/cpu_test.odin` runs.

Decided while implementing:

- **`Real` requires unary `-`.** Rotations, `look_at`, and the projections
  negate; `T(0) - x` would lose the sign of zero.
- **Its bodies compare with `<` and `==` only.** `Ordered` requires no `<=`,
  and `!(a < b)` holds for a NaN, so `a <= b` is written
  `a < b || a == b`.
- **`Matrix.splat`.** A zero-initialized record holds `T`'s zero value, which
  for a user type such as a rational `{0, 0}` is not `T(0)`; `identity` and
  the projections start from `splat(T(0))`.
- **An infinity is approximately equal only to itself.** With a relative
  tolerance, `relative * max(|a|, |b|)` is infinite for an infinite operand,
  so the formula alone would call `+Inf` close to `F64_MAX` and to `-Inf`.
- **Shape-restricted names are groups.** `determinant`, `rotation`,
  `from_vector`, and `to_vector` each select one of several private members
  by their bounds; `determinant` above 4 x 4 is elimination and needs `Real`.
- **The `_lh` projections are their twins times `diag(1, 1, -1, 1)`**, bit
  for bit, and `look_at_lh` takes `up x forward` as its side, so the
  left-handed pipeline sees the `Z`-mirrored scene as the right-handed one
  sees the scene.
- **Compile-time evaluation stops at `sqrt`.** `math.sqrt` is a foreign
  procedure, which a compile-time call cannot run
  ([Compile-time procedure evaluation](design.md#compile-time-procedure-evaluation)),
  so `length`, `normalize`, `look_at`, and the rest do not fold; the
  projections, rotations, products, and `inverse` do. The question is in
  [Correctly rounded procedures at compile time](open-questions.md#correctly-rounded-procedures-at-compile-time).

Compiler bugs found and fixed in the same change, each with a regression test
(`tests/run/generic_group_bound_order`,
`tests/run/const_eval_generic_members`):

- A procedure group declared before its members in a generic `impl` kept a
  member whose `where` bound excluded it, so every call through the group was
  ambiguous.
- A member of an instantiated generic block called at compile time before the
  checker had reached that block reported its own `where` clause as having
  nothing generic in scope, and a user operator reached through its
  resolution, such as an `inout` subscript, ran with an unchecked body.
