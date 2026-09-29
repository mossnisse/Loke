# Loke tutorials

These pages assume you have programmed in another language and know variables,
loops, and functions. They focus on Loke's syntax and semantics, from a first
program to a small program split into packages, then explicit memory management
and compile-time programming. The first seven pages form the core route to a
working tool. The later pages build on that foundation.

## Build a useful program

1. [Getting started](01-getting-started.md): install the compiler, then write,
   build, and run a first program.
2. [Values and control flow](02-values-and-control-flow.md): variables, types,
   procedures, loops, and decisions.
3. [Records, enums, and unions](03-records-enums-unions.md): your own types,
   with methods and operators.
4. [Strings and containers](04-strings-and-containers.md): text, arrays, maps,
   and who owns what.
5. [Errors](05-errors.md): `Option`, `Result`, `or_return`, `or_else`, and
   panics.
6. [Packages](06-packages.md): a program in several packages, and what each
   one shows the others.
7. [A command-line tool](07-a-command-line-tool.md): arguments, files, and exit
   codes, put together in one program.

## Understand storage and compile-time code

8. [Borrowing and lifetimes](08-borrowing-and-lifetimes.md): choose parameter
   forms, return views, and understand overlapping borrows.
9. [Compile-time programming](09-compile-time.md): ordinary procedures evaluated
   by the compiler, tables, `static_assert`, `when`, and build configuration.
10. [Generics and interfaces](10-generics-and-interfaces.md): reusable code,
    structural requirements, and dynamic dispatch.
11. [Choosing an allocator](11-allocators.md): `via`, arena and scratch storage,
    reset lifetimes, and recoverable allocation failure.
12. [Owning resources](12-owning-resources.md): explicit allocation, move-only
    types, cleanup hooks, and fallible close operations.

## Extend and integrate

13. [Calling C](13-calling-c.md): foreign procedures, callbacks, and linking.
14. [Allocator providers](14-allocator-providers.md): select a bounded default
    provider and understand its lifetime and implementation contract.
15. [Reflection and formatting](15-reflection-and-formatting.md): static field
    and enum expansion, then a custom printed representation.

Each lesson introduces a concrete use, shows a complete program and its output,
and explains the rules that make it work. Rejected examples show the limits.

The pages leave the full rules to the language
specification, [design.md](../design.md), which they link to section by
section. The library is described in
[standard-library.md](../standard-library.md).

## How the examples are checked

Every program on these pages is compiled and run by the test suite exactly as
printed, and its output is compared with the output the page shows. Where a
page shows a program the compiler rejects, the test checks that it is rejected
with that message. An example that stops working fails the build, so none can
quietly go out of date.

The commands use PowerShell on Windows, which is the platform the compiler
supports today.
