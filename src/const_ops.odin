// Constant values and their arithmetic, shared by the checker and the
// compile-time evaluator so both fold identically. `src/bigint.odin` is the
// arbitrary-precision integer half.
package lokec

import "core:mem"
import "core:strings"

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

// design.md "Type conversion": the bounds of a float-to-integer conversion are
// powers of two, so one interval serves every float width — the value is exact
// in any format that can hold it and an infinity in one that cannot.
power_of_two :: proc(exponent: int) -> f64 {
	out := f64(1)
	for _ in 0 ..< exponent {
		out *= 2
	}
	return out
}

// A typed float operation rounds to its own width after every step: folding an
// `f32` expression in `f64` and rounding once at the end can disagree with what
// the same expression computes at runtime.
round_float :: proc(value: f64, bits: u16) -> f64 {
	switch bits {
	case 16:
		return f16_bits_to_f64(f64_to_f16_bits(value))
	case 32:
		return f64(f32(value))
	}
	return value
}

// The IEEE-754 encoding of a value already rounded to `bits`, and its inverse.
float_pattern :: proc(value: f64, bits: u16) -> u64 {
	switch bits {
	case 16:
		return u64(f64_to_f16_bits(value))
	case 32:
		return u64(transmute(u32)f32(value))
	}
	return transmute(u64)value
}

float_from_pattern :: proc(raw: u64, bits: u16) -> f64 {
	switch bits {
	case 16:
		return f16_bits_to_f64(u16(raw))
	case 32:
		return f64(transmute(f32)u32(raw))
	}
	return transmute(f64)raw
}

// A Float carries the exact pattern of the width it was rounded to; any other
// width re-encodes from the numeric field.
const_float_pattern :: proc(value: Const_Value, bits: u16) -> u64 {
	if value.float_bits == bits {
		return value.float_raw
	}
	return float_pattern(value.float, bits)
}

// IEEE-754 binary16, rounding to nearest with ties to even. Odin's own `f16(x)`
// rounds halfway cases away from zero — it turns 2049 into 2050 where the
// hardware `fadd half` LLVM emits produces 2048, which would make a folded
// `f16` constant disagree with the runtime expression.
f64_to_f16_bits :: proc(value: f64) -> u16 {
	pattern := transmute(u64)value
	sign := u16((pattern >> 48) & 0x8000)
	exponent := int((pattern >> 52) & 0x7ff)
	mantissa := pattern & 0x000f_ffff_ffff_ffff

	if exponent == 0x7ff {
		return mantissa != 0 ? sign | 0x7e00 : sign | 0x7c00 // NaN, or infinity
	}
	if exponent == 0 {
		return sign // zero, or an f64 subnormal, far below f16's range
	}

	unbiased := exponent - 1023
	if unbiased > 15 {
		return sign | 0x7c00 // beyond f16's largest finite value
	}
	significand := mantissa | (u64(1) << 52) // 53 bits, implicit bit included
	target_exponent := unbiased + 15
	shift := 42 // 52 explicit bits down to f16's 10
	if target_exponent <= 0 {
		// An f16 subnormal: the implicit bit moves into the stored mantissa.
		shift = 43 - target_exponent
		if shift > 63 {
			return sign
		}
		target_exponent = 0
	}

	dropped := significand & ((u64(1) << u64(shift)) - 1)
	result := significand >> u64(shift)
	halfway := u64(1) << u64(shift - 1)
	if dropped > halfway || (dropped == halfway && (result & 1) != 0) {
		result += 1
	}
	if target_exponent == 0 {
		// Rounding may have carried a subnormal up to the smallest normal, whose
		// encoding is the next value in sequence; no special case is needed.
		return sign | u16(result)
	}
	if result >= (u64(1) << 11) {
		result >>= 1
		target_exponent += 1
		if target_exponent >= 31 {
			return sign | 0x7c00
		}
	}
	return sign | u16(u64(target_exponent) << 10) | u16(result & 0x3ff)
}

