# Linear algebra library plan

Status: proposal, 2026-10-29. Nothing here is implemented. This document
proposes a `core:math/linalg` package; it does not change the language
contract. The authorities it builds on are
[Library numeric types](design.md#library-numeric-types),
[Operator declarations](design.md#operator-declarations),
[Methods and implementation blocks](design.md#methods-and-implementation-blocks),
[Floating-point operators](design.md#floating-point-operators),
[`core:math`](standard-library.md#coremath), and
[`core:math/repro`](standard-library.md#coremathrepro).

## Goal and scope

`core:math` has scalar functions, `Complex(T)`, and `Quaternion(T)`, but no
vectors or matrices. `Simd(T, N)` is a machine-lane abstraction with
size-alignment and constant-index rules ([Layout](design.md#layout),
[Lane access](design.md#lane-access)), not a geometry type. A program that
draws or simulates anything in two or three dimensions writes its own vector
record today.

The first caller is a game engine (DerpMiner, in a separate repository): its
camera needs view and projection matrices for OpenGL 3.3, and its collision
proof needs vector arithmetic in `f64` world space and `f32` render space. Its
conventions are right-handed, `+Y` up, `f64` world positions, and
camera-relative `f32` rendering. The package is general-purpose, so that
caller fixes the first subset, not the shape of the API.

In scope:

- `Vector2(T)`, `Vector3(T)`, and `Vector4(T)`, generic over
  `interfaces.Numeric(T)`, so integer cell coordinates use the same type as
  float positions;
- `Matrix3(T)` and `Matrix4(T)`, square, column-major, acting on column
  vectors;
- rotations as `math.Quaternion(T)`, the existing Hamilton quaternion;
- transform and camera constructors with a stated clip-space convention;
- `f32` and `f64` for everything that needs a square root, a trigonometric
  function, or a degenerate-input check.

Out of scope: general `M x N` matrices, tensors, decompositions (LU, QR,
SVD, eigenvalues), sparse storage, dual quaternions, and geometric algebra.
Rays, planes, AABBs, and frustum culling belong in a later, separate geometry
package once two callers share them (see [Later work](#later-work)). Camera
logic, camera-relative conversion, character controllers, BVHs, and contact
solvers stay in their programs.

## Design decisions

### Ordinary records, not SIMD

Each type is a plain record with named fields:

```loke
Vector2 :: struct($T: type) where interfaces.Numeric(T) { x, y: T }
Vector3 :: struct($T: type) where interfaces.Numeric(T) { x, y, z: T }
Vector4 :: struct($T: type) where interfaces.Numeric(T) { x, y, z, w: T }

Matrix3 :: struct($T: type) where interfaces.Numeric(T) { columns: [3]Vector3(T) }
Matrix4 :: struct($T: type) where interfaces.Numeric(T) { columns: [4]Vector4(T) }
```

`Vector3(f32)` is 12 bytes with 4-byte alignment, the layout of `[3]f32`, so
arrays of vertices and uniform blocks have no padding the program did not ask
for, and the types may cross a foreign boundary. A `Simd(f32, 4)` is 16-byte
aligned and allows only constant lane indices, which is the wrong contract for
stored data. The implementation may use `Simd` internally later, behind the
same records, if [measurement](#validation) shows a gain;
[Compiler-defined domain types](comments.md#compiler-defined-domain-types) is
the existing reason these are library types.

Named fields because a fixed array has no `.x` selectors and the language has
no swizzles. `operator([])` gives a runtime index for axis loops (the longest
axis of a box, a DDA step), panicking outside `0 ..< N` as array indexing does.

### Generic arithmetic, two float widths

The [`Complex` pattern](standard-library.md#coremath) carries over: a generic
`impl Vector3($T)` holds what `Numeric` can express (`+`, `-`, `*`, `/`,
`dot`, `cross`, `length_squared`, transpose, matrix products, determinant),
and `impl Vector3(f32)` and `impl Vector3(f64)` add what needs a float
(`length`, `normalize`, `inverse`, projections). Integer vectors get checked
arithmetic, so an overflowing `dot` of two `Vector3(i64)` panics like the
scalar.

`core:math` spells float-specific free procedures twice, unsuffixed for `f64`
and `_f32` for `f32`. Methods need no suffix: the receiver's type selects the
impl block, so `v.length()` is unambiguous. Constructors that take only
scalars are members of the specialized type, `Matrix4(f32).perspective_gl(...)`,
so an unfixed literal never has to choose a width. Free procedures over
quaternions take a typed vector or quaternion argument, which selects the
member of a two-member group.

There is no implicit widening or narrowing. Conversion hooks give
`Vector3(f32)(world_offset)` and `Vector3(f64)(v)`, and from `i32` and `i64`
vectors to both float widths, each component converting as the scalar
`f32(x)` does. A camera-relative offset is computed as `f64` subtraction and
then narrowed once, by the program.

### Storage and multiplication order

- Vectors are column vectors. `m * v` transforms `v`; there is no `v * m`.
- `m.columns[c]` is column `c`, and `m.columns[c][r]` is the element in row
  `r`, column `c`: column-major storage, which is OpenGL's upload order with
  `transpose = GL_FALSE`. `to_array` returns the same order as a flat
  `[16]T` or `[9]T`.
- `from_rows` exists so that a matrix can be written in source in the order
  it is printed in a textbook; `from_columns` and a literal are the storage
  order.
- `a * b` applies `b` first. `translation * rotation * scale` scales, then
  rotates, then translates.
- `format` prints rows, so printed output reads like the mathematics.

### Coordinate and rotation conventions

- Angles are radians.
- Right-handed: `cross(X, Y) == Z`. A positive angle rotates
  counterclockwise when seen from the positive end of the axis looking toward
  the origin.
- Rotations are `math.Quaternion(T)` with `real` as the scalar part (often
  called `w`). A unit quaternion `q` rotates `v` as `q v q*`, an active
  rotation; `q` and `-q` are the same rotation. `a * b` rotates by `b` first,
  matching the matrix order, so `Matrix3.from_quaternion(a * b)` equals
  `from_quaternion(a) * from_quaternion(b)` up to rounding.
- A new rotation type was considered and left out: the existing quaternion
  already has Hamilton multiplication, conjugate, and formatting, and a
  "unit" type cannot hold its invariant once rounding drifts it. Because an
  extension `impl` is visible only in its own package
  ([Methods and implementation blocks](design.md#methods-and-implementation-blocks)),
  the rotation operations are free procedures in `linalg` (`linalg.rotate(q, v)`),
  not methods on the quaternion.
- No Euler-angle API. Yaw and pitch compose as two axis rotations in the
  order the program chooses, and the documentation shows the first-person
  case:

  ```loke
  orientation := linalg.quaternion_from_axis_angle(Vector3(f32).unit_y(), yaw) *
  	linalg.quaternion_from_axis_angle(Vector3(f32).unit_x(), pitch);
  ```

### The OpenGL projection convention

The projection constructors put the convention in their names, because three
are in common use (OpenGL's `[-1, 1]` depth, Direct3D's and Vulkan's `[0, 1]`,
and reversed depth) and a silent default is the classic source of
depth-buffer bugs:

- `perspective_gl(fovy, aspect, near, far)` and
  `orthographic_gl(left, right, bottom, top, near, far)` map a right-handed
  view space, looking down `-Z` with `+Y` up, to OpenGL normalized device
  coordinates: `x`, `y`, and `z` in `[-1, 1]`, the near plane to `z = -1` and
  the far plane to `z = +1`. This needs no `glClipControl`, which OpenGL 3.3
  core lacks.
- `perspective_gl` is the usual matrix with `f = cot(fovy/2)`:

  ```text
  [ f/aspect  0   0                      0                    ]
  [ 0         f   0                      0                    ]
  [ 0         0   (far+near)/(near-far)  2*far*near/(near-far) ]
  [ 0         0   -1                     0                    ]
  ```

- Invalid parameters are programmer errors and panic, as `math.clamp` does
  for reversed bounds: `fovy` outside `(0, pi)`, a non-positive `aspect` or
  `near`, `far <= near`, or any NaN. An infinite `far` is special-cased to the
  infinite-far-plane limit (`-1` and `-2*near` in the third row), since the
  formula would divide infinity by infinity.
- `look_at(eye, target, up)` and `look_to(eye, forward, up)` build the
  right-handed view matrix whose rows are the side, up, and back vectors.
  Both return `Option(Matrix4(T))`: `.none` when `forward` is zero or parallel
  to `up`, which is the degenerate camera every engine meets when looking
  straight up.

Zero-to-one and reversed-depth variants are added when a caller targets
them; they are new names, so the existing ones never change meaning.

### Degenerate inputs are explicit

- `normalize` returns `Option(Vector3(T))`: `.none` when the squared length is
  below the format's smallest normal, infinite, or NaN. That covers the zero
  vector, vectors whose squares underflow, overflowing ones, and NaN, and
  leaves every other vector with a relative error of a few ulps.
  `normalize_or(v, fallback)` is the common pattern spelled once. There is no
  normalize that silently returns zero or NaN.
- `inverse` on a float matrix returns `Option`: `.none` when the determinant
  is zero, infinite, or NaN. A nearly singular matrix still inverts, with
  large entries; the documentation says so rather than inventing a tolerance.
- `inverse_rigid` assumes a rotation plus translation and returns the
  transpose-based inverse without checking; it is the cheap, accurate inverse
  of a camera transform. `inverse_affine` checks only the 3 x 3 part.
- `quaternion_normalize` follows `normalize`. `quaternion_from_axis_angle`
  takes the axis as given; a non-unit axis gives a non-unit quaternion, and
  the documentation shows `normalize(axis)` at the call site.
- `project_point` divides by `w` and returns `.none` when `w` is zero or the
  result is not finite; `transform_point` and `transform_direction` take `w`
  as 1 and 0 and never divide.

### Determinism

Every operation in the package gives the same bits on every machine, CPU
level, and optimization level, and at compile time, so that lockstep or
seed-generated content can use it:

- Each formula is specified in its evaluation order: `dot` is
  `(x*x' + y*y') + z*z'`, a matrix product element is the `dot` of a row and a
  column in index order, and `lerp(a, b, t)` is `a*(1 - t) + b*t`, exact at
  both ends. [Floating-point operators](design.md#floating-point-operators)
  already forbid contraction and reassociation, so the written order is the
  computed one.
- `length` uses `math.sqrt`, which is correctly rounded.
- `sin`, `cos`, and `acos` come from `core:math/repro`, not the C library.
  Rotation and projection constructors run per object or per frame, not per
  vertex, so its roughly fourfold cost
  ([Deterministic math functions](open-questions.md#deterministic-math-functions))
  does not matter here. `perspective_gl` takes `cot(fovy/2)` as
  `cos/sin`, so it does not wait for a `repro.tan`.
- No `math.fma` and no `hypot`, whose results differ by machine or CPU level.

This costs nothing on the hot path, since vector arithmetic is the plain
operators, and removes a class of desynchronization bugs that a games-oriented
library would otherwise document as a warning.

## Proposed API

Sketches in the [standard-library](standard-library.md) style: constraints and
receiver modes are omitted. `V` is the vector type of the block.

### Vectors, any `Numeric` `T`

```text
Vector2/3/4(T):
  splat(value: T) -> V
  unit_x(), unit_y(), unit_z(), unit_w() -> V        // as the dimension allows
  + - (binary), - (unary), * / (component-wise)
  * (V, T), * (T, V), / (V, T)
  ==                                                  // exact, component-wise
  [] and []= with a runtime index
  dot(a, b) -> T
  length_squared(self) -> T
  distance_squared(a, b) -> T
  min(a, b), max(a, b) -> V                           // component-wise math.min/max
  format(self, writer, options)
Vector3(T): cross(a, b) -> Vector3(T); extend(self, w: T) -> Vector4(T); xy()
Vector4(T): xyz() -> Vector3(T)
Vector2(T): extend(self, z: T) -> Vector3(T); perp(self) -> Vector2(T)   // (-y, x)
```

### Vectors, `f32` and `f64`

```text
length(self) -> T
distance(a, b) -> T
normalize(self) -> Option(V)
normalize_or(self, fallback: V) -> V
lerp(a, b: V, t: T) -> V
project(self, onto_unit: V) -> V      // onto_unit * dot(self, onto_unit)
reject(self, unit_normal: V) -> V     // self - project(self, unit_normal): sliding
abs, floor -> V                       // component-wise, for DDA and cell lookup
conversion hooks from the other float width and from i32 and i64
```

### Matrices, any `Numeric` `T`

```text
Matrix3/4(T):
  identity() -> M
  from_columns(...), from_rows(...) -> M
  column(self, c), row(self, r) -> Vector
  transpose(self) -> M
  * (M, M) -> M, * (M, Vector) -> Vector
  ==
  determinant(self) -> T
  to_array(self) -> [9]T or [16]T     // column-major
  format(self, writer, options)
Matrix4(T):
  translation(offset: Vector3(T)), scaling(factors: Vector3(T)) -> Matrix4(T)
  transform_point(self, p: Vector3(T)) -> Vector3(T)        // w = 1, no divide
  transform_direction(self, d: Vector3(T)) -> Vector3(T)    // w = 0
  upper_left(self) -> Matrix3(T)
  inverse_rigid(self) -> Matrix4(T)
  from_quaternion(q: math.Quaternion(T)) -> Matrix4(T)
Matrix3(T):
  extend(self) -> Matrix4(T)
  from_quaternion(q: math.Quaternion(T)) -> Matrix3(T)
```

`from_quaternion` assumes a unit quaternion and uses only arithmetic, so it is
generic.

### Matrices, `f32` and `f64`

```text
inverse(self) -> Option(M)
Matrix4:
  inverse_affine(self) -> Option(Matrix4(T))
  normal_matrix(self) -> Option(Matrix3(T))     // inverse transpose of upper_left
  project_point(self, p: Vector3(T)) -> Option(Vector3(T))
  rotation_x(angle), rotation_y(angle), rotation_z(angle) -> Matrix4(T)
  rotation(axis: Vector3(T), angle: T) -> Matrix4(T)
  perspective_gl(fovy, aspect, near, far: T) -> Matrix4(T)
  orthographic_gl(left, right, bottom, top, near, far: T) -> Matrix4(T)
  look_at(eye, target, up: Vector3(T)) -> Option(Matrix4(T))
  look_to(eye, forward, up: Vector3(T)) -> Option(Matrix4(T))
Matrix3: rotation_x/y/z, rotation(axis, angle) as above
```

`inverse` is the adjugate divided by the determinant, built from 2 x 2 minors
in a fixed order, each element divided rather than multiplied by a reciprocal.

### Rotations over `math.Quaternion(T)`

Free procedures, each a group of an `f32` and an `f64` member:

```text
quaternion_from_axis_angle(axis: Vector3(T), angle: T) -> Quaternion(T)
    // (cos(angle/2), sin(angle/2) * axis)
rotate(q: Quaternion(T), v: Vector3(T)) -> Vector3(T)
    // t := 2*cross(u, v); v + real*t + cross(u, t), for u the vector part
quaternion_normalize(q) -> Option(Quaternion(T))
```

## Milestones

1. **Camera.** The vector types and their generic and float members; `Matrix3`
   and `Matrix4` with products, transpose, `to_array`, translation, scaling,
   axis rotations, `from_quaternion`, `inverse`, `inverse_rigid`,
   `perspective_gl`, `orthographic_gl`, `look_at`, and `look_to`;
   `quaternion_from_axis_angle`, `rotate`, and `quaternion_normalize`. Enough
   for a first-person camera, a uniform upload, and an orthographic UI pass.
2. **Collision proof.** `project`, `reject`, `abs`, `floor`, the integer
   conversions, `normal_matrix`, `inverse_affine`, and `project_point`, and
   then, as the controller needs them: `quaternion_between(a, b)`, whose
   opposite-vector case returns `.none` or takes an explicit fallback axis;
   `nlerp` and `slerp`, `slerp` with `repro.acos` and the shortest path;
   `quaternion_from_matrix` by Shepperd's method.
3. **Measured performance.** Benchmarks of matrix products, `rotate`, and
   batch transforms against hand-written loops, then `Simd` inside the
   records only where it wins without changing a result bit.

Each milestone ships its `api.loki`, a [`standard-library.md`](standard-library.md)
section and package-layout line, a `CHANGELOG.md` line, and the tests below.

## Validation

`tests/run/lib_linalg*.loke` with `.expected` files, following
[Standard-library verification](compiler-architecture.md#standard-library-verification):

- **Exact identities**, compared bit for bit: `identity * m == m`,
  `transpose(transpose(m)) == m`, `cross(X, Y) == Z` and its cyclic
  permutations, rotations by zero, `from_rows` against `from_columns` of the
  transpose, and `to_array` order.
- **Approximate identities** with tolerances stated per test, as a small
  multiple of the format's epsilon times the operands' magnitude:
  `m * inverse(m)` near identity for well-conditioned `m`; rotation matrices
  orthonormal with determinant 1; `from_quaternion` agreeing with `rotate`;
  `from_quaternion(a * b)` agreeing with the product; `normalize` within a
  few ulps of length 1.
- **Degenerate inputs**: zero, subnormal, huge, infinite, and NaN vectors
  through `normalize`; singular and NaN matrices through `inverse`; `look_at`
  with `eye == target` and `forward` parallel to `up`; `project_point` at
  `w = 0`; every `perspective_gl` panic case, and an infinite far plane.
- **The GL convention**: a point on the near plane on the view axis maps to
  `z = -1`, on the far plane to `+1`; clip `w` equals `-z_view`; a point at
  `+Y` lands at positive NDC `y`; `look_at` from `+Z` toward the origin is the
  identity rotation.
- **Both widths**: each test runs at `f32` and `f64`, and the `f64` world to
  camera-relative `f32` narrowing is pinned with a large world coordinate.
- **Integers**: `Vector3(i64)` arithmetic, and an overflowing `dot` panics.
- **Determinism**: results printed as bit patterns, the same at every
  optimization and [CPU level](compiler-guide.md#cpu-levels) and when folded
  at compile time, as `tests/repro_test.odin` checks for `core:math/repro`.

## Later work

- A geometry package (`Aabb`, `Ray`, `Plane`, frustum planes from a
  projection-view matrix, ray-box and ray-triangle tests) once a second
  caller shares the engine's needs.
- Zero-to-one and reversed-depth projections, with the first caller that
  targets them.
- `Matrix2`, affine 2D transforms, and non-square matrices, each with a
  caller.

## Questions to settle before implementing

- Whether a generic conversion hook (`Vector3(T)` from `Vector3($U)`) can be
  constrained to convertible pairs, or the hooks stay a fixed list.
- Whether the package should export short aliases (`Vector3f`, `Vector3d`) or
  leave `Vec3 :: linalg.Vector3(f32);` to programs. The proposal leaves them
  out.
- Whether an approximate-equality helper belongs in the public API or only in
  the tests. The proposal keeps it in the tests until a caller needs one.
- Whether `perspective_gl` should validate with panics, as proposed, or
  return `Option`; constructing a projection from runtime settings (a field of
  view slider) might argue for `Option`.
- Whether `unit_x()` and the like are constants in the generic `impl` or
  procedures, depending on what the compiler accepts for a generic constant.
