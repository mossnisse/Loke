// Constant values and their arithmetic, shared by the checker and the
// compile-time evaluator so both fold identically. `src/bigint.odin` is the
// arbitrary-precision integer half and `src/const_float.odin` the exact float one.
package lokec

import "base:intrinsics"
import "core:math"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

Const_Kind :: enum {
	Invalid,
	Integer,
	Boolean,
	Float,
	String,
	Rune,
	Nil,
	Type,
	Aggregate,
}

// Struct, array, and union constants. Behind a pointer so `Const_Value` stays a
// fixed-size value an AST node can embed.
Const_Aggregate :: struct {
	type:     Type_Id,
	elements: []Const_Value,
	// For a union constant: the variant held, with `elements[0]` its payload (an
	// `Invalid` value when the variant is payloadless).
	variant:  int,
}

// Text is source/compilation backed; `integer` is arena-owned and immutable
// after publication (see `src/bigint.odin`).
Const_Value :: struct {
	kind:       Const_Kind,
	integer:    Big_Int, // Integer and Rune
	float:      f64,
	float_bits: u16,     // the semantic width a Float was last rounded to
	// The exact encoding at `float_bits`. `float` alone cannot carry it: an f32
	// signalling NaN round-tripped through the f64 field comes back quiet, so
	// `unsafe.transmute(u32, x)` would not answer the bits it was handed.
	float_raw:  u64,
	boolean:    bool,
	// A String's text, or an unfixed Float literal's decimal spelling, kept so
	// a narrower destination rounds the exact value once (design.md "Number
	// literals").
	text:       string,
	type_value: Type_Id,
	aggregate:  ^Const_Aggregate,
}

integer_const :: proc(value: Big_Int) -> Const_Value {
	return Const_Value{kind = .Integer, integer = value}
}

int_const :: proc(c: ^Compiler, value: i64) -> Const_Value {
	return Const_Value{kind = .Integer, integer = bi_from_i64(c, value)}
}

rune_const :: proc(value: Big_Int) -> Const_Value {
	return Const_Value{kind = .Rune, integer = value}
}

bool_const :: proc(value: bool) -> Const_Value {
	return Const_Value{kind = .Boolean, boolean = value}
}

nil_const :: proc() -> Const_Value {
	return Const_Value{kind = .Nil}
}

type_const :: proc(type: Type_Id) -> Const_Value {
	return Const_Value{kind = .Type, type_value = type}
}

float_const :: proc(value: f64, bits: u16) -> Const_Value {
	rounded := round_float(value, bits)
	return Const_Value{kind = .Float, float = rounded, float_bits = bits, float_raw = float_pattern(rounded, bits)}
}

// The `unsafe.transmute` direction: exact bits in, the nearest `f64` view of
// them alongside for every ordinary constant operation.
float_bits_const :: proc(raw: u64, bits: u16) -> Const_Value {
	return Const_Value{kind = .Float, float = float_from_pattern(raw, bits), float_bits = bits, float_raw = raw}
}

// The compile-time value of `core:math.count_ones`, `leading_zeros`,
// `trailing_zeros`, or `bit_width` (`builtin`) of `value` as a `bits`-wide
// integer. Zero has `bits` leading and trailing zeros, as LLVM's `ctlz` and
// `cttz` with a defined zero result give, and so a bit width of 0.
bit_count :: proc(value: Big_Int, bits: int, builtin: Builtin_Kind) -> int {
	x := bi_pattern(value, bits)
	#partial switch builtin {
	case .Math_Count_Ones:
		return int(intrinsics.count_ones(x))
	case .Math_Leading_Zeros:
		return int(intrinsics.count_leading_zeros(x)) - (128 - bits)
	case .Math_Bit_Width:
		return 128 - int(intrinsics.count_leading_zeros(x))
	}
	return x == 0 ? bits : int(intrinsics.count_trailing_zeros(x))
}

