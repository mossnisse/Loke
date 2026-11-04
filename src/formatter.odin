// `-fmt`: canonical layout for Loke source.
//
// Changes whitespace only and refuses a file that does not parse; a result whose
// tokens differ is reported, not written (comments.md "Formatting").
package lokec

import "core:fmt"
import "core:os"
import "core:strings"

// Formats every `.loke` file of `input`.
format_files :: proc(c: ^Compiler, input: string, check: bool) -> int {
	return rewrite_files(c, input, check, format_source)
}

// Rewrites every `.loke` file of `input`, a file or a directory's direct files,
// in place; with `check`, only lists the ones that would change. The exit status
// is 1 when a file does not parse or, with `check`, would change.
rewrite_files :: proc(c: ^Compiler, input: string, check: bool, rewrite: proc(c: ^Compiler, file: u32) -> (string, bool)) -> int {
	status := 0
	for path in input_sources(c, input) {
		file, loaded := load_source(c, path)
		if !loaded {
			status = 1
			continue
		}
		rewritten, ok := rewrite(c, file)
		if !ok {
			status = 1
			continue
		}
		defer delete(rewritten)
		if rewritten == c.sources[file].text {
			continue
		}
		if check {
			fmt.println(path)
			status = 1
		} else if os.write_entire_file(path, transmute([]u8)rewritten) != nil {
			errorf(c, NO_SPAN, "L0401", "cannot write `%s`", path)
			status = 1
		}
	}
	return status
}

// An editor's unsaved `text` for `path`, laid out as `-fmt` would write the
// file; false, with `c`'s diagnostics saying why, where `-fmt` would refuse it.
format_text :: proc(c: ^Compiler, path, text: string) -> (formatted: string, ok: bool) {
	file := add_loaded_source(c, path, transmute([]u8)strings.clone(text)) or_return
	return format_source(c, file)
}

// The source of `file` laid out canonically. False, with `c`'s diagnostics saying
// why, where it refuses.
format_source :: proc(c: ^Compiler, file: u32) -> (string, bool) {
	errors := c.error_count
	tokens := lex(c, file)
	defer delete(tokens)
	ast := parse(c, file, tokens)
	destroy_ast(&ast)
	if c.error_count > errors {
		return "", false
	}
	text := c.sources[file].text
	formatted := layout(text, tokens, c.sources[file].comments[:])

	// The guarantee, checked rather than assumed: the same tokens, in order.
	// The parser retagged contextual keywords and keyword member names, so a
	// token is compared by its text; the same text lexes to the same kind.
	again := lex_text(formatted)
	defer delete(again)
	same := len(again) == len(tokens)
	for index := 0; same && index < len(tokens); index += 1 {
		a, b := tokens[index], again[index]
		same = text[a.lo:a.hi] == formatted[b.lo:b.hi]
	}
	if !same {
		errorf(c, Span{file = file}, "L0405", "internal formatter error: formatting would change this file's tokens")
		return "", false
	}
	return formatted, true
}

// The clause a line may be in the middle of: a comma leaves a `where` clause
// unfinished, and a `case` header ends at its colon.
@(private = "file")
Clause :: enum {
	None,
	Where,
	Case,
}

// An open bracket, and the indentation of what it encloses.
@(private = "file")
Open :: struct {
	kind:  Token_Kind,
	inner: int,
	line:  int,
	// `@(...)`, whose arguments keep their written spacing.
	attribute: bool,
	// The clause the bracket opened in, which goes on when it closes.
	clause: Clause,
}

@(private = "file")
Layout :: struct {
	out:        strings.Builder,
	text:       string,
	newline:    string,
	opens:      [dynamic]Open,
	line:       int,
	// The last token written, and the line it was on; the kind is .EOF before
	// the first.
	last:       Token,
	last_line:  int,
	// Recognizes the operator spelled `[]=`.
	before_last: Token_Kind,
	// The first token of the last line that had one.
	line_first: Token,
	// Whether `last` is a postfix `^` or `?`, which ends an operand, and
	// whether it is an operator used as binary rather than prefix, and written
	// tight (`written_tight`).
	postfix:     bool,
	last_binary: bool,
	last_tight:  bool,
	// Whether `last` ends a `case` header or an attribute, so that the next line
	// starts afresh.
	last_finishes: bool,
	// The clause open in the innermost bracket.
	clause:     Clause,
	// The tabs the current line started with, and whether it continues an
	// unfinished one.
	indent:     int,
	continued:  bool,
}

