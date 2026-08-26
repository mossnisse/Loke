// Lexer (compiler-plan B3), complete against grammar.md "Lexical structure".
//
// Two rules that a hand-written scanner gets wrong by reflex:
//   * `::` and `:=` are TOKEN PAIRS, not tokens. `x := 1` is `x` `:` `=` `1`.
//     That is what makes `x: int = 1`, `x: = 1` and `x := 1` one declaration.
//   * Longest match, so `&~=`, `..=`, `..<`, `<<=`, `>>=` and `---` each lex as
//     a single token.
//
// A bad character produces an Error token and lexing continues; the parser must
// still be able to say something useful.
package lokec

import "core:strings"

Token_Kind :: enum {
	EOF,
	Error,

	// literals and names
	Ident,
	Int,
	Float,
	String,
	Raw_String,
	Rune,

	// keywords, reserved in every position
	Break,
	Case,
	Continue,
	Defer,
	Distinct,
	Dyn,
	Dynamic,
	Else,
	Enum,
	For,
	Foreach,
	Foreign,
	Hook,
	If,
	Impl,
	Import,
	In,
	Inout,
	Interface,
	Map,
	Move,
	Move_Only,
	Mut,
	Operator,
	Or_Else,
	Or_Return,
	Package,
	Proc,
	Return,
	Struct,
	Switch,
	Type,
	Union,
	Via,
	When,
	Where,

	// operators and punctuation
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Amp,
	Amp_Tilde,
	Pipe,
	Tilde,
	Shl,
	Shr,
	And_And,
	Or_Or,
	Not,
	Eq_Eq,
	Not_Eq,
	Lt,
	Lt_Eq,
	Gt,
	Gt_Eq,
	Assign,
	Plus_Eq,
	Minus_Eq,
	Star_Eq,
	Slash_Eq,
	Percent_Eq,
	Pipe_Eq,
	Tilde_Eq,
	Amp_Eq,
	Amp_Tilde_Eq,
	Shl_Eq,
	Shr_Eq,
	Colon,
	Semicolon,
	Comma,
	Period,
	Range,
	Range_Incl,
	Range_Excl,
	Arrow,
	Uninit,
	Question,
	Dollar,
	Caret,
	At,
	Lparen,
	Rparen,
	Lbracket,
	Rbracket,
	Lbrace,
	Rbrace,
}

Token :: struct {
	kind: Token_Kind,
	lo:   u32,
	hi:   u32,
}

@(private = "file")
Lexer :: struct {
	c:    ^Compiler,
	file: u32,
	src:  string,
	pos:  u32,
}

lex :: proc(c: ^Compiler, file: u32) -> []Token {
	l := Lexer {
		c    = c,
		file = file,
		src  = c.sources[file].text,
	}
	tokens := make([dynamic]Token)
	for {
		t := next_token(&l)
		append(&tokens, t)
		if t.kind == .EOF {
			break
		}
	}
	return tokens[:]
}

@(private = "file")
at_end :: proc(l: ^Lexer) -> bool {
	return int(l.pos) >= len(l.src)
}

@(private = "file")
peek :: proc(l: ^Lexer, offset: u32 = 0) -> u8 {
	i := int(l.pos + offset)
	return i < len(l.src) ? l.src[i] : 0
}

@(private = "file")
matches :: proc(l: ^Lexer, text: string) -> bool {
	return strings.has_prefix(l.src[l.pos:], text)
}

@(private = "file")
span_from :: proc(l: ^Lexer, lo: u32) -> Span {
	return Span{file = l.file, lo = lo, hi = l.pos}
}

@(private = "file")
is_digit :: proc(ch: u8) -> bool {return ch >= '0' && ch <= '9'}

@(private = "file")
is_hex :: proc(ch: u8) -> bool {
	return is_digit(ch) || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')
}

// Only ever called on a character `is_hex` accepted.
@(private = "file")
hex_value :: proc(ch: u8) -> u32 {
	switch {
	case ch <= '9':
		return u32(ch - '0')
	case ch <= 'F':
		return u32(ch - 'A' + 10)
	}
	return u32(ch - 'a' + 10)
}