// The compile-time value of `core:math.reverse_bits`, `is_power_of_two`, or
// `next_power_of_two` (`builtin`) of `value`, of integer type `type`.
// `is_power_of_two` and `next_power_of_two` read the value: a power of two is
// positive, and every value up to 1 rounds up to 1. A `next_power_of_two` that
// does not fit `type` is not `fits`, and `result` is then the mathematical power,
// for the overflow diagnostic.
bit_value_const :: proc(c: ^Compiler, value: Big_Int, type: Type_Id, builtin: Builtin_Kind, allocator: mem.Allocator = {}) -> (result: Const_Value, fits: bool) {
	storage := value_allocator(c, allocator)
	bits := type_bits(c, type)
	signed := type_signed(c, type)
	x := bi_pattern(value, bits)
	#partial switch builtin {
	case .Math_Reverse_Bits:
		reversed := intrinsics.reverse_bits(x) >> uint(128 - bits)
		return integer_const(bi_from_pattern(storage, reversed, bits, signed)), true
	case .Math_Is_Power_Of_Two:
		return bool_const(bi_sign(value) > 0 && intrinsics.count_ones(x) == 1), true
	}
	if bi_cmp(storage, value, bi_from_i64(storage, 1)) <= 0 {
		return integer_const(bi_from_i64(storage, 1)), true
	}
	// `value` is above 1 here, so its pattern is its value.
	exponent := 128 - int(intrinsics.count_leading_zeros(x - 1))
	return integer_const(bi_pow2(storage, exponent)), exponent < bits - (signed ? 1 : 0)
}

// The compile-time value of `core:math.rotate_left` or `rotate_right`
// (`builtin`): `value` of integer type `type` rotated by `count` modulo its
// width, which the floored remainder makes a left rotation for a negative
// right count and the reverse.
rotate_const :: proc(c: ^Compiler, value, count: Big_Int, type: Type_Id, builtin: Builtin_Kind, allocator: mem.Allocator = {}) -> Big_Int {
	storage := value_allocator(c, allocator)
	bits := type_bits(c, type)
	amount, _ := bi_to_i64(storage, count)
	left := int(amount) & (bits - 1)
	if builtin == .Math_Rotate_Right {
		left = (bits - left) % bits
	}
	pattern := bi_wrap(storage, value, bits, false)
	rotated := bi_or(storage, bi_shl(storage, pattern, left), bi_shr(storage, pattern, bits - left))
	return bi_wrap(storage, rotated, bits, type_signed(c, type))
}

value_allocator :: proc(c: ^Compiler, requested: mem.Allocator) -> mem.Allocator {
	return requested.procedure == nil ? c.semantic_allocator : requested
}

fold_arithmetic :: proc(
	c: ^Compiler,
	op: Token_Kind,
	op_span: Span,
	a, b: Const_Value,
	type: Type_Id,
	allocator: mem.Allocator = {},
) -> (Const_Value, bool) {
	switch {
	case a.kind == .Invalid || b.kind == .Invalid:
		// An operand already reported, whose failure is not repeated.
		return Const_Value{}, false
	case a.kind == .String && b.kind == .String && op == .Plus:
		joined, err := strings.concatenate({a.text, b.text}, value_allocator(c, allocator))
		return Const_Value{kind = .String, text = joined}, err == nil
	case a.kind == .Float && b.kind == .Float:
		if result, ok := fold_float(op, a.float, b.float); ok {
			bits := type_is_untyped(c, type) ? 64 : u16(type_bits(c, type))
			return float_const(result, bits), true
		}
	case a.kind == .Boolean && b.kind == .Boolean:
		// design.md "SIMD vectors": bitwise operators apply to `bool` lanes too.
		if result, ok := fold_bool(op, a.boolean, b.boolean); ok {
			return bool_const(result), true
		}
	case const_is_integral(a) && const_is_integral(b):
		if integer_operator(op) {
			result, ok := fold_integer(c, op, op_span, a.integer, b.integer, type, value_allocator(c, allocator))
			return Const_Value{kind = a.kind, integer = result}, ok
		}
	}
	errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
	return Const_Value{}, false
}

@(private = "file")
const_is_integral :: proc(value: Const_Value) -> bool {
	return value.kind == .Integer || value.kind == .Rune
}

