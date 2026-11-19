# `src/doc_comments.odin` review

Reviewed [`src/doc_comments.odin`](../../src/doc_comments.odin) at `ea622efe`.

## Findings

### The syntax walk reports valid field comments as unattached [P2]

Lines 160–223 find documented members through selected AST edges. The
file-scope walk skips `Item_Static_Assert.call`. The type walk skips enum
member values, record and procedure `where` clauses, and expressions in
interface requirements. These are positions where a type can be written.
For example, this valid enum reports `L0260` on its anonymous record's field.

```loke
package main;
E :: enum { Count = size_of((
    /// A field in an enum value.
    n: int,
)) }
main :: proc() {}
```

Visit the missing syntax edges, including unselected `when` branches as
today. Keep marking the spans of only the documented item kinds. The
walker also omits all procedure bodies. Clarify whether the specification's
“wherever the type is written” includes a local type's fields since the same
section gives a comment inside a procedure body as an example of a warning.
Add regression cases for both documented fields in nested types and comments
above ineligible items. [Doc comments](../design.md#doc-comments) ·
[AST child traversal](../../src/ast.odin) ·
[Warning tests](../../tests/err/doc_comments.loke)

### Hover reads comments already diagnosed as unattached [P2]

Lines 9–26 determine attachment from adjacency alone. The warning walk at
lines 116–143 also checks whether the item can be documented, but keeps that
decision in a temporary array. `query_documentation` asks the adjacency
reader for any source-backed binding. A `///` immediately above a local
variable is diagnosed as unattached and still becomes that variable's hover
text. Reuse the syntax walk's eligible item spans for documentation lookup,
or give the query an eligibility predicate with the same source-level rules.
Exercise local bindings and valid fields together in a documentation query
regression. [Doc comments](../design.md#doc-comments) ·
[Documentation query](../../src/queries.odin)

## Simplification and compiler boundaries

- Lines 39–74 already own a mutable `written_lines` slice. Trim it, compute
  the shared margin, and adjust its entries in place. This removes the
  second scratch array and its repeated append operations. Keep the first
  line's separate indentation rule and nested comment text.
  [Doc comments](../design.md#doc-comments) ·
  [Markdown fixture](../../tests/doc/shapes.loke)
- Keep comment spans in `Source` and share the binary search at lines 77–90
  with `shown_text`, which also needs the first intersecting comment. The
  field walks need syntax, and `expr_children` deliberately stops at name
  binders. Compare the explicitly visited binder edges with `api_refs` when
  adding syntax, since the latter already visits several missed edges.
  [Source storage](../../src/source.odin) ·
  [API formatting and reference walk](../../src/doc.odin)

## Verification

Ran a source probe with `loke-source-review.exe -emit-ll` and observed
`L0260` for fields within an enum member value, a file-scope assertion, a
record constraint, and a procedure constraint. The procedure-local field
also emitted `L0260`. Sent a hover request to `loke-source-review-lsp.exe`
at `ea622efe` for a local variable with a comment above it. The response
included the comment and the same session published `L0260` on it. As a
control, hovering over the enclosing procedure showed its valid comment.
Checked the report's relative links and heading anchor.
`check-citations.ps1` and `bundle.ps1` passed.
