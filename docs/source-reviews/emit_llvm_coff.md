# `src/emit_llvm_coff.odin` review

Reviewed [`src/emit_llvm_coff.odin`](../../src/emit_llvm_coff.odin) at
`e1aab600`. This file supplies the COFF data behind the compiler's pre-link
`L0755` warning. The scanner belongs on the link-input side of the backend.
It reads object and archive bytes, while the caller handles import paths,
diagnostics, and linker invocation. Mapping the input and walking its
headers keeps large archives out of the compiler's allocator. A four-bit set
and a scan of four known library names fit this fixed vocabulary. The
archive, ordinary object, and bigobj paths each have a distinct role and
share the same section and directive readers. [Link input collection](../../src/emit_llvm_toolchain.odin#L285)

## Findings

### Quoting a whole default-library option suppresses L0755 [P2]

The scanner tracks quotes to find argument boundaries, then checks the
first raw byte for `/` or `-`. It drops an option whose opening quote
precedes that prefix. A C object containing the following code linked
successfully, imported `VCRUNTIME140.dll` and the dynamic `malloc`, and drew
no warning. Removing the two escaped quotes from the pragma drew `L0755`
with the same imports. Interpret argument quoting before inspecting the
prefix and option name. Cover both whole-option and value-only quoting in the
directive test. [Directive scanner](../../src/emit_llvm_coff.odin#L134) ·
[Spelling tests](../../src/emit_llvm_coff_test.odin#L53) ·
[C runtime warning](../compiler-guide.md#c-runtime)

```c
#pragma comment(linker, "\"/DEFAULTLIB:msvcrt.lib\"")
__declspec(dllimport) void *malloc(unsigned long long size);
int used_answer(void) { return malloc(16) != 0; }
```

Compile this with `clang -c quoted.c -o quoted.obj`, then link the object
by path from Loke and call `used_answer` through a `proc "c" () -> i32`
declaration.

### Unused archive members cause a definite two-runtime warning [P3]

The scanner folds directives from every archive member into a single bit
set. An archive with a `/MT` member exporting `used_answer` and a `/MD`
member exporting `unused_allocate` drew `L0755` when Loke referenced only
`used_answer`. The resulting executable imported only `KERNEL32.dll`.
Referencing `unused_allocate`, which calls `malloc` through the DLL import,
made the dynamic runtime appear in the executable's imports. Preserve the
cheap pre-link scan and qualify the archive warning to say the executable
may pick up a second runtime if the linker selects those members. The
archive's contents cannot establish which members the linker selected.
[Archive scan](../../src/emit_llvm_coff.odin#L58) ·
[Warning wording](../../src/emit_llvm_toolchain.odin#L339) ·
[C runtime guide](../compiler-guide.md#c-runtime)

## Simplification

- L169–177 `stdlib:` Replace `read_u16_le` and `read_u32_le` with Odin's `core:encoding/endian` `unchecked_get_u16le` and `unchecked_get_u32le` on slices starting at the field offsets. The COFF header and section length checks already cover all of these loads, including unaligned fields. [Little-endian reads](../../src/emit_llvm_coff.odin#L169)

`net: -8 lines possible.`

## Verification

All three focused COFF unit tests passed. Reproduced both diagnostics with
`lokec 0.10.0 (v0.10.0-15-ge1aab600)` and LLVM 22.1.8. Used `llvm-readobj
--coff-directives` to inspect the quoted option and `--coff-imports` to
compare the resulting executables against the controls.