// design.md "Floating-point operators": IEEE-754, and no panic.
@(private = "file")
fold_float :: proc(op: Token_Kind, x, y: f64) -> (f64, bool) {
	#partial switch op {
	case .Plus:
		return x + y, true
	case .Minus:
		return x - y, true
	case .Star:
		return x * y, true
	case .Slash:
		return x / y, true
	}
	return 0, false
}

@(private = "file")
fold_bool :: proc(op: Token_Kind, x, y: bool) -> (bool, bool) {
	#partial switch op {
	case .Amp:
		return x && y, true
	case .Pipe:
		return x || y, true
	case .Tilde:
		return x != y, true
	case .Amp_Tilde:
		return x && !y, true
	}
	return false, false
}

@(private = "file")
integer_operator :: proc(op: Token_Kind) -> bool {
	#partial switch op {
	case .Plus, .Plus_Wrap, .Minus, .Minus_Wrap, .Star, .Star_Wrap, .Slash, .Percent,
	     .Amp, .Pipe, .Tilde, .Amp_Tilde, .Shl, .Shr:
		return true
	}
	return false
}

// `op` is an `integer_operator`. Only the operators that can leave `type`'s range
// check or wrap: the rest stay in range for in-range operands.
@(private = "file")
fold_integer :: proc(c: ^Compiler, op: Token_Kind, op_span: Span, x, y: Big_Int, type: Type_Id, storage: mem.Allocator) -> (result: Big_Int, ok: bool) {
	if (op == .Slash || op == .Percent) && bi_is_zero(y) {
		errorf(c, op_span, "L0319", "division by zero")
		return
	}
	#partial switch op {
	case .Plus, .Plus_Wrap:
		result = bi_add(storage, x, y)
	case .Minus, .Minus_Wrap:
		result = bi_sub(storage, x, y)
	case .Star, .Star_Wrap:
		result = bi_mul(storage, x, y)
	case .Slash:
		result = bi_quo(storage, x, y)
	case .Percent:
		result = bi_rem(storage, x, y)
	case .Amp:
		result = bi_and(storage, x, y)
	case .Pipe:
		result = bi_or(storage, x, y)
	case .Tilde:
		result = bi_xor(storage, x, y)
	case .Amp_Tilde:
		result = bi_and_not(storage, x, y)
	case .Shl, .Shr:
		result = fold_shift(c, op, op_span, x, y, type, storage) or_return
	}
	#partial switch op {
	case .Plus, .Minus, .Star, .Slash:
		if !integer_fits(c, result, type, storage) {
			report_integer_overflow(c, op_span, result, type, storage)
			return result, false
		}
	case .Plus_Wrap, .Minus_Wrap, .Star_Wrap, .Shl:
		result = wrap_to_type(c, result, type, storage)
	}
	return result, true
}

// design.md "Integer operators": a shift saturates, so a larger count folds as
// the limit. Only an untyped `<<` grows, up to a storage cap. A negative count,
// which only a signed type holds, panics at run time.
@(private = "file")
fold_shift :: proc(c: ^Compiler, op: Token_Kind, op_span: Span, x, y: Big_Int, type: Type_Id, storage: mem.Allocator) -> (Big_Int, bool) {
	if bi_sign(y) < 0 {
		errorf(c, op_span, "L0356", "a shift count cannot be negative, found %s", bi_text(storage, y))
		return {}, false
	}
	untyped := type_is_untyped(c, type)
	limit := u64(bi_magnitude_bits(storage, x))
	if op == .Shl {
		limit = untyped ? 1 << 20 : u64(type_bits(c, type))
	}
	count, fits := bi_to_u64(storage, y)
	if !fits || count > limit {
		if op == .Shl && untyped {
			errorf(c, op_span, "L0356", "shift count %s is too large to fold", bi_text(storage, y))
			return {}, false
		}
		count = limit
	}
	return op == .Shl ? bi_shl(storage, x, int(count)) : bi_shr(storage, x, int(count)), true
}