@(private = "file")
layout :: proc(text: string, tokens: []Token, comments: []Span) -> string {
	l := Layout {
		out     = strings.builder_make(),
		text    = text,
		newline = strings.contains(text, "\r\n") ? "\r\n" : "\n",
		opens   = make([dynamic]Open),
		last    = Token{kind = .EOF},
	}
	defer delete(l.opens)
	previous_hi: u32 = 0
	next_comment := 0
	for token in tokens {
		for next_comment < len(comments) && comments[next_comment].lo < token.lo {
			comment := comments[next_comment]
			next_comment += 1
			gap := text[previous_hi:comment.lo]
			if strings.builder_len(l.out) == 0 || break_line(&l, gap) {
				indent(&l, token, true)
			} else {
				// A trailing comment keeps its alignment, and at least a space
				// where spacing allows one.
				tight := l.last.kind == .Lparen || l.last.kind == .Lbracket || l.last_tight
				strings.write_string(&l.out, gap != "" || tight ? gap : " ")
			}
			strings.write_string(&l.out, strings.trim_right(text[comment.lo:comment.hi], " \t"))
			previous_hi = comment.hi
		}
		if token.kind == .EOF {
			break
		}
		gap := text[previous_hi:token.lo]
		switch {
		case strings.builder_len(l.out) == 0:
		case break_line(&l, gap):
			indent(&l, token, false)
		case previous_hi == l.last.hi:
			strings.write_string(&l.out, spacing(&l, token, gap))
		case:
			strings.write_string(&l.out, gap)
		}
		write_token(&l, token)
		previous_hi = token.hi
	}
	strings.write_string(&l.out, l.newline)
	return strings.to_string(l.out)
}

// Starts a new line when the gap held one, keeping at most one blank line.
@(private = "file")
break_line :: proc(l: ^Layout, gap: string) -> bool {
	breaks := strings.count(gap, "\n")
	if breaks == 0 {
		return false
	}
	for _ in 0 ..< min(breaks, 2) {
		strings.write_string(&l.out, l.newline)
	}
	l.line += 1
	l.continued = false
	return true
}

// Tabs for a line that starts with `first` (comments.md "Formatting").
@(private = "file")
indent :: proc(l: ^Layout, first: Token, comment: bool) {
	depth := 0
	top: Open
	if len(l.opens) > 0 {
		top = l.opens[len(l.opens) - 1]
		depth = top.inner
	}
	switch {
	case !comment && (first.kind == .Rparen || first.kind == .Rbracket || first.kind == .Rbrace):
		depth -= 1
	case (first.kind == .Case || first.kind == .Default) && top.kind == .Lbrace:
		depth -= 1
	case first.kind != .Lbrace && continues(l, top):
		depth += 1
		l.continued = true
	}
	l.indent = max(depth, 0)
	for _ in 0 ..< l.indent {
		strings.write_byte(&l.out, '\t')
	}
}

// Whether the last line with a token left its statement unfinished, outside
// any `(` or `[`, whose own indentation is enough. A comma ends a list item,
// except in a `where` clause.
@(private = "file")
continues :: proc(l: ^Layout, top: Open) -> bool {
	if l.last_finishes {
		return false
	}
	#partial switch l.last.kind {
	case .EOF, .Semicolon, .Lbrace, .Rbrace, .Lparen, .Lbracket:
		return false
	case .Comma:
		if l.clause != .Where {
			return false
		}
	}
	return len(l.opens) == 0 || top.kind == .Lbrace && top.line < l.last_line
}

