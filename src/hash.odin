// The compiler-contributed `hash` for design.md's `Hashable` catalogue, and map
// key policies. The mix is 64-bit FNV-1a's step per scalar, folded over arrays;
// the compile-time and runtime paths must agree exactly.
//
// ponytail: one non-seeded mixing constant. The per-table seed threaded through
// `hash` varies the result between tables; a per-*process* seed, which a
// hash-flooding defence needs, is not derived here.
package lokec

import "core:fmt"
import "core:mem"

// The 64-bit FNV prime.
HASH_MULTIPLIER :: u64(1099511628211)

// design.md: `bool`, integers, runes, `string`, `string_view`, pointers,
// enums, `typeid`, and fixed arrays of hashable elements. Not floats: NaN is
// unequal to itself, so no `==` over floats is coherent with any hash. A
// record or union that keeps its generated `==` hashes structurally too
// (design.md "Maps"), part by part.
type_is_hashable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	seen: Type_Walk
	defer delete(seen)
	return type_is_hashable_walk(c, id, &seen)
}

// Guarded because a record diagnosed as containing itself still reaches
// body checking.
@(private = "file")
type_is_hashable_walk :: proc(c: ^Compiler, id: Type_Id, seen: ^Type_Walk) -> bool {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Enum:
		return record_hashes_structurally(c, id, under, info)
	case .Bool, .Int, .Rune, .Typeid,
	     .Raw_Pointer, .Pointer, .C_Pointer,
	     .String, .String_View,
	     .Untyped_Int, .Untyped_Bool, .Untyped_Rune, .Untyped_String:
		return true
	case .Array:
		return part_is_hashable(c, info.element, seen)
	case .Struct, .Union:
		if !record_hashes_structurally(c, id, under, info) {
			return false
		}
		// A type seen before answers as it did then, or is a diagnosed cycle.
		if !type_walk_enter(seen, under, info) {
			return true
		}
		parts := make([dynamic]Type_Id, 0, len(info.fields) + len(info.variants))
		defer delete(parts)
		if info.kind == .Struct {
			for field in info.fields {
				sym := symbol_of(c, field)
				// design.md "Uninitialized capacity": a counted prefix is no structural part.
				if sym == nil || sym.initialized_by != INVALID_SYMBOL {
					return false
				}
				append(&parts, sym.type)
			}
		} else {
			for variant in info.variants {
				if variant != TYPE_VOID {
					append(&parts, variant)
				}
			}
		}
		for part in parts {
			if !part_is_hashable(c, part, seen) {
				return false
			}
		}
		return true
	}
	return false
}

// A field, variant payload, or array element: one with its own `==` is hashed
// by its own `hash`, and any other hashes as its type does.
@(private = "file")
part_is_hashable :: proc(c: ^Compiler, part: Type_Id, seen: ^Type_Walk) -> bool {
	if type_own_equality(c, part) != INVALID_SYMBOL {
		return part_own_hash(c, part) != INVALID_SYMBOL
	}
	return type_is_hashable_walk(c, part, seen)
}

// A record, union, or enum with the generated `==`, which a structural `hash` is
// the coherent partner of: none of its own, no `hash` of its own, not a callable,
// and not packed, whose fields are read in place.
@(private = "file")
record_hashes_structurally :: proc(c: ^Compiler, id, under: Type_Id, info: ^Type_Info) -> bool {
	if info.packed || type_is_capture_record(c, under) {
		return false
	}
	if type_own_equality(c, id) != INVALID_SYMBOL || inherent_hash_member(c, under) != INVALID_SYMBOL {
		return false
	}
	return true
}

// The `hash` a part with its own `==` must also declare, which a structural
// hash calls for it with the protocol's shape; INVALID_SYMBOL when the part
// hashes structurally, or its `hash` is missing or has another signature.
part_own_hash :: proc(c: ^Compiler, part: Type_Id) -> Symbol_Id {
	found, holder := part_hash_member(c, part)
	if found == INVALID_SYMBOL || !key_hash_signature_ok(symbol_of(c, found), holder) {
		return INVALID_SYMBOL
	}
	return found
}

