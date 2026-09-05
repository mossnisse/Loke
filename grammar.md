# Loke grammar

Formal grammar for the language specified in [design.md](design.md). This file
covers syntax only; semantics are described there.

## Notation

Productions use `=`. Terminals are quoted. `?` is optional, `*` is zero or
more, `+` is one or more, `|` is alternation, and `(...)` groups. A production
name in `Title_Case` refers to another rule. Anything else is prose commentary
after a `//`.

The grammar is written to be parsed top-down with a small fixed lookahead. Rules
needing more than one token of lookahead are marked and listed under
[Resolved ambiguities](#resolved-ambiguities).

# Lexical structure

## Source encoding

A source file is UTF-8 without a BOM. Files use the `.loke` extension. Outside
comments, string literals, character literals, and raw string literals, every
character must be ASCII.

## Whitespace and comments

Whitespace is space, tab, carriage return, and newline. It separates tokens and
is otherwise insignificant: there is **no automatic semicolon insertion** and no
layout rule. A newline is not a terminator.

```
Line_Comment  = "//" (any character except newline)*
Block_Comment = "/*" (Block_Comment | any character)* "*/"    // nests
```

A comment is whitespace.

## Identifiers

```
Identifier = ("A".."Z" | "a".."z" | "_") ("A".."Z" | "a".."z" | "0".."9" | "_")*
```

Identifiers are case-sensitive. `_` is the discard identifier: it may appear
wherever a name is bound but introduces no binding.

## Keywords

Reserved in every position:

```
break       case       continue   defer      distinct   dyn        dynamic
else        enum       for        foreach    foreign
hook        if         impl       import     in         inout      interface
map         move       move_only  mut        operator   or_else    or_return
package     proc       return     struct     switch     type       union
via         when       where
```

Contextual keywords, reserved only in the positions given:

| Word | Position |
| --- | --- |
| `static`, `thread_local` | in the storage-modifier position of a declaration, after its `:` |
| `self` | the first parameter name of a procedure declared in an `impl` block, or of an interface `slot` |
| `slot` | at the start of a named dispatch requirement in an `interface` body |
| `using` | before a promoted struct field |
| `delegate` | at the start of an operator-delegation declaration in an `impl` body |

`nil`, `true`, and `false` are predeclared identifiers, not keywords; they may be
shadowed by a declaration like any other name. So are the built-in procedures,
including `drop`, `len`, `cap`, `new`, and `make`.

## Compile-time names

There is no `#name` lexical form. The compile-time built-ins — `static_assert`,
`build_config`, `source_location`, and `caller_location` — are predeclared
identifiers reached through the ordinary call suffix, exactly like `size_of`
and `type_of`, and like those they may be shadowed by a declaration.

## Operators and punctuation

```
+    -    *    /    %    &    &~   |    ~    <<   >>
&&   ||   !    ==   !=   <    <=   >    >=
=    +=   -=   *=   /=   %=   |=   ~=   &=   &~=  <<=  >>=
:    ;    ,    .    ..   ..=  ..<  ->   ---  ?    $    ^    @
(    )    [    ]    {    }
```

The longest match wins, so `&~=` lexes as one token and `..=` never lexes as
`..` followed by `=`.

`::` and `:=` are **token pairs**, not tokens: `x :: 1` is `x` `:` `:` `1`, and
`x := 1` is `x` `:` `=` `1`. This is what makes `x: int = 1`, `x: = 1`, and
`x := 1` the same declaration.

## Literals

```
Digit          = "0".."9"
Octal_Digit    = "0".."7"
Hex_Digit      = Digit | "A".."F" | "a".."f"

Int_Literal    = Decimal | Binary | Octal | Hexadecimal
Decimal        = Digit (Digit | "_")*
Binary         = "0b" ("0" | "1" | "_")+
Octal          = "0o" ("0".."7" | "_")+
Hexadecimal    = "0x" (Hex_Digit | "_")+

Float_Literal  = Decimal "." Decimal Exponent?
               | Decimal Exponent
Exponent       = ("e" | "E") ("+" | "-")? Digit+
```

A leading `0` does not introduce an octal constant. An underscore may not be the
first character of a literal.

```
String_Literal     = '"' (String_Char | Escape)* '"'
Raw_String_Literal = "`" (any character except "`")* "`"
Rune_Literal       = "'" (Rune_Char | Escape) "'"

String_Char = any Unicode scalar except '"', "\\", carriage return, or newline
Rune_Char   = any Unicode scalar except "'", "\\", carriage return, or newline

Escape = "\\" ("a"|"b"|"e"|"f"|"n"|"r"|"t"|"v"|"\\"|'"'|"'")
       | "\\" Octal_Digit Octal_Digit Octal_Digit
       | "\\x" Hex_Digit Hex_Digit
       | "\\u" Hex_Digit Hex_Digit Hex_Digit Hex_Digit
       | "\\U" Hex_Digit Hex_Digit Hex_Digit Hex_Digit
                Hex_Digit Hex_Digit Hex_Digit Hex_Digit
```

A raw string literal contains no escapes and may span lines.

# Attributes

```
Attributes     = Attribute_Group+
Attribute_Group= "@" "(" Attribute ("," Attribute)* ")"
Attribute      = Identifier ("." Identifier)* ("=" Attribute_Value)?
Attribute_Value= Expression
```

The qualified form is an [extension attribute](design.md#extension-attributes),
e.g. `@(compiler.no_alias)`. Attributes attach to declarations, package
clauses, statements, blocks, parameters, record type literals, and foreign
blocks; which attribute is valid where is semantic, not grammatical.
`@(allocator_reset)` and `@(escape=<level>)` are part of procedure-type
compatibility — see [design.md](design.md#allocator_reset). `@(escape=...)`
needs no grammar of its own; its value is an ordinary identifier expression.

# Source files

```
Source_File   = Package_Clause Top_Level_Item*

Package_Clause= Attributes? "package" Identifier ";"

Top_Level_Item= Import_Decl
              | Foreign_Import_Decl
              | Foreign_Block
              | Impl_Block
              | Top_Level_When
              | Top_Level_Static_Assert
              | Declaration
              | ";"                       // empty item

Top_Level_Static_Assert = Attributes? "static_assert" "(" Argument_List ")" ";"

Top_Level_When = Attributes? "when" "(" Expression ")" Top_Level_Block
                 ("else" (Top_Level_When | Top_Level_Block))?
Top_Level_Block= Attributes? "{" Top_Level_Item* "}"
```

`static_assert` is not a keyword. It is matched contextually at item position,
by the identifier followed by `(`, and the semantic checker still resolves it as
the predeclared built-in with the same meaning it has as a statement. This is
the only expression admitted at item position; no other call or expression
statement may appear there. The `Attributes?` is grammatical only — no attribute
may appear on this item, and one written there is reported as misplaced.

```

Import_Decl   = Attributes? "import" Identifier? String_Literal ";"

Foreign_Import_Decl = Attributes? "foreign" "import" Identifier String_Literal ";"

Foreign_Block = Attributes? "foreign" Identifier "{" Foreign_Decl* "}"
Foreign_Decl  = Attributes? Identifier ":" ( ":" Proc_Literal | Type ) ";"
              | ";"

Impl_Block    = Attributes? "impl" Type "{" Impl_Member* "}"
Impl_Member   = Declaration | Delegate_Decl | ";"
Delegate_Decl = "delegate" "(" Operator_Symbol ("," Operator_Symbol)* ","? ")" ";"
```

Whether an `Impl_Block` is an inherent implementation or an extension is not
written — it follows from whether the subject type is declared by the
enclosing package, a semantic rule (see [design.md](design.md#methods-and-implementation-blocks)).

A procedure declared in a foreign block has no body and ends its signature with
`---`; see [Procedures](#procedures).

# Declarations

```
Declaration   = Variable_Decl | Constant_Decl

Variable_Decl = Attributes? Identifier_List ":" Declared_Type ("=" Variable_Initializer_List)? ";"
              | Attributes? Identifier_List ":" Storage_Modifiers "=" Expression_List ";"
                                                         // destructures when the
                                                         // name list has 2+ and
                                                         // the initializer list
                                                         // has exactly 1

Constant_Decl = Attributes? Identifier ":" Type? ":" Constant_Initializer

Identifier_List = Identifier ("," Identifier)*
Variable_Initializer_List = Variable_Initializer ("," Variable_Initializer)*
Variable_Initializer = Expression | "---"

Declared_Type = Storage_Modifiers Type ("via" Unary_Expression)?

Storage_Modifiers = Duration_Modifier?
Duration_Modifier = "static" | "thread_local"

Constant_Initializer = Braced_Constant_Value
                     | Semicolon_Constant_Value ";"

Braced_Constant_Value = Type_Definition
                      | Interface_Definition
                      | Proc_Definition
                      | Proc_Group
                      | Operator_Definition
                      | Hook_Definition

Semicolon_Constant_Value = Operator_Declaration
                         | Hook_Declaration
                         | Expression
```

`x: T;` declares a zero-initialized variable; `x: T = e;` / `x: = e;` add an
initializer; `x: T: e;` declares a constant. `x: T = ---;` uses the
uninitialized-storage marker, which is not an expression and so cannot appear
in inferred `x := ...` form. The second `Variable_Decl` alternative is
`x := e`, and also covers a storage modifier with an inferred type
(`x: static = 0;`, `counter: thread_local = 0;`); since `Storage_Modifiers` is
nullable, the two alternatives are distinguished by whether a `Type` follows,
and a modifier always precedes the alternative's single `=`, never a `:` `=`
pair.

Duration is the only modifier axis, and `static`/`thread_local` are mutually
exclusive; see [design.md](design.md#storage-modifiers) for what each means at
runtime. Suppressing cleanup is not a modifier: it is `unsafe.forget(value)`, a
property of the value rather than of the declaration.

File-scope, `static`, and `thread_local` declarations require constant
initializers, may not use `via`, and default omitted initializers to the zero
value — semantic restrictions, not separate productions.

A brace-bodied constant ends at its outer `}`; a following `;` is a separate
empty item. An expression constant always requires `;`, even when it ends in a
composite literal.

`via` takes a unary expression so that `b: [dynamic]u8 via arena.allocator() =
...;` parses without backtracking. Which types accept `via`, and what happens
when it's omitted, is semantic — see [design.md](design.md#storage-modifiers).

# Types

```
Type = "^" "mut"? Type                                   // pointer
     | "[" "^" "]" Type                                  // C pointer
     | "[" "]" "mut"? Type                               // slice
     | "[" "dynamic" "]" Type                            // dynamic array
     | "[" "?" "]" Type                                  // inferred-length array
     | "[" Expression "]" Type                           // fixed array
     | "map" "[" Type "]" Type
     | "distinct" Type
     | Move_Only_Struct_Type
     | "dyn" "mut"? Type_Name Type_Arguments?           // borrowed dynamic interface
     | "type"                                           // compile-time-only type of types
     | Proc_Type
     | Type_Definition
     | "$" Identifier (":" Type)?                        // specialization binding
     | Record_Type                                       // anonymous structural record
     | Type_Name Type_Arguments?

Record_Type    = "(" Record_Field ("," Record_Field)* ","? ")"
Record_Field   = Identifier_List ":" Type

Type_Name      = Identifier ("." Identifier)?            // optionally package-qualified
Type_Arguments = "(" Generic_Argument ("," Generic_Argument)* ")"
Generic_Argument = Type | Expression                     // type or compile-time value

Type_Definition = Struct_Type | Move_Only_Struct_Type | Enum_Type | Union_Type

Proc_Type = "proc" Calling_Convention? Signature
Calling_Convention = String_Literal                      // portable: "loke", "c", "stdcall"
```

`[?]T` is valid only as the type of a composite literal. `mut` is the
capability modifier, written on a slice, a pointer, a `dyn` view, or a unary
`&` (`[]mut T` vs. read-only `[]T`); see
[design.md](design.md#capabilities-and-the-one-rule) for what each carrier's
capability permits. `Type_Arguments` also carries specialization patterns, as
in `^Table($Key, $Value)`, because `$Name` is itself a `Type`. A value
parameter accepts any constant expression, so `Matrix(f32, 4)` is valid when
the second record parameter has type `int`. A bare identifier in a generic
argument is parsed as an unresolved name and classified as a type or value
during name resolution.

The single selector in `Type_Name` is classified during name resolution too. It
is either a package-qualified type such as `interfaces.Sequence` or an associated
type such as `S.Element` made available by an active interface constraint.
Associated-type selectors do not chain in version 1.

In `dyn Interface(arguments...)`, `Type_Name` must resolve to a dyn-compatible
interface. Its first generic parameter is the erased subject and is omitted from
`arguments`; all remaining interface parameters are supplied there. The explicit
conversion syntax uses the existing parenthesised-type expression,
`(dyn Interface)(&value)`.

## Records

```
Struct_Type = "struct" Generic_Parameters? Attributes? Where_Clause? "{" Field_List? "}"
Move_Only_Struct_Type = "move_only" Struct_Type
Field_List  = Field ("," Field)* ","?
Field       = Attributes? "using"? Member_Name_List ":" Type

Enum_Type   = "enum" Type? "{" Enum_Field_List? "}"
Enum_Field_List = Enum_Field ("," Enum_Field)* ","?
Enum_Field  = Member_Name ("=" Expression)?

// A member name is an identifier, plus the keyword `type`: a name in this
// position can never begin a type expression, and the reflection descriptors
// and the runtime metadata both spell one of their members `type`
// (`field.type`, `runtime.Member_Info.type`).
Member_Name_List = Member_Name ("," Member_Name)*
Member_Name = Identifier | "type"

Union_Type  = "union" Generic_Parameters? Attributes? Where_Clause? "{" Union_Variants? "}"
Union_Variants = Union_Variant ("," Union_Variant)* ","?
Union_Variant  = Identifier ":" Type?

Generic_Parameters = "(" Generic_Parameter ("," Generic_Parameter)* ")"
Generic_Parameter  = Generic_Name ("," Generic_Name)* ":" Type
Generic_Name       = "$" Identifier

Where_Clause    = "where" Expression ("," Expression)*
```

A `Where_Clause` expression must be a compile-time boolean over generic
parameters, constants, types, interfaces, and compile-time-evaluable
procedures — never runtime values; see [design.md](design.md#where-clauses).

A `Where_Clause` expression may not have a `Composite_Literal` at its top level;
see [Resolved ambiguities](#resolved-ambiguities).

A field named `_` is an unnamed padding field. A field type may itself be a
`Struct_Type`, which is how anonymous nested records are written.

## Interfaces

```
Interface_Definition = "interface" Generic_Parameters "{" Requirement* "}"

Requirement  = Bindings? Expression ("->" Requirement_Result)? ";"
             | "slot" Identifier ":" Proc_Type ";"

Requirement_Result = "inout"? Type
Bindings           = "(" Binding_Group ("," Binding_Group)* ")"
Binding_Group      = Identifier ("," Identifier)* ":" "inout"? Type
```

A requirement beginning with `(` starts a binding list when an identifier
followed by `,` or `:` comes next — a form no expression can start with;
otherwise wrap the expression in parentheses, as in `((a + b).c()) -> T;`.
`T.NAME -> U;` is an associated-constant requirement; when `U` is `type`, the
selected member becomes an associated type usable by later requirements.
`inout` in a binding or result denotes a hypothetical exclusive place, not a
general first-class reference type. `move` bindings are not part of
requirement lists.

`slot` is contextual only in this position. Its procedure type may not
introduce new generic parameters, and its first parameter must be the receiver
`self`; dyn compatibility adds further rules — see
[design.md](design.md#dyn-compatibility).

# Procedures

```
Proc_Header  = "proc" Calling_Convention? Signature Where_Clause?
Proc_Literal = Proc_Definition | Proc_Declaration
Proc_Definition = Proc_Header Block
Proc_Declaration= Proc_Header "---"

Proc_Group   = "proc" "{" Identifier ("," Identifier)* ","? "}"

Operator_Decl       = Operator_Definition | Operator_Declaration
Operator_Definition = "operator" "(" Operator_Symbol ")" (Proc_Definition | Proc_Group)
Operator_Declaration= "operator" "(" Operator_Symbol ")" Proc_Declaration

Hook_Decl        = Hook_Definition | Hook_Declaration
Hook_Definition  = "hook" "(" Hook_Role ")" Proc_Definition
Hook_Declaration = "hook" "(" Hook_Role ")" Proc_Declaration
Hook_Role        = "convert" | "copy" | "drop"

Operator_Symbol = "+" | "-" | "*" | "/" | "%"
                | "|" | "~" | "&" | "&~" | "<<" | ">>"
                | "==" | "!=" | "<" | "<=" | ">" | ">=" | "!"
                | "in"
                | "+=" | "-=" | "*=" | "/=" | "%="
                | "|=" | "~=" | "&=" | "&~=" | "<<=" | ">>="
                | "[" "]" | "[" "]" "=" | "[" ":" "]"

Signature    = "(" Parameter_List? ")" ("->" Results)?

Parameter_List = Parameter ("," Parameter)* ","?
Parameter    = Attributes? Parameter_Names
             | Attributes? Parameter_Names ":" Type ("=" Expression)?
             | Attributes? Parameter_Names ":" Parameter_Mode Type
             | Attributes? Parameter_Names ":" ".." Type
             | Attributes? Parameter_Names ":" "=" Expression
Parameter_Names = Parameter_Name ("," Parameter_Name)*
Parameter_Name  = "$"? (Identifier | "_")
Parameter_Mode  = "borrow" | "inout" | "move"

Results      = Result_Type                                // exactly one, or none
Result_Type  = "inout"? Type
```

A parameter with no type is legal only for the receiver `self` (typed from the
enclosing `impl` block or interface `slot`); a leading `self` therefore ends
`Parameter_Names` in `proc(self, allocator: Allocator)`, since it would
otherwise swallow the receiver. The receiver keeps an immutable borrow mode
regardless of the group's `Parameter_Mode`; one wanting another mode writes its
own type, as `self: inout Type`. `..T` is a variadic parameter; variadic,
`borrow`, `inout`, and `move` parameters cannot have defaults. `borrow` is
contextual in the parameter-mode position; it remains an ordinary identifier
elsewhere. A value parameter's
`= Expression` default may reference the receiver and parameters to its left
only — see [design.md](design.md#default-values) for when it's evaluated. A result
is anonymous: `Results` is one `Result_Type`, so there is no result name and no
result local, and `return` always carries its value. The `---` body marks a
foreign declaration.

`convert`, `copy`, and `drop` are contextual only inside `hook(...)`. A hook is
legal only as an inherent `impl` member; its role fixes the signature (see
[design.md](design.md#compiler-semantic-hooks)), not its declared name.

# Statements

```
Block     = Attributes? "{" Statement* "}"

Statement = Block
          | Declaration
          | If_Statement
          | For_Statement
          | Foreach_Statement
          | Switch_Statement
          | When_Statement
          | Defer_Statement
          | Return_Statement
          | Branch_Statement
          | Attributes? Simple_Statement ";"
          | ";"                                  // empty statement

Simple_Statement = Assignment | Expression_List

Init_Statement = Variable_Decl | Simple_Statement ";"   // supplies its own `;`

Assignment   = Expression_List "=" Expression_List       // destructures when
                                                         // the left has 2+ and
                                                         // the right has 1
             | Expression Compound_Operator Expression
Compound_Operator = "+=" | "-=" | "*=" | "/=" | "%="
                  | "|=" | "~=" | "&=" | "&~=" | "<<=" | ">>="

Expression_List = Expression ("," Expression)*
```

A statement built from a brace-bodied construct is not followed by `;`. A stray
`;` is an empty statement, which is what makes the trailing semicolon in
`Foo :: struct {};` legal.

## Control flow

Every control-flow header is parenthesised and every body is braced. There is no
single-statement body form.

```
If_Statement   = "if" "(" Init_Statement? Expression ")" Block
                 ("else" (If_Statement | Block))?

For_Statement  = "for" "(" For_Header ")" Block
For_Header     = (Init_Statement | ";") Expression? ";" Simple_Statement?
               | Expression

Foreach_Statement = "foreach" "(" Binding ("," Binding)* "in" Expression ")" Block
Binding         = "$"? "&"? (Identifier | "_")

When_Statement = Attributes? "when" "(" Expression ")" Block
                 ("else" (When_Statement | Block))?

Defer_Statement= "defer" Statement

Return_Statement = "return" Return_Value? ";"
Return_Value   = "inout"? Expression

Branch_Statement = ("break" | "continue") ";"
```

`for (;;)` is the three-part header with every part empty. `for (cond)` is the
condition-only form.

A binding list has any length: it names the fields of the element the iterable
yields, so the arity a header may use is a semantic property of that element's
type, not a syntactic limit.

A `foreach` whose bindings carry `$` is a static expansion over a compile-time
iterable; the two forms share one production so a mixed header parses and can
be diagnosed. Semantic restrictions (binding `$`-agreement, no `&` with `$`, no
`break`/`continue` across an expansion) are in
[design.md](design.md#static-foreach-expansion).

`Init_Statement` is what makes `for (i := 0; ...)`, `if (x := foo(); ...)`, and
`switch (arch := LOKE_ARCH; arch)` legal: an initial statement may be a variable
declaration, which already carries its own `;`, or an ordinary simple statement
followed by one.

`return inout expr` is legal only in a procedure whose corresponding result is
declared `inout`; see [Procedures](#procedures). Everywhere else a `Return_Value`
is an ordinary expression.

`Defer_Statement`'s body is narrowed semantically: no `return`, `or_return`, or
nested `defer`; `break`/`continue` may target only a loop or switch wholly
inside it. See [design.md](design.md#defer-statement).

## Switch

```
Switch_Statement = Value_Switch | Type_Switch

Value_Switch = Attributes? "switch" "(" Init_Statement? Expression ")"
               "{" Value_Case* "}"
Value_Case   = "case" Expression_List? ":" Statement*

Type_Switch  = Attributes? "switch" "(" Init_Statement? Binding_Name "in" Expression ")"
               "{" Type_Case* "}"
Binding_Name = Identifier | "_"
Type_Case    = "case" (Case_Selector ("," Case_Selector)*)? ":" Statement*
// A union case names variants; an `any_view` case names types. Which one a
// case list is read as follows from the subject's type, and a `.` at case
// position can never begin a type expression.
Case_Selector = ("." Identifier) | Type
```

`case` with no values is the default case. Case values may be ranges, since
`..=` and `..<` are ordinary binary operators in the expression grammar.

# Expressions

Levels are numbered as in [Operator precedence](design.md#operator-precedence);
level 1 binds loosest. Levels 3 through 7 associate left to right. Level 1
associates **right**, so that `a if c else b if d else e` groups as
`a if c else (b if d else e)`, matching the else-if chain it reads as. Level 2 is
**non-associative**: a range takes exactly two endpoints, so `a ..< b ..< c` is a
syntax error rather than a nested range.

`in` sits at level 5 with the comparisons because it produces a `bool`. At the
additive level `x in values + extra` would have grouped as
`(x in values) + extra`.

```
Expression   = Level_2 (("or_else" Expression) | ("if" Level_2 "else" Expression))?  // 1
Level_2      = Level_3 (("..=" | "..<") Level_3)?                               // 2
Level_3      = Level_4 ("||" Level_4)*                                          // 3
Level_4      = Level_5 ("&&" Level_5)*                                          // 4
Level_5      = Level_6 (("==" | "!=" | "<" | ">" | "<=" | ">=" | "in") Level_6)* // 5
Level_6      = Level_7 (("+" | "-" | "|" | "~") Level_7)*                       // 6
Level_7      = Unary_Expression
               (("*" | "/" | "%" | "&" | "&~" | "<<" | ">>") Unary_Expression)*  // 7

Unary_Expression = ("+" | "-" | "!" | "~" | "&" "mut"?) Unary_Expression
                 | Postfix_Expression

Postfix_Expression = Primary_Expression Suffix*
Suffix = "^"                                          // dereference
       | "." Member_Name                              // selector
       | "." "(" Type ")"                             // trapping checked extraction
       | "(" Argument_List? ")"                       // call or conversion
       | "[" Index_Or_Slice "]"
       | "or_return"

Index_Or_Slice = Expression ("," Expression)*          // index; comma form is user-defined
               | Expression? ":" Expression?           // slice
```

## Primary expressions

```
Primary_Expression =
       Int_Literal | Float_Literal | Rune_Literal
     | String_Literal | Raw_String_Literal
     | Identifier
     | "." Identifier                                  // implicit selector, .Member
     | "move" "(" Expression ")"
     | Composite_Literal
     | Proc_Literal
     | "(" Expression ")"
     | "(" Type ")"                                    // parenthesised type, as in (^u32)(&f)

Composite_Literal = Composite_Type? "{" Element_List? "}"
Composite_Type    = Type_Name Type_Arguments?
                  | "[" "]" "mut"? Type
                  | "[" "?" "]" Type
                  | "[" "dynamic" "]" Type
                  | "[" Expression "]" Type
                  | "map" "[" Type "]" Type

Element_List = Element ("," Element)* ","?
Element      = (Element_Key "=")? Expression
Element_Key  = Expression                              // field name, index, or index range

Argument_List = Argument ("," Argument)* ","?
Argument      = Identifier "=" Named_Argument_Value    // named argument
              | "inout" Expression                     // mutable-borrow argument
              | ".." Expression                        // variadic spread
              | Argument_Value
Named_Argument_Value = "inout" Expression | Argument_Value
Argument_Value= Expression | Type                       // runtime value or compile-time type
```

Where `Expression` and `Type` overlap, the parser records one unresolved
argument form and name resolution classifies it using the selected parameter.
Syntactically distinctive types such as `^T`, `[]T`, and `[dynamic]T` are
accepted directly as arguments. A type argument is legal only where the callee
expects a compile-time `type` parameter or is a compiler-defined built-in that
expects a type. An interface declaration is accepted as an argument only by
compiler-defined reflection operations.

An `Element_Key` is an ordinary expression; which kind of key it is depends on
the literal's type, so a bare identifier is a field name in a record literal and
an ordinary value expression everywhere else.

A `Composite_Literal` with no `Composite_Type` takes its type from context. It
may not begin an expression statement, because `{` at statement position starts
a block. A slice literal's type is the one written: `[]T{...}` is read-only and
`[]mut T{...}` has mutable elements.

An anonymous `Record_Type` is never a `Composite_Type`: a record value is built
from a contextually typed literal, or through an alias used as an ordinary
literal prefix. There is no inline `(field: T){...}` form.

A parenthesised group is a `Record_Type` only when its first field group is
labelled — the same bounded `Identifier_List ":"` scan a `Variable_Decl` uses.
`(T)` in expression position therefore stays a parenthesised expression, and
`Type_Name "(" Record_Field ...` is not a `Type_Arguments` list.

Right associativity is also what lets `or_else` chain: `a or_else b or_else c`
groups as `a or_else (b or_else c)`, giving each `or_else` an unresolved
[fallible expression](design.md#typed-fallibility) on its left — left
association would break type-checking. What shape that operand must have is in
[design.md](design.md#or_else-expression).

Variant construction has no suffix of its own either: `.name(payload)` is the
implicit-selector primary followed by the call suffix, and `U.name(payload)` is
the ordinary selector followed by one. Whether `.name` denotes a variant, an
enum member, or a member of an expected record type follows from the expected
type, not from the syntax.

The erased extraction `view.as(T)` is likewise written with the selector and
call suffixes above. Its receiver's type is what makes it the built-in — an
`any_view` — so a declared member named `as` on any other type is reached by
exactly the same syntax. `m.lookup_value(key)` is an ordinary member call in the
same way. No result count depends on the destination.

`move(x)` is a primary form rather than a call because `move` is a keyword — it
is also a [parameter mode](#procedures), so it has to be reserved anyway.
`drop`, `len`, `cap`, `new`, `make`, and the rest of the built-ins are ordinary
identifiers and use the call suffix. `make([dynamic]int)` and the `core:unsafe`
member call `unsafe.transmute(T, x)` pass types as arguments through
`Argument_Value`.

# Resolved ambiguities

The productions above use the following deterministic parsing rules:

- `switch (name in expression)` is a type switch, over a union's variants or an
  `any_view`'s types. A value switch over membership uses
  `switch ((name in expression))`.
- An `Init_Statement` is a `Variable_Decl` when the comma-separated list of names
  that opens it is followed by `:`, and a `Simple_Statement` otherwise. Deciding
  this means scanning a name list, which is the same bounded scan `Declaration`
  already performs at statement position.
- After the first `:` of a declaration, `static` and `thread_local` are storage
  modifiers only when followed by another modifier, by a type-start token, or by
  `=`. Otherwise they are ordinary type names.
- At the start of an `impl` member, `delegate` is the contextual
  keyword only when followed by `(`; otherwise it remains an ordinary identifier
  that may begin a declaration.
- `via` in a declaration consumes one unary expression. A larger allocator
  expression is parenthesised.
- A `Where_Clause` is followed immediately by the declaration's `{`, so an
  expression in the clause may not have a `Composite_Literal` at its top level.
  In `where Additive(T) {`, the brace opens the body; `Additive(T)` is a call or
  interface application and never the type of a literal `Additive(T){...}`. A
  bound that needs a composite literal parenthesises it. This is the only place
  in the grammar where an expression abuts a body brace without an enclosing
  pair of parentheses, which is why every `Control-flow header` is
  parenthesised.
- In an interface requirement, an opening `(` begins `Bindings`; an expression that
  itself begins with parentheses uses a second pair.
- At the start of an interface requirement, `slot` is the contextual keyword
  only when followed by an identifier, `:`, and `proc`; otherwise it is an
  ordinary identifier beginning an expression requirement.
- A bare identifier in a generic argument, or in parentheses by itself, is stored
  as an unresolved name. Name resolution classifies it as a type, constant, or
  value. Syntactically distinctive type forms such as `^T`, `[]T`, and `proc()`
  are parsed as types immediately. This avoids consulting a partially built
  symbol table and permits forward references.
- After `name : Type? :`, a type definition, procedure definition, procedure
  group, or brace-bodied operator definition is a `Braced_Constant_Value` and
  ends at its outer `}`. A following `;` is an empty item. Other constant
  expressions, including composite literals, use `Semicolon_Constant_Value` and
  require `;`.

These are parser decisions, not overload or type-checking rules. They require
only bounded token lookahead except for the normal task of finding a matching
delimiter.
