# `src/check.odin`

Reviewed at `ea622efe`. This file coordinates package declaration, signature, and body checks. It also implements declaration binding, signature normalization, and the rules shared by record-destructuring forms. The separation between package preparation and body checking is needed for import discovery and selected branches. The common parameter normalization and destructuring checks serve distinct syntax forms and should remain shared. [Checker](../../src/check.odin), [checker architecture](../compiler-architecture.md#one-annotated-ast)

## Findings

- **P2 · Correctness.** `enter_symbol_location` (lines 602–619) leaves `k.impl_type` untouched when an on-demand caller does not supply a subject. Within an `impl R`, a reference to a later package procedure can therefore check its signature with `R` as the implicit receiver. A body-local named procedure can inherit that same context because `append_signature_group` reads `k.impl_type` directly (lines 1285–1340). Both cases change the first parameter of `proc(self, x: int)` from `int` to `R`. Derive the signature's receiver from the procedure symbol's owner type, which is invalid for a plain declaration, and restore the definition's context on an on-demand visit. Route the eager member resolution in `resolve_group_members` (lines 781–783) through the definition-site entry point so those signatures use their own file and scope too. [Checker](../../src/check.odin), [type-position call resolution](../../src/check_types.odin), [implementation member symbols](../../src/impl.odin), [import cycles and declaration order](../design.md#import-cycles), [receiver forms](../design.md#receiver-forms)
- **P2 · Correctness.** `check_decl_value` (lines 1744–1756) calls `require_const` only when a symbol exists. Since the discard deliberately receives `INVALID_SYMBOL`, `_ :: seed;` accepts a mutable global as a constant initializer. Evaluate the constant independently of storing its value and alias metadata, which still require a symbol. Preserve the existing error guard for an initializer that did not check successfully. [Checker](../../src/check.odin), [identifiers](../design.md#identifiers), [constant declarations](../design.md#constant-declarations)
- **P2 · Correctness.** `bind_import_aliases` (lines 246–269) omits the reserved-name check used for other lexical declarations. `import true "core:fmt";` compiles and `true.println(...)` resolves `true` as the lexical package name. The exception for names reached through a selector covers `println` in this expression. Check the alias identifier before inserting it, for both explicit and path-derived aliases. [Checker](../../src/check.odin), [predeclared names](../design.md#predeclared-names), [import statement](../design.md#import-statement)
- **P2 · Correctness.** `flow_then` (lines 129–134) merges a statement's exits even when the preceding statements cannot fall through. A dead `break` following `panic` makes `check_for` treat a conditionless loop as able to exit. This produces L0710 for a valid diverging procedure. Merge only reachable loop exits while continuing to check every statement. Diagnose illegal transfers in `defer` at the branch and return sites using the existing defer context. This preserves the restrictions for unreachable statements and removes the only consumers of the propagated `returns` and `continues` flags. [Checker](../../src/check.odin), [loop and defer checking](../../src/check_stmt.odin), [diverging procedures](../design.md#diverging-procedures), [defer statement](../design.md#defer-statement)
- **P3 · Correctness.** `append_signature_group` stores a default for an explicit borrowing receiver (lines 1317–1347). `check_param_defaults` checks it as an ordinary pointer expression (lines 1380–1391), allowing a static method call to omit the receiver entirely. The default rule permits ordinary value parameters and compile-time parameters. Diagnose the default after receiver normalization identifies the borrowing mode. Preserve defaults on ordinary explicit pointer parameters and on value parameters following a split receiver. [Checker](../../src/check.odin), [receiver forms](../design.md#receiver-forms), [default values](../design.md#default-values)
- **P3 · Simplify.** The item and declaration visitors (lines 353–374) duplicate the file, scope, and active-item traversal. Keep the declaration visitor for phases that apply to declaration items and share its per-file location setup with the general visitor. A traversal using an explicit loop can also cover the `impl` collection in `prepare_package` (lines 200–220). Preserve the separate passes and their current ordering. [Checker](../../src/check.odin)
- **P3 · Algorithm.** Anonymous record labels, declaration parameter names, and procedure group member IDs use a linear duplicate search for every new name (lines 797, 908, and 1305). Generated declarations with many entries incur quadratic comparisons. The nominal field checker already uses a temporary set (lines 831–845). Use temporary sets for duplicate membership while retaining the existing ordered output slices. Hoist the group owner lookup above the member loop since symbols have stable addresses. [Checker](../../src/check.odin), [symbol storage](../../src/semantic.odin)
- **P3 · Simplify.** `resolve_proc_signature` reloads its symbol pointer after creating bindings (lines 1254–1255), citing symbol-store growth. `new_symbol` allocates each symbol separately and grows a slice of pointers. Remove that reload and its stale comment. `const_type_value` also reloads the same symbol by ID after declaration checking (lines 662–665) and can observe the updated value through the existing pointer. [Checker](../../src/check.odin), [symbol storage](../../src/semantic.odin)

## Verification

The compiler built at `ea622efe` reported L0352 for the following input under `-emit-ll`. Moving `F` before the `impl` emitted LLVM IR.

```loke
package main;

R :: struct { n: int }

impl R {
    m :: proc(a: F(0, 0)) -> int { return a; }
}

F :: proc(self, x: int) -> type { return int; }
main :: proc() { _ = R.m(3); }
```

The following independent `impl` also reported L0354 and L0352. Writing `f` as a procedure value with `:=` emitted LLVM IR because the literal path already clears the enclosing receiver context.

```loke
package main;

R :: struct { n: int }

impl R {
    m :: proc() {
        f :: proc(self, n: int) -> int { return self + n; }
        _ = f(1, 2);
    }
}

main :: proc() { R.m(); }
```

Three more independent inputs emitted LLVM IR. Each used `package main;`.

```loke
seed: int = 7;
_ :: seed;
main :: proc() {}
```

```loke
import true "core:fmt";
main :: proc() { true.println("example"); }
```

```loke
R :: struct { n: int }
value: R = {7};
impl R {
    read :: proc(self: ^R = &value) -> int { return self.n; }
}
main :: proc() { assert(R.read() == 7); }
```

An ordinary `proc(p: ^R = &value)` also emitted LLVM IR, as expected.

The following input reported L0710. Removing `break;` emitted LLVM IR.

```loke
package main;

never :: proc() -> ! {
    for (;;) {
        panic("stop");
        break;
    }
}

main :: proc() {}
```

The report's simplifications come from source inspection. The probes stopped at LLVM IR.
