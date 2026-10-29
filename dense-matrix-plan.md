# Dense matrix library plan

Status: proposal, 2026-10-29. It is milestone 3 of the
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
	@(private) rows, columns: int,
	@(private) data: [dynamic]T,       // column-major, rows*columns elements
}

View :: struct($T: type) where interfaces.Numeric(T) {
	@(private) data: []T,
	@(private) rows, columns: int,
	@(private) row_stride, column_stride: int,
}

View_Mut :: struct($T: type) where interfaces.Numeric(T) {
	@(private) data: []mut T,
	@(private) rows, columns: int,
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
  index the shape and strides reach is inside `data`. The kernels can then index
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
slice. `split_columns_mut(k)` splits a column-major view, whose columns are
contiguous runs; `split_rows_mut(k)` splits a row-major one. A split across the
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
rational matrices work. The factorizations need `linalg.Real(T)`, the same
interface the fixed-size package uses, so a dual number differentiates through
`solve` as it does through `linalg.inverse`. Complex elements need a conjugate
for Hermitian products, which neither interface has; they are a later milestone
with an interface of their own ([Milestones](#milestones)).

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
	@(private) factors: Matrix(T),   // L below the diagonal (unit diagonal), U on and above
	@(private) pivots:  [dynamic]int,
	@(private) sign:    T,           // of the permutation, for the determinant
}
```

`lu(a, allocator)` returns `Result(Lu(T), Error)`, and the result has `solve`,
`solve_into`, `determinant`, `inverse`, and `reciprocal_condition`. The
in-place form `lu_in_place(a: View_Mut(T), pivots: []mut int) -> Status(Error)`
overwrites `a` with the factors as LAPACK's `getrf` does, for a caller who owns
the storage. Cholesky, QR, the symmetric eigendecomposition, and the SVD follow
the same pattern.

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
Right-looking blocked LU and Cholesky keep the unblocked order by the update
rule above. Blocked Householder QR in the compact WY form does not: it reorders
the reflector updates, so QR's first implementation is unblocked
([Questions to settle](#questions-to-settle)).

A foreign BLAS is faster still, and its results differ by machine, library,
and thread count. It belongs in a separate package that binds one, with that
contract stated, not behind a flag in this one.

Threads take a `^thread.Pool` ([Pools](standard-library.md#pools)) as an
optional argument to the operations that use one, run under a
[`parallel (pool)`](design.md#parallel-blocks) block, and split the output, so
a threaded result is bit-identical to a sequential one. They come with the
measured-performance milestone.

### Algorithms

| Operation | Method | Fails with |
| --- | --- | --- |
| `lu`, `solve` | Gaussian elimination, partial pivoting, the first largest magnitude on a tie | `Singular` |
| `cholesky` | the `L L^T` factor, by columns | `Not_Positive_Definite` |
| `qr`, `least_squares` | Householder reflectors, unblocked; full column rank assumed | `Singular` for an exact zero on `R`'s diagonal |
| `symmetric_eigen` | Householder tridiagonalization, then implicit QL with Wilkinson shifts | `No_Convergence` |
| `svd` | Golub-Kahan bidiagonalization, then implicit-shift QR (Golub-Reinsch) | `No_Convergence` |
| `reciprocal_condition` | Hager and Higham's 1-norm estimator on an `Lu` | |
| `norm_frobenius` | one pass with a running scale, so it does not overflow | |

The iterative methods test convergence by rounding rather than by a
tolerance, as EISPACK's `tql2` does: an off-diagonal element `e` is negligible
when `t + |e| == t` for the neighbouring diagonal magnitude `t`. That needs no
epsilon in `linalg.Real`, works for any element type, and is the same test at
every precision. Each has a fixed iteration limit per eigenvalue or singular
value, 30 as in EISPACK and LINPACK, and returns `No_Convergence` past it, which
for these methods is a bug report rather than an expected outcome. Jacobi
methods, slower and more accurate for small singular values, are a later
addition.

`least_squares` assumes full column rank. A rank-deficient problem needs a
rank decision, so its minimum-norm solution is `Svd.solve(b, relative)`, which
treats singular values below `relative * largest` as zero and has no default
for `relative`.

## Proposed API

Sketches in the [standard-library](standard-library.md) style; constraints,
receiver modes, and the `allocator := mem.default_allocator()` parameters are
omitted. "Real" means members bounded by `linalg.Real(T)`.

```text
Matrix(T), any Numeric T:
  zeros(rows, columns), identity(n), from_view(View), from_fixed(linalg.Matrix(T, R, C))
  from_column_major([]T, rows, columns), from_rows([][]T)     // copies
  rows(), columns(), [r, c] and [r, c]=, view(), view_mut(), to_fixed($R, $C)
  format                                       // by rows, as linalg

View(T) and View_Mut(T), any Numeric T:
  from_column_major(data, rows, columns, leading := rows)
  from_row_major(data, rows, columns, leading := columns)
  from_column(values) -> rows x 1
  rows(), columns(), [r, c] (and [r, c]= on View_Mut)
  block(row, column, rows, columns), transpose(), row(r), column(c)
  View_Mut: as_view(), fill(value), copy_from(View),
            split_columns_mut(k), split_rows_mut(k)   // panic for the interleaved direction

Operations, any Numeric T, each with an `_into` form:
  multiply(a, b), multiply_add_into(out, a, b), add(a, b), subtract(a, b),
  scale(a, s), transpose(a), dot(x, y), trace(a), equal(a, b)

Real:
  approx_equal(a, b, absolute, relative)       // linalg's rule, element-wise
  norm_frobenius(a), norm_one(a), norm_infinity(a)
  lu(a) -> Result(Lu(T), Error); lu_in_place(a, pivots) -> Status(Error)
    Lu: solve(b), solve_into(b), determinant(), inverse(), reciprocal_condition()
  cholesky(a) -> Result(Cholesky(T), Error)    // reads the lower triangle
    Cholesky: solve(b), solve_into(b), determinant(), lower()
  qr(a) -> Result(Qr(T), Error)                // rows >= columns
    Qr: least_squares(b), q(), r(), apply_q_into(b), apply_q_transpose_into(b)
  solve_lower_into(l, b, unit_diagonal), solve_upper_into(u, b)   // triangular
  solve(a, b), least_squares(a, b)             // factor, then solve, in one call
  symmetric_eigen(a) -> Result(Symmetric_Eigen(T), Error)
    values ascending; vectors as columns, each with its largest-magnitude
    component positive, the first on a tie
  svd(a) -> Result(Svd(T), Error)
    u, singular values descending, v, each pair signed as an eigenvector is by
    its column of v; solve(b, relative)
```

The sign conventions in `symmetric_eigen` and `svd` are part of the contract,
so that two runs, two machines, and two versions give the same vectors and not
merely the same subspaces.

## Milestones

1. **Storage, views, products, LU, and Cholesky.** `Matrix`, `View`,
   `View_Mut`, the splits, products and the element-wise operations,
   triangular solves, `lu`, `cholesky`, `solve`, `inverse`, `determinant`,
   `reciprocal_condition`, and the norms. Before it, a spike that runs one
   view, one product, and one `lu` against the borrow checker and measures the
   unchecked kernel.
2. **QR and least squares.** `qr`, `least_squares`, and the `Q` application
   forms.
3. **Eigenvalues and singular values.** `symmetric_eigen` and `svd`, with
   `Svd.solve`.
4. **Measured performance.** Benchmarks against hand-written loops and a
   reference BLAS for scale, then blocking, `Simd` kernels across outputs, and
   the optional pool, each kept only where it wins without changing a bit.
5. **Complex elements.** A conjugate-aware interface, Hermitian products,
   complex LU and QR, and the Hermitian eigensolver.

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
- **Element types**: `f32` and `f64` throughout, integers through the
  `Numeric` operations, and a dual number through `lu` and `solve`, whose
  derivative is checked against `-A^{-1} (dA) A^{-1} b` for a constant `b`.
- **Determinism**: results as bit patterns, the same at every optimization and
  [CPU level](compiler-guide.md#cpu-levels), with a pool and without.

## Questions to settle

Each has a recommendation; the sections above assume it.

1. **The package's name.** `core:math/dense` with `dense.Matrix(T)`,
   `dense.View(T)`, and `dense.lu`, beside `linalg.Matrix(T, R, C)`.
   Alternatives: `core:math/linalg/dense`, which says the relation but
   stutters as `dense.Dense` if the type keeps the old plan's name `Dense(T)`;
   and `core:math/matrix`, which reads as the home of every matrix.
   Recommended: `core:math/dense`.
2. **Copyable or move-only `Matrix(T)`.** Recommended: copyable, a clone as
   [Copying is a clone](#copying-is-a-clone) says.
3. **Operators on `Matrix(T)`.** Recommended: none
   ([Named procedures, not operators](#named-procedures-not-operators)).
   The alternative is `*` and `+` allocating from the default allocator, as
   NumPy and Eigen read, at the cost of hidden allocation.
4. **One error type or one per factorization.** Recommended: one
   `dense.Error`, so `or_return` chains across factorizations.
5. **`try_` forms for allocation failure.** Recommended: not in the first
   milestone; the `_into` forms are the non-allocating path.
6. **Unblocked QR.** Blocked QR in the WY form, LAPACK's choice, is faster on
   large matrices because its updates are matrix products, and it changes the
   bits. Recommended: unblocked only, keeping one
   result everywhere; a blocked `qr_fast` is decided with the benchmarks of
   milestone 4.
7. **SVD method.** Golub-Reinsch, recommended, is the standard and is fast.
   One-sided Jacobi is simpler and more accurate for tiny singular values, and
   several times slower. Recommended: Golub-Reinsch first, Jacobi later.
8. **Interop with fixed-size matrices.** `from_fixed` and `to_fixed` copy.
   A view of a `linalg.Matrix` without a copy needs its `[C][R]T` storage as
   a flat `[]T`, which the language has no safe spelling for
   ([Flat views of nested fixed arrays](open-questions.md#flat-views-of-nested-fixed-arrays)).
   Recommended: copies now, a view if the language adds the flattening.
