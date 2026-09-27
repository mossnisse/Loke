# Loke tutorials

These pages teach Loke from a first program to a small program split into
packages. Read them in order: each one uses what the earlier ones explained.

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
6. [Generics and interfaces](06-generics-and-interfaces.md): code that works
   for many types.
7. [Packages](07-packages.md): a program in several packages, and what each
   one shows the others.
8. [A command-line tool](08-a-command-line-tool.md): arguments, files, and exit
   codes, put together in one program.
9. [Calling C](09-calling-c.md): foreign procedures from a C library.

The pages teach by example and leave the full rules to the language
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
