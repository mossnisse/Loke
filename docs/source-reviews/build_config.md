# Source review of build_config.odin

Reviewed [build_config.odin](../../src/build_config.odin) at `ea622efe`. This file owns the build settings shared by the driver, checker, evaluator, and emitter. It also seeds the checked build constants and per-session overrides.

## Findings

- **P3 · Correctness, line 163.** `seed_defines` accepts reserved keywords as override names. A compiler built from the reviewed source accepts `-define:if=1` with exit 0, but `build_config(if, 0)` fails to parse the name. The override can silently have no effect. Reuse the lexer's reserved-word classification and report L0388 while seeding the override. A control with `build_config(where, 0)` and `-define:where=1` resolves to 1, so keep contextual words accepted. [Identifier grammar](../grammar.md#keywords) · [Lexer](../../src/lexer.odin) · [Built-in checker](../../src/check_builtin.odin)
- **P3 · Duplicate representation, lines 120–125.** `enum_const` creates a second integer for the value that `synth_enum` already stored on the selected member. Read that member's `const_value` by ordinal and keep `synth_enum` responsible for numbering and allocation. The callers already use ordinals to select from the synthesized member lists. [Enum synthesis](../../src/enums.odin)
- **P3 · Ownership, lines 85–92.** The optimization-to-Clang-flag table has one consumer, `append_codegen_flags`. Move it beside that consumer and give it file-private, read-only storage. Keep the optimization enum in the shared configuration for predeclaration and use by the driver. [Toolchain flag construction](../../src/emit_llvm_toolchain.odin)
- **Simplification, lines 171–180.** Combine the two boolean spellings into one switch case and use `bool_const(text == "true")`. The integer-first and string fallback paths can stay as written.

## Scope and verification

The three-entry enum-indexed CPU name table supports lookup in both directions with a bounded scan. The override map supports repeated exact-name lookup and duplicate detection, and the session owns the input strings for the map's lifetime. All configuration groups have live callers. No standalone dead code surfaced. [Session ownership](../../src/session.odin)

Built the compiler from the reviewed source and ran the reserved and contextual name probes with explicit bundled collection roots. Also confirmed that `-define:bad-name=1` reports L0388. [Build configuration guide](../compiler-guide.md#build-configuration)