// design.md "Integer overflow": a result that does not fit its integer type is
// a compile-time error where a runtime one would panic. An untyped constant is
// exact, and only `+%`, `-%`, and `*%` wrap.
integer_fits :: proc(c: ^Compiler, value: Big_Int, type: Type_Id, allocator: mem.Allocator = {}) -> bool {
	if type_is_untyped(c, type) {
		return true
	}
	bits := type_bits(c, type)
	return bits <= 0 || bi_fits(value_allocator(c, allocator), value, bits, type_signed(c, type))
}

report_integer_overflow :: proc(c: ^Compiler, span: Span, value: Big_Int, type: Type_Id, allocator: mem.Allocator = {}) {
	errorf(
		c, span, "L0397", "%s overflow: the result %s does not fit `%s`",
		type_signed(c, type) ? "signed" : "unsigned",
		bi_text(value_allocator(c, allocator), value), type_name(c, type),
	)
}

// design.md "Integer overflow": a typed result keeps the low bits of its
// width, as `+%`, `<<`, and `math.wrap` do; an untyped one stays exact.
wrap_to_type :: proc(c: ^Compiler, value: Big_Int, type: Type_Id, allocator: mem.Allocator = {}) -> Big_Int {
	if type_is_untyped(c, type) {
		return value
	}
	bits := type_bits(c, type)
	if bits <= 0 {
		return value
	}
	return bi_wrap(value_allocator(c, allocator), value, bits, type_signed(c, type))
}

fold_comparison :: proc(c: ^Compiler, op: Token_Kind, a, b: Const_Value, allocator: mem.Allocator = {}) -> (bool, bool) {
	storage := value_allocator(c, allocator)
	order := 0
	switch {
	case a.kind == .String || b.kind == .String:
		if a.kind != .String || b.kind != .String {
			return false, false
		}
		// Byte order. The empty string may have no storage at all, which
		// `strings.compare` orders first.
		order = len(a.text) == 0 && len(b.text) == 0 ? 0 : strings.compare(a.text, b.text)
	case a.kind == .Float && b.kind == .Float:
		// NaN compares false against everything, including itself.
		if a.float != a.float || b.float != b.float {
			return op == .Not_Eq, true
		}
		order = a.float < b.float ? -1 : (a.float > b.float ? 1 : 0)
	case a.kind == .Float || b.kind == .Float:
		// Integer against float, compared exactly.
		float, integer := a, b
		if b.kind == .Float {
			float, integer = b, a
		}
		if !const_is_integral(integer) {
			return false, false
		}
		if float.float != float.float {
			return op == .Not_Eq, true
		}
		order = bi_cmp_float(storage, integer.integer, float.float)
		if a.kind == .Float {
			order = -order
		}
	case const_is_integral(a) && const_is_integral(b):
		order = bi_cmp(storage, a.integer, b.integer)
	case a.kind == .Boolean:
		if b.kind != .Boolean {
			return false, false
		}
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		return (a.boolean == b.boolean) == (op == .Eq_Eq), true
	case a.kind == .Nil && b.kind == .Nil:
		return op == .Eq_Eq, true
	case a.kind == .Type && b.kind == .Type:
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		equal, known := type_consts_equal(storage, a, b)
		return equal == (op == .Eq_Eq), known
	case a.kind == .Aggregate && b.kind == .Aggregate:
		if op != .Eq_Eq && op != .Not_Eq {
			return aggregate_order(c, op, a.aggregate, b.aggregate, storage)
		}
		equal, known := aggregate_equal(c, a.aggregate, b.aggregate, storage)
		return equal == (op == .Eq_Eq), known
	case:
		return false, false
	}

	#partial switch op {
	case .Eq_Eq:
		return order == 0, true
	case .Not_Eq:
		return order != 0, true
	case .Lt:
		return order < 0, true
	case .Lt_Eq:
		return order <= 0, true
	case .Gt:
		return order > 0, true
	case .Gt_Eq:
		return order >= 0, true
	}
	return false, false
}

