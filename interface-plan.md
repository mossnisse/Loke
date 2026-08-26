# Interface mechanics improvement plan

## Outcome

Make the constraint model simpler to explain, add an explicit place for a type
author to claim and validate conformance, and make every positive interface
check produce the same requirement-level diagnostic. Preserve structural
interface applications for static generic programming unless a later language
decision deliberately makes them nominal.

## What the compiler does today

- `src/parser.odin` parses expression, validity, and named `slot`
  requirements. A validity requirement succeeds when its expression type-checks;
  its value is not inspected.
- `src/interface.odin` turns `Interface(Type, ...)` into a constant `bool` and
  probes requirements through the ordinary expression checker. A bare interface
  application in an interface body is special-cased as composition and must be
  true.
- Interface arguments are currently resolved only as types, even though the
  generic argument representation already supports constant value arguments.
- `src/generic.odin` evaluates every `where` bound as a compile-time `bool` after
  generic arguments have been bound. Constraints filter overload viability and
  do not rank candidates.
- Satisfaction is checked on demand. There is no conformance declaration or
  conformance registry. A type declaration is therefore not an interface-check
  point.
- A failed bare interface bound and a failed `dyn` conversion report the
  concrete application and failed requirement. A direct
  `static_assert(Interface(Type))` currently reports only `static assertion
  failed`, and `static_assert` is not accepted as a file-scope item.
- `src/erased.odin` constructs witnesses lazily per
  `(Interface, Concrete, arguments)`. Slot selection is coherent: it uses
  inherent methods and extensions from the slot-owning interface's package,
  rather than caller-local extensions.

These observations were confirmed with focused compiler probes: `false;` is a
satisfied validity requirement; an interface value parameter such as `$N: int`
cannot currently be applied; and a direct failed interface `static_assert`
loses the per-requirement explanation.

## Proposed language changes

### 1. Keep one constraint model

Describe generic applicability as two operations:

1. Parameter specialization matches and destructures shape.
2. `where` evaluates compile-time Boolean predicates.

An interface application is a named predicate used by the second operation, not
a third constraint mechanism. Interface body entries remain well-formedness,
result, slot, and composition propositions; they are not reinterpreted as
Boolean expressions.

### 2. Add interface value predicates without overloading validity

Permit an interface declaration to carry its own `where` clause:

```odin
Sized_Additive :: interface($T: type, $N: int)
where N > 2 {
	Additive(T);
}
```

Applying the interface binds both type and constant value arguments, evaluates
the interface's `where` bounds, and then checks its body. This reuses the
existing truth-valued syntax and leaves `expr;` with its unambiguous
"well-formed" meaning.

### 3. Add an explicit checked conformance declaration

Add a file-scope declaration whose argument is a complete interface
application:

```odin
impl Circle {
	draw :: proc(self, canvas: inout Canvas) { ... }
}

implements Drawable(Circle);
```

The declaration:

- defines no methods and changes no lookup;
- is checked after the package's declarations and implementation signatures are
  installed, so source order and split `impl` blocks do not matter;
- succeeds only when the structural application is true;
- reports the exact missing or mismatched requirement at the `implements` line;
- serves as searchable documentation of the type author's intent.

Initially this should be a checked assertion rather than a nominal gate. Static
generic code may continue to use a structurally satisfying type without a
claim. That gives the desired early diagnostic without breaking built-in,
recursive aggregate, foreign-type, or local extension satisfaction.

Whether a claim should later be mandatory is a separate compatibility decision.
The smallest meaningful stricter rule is to require one before constructing a
user-defined `dyn Interface` witness. Fully nominal static satisfaction would
also require orphan/coherence rules, conditional claims for generic types, and
explicit compiler claims for every built-in family; it should not arrive as an
incidental consequence of adding the assertion syntax.

### 4. Unify positive-failure diagnostics

Create one semantic operation for "require this interface application":

- a bare interface bound in `where`;
- a direct `static_assert(Interface(args))`;
- an `implements Interface(args);` declaration;
- conversion to `dyn Interface`.

All four sites should call the same reporting path. Evaluating the application
as an ordinary Boolean must remain silent and yield `false`.

## Compiler work

### Phase 1: lock down and share diagnostics

- Add regression fixtures for false validity requirements, direct interface
  assertions, composed-interface failure, and wrong slot signatures.
- Refactor `report_failed_interface_bound` in `src/interface.odin` into a helper
  that recognizes and requires a bare interface application from any caller.
- Call it from `check_static_assert` in `src/check_expr.odin` before issuing the
  generic `L0387` failure.
- Preserve silent probing during overload candidate construction.

**Exit:** `where`, `static_assert`, and `dyn` name the same failed requirement,
while `flag := Interface(Type)` simply evaluates to false.

### Phase 2: type and value arguments plus interface `where`

- Add `where_clauses` to `Type_Interface` in `src/ast.odin`; update parsing,
  cloning, and AST dumping.
- Generalize `interface_arguments` and `composed_arguments` in
  `src/interface.odin` to resolve each argument against its declared parameter
  type. Reuse `Generic_Arg` and the existing constant freezing/key machinery.
- Evaluate the interface's own bounds in its substituted scratch scope before
  checking body requirements. Keep silent and reporting modes separate.
- Extend `dyn` argument formation, display names, and witness keys for constant
  non-subject arguments; the witness key code already represents value
  arguments.
- Update `grammar.md` and add syntax, run, error, package, and LLVM witness
  fixtures.

**Exit:** `Sized_Additive(int, 4)` succeeds,
`Sized_Additive(int, 2)` is false with a bound-specific diagnostic when
required, and distinct value arguments produce distinct stable witnesses where
the interface is dyn-compatible.

### Phase 3: explicit concrete conformance claims

- Reserve or contextually recognize `implements` at file scope.
- Add an `Item_Implements` AST node holding one complete interface application;
  update cloning/dumping only where top-level items require it.
- Register claims during package checking, but validate them after all relevant
  `impl` signatures and extensions have been installed.
- Reject a non-interface operand, an incomplete application, a runtime
  expression, and duplicate identical claims in one package with dedicated
  interface diagnostics.
- Do not add claims to ordinary member lookup or to static satisfaction.
- Add cross-file and cross-package tests proving source-order independence and
  preserving witness coherence.

**Exit:** the `Circle` example above succeeds, while a missing or incorrectly
typed `draw` fails at the `implements` declaration and points to the `slot`
requirement.

### Phase 4: conditional claims and the `dyn` policy

- Add generic conformance claims only after concrete claims are stable, using
  ordinary generic parameters and `where` bounds and instantiating the claim for
  concrete applications.
- Decide explicitly whether `dyn` witness construction requires a matching
  claim. If enabled, compiler-provided built-ins count as claimed, and a claim
  may be owned only by the subject type's package or the interface's package.
- Do not make static satisfaction nominal without a separate design change and
  migration plan.

**Exit:** generic container claims are checked per concrete instantiation, and
the chosen `dyn` rule has package-coherence and negative fixtures.

## Verification

Each phase should run:

```powershell
odin test src -define:ODIN_TEST_TRACK_MEMORY=false
odin build src -out:lokec.exe
odin test tests -define:ODIN_TEST_TRACK_MEMORY=false
```

Before merging the completed change, run `test-all.ps1` so the runtime/trap
corpus is also checked under every optimization level.
