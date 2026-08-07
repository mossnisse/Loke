# Loke grammar

Formal grammar for the language specified in [design.md](design.md).

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

Identifiers are case-sensitive. The identifier `_` is the discard identifier: it
may appear wherever a name is bound but introduces no binding and cannot be
referenced.

## Keywords

Reserved in every position:

```
break      case       concept    context    continue   defer      distinct
dynamic    else       enum       extend     fallthrough for        foreach
foreign    if         impl       import     in         inout      map
move       mut        operator   or_else    or_return  package    proc
return     struct     switch     transmute  union      using      via
when       where
```

Contextual keywords, reserved only in the positions given:

| Word | Position |
| --- | --- |
| `stack`, `manual` | immediately after the `:` of a declaration, when followed by a type-start token |
| `self` | the first parameter name of a procedure declared in an `impl` or `extend` block |
| `const` | at the start of an associated-constant requirement in a `concept` body |

`nil`, `true`, and `false` are predeclared identifiers, not keywords; they may be
shadowed by a declaration like any other name.

## Compile-time names

```
Hash_Name = "#" Identifier
```

The complete set is `#assert`, `#panic`, `#config`, `#location`,
`#caller_location`, and `#simd`. An unrecognised `#name` is a lexical error.

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
for example `@(compiler.no_alias)`. Attributes attach to declarations, package
clauses, statements, blocks, parameters, record type literals, and foreign
blocks; which attribute is valid where is a semantic rule, not a grammatical one.
The base `@(allocator_reset)` parameter attribute is part of procedure-type
compatibility and carries the allocator-region invalidation effect described in
the language specification.

# Source files

```
Source_File   = Package_Clause Top_Level_Item*

Package_Clause= Attributes? "package" Identifier ";"

Top_Level_Item= Import_Decl
              | Foreign_Import_Decl
              | Foreign_Block
              | Impl_Block
              | Extend_Block
              | Top_Level_When
              | Declaration
              | ";"                       // empty item

Top_Level_When = Attributes? "when" "(" Expression ")" Top_Level_Block
                 ("else" (Top_Level_When | Top_Level_Block))?
Top_Level_Block= Attributes? "{" Top_Level_Item* "}"

Import_Decl   = Attributes? "import" Identifier? String_Literal ";"

Foreign_Import_Decl = Attributes? "foreign" "import" Identifier String_Literal ";"

Foreign_Block = Attributes? "foreign" Identifier "{" Foreign_Decl* "}"
Foreign_Decl  = Attributes? Identifier ":" ( ":" Proc_Literal | Type ) ";"
              | ";"

Impl_Block    = Attributes? "impl"   Type "{" (Declaration | ";")* "}"
Extend_Block  = Attributes? "extend" Type "{" (Declaration | ";")* "}"
```