// Unknown while a `typeid` part awaits its number (`type_consts_equal`), and then
// only if no other part already differs; and for a count the run-time comparison
// panics on.
@(private = "file")
aggregate_equal :: proc(c: ^Compiler, a, b: ^Const_Aggregate, allocator: mem.Allocator) -> (equal: bool, known: bool) {
	if a == nil || b == nil || len(a.elements) != len(b.elements) {
		return false, true
	}
	// design.md "Unions": equal values hold the same variant.
	if type_is_union(c, a.type) {
		if a.variant != b.variant {
			return false, true
		}
		if union_variant_payload(c, a.type, a.variant) == TYPE_VOID {
			return true, true
		}
	}
	deferred := false
	info := underlying_info(c, a.type)
	for element, index in a.elements {
		other := b.elements[index]
		field := info != nil && info.kind == .Struct ? symbol_of(c, info.fields[index]) : nil
		// design.md "Uninitialized capacity": only the live prefix has values.
		if counter := field != nil ? symbol_of(c, field.initialized_by) : nil; counter != nil {
			if element.aggregate == nil || other.aggregate == nil {
				return false, false
			}
			live, live_ok := common_live_count(
				allocator, a.elements[counter.index].integer, b.elements[counter.index].integer,
				len(element.aggregate.elements), len(other.aggregate.elements),
			)
			if !live_ok {
				return false, false
			}
			for at in 0 ..< live {
				if !part_equal(c, element.aggregate.elements[at], other.aggregate.elements[at], allocator, &deferred) {
					return false, true
				}
			}
			continue
		}
		if !part_equal(c, element, other, allocator, &deferred) {
			return false, true
		}
	}
	if deferred {
		return false, false
	}
	return true, true
}

// design.md "Uninitialized capacity": how many elements of two `@(initialized)`
// arrays both hold values, and not `ok` when either count is outside `0 ..= N`,
// which equality panics on.
common_live_count :: proc(storage: Value_Storage, a_count, b_count: Big_Int, a_capacity, b_capacity: int) -> (live: int, ok: bool) {
	a, a_ok := bi_to_i64(storage, a_count)
	b, b_ok := bi_to_i64(storage, b_count)
	if !a_ok || !b_ok || a < 0 || b < 0 || a > i64(a_capacity) || b > i64(b_capacity) {
		return 0, false
	}
	return int(min(a, b)), true
}

// Whether a pair of parts may be equal; a pair awaiting a `typeid` number sets
// `deferred`. Any other pair a constant cannot compare counts as a difference.
@(private = "file")
part_equal :: proc(c: ^Compiler, a, b: Const_Value, allocator: mem.Allocator, deferred: ^bool) -> bool {
	equal, ok := fold_comparison(c, .Eq_Eq, a, b, allocator)
	// Between two `type` or two aggregate constants, `==` is unknown only then.
	if !ok && (a.kind == .Type || a.kind == .Aggregate) && a.kind == b.kind {
		deferred^ = true
		return true
	}
	return ok && equal
}

// design.md "Comparison operators": an anonymous record orders by its first
// unequal field, and equal records answer `<=` and `>=`.
@(private = "file")
aggregate_order :: proc(c: ^Compiler, op: Token_Kind, a, b: ^Const_Aggregate, allocator: mem.Allocator) -> (bool, bool) {
	if a == nil || b == nil || len(a.elements) != len(b.elements) || !type_is_ordered(c, a.type) {
		return false, false
	}
	for element, index in a.elements {
		other := b.elements[index]
		equal, ok := fold_comparison(c, .Eq_Eq, element, other, allocator)
		if !ok {
			return false, false
		}
		if equal {
			continue
		}
		if op == .Gt || op == .Gt_Eq {
			return fold_comparison(c, .Lt, other, element, allocator)
		}
		return fold_comparison(c, .Lt, element, other, allocator)
	}
	return op == .Lt_Eq || op == .Gt_Eq, true
}

// ---------------------------------------------------- bit reinterpretation --

Const_Pattern :: enum {
	Folded,
	// Not a value of the type at all.
	Invalid,
	// Reads padding, whose bits no value put there.
	Padding,
	// Valid, but with no compile-time storage (a pointer, a union, a record
	// with uninitialized capacity, or a `typeid_of(T)` not yet numbered).
	Unfoldable,
}