// A part with its own `==`, and the `hash` member beside it whatever its
// signature, with the type that declares it; a checker resolves the signature
// before `part_own_hash` reads it.
part_hash_member :: proc(c: ^Compiler, part: Type_Id) -> (Symbol_Id, Type_Id) {
	if type_own_equality(c, part) == INVALID_SYMBOL {
		return INVALID_SYMBOL, INVALID_TYPE
	}
	if found := inherent_hash_member(c, part); found != INVALID_SYMBOL {
		return found, part
	}
	under := type_underlying(c, part)
	return inherent_hash_member(c, under), under
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

// The first field or variant that keeps a record or union from hashing
// structurally, for the diagnostic.
@(private = "file")
first_unhashable_part :: proc(c: ^Compiler, type: Type_Id) -> (string, Type_Id, bool) {
	// An array's element is the part its elements share.
	info := type_of(c, type_underlying(c, type))
	if info == nil || (info.kind != .Struct && info.kind != .Union) {
		return "", INVALID_TYPE, false
	}
	unhashable :: proc(c: ^Compiler, part: Type_Id) -> bool {
		if part == TYPE_VOID {
			return false
		}
		if type_own_equality(c, part) != INVALID_SYMBOL {
			return part_own_hash(c, part) == INVALID_SYMBOL
		}
		return !type_is_hashable(c, part)
	}
	if info.kind == .Union {
		for variant, index in info.variants {
			if unhashable(c, variant) {
				return union_variant_name(c, type_underlying(c, type), index), variant, true
			}
		}
		return "", INVALID_TYPE, false
	}
	for field in info.fields {
		if sym := symbol_of(c, field); sym != nil && unhashable(c, sym.type) {
			return identifier_text(c, sym.name), sym.type, true
		}
	}
	return "", INVALID_TYPE, false
}

// design.md "Maps": the compiler supplies a key's `==`/`hash` pair, or the key
// type declares both inherently; extensions never count. `Rejected` means already
// reported.
Key_Policy_Kind :: enum { Unresolved, Builtin, Inherent, Rejected }

// Chosen during checking and read by CTFE and the backend.
Key_Policy :: struct {
	kind:      Key_Policy_Kind,
	hash:      Symbol_Id,
	equal:     Symbol_Id,
}

// Whether the policy names the operations to run.
key_policy_settled :: proc(policy: Key_Policy) -> bool {
	return policy.kind == .Builtin || policy.kind == .Inherent
}

// Does not cache: discovery may still be installing inherent members.
resolve_map_key_policy :: proc(c: ^Compiler, key: Type_Id) -> (Key_Policy, string) {
	if key == INVALID_TYPE {
		return Key_Policy{}, "is not a type"
	}
	hash := inherent_hash_member(c, key)
	equal, _ := inherent_equality(c, key)
	// Declaring either half opts out of the catalogue, so a `distinct` scalar
	// never pairs its own `==` with its underlying type's hash.
	if hash == INVALID_SYMBOL && equal == INVALID_SYMBOL {
		if type_is_hashable(c, key) {
			return Key_Policy{kind = .Builtin}, ""
		}
		if type_holds_float(c, key) {
			return Key_Policy{}, "holds a float, and NaN never equals itself, so no float is hashable; key by an integer image of the value instead"
		}
		if part, part_type, found := first_unhashable_part(c, key); found {
			if own, _ := part_hash_member(c, part_type); own != INVALID_SYMBOL {
				return Key_Policy{}, fmt.aprintf(
					"has `%s: %s`, whose `hash` must be written `proc(self, seed: uint) -> uint`",
					part, type_name(c, part_type), allocator = c.semantic_allocator,
				)
			}
			return Key_Policy{}, fmt.aprintf(
				"has `%s: %s`, which is not hashable, so it needs an inherent `==` and `value.hash(seed: uint) -> uint` pair in its own package",
				part, type_name(c, part_type), allocator = c.semantic_allocator,
			)
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

// design.md "Maps": a key needs a coherent inherent `==` and `hash`. Checked
// where the map type is named.
@(private = "file")
require_map_key_policy :: proc(k: ^Checker, type: Type_Id, span: Span) -> bool {
	key := container_key(k.c, type)
	if key == INVALID_TYPE {
		return true
	}
	#partial switch k.c.map_key_policies[key].kind {
	case .Builtin, .Inherent:
		return true
	case .Rejected:
		return false // already reported, once, at this key
	}
	// A speculative probe's diagnostics are rolled back, so it must not cache one.
	if committing(k.c) {
		k.c.map_key_policies[key] = Key_Policy{kind = .Rejected}
	}
	if type_clone_disabled(k.c, key) {
		errorf(
			k.c, span, "L0586",
			"`%s` cannot be a map key: it is move-only, and a key must be copyable",
			type_name(k.c, key),
		)
		return false
	}
	settle_part_hashes(k, key)
	policy, reason := resolve_map_key_policy(k.c, key)
	if reason == "" && policy.kind == .Inherent {
		resolve_symbol_signature_in_place(k, policy.hash)
		if sym := symbol_of(k.c, policy.hash); sym == nil || !key_hash_signature_ok(sym, key) {
			reason = "has an inherent `hash`, which must be written `proc(self, seed: uint) -> uint`"
		}
	}
	if reason == "" {
		k.c.map_key_policies[key] = policy
		return true
	}
	errorf(
		k.c, span, "L0586",
		"`%s` cannot be a map key: it %s",
		type_name(k.c, key), reason,
	)
	add_notef(
		k.c, no_span(),
		"an extension block does not qualify; wrap the key in a local `distinct` type with its own inherent operations",
	)
	return false
}

require_nested_map_key_policies :: proc(k: ^Checker, type: Type_Id, span: Span) -> bool {
	seen: Type_Walk
	defer delete(seen)
	return require_nested_map_key_policies_walk(k, type, span, &seen)
}

@(private = "file")
require_nested_map_key_policies_walk :: proc(k: ^Checker, type: Type_Id, span: Span, seen: ^Type_Walk) -> bool {
	if type == INVALID_TYPE { return true }
	info := type_of(k.c, type)
	if info == nil || !type_walk_enter(seen, type, info) { return true }
	#partial switch info.kind {
	case .Map:
		return require_map_key_policy(k, type, span) &&
		       require_nested_map_key_policies_walk(k, info.key, span, seen) &&
		       require_nested_map_key_policies_walk(k, info.element, span, seen)
	case .Array, .Dynamic_Array, .Slice, .Pointer, .C_Pointer, .Box, .Distinct:
		return require_nested_map_key_policies_walk(k, info.element, span, seen)
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(k.c, field); sym != nil &&
			   !require_nested_map_key_policies_walk(k, sym.type, span, seen) { return false }
		}
	case .Union:
		for variant in info.variants {
			if !require_nested_map_key_policies_walk(k, variant, span, seen) { return false }
		}
	case .Proc:
		for parameter in info.parameters {
			if !require_nested_map_key_policies_walk(k, parameter, span, seen) { return false }
		}
		return require_nested_map_key_policies_walk(k, info.result, span, seen)
	}
	return true
}

// The key type's own non-synthesized `hash`; a `distinct` type inherits none.
@(private = "file")
inherent_hash_member :: proc(c: ^Compiler, type: Type_Id) -> Symbol_Id {
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL
	}
	wanted := intern_identifier(c, "hash")
	for member in info.members {
		sym := symbol_of(c, member)
		if sym != nil && sym.name == wanted && sym.kind == .Proc && sym.operator == "" &&
		   sym.synth == .None {
			return member
		}
	}
	return INVALID_SYMBOL
}

