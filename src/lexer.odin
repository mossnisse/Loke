// Lexer for grammar.md "Lexical structure". Invalid input becomes an Error
// token so parsing can continue.
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

	// Keywords, reserved in every position. `reserved_keyword` and `any_keyword`
	// read these ranges, so a new one goes inside its range, with a row in
	// `keyword_table`.
	Break,
	Case,
	Continue,
	Default,
	Defer,
	Distinct,
	Dyn,
	Else,
	Enum,
	Errdefer,
	For,
	Foreach,
	Foreign,
	If,
	Impl,
	Import,
	In,
	Inout,
	Interface,
	Map,
	Move,
	Mut,
	Or_Else,
	Or_Return,
	Package,
	Proc,
	Return,
	Struct,
	Switch,
	Type,
	Union,
	When,

	// Contextual keywords (grammar.md "Keywords"). The lexer produces them as
	// `Ident`; the parser retags one it reads as the keyword, so a tool laying
	// out the parsed tokens sees the keyword.
	Dynamic,
	Hook,
	Operator,
	Parallel,
	Spawn,
	Via,
	Where,

	// `move_only` is a name. The parser retags it directly before `struct`, where
	// it is the earlier spelling of `@(move_only)`.
	Move_Only,

	// operators and punctuation
	Plus,
	Minus,
	Star,
	Plus_Wrap,
	Minus_Wrap,
	Star_Wrap,
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
	Plus_Wrap_Eq,
	Minus_Wrap_Eq,
	Star_Wrap_Eq,
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
	clear(&c.sources[file].comments)
	reject_lone_carriage_returns(&l)
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