// design.md "`unsafe.transmute`" at compile time: the constant's storage, read
// back as `target`. The result is built in `allocator`, the evaluator's scratch
// when it asks.
transmute_const :: proc(c: ^Compiler, value: Const_Value, source, target: Type_Id, allocator: mem.Allocator = {}) -> (Const_Value, Const_Pattern) {
	size := int(type_size(c, source))
	bytes := make([]u8, size)
	defer delete(bytes)
	written := make([]bool, size)
	defer delete(written)
	if !const_storage(c, value, source, bytes, written) {
		return {}, .Unfoldable
	}
	return const_from_storage(c, value_allocator(c, allocator), bytes, written, target)
}

// Where the `index`th member of an array, vector, or struct sits in its storage.
// A field `initialized_by` another has no compile-time storage.
@(private = "file")
storage_member :: proc(c: ^Compiler, type: Type_Id, info: ^Type_Info, index: int) -> (member: Type_Id, at, end: int, ok: bool) {
	if info.kind != .Struct {
		step := int(type_size(c, info.element))
		return info.element, index * step, (index + 1) * step, true
	}
	field := symbol_of(c, info.fields[index])
	if field == nil || field.initialized_by != INVALID_SYMBOL {
		return
	}
	at = int(type_field_offset(c, type, index))
	return field.type, at, at + int(type_size(c, field.type)), true
}

// Little-endian, like every target. `written` marks the bytes a value occupies,
// so padding stays unwritten.
@(private = "file")
const_storage :: proc(c: ^Compiler, value: Const_Value, type: Type_Id, bytes: []u8, written: []bool) -> bool {
	info := underlying_info(c, type)
	if info == nil {
		return false
	}
	pattern: u128
	#partial switch info.kind {
	case .Float:
		if value.kind != .Float {
			return false
		}
		pattern = u128(const_float_pattern(value, info.bits))
	case .Bool:
		if value.kind != .Boolean {
			return false
		}
		pattern = value.boolean ? 1 : 0
	case .Int, .Rune, .Enum:
		if value.kind != .Integer && value.kind != .Rune {
			return false
		}
		pattern = bi_pattern(value.integer, len(bytes) * 8)
	case .Typeid:
		// design.md "`type` and `typeid`": a `typeid_of(T)` has no number until
		// `freeze_typeids` gives it one, and folding it now would fix one that
		// emission might not agree with.
		number, known := typeid_const_number(c, value)
		if !known {
			return false
		}
		pattern = u128(number)
	case .Array, .Simd, .Struct:
		count := info.kind == .Struct ? len(info.fields) : int(info.count)
		if value.kind != .Aggregate || value.aggregate == nil || len(value.aggregate.elements) != count {
			return false
		}
		for element, index in value.aggregate.elements {
			member, at, end, ok := storage_member(c, type, info, index)
			if !ok || !const_storage(c, element, member, bytes[at:end], written[at:end]) {
				return false
			}
		}
		return true
	case:
		return false
	}
	for index in 0 ..< len(bytes) {
		bytes[index], written[index] = u8(pattern), true
		pattern >>= 8
	}
	return true
}