// design.md "Comparison operators": the `==` a type declares for itself, or a
// distinct type's underlying type does. A value of the type compares by it
// wherever it is nested, as a map key does.
type_own_equality :: proc(c: ^Compiler, type: Type_Id) -> Symbol_Id {
	callable, _ := own_equality(c, type)
	return callable
}

// The declaration that `type_own_equality`'s procedure belongs to, the group
// when it is in one: what `@(public)` is written on, so what visibility asks.
type_own_equality_declared :: proc(c: ^Compiler, type: Type_Id) -> Symbol_Id {
	_, declared := own_equality(c, type)
	return declared
}

@(private = "file")
own_equality :: proc(c: ^Compiler, type: Type_Id) -> (callable, declared: Symbol_Id) {
	if callable, declared = inherent_equality(c, type); callable != INVALID_SYMBOL {
		return
	}
	under := type_underlying(c, type)
	if under == type {
		return INVALID_SYMBOL, INVALID_SYMBOL
	}
	return inherent_equality(c, under)
}

// Every type within `type`, itself included, that compares by its own `==`;
// structural comparison does not look inside one.
own_equalities_within :: proc(c: ^Compiler, type: Type_Id, out: ^[dynamic]Type_Id) {
	seen: Type_Walk
	defer delete(seen)
	own_equalities_walk(c, type, out, &seen, false)
}

// Those a comparison or hash of a value of `type` calls: a zero-length array has
// no element (design.md "Global write effects"), though comparing one still
// requires of its element what `own_equalities_within` says.
own_equalities_called :: proc(c: ^Compiler, type: Type_Id, out: ^[dynamic]Type_Id) {
	seen: Type_Walk
	defer delete(seen)
	own_equalities_walk(c, type, out, &seen, true)
}

// Guarded because a record diagnosed as containing itself still reaches
// body checking.
@(private = "file")
own_equalities_walk :: proc(c: ^Compiler, type: Type_Id, out: ^[dynamic]Type_Id, seen: ^Type_Walk, called: bool) {
	if type_own_equality(c, type) != INVALID_SYMBOL {
		append(out, type)
		return
	}
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil || !type_walk_enter(seen, under, info) {
		return
	}
	#partial switch info.kind {
	case .Array:
		if !called || info.count > 0 {
			own_equalities_walk(c, info.element, out, seen, called)
		}
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil {
				own_equalities_walk(c, sym.type, out, seen, called)
			}
		}
	case .Union:
		for variant in info.variants {
			own_equalities_walk(c, variant, out, seen, called)
		}
	}
}

// A delegated `==` keeps the underlying type's policy, so it is not one of the
// type's own.
@(private = "file")
inherent_equality :: proc(c: ^Compiler, type: Type_Id) -> (callable, declared: Symbol_Id) {
	callable, declared = inherent_self_operator(c, type, "==")
	if sym := symbol_of(c, callable); sym == nil || sym.delegated {
		return INVALID_SYMBOL, INVALID_SYMBOL
	}
	return
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