@(private = "file")
write_token :: proc(l: ^Layout, token: Token) {
	if l.last_line != l.line || l.last.kind == .EOF {
		l.line_first = token
	}
	finishes := false
	#partial switch token.kind {
	case .Where:
		l.clause = .Where
	case .Case, .Default:
		l.clause = .Case
	case .Colon:
		if l.clause == .Case {
			finishes = true
			l.clause = .None
		}
	case .Semicolon:
		l.clause = .None
	case .Lparen, .Lbracket, .Lbrace:
		// Brackets opened together on one line indent their contents once, and
		// one opened on a continued line, such as a `where` clause's `{`, indents
		// from the line its statement began on.
		inner := l.indent + 1
		if l.continued && token.kind == .Lbrace {
			inner -= 1
		}
		if len(l.opens) > 0 && l.opens[len(l.opens) - 1].line == l.line {
			inner = l.opens[len(l.opens) - 1].inner
		}
		if token.kind == .Lbrace && len(l.opens) == 0 && flat_when(l, token) {
			inner = 0
		}
		// A `{` ends the `where` clause it follows.
		outer := token.kind == .Lbrace && l.clause == .Where ? Clause.None : l.clause
		append(&l.opens, Open{kind = token.kind, inner = inner, line = l.line, attribute = l.last.kind == .At, clause = outer})
		l.clause = .None
	case .Rparen, .Rbracket, .Rbrace:
		open := pop(&l.opens)
		finishes = open.attribute
		l.clause = open.clause
	}
	operand := ends_operand(l)
	l.postfix = (token.kind == .Caret || token.kind == .Question) && operand
	l.last_binary = used_as_binary(token.kind, operand)
	l.last_tight = l.last_binary && written_tight(l, token)
	strings.write_string(&l.out, l.text[token.lo:token.hi])
	l.before_last = l.last.kind
	l.last, l.last_line, l.last_finishes = token, l.line, finishes
}

// A file-scope `when` body, or its `else`, keeps its contents at column zero
// when the author wrote its first line there, as `core/`'s long platform
// blocks do.
@(private = "file")
flat_when :: proc(l: ^Layout, brace: Token) -> bool {
	if l.line_first.kind != .When && l.line_first.kind != .Rbrace {
		return false
	}
	at := int(brace.hi)
	for at < len(l.text) && strings.is_space(rune(l.text[at])) {
		at += 1
	}
	return at < len(l.text) && l.text[at - 1] == '\n'
}

// Whether the last token ends an operand, which makes a following `-`, `&`,
// or `^` binary or postfix rather than prefix.
@(private = "file")
ends_operand :: proc(l: ^Layout) -> bool {
	#partial switch l.last.kind {
	// A bare `or_return` ends one too (grammar.md "Expressions"): an operator
	// after it is binary or postfix.
	case .Ident, .Int, .Float, .String, .Raw_String, .Rune, .Rparen, .Rbracket, .Rbrace, .Uninit, .Or_Return:
		return true
	case .Caret, .Question:
		return l.postfix
	}
	return false
}

@(private = "file")
binary_operator :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Not:
		return false
	case .Range_Incl, .Range_Excl, .Arrow, .In, .Or_Else, .Via:
		return true
	}
	return kind >= .Plus && kind <= .Shr_Eq
}

// Whether an operator is binary here, given whether an operand comes before it.
@(private = "file")
used_as_binary :: proc(kind: Token_Kind, operand: bool) -> bool {
	return binary_operator(kind) && (operand || !maybe_prefix(kind))
}

// An arithmetic or bitwise operator the author wrote with no space on either
// side, as `core/` writes `a*b + c*d` by precedence. It stays tight; one with
// a space on either side gets one on both.
@(private = "file")
written_tight :: proc(l: ^Layout, token: Token) -> bool {
	return token.kind >= .Plus && token.kind <= .Shr &&
		!strings.is_space(rune(l.text[token.lo - 1])) && !strings.is_space(rune(l.text[token.hi]))
}

// Whether `kind` can begin the operand a prefix operator applies to; `-> !`
// before `---` or `{` is the diverging result, not a prefix.
@(private = "file")
starts_operand :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Ident, .Int, .Float, .String, .Raw_String, .Rune, .Lparen, .Lbracket, .Period,
	     .Proc, .Struct, .Union, .Map, .Dynamic, .Distinct, .Dyn, .Mut, .Move, .Inout:
		return true
	}
	return maybe_prefix(kind)
}