@(private = "file")
const_from_storage :: proc(c: ^Compiler, storage: mem.Allocator, bytes: []u8, written: []bool, type: Type_Id) -> (Const_Value, Const_Pattern) {
	info := underlying_info(c, type)
	if info == nil {
		return {}, .Unfoldable
	}
	#partial switch info.kind {
	case .Float, .Bool, .Int, .Rune, .Enum, .Typeid:
		raw: u128
		for index := len(bytes) - 1; index >= 0; index -= 1 {
			if !written[index] {
				return {}, .Padding
			}
			raw = raw << 8 | u128(bytes[index])
		}
		#partial switch info.kind {
		case .Float:
			return float_bits_const(u64(raw), info.bits), .Folded
		case .Bool:
			if raw > 1 {
				return {}, .Invalid
			}
			return bool_const(raw != 0), .Folded
		case .Int:
			return integer_const(bi_from_pattern(storage, raw, int(info.bits), info.signed)), .Folded
		case .Rune:
			// design.md "Invalid representations": every 32-bit pattern is a `rune`.
			return rune_const(bi_from_pattern(storage, raw, 32, true)), .Folded
		case .Typeid:
			// design.md "Invalid representations": and every pattern a `typeid`.
			return typeid_number_const(storage, u64(raw)), .Folded
		case .Enum:
			candidate := integer_const(bi_from_pattern(storage, raw, int(info.bits), info.signed))
			if enum_member_by_value(c, type, candidate) == INVALID_SYMBOL {
				return {}, .Invalid
			}
			return candidate, .Folded
		}
	case .Array, .Simd, .Struct:
		count := info.kind == .Struct ? len(info.fields) : int(info.count)
		elements, refused := make([]Const_Value, count, storage)
		aggregate, unavailable := new(Const_Aggregate, storage)
		if refused != nil || unavailable != nil {
			return {}, .Unfoldable
		}
		for index in 0 ..< count {
			member, at, end, ok := storage_member(c, type, info, index)
			if !ok {
				return {}, .Unfoldable
			}
			element, status := const_from_storage(c, storage, bytes[at:end], written[at:end], member)
			if status != .Folded {
				return {}, status
			}
			elements[index] = element
		}
		aggregate.type = type
		aggregate.elements = elements
		return Const_Value{kind = .Aggregate, type_value = type, aggregate = aggregate}, .Folded
	}
	return {}, .Unfoldable
}

