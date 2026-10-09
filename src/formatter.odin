// `-fmt`: canonical layout for Loke source.
//
// The formatter changes whitespace only. It keeps every token and comment in
// order, keeps the author's line breaks (collapsing blank-line runs to one),
// and decides indentation from nesting and the spacing between neighbouring
// tokens on a line. Spaces beyond the one a rule requires are kept, since
// `core/` aligns columns with them. A file that does not parse is refused, and
// a result whose tokens differ from the input's is a bug the formatter reports
// rather than writes (comments.md "Formatting").
package lokec

import "core:fmt"
import "core:os"
import "core:strings"

// Formats every `.loke` file of `input`, a file or a directory's direct
// files, in place; with `check`, only lists the ones that would change. The
// exit status is 1 when a file does not parse or, with `check`, would change.
format_files :: proc(c: ^Compiler, input: string, check: bool) -> int {
	// Listed as a package's sources are, never as a pattern, so a directory
	// name holding `[` or `*` is only a name.
	paths: []string
	if is_directory(input) {
		paths = package_sources(c, input)
	} else {
		paths = []string{input}
	}
	status := 0
	for path in paths {
		file, loaded := load_source(c, path)
		if !loaded {
			status = 1
			continue
		}
		formatted, ok := format_source(c, file)
		if !ok {
			status = 1
			continue
		}
		if formatted == c.sources[file].text {
			continue
		}
		if check {
			fmt.println(path)
			status = 1
		} else if os.write_entire_file(path, transmute([]u8)formatted) != nil {
			errorf(c, no_span(), "L0401", "cannot write `%s`", path)
			status = 1
		}
	}
	return status
}

// The source of `file` laid out canonically, or false when it does not parse.
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
	formatted := layout(text, tokens[:len(tokens) - 1], c.sources[file].comments[:])

	// The guarantee, checked rather than assumed: the same tokens, in order.
	scratch: Compiler
	defer destroy_compilation(&scratch)
	append(&scratch.sources, Source{path = c.sources[file].path, text = formatted, line_starts = {}})
	again := lex(&scratch, 0)
	defer delete(again)
	same := len(again) == len(tokens)
	for index := 0; same && index < len(tokens); index += 1 {
		a, b := tokens[index], again[index]
		same = a.kind == b.kind && text[a.lo:a.hi] == formatted[b.lo:b.hi]
	}
	if !same {
		errorf(c, Span{file = file}, "L0405", "internal formatter error: formatting would change this file's tokens")
		return "", false
	}
	return formatted, true
}

// An open bracket, and the indentation of what it encloses.
@(private = "file")
Open :: struct {
	kind:  Token_Kind,
	inner: int,
	line:  int,
	// `@(...)`, whose arguments keep their written spacing.
	attribute: bool,
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
	// The kind of the token before `last`.
	before_last: Token_Kind,
	// The first token of the last line that had one.
	line_first: Token,
	// Whether `last` is a postfix `^` or `?`, which ends an operand, and
	// whether it is an operator used as binary rather than prefix, and written
	// tight (`written_tight`).
	postfix:     bool,
	last_binary: bool,
	last_tight:  bool,
	// Whether the current line continues an unfinished one, and whether the
	// line `last` is on did.
	continued:      bool,
	last_continued: bool,
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
	started := false
	next_comment := 0
	for index := 0; index <= len(tokens); index += 1 {
		// Comments before this token come first.
		limit := index < len(tokens) ? tokens[index].lo : u32(len(text))
		for next_comment < len(comments) && comments[next_comment].lo < limit {
			comment := comments[next_comment]
			next_comment += 1
			gap := text[previous_hi:comment.lo]
			if started && !break_line(&l, gap) {
				// A trailing comment keeps its alignment, and at least a space.
				strings.write_string(&l.out, horizontal(gap) != "" ? horizontal(gap) : " ")
			} else {
				indent(&l, index < len(tokens) ? tokens[index] : Token{kind = .EOF}, true)
			}
			strings.write_string(&l.out, strings.trim_right(text[comment.lo:comment.hi], " \t"))
			previous_hi = comment.hi
			started = true
		}
		if index == len(tokens) {
			break
		}
		token := tokens[index]
		gap := text[previous_hi:token.lo]
		if started && break_line(&l, gap) {
			indent(&l, token, false)
		} else if started && l.last.kind != .EOF && l.last_line == l.line {
			space := spacing(&l, token, horizontal(gap))
			if space == "" && horizontal(gap) != "" && would_merge(text[l.last.hi - 1], text[token.lo]) {
				space = " " // `& &x` must not become `&&x`
			}
			strings.write_string(&l.out, space)
		} else if started {
			strings.write_string(&l.out, horizontal(gap) != "" ? horizontal(gap) : " ")
		}
		write_token(&l, token)
		previous_hi = token.hi
		started = true
	}
	strings.write_string(&l.out, l.newline)
	return strings.to_string(l.out)
}

