package lokec

import "core:reflect"
import "core:strings"
import "core:testing"

// `ast_clone.odin` copies written syntax and drops what the checker fills in. A
// field added to a node is dropped from every clone unless it is copied there
// (compiler-architecture.md "How to make a compiler change"), and nothing else
// notices, so every field is classified here and a new one fails until it is.
@(private = "file")
Clone_Split :: struct {
	type:            typeid,
	copied, dropped: string,
}

@(test)
ast_clone_classifies_every_node_field :: proc(t: ^testing.T) {
	split := []Clone_Split {
		// A node's `base` is classified once, here.
		{Expr_Base, "span has_error", "type denoted_type const_value is_const resolution value_category addressable assignable immutable erased_from view_from splat_from"},
		{Node_Base, "span has_error attributes", ""},

		{Expr_Error, "", ""},
		{Expr_Literal, "kind text", ""},
		{Expr_Ident, "name name_id", "symbol"},
		{Expr_Selector, "operand name", "variant_union variant_index"},
		{Expr_Checked_Extract, "operand target mode", "payload"},
		{Expr_Index, "operand indices", "bound map_inserts"},
		{Expr_Slice, "operand lo hi", "bound"},
		{Expr_Call, "callee args", "bound bound_order operation overload_members is_variadic variadic_slot variadic_forwards variadic_elements variadic_spreads variadic_order"},
		{Expr_Postfix, "op op_span operand", "borrows"},
		{Expr_Unary, "op op_span mutable operand", ""},
		{Expr_Binary, "op op_span lhs rhs", "negated"},
		{Expr_Range, "op op_span lo hi", ""},
		{Expr_Or_Else, "value fallback", "borrows fallback_clone"},
		{Expr_Cond, "then cond otherwise", "then_clone else_clone"},
		{Expr_Move, "value", ""},
		{Expr_Composite, "type_expr elements", "field_indices element_clones backing via"},
		{Expr_Proc, "signature where_clauses body bodiless", "symbol defer_count generic_instance"},
		{Expr_Proc_Group, "names", ""},
		{Expr_Operator, "symbol symbol_span hook value", ""},
		{Type_Pointer, "mutable elem", ""},
		{Type_C_Pointer, "elem", ""},
		{Type_Slice, "mutable elem", ""},
		{Type_Dynamic_Array, "elem", ""},
		{Type_Array, "length inferred elem", ""},
		{Type_Map, "key value", ""},
		{Type_Distinct, "elem", ""},
		{Type_Dyn, "mutable interface_expr", ""},
		{Type_Type, "", ""},
		{Type_Poly, "name constraint", ""},
		{Type_Proc, "convention params result", ""},
		{Type_Record, "kind move_only generic_params attributes where_clauses fields variants", ""},
		{Type_Anon_Record, "fields", ""},
		{Type_Enum, "backing fields", ""},
		{Type_Interface, "generic_params where_clauses requirements", ""},

		{Block, "stmts", ""},
		{Decl, "kind names duration declared_type via values top_level", "symbols value_clones destructure sig_state check_state"},
		{Stmt_Error, "", ""},
		{Stmt_Expr, "exprs", ""},
		{Stmt_Assign, "op op_span lhs rhs", "rhs_clones destination_live destructure operator operator_direct place_setter setter_bound"},
		{Stmt_If, "init cond then otherwise", ""},
		{Stmt_For, "init cond post body condition_only", ""},
		{Stmt_Foreach, "bindings iterable body", "kind adapter indexed element_type item_type borrows count iterator_type iter_symbol next_symbol expansion"},
		{Stmt_When, "cond then otherwise", "resolved selected"},
		{Stmt_Switch, "kind init binding subject cases", "exhaustive"},
		{Stmt_Defer, "stmt", "slot"},
		{Stmt_Return, "value", ""},
		{Stmt_Branch, "kind", ""},

		{Item_Error, "", ""},
		{Item_Import, "alias path", "bound"},
		{Item_Foreign_Import, "name path", ""},
		{Item_Foreign_Block, "library members", "declared"},
		// `kind` is filled in by the checker, but an instance reads its template's.
		{Item_Impl, "kind type members", "subject declared"},
		{Item_Delegate, "symbols", ""},
		{Item_When, "cond then otherwise", "resolved taken stalled"},
		{Item_Block, "items", ""},
		{Item_Static_Assert, "call", ""},

		// The parts cloned by their own helpers.
		{Attribute, "span path value", ""},
		{Argument, "span name mode value", ""},
		{Element, "span key value", ""},
		{Parameter, "span attributes names mode type default", "symbols"},
		{Result, "span is_inout type diverges", ""},
		{Field, "span attributes is_using names type", "symbols"},
		{Variant, "span name type", ""},
		{Enum_Field, "span name value", "symbol"},
		{Generic_Param, "span names type", "symbols"},
		{Binding_Group, "span names is_inout type", "symbols"},
		{Requirement, "span kind bindings expr result_inout result name slot_type", ""},
		{Switch_Case, "span values stmts binding", "binding_symbol binding_type variant_indices"},
		{Return_Value, "span is_inout expr", "clone_on_return"},
		{Foreach_Binding, "name is_static is_ref group", "symbol"},
	}

	listed := make(map[typeid]bool, context.temp_allocator)
	for entry in split {
		listed[entry.type] = true
		classified := make(map[string]int, context.temp_allocator)
		for name in strings.fields(entry.copied, context.temp_allocator) {
			classified[name] += 1
		}
		for name in strings.fields(entry.dropped, context.temp_allocator) {
			classified[name] += 1
		}
		for name in reflect.struct_field_names(entry.type) {
			if name == "base" {
				continue
			}
			count := classified[name]
			testing.expectf(
				t, count == 1, "%v.%s is %s", entry.type, name,
				count == 0 ? "neither copied nor dropped; copy it in ast_clone.odin if it is written syntax, and classify it here" : "both copied and dropped",
			)
			delete_key(&classified, name)
		}
		for name in classified {
			testing.expectf(t, false, "%v.%s is classified but is no longer a field", entry.type, name)
		}
	}

	// Every node is classified, not only the ones listed when this was written.
	for tree in ([]typeid{Expr, Stmt, Item}) {
		for variant in reflect.type_info_base(type_info_of(tree)).variant.(reflect.Type_Info_Union).variants {
			node := variant.variant.(reflect.Type_Info_Pointer).elem.id
			testing.expectf(t, listed[node], "%v, a %v node, is not classified", node, tree)
		}
	}
}