f16_bits_to_f64 :: proc(bits: u16) -> f64 {
	sign := u64(bits & 0x8000) << 48
	exponent := int((bits >> 10) & 0x1f)
	mantissa := u64(bits & 0x3ff)

	switch {
	case exponent == 0x1f:
		pattern := sign | 0x7ff0_0000_0000_0000 | (mantissa != 0 ? u64(0x0008_0000_0000_0000) : 0)
		return transmute(f64)pattern
	case exponent == 0 && mantissa == 0:
		return transmute(f64)sign
	case exponent == 0:
		// Subnormal: `mantissa * 2^-24`, exact in f64 both times.
		magnitude := f64(mantissa) / 16777216.0
		return sign != 0 ? -magnitude : magnitude
	}
	pattern := sign | (u64(exponent - 15 + 1023) << 52) | (mantissa << 42)
	return transmute(f64)pattern
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
	storage := value_allocator(c, allocator)
	// design.md "SIMD vectors": operators apply lane-wise.
	if info := underlying_info(c, type); info != nil && info.kind == .Simd {
		return fold_simd_lanes(c, op, op_span, a, b, type, info, allocator)
	}
	if a.kind == .String || b.kind == .String {
		// Only `+` applies to compile-time strings.
		if op != .Plus || a.kind != .String || b.kind != .String {
			errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
			return Const_Value{}, false
		}
		joined, err := strings.concatenate({a.text, b.text}, storage)
		return Const_Value{kind = .String, text = joined}, err == nil
	}

	if a.kind == .Float || b.kind == .Float {
		bits := u16(type_bits(c, type))
		if type_is_untyped(c, type) {
			bits = 64
		}
		x, y := a.float, b.float
		result: f64
		#partial switch op {
		case .Plus:
			result = x + y
		case .Minus:
			result = x - y
		case .Star:
			result = x * y
		case .Slash:
			// design.md "Floating-point operators": IEEE-754, and no panic.
			result = x / y
		case:
			errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
			return Const_Value{}, false
		}
		return float_const(result, bits), true
	}

	// design.md "SIMD vectors": bitwise operators apply to `bool` lanes too.
	if a.kind == .Boolean || b.kind == .Boolean {
		if a.kind != .Boolean || b.kind != .Boolean {
			errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
			return Const_Value{}, false
		}
		#partial switch op {
		case .Amp:
			return bool_const(a.boolean && b.boolean), true
		case .Pipe:
			return bool_const(a.boolean || b.boolean), true
		case .Tilde:
			return bool_const(a.boolean != b.boolean), true
		case .Amp_Tilde:
			return bool_const(a.boolean && !b.boolean), true
		}
		errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
		return Const_Value{}, false
	}

	if (op == .Slash || op == .Percent) && bi_is_zero(b.integer) {
		errorf(c, op_span, "L0319", "division by zero")
		return Const_Value{}, false
	}

	x, y := a.integer, b.integer
	result: Big_Int
	#partial switch op {
	case .Plus:
		result = bi_add(storage, x, y)
	case .Minus:
		result = bi_sub(storage, x, y)
	case .Star:
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
		// design.md "Integer operators": a shift saturates, so a larger count folds
		// as the limit. Only an untyped `<<` grows, up to a storage cap.
		untyped := type_is_untyped(c, type)
		limit := u64(bi_magnitude_bits(storage, x))
		if op == .Shl {
			limit = untyped ? 1 << 20 : u64(type_bits(c, type))
		}
		count, fits := bi_to_u64(storage, y)
		if !fits || count > limit {
			if op == .Shl && untyped {
				errorf(c, op_span, "L0356", "shift count %s is too large to fold", bi_text(storage, y))
				return Const_Value{}, false
			}
			count = limit
		}
		result = op == .Shl ? bi_shl(storage, x, int(count)) : bi_shr(storage, x, int(count))
	case:
		errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
		return Const_Value{}, false
	}
	return Const_Value{kind = a.kind, integer = wrap_to_type(c, result, type, storage)}, true
}

