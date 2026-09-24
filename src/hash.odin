// The compiler-contributed `hash` for design.md's `Hashable` catalogue, and map
// key policies. The mix is 64-bit FNV-1a's step per scalar, folded over arrays;
// the compile-time and runtime paths must agree exactly.
//
// ponytail: one non-seeded mixing constant. The per-table seed threaded through
// `hash` varies the result between tables; a per-*process* seed, which a
// hash-flooding defence needs, is not derived here.
package lokec

import "core:mem"

// The 64-bit FNV prime.
HASH_MULTIPLIER :: u64(1099511628211)

// design.md: `bool`, integers, runes, `string`, `string_view`, pointers,
// enums, `typeid`, and fixed arrays of hashable elements. Not floats: NaN is
// unequal to itself, so no `==` over floats is coherent with any hash.
type_is_hashable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Bool, .Int, .Rune, .Enum, .Typeid,
	     .Raw_Pointer, .Pointer, .C_Pointer,
	     .String, .String_View,
	     .Untyped_Int, .Untyped_Bool, .Untyped_Rune, .Untyped_String:
		return true
	case .Array:
		return type_is_hashable(c, info.element)
	}
	return false
}

// A float, or a fixed array of them, as `type_is_hashable` excludes.
@(private = "file")
type_holds_float :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := type_of(c, type_underlying(c, id))
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Float, .Untyped_Float:
		return true
	case .Array:
		return type_holds_float(c, info.element)
	}
	return false
}

// design.md "Maps": the compiler supplies a key's `==`/`hash` pair, or the key
// type declares both inherently; extensions never count.
Key_Policy_Kind :: enum { Unresolved, Builtin, Inherent }

// Chosen during checking and read by CTFE and the backend.
Key_Policy :: struct {
	kind:      Key_Policy_Kind,
	hash:      Symbol_Id,
	equal:     Symbol_Id,
}

// Checking is the only phase allowed to select a policy. Failed lookups are not
// cached: discovery may still be installing inherent members.
resolve_map_key_policy :: proc(c: ^Compiler, key: Type_Id) -> (Key_Policy, string) {
	if key == INVALID_TYPE {
		return Key_Policy{}, "is not a type"
	}
	hash := inherent_member_named(c, key, "hash")
	equal := inherent_operator_named(c, key, "==")
	// Declaring either half opts out of the catalogue, so a `distinct` scalar
	// never pairs its own `==` with its underlying type's hash.
	if hash == INVALID_SYMBOL && equal == INVALID_SYMBOL {
		if type_is_hashable(c, key) {
			return Key_Policy{kind = .Builtin}, ""
		}
		if type_holds_float(c, key) {
			return Key_Policy{}, "holds a float, and NaN never equals itself, so no float is hashable; key by an integer image of the value instead"
		}
		return Key_Policy{}, "needs an inherent `==` and `value.hash(seed: uint) -> uint` pair in its own package"
	}
	if hash == INVALID_SYMBOL {
		return Key_Policy{}, "has an inherent `==` but no inherent `hash`"
	}
	if equal == INVALID_SYMBOL {
		return Key_Policy{}, "has an inherent `hash` but no inherent `==`"
	}
	return Key_Policy{kind = .Inherent, hash = hash, equal = equal}, ""
}

// An inherent `hash` is called with the map's own key storage and a seed, so it
// borrows its receiver and has exactly the protocol's shape.
key_hash_signature_ok :: proc(sym: ^Symbol, key: Type_Id) -> bool {
	return sym.has_receiver && (sym.receiver == .Borrow || sym.receiver == .Value) && sym.result == TYPE_UINT &&
		len(sym.params) == 2 && sym.params[0] == key && sym.params[1] == TYPE_UINT
}

// The key type's own non-synthesized member; a `distinct` type inherits none.
@(private = "file")
inherent_member_named :: proc(c: ^Compiler, type: Type_Id, name: string) -> Symbol_Id {
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL
	}
	wanted := intern_identifier(c, name)
	for member in info.members {
		sym := symbol_of(c, member)
		if sym != nil && sym.name == wanted && sym.kind == .Proc && sym.operator == "" &&
		   sym.synth == .None {
			return member
		}
	}
	return INVALID_SYMBOL
}

@(private = "file")
inherent_operator_named :: proc(c: ^Compiler, type: Type_Id, symbol_text: string) -> Symbol_Id {
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL
	}
	for member in info.members {
		sym := symbol_of(c, member)
		// A delegated `==` keeps the underlying type's policy.
		if sym != nil && sym.operator == symbol_text && !sym.delegated && operator_on_self(sym, type) {
			return member
		}
	}
	return INVALID_SYMBOL
}

// --------------------------------------------------------- compile time --

// The integer image of one scalar, which is what the mix consumes.
hash_scalar_bits :: proc(c: ^Compiler, value: Const_Value, type: Type_Id, allocator: mem.Allocator = {}) -> u64 {
	under := type_underlying(c, type)
	#partial switch type_kind(c, under) {
	case .Bool, .Untyped_Bool:
		return value.boolean ? 1 : 0
	case .Raw_Pointer, .Pointer, .C_Pointer:
		return 0 // the only compile-time pointer constant is nil
	}
	storage := value_allocator(c, allocator)
	wrapped := bi_wrap(storage, value.integer, 64, false)
	bits, _ := bi_to_u64(storage, wrapped)
	return bits
}

hash_const :: proc(c: ^Compiler, value: Const_Value, type: Type_Id, seed: u64, allocator: mem.Allocator = {}) -> u64 {
	under := type_underlying(c, type)
	info := type_of(c, under)
	#partial switch type_kind(c, under) {
	case .String, .String_View, .Untyped_String:
		// As `loke_rt_v1_hash_bytes`: the bytes, then the length, so the elements
		// of `{"ab", ""}` and `{"a", "b"}` do not hash alike.
		result := seed
		for index in 0 ..< len(value.text) {
			result = (result ~ u64(value.text[index])) * HASH_MULTIPLIER
		}
		return (result ~ u64(len(value.text))) * HASH_MULTIPLIER
	}
	if info != nil && info.kind == .Array {
		result := seed
		for index in 0 ..< int(info.count) {
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			result = hash_const(c, element, info.element, result, allocator)
		}
		return result
	}
	return (seed ~ hash_scalar_bits(c, value, type, allocator)) * HASH_MULTIPLIER
}
