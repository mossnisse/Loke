// The compiler-contributed `hash` for standard-library.md's `Hashable` catalogue,
// and map key policies. The mix is 64-bit FNV-1a's step per scalar, folded over
// arrays; the compile-time and runtime paths must agree exactly.
//
// ponytail: one non-seeded mixing constant. The per-table seed threaded through
// `hash` varies the result between tables; a per-*process* seed, which a
// hash-flooding defence needs, is not derived here.
package lokec

import "core:fmt"
import "core:mem"

// The 64-bit FNV prime.
HASH_MULTIPLIER :: u64(1099511628211)
// The 64-bit FNV offset basis.
HASH_OFFSET_BASIS :: u64(0xcbf29ce484222325)

// One step of the mix: `value` folded into `current`.
hash_mix :: proc(current, value: u64) -> u64 {
	return (current ~ value) * HASH_MULTIPLIER
}

// standard-library.md "Standard interface catalogue" lists the hashable scalars;
// a record or union keeping its generated `==` hashes structurally (design.md
// "Maps"), and a type with its own `==` hashes by its own `hash`.
type_is_hashable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	seen: Type_Walk
	defer delete(seen)
	return id != TYPE_VOID && type_is_hashable_walk(c, id, &seen)
}

// A union's payloadless variant carries `void`, which hashes as nothing.
@(private = "file")
type_is_hashable_walk :: proc(c: ^Compiler, id: Type_Id, seen: ^Type_Walk) -> bool {
	if id == TYPE_VOID {
		return true
	}
	if hash, equal, _ := key_pair(c, id); hash != INVALID_SYMBOL || equal != INVALID_SYMBOL {
		return part_own_hash(c, id) != INVALID_SYMBOL
	}
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Enum, .Bool, .Int, .Rune, .Typeid,
	     .Raw_Pointer, .Pointer, .C_Pointer,
	     .String, .String_View:
		return true
	case .Array:
		return type_is_hashable_walk(c, info.element, seen)
	case .Struct, .Union:
		// Packed fields are read in place.
		if info.packed || type_is_capture_record(c, under) {
			return false
		}
		if !type_walk_enter(seen, under, info) {
			return true
		}
		for field in info.fields {
			sym := symbol_of(c, field)
			// design.md "Uninitialized capacity": a counted prefix is no structural part.
			if sym == nil || sym.initialized_by != INVALID_SYMBOL || !type_is_hashable_walk(c, sym.type, seen) {
				return false
			}
		}
		for variant in info.variants {
			if !type_is_hashable_walk(c, variant, seen) {
				return false
			}
		}
		return true
	}
	return false
}

// The `==` and `hash` a type keys by, with the type that declares them: its own,
// or, when it declares neither half, its underlying type's (design.md "Maps").
// Either is INVALID_SYMBOL when that type does not declare it.
@(private = "file")
key_pair :: proc(c: ^Compiler, type: Type_Id) -> (hash, equal: Symbol_Id, holder: Type_Id) {
	holder = type
	hash = inherent_hash_member(c, holder)
	equal, _ = inherent_equality(c, holder)
	if hash == INVALID_SYMBOL && equal == INVALID_SYMBOL {
		holder = type_underlying(c, type)
		hash = inherent_hash_member(c, holder)
		equal, _ = inherent_equality(c, holder)
	}
	return
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

// The `hash` member paired with a part's own `==`, whatever its signature, with
// the type that declares both; a checker resolves the signature before
// `part_own_hash` reads it.
part_hash_member :: proc(c: ^Compiler, part: Type_Id) -> (Symbol_Id, Type_Id) {
	hash, equal, holder := key_pair(c, part)
	if equal == INVALID_SYMBOL {
		return INVALID_SYMBOL, INVALID_TYPE
	}
	return hash, holder
}

// A float, or a fixed array of them, as `type_is_hashable` excludes.
@(private = "file")
type_holds_float :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Float:
		return true
	case .Array:
		return type_holds_float(c, info.element)
	}
	return false
}