// design.md "Integer overflow": a typed result wraps to its width; an untyped
// one stays exact.
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
		// Byte order.
		order = strings.compare(a.text, b.text)
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
		if integer.kind != .Integer && integer.kind != .Rune {
			return false, false
		}
		if float.float != float.float {
			return op == .Not_Eq, true
		}
		order = bi_cmp_float(storage, integer.integer, float.float)
		if a.kind == .Float {
			order = -order
		}
	case a.kind == .Integer || a.kind == .Rune:
		if b.kind != .Integer && b.kind != .Rune {
			return false, false
		}
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
	// Type identity after aliases are resolved.
	case a.kind == .Type && b.kind == .Type:
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		return (a.type_value == b.type_value) == (op == .Eq_Eq), true
	case a.kind == .Aggregate && b.kind == .Aggregate:
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		equal := aggregate_equal(c, a.aggregate, b.aggregate, storage)
		return equal == (op == .Eq_Eq), true
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

@(private = "file")
aggregate_equal :: proc(c: ^Compiler, a, b: ^Const_Aggregate, allocator: mem.Allocator = {}) -> bool {
	if a == nil || b == nil || len(a.elements) != len(b.elements) {
		return false
	}
	// design.md "Unions": equal values hold the same variant.
	if type_is_union(c, a.type) {
		if a.variant != b.variant {
			return false
		}
		if union_variant_payload(c, a.type, a.variant) == TYPE_VOID {
			return true
		}
	}
	info := underlying_info(c, a.type)
	for element, index in a.elements {
		other := b.elements[index]
		field := info != nil && info.kind == .Struct ? symbol_of(c, info.fields[index]) : nil
		// design.md "Uninitialized capacity": only the live prefix has values.
		if counter := field != nil ? symbol_of(c, field.initialized_by) : nil; counter != nil {
			live, live_ok := bi_to_i64(allocator, a.elements[counter.index].integer)
			if !live_ok || live < 0 || element.aggregate == nil || other.aggregate == nil ||
			   live > i64(min(len(element.aggregate.elements), len(other.aggregate.elements))) {
				return false
			}
			for at in 0 ..< int(live) {
				equal, ok := fold_comparison(c, .Eq_Eq, element.aggregate.elements[at], other.aggregate.elements[at], allocator)
				if !ok || !equal {
					return false
				}
			}
			continue
		}
		equal, ok := fold_comparison(c, .Eq_Eq, element, other, allocator)
		if !ok || !equal {
			return false
		}
	}
	return true
}

// One lane at a time at the element type. A non-aggregate operand is a
// splatted scalar.
@(private = "file")
fold_simd_lanes :: proc(
	c: ^Compiler,
	op: Token_Kind,
	op_span: Span,
	a, b: Const_Value,
	type: Type_Id,
	info: ^Type_Info,
	allocator: mem.Allocator,
) -> (Const_Value, bool) {
	lane :: proc(value: Const_Value, index: int) -> Const_Value {
		if value.kind != .Aggregate || value.aggregate == nil {
			return value
		}
		return index < len(value.aggregate.elements) ? value.aggregate.elements[index] : Const_Value{}
	}
	elements := make([]Const_Value, info.count, value_allocator(c, allocator))
	for index in 0 ..< int(info.count) {
		folded, ok := fold_arithmetic(
			c, op, op_span, lane(a, index), lane(b, index), info.element, allocator,
		)
		if !ok {
			return Const_Value{}, false
		}
		elements[index] = folded
	}
	aggregate := new(Const_Aggregate, value_allocator(c, allocator))
	aggregate.type = type
	aggregate.elements = elements
	return Const_Value{kind = .Aggregate, aggregate = aggregate}, true
}