@(private = "file")
is_ident_start :: proc(ch: u8) -> bool {
	return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

@(private = "file")
is_ident_part :: proc(ch: u8) -> bool {
	return is_ident_start(ch) || is_digit(ch)
}

@(private = "file")
skip_trivia :: proc(l: ^Lexer) {
	for !at_end(l) {
		switch peek(l) {
		case ' ', '\t', '\r', '\n':
			l.pos += 1
		case '/':
			if peek(l, 1) == '/' {
				for !at_end(l) && peek(l) != '\n' {
					l.pos += 1
				}
			} else if peek(l, 1) == '*' {
				block_comment(l)
			} else {
				return
			}
		case:
			return
		}
	}
}

// Block comments nest, so this counts depth rather than scanning for the first
// `*/`.
@(private = "file")
block_comment :: proc(l: ^Lexer) {
	start := l.pos
	depth := 0
	for !at_end(l) {
		if matches(l, "/*") {
			depth += 1
			l.pos += 2
		} else if matches(l, "*/") {
			depth -= 1
			l.pos += 2
			if depth == 0 {
				return
			}
		} else {
			l.pos += 1
		}
	}
	errorf(
		l.c,
		Span{file = l.file, lo = start, hi = start + 2},
		"L0103",
		"unterminated block comment",
	)
}

@(private = "file")
next_token :: proc(l: ^Lexer) -> Token {
	skip_trivia(l)
	lo := l.pos
	if at_end(l) {
		return Token{kind = .EOF, lo = lo, hi = lo}
	}

	ch := peek(l)
	switch {
	case is_ident_start(ch):
		return ident_or_keyword(l)
	case is_digit(ch):
		return number(l)
	case ch == '"':
		return string_literal(l)
	case ch == '`':
		return raw_string_literal(l)
	case ch == '\'':
		return rune_literal(l)
	case ch >= 0x80:
		// Everything outside strings, comments and rune literals is ASCII.
		l.pos += 1
		for !at_end(l) && peek(l) >= 0x80 {
			l.pos += 1
		}
		errorf(
			l.c,
			span_from(l, lo),
			"L0102",
			"non-ASCII character outside a string, comment or character literal",
		)
		return Token{kind = .Error, lo = lo, hi = l.pos}
	}

	return operator(l)
}

@(private = "file")
ident_or_keyword :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	for !at_end(l) && is_ident_part(peek(l)) {
		l.pos += 1
	}

	// Contextual keywords (`static`, `self`, `slot`, `using`, `delegate`,
	// `thread_local`, `manual`) and the predeclared, shadowable names (`nil`,
	// `true`, `false`, the built-ins) stay ordinary identifiers here; position
	// is the parser's problem.
	kind: Token_Kind = .Ident
	switch l.src[lo:l.pos] {
	case "break":
		kind = .Break
	case "case":
		kind = .Case
	case "continue":
		kind = .Continue
	case "defer":
		kind = .Defer
	case "distinct":
		kind = .Distinct
	case "dyn":
		kind = .Dyn
	case "dynamic":
		kind = .Dynamic
	case "else":
		kind = .Else
	case "enum":
		kind = .Enum
	case "for":
		kind = .For
	case "foreach":
		kind = .Foreach
	case "foreign":
		kind = .Foreign
	case "hook":
		kind = .Hook
	case "if":
		kind = .If
	case "impl":
		kind = .Impl
	case "import":
		kind = .Import
	case "in":
		kind = .In
	case "inout":
		kind = .Inout
	case "interface":
		kind = .Interface
	case "map":
		kind = .Map
	case "move":
		kind = .Move
	case "move_only":
		kind = .Move_Only
	case "mut":
		kind = .Mut
	case "operator":
		kind = .Operator
	case "or_else":
		kind = .Or_Else
	case "or_return":
		kind = .Or_Return
	case "package":
		kind = .Package
	case "proc":
		kind = .Proc
	case "return":
		kind = .Return
	case "struct":
		kind = .Struct
	case "switch":
		kind = .Switch
	case "type":
		kind = .Type
	case "union":
		kind = .Union
	case "via":
		kind = .Via
	case "when":
		kind = .When
	case "where":
		kind = .Where
	}
	return Token{kind = kind, lo = lo, hi = l.pos}
}

