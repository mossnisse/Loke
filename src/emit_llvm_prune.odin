// Dropping the definitions nothing reaches, from the finished module's text.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:strings"

// A function or a global the module defines: `module[lo:hi]`, which is whole
// lines, from the comment lines directly above it through the blank lines below.
@(private = "file")
Definition :: struct {
	lo, hi:  int,
	reached: bool,
}

// `module` without the functions and globals that nothing reaches from one a
// linker can see, which is every one not `internal` or `private`. What stays keeps
// its text and order. Every package's every procedure is written, and a program
// calls few of them, so most of a module is code clang would compile only to
// have the linker drop it.
//
// This reads the text alone, so no part of the emitter says what it refers to: a
// witness table keeps its thunks, and a thunk its target, because their names
// appear. It reads the module before `attach_debug_info` does, so a dropped
// definition's markers go with it.
@(private)
prune_unreachable :: proc(module: string) -> string {
	definitions := make([dynamic]Definition, 0, 1024)
	by_name := make(map[string]int, 1024)
	work := make([dynamic]int, 0, 64)
	// Where the comment lines directly above the line at `at` begin.
	lead := 0
	for at := 0; at < len(module); {
		line := line_at(module, at)
		function := strings.has_prefix(line, "define ")
		if !function && !strings.has_prefix(line, "@") {
			at += len(line)
			if !strings.has_prefix(line, ";") {
				lead = at
			}
			continue
		}
		// `define <linkage> <type> @<name>(`, or `@<name> = <linkage> `.
		name, after, _ := next_global_name(line, 0)
		linkage := function ? line[len("define "):] : strings.trim_prefix(line[after:], " = ")
		at += len(line)
		// A function whose first line opens its body ends at the `}` that opens
		// a line.
		for body := function && strings.has_suffix(line, "{\n"); body && at < len(module); {
			line = line_at(module, at)
			at += len(line)
			body = !strings.has_prefix(line, "}")
		}
		for at < len(module) && module[at] == '\n' {
			at += 1
		}
		root := !strings.has_prefix(linkage, "internal ") && !strings.has_prefix(linkage, "private ")
		if root {
			append(&work, len(definitions))
		}
		by_name[name] = len(definitions)
		append(&definitions, Definition{lo = lead, hi = at, reached = root})
		lead = at
	}

	for len(work) > 0 {
		reached := definitions[pop(&work)]
		text := module[reached.lo:reached.hi]
		for at := 0; at < len(text); {
			name, after, _ := next_global_name(text, at)
			at = after
			if index, defined := by_name[name]; defined && !definitions[index].reached {
				definitions[index].reached = true
				append(&work, index)
			}
		}
	}

	out := strings.builder_make(0, len(module))
	kept := 0
	for definition in definitions {
		if !definition.reached {
			strings.write_string(&out, module[kept:definition.lo])
			kept = definition.hi
		}
	}
	if kept == 0 {
		return module
	}
	strings.write_string(&out, module[kept:])
	return strings.to_string(out)
}

// The line of `text` that starts at `at`, with its line break.
@(private = "file")
line_at :: proc(text: string, at: int) -> string {
	length := strings.index_byte(text[at:], '\n')
	return length < 0 ? text[at:] : text[at:at + length + 1]
}

// The first `@name` of `text` at or after `from`, as LLVM reads it, which is
// without the quotes a name may be written in, and where the text after it
// begins. A quoted string is skipped: its bytes name nothing, and one ending in
// `@` would otherwise read as the start of a quoted name.
@(private = "file")
next_global_name :: proc(text: string, from: int) -> (name: string, after: int, found: bool) {
	for at := from; at < len(text); at += 1 {
		switch text[at] {
		case '"':
			at = closing_quote(text, at)
		case '@':
			lo := at + 1
			if lo < len(text) && text[lo] == '"' {
				hi := closing_quote(text, lo)
				return text[lo + 1:hi], min(hi + 1, len(text)), true
			}
			hi := lo
			for hi < len(text) && global_name_byte(text[hi]) {
				hi += 1
			}
			return text[lo:hi], hi, true
		}
	}
	return "", len(text), false
}

// The quote that closes the one at `open`. LLVM writes a quote inside a string
// as `\22`, so the next one closes it.
@(private = "file")
closing_quote :: proc(text: string, open: int) -> int {
	length := strings.index_byte(text[open + 1:], '"')
	return length < 0 ? len(text) : open + 1 + length
}

// A byte of a name LLVM reads without quotes.
@(private = "file")
global_name_byte :: proc(ch: u8) -> bool {
	switch ch {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '.', '$', '-':
		return true
	}
	return false
}