// Whether two tokens ending in `a` and starting with `b`, written together,
// would begin a longer operator instead.
@(private = "file")
would_merge :: proc(a, b: u8) -> bool {
	switch string([]u8{a, b}) {
	case "&&", "||", "<<", ">>", "==", "!=", "<=", ">=", "::", ":=", "..", "&~", "->",
	     "+=", "-=", "*=", "/=", "%=", "|=", "~=", "&=", "--", "//", "/*":
		return true
	}
	return false
}

// The spaces and tabs of a gap on one line.
@(private = "file")
horizontal :: proc(gap: string) -> string {
	return strings.trim(gap, "\r\n")
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

// Tabs for a line that starts with `first`: one per enclosing bracket opened
// on an earlier line, one fewer for a closing bracket or a `case`, and one
// more for a line continuing an unfinished one.
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
	case continues(l, top):
		depth += 1
		l.continued = true
	}
	for _ in 0 ..< max(depth, 0) {
		strings.write_byte(&l.out, '\t')
	}
}

// Whether the last line with a token left its statement unfinished, outside
// any `(` or `[`, whose own indentation is enough. A comma ends a list item,
// except on a line that was already a continuation, such as a `where` clause.
@(private = "file")
continues :: proc(l: ^Layout, top: Open) -> bool {
	#partial switch l.last.kind {
	case .EOF, .Semicolon, .Lbrace, .Rbrace, .Lparen, .Lbracket:
		return false
	case .Colon:
		// `case .a:` ends its line; `TEXT ::` continues onto the next.
		if l.line_first.kind == .Case || l.line_first.kind == .Default {
			return false
		}
	case .Comma:
		if !l.last_continued {
			return false
		}
	}
	// An attribute line such as `@(public)` belongs to the line below it.
	if l.line_first.kind == .At {
		return false
	}
	return len(l.opens) == 0 || top.kind == .Lbrace && top.line < l.last_line
}

@(private = "file")
write_token :: proc(l: ^Layout, token: Token) {
	if l.last_line != l.line || l.last.kind == .EOF {
		l.line_first = token
	}
	#partial switch token.kind {
	case .Lparen, .Lbracket, .Lbrace:
		// Brackets opened together on one line indent their contents once, and
		// one opened on a continued line, such as a `where` clause's `{`, indents
		// from the line its statement began on.
		inner := line_indent(l) + 1
		if l.continued && token.kind == .Lbrace {
			inner -= 1
		}
		if len(l.opens) > 0 && l.opens[len(l.opens) - 1].line == l.line {
			inner = l.opens[len(l.opens) - 1].inner
		}
		if token.kind == .Lbrace && len(l.opens) == 0 && flat_when(l, token) {
			inner = 0
		}
		append(&l.opens, Open{kind = token.kind, inner = inner, line = l.line, attribute = l.last.kind == .At})
	case .Rparen, .Rbracket, .Rbrace:
		if len(l.opens) > 0 {
			pop(&l.opens)
		}
	}
	operand := ends_operand(l)
	l.postfix = (token.kind == .Caret || token.kind == .Question) && operand
	l.last_binary = binary_operator(token.kind) && (operand || !maybe_prefix(token.kind))
	l.last_tight = l.last_binary && written_tight(l, token)
	strings.write_string(&l.out, l.text[token.lo:token.hi])
	l.before_last = l.last.kind
	l.last, l.last_line, l.last_continued = token, l.line, l.continued
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
	return at < len(l.text) && at > int(brace.hi) && l.text[at - 1] == '\n'
}

