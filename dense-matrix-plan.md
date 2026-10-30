# Dense matrix library plan

Status: milestones 1 to 5 implemented, 2026-10-29, as
[`core:math/dense`](standard-library.md#coremathdense)
([Milestone 1 results](#milestone-1-results),
[Milestone 2 results](#milestone-2-results),
[Milestone 3 results](#milestone-3-results),
[Milestone 4 results](#milestone-4-results),
[Milestone 5 results](#milestone-5-results)), after its design questions were
settled and its spike run the same day ([Settled questions](#settled-questions),
[Spike results](#spike-results)). It is
milestone 3 of the
[linear algebra library plan](linear-algebra-plan.md#milestones), which left
this package [its own plan](linear-algebra-plan.md#dense-matrices-a-later-package)
and the questions it has to settle. Nothing here changes the language
contract; the language questions it raises are in
[open-questions.md](open-questions.md#open-questions-from-the-linear-algebra-spike).
The authorities it builds on are
[Allocators](design.md#allocators),
[Allocation failure](design.md#allocation-failure),
[Values that contain borrows](design.md#values-that-contain-borrows),
[Capabilities and the one rule](design.md#capabilities-and-the-one-rule),
[Splitting a mutable slice](design.md#splitting-a-mutable-slice),
[Parallel blocks](design.md#parallel-blocks),
[The `unsafe` package](design.md#the-unsafe-package),
[Floating-point operators](design.md#floating-point-operators),
[Errors are values](standard-library.md#errors-are-values),
[Ownership is visible](standard-library.md#ownership-is-visible), and
[`core:math/linalg`](standard-library.md#coremathlinalg).

## Goal and scope

[`core:math/linalg`](standard-library.md#coremathlinalg) covers shapes fixed at
compile time, as values that never allocate. Sizes known only at run time are a
different contract: the storage is allocated, it is borrowed far more often than
copied, and the work is in the solvers rather than in the operators. Statistics
and regression, curve and surface fitting, finite elements and circuit
simulation, Kalman filters with run-time state sizes, structure from motion and
bundle adjustment, principal component analysis, spectral clustering, and
machine-learning inference all need the same core: a matrix whose size is data,
views of it and of foreign buffers, products, and the standard factorizations.

The package is for those uses together, under the rules `linalg` already
follows:

- every result is the same bits on every machine, CPU level, and optimization
  level, so a regression test, a replay, or a distributed computation can rely
  on it;
- ownership and allocation are visible: an operation that allocates takes an
  allocator, and every operation has a form that writes into caller storage;
- a programmer error (a shape mismatch, an index outside a view) panics, and a
  numerical failure (a singular matrix, one that is not positive definite, an
  iteration that does not converge) is a returned error;
- nothing decides with a tolerance the caller did not give, except where an
  algorithm's convergence test is defined by rounding, which is stated.

Out of scope: sparse storage, tensors of rank above 2, banded and packed
storage, distributed matrices, and a foreign BLAS or LAPACK binding, which
would give different bits on different machines
([Determinism and speed](#determinism-and-speed)).

## Design decisions

### One owner and two views

```loke
Matrix :: struct($T: type) where interfaces.Numeric(T) {
	@(private) row_count, column_count: int,
	@(private) data: [dynamic]T,       // column-major, rows*columns elements
}

View :: struct($T: type) where interfaces.Numeric(T) {
	@(private) data: []T,
	@(private) row_count, column_count: int,
	@(private) row_stride, column_stride: int,
}

View_Mut :: struct($T: type) where interfaces.Numeric(T) {
	@(private) data: []mut T,
	@(private) row_count, column_count: int,
	@(private) row_stride, column_stride: int,
}
```

- `Matrix(T)` owns contiguous column-major storage, the order LAPACK, Fortran,
  MATLAB, Julia, R, and `linalg.Matrix` use. Its allocator is the one its
  `[dynamic]T` remembers ([Allocators](design.md#allocators)), chosen at
  construction.
- A view is a borrow of elements somewhere else: element `(r, c)` is
  `data[r*row_stride + c*column_stride]`. One type covers every case without a
  copy: a whole matrix, a block of it, its transpose (the strides swapped), a
  single row or column, a column-major foreign buffer with a leading dimension,
  and a row-major one (`row_stride = columns`, `column_stride = 1`).
- The fields are private, and every constructor checks once that the largest
  index the shape and strides reach is inside `data`, and that the leading
  dimension covers a whole column or row, so that no two elements share a
  place. The kernels can then index
  without a check per element, through `unsafe.raw_data`, and stay memory-safe:
  safe code cannot build a view whose strides point outside its slice. Strides
  are non-negative; a reversed view is a later addition if a caller needs one.
- A view carries its slice's borrow
  ([Values that contain borrows](design.md#values-that-contain-borrows)), so
  the checker keeps it from outliving the matrix or buffer, and the
  capability is in the type: `View` reads, `View_Mut` writes.
- A vector is a view with one column. A contiguous `[]T` becomes one with
  `View(T).from_column(values)`, so no procedure needs a separate vector form.

Two mutable views of one matrix cannot both be live, by
[the one rule](design.md#capabilities-and-the-one-rule), so `multiply_into(out,
a, b)` needs no aliasing check: a call that writes `out` while `a` reads the
same storage is rejected where it is written. Disjoint mutable blocks come from
splitting, as [`split_at_mut`](design.md#splitting-a-mutable-slice) splits a
slice. `split_columns(k)` splits a column-major view, whose columns are
contiguous runs; `split_rows(k)` splits a row-major one. A split across the
interleaved direction, the top and bottom rows of a column-major matrix, has no
safe spelling yet ([Disjoint strided mutable views](open-questions.md#disjoint-strided-mutable-views)).
The factorizations need none: each works through one `View_Mut` by index.

### Copying is a clone

A `Matrix(T)` copies as its `[dynamic]T` does, deeply, which
[Copy-cost diagnostics](design.md#copy-cost-diagnostics) report as a clone.
Making it `move_only` was considered: it would stop an accidental copy, but a
matrix is a value in every numerical language, a copy is sometimes what the
algorithm wants, and the diagnostic already names it. A copy in an ordinary
argument is a borrow, not a clone, and `clone(m, allocator)` copies into a
chosen allocator.

### Named procedures, not operators

`Matrix(T)` has no `+`, `-`, or `*`. Each result of `a * b + c` would be a
matrix allocated from an allocator the expression cannot name, which
[Ownership is visible](standard-library.md#ownership-is-visible) rules out, and
a temporary per operator is the cost a numerical program most wants to see.
Every operation is a named procedure in two forms:

- `multiply_into(out: View_Mut(T), a, b: View(T))` writes into caller storage
  and never allocates;
- `multiply(a, b: View(T), allocator := mem.default_allocator()) -> Matrix(T)`
  allocates its result.

The same pairing holds for `add`, `subtract`, `scale`, `transpose`, and every
factorization. The fused forms that avoid a temporary are separate names:
`multiply_add_into(out, a, b)` is `out += a * b`.

### Element types

Storage, views, and products need `interfaces.Numeric(T)`, so integer and
rational matrices work. The factorizations need `linalg.Scalar(T)`, a real or
complex number type: `T.Real` names the type of its parts, which is
`linalg.Real`, and `conjugate`, `real_part`, and `imaginary_part` give the
rest. `f32`, `f64`, and `math.Complex(R)` for any `Real(R)` meet it, and a
user real type, such as a dual number, meets it with four members beside
`linalg.Real`'s, so a dual number differentiates through `solve` as it does
through `linalg.inverse` ([Milestone 5 results](#milestone-5-results)).

### Shapes and errors

- A shape mismatch is a programmer error and panics: `multiply_into` with
  `a.columns() != b.rows()`, an `out` of the wrong shape, a non-square input to
  `lu`.
- A numerical failure is `Result(T, Error)` or `Status(Error)`
  ([Errors are values](standard-library.md#errors-are-values)), with one error
  type for the package:

  ```loke
  Error :: enum {
  	Singular,               // an exact zero pivot, or a non-finite result
  	Not_Positive_Definite,  // a Cholesky pivot that is not positive
  	No_Convergence,         // an iteration limit reached
  }
  ```

  One type keeps `or_return` working through a chain such as "factor, solve,
  refine" without [changing error domains](design.md#changing-error-domains);
  each procedure documents which variants it returns.
- Allocation follows the allocator's [failure policy](design.md#allocation-failure),
  as `make` does. `try_` forms that return allocation failure too are added
  with a caller who needs them; the `_into` forms never allocate, so a program
  that must not fail on allocation already has a path.
- Singularity is decided as `linalg` decides it: an exact zero pivot, or a
  result that is not finite. A nearly singular matrix factors with large
  elements, and `Lu.reciprocal_condition` estimates how near it is, so the
  caller chooses the tolerance.

### Factorizations are values

A factorization is computed once and used many times, so each is a record that
owns its factors:

```loke
Lu :: struct($T: type) where linalg.Real(T) {
	@(private) packed: Matrix(T),    // L below the diagonal (unit diagonal), U on and above
	@(private) swaps:  [dynamic]int,
	@(private) norm:   T,            // the 1-norm of A, for reciprocal_condition
}
```

`lu(a, allocator)` returns `Result(Lu(T), Error)`, and the result has `solve`,
`solve_into`, `determinant`, `inverse`, `reciprocal_condition`, and the
factors and pivots in `getrf`'s form. The
in-place form `lu_in_place(a: View_Mut(T), pivots: []mut int) -> Status(Error)`
overwrites `a` with the factors as LAPACK's `getrf` does, for a caller who owns
the storage. Cholesky and QR follow the same pattern. The symmetric
eigendecomposition and the SVD are records too, without an in-place form
([Milestone 3 results](#milestone-3-results)).

### Determinism and speed

Each operation's floating-point order is part of its contract, as in `linalg`:

- An element of a product is `((a[i,0]*b[0,j] + a[i,1]*b[1,j]) + ...)`, the
  terms in increasing `k`, the same order `linalg.Matrix` uses.
- An update in a factorization is applied as one subtraction per term into the
  running element, in increasing `k`: LU's trailing element is
  `((a - l0*u0) - l1*u1) - ...`, not `a - (l0*u0 + l1*u1 + ...)`.
- Reductions (`dot`, norms) sum in index order.

This costs less speed than it seems. Cache blocking and threads that split the
*output* keep each element's order: a blocked product that visits the `k`
blocks in increasing order updates each accumulator in the same sequence, and
a `Simd` kernel that computes several outputs side by side (the columns of a
column-major `a`) performs the same scalar operations in each lane. The one
thing ruled out is splitting a single sum into several accumulators, which a
column-major product and `A * x` never need and only a long `dot` would.
Blocked LU and Cholesky keep the unblocked order by the update rule above, and
are what `lu` and `cholesky` run ([Milestone 4 results](#milestone-4-results)).
Blocked Householder QR in the compact WY form does not: it reorders the
reflector updates, so QR stays unblocked, its reflectors applied to a panel of
columns at a time with each column's order unchanged
([Settled questions](#settled-questions)).

A foreign BLAS is faster still, and its results differ by machine, library,
and thread count. It belongs in a separate package that binds one, with that
contract stated, not behind a flag in this one.

Threads take a `^thread.Pool` ([Pools](standard-library.md#pools)) as an
optional `pool: Option(^thread.Pool) = .none` argument to the operations that
use one, run under a [`parallel (pool)`](design.md#parallel-blocks) block, and
split the output, so a threaded result is bit-identical to a sequential one.
The products, `lu`, and `cholesky` take one
([Milestone 4 results](#milestone-4-results)).

### Algorithms

| Operation | Method | Fails with |
| --- | --- | --- |
| `lu`, `solve` | Gaussian elimination, partial pivoting, the first largest magnitude on a tie, a complex element's being the sum of its parts' magnitudes; blocked, right-looking | `Singular` |
| `cholesky` | the `L L^H` factor, by columns; blocked, left-looking, or right-looking with a pool | `Not_Positive_Definite` |
| `qr`, `least_squares` | Householder reflectors, unblocked, applied a panel at a time; full column rank assumed | `Singular` for an exact zero on `R`'s diagonal |
| `symmetric_eigen` | Householder reduction to a real tridiagonal, then implicit QL with Wilkinson shifts; Hermitian for a complex `T` | `No_Convergence` |
| `svd` | Golub-Kahan reduction to a real bidiagonal, then implicit-shift QR (Golub-Reinsch) | `No_Convergence` |
| `reciprocal_condition` | Hager and Higham's 1-norm estimator on an `Lu` | |
| `norm_frobenius` | one pass with a running scale, so it does not overflow | |

The iterative methods test convergence by rounding rather than by a
tolerance, as EISPACK's `imtql2` and LINPACK's `dsvdc` do: an off-diagonal
element `e` is negligible when `t + |e| == t` for the sum `t` of its two
diagonal neighbours' magnitudes. That needs no epsilon in `linalg.Real`, works
for any element type, and is the same test at every precision. Each has a
fixed iteration limit, 30 sweeps for each eigenvalue or singular value as in
EISPACK and LINPACK but pooled over the matrix
([Milestone 3 results](#milestone-3-results)), and returns `No_Convergence`
past it, which for these methods is a bug report rather than an expected
outcome. Jacobi methods, slower and more accurate for small singular values,
are a later addition.

`least_squares` assumes full column rank. A rank-deficient problem needs a
rank decision, so its minimum-norm solution is `Svd.solve(b, relative)`, which
treats singular values below `relative * largest` as zero and has no default
for `relative`.

## Proposed API

Sketches in the [standard-library](standard-library.md) style; constraints,
receiver modes, and the `allocator := mem.default_allocator()` parameters are
omitted, and so are the `pool := .none` parameters of `multiply`,
`multiply_into`, `multiply_add_into`, `lu`, `lu_in_place`, `cholesky`, and
`cholesky_in_place`. "Scalar" means members bounded by `linalg.Scalar(T)`; a
norm, a tolerance, an eigenvalue, and a singular value are `T.Real`, and a
transpose in a factorization is the conjugate transpose.

```text
Matrix(T), any Numeric T:
  zeros(rows, columns), filled(rows, columns, value), identity(n)
  from_view(View), from_fixed(linalg.Matrix(T, R, C))
  from_column_major([]T, rows, columns), from_rows([R][C]T)    // copies
  rows(), columns(), [r, c] and [r, c]=, view(), view_mut(), to_fixed($R, $C)
  format                                       // by rows, as linalg

View(T) and View_Mut(T), any Numeric T:
  from_column_major(data, rows, columns, leading := rows)
  from_row_major(data, rows, columns, leading := columns)
  from_column(values) -> rows x 1
  rows(), columns(), [r, c] (and [r, c]= on View_Mut)
  block(row, column, rows, columns), transpose(), row(r), column(c), to_fixed($R, $C)
  View, Scalar T: adjoint()                    // conjugated, no copy
  View_Mut: as_view(), fill(value), copy_from(View), scale_by(s), add_scaled(s, View),
            split_columns(k), split_rows(k)   // panic for the interleaved direction

Operations, any Numeric T, each with an `_into` form:
  multiply(a, b), multiply_add_into(out, a, b), add(a, b), subtract(a, b),
  scale(a, s), transpose(a), dot(x, y), trace(a), equal(a, b)

Scalar:
  approx_equal(a, b, absolute, relative)       // linalg's rule, element-wise, by modulus
  norm_frobenius(a), norm_one(a), norm_infinity(a)
  lu(a) -> Result(Lu(T), Error); lu_in_place(a, pivots) -> Status(Error)
    Lu: solve(b), solve_into(b), determinant(), inverse(), reciprocal_condition(),
        factors(), pivots(), size()
  cholesky(a) -> Result(Cholesky(T), Error)    // reads the lower triangle
  cholesky_in_place(a) -> Status(Error)
    Cholesky: solve(b), solve_into(b), determinant(), lower(), size()
  qr(a) -> Result(Qr(T), Error)                // rows >= columns
  qr_in_place(a, tau) -> Status(Error)
    Qr: least_squares(b), least_squares_into(b), q(), r(),
        apply_q_into(b), apply_q_adjoint_into(b), factors(), tau(), rows(), columns()
  solve_lower_into(l, b, unit_diagonal), solve_upper_into(u, b, unit_diagonal)
  solve(a, b), inverse(a), least_squares(a, b) // factor, then solve, in one call
  symmetric_eigen(a) -> Result(Symmetric_Eigen(T), Error)   // reads the lower triangle
    Symmetric_Eigen: values() ascending; vectors() as columns, each with its
        largest-magnitude component positive, the first on a tie; size()
  svd(a) -> Result(Svd(T), Error)              // thin, any shape
    Svd: u(), singular_values() descending, v(), each pair signed as an
        eigenvector is by its column of v; rank(relative),
        solve(b, relative), solve_into(out, b, relative), rows(), columns()
```

The sign conventions in `symmetric_eigen` and `svd` are part of the contract,
so that two runs, two machines, and two versions give the same vectors and not
merely the same subspaces.

## Milestones

1. **Storage, views, products, LU, and Cholesky.** Done
   ([Milestone 1 results](#milestone-1-results)). `Matrix`, `View`,
   `View_Mut`, the splits, products and the element-wise operations,
   triangular solves, `lu`, `cholesky`, `solve`, `inverse`, `determinant`,
   `reciprocal_condition`, and the norms. The spike before it is done
   ([Spike results](#spike-results)).
2. **QR and least squares.** Done
   ([Milestone 2 results](#milestone-2-results)). `qr`, `least_squares`, and
   the `Q` application forms.
3. **Eigenvalues and singular values.** Done
   ([Milestone 3 results](#milestone-3-results)). `symmetric_eigen` and
   `svd`, with `Svd.solve`.
4. **Measured performance.** Done
   ([Milestone 4 results](#milestone-4-results)). Benchmarks against
   hand-written loops and a reference BLAS for scale, then blocking, `Simd`
   kernels across outputs, and the optional pool, each kept only where it wins
   without changing a bit.
5. **Complex elements.** Done
   ([Milestone 5 results](#milestone-5-results)). A conjugate-aware
   interface, Hermitian products, complex LU and QR, and the Hermitian
   eigensolver, and complex Cholesky and SVD with them.

Each milestone ships its `api.loki`, a [`standard-library.md`](standard-library.md)
section (the first one with a package-layout line), a `CHANGELOG.md` line, and
the tests below.

## Validation

`tests/run/lib_dense*.loke` with `.expected` files, following
[Standard-library verification](compiler-architecture.md#standard-library-verification):

- **Views**: every constructor's bounds check at and beside its limit (in
  `tests/trap`), a transpose and a block of a transpose against copies, a
  row-major foreign buffer, splits in both directions and the panic for the
  interleaved one, and the borrow checker rejecting `multiply_into(m.view_mut(),
  m.view(), b)` (in `tests/err`).
- **Exact results**: integer and rational products and determinants by hand;
  products against `linalg.Matrix` for shapes up to 4 x 4, bit for bit, since
  the order is the same.
- **Residuals**, as LAPACK's test ratios: `|A - LU| / (n |A| eps)`,
  `|A x - b| / (|A| |x| eps)`, `|Q^T Q - I| / (n eps)`, `|A V - V D|`, and
  `|A - U S V^T|`, each below a stated bound, for random, Hilbert, Wilkinson,
  graded, and nearly singular matrices from 1 x 1 to 200 x 200, with rows
  fewer than, equal to, and more than columns where the operation allows.
- **Failures**: an exact singular matrix, a NaN, an indefinite matrix through
  `cholesky`, and a rank-deficient `least_squares` against `Svd.solve`.
- **Element types**: `f32` and `f64` throughout, `math.Complex` of each,
  integers through the `Numeric` operations, and a dual number through `lu`
  and `solve`, whose derivative is checked against `-A^{-1} (dA) A^{-1} b` for
  a constant `b`.
- **Determinism**: results as bit patterns, the same at every optimization and
  [CPU level](compiler-guide.md#cpu-levels), with a pool and without.

## Settled questions

Settled on 2026-10-29, each as recommended; the sections above carry the
decisions.

- **The package's name**: `core:math/dense`, with `dense.Matrix(T)`,
  `dense.View(T)`, and `dense.lu`, beside `linalg.Matrix(T, R, C)`.
  `core:math/linalg/dense` was rejected: it says the relation at the cost of
  a longer import, and would have stuttered as `dense.Dense` had the type kept
  the earlier name `Dense(T)`. `core:math/matrix` was rejected because it
  reads as the home of every matrix, the fixed-size ones included.
- **Copying**: `Matrix(T)` is copyable, and a copy is a clone
  ([Copying is a clone](#copying-is-a-clone)). `move_only` was rejected
  because a copy is sometimes what an algorithm wants, and the copy-cost
  diagnostic already reports one.
- **Operators**: none on `Matrix(T)`
  ([Named procedures, not operators](#named-procedures-not-operators)). `*`
  and `+` allocating from the default allocator, as NumPy and Eigen read, were
  rejected for the hidden allocation and the temporary per operator.
- **Errors**: one `dense.Error` for every numerical failure, so `or_return`
  chains across factorizations; each procedure documents its variants. A type
  per factorization would say more in each signature and break those chains.
- **Allocation failure**: no `try_` forms in the first milestone. Allocation
  follows the allocator's policy, and the `_into` forms are the path that
  never allocates.
- **QR**: unblocked Householder only, so QR has one result everywhere. The
  blocked WY form, LAPACK's choice, is faster on large matrices because its
  updates are matrix products, and it changes the bits; a separate `qr_fast`
  was to be decided with milestone 4's benchmarks, and waits for a caller
  ([Milestone 4 results](#milestone-4-results)).
- **SVD**: Golub-Reinsch first. One-sided Jacobi, simpler and more accurate
  for tiny singular values but several times slower, is a later addition.
- **Fixed-size matrices**: `from_fixed` and `to_fixed` copy. A view without a
  copy waits for a flattening borrow
  ([Flat views of nested fixed arrays](open-questions.md#flat-views-of-nested-fixed-arrays)).

## Spike results

Done 2026-10-29. The spike was a cut-down package, `tests/pkg/dense_spike`,
with `Matrix`, `View`, `View_Mut`, `split_columns_mut`, `multiply_into`, and
LU, used from a program at `f64` and with a forward-mode dual number. Its
output was the same at every optimization level and at both CPU levels tried.
Milestone 1 replaced it, and its aliasing test, what the borrow checker must
reject, is now `tests/err/lib_dense_aliasing.loke`. No compiler change was
needed.

What held as planned:

- Views as records with private fields that carry their slice's borrow. A view
  of a foreign buffer in either order, a transpose, and a block all index
  alike.
- `split_columns_mut` through `split_at_mut` inside a generic method, with
  both halves written at once.
- `Result(Lu(T), Error)` holding owners, `Status(Error)` through `or_return`,
  and a dual number through `lu` and `solve_into`, whose derivative
  `(-0.12, 0.04)` is the analytic one.
- The borrow checker, with no run-time check, rejects all three misuses:
  `multiply_into(m.view_mut(), m.view(), b)` (`L0511`), returning a view of a
  local matrix (`L0526`), and writing a matrix while a view of it is live
  (`L0512`).

What the package must allow for:

- **`view` takes `self: ^`.** A plain `self` is a value whose borrows end with
  the call ([Receiver forms](design.md#receiver-forms)); `view_mut` and the
  splits take `self: inout`.
- **Accessors cannot share a field's name**, even a private field's, since
  `m.rows` would select the field. The fields are `row_count` and
  `column_count`, and the accessors are `rows()` and `columns()`.
- **A `View_Mut` parameter is copied to a local before it is written through
  `[r, c]=`**, since the subscript's receiver is `inout` and a parameter is
  not a variable. The copy is a reborrow and costs nothing.

The kernel, measured as the best of several runs of a 256 x 256 `f64`
product with `-opt=speed` on the development machine (milliseconds):

| Kernel | `x86-64` | `x86-64-v3` |
| --- | --- | --- |
| through a view's checked `[r, c]` | 21.7 | 21.1 |
| a hand-written loop over a slice, checked indexing | 17.0 | 17.0 |
| raw pointers, checked index arithmetic | 14.7 | 14.9 |
| raw pointers, wrapping index arithmetic, contiguous | 4.2 | 2.6 |
| the view kernel: raw pointers, wrapping arithmetic, any strides | 4.4 | 2.6 |

- **Index once, then index unchecked.** The checked subscript costs a factor of
  five to eight against the final kernel, which confirms the private-stride
  design: the extent is checked when the view is made, and the kernels read
  through `unsafe.raw_data`.
- **The kernels' index arithmetic is wrapping.** A checked `+` or `*` is a
  panic branch per element ([Integer overflow](design.md#integer-overflow)),
  and it alone keeps the loop from vectorizing: raw pointers with checked
  arithmetic are barely faster than the checked loop. Every index in a kernel
  is below its view's checked extent, so `+%` and `*%` never wrap there.
  Written so, the strided kernel runs as fast as the contiguous one on
  contiguous data, so a separate unit-stride kernel is not needed. It
  vectorizes across rows, the output
  elements, so the bits are those of the checked kernel, which the spike
  compares element for element.
- A hand-written loop pays the same price, which is a language question
  rather than this package's
  ([Overflow checks in index arithmetic](open-questions.md#overflow-checks-in-index-arithmetic)).

## Milestone 1 results

Done 2026-10-29, as
[`core:math/dense`](standard-library.md#coremathdense) with its `api.loki`.
`tests/run/lib_dense.loke` covers storage, views, splits, products, the
element-wise operations, and the norms; `tests/run/lib_dense_solve.loke` the
factorizations; each `tests/trap/dense_*.loke` one panic; and
`tests/err/lib_dense_aliasing.loke` the checker. Both run tests give the same
output at every optimization level and CPU level tried, and both are in the
CPU-level corpus.

What the tests show:

- **Products** equal `linalg.Matrix`'s bit for bit for every shape tried up to
  4 x 4, and through transposed views and blocks of larger matrices.
- **LAPACK's test ratios**, `|P A - L U| / (n |A| eps)`, `|A x - b| / (|A| |x|
  eps)`, `|A A^-1 - I| / (n |A| |A^-1| eps)`, and their Cholesky forms, stay
  below 1 for random, Hilbert (to 10 x 10), graded, and nearly singular
  matrices from 1 x 1 to 200 x 200 at `f64` and to 64 x 64 at `f32`; LAPACK's
  threshold is 30, which the test checks.
- **The Wilkinson matrix**, the worst case for partial pivoting, is not among
  those families: its growth is `2^(n-1)`, so its residuals are as large as
  that predicts. Every operation on it is exact, so the test checks instead
  that `P A = L U` exactly and that `U`'s last element is `2^(n-1)`. The
  symmetric Wilkinson matrices belong with the eigensolver tests of
  milestone 3.
- **`reciprocal_condition`** is never below the exact `1 / (|A|_1 |A^-1|_1)`
  and never above three times it, for those families at sizes 2 to 31.
- **A dual number** through `solve` gives the derivative `-A^-1 E x` to within
  `1e-10` relative, and its value parts are the `f64` solution bit for bit.
- **Rational elements** are not tested: the standard library has no rational
  type, and integers cover exact `Numeric` arithmetic.

What changed from the plan:

- **Receivers for smaller views.** `block`, `transpose`, `row`, `column`, and
  the splits on a `View_Mut` are each a group of a `self: move` member and a
  `self: inout` one. A temporary or `move(v)` is consumed, so
  `left, right := m.view_mut().split_columns(k)` can be bound, which a
  borrowing receiver alone forbids; a named view is borrowed and stays usable.
  The splits lost the plan's `_mut` suffix, which on `View_Mut` said nothing.
- **In-place element-wise forms.** The one rule rejects
  `add_into(m.view_mut(), m.view(), b)`, so `out += s*a` needs a form of its
  own: `View_Mut.add_scaled(s, a)` and `scale_by(s)`, beside `fill` and
  `copy_from`.
- **Overlapping views.** Every constructor also checks that the leading
  dimension covers a column (or row), so no two elements of a view share a
  place, which the splits and a later threaded kernel rely on.
- **The triangular solves** both take `unit_diagonal`, which has no default,
  and return `Status(Error)`: `.Singular`, with `b` unchanged, for an exact
  zero on a diagonal that is read.
- **`from_rows`** takes a nested fixed array, `[R][C]T`, which a literal
  writes as it prints; a run-time row-major buffer is copied with
  `from_view(View.from_row_major(...))`.
- **`Lu.factors()` and `Lu.pivots()`** give the packed factors in `getrf`'s
  form, which the residual tests need and a caller passing them to other code
  does too. `inverse(a)` is the one-call form beside `solve(a, b)`.
- **The bound on each method.** A method of `impl Lu($T)` that calls a `Real`
  slot restates `where linalg.Real(T)`, although `Lu` itself is bounded so
  ([Slots through a record's bound](open-questions.md#slots-through-a-records-bound)).

The kernels, the products, the element-wise operations, the factorizations,
and the substitutions index through `unsafe.raw_data` with wrapping index
arithmetic, which the spike found they need to vectorize. Their speed is
measured in [milestone 4](#milestone-4-results).

## Milestone 2 results

Done 2026-10-29: `qr`, `qr_in_place`, `Qr`, and `least_squares` in
[`core:math/dense`](standard-library.md#coremathdense).
`tests/run/lib_dense_qr.loke` checks them, in the CPU-level corpus with the
same output at every optimization and CPU level tried, and
`tests/trap/dense_qr_wide.loke` the panic for a wide matrix.

- **LAPACK's test ratios**, `|A - Q R| / (m |A| eps)`, `|Q^T Q - I| / (m eps)`,
  and for the least-squares residual `r`,
  `|A^T r| / (m |A| (|A| |x| + |b|) eps)`, stay below 30 for random, Hilbert
  (to 10 columns at `f64`, 6 at `f32`), column-graded, and nearly
  rank-deficient matrices from 1 x 1 to 200 x 200 at `f64` and to 64 x 64 at
  `f32`.
- **Exact cases**: orthogonal columns give their exact `R` and reflectors, a
  fitted line its coefficients and residual norm, and an exact fit no
  residual.
- **`Q`** applied and then transposed returns `b`; the whole `Q`, built by
  applying it to the identity, is orthogonal, and its first columns are
  `q()` bit for bit; `Q^T A` is `R` above zero rows.
- **A dual number** through `least_squares` gives the analytic derivative
  `(A^T A)^-1 (E^T r - A^T E x)`, and its value parts are the `f64`
  minimizer bit for bit.

Decided while implementing:

- **The reflectors are LAPACK's.** `beta = -sign(alpha) hypot(alpha, s)`,
  so `R`'s diagonal may be negative, as `geqrf`'s is; the column norm uses
  `norm_frobenius`'s running scale and `hypot` scales too, so neither
  overflows. `v` is computed by dividing by `alpha - beta`, not by
  multiplying by its reciprocal, which could overflow where the quotient
  cannot. A zero below the diagonal gives the identity reflector, `tau = 0`,
  which `apply_q_into` skips as `larf` does.
- **Full rank is decided by an exact zero on `R`'s diagonal**, as the plan
  says. A nearly rank-deficient matrix factors, and its least-squares
  solution is large; the rank decision belongs to `Svd.solve` in milestone 3.
- **`least_squares_into(b)`** is the form that does not allocate. It leaves
  the residual's components in `b`'s last `m - n` rows, as `gels` does, so
  the residual norm costs nothing more; `least_squares` copies the first `n`
  rows out.
- **`q()` is the thin `Q`**, `m x n`. The whole `Q` is `apply_q_into` of the
  identity, which most uses never need, since `apply_q_into` and
  `apply_q_transpose_into` apply it without forming it.

## Milestone 3 results

Done 2026-10-29: `symmetric_eigen`, `Symmetric_Eigen`, `svd`, and `Svd` in
[`core:math/dense`](standard-library.md#coremathdense).
`tests/run/lib_dense_eigen.loke` and `tests/run/lib_dense_svd.loke` check
them, both in the CPU-level corpus with the same output at every optimization
and CPU level tried, and `tests/trap/dense_eigen_square.loke` and
`tests/trap/dense_svd_relative.loke` the two panics.

- **LAPACK's test ratios**, `|A V - V D| / (n |A| eps)` and
  `|V^T V - I| / (n eps)` for the eigensolver, and
  `|A - U S V^T| / (max(m, n) |A| eps)`, `|U^T U - I| / (m eps)`, and
  `|V^T V - I| / (n eps)` for the SVD, stay below 30 (the eigensolver's below
  3) for random, Hilbert, graded, Wilkinson, and nearly repeated symmetric
  matrices, and for random, Hilbert, column-graded, and rank-deficient ones
  of shapes from 1 x 1 to 200 x 200, tall and wide, at `f64` and to 64 x 64
  at `f32`. Every result has the order and signs the contract gives.
- **Exact cases**: a diagonal matrix gives its values sorted and a
  permutation of the identity, the SVD moving a negative value's sign into
  `U`; the tridiagonal matrix with 2 on the diagonal and 1 beside it gives
  its known eigenvalues and signed eigenvectors; and a transposed matrix's
  SVD is the original's with `U` and `V` exchanged, bit for bit.
- **Wilkinson's W21+** gives its two largest eigenvalues, which agree to 14
  digits, each within a relative `4 eps` of the published value, with
  orthogonal vectors.
- **`Svd.solve`** of a full-rank tall system is `least_squares`'s solution;
  of a rank-deficient one it is orthogonal to the null space and satisfies the
  normal equations; of a wide one it reproduces `b`; and a zero column, which
  `least_squares` reports as `.Singular`, gets exactly 0. `rank` finds the
  rank of a product of random factors.
- **A dual number** through `symmetric_eigen` gives each eigenvalue's
  derivative `v^T E v`, and through `svd` each singular value's `u^T E v`,
  and the value parts are the `f64` results bit for bit.

Decided while implementing:

- **The iteration limit is pooled**, `30 n` sweeps for the whole matrix
  rather than 30 for each value as `dsvdc` and `imtql2` have it. In the
  200 x 200 column-graded test matrix, the top of the bidiagonal is large,
  and the shift, computed from the small trailing block, is lost against it
  in rounding, so the sweeps converge only linearly: the first singular value
  took 62 sweeps, and the other 199 then took 212 between them. A limit for
  each value failed there and at 64 x 64 in `f32`; LAPACK's `bdsqr` pools its
  limit too. A result that converged under the old limit is unchanged.
- **The QL iteration is `tqli`'s**, Numerical Recipes' form of EISPACK's
  `imtql2`, after `sytd2`'s tridiagonalization, which reads and updates only
  the lower triangle, so the trailing block stays exactly symmetric. The SVD's
  iteration is `dsvdc`'s, after `gebd2`'s bidiagonalization. Both reductions
  build their reflectors with `qr_in_place`'s code, now shared, whose results
  are unchanged.
- **No in-place forms.** Both iterations need several vectors of scratch
  beyond the matrix, so an `_in_place` form would need a workspace argument;
  the allocator argument already lets a caller place everything, in an arena
  for instance. One is added with a caller who needs it.
- **An element that is not finite is `.No_Convergence`, checked before the
  reduction.** The iteration cannot reduce a NaN, and an infinity on the
  diagonal would otherwise pass the rounding test with meaningless vectors.
- **`Svd` is the thin decomposition**, `U` `m x k` and `V` `n x k` for
  `k = min(m, n)`, which is what `solve` and `rank` need; a wide matrix is
  decomposed as its transpose. A full `U` waits for a caller.
- **`rank` and `solve` share one cutoff**: a singular value counts when it is
  greater than `relative` times the largest, so `relative = 0` keeps every
  value that is not zero, as NumPy's `rcond` does, and a zero matrix has
  rank 0.
- **Values-only forms**, cheaper because they skip the vectors, are a later
  addition with a caller. They would give the same values bit for bit, since
  the vectors never feed back into the values.

## Milestone 4 results

Done 2026-10-29. `bench/dense.loke` times each kernel, and its checksums, in
`bench/dense.expected`, are the same at both CPU levels, so `perf.ps1` checks
on every run that no result changed. `tests/run/lib_dense_kernels.loke`, in
the CPU-level corpus, checks the new paths against the plain kernels bit for
bit: products of every shape around the tile and block edges, with strided
operands and blocks of `out`; blocked LU and Cholesky around their panel
widths, and failing in a later panel; and products, LU, and Cholesky with a
pool. Every earlier `lib_dense` test gives the same output as before at every
optimization and CPU level tried, so no result changed.

What each kernel became:

- **Products** of `f32` and `f64` whose `a` and `out` have contiguous columns
  take a `Simd` kernel. It packs a panel of `2W` rows of `a` and groups of four
  columns of `b`, 256 terms at a time, and computes a `2W x 4` tile of `out` in
  eight `Simd(T, W)` accumulators, `W` being 4 for `f64` and 8 for `f32`.
  Each lane is one element of `out`, its terms added in increasing `k` and the
  blocks of terms visited in increasing order, so the bits are the scalar
  kernel's. Every other case, integer and dual-number elements and a strided
  `a`, keeps the scalar kernel.
- **LU** is right-looking and blocked, 64 columns to a panel, for `f32` and
  `f64` with contiguous columns and more than 64 rows. Each panel is
  eliminated unblocked, its swaps applied to the other columns, the rows of
  `U` to its right solved, and the trailing matrix updated through the product
  kernel, with the panel's multipliers packed negated: `x + (-l u)` is
  `x - l u` bit for bit, so each element still has its terms subtracted one at
  a time in increasing `k`. A row's multipliers move with it, so applying the
  swaps a panel late changes nothing.
- **Cholesky** is blocked, 32 columns to a panel, under the same conditions.
  Without a pool it is left-looking: each panel's elements first have every
  earlier column's terms subtracted through the product kernel, the diagonal
  block in a copy so that nothing above the diagonal is read or written, and
  then the panel is factored by columns. With a pool it is right-looking, the
  columns right of each panel updated as tasks. Both subtract each element's
  terms in increasing `k`, the unblocked order.
- **QR** stays unblocked. Each reflector is applied to the rest of its
  16-column panel, and then the panel's reflectors, in order, to the later
  columns, four at a time, so a column is read from memory once a panel rather
  than once a reflector. Each column's sum and update are the same operations
  as before. The bidiagonalization, `Q`'s application, and the forming of `Q`,
  `U`, and `V` apply reflectors four columns at a time the same way.
- **With a pool**, a product is halved by columns or by rows until each task
  has one to two million terms; LU's trailing update and Cholesky's
  right-looking update are halved by columns. Each task writes its own part of
  the output, each element in the same order, so the result is the same bits.
- `zeros`, `filled`, `from_view`, and the 1-norm and infinity norm read and
  write through raw pointers.

The best of several runs, in floating-point operations per nanosecond (the
usual counts: `2 n^3` for a product, `2 n^3 / 3` for LU, `n^3 / 3` for
Cholesky), at `-opt=speed` on the development machine, a six-core Intel
processor shared with other work while measuring. "Before" is the package of
milestone 3 under the same benchmark. OpenBLAS 0.3.33 through NumPy, on one
thread, uses its Haswell kernels, with fused multiply-adds, which Loke's
contract rules out ([Floating-point operators](design.md#floating-point-operators)),
and blocked WY QR.

| Operation | Size | `x86-64` before | `x86-64` after | `x86-64-v3` before | `x86-64-v3` after | OpenBLAS |
| --- | --- | --- | --- | --- | --- | --- |
| product | 64 | 9.8 | 13.1 | 14.4 | 26.3 | 35 |
| product | 256 | 9.1 | 13.6 | 14.1 | 28.7 | 59 |
| product | 512 | 8.6 | 13.5 | 15.2 | 27.5 | 56 |
| product | 1024 | 6.3 | 14.3 | 9.3 | 28.7 | 58 |
| product, `b` transposed | 1024 | | | 8.0 | 28.9 | |
| product, `f32` | 512 | 17.7 | 25.3 | 26.5 | 58.8 | 111 |
| `lu` | 256 | 4.6 | 9.0 | 5.1 | 12.7 | 23 |
| `lu` | 1024 | 5.8 | 10.8 | 7.0 | 18.9 | 39 |
| `cholesky` | 1024 | 6.5 | 11.1 | 8.6 | 19.9 | 20.6 |
| `qr` | 1024 x 512 | 3.6 | 8.5 | 3.9 | 10.2 | 27 |
| `symmetric_eigen` | 256 | 6.6 | 8.4 | 8.2 | 10.7 | 28.6 |
| `svd` | 512 x 256 | 3.8 | 7.2 | 3.9 | 8.0 | 37.2 |

A hand-written triple loop over slices, checked indexing, in the same order,
gives the same bits as the product at 1.5 to 2.3. The `x86-64-v3` product
kernel runs near the processor's peak without fused multiply-adds, about 32
to 36 operations a nanosecond, and half OpenBLAS's rate, which is the cost of
the separate multiply and add. With a pool of six workers:

| Operation | Size | `x86-64` | `x86-64-v3` | OpenBLAS, six threads |
| --- | --- | --- | --- | --- |
| product | 256 | | 74.7 | |
| product | 1024 | 69.6 | 137.1 | 222 |
| `lu` | 1024 | 29.5 | 39.1 | |
| `cholesky` | 1024 | 18.6 | 27.5 | |

Decided while measuring:

- **Cholesky without a pool is left-looking.** Right-looking, as with a pool,
  ran at 14.4 against 18.6 for left-looking at `n = 1024`: left-looking
  reads each earlier column once a panel and writes only the panel. With a
  pool the right-looking update is the one that splits into independent tasks.
- **The rotations of the eigensolver and the SVD stay one at a time.**
  Recording a sweep's rotations and applying them to the vectors in blocks of
  rows kept the bits and was 45 % slower: applied at once, each rotation's
  vector update overlaps the serial computation of the next.
- **No `qr_fast`.** The fused panels bring QR to 10 operations a nanosecond;
  the WY form would gain more, but with other bits, and a separate entry
  point waits for a caller who needs that speed with that contract.

Not done, for later milestones or callers:

- the tridiagonalization's symmetric product, which reads by rows and is now
  the eigensolver's largest cost;
- a pool for `qr`, `symmetric_eigen`, and `svd`, and on the one-call
  `solve`, `inverse`, and `least_squares`;
- products with a strided `a`, which keep the scalar kernel; packing makes a
  fast path possible but none of the factorizations needs one;
- small products, where packing `b` costs a few percent against the
  unpacked kernel.

## Milestone 5 results

Done 2026-10-29: `linalg.Scalar`, `View.adjoint`, and every factorization for
`math.Complex` elements, in [`core:math/linalg`](standard-library.md#coremathlinalg)
and [`core:math/dense`](standard-library.md#coremathdense). Settled the same
day: one conjugate-aware interface rather than a second implementation of each
algorithm for `math.Complex`; the interface in `core:math/linalg`, beside
`Real`; and the conjugate transpose as a view. Cholesky and the SVD take
complex elements too, since one generic implementation leaves no reason to
except them. `tests/run/lib_dense_complex.loke`, in the CPU-level corpus,
checks them, with the same output at every optimization and CPU level tried,
and every earlier `lib_dense` test gives the output it gave before, so no real
result changed.

- **A real matrix as complex** gives, through `lu`, `solve`, `cholesky`, `qr`,
  `symmetric_eigen`, and `svd`, the real factorization's bits in the real parts
  and zero imaginary parts, at `f32` and `f64` from 1 x 1 to 70 x 70: on zero
  imaginary parts every complex step is the real one, Smith's division
  included.
- **LAPACK's test ratios** for `P A - L U`, the solve and the inverse,
  `A - L L^H`, `A - Q R` and `Q^H Q - I` with the least-squares residual's
  `A^H r`, `A V - V D` and `V^H V - I`, and `A - U S V^H` with both
  orthonormality ratios, stay below 30 for random complex matrices from
  1 x 1 to 100 x 100 at `f64`, and to 33 x 33 at `f32`, tall and wide for the
  SVD. `R`'s diagonal, `L`'s, the eigenvalues, and the singular values are
  real, with the order and signs the contract gives.
- **What is not read**: NaN above the diagonal and an imaginary part on it
  change nothing in `cholesky` or `symmetric_eigen`.
- **The adjoint** reads the conjugate transpose, its adjoint is the view, and
  a copy, a block, a product, an element-wise operation, and a triangular
  solve through one equal the same on a conjugated copy bit for bit. A real
  adjoint is the transpose.
- **Planted bugs** are caught: an unconjugated sum in either reflector kernel,
  a reflector skipped for a complex `alpha`, an unconjugated element above the
  diagonal in the tridiagonalization or update in Cholesky, an unconjugated
  row reflector or `V` formed through the transpose in the SVD, the adjoint's
  flag ignored, and an eigenvector's leading component left inexact.

Decided while implementing:

- **`linalg.Scalar(T)`** requires `interfaces.Numeric(T)`, `==`, unary `-`,
  an associated type `T.Real` that is `linalg.Real`, a conversion `T(x)` from
  a `T.Real`, and the slots `conjugate`, `real_part`, and `imaginary_part`.
  Generic code recognises a real `T` as `T == T.Real` and keeps the real form
  of each step there, which is why no real result changed; for a complex one
  it conjugates where the complex algorithm does. A user real type, such as
  the tests' dual number, adds `Real`, `conjugate`, `real_part`, and
  `imaginary_part` to what `linalg.Real` asks, and `math.Complex` of it then
  works too.
- **`View.adjoint()`** sets a private flag that every kernel reading a view
  honours, and is the transpose for a real `T`, so the flag is never set on
  the real fast paths. `View_Mut` has no adjoint: a write through a conjugated
  view would have to conjugate on the way in, and nothing needs it.
- **`dot` conjugates nothing**, as its order was documented; `x^H y` is
  `dot(x.adjoint().transpose(), y)`. A conjugating `dot` is added with a caller
  who wants a name for it.
- **`Qr.apply_q_transpose_into` is now `apply_q_adjoint_into`**, since for a
  complex `T` it applies `Q^H`. The package has not been released, so the
  rename needs no upgrade note.
- **`symmetric_eigen` keeps its name** for a Hermitian matrix: a complex
  symmetric one, `A = A^T`, is not what it computes, and its documentation
  says it reads the lower triangle as Hermitian. `Symmetric_Eigen.values()`
  are `T.Real`.
- **A pivot's magnitude is `|re| + |im|`**, LAPACK's `cabs1`, which needs no
  square root and is `|x|` for a real element. The condition estimate follows
  `zlacn2`, whose signs are the units `x / |x|` and which does not test for
  repeated signs.
- **The reflectors are `zlarfg`'s**: `beta` is real, so `R`'s diagonal and the
  reduced tridiagonal and bidiagonal are real, and the real iterations of
  milestone 3 run on them unchanged, their rotations applied to complex
  vectors. A column whose part below the diagonal is zero still gets a
  reflector when its leading element is not real. The row reflectors of the
  SVD are built from the row as it stands and applied to the transpose's
  columns as `H^H`, which is the row-side `A G` for `G` its conjugate.
- **A complex vector's sign** is a unit: each eigenvector, and each column of
  `V` with its column of `U`, is multiplied by `conj(z) / |z|` for its first
  component `z` of largest modulus, which is then set to `|z|` exactly. For a
  real `T` that unit is `-1` or `1`, the negation milestone 3 applied.
- **`T.Real` in `core:math/dense`** is declared again for `f32`, `f64`, and
  `math.Complex`, privately, because a bound grants a package the slots of
  `linalg`'s private extensions but not their associated constant; and a
  `Real` slot on a complex `T`'s parts is reached through a helper bounded by
  `linalg.Real`. Both are open language questions
  ([Associated constants through a bound](open-questions.md#associated-constants-through-a-bound),
  [Slots through an associated type's bound](open-questions.md#slots-through-an-associated-types-bound)).

Complex elements use the scalar kernels. At `-opt=speed` on `x86-64-v3`,
counting real operations, a 256 x 256 complex product runs at about 8 a
nanosecond, against 28 for the real `Simd` kernel; `lu` at about 9, the
Hermitian eigensolver at 11, and a 512 x 256 SVD at 14. A complex `Simd`
kernel, its parts in separate lanes, is later work with a caller who needs
the speed; it would have to keep `math.Complex`'s order, `ac - bd` and
`ad + bc`, in each lane.