// Operators that are prefix when no operand precedes them.
@(private = "file")
maybe_prefix :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Minus, .Plus, .Not, .Tilde, .Amp, .Caret, .Question, .Range, .Dollar:
		return true
	}
	return false
}

// Control keywords that take a space before their `(`.
@(private = "file")
spaced_keyword :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .If, .For, .Foreach, .Switch, .When, .Return, .Case, .In, .Else, .Or_Else, .Via, .Where, .Defer, .Errdefer,
	     .Parallel:
		return true
	}
	return false
}

// The whitespace between the last token and `next` on one line. `written` is
// what the author put there; where no rule decides, it is kept.
@(private = "file")
spacing :: proc(l: ^Layout, next: Token, written: string) -> string {
	last := l.last.kind
	at_least_one := written != "" ? written : " "
	in_brackets := len(l.opens) > 0 && l.opens[len(l.opens) - 1].kind == .Lbracket
	operand := ends_operand(l)

	if len(l.opens) > 0 && l.opens[len(l.opens) - 1].attribute {
		return written
	}
	// `::` and `:=` are two tokens; nothing goes between them.
	if last == .Colon && (next.kind == .Colon || next.kind == .Assign) && written == "" {
		return ""
	}
	#partial switch next.kind {
	case .Rparen, .Semicolon:
		return last == .Semicolon ? written : "" // `for (; ok; )`, `for (i := 0; ; i += 1)`
	case .Comma, .Rbracket:
		return ""
	case .Rbrace, .Lbrace:
		return written // `Point{1, 2}`, `proc{a, b}`, and `if (x) {` alike
	case .Period:
		// `f() or_return .io`: a `.` after `or_return` begins its operand.
		return operand && last != .Or_Return ? "" : written
	case .Colon:
		after := l.text[next.hi:min(next.hi + 1, u32(len(l.text)))]
		if after == ":" || after == "=" {
			return at_least_one // `x :: 1`, `x := 1`
		}
		// `x: int`, and the typed constant `HEIGHT : int : 5` as written.
		return in_brackets ? "" : written
	case .Assign:
		if last == .Rbracket && l.before_last == .Lbracket && written == "" {
			return "" // the operator spelled `[]=`
		}
	case .Lparen, .Lbracket:
		// A string before `(` is a calling convention: `proc "c" (`.
		if spaced_keyword(last) || (next.kind == .Lparen && (last == .String || last == .Raw_String)) {
			return at_least_one
		}
		// `inout (^mut T)(p)^` prefixes a parenthesized operand; every other
		// keyword hugs its bracket: `proc(`, `move(x)`, `hook(drop)`, `map[K]V`.
		if last == .Inout || last == .Mut || last == .Distinct || last == .Or_Return {
			return written
		}
		// The contextual keywords of `storage: static [256]u8`.
		if last == .Ident {
			switch l.text[l.last.lo:l.last.hi] {
			case "static", "thread_local":
				return written
			}
		}
		if operand || any_keyword(last) && (next.kind == .Lparen || last == .Map) {
			return ""
		}
		if any_keyword(last) {
			return at_least_one // `impl []int`, `return [2]int{1, 2}`
		}
	case .Caret, .Question:
		if operand {
			return "" // postfix
		}
	}

	#partial switch last {
	case .Lparen, .Lbracket, .Period, .At, .Dollar:
		return ""
	case .Comma, .Semicolon:
		return at_least_one
	case .Colon:
		return in_brackets ? "" : at_least_one
	}
	if maybe_prefix(last) && !l.postfix && !l.last_binary && starts_operand(next.kind) {
		// A prefix operator binds to its operand, unless a written space keeps the
		// two from lexing as one token: `& &x` must not become `&&x`.
		merges := last == .Amp && (next.kind == .Amp || next.kind == .Tilde) || last == .Minus && next.kind == .Minus
		return merges && written != "" ? " " : ""
	}
	if used_as_binary(next.kind, operand) {
		return written_tight(l, next) ? "" : at_least_one
	}
	if l.last_tight {
		return ""
	}
	if binary_operator(last) || any_keyword(last) {
		return at_least_one
	}
	return written
}