// The tabs the line being written started with.
@(private = "file")
line_indent :: proc(l: ^Layout) -> int {
	written := strings.to_string(l.out)
	start := strings.last_index_byte(written, '\n') + 1
	depth := 0
	for start + depth < len(written) && written[start + depth] == '\t' {
		depth += 1
	}
	return depth
}

// Whether the last token ends an operand, which makes a following `-`, `&`,
// or `^` binary or postfix rather than prefix.
@(private = "file")
ends_operand :: proc(l: ^Layout) -> bool {
	#partial switch l.last.kind {
	case .Ident, .Int, .Float, .String, .Raw_String, .Rune, .Rparen, .Rbracket, .Rbrace, .Uninit:
		return true
	case .Caret, .Question:
		return l.postfix
	}
	return false
}

@(private = "file")
binary_operator :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Plus, .Minus, .Star, .Slash, .Percent, .Amp, .Amp_Tilde, .Pipe, .Tilde, .Shl, .Shr,
	     .And_And, .Or_Or, .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq, .Assign, .Plus_Eq,
	     .Minus_Eq, .Star_Eq, .Slash_Eq, .Percent_Eq, .Pipe_Eq, .Tilde_Eq, .Amp_Eq,
	     .Amp_Tilde_Eq, .Shl_Eq, .Shr_Eq, .Range_Incl, .Range_Excl, .Arrow, .In,
	     .Or_Else, .Via:
		return true
	}
	return false
}

// An arithmetic or bitwise operator the author wrote with no space on either
// side, as `core/` writes `a*b + c*d` by precedence. It stays tight; one with
// a space on either side gets one on both.
@(private = "file")
written_tight :: proc(l: ^Layout, token: Token) -> bool {
	#partial switch token.kind {
	case .Plus, .Minus, .Star, .Slash, .Percent, .Amp, .Amp_Tilde, .Pipe, .Tilde, .Shl, .Shr:
	case:
		return false
	}
	return token.lo > 0 && token.hi < u32(len(l.text)) &&
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
	case .Minus, .Plus, .Not, .Tilde, .Amp, .Caret, .Question, .Range, .Dollar, .At:
		return true
	}
	return false
}

// Control keywords that take a space before their `(`.
@(private = "file")
spaced_keyword :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .If, .For, .Foreach, .Switch, .When, .Return, .Case, .In, .Else, .Or_Else, .Via, .Where, .Defer:
		return true
	}
	return false
}

@(private = "file")
is_keyword :: proc(kind: Token_Kind) -> bool {
	return kind >= .Break && kind <= .Where
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
	case .Rbrace:
		return written
	case .Lbrace:
		return written // `Point{1, 2}`, `proc{a, b}`, and `if (x) {` alike
	case .Period:
		return operand ? "" : written
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
		if last == .Inout || last == .Mut || last == .Distinct {
			return written
		}
		// The contextual keywords of `storage: static [256]u8`.
		if last == .Ident {
			switch l.text[l.last.lo:l.last.hi] {
			case "static", "thread_local":
				return written
			}
		}
		if operand || is_keyword(last) && (next.kind == .Lparen || last == .Map) {
			return ""
		}
		if is_keyword(last) {
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
		return "" // a prefix operator binds to its operand
	}
	if binary_operator(next.kind) && !(maybe_prefix(next.kind) && !operand) {
		return written_tight(l, next) ? "" : at_least_one
	}
	if l.last_tight {
		return ""
	}
	if binary_operator(last) || is_keyword(last) {
		return at_least_one
	}
	return written
}