// grammar.md "Whitespace and comments": a carriage return only ever begins a
// `\r\n`. Checked over the whole text, comments and literals included, so that
// every line table, which only `\n` ends, agrees with an editor's. The first
// is reported: a file that has one usually ends every line that way.
@(private = "file")
reject_lone_carriage_returns :: proc(l: ^Lexer) {
	for i := 0; i < len(l.src); i += 1 {
		if l.src[i] == '\r' && (i + 1 == len(l.src) || l.src[i + 1] != '\n') {
			errorf(
				l.c,
				Span{file = l.file, lo = u32(i), hi = u32(i + 1)},
				"L0115",
				"a carriage return must be followed by a newline",
			)
			return
		}
	}
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

// A digit's value in any base up to 16; anything else is larger than every radix.
digit_value :: proc(ch: u8) -> int {
	switch ch {
	case '0' ..= '9':
		return int(ch - '0')
	case 'a' ..= 'f':
		return int(ch - 'a') + 10
	case 'A' ..= 'F':
		return int(ch - 'A') + 10
	}
	return 99
}

@(private = "file")
is_ident_start :: proc(ch: u8) -> bool {
	return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

is_ident_part :: proc(ch: u8) -> bool {
	return is_ident_start(ch) || is_digit(ch)
}

// Whether `text` is spelled as a name, keyword or not.
identifier_spelling :: proc(text: string) -> bool {
	if text == "" || !is_ident_start(text[0]) { return false }
	for i in 1 ..< len(text) {
		if !is_ident_part(text[i]) { return false }
	}
	return true
}

@(private = "file")
at_literal_end :: proc(l: ^Lexer) -> bool {
	return at_end(l) || peek(l) == '\n' || peek(l) == '\r'
}

@(private = "file")
skip_ident_tail :: proc(l: ^Lexer) {
	for is_ident_part(peek(l)) {
		l.pos += 1
	}
}

@(private = "file")
skip_trivia :: proc(l: ^Lexer) {
	for !at_end(l) {
		switch peek(l) {
		case ' ', '\t', '\r', '\n':
			l.pos += 1
		case '/':
			lo := l.pos
			if peek(l, 1) == '/' {
				for !at_end(l) && peek(l) != '\n' {
					l.pos += 1
				}
				hi := l.pos
				if l.src[hi - 1] == '\r' {
					hi -= 1
				}
				append(&l.c.sources[l.file].comments, Span{file = l.file, lo = lo, hi = hi})
			} else if peek(l, 1) == '*' {
				block_comment(l)
				append(&l.c.sources[l.file].comments, span_from(l, lo))
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

// Reports over the text since `lo`, which becomes one bad token.
@(private = "file")
error_token :: proc(l: ^Lexer, lo: u32, code, format: string, args: ..any) -> Token {
	errorf(l.c, span_from(l, lo), code, format, ..args)
	return Token{kind = .Error, lo = lo, hi = l.pos}
}

// Reports at the opening quote of what never closes.
@(private = "file")
unterminated :: proc(l: ^Lexer, lo: u32, code, what: string) -> Token {
	errorf(l.c, Span{file = l.file, lo = lo, hi = lo + 1}, code, "unterminated %s", what)
	return Token{kind = .Error, lo = lo, hi = l.pos}
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
		// grammar.md "Source encoding"
		l.pos += 1
		for peek(l) >= 0x80 {
			l.pos += 1
		}
		return error_token(l, lo, "L0102", "non-ASCII character outside a string, comment or character literal")
	}

	return operator(l)
}

// A word reserved in every position (grammar.md "Keywords"), which is still a
// member name.
reserved_keyword :: proc(kind: Token_Kind) -> bool {
	return kind >= .Break && kind <= .When
}

// A reserved or a contextual keyword.
any_keyword :: proc(kind: Token_Kind) -> bool {
	return kind >= .Break && kind <= .Where
}

// Every keyword's spelling, the reserved ones first. Read-only data, as
// `operator_table` is.
@(rodata)
keyword_table := [?]struct {
	text: string,
	kind: Token_Kind,
}{
	{"break", .Break},
	{"case", .Case},
	{"continue", .Continue},
	{"default", .Default},
	{"defer", .Defer},
	{"distinct", .Distinct},
	{"dyn", .Dyn},
	{"else", .Else},
	{"enum", .Enum},
	{"errdefer", .Errdefer},
	{"for", .For},
	{"foreach", .Foreach},
	{"foreign", .Foreign},
	{"if", .If},
	{"impl", .Impl},
	{"import", .Import},
	{"in", .In},
	{"inout", .Inout},
	{"interface", .Interface},
	{"map", .Map},
	{"move", .Move},
	{"mut", .Mut},
	{"or_else", .Or_Else},
	{"or_return", .Or_Return},
	{"package", .Package},
	{"proc", .Proc},
	{"return", .Return},
	{"struct", .Struct},
	{"switch", .Switch},
	{"type", .Type},
	{"union", .Union},
	{"when", .When},
	{"dynamic", .Dynamic},
	{"hook", .Hook},
	{"operator", .Operator},
	{"parallel", .Parallel},
	{"spawn", .Spawn},
	{"via", .Via},
	{"where", .Where},
}

@(private = "file")
ident_or_keyword :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	skip_ident_tail(l)
	word := l.src[lo:l.pos]
	for keyword in keyword_table {
		if !reserved_keyword(keyword.kind) { break }
		if keyword.text == word {
			return Token{kind = keyword.kind, lo = lo, hi = l.pos}
		}
	}
	return Token{kind = .Ident, lo = lo, hi = l.pos}
}

@(private = "file")
number :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	kind := Token_Kind.Int

	if peek(l) == '0' && (peek(l, 1) == 'b' || peek(l, 1) == 'o' || peek(l, 1) == 'x') {
		base := peek(l, 1)
		radix := base == 'b' ? 2 : (base == 'o' ? 8 : 16)
		l.pos += 2
		digits := 0
		for {
			ch := peek(l)
			if digit_value(ch) < radix {
				digits += 1
			} else if ch != '_' {
				break
			}
			l.pos += 1
		}
		// With a tail still to come (`0o8`, `0xzz`) `number_end` gives the better
		// message; L0110 is for a prefix with nothing after it at all.
		if digits == 0 && !is_ident_part(peek(l)) {
			return error_token(l, lo, "L0110", "expected digits after `0%c`", base)
		}
		return number_end(l, lo, .Int)
	}

	for is_digit(peek(l)) || peek(l) == '_' {
		l.pos += 1
	}

	// A float needs a digit after the point, which is what keeps `1..5` from
	// swallowing the range operator.
	if peek(l) == '.' && is_digit(peek(l, 1)) {
		kind = .Float
		l.pos += 1
		for is_digit(peek(l)) || peek(l) == '_' {
			l.pos += 1
		}
	}

	if peek(l) == 'e' || peek(l) == 'E' {
		l.pos += peek(l, 1) == '+' || peek(l, 1) == '-' ? 2 : 1
		if !is_digit(peek(l)) {
			// Take a bad exponent as one token, like other malformed numbers.
			skip_ident_tail(l)
			return error_token(l, lo, "L0112", "an exponent needs at least one digit")
		}
		kind = .Float
		for is_digit(peek(l)) {
			l.pos += 1
		}
	}

	return number_end(l, lo, kind)
}

// A number never abuts a name: `0b12`, `123abc` and `1_000u` are typos, not
// two tokens; consuming the tail keeps the parser from tripping over a stray
// identifier a line later.
@(private = "file")
number_end :: proc(l: ^Lexer, lo: u32, kind: Token_Kind) -> Token {
	if !is_ident_part(peek(l)) {
		return Token{kind = kind, lo = lo, hi = l.pos}
	}
	bad := l.pos
	skip_ident_tail(l)
	return error_token(l, lo, "L0113", "unexpected `%s` in a number", l.src[bad:l.pos])
}

Escape_Problem :: enum {
	None,
	Incomplete,
	Short_Hex,
	Octal,
	Unknown,
	Not_A_Character,
}

@(private = "file")
hex_escape_digits :: proc(ch: u8) -> int {
	return ch == 'x' ? 2 : (ch == 'u' ? 4 : 8)
}

// The escape that `text` begins with, backslash first: its value and how many
// bytes it spans, which on a problem end where reading stopped. A line ending is
// not something a backslash escapes. Leaving it unread is what lets a literal end
// there instead of scanning into the next line for a closing quote.
scan_escape :: proc(text: string) -> (value: rune, width: int, problem: Escape_Problem) {
	if len(text) < 2 || text[1] == '\n' || text[1] == '\r' {
		return 0, 1, .Incomplete
	}
	ch := text[1]
	switch ch {
	case 'a': return '\a', 2, .None
	case 'b': return '\b', 2, .None
	case 'e': return 0x1b, 2, .None
	case 'f': return '\f', 2, .None
	case 'n': return '\n', 2, .None
	case 'r': return '\r', 2, .None
	case 't': return '\t', 2, .None
	case 'v': return '\v', 2, .None
	case '\\', '"', '\'': return rune(ch), 2, .None
	case 'x', 'u', 'U':
		digits: u32 = 0
		width = 2
		for _ in 0 ..< hex_escape_digits(ch) {
			digit := width < len(text) ? digit_value(text[width]) : 99
			if digit >= 16 { return 0, width, .Short_Hex }
			digits = digits * 16 + u32(digit)
			width += 1
		}
		// `\x` is a raw byte; `\u` and `\U` name a character, and the surrogate
		// range has no character in it.
		if ch != 'x' && (digits > 0x10ffff || (digits >= 0xd800 && digits <= 0xdfff)) {
			return 0, width, .Not_A_Character
		}
		return rune(digits), width, .None
	case '0' ..= '9':
		return 0, 2, .Octal
	}
	return 0, 2, .Unknown
}

@(private = "file")
escape :: proc(l: ^Lexer) -> bool {
	lo := l.pos
	_, width, problem := scan_escape(l.src[lo:])
	l.pos += u32(width)
	switch problem {
	case .None:
		return true
	case .Incomplete:
		errorf(l.c, span_from(l, lo), "L0105", "incomplete escape sequence")
	case .Short_Hex:
		ch := l.src[lo + 1]
		errorf(l.c, span_from(l, lo), "L0105", "`\\%c` needs %d hexadecimal digits", ch, hex_escape_digits(ch))
	case .Not_A_Character:
		errorf(l.c, span_from(l, lo), "L0114", "`%s` is not a Unicode character", l.src[lo:l.pos])
	case .Octal:
		// C's octal byte escape; Loke has none (comments.md "No octal escapes").
		errorf(l.c, span_from(l, lo), "L0105", "there are no octal escapes; write a byte as `\\xNN` or a character as `\\uNNNN`")
	case .Unknown:
		errorf(l.c, span_from(l, lo), "L0105", "unknown escape sequence")
	}
	return false
}

@(private = "file")
string_literal :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	l.pos += 1
	valid := true
	for {
		if at_literal_end(l) {
			return unterminated(l, lo, "L0104", "string literal")
		}
		switch peek(l) {
		case '"':
			l.pos += 1
			return Token{kind = valid ? .String : .Error, lo = lo, hi = l.pos}
		case '\\':
			escape_ok := escape(l)
			valid = escape_ok && valid
			// One diagnostic per literal: no L0104 after a failed escape.
			if !escape_ok && at_literal_end(l) {
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
		l.pos += 1
	}
	if at_end(l) {
		return unterminated(l, lo, "L0111", "raw string literal")
	}
	l.pos += 1
	return Token{kind = .Raw_String, lo = lo, hi = l.pos}
}

@(private = "file")
rune_literal :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	l.pos += 1
	if at_literal_end(l) {
		return unterminated(l, lo, "L0106", "character literal")
	}

	// Consume a closed but empty literal without scanning past it.
	if peek(l) == '\'' {
		l.pos += 1
		return error_token(l, lo, "L0107", "a character literal holds exactly one character")
	}

	valid := true
	if peek(l) == '\\' {
		valid = escape(l)
	} else {
		// One Unicode scalar: step over a whole UTF-8 sequence.
		l.pos += 1
		for peek(l) >= 0x80 && peek(l) < 0xc0 {
			l.pos += 1
		}
	}

	if peek(l) != '\'' {
		for !at_literal_end(l) && peek(l) != '\'' {
			l.pos += 1
		}
		if peek(l) == '\'' {
			l.pos += 1
			if valid {
				errorf(
					l.c,
					span_from(l, lo),
					"L0107",
					"a character literal holds exactly one character",
				)
			}
		} else if valid {
			return unterminated(l, lo, "L0106", "character literal")
		}
		return Token{kind = .Error, lo = lo, hi = l.pos}
	}
	l.pos += 1
	return Token{kind = valid ? .Rune : .Error, lo = lo, hi = l.pos}
}

// First match wins, so longer operators must precede their prefixes. The most
// common come first, none of them a prefix. `:` stays separate because `::` and
// `:=` are token pairs. Read-only data rather than a constant, so a scan does not
// materialize the table first.
@(private, rodata)
operator_table := [?]struct {
	text: string,
	kind: Token_Kind,
}{
	{"(", .Lparen},
	{")", .Rparen},
	{"[", .Lbracket},
	{"]", .Rbracket},
	{"{", .Lbrace},
	{"}", .Rbrace},
	{";", .Semicolon},
	{",", .Comma},
	{"&~=", .Amp_Tilde_Eq},
	{"+%=", .Plus_Wrap_Eq},
	{"-%=", .Minus_Wrap_Eq},
	{"*%=", .Star_Wrap_Eq},
	{"..=", .Range_Incl},
	{"..<", .Range_Excl},
	{"<<=", .Shl_Eq},
	{">>=", .Shr_Eq},
	{"---", .Uninit},
	{"&~", .Amp_Tilde},
	{"+%", .Plus_Wrap},
	{"-%", .Minus_Wrap},
	{"*%", .Star_Wrap},
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
	{".", .Period},
	{"?", .Question},
	{"$", .Dollar},
	{"^", .Caret},
	{"@", .At},
}

operator_spelling :: proc(kind: Token_Kind) -> string {
	for op in operator_table {
		if op.kind == kind {
			return op.text
		}
	}
	return ""
}

@(private = "file")
operator :: proc(l: ^Lexer) -> Token {
	lo := l.pos
	first := peek(l)
	for op in operator_table {
		// Nearly every entry differs in its first byte, which is cheaper to
		// compare than the whole spelling.
		if op.text[0] == first && matches(l, op.text) {
			l.pos += u32(len(op.text))
			return Token{kind = op.kind, lo = lo, hi = l.pos}
		}
	}
	l.pos += 1
	return error_token(l, lo, "L0101", "invalid character `%s`", l.src[lo:l.pos])
}
