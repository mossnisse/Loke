# `src/emit_llvm_debug.odin` review

Reviewed [`src/emit_llvm_debug.odin`](../../src/emit_llvm_debug.odin) at
`e1aab600`. The file translates source markers to LLVM debug metadata and
writes Natvis rules for storage the debugger cannot interpret by type alone.
The linear pass keeps location tracking out of instruction emitters. A stack
fits lexical scopes, and the file, type, and location caches avoid duplicating
metadata. Forward type IDs handle recursive types. Record fields and tagged
unions use shared compiler layout queries. Map expansion follows the runtime
header and uses its stored offsets for entries. [Backend responsibilities](../compiler-architecture.md#llvm-and-toolchain) ·
[Map table layout](../../runtime/container.c#L599)

## Findings

### A user type can capture the string-view Natvis rule [P2]

`debug_type_name` gives the first type with a spelling the unsuffixed name.
A legal local type called `string_view` can claim that name before the built-in
type. The PDB then names `record` as `string_view` and `original` as
`string_view$30` in the example below. The generated Natvis rule matches
`string_view` and reads `data` and `len`. It selects the record, which has only
`n`, and leaves the built-in view without a text rule. Use an internal name
for the built-in view as for `string$`, and match that name in Natvis.
[Type name allocation](../../src/emit_llvm_debug.odin#L353) ·
[Sequence types](../../src/emit_llvm_debug.odin#L475) ·
[Natvis selector](../../src/emit_llvm_debug.odin#L556) ·
[Predeclared names](../design.md#predeclared-names) ·
[Debug build options](../compiler-guide.md#common-options)

```loke
package main;
Builtin_View :: string_view;
stop :: proc() {}
main :: proc() {
    string_view :: struct { n: int }
    record := string_view{n = 7};
    original: Builtin_View = "message";
    stop();
    assert(record.n == original.len());
}
```

### Procedure-scoped static and TLS locals are absent from debug records [P3]

`emit_local_decl` skips bindings with storage modifiers, so it emits neither
a debug variable marker nor a local record for them. `emit_static_locals`
emits their global definitions without source-variable metadata. This hides
both bindings below from normal local inspection. With `-g -keep-temps`, the
IR contains mangled `.visits` and `.local_tls` globals and a local variable
record for `ordinary`. The PDB also contains `ordinary` and lacks source
variable records for the static and TLS bindings. Carry the source scope and
name through the static definition path, with a TLS-aware location for
`local_tls`. [Local declaration lowering](../../src/emit_llvm_stmt.odin#L255) ·
[Static definition pass](../../src/emit_llvm_runtime.odin#L247) ·
[Variable metadata](../../src/emit_llvm_debug.odin#L253) ·
[Storage modifiers](../design.md#storage-modifiers) ·
[Debug build options](../compiler-guide.md#common-options)

```loke
package main;
import "core:fmt";
stop :: proc() {}
main :: proc() {
    visits: static int = 5;
    local_tls: thread_local int = 6;
    ordinary := 7;
    visits += 2;
    local_tls += 3;
    stop();
    fmt.println(visits, local_tls, ordinary);
}
```

## Simplification and boundaries

- L274–280 `shrink:` Use `symbol.index` for a single guarded lookup in
  `p.symbol.param_symbols`. The signature checker records the flattened
  index, and the ID comparison excludes ordinary locals and bindings from
  other procedures. Keep the size check for CodeView's treatment of
  wider parameters. [Parameter detection](../../src/emit_llvm_debug.odin#L274) ·
  [Index assignment](../../src/check.odin#L1339)
- L142–144 and L254–255 `stdlib:` Use `strings.partition(text, " ")` for
  both marker payloads. The location marker needs exactly two fields, so
  this removes the allocated `strings.fields` slice. For variable markers
  the returned tail replaces the hand-written address slice.
  [Location marker parsing](../../src/emit_llvm_debug.odin#L141) ·
  [Variable marker parsing](../../src/emit_llvm_debug.odin#L253)
- L626–635 `delete:` Skip marker and metadata emission for witnesses with
  zero slots. Natvis already skips them because zero-sized tables can share
  an address. The debug global and retained typedef for each such table have
  no Natvis consumer. [Witness marker emission](../../src/emit_llvm_erased.odin#L89) ·
  [Witness filtering](../../src/emit_llvm_debug.odin#L645)
- L374 `delete:` Skip `debug_type_name` for checked pointers, C pointers,
  arrays, maps, and `dyn` types. The first three emit unnamed nodes, and the
  last two use generated type-ID names. Their unused names currently consume
  temporary text and entries in the name registry.
  [Type dispatch](../../src/emit_llvm_debug.odin#L365)

`net: -2 lines possible` from the parameter lookup, plus the removed
per-marker allocations and unused metadata.

## Verification

Built and ran focused `-g -keep-temps` probes with
`lokec 0.10.0 (v0.10.0-15-ge1aab600)`. Inspected the generated LLVM, Natvis,
and CodeView type and symbol records with `llvm-pdbutil`. Four existing
debug-emission unit tests passed with Odin's memory checks and vet flags.
The existing [debugger fixture](../../tests/debugger/values.loke) also built
and ran, with string, map, and `dyn` rules in its Natvis XML. The `cdbX64`
alias failed to launch and the SDK's default `cdb` executable was absent.
The Natvis match was checked against the emitted PDB and XML.