// Converts a constant to a target type. Only an `explicit` `T(v)` turns a float
// into an integer, truncating it; an implicit conversion refuses even an
// integral float.
convert_const :: proc(c: ^Compiler, value: Const_Value, target: Type_Id, explicit: bool, allocator: mem.Allocator = {}) -> (Const_Value, bool) {
	storage := value_allocator(c, allocator)
	info := underlying_info(c, target)
	if info == nil {
		return value, false
	}
	// A typed zero such as an empty slice shares `.Nil` with the written `nil`;
	// the sites converting an untyped constant refuse `nil` for other types.
	if value.kind == .Nil {
		return value, info.kind == .Untyped_Nil || type_accepts_nil(c, target) || zero_is_nil(c, target)
	}
	#partial switch info.kind {
	case .Untyped_Int, .Untyped_Rune:
		if value.kind == .Integer || value.kind == .Rune {
			return Const_Value{kind = info.kind == .Untyped_Rune ? .Rune : .Integer, integer = value.integer}, true
		}
	case .Untyped_Float:
		if value.kind == .Float {
			return value, true
		}
		if value.kind == .Integer || (value.kind == .Rune && explicit) {
			converted, fits := bi_to_float(storage, value.integer, 64)
			return fits ? float_const(converted, 64) : value, fits
		}
	case .Untyped_Bool, .Bool:
		if value.kind == .Boolean {
			return value, true
		}
	case .Untyped_String, .CString_View:
		if value.kind == .String {
			return value, true
		}
	// A `string` always holds valid UTF-8 (design.md "string type"). It is checked
	// after folding, so `"\xc3" + "\xa9"` is the `é` it spells.
	case .String, .String_View:
		if value.kind == .String {
			return value, utf8.valid_string(value.text)
		}
	case .Enum:
		// Retyping a constant must never manufacture a non-variant. Source-type
		// checks at conversion and generic-binding sites enforce enum identity.
		return value, value.kind == .Integer && enum_member_by_value(c, target, value) != INVALID_SYMBOL
	case .Int:
		bits, signed := type_bits(c, target), type_signed(c, target)
		#partial switch value.kind {
		case .Integer, .Rune:
			if !bi_fits(storage, value.integer, bits, signed) {
				return value, false
			}
			return Const_Value{kind = .Integer, integer = value.integer}, true
		case .Float:
			// design.md "Implicit type conversions": a float never becomes an
			// integer implicitly, even when it is integral.
			if !explicit {
				return value, false
			}
			// The interval the runtime conversion checks (design.md "Type
			// conversion"); NaN and infinities fail it.
			limit := power_of_two(int(bits) - (signed ? 1 : 0))
			if !(value.float >= (signed ? -limit : 0) && value.float < limit) {
				return value, false
			}
			truncated, _, ok := bi_from_f64_trunc(storage, value.float)
			if !ok {
				return value, false
			}
			if !bi_fits(storage, truncated, bits, signed) {
				return value, false
			}
			return Const_Value{kind = .Integer, integer = truncated}, true
		}
	case .Rune:
		#partial switch value.kind {
		case .Integer, .Rune:
			if !bi_fits(storage, value.integer, 32, true) {
				return value, false
			}
			return Const_Value{kind = .Rune, integer = value.integer}, true
		}
	case .Float:
		#partial switch value.kind {
		case .Float:
			// Kept as is, so a signalling NaN is not quieted.
			if value.float_bits == info.bits {
				return value, true
			}
			// design.md "Number literals": a finite constant may not round to an
			// infinity. A literal's decimal value is rounded once, not through f64.
			converted := float_const(value.float, info.bits)
			if exact, exact_ok := decimal_to_float(storage, value.text, info.bits); exact_ok {
				converted = float_const(exact, info.bits)
			}
			return converted, !math.is_inf(converted.float) || math.is_inf(value.float)
		case .Integer, .Rune:
			// design.md "Implicit type conversions": a rune constant never
			// becomes a float implicitly.
			if value.kind == .Rune && !explicit {
				return value, false
			}
			converted, fits := bi_to_float(storage, value.integer, info.bits)
			return fits ? float_const(converted, info.bits) : value, fits
		}
	case .Typeid, .Type:
		// A folded `typeid_of(T)` keeps the type it identifies; the value's own
		// type, checked before this, is what separates it from a type.
		if value.kind == .Type {
			return value, true
		}
	case .Simd:
		// design.md "SIMD vectors": each lane converts as a scalar would, and a
		// scalar splats into every lane.
		if value.kind == .Aggregate {
			if value.aggregate == nil || len(value.aggregate.elements) != int(info.count) {
				return value, false
			}
			if value.aggregate.type == target {
				return value, true
			}
		}
		elements := make([]Const_Value, info.count, storage)
		for index in 0 ..< int(info.count) {
			lane := value
			if value.kind == .Aggregate {
				lane = value.aggregate.elements[index]
			}
			converted, fits := convert_const(c, lane, info.element, explicit, allocator)
			if !fits {
				return value, false
			}
			elements[index] = converted
		}
		aggregate := new(Const_Aggregate, storage)
		aggregate.type = target
		aggregate.elements = elements
		return Const_Value{kind = .Aggregate, aggregate = aggregate}, true
	case .Struct, .Array, .Union, .Dynamic_Array, .Map:
		return retype_aggregate(c, value, target, explicit, storage)
	}
	return value, false
}

// A struct, array, union, or empty container constant keeps its representation when it converts
// to its own type, when a labelled record drops its labels, or, written out,
// between a distinct type and its underlying one (design.md "Distinct types").
@(private = "file")
retype_aggregate :: proc(c: ^Compiler, value: Const_Value, target: Type_Id, explicit: bool, storage: mem.Allocator) -> (Const_Value, bool) {
	if value.kind != .Aggregate || value.aggregate == nil {
		return value, false
	}
	source := value.aggregate.type
	if source == target {
		return value, true
	}
	relabelled := record_drops_labels_to(c, source, target)
	if union_widens_to(c, source, target) {
		return widen_const(c, value, source, target, storage), true
	}
	if !relabelled && (!explicit || type_underlying(c, source) != type_underlying(c, target)) {
		return value, false
	}
	retyped := new_clone(value.aggregate^, storage)
	retyped.type = target
	return Const_Value{kind = .Aggregate, aggregate = retyped}, true
}

// Is `.Nil` the zero value of `type`? A reference's zero_const is `.Nil` too,
// but a reference has no zero.
@(private = "file")
zero_is_nil :: proc(c: ^Compiler, type: Type_Id) -> bool {
	zero, ok := zero_const(c, type, false)
	return ok && zero.kind == .Nil && type_has_zero(c, type)
}
