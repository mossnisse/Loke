# Compiler source review (2026-11-02)

A review of the source of `lokec` at commit `92cb0d18`, one file at a time.
Besides bugs it looked for simplifications, dead code, data structures and
algorithms that did not fit their purpose, near copies, structure and boundaries,
and comments that could be shortened. It is non-normative: nothing here changes
the specification.

**No findings remain.** Each was fixed, or on reading the code proved wrong or not
worth doing, and was then deleted from this report. The commits after `92cb0d18`
say which, with a "Not done" list for those declined, and the report's history has
the original findings. What is still open went to
[known-gaps.md](known-gaps.md) and [open-questions.md](open-questions.md).

## How the review was done

Each of the 106 non-test files in `src/` went to its own agent. The six files
over 4000 lines were reviewed in parts of about 3000 lines, which made 115
reviews. A separate agent then tried to refute each high and medium severity bug
by reading the callers and the specification and by running probe programs
against `lokec.exe`. A last agent read the code behind the findings that span files.

The review did not cover the `_test.odin` files, `lsp/`, `runtime/`, or the
bundled packages.

## Looked at and left alone

Near copies the review read and judged better kept apart:

- `aggregate_equal` and `aggregate_order` against `eval_compare`: one loop would need a reader callback over `Const_Value` and `Eval_Value`, no simpler than the copies.
- `eval_hash` against `emit_hash_value`: one computes and one emits, so they can only change together.
- `prints_through_method_walk` against `emit_format_body`: the layering rules out a shared form; the checker cannot call the emitter's walk.
- `synchronized_field_walk` and `type_requires_results_walk`: inline-only walks with no closures to share them; a visitor would be longer.
- `type_is_comparable_walk` and `type_is_hashable_walk`: each kind has its own rule, so `type_parts` would remove little.
- Region-content find-or-grow in the provenance and borrow analyses: differing equality tests, path truncation and allocators leave a shared form no simpler.
- `fmt.aprintf(..., allocator = c.semantic_allocator)`: a wrapper shortens the lines without removing any, and the checker's local failure blocks are better served by per-file helpers such as `requirement_failuref`.
