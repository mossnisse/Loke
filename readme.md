Loke is a private project to make a new programming language building on Odin.

It aims to add more high level language functionality and more possibilities for abstractions with good ergonomics and still have the possibilities to have low level access and control of the binary output similar to Odin and C.

It aims at making it easier to handle memory allocations and complex datatypes as strings and dynamic arrays, not making the language 100% memory safe as Rust.

Loke should be able to use compiled C libraries (C ABI) and have some compatibility C datatypes

The language specification is in [design.md](design.md), and its grammar in [grammar.md](grammar.md). Its main sections define the implementable rules for the current language version. Possible later changes that are deliberately still open are collected at the end under "Open questions".