// The first field or variant that keeps a record or union from hashing
// structurally, for the diagnostic; INVALID_TYPE when none does.
@(private = "file")
first_unhashable_part :: proc(c: ^Compiler, type: Type_Id) -> (string, Type_Id) {
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil {
		return "", INVALID_TYPE
	}
	seen: Type_Walk
	defer delete(seen)
	#partial switch info.kind {
	case .Union:
		for variant, index in info.variants {
			if !type_is_hashable_walk(c, variant, &seen) {
				return union_variant_name(c, under, index), variant
			}
		}
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && !type_is_hashable_walk(c, sym.type, &seen) {
				return identifier_text(c, sym.name), sym.type
			}
		}
	}
	return "", INVALID_TYPE
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
	hash, equal, _ := key_pair(c, key)
	// Declaring either half opts out of the catalogue, so a `distinct` scalar
	// never pairs its own `==` with its underlying type's hash.
	if hash == INVALID_SYMBOL && equal == INVALID_SYMBOL {
		if type_is_hashable(c, key) {
			return Key_Policy{kind = .Builtin}, ""
		}
		return Key_Policy{}, unhashable_key_reason(c, key)
	}
	if hash == INVALID_SYMBOL {
		return Key_Policy{}, "has an inherent `==` but no inherent `hash`"
	}
	if equal == INVALID_SYMBOL {
		return Key_Policy{}, "has an inherent `hash` but no inherent `==`"
	}
	return Key_Policy{kind = .Inherent, hash = hash, equal = equal}, ""
}

// Why a key declaring neither half of the pair has no generated one.
@(private = "file")
unhashable_key_reason :: proc(c: ^Compiler, key: Type_Id) -> string {
	NEEDS_PAIR :: "needs an inherent `==` and `value.hash(seed: uint) -> uint` pair in its own package"
	if type_holds_float(c, key) {
		return "holds a float, and NaN never equals itself, so no float is hashable; key by an integer image of the value instead"
	}
	part, part_type := first_unhashable_part(c, key)
	if part_type == INVALID_TYPE {
		return NEEDS_PAIR
	}
	if own, _ := part_hash_member(c, part_type); own != INVALID_SYMBOL {
		return fmt.aprintf(
			"has `%s: %s`, whose `hash` must be written `proc(self, seed: uint) -> uint`",
			part, type_name(c, part_type), allocator = c.semantic_allocator,
		)
	}
	return fmt.aprintf(
		"has `%s: %s`, which is not hashable, so it " + NEEDS_PAIR,
		part, type_name(c, part_type), allocator = c.semantic_allocator,
	)
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
		if part_own_hash(k.c, key) == INVALID_SYMBOL {
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
		k.c, NO_SPAN,
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
	if info.kind == .Map && !require_map_key_policy(k, type, span) {
		return false
	}
	for part in type_parts(k.c, info) {
		if !require_nested_map_key_policies_walk(k, part, span, seen) {
			return false
		}
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

// --------------------------------------------------------- compile time --

// One scalar folded into `seed`, as `emit_hash_value` does at run time.
hash_const :: proc(c: ^Compiler, value: Const_Value, type: Type_Id, seed: u64, allocator: mem.Allocator) -> u64 {
	#partial switch underlying_kind(c, type) {
	case .String, .String_View:
		// As `loke_rt_v1_hash_bytes`: the bytes, then the length, so the elements
		// of `{"ab", ""}` and `{"a", "b"}` do not hash alike.
		result := seed
		for index in 0 ..< len(value.text) {
			result = hash_mix(result, u64(value.text[index]))
		}
		return hash_mix(result, u64(len(value.text)))
	case .Bool:
		return hash_mix(seed, value.boolean ? 1 : 0)
	case .Raw_Pointer, .Pointer, .C_Pointer:
		return hash_mix(seed, 0) // the only compile-time pointer constant is nil
	}
	bits, _ := bi_to_u64(allocator, bi_wrap(allocator, value.integer, 64, false))
	return hash_mix(seed, bits)
}
