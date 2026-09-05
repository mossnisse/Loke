# Known gaps

Divergences between the specification documents and the shipped compiler, with
a minimal reproduction for each. A gap leaves this file when the compiler
accepts the program the spec describes — not when the spec is reworded to match
the compiler, unless the rewording is the intended fix.

Nothing here is checked by the test corpus: a test asserting today's behavior
would cement the wrong answer, and one asserting the right answer would be red.
Each entry carries its own repro instead, small enough to paste.

## Not gaps

Recorded because they look like gaps and are not, and each cost an
investigation once.

- **An exhaustive enum `switch` where every arm returns still needs a return
  after it** (`error[L0365]`). Correct: `design.md` "Exhaustive switch" makes
  exhaustiveness a check over declared members, not values, and conversion into
  an enum is unchecked — so a subject holding a non-member value matches no case
  and falls out of the bottom. A *variant* switch covering every variant is the
  case where no path reaches the end, and the compiler already accepts that one
  with no trailing return. The diagnostic now says this at the switch rather
  than at the signature, so it no longer reads as a missing feature.
- **Overlapping range cases are accepted.** Correct: cases are tried top to
  bottom and the first match wins (`design.md` "switch statement"). Only
  duplicate constant values are diagnosed.