@(private = "file")
number :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	kind := Token_Kind.Int

	if peek(l) == '0' && (peek(l, 1) == 'b' || peek(l, 1) == 'o' || peek(l, 1) == 'x') {
		base := peek(l, 1)
		l.pos += 2
		digits := 0
		for !at_end(l) {
			ch := peek(l)
			valid: bool
			switch base {
			case 'b':
				valid = ch == '0' || ch == '1'
			case 'o':
				valid = ch >= '0' && ch <= '7'
			case:
				valid = is_hex(ch)
			}
			if !valid && ch != '_' {
				break
			}
			if ch != '_' {
				digits += 1
			}
			l.pos += 1
		}
		// With a tail still to come (`0o8`, `0xzz`) `number_end` gives the better
		// message; L0110 is for a prefix with nothing after it at all.
		if digits == 0 && !is_ident_part(peek(l)) {
			errorf(l.c, span_from(l, lo), "L0110", "expected digits after `0%c`", base)
			return Token{kind = .Error, lo = lo, hi = l.pos}
		}
		return number_end(l, lo, .Int)
	}

	for !at_end(l) && (is_digit(peek(l)) || peek(l) == '_') {
		l.pos += 1
	}

	// A float needs a digit after the point, which is what keeps `1..5` from
	// swallowing the range operator.
	if peek(l) == '.' && is_digit(peek(l, 1)) {
		kind = .Float
		l.pos += 1
		for !at_end(l) && (is_digit(peek(l)) || peek(l) == '_') {
			l.pos += 1
		}
	}

	if peek(l) == 'e' || peek(l) == 'E' {
		offset: u32 = 1
		if peek(l, 1) == '+' || peek(l, 1) == '-' {
			offset = 2
		}
		if !is_digit(peek(l, offset)) {
			l.pos += offset
			errorf(l.c, span_from(l, lo), "L0112", "an exponent needs at least one digit")
			return Token{kind = .Error, lo = lo, hi = l.pos}
		}
		kind = .Float
		l.pos += offset
		for !at_end(l) && is_digit(peek(l)) {
			l.pos += 1
		}
	}

	return number_end(l, lo, kind)
}

// A number never abuts a name: `0b12`, `123abc` and `1_000u` are typos, not two
// tokens. Consuming the tail keeps the parser from tripping over a stray
// identifier a line later.
@(private = "file")
number_end :: proc(l: ^Lexer, lo: u32, kind: Token_Kind) -> Token {
	if at_end(l) || !is_ident_part(peek(l)) {
		return Token{kind = kind, lo = lo, hi = l.pos}
	}
	bad := l.pos
	for !at_end(l) && is_ident_part(peek(l)) {
		l.pos += 1
	}
	errorf(l.c, span_from(l, lo), "L0113", "unexpected `%s` in a number", l.src[bad:l.pos])
	return Token{kind = .Error, lo = lo, hi = l.pos}
}

// Validates one escape sequence, `l.pos` sitting on the backslash.
@(private = "file")
escape :: proc(l: ^Lexer) -> bool {
	lo := l.pos
	l.pos += 1 // the backslash
	if at_end(l) {
		errorf(l.c, span_from(l, lo), "L0105", "incomplete escape sequence")
		return false
	}
	ch := peek(l)
	switch ch {
	case 'a', 'b', 'e', 'f', 'n', 'r', 't', 'v', '\\', '"', '\'':
		l.pos += 1
		return true
	case 'x', 'u', 'U':
		count := 2 if ch == 'x' else (4 if ch == 'u' else 8)
		l.pos += 1
		value: u32 = 0
		for i := 0; i < count; i += 1 {
			if !is_hex(peek(l)) {
				errorf(
					l.c,
					span_from(l, lo),
					"L0105",
					"`\\%c` needs %d hexadecimal digits",
					ch,
					count,
				)
				return false
			}
			value = value * 16 + hex_value(peek(l))
			l.pos += 1
		}
		// `\x` is a raw byte; `\u` and `\U` name a character, and the surrogate
		// range has no character in it.
		if ch != 'x' && (value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) {
			errorf(
				l.c,
				span_from(l, lo),
				"L0114",
				"`%s` is not a Unicode character",
				l.src[lo:l.pos],
			)
			return false
		}
		return true
	case '0' ..= '7':
		for i := 0; i < 3; i += 1 {
			if peek(l) < '0' || peek(l) > '7' {
				errorf(l.c, span_from(l, lo), "L0105", "an octal escape needs 3 digits")
				return false
			}
			l.pos += 1
		}
		return true
	}
	l.pos += 1
	errorf(l.c, span_from(l, lo), "L0105", "unknown escape sequence")
	return false
}

@(private = "file")
string_literal :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	l.pos += 1
	valid := true
	for {
		if at_end(l) || peek(l) == '\n' || peek(l) == '\r' {
			errorf(l.c, Span{file = l.file, lo = lo, hi = lo + 1}, "L0104", "unterminated string literal")
			return Token{kind = .Error, lo = lo, hi = l.pos}
		}
		switch peek(l) {
		case '"':
			l.pos += 1
			return Token{kind = valid ? .String : .Error, lo = lo, hi = l.pos}
		case '\\':
			escape_ok := escape(l)
			valid = escape_ok && valid
			if !escape_ok && at_end(l) {
				return Token{kind = .Error, lo = lo, hi = l.pos}
			}
		case:
			l.pos += 1
		}
	}
}