A procedure declared in a foreign block has no body and ends its signature with
`---`; see [Procedures](#procedures).

# Declarations

```
Declaration   = Variable_Decl | Constant_Decl

Variable_Decl = Attributes? Identifier_List ":" Declared_Type ("=" Expression_List)? ";"
              | Attributes? Identifier_List ":" "=" Expression_List ";"

Constant_Decl = Attributes? Identifier ":" Type? ":" Constant_Initializer

Identifier_List = Identifier ("," Identifier)*

Declared_Type = Storage_Modifier? Type ("via" Unary_Expression)?
Storage_Modifier = "stack" | "manual"

Constant_Initializer = Braced_Constant_Value
                     | Semicolon_Constant_Value ";"

Braced_Constant_Value = Type_Definition
                      | Proc_Definition
                      | Proc_Group
                      | Operator_Definition

Semicolon_Constant_Value = Operator_Declaration
                         | Expression
```

`x: T;` declares a zero-initialized variable, `x: T = e;` and `x: = e;` add an
initializer, and `x: T: e;` declares a constant. The second `Variable_Decl`
alternative is the `x := e` spelling.

A brace-bodied constant is terminated by its outer closing `}`. A following
semicolon is parsed as a separate empty item. An expression constant always
requires `;`, including when its expression ends in a composite literal.

`via` selects the allocator for a managed value and takes a unary expression, so
`b: [dynamic]u8 via context.temp_allocator = ...;` parses without backtracking.

# Types

```
Type = "^" Type                                          // pointer
     | "[" "^" "]" Type                                  // multi-pointer
     | "[" "]" "mut"? Type                               // slice
     | "[" "dynamic" "]" Type                            // dynamic array
     | "[" "?" "]" Type                                  // inferred-length array
     | "[" Expression "]" Type                           // fixed array
     | "map" "[" Type "]" Type
     | "#simd" "[" Expression "]" Type
     | "distinct" Type
     | Proc_Type
     | Type_Definition
     | "$" Identifier (":" Type)?                        // polymorphic name
     | Type_Name Type_Arguments?

Type_Name      = Identifier ("." Identifier)?            // optionally package-qualified
Type_Arguments = "(" Generic_Argument ("," Generic_Argument)* ")"
Generic_Argument = Type | Expression                     // type or compile-time value

Type_Definition = Struct_Type | Enum_Type | Union_Type | Concept_Type

Proc_Type = "proc" Calling_Convention? Signature
Calling_Convention = String_Literal                      // "c", "contextless", "stdcall", ...
```

`[?]T` is valid only as the type of a composite literal. `[]mut T` is a slice
with mutable elements; `[]T` is read-only. `Type_Arguments` also carries
specialization patterns, as in `^Table($Key, $Value)`, because `$Name` is itself
a `Type`. A value parameter accepts any constant expression, so `Matrix(f32, 4)`
is valid when the second record parameter has type `int`. A bare identifier in a
generic argument is parsed as an unresolved name and classified as a type or
value during name resolution.

## Records

```
Struct_Type = "struct" Poly_Parameters? Attributes? Where_Clause? "{" Field_List? "}"
Field_List  = Field ("," Field)* ","?
Field       = Attributes? "using"? Identifier_List ":" Type Field_Tag?
Field_Tag   = String_Literal | Raw_String_Literal

Enum_Type   = "enum" Type? "{" Enum_Field_List? "}"
Enum_Field_List = Enum_Field ("," Enum_Field)* ","?
Enum_Field  = Identifier ("=" Expression)?

Union_Type  = "union" Poly_Parameters? Attributes? Where_Clause? "{" Union_Variants? "}"
Union_Variants = Type ("," Type)* ","?

Poly_Parameters = "(" Poly_Parameter ("," Poly_Parameter)* ")"
Poly_Parameter  = Poly_Name ("," Poly_Name)* ":" Type
Poly_Name       = "$"? Identifier

Where_Clause    = "where" Expression ("," Expression)*
```

A field named `_` is an unnamed padding field. A field type may itself be a
`Struct_Type`, which is how anonymous nested records are written.

## Concepts

```
Concept_Type = "concept" Poly_Parameters "{" Requirement* "}"

Requirement  = Bindings? Expression ("->" Type)? ";"
             | "const" Identifier "." Identifier ":" Type ";"

Bindings     = "(" Binding_Group ("," Binding_Group)* ")"
Binding_Group= Identifier ("," Identifier)* ":" Type
```

A requirement beginning with `(` always starts a binding list; wrap the
expression in a second pair of parentheses if a requirement must begin with a
parenthesised expression. In `const T.NAME: U;`, `T` must name one of the
concept's type parameters; the requirement asks for `NAME` in `T`'s `impl`.

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

Operator_Symbol = "+" | "-" | "*" | "/" | "%"
                | "|" | "~" | "&" | "&~" | "<<" | ">>"
                | "==" | "!=" | "<" | "<=" | ">" | ">=" | "!"
                | "in"
                | "+=" | "-=" | "*=" | "/=" | "%="
                | "|=" | "~=" | "&=" | "&~=" | "<<=" | ">>="
                | "[" "]" | "[" "]" "=" | "[" ":" "]"

Signature    = "(" Parameter_List? ")" ("->" Results)?

Parameter_List = Parameter ("," Parameter)* ","?
Parameter    = Attributes? Parameter_Names (":" Parameter_Type ("=" Expression)?)?
             | Attributes? Parameter_Names ":" "=" Expression
Parameter_Names = Parameter_Name ("," Parameter_Name)*
Parameter_Name  = "$"? (Identifier | "_")
Parameter_Type  = Parameter_Mode? ".."? Type
Parameter_Mode  = "inout" | "move"

Results      = Result_Type
             | "(" Result_Item ("," Result_Item)* ","? ")"
Result_Item  = Identifier_List ":" (Result_Type ("=" Expression)? | "=" Expression)
             | Result_Type
Result_Type  = "inout"? Type
```

A parameter with no type is legal only for the receiver `self`, whose type is
inferred from the enclosing `impl` or `extend` block. `..T` is a variadic
parameter. The `---` body marks a foreign declaration.

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
          | Context_Statement
          | Defer_Statement
          | Return_Statement
          | Branch_Statement
          | Simple_Statement ";"
          | ";"                                  // empty statement

Simple_Statement = Assignment | Expression_List

Assignment   = Expression_List "=" Expression_List
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
If_Statement   = "if" "(" (Simple_Statement ";")? Expression ")" Block
                 ("else" (If_Statement | Block))?

For_Statement  = "for" "(" For_Header ")" Block
For_Header     = Simple_Statement? ";" Expression? ";" Simple_Statement?
               | Expression

Foreach_Statement = "foreach" "(" Binding ("," Binding)? "in" Expression ")" Block
Binding        = "&"? (Identifier | "_")

When_Statement = Attributes? "when" "(" Expression ")" Block
                 ("else" (When_Statement | Block))?

Defer_Statement= "defer" Statement

Return_Statement = "return" Expression_List? ";"

Branch_Statement = ("break" | "continue" | "fallthrough") ";"
```

`for (;;)` is the three-part header with every part empty. `for (cond)` is the
condition-only form. `break` and `continue` take no operand and there are no
labels.

The unrestricted `Statement` in `Defer_Statement` is narrowed semantically:
deferred syntax may not contain `return`, `or_return`, or another `defer`.
`break`, `continue`, and `fallthrough` may target only a loop or switch wholly
inside that deferred statement. Nested procedure literals are checked as
independent procedures.

## Scoped context

```
Context_Statement = Attributes? "context" "(" Context_Header ")" Block

Context_Header = "using" Expression ("," Context_Override)* ","?
               | Context_Override ("," Context_Override)* ","?

Context_Override = Identifier "." Identifier "=" Expression
```

The `using` form installs a complete `Context` value and is required when a
foreign or contextless procedure has no incoming ambient context; it is not
permitted in an ordinary `loke` procedure. Without `using`, the statement
derives routing from the incoming context. In an override,
`package.field` uses an import name as a compile-time package selector; an
override may not target the current package. Override expressions are evaluated
in source order before the body becomes active. The current procedure continues
to see its unchanged effective view; the derived routing is observed when the
target package is called. The predeclared
`context` expression inside a procedure is an immutable package-effective view;
assigning, moving, mutably borrowing, or taking its address is a semantic error.

## Switch

```
Switch_Statement = Value_Switch | Type_Switch

Value_Switch = Attributes? "switch" "(" (Simple_Statement ";")? Expression ")"
               "{" Value_Case* "}"
Value_Case   = "case" Expression_List? ":" Statement*

Type_Switch  = Attributes? "switch" "(" (Simple_Statement ";")? Binding_Name "in" Expression ")"
               "{" Type_Case* "}"
Binding_Name = Identifier | "_"
Type_Case    = "case" (Type ("," Type)*)? ":" Statement*
```

`case` with no values is the default case. Case values may be ranges, since
`..=` and `..<` are ordinary binary operators in the expression grammar.

# Expressions

Levels are numbered as in [Operator precedence](design.md#operator-precedence);
level 1 binds loosest. Every binary level associates left to right.

```
Expression   = Level_2 (("or_else" Level_2) | ("if" Level_2 "else" Level_2))*   // 1
Level_2      = Level_3 (("..=" | "..<") Level_3)*                               // 2
Level_3      = Level_4 ("||" Level_4)*                                          // 3
Level_4      = Level_5 ("&&" Level_5)*                                          // 4
Level_5      = Level_6 (("==" | "!=" | "<" | ">" | "<=" | ">=") Level_6)*        // 5
Level_6      = Level_7 (("+" | "-" | "|" | "~" | "in") Level_7)*                 // 6
Level_7      = Unary_Expression
               (("*" | "/" | "%" | "&" | "&~" | "<<" | ">>") Unary_Expression)*  // 7

Unary_Expression = ("+" | "-" | "!" | "~" | "&") Unary_Expression
                 | Postfix_Expression

Postfix_Expression = Primary_Expression Suffix*
Suffix = "^"                                          // dereference
       | "." Identifier                               // selector
       | "." "(" Type ")"                             // type assertion
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
     | "context"
     | "---"
     | "move" "(" Expression ")"
     | "transmute" "(" Type ")" Unary_Expression
     | Composite_Literal
     | Proc_Literal
     | Hash_Name
     | "(" Expression ")"
     | "(" Type ")"                                    // parenthesised type, as in (^u32)(&f)

Composite_Literal = Composite_Type? "{" Element_List? "}"
Composite_Type    = Type_Name Type_Arguments?
                  | "[" "]" Type
                  | "[" "?" "]" Type
                  | "[" "dynamic" "]" Type
                  | "[" Expression "]" Type
                  | "map" "[" Type "]" Type
                  | "#simd" "[" Expression "]" Type

Element_List = Element ("," Element)* ","?
Element      = (Element_Key "=")? Expression
Element_Key  = Identifier | Expression                 // field name, index, or index range

Argument_List = Argument ("," Argument)* ","?
Argument      = Identifier "=" Expression              // named argument
              | "inout" Expression                     // mutable-borrow argument
              | "via" Expression                       // allocator argument
              | ".." Expression                        // variadic spread
              | Expression
```

A `Composite_Literal` with no `Composite_Type` takes its type from context. It
may not begin an expression statement, because `{` at statement position starts
a block.

`move(x)` and `transmute(T)x` are primary forms rather than calls because `move`
and `transmute` are keywords. `drop`, `len`, `cap`, `new`, `make`, and the rest
of the built-ins are ordinary identifiers and use the call suffix.

# Resolved ambiguities

The productions above use the following deterministic parsing rules:

- `switch (name in expression)` is a type switch. A value switch over membership
  uses `switch ((name in expression))`.
- After the first `:` of a declaration, `stack` and `manual` are storage modifiers
  only when followed by a type-start token. Otherwise they are ordinary names.
- `via` in a declaration consumes one unary expression. A larger allocator
  expression is parenthesised.
- In a concept requirement, an opening `(` begins `Bindings`; an expression that
  itself begins with parentheses uses a second pair.
- At statement position, `context (` begins `Context_Statement`; the predeclared
  context view is not callable. `context.field` remains an ordinary primary
  expression followed by a selector.
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