@(private = "file")
raw_string_literal :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	l.pos += 1
	for !at_end(l) && peek(l) != '`' {
		l.pos += 1 // no escapes, and it may span lines
	}
	if at_end(l) {
		errorf(
			l.c,
			Span{file = l.file, lo = lo, hi = lo + 1},
			"L0111",
			"unterminated raw string literal",
		)
		return Token{kind = .Error, lo = lo, hi = l.pos}
	}
	l.pos += 1
	return Token{kind = .Raw_String, lo = lo, hi = l.pos}
}

@(private = "file")
rune_literal :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	l.pos += 1
	if at_end(l) || peek(l) == '\n' || peek(l) == '\r' {
		errorf(
			l.c,
			Span{file = l.file, lo = lo, hi = lo + 1},
			"L0106",
			"unterminated character literal",
		)
		return Token{kind = .Error, lo = lo, hi = l.pos}
	}

	if peek(l) == '\\' {
		if !escape(l) {
			return Token{kind = .Error, lo = lo, hi = l.pos}
		}
	} else {
		// One Unicode scalar: step over a whole UTF-8 sequence.
		l.pos += 1
		for !at_end(l) && peek(l) >= 0x80 && peek(l) < 0xc0 {
			l.pos += 1
		}
	}

	if peek(l) != '\'' {
		for !at_end(l) && peek(l) != '\'' && peek(l) != '\n' {
			l.pos += 1
		}
		if peek(l) == '\'' {
			l.pos += 1
			errorf(
				l.c,
				span_from(l, lo),
				"L0107",
				"a character literal holds exactly one character",
			)
		} else {
			errorf(
				l.c,
				Span{file = l.file, lo = lo, hi = lo + 1},
				"L0106",
				"unterminated character literal",
			)
		}
		return Token{kind = .Error, lo = lo, hi = l.pos}
	}
	l.pos += 1
	return Token{kind = .Rune, lo = lo, hi = l.pos}
}

// Longest match wins. `:` is never combined with anything: `::` and `:=` are
// token pairs by design.
@(private = "file")
OPERATORS :: [?]struct {
	text: string,
	kind: Token_Kind,
}{
	{"&~=", .Amp_Tilde_Eq},
	{"..=", .Range_Incl},
	{"..<", .Range_Excl},
	{"<<=", .Shl_Eq},
	{">>=", .Shr_Eq},
	{"---", .Uninit},
	{"&~", .Amp_Tilde},
	{"&&", .And_And},
	{"||", .Or_Or},
	{"==", .Eq_Eq},
	{"!=", .Not_Eq},
	{"<=", .Lt_Eq},
	{">=", .Gt_Eq},
	{"<<", .Shl},
	{">>", .Shr},
	{"+=", .Plus_Eq},
	{"-=", .Minus_Eq},
	{"*=", .Star_Eq},
	{"/=", .Slash_Eq},
	{"%=", .Percent_Eq},
	{"|=", .Pipe_Eq},
	{"~=", .Tilde_Eq},
	{"&=", .Amp_Eq},
	{"->", .Arrow},
	{"..", .Range},
	{"+", .Plus},
	{"-", .Minus},
	{"*", .Star},
	{"/", .Slash},
	{"%", .Percent},
	{"&", .Amp},
	{"|", .Pipe},
	{"~", .Tilde},
	{"!", .Not},
	{"<", .Lt},
	{">", .Gt},
	{"=", .Assign},
	{":", .Colon},
	{";", .Semicolon},
	{",", .Comma},
	{".", .Period},
	{"?", .Question},
	{"$", .Dollar},
	{"^", .Caret},
	{"@", .At},
	{"(", .Lparen},
	{")", .Rparen},
	{"[", .Lbracket},
	{"]", .Rbracket},
	{"{", .Lbrace},
	{"}", .Rbrace},
}

// The canonical text a punctuation operator is written with, and "" for every
// kind the table has no spelling for — the keyword operators (`in`, `or_else`)
// among them. `OPERATORS` stays the one place a spelling is written down, so a
// new operator cannot lex and then print as something else.
operator_spelling :: proc(kind: Token_Kind) -> string {
	for op in OPERATORS {
		if op.kind == kind {
			return op.text
		}
	}
	return ""
}

@(private = "file")
operator :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	for op in OPERATORS {
		if matches(l, op.text) {
			l.pos += u32(len(op.text))
			return Token{kind = op.kind, lo = lo, hi = l.pos}
		}
	}
	l.pos += 1
	errorf(l.c, span_from(l, lo), "L0101", "invalid character `%s`", l.src[lo:l.pos])
	return Token{kind = .Error, lo = lo, hi = l.pos}
}
