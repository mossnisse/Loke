package lokec

import "base:runtime"
import "core:fmt"
import "core:mem"
import os2 "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The body of the file's `main :: proc() { ... }`.
@(private = "file")
main_body :: proc(f: ^File) -> ^Block {
	for item in f.items {
		if d, ok := item.(^Decl); ok && len(d.names) == 1 && d.names[0].text == "main" {
			if literal := decl_proc(d); literal != nil {
				return literal.body
			}
		}
	}
	return nil
}

// The bootstrap instantiates `Result(Unit, Allocator_Error)`.
BOOTSTRAP_INSTANCES :: 1

// The single-package half of `compile_program`, without `when` discovery.
check_one_package :: proc(c: ^Compiler, pkg_id: Package_Id) {
	k := Checker{c = c}
	defer delete(k.nil_uses)
	ensure_runtime_bootstrap(&k)
	rebuild_active_items(c, package_of(c, pkg_id))
	prepare_package(&k, pkg_id)
	check_package_bodies(&k, pkg_id)
}

// A single-file program, filled in place because packages keep `&f`.
Checked :: struct {
	c:      Compiler,
	f:      File,
	tokens: []Token,
	pkg:    Package_Id,
}

parse_source :: proc(p: ^Checked, source: string) {
	p.c = test_compiler(source)
	p.tokens = lex(&p.c, 0)
	p.f = parse(&p.c, 0, p.tokens)
}

check_parsed :: proc(p: ^Checked, name := "") {
	p.pkg = new_package(&p.c, name != "" ? name : p.f.package_name)
	add_package_file(&p.c, p.pkg, &p.f)
	check_one_package(&p.c, p.pkg)
}

check_source :: proc(p: ^Checked, source: string, name := "") {
	parse_source(p, source)
	check_parsed(p, name)
}

destroy_checked :: proc(p: ^Checked) {
	destroy_ast(&p.f)
	delete(p.tokens)
	destroy_compilation(&p.c)
}

test_compiler :: proc(text: string) -> Compiler {
	c: Compiler
	add_source(&c, "<test>", text)
	return c
}

@(test)
deep_type_graphs_have_no_arbitrary_cutoff :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	deep := TYPE_I32
	for _ in 0 ..< 96 {
		deep = new_type(&c, Type_Info{kind = .Distinct, element = deep})
	}
	testing.expect(t, type_underlying(&c, deep) == TYPE_I32, "a valid distinct chain was truncated")
}

@(private = "file")
deep_typeid_pair :: proc(reverse: bool) -> (u64, u64) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	left, right := TYPE_I32, TYPE_I64
	for _ in 0 ..< 96 {
		left = new_type(&c, Type_Info{kind = .Pointer, element = left})
		right = new_type(&c, Type_Info{kind = .Pointer, element = right})
	}
	if reverse {
		request_typeid(&c, right)
		request_typeid(&c, left)
	} else {
		request_typeid(&c, left)
		request_typeid(&c, right)
	}
	freeze_typeids(&c)
	return typeid_value(&c, left), typeid_value(&c, right)
}

@(test)
deep_typeids_are_request_order_independent :: proc(t: ^testing.T) {
	left_first, right_first := deep_typeid_pair(false)
	left_reverse, right_reverse := deep_typeid_pair(true)
	testing.expect(t, left_first != right_first, "different deep type graphs received one identity")
	testing.expect(t, left_first == left_reverse, "deep left typeid depends on request order")
	testing.expect(t, right_first == right_reverse, "deep right typeid depends on request order")
}

// `Box(a.Token)` and `Box(b.Token)` print alike; their sort keys must not.
@(test)
applied_typeids_do_not_key_on_display_names :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	name := intern_identifier(&c, "Box(Token)")
	template := new_symbol(&c, Symbol{name = intern_identifier(&c, "Box"), kind = .Type})
	interface_symbol := new_symbol(&c, Symbol{name = intern_identifier(&c, "Drawable"), kind = .Type})

	applied :: proc(c: ^Compiler, name: Identifier_Id, owner: Symbol_Id, arg: Type_Id, dyn: bool) -> Type_Id {
		args := make([]Generic_Arg, 1, c.semantic_allocator)
		args[0] = Generic_Arg{is_type = true, type = arg}
		info := Type_Info{kind = .Struct, name = name}
		if dyn {
			info.kind, info.dyn_interface, info.dyn_args = .Dyn, owner, args
		} else {
			info.symbol, info.instance_of, info.instance_args = new_symbol(c, Symbol{name = name, kind = .Type}), owner, args
		}
		return new_type(c, info)
	}
	// Two packages' unrelated `Token`: separate nominal types that print alike.
	token :: proc(c: ^Compiler, pkg: string) -> Type_Id {
		symbol := new_symbol(c, Symbol {
			name = intern_identifier(c, "Token"),
			kind = .Type,
			pkg  = new_package(c, pkg, pkg),
		})
		return new_type(c, Type_Info{kind = .Struct, symbol = symbol})
	}
	first, second := token(&c, "a"), token(&c, "b")

	testing.expect(
		t,
		typeid_sort_key(&c, applied(&c, name, template, first, false)) !=
		typeid_sort_key(&c, applied(&c, name, template, second, false)),
		"two generic instances collided on their shared display name",
	)
	dyn_name := intern_identifier(&c, "dyn Drawable")
	testing.expect(
		t,
		typeid_sort_key(&c, applied(&c, dyn_name, interface_symbol, first, true)) !=
		typeid_sort_key(&c, applied(&c, dyn_name, interface_symbol, second, true)),
		"two dyn views collided on their shared display name",
	)
}

@(test)
written_signatures_agree_on_parameter_shapes :: proc(t: ^testing.T) {
	source := `package main;
Sink :: struct { value: int }
Collects :: interface($T: type) {
    slot append: proc(self, values: ..int) -> int;
    slot show: proc(self, values: ..any_view) -> int;
    slot update: proc(self, left, right: inout int);
    slot defaulted: proc(self, value: int) -> int;
    slot take: proc(self: move T) -> int;
    slot place: proc(self: inout T) -> inout int;
}
sum :: proc(self, other: int) -> int { return self + other; }
impl Sink {
    append :: proc(self, values: ..int) -> int { return values.len(); }
    show :: proc(self, values: ..any_view) -> int { return values.len(); }
    update :: proc(self, left, right: inout int) { left += 1; right += 1; }
    defaulted :: proc(self, value: int = 7) -> int { return value; }
    take :: proc(self: move Sink) -> int { return self.value; }
    place :: proc(self: inout Sink) -> inout int { return inout self.value; }
    plain_type :: proc(self) -> int {
        // Even inside an impl, a plain proc type gives both names the written type.
        callback: proc(self, other: int) -> int = sum;
        return callback(1, 2);
    }
}
main :: proc() {
    static_assert(Collects(Sink));
    value := Sink{};
    // A plain receiver is a value, so the qualified form passes it like any
    // other argument.
    assert(Sink.append(value, 1, 2) == 2);
    assert(value.append(1, 2) == 2);
    assert(value.show(1, true) == 2);
    assert(value.defaulted() == 7);
    assert(value.plain_type() == 3);
    left, right := 1, 2;
    value.update(inout left, inout right);
}`
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, source)
	if !testing.expect(t, p.c.error_count == 0, "declaration, procedure type, and slot shapes disagree") {
		report(&p.c)
	}
}

@(test)
variadic_slots_remain_static_only :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
Collects :: interface($T: type) { slot append: proc(self, values: ..int) -> int; }
View :: dyn Collects;
main :: proc() {}`)
	if !testing.expect(t, len(p.c.diagnostics) == 1, "expected one dyn compatibility diagnostic") {
		report(&p.c)
		return
	}
	diagnostic := p.c.diagnostics[0]
	testing.expect(t, diagnostic.code == "L0463" && strings.contains(diagnostic.message, "variadic"),
	               "a variadic slot became dyn-compatible")
}

@(test)
generic_probes_do_not_commit_bodies :: proc(t: ^testing.T) {
	source := `package main;
identity :: proc(value: $T) -> typeid { return typeid_of(T); }
Probe :: interface($T: type) { (value: T) identity(value) -> typeid; }
known :: proc($T: type) -> bool { return typeid_of(T) == typeid_of(T); }
bounded :: proc(value: $T) -> int where known(T) { return 1; }
main :: proc() {
    static_assert(Probe(i8));
    static_assert(Probe(int));
    assert(identity(1) != nil);
    assert(bounded(true) == 1);
}`
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, source)
	if !testing.expectf(t, p.c.error_count == 0, "probe checking produced %d errors", p.c.error_count) {
		report(&p.c)
		return
	}
	freeze_typeids(&p.c)
	testing.expect(t, typeid_value(&p.c, TYPE_I8) == 0, "a hypothetical call registered its unexecuted body")
	testing.expect(t, typeid_value(&p.c, TYPE_INT) != 0, "a real call lost the probed body's dependencies")
	testing.expect(t, typeid_value(&p.c, TYPE_BOOL) != 0, "an executed generic bound lost its dependencies")
}

// Only committed emission state: type interning, signature instances, and other
// semantic caches may grow while answering a hypothetical requirement.
@(private = "file")
Probe_Emission_State :: struct {
	typeids, typeid_order:                   int,
	witnesses, witness_order:                int,
	materialized, materialized_order:        int,
	instances, checked_bodies, static_locals: int,
	format_requested, type_info_requested:   bool,
}

@(private = "file")
probe_emission_state :: proc(c: ^Compiler) -> Probe_Emission_State {
	state := Probe_Emission_State {
		typeids             = len(c.typeid_requested),
		typeid_order        = len(c.typeid_order),
		witnesses           = len(c.witnesses),
		witness_order       = len(c.witness_order),
		materialized        = len(c.materialized),
		materialized_order  = len(c.materialized_order),
		checked_bodies      = len(c.checked_bodies),
		static_locals       = len(c.static_locals),
		format_requested    = c.format_requested,
		type_info_requested = c.type_info_requested,
	}
	for pkg in c.packages { state.instances += len(pkg.instances) }
	return state
}

@(test)
interface_probes_do_not_register_emission_dependencies :: proc(t: ^testing.T) {
	// A small core:fmt package reaches its private dispatch intrinsic without
	// checking the real library's bodies, which already request formatting.
	source := `package fmt;
import "base:runtime";
Writer :: struct {}
Options :: struct {}
Record :: struct { value: int }
Sized :: interface($T: type) { slot size: proc(self) -> int; }
impl Record { size :: proc(self) -> int { return self.value; } }
View :: dyn Sized;
TABLE :: [2]int{1, 2};
identity :: proc(value: $T) -> typeid { return typeid_of(T); }
Probe :: interface($T: type) {
    (value: T) identity(value) -> typeid;
    (value: ^T) (dyn Sized)(value) -> View;
    &TABLE -> ^[2]int;
    typeid_of(T) -> typeid;
    type_info_of(typeid_of(T)) -> _;
    (value: any_view, writer: Writer, options: Options) format_any(value, writer, options) -> _;
}
Nested :: interface($T: type) { Probe(T); }
Rejected :: interface($T: type) { Nested(T); T.missing -> _; }
`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, source)
	k := Checker{c = &p.c}
	ensure_runtime_bootstrap(&k)
	if !testing.expect(t, p.c.error_count == 0) { report(&p.c); return }
	p.pkg = new_package(&p.c, p.f.package_name, STD_FMT)
	add_package_file(&p.c, p.pkg, &p.f)
	append(&package_of(&p.c, p.pkg).imports, Package_Import {
		target = symbol_of(&p.c, p.c.result_symbol).pkg,
		alias  = "runtime",
	})
	check_one_package(&p.c, p.pkg)
	if !testing.expect(t, p.c.error_count == 0) { report(&p.c); return }
	scope := package_of(&p.c, p.pkg).scope
	k = Checker{c = &p.c, pkg = p.pkg, lookup_pkg = p.pkg, scope = scope, file_node = &p.f}
	record := symbol_of(&p.c, scope.names[intern_identifier(&p.c, "Record")]).type
	table := scope.names[intern_identifier(&p.c, "TABLE")]
	args := []Generic_Arg{{is_type = true, type = record}}
	before := probe_emission_state(&p.c)
	cached_before := len(p.c.procedure_instances)
	testing.expect(t, !before.format_requested && !before.type_info_requested,
	               "the fixture already requested the runtime tables")

	// Rejection happens after every registration path was reached. Repetition
	// also exercises the signature cache populated by the first accepted probe.
	for name in ([]string{"Probe", "Nested", "Rejected", "Probe"}) {
		info := interface_info_for(&k, scope.names[intern_identifier(&p.c, name)])
		if !testing.expectf(t, info != nil, "missing interface %s", name) { return }
		held := interface_satisfied(&k, info, args, no_span(), report = false)
		testing.expectf(t, held == (name != "Rejected"), "%s returned the wrong probe result", name)
		after := probe_emission_state(&p.c)
		testing.expectf(t, after == before, "%s changed emission state: before %v, after %v", name, before, after)
		testing.expectf(t, p.c.speculation_depth == 0, "%s did not restore speculation depth", name)
		testing.expectf(t, p.c.error_count == 0, "%s leaked a diagnostic", name)
	}
	testing.expect(t, len(p.c.procedure_instances) > cached_before,
	               "the probe did not exercise signature instantiation")

	// Check real uses in the same compilation so cached probe results cannot
	// hide a missing commitment. CTFE inside a bound is covered separately above.
	real_source := `package fmt;
use_dependencies :: proc(value: ^Record, erased: any_view, writer: Writer, options: Options) {
    id := identity(value^);
    view := (dyn Sized)(value);
    address := &TABLE;
    info := type_info_of(typeid_of(Record));
    format_any(erased, writer, options);
}`
	file_id := add_source(&p.c, "<real-use>", real_source)
	tokens := lex(&p.c, file_id)
	defer delete(tokens)
	f := parse(&p.c, file_id, tokens)
	defer destroy_ast(&f)
	add_package_file(&p.c, p.pkg, &f)
	check_one_package(&p.c, p.pkg)
	if !testing.expect(t, p.c.error_count == 0) { report(&p.c); return }
	after := probe_emission_state(&p.c)
	testing.expect(t, after.typeids == before.typeids + 1 && after.typeid_order == before.typeid_order + 1 &&
	               p.c.typeid_requested[record], "a real use lost the probed typeid")
	testing.expect(t, after.witnesses == before.witnesses + 1 && after.witness_order == before.witness_order + 1 &&
	               p.c.witness_order[before.witness_order].concrete == record,
	               "a real conversion lost the probed witness")
	testing.expect(t, after.materialized == before.materialized + 1 && after.materialized_order == before.materialized_order + 1 &&
	               p.c.materialized[table] != nil, "a real address lost the probed constant's storage")
	testing.expect(t, after.instances == before.instances + 1 && after.checked_bodies == before.checked_bodies + 2,
	               "a real call did not commit the probed generic body and its caller")
	testing.expect(t, after.format_requested && after.type_info_requested,
	               "real uses did not request the formatter and reflection tables")
}

@(test)
foreign_abi_walk_defers_by_value_cycles_to_size_check :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	record := new_type(&c, Type_Info{kind = .Struct})
	field := new_symbol(&c, Symbol{kind = .Var, type = record})
	fields := make([]Symbol_Id, 1, c.semantic_allocator)
	fields[0] = field
	type_of(&c, record).fields = fields
	safe, _ := foreign_abi_safe(&c, record)
	testing.expect(t, safe, "ABI traversal diagnosed or recursed before finite-size checking")
}

@(test)
semantic_ids_survive_phases :: proc(t: ^testing.T) {
	text := `package main;

N :: 3;
main :: proc() {
	x := N + 1;
	sink(x);
}
sink :: proc(value: int) {}`
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, text)
	c, f, pkg_id := &p.c, &p.f, p.pkg
	validate_executable(c, pkg_id)
	if !testing.expectf(t, c.error_count == 0, "semantic phases produced %d diagnostics", c.error_count) {
		return
	}

	n_decl := f.items[0].(^Decl)
	main_decl := f.items[1].(^Decl)
	body := decl_proc(main_decl).body
	local := body.stmts[0].(^Decl)
	call_stmt := body.stmts[1].(^Stmt_Expr)
	call := call_stmt.exprs[0].(^Expr_Call)
	argument := call.args[0].value.(^Expr_Ident)
	initializer := local.values[0].(^Expr_Binary)
	n_use := initializer.lhs.(^Expr_Ident)

	testing.expect(t, n_decl.symbols[0] != INVALID_SYMBOL, "top-level declaration has no stable symbol")
	testing.expect(t, main_decl.symbols[0] != INVALID_SYMBOL, "procedure has no stable symbol")
	testing.expect(t, local.symbols[0] != INVALID_SYMBOL, "local declaration has no stable symbol")
	testing.expect(t, n_use.symbol == n_decl.symbols[0], "top-level use did not retain its binding ID")
	testing.expect(t, argument.symbol == local.symbols[0], "local use did not retain its binding ID")
	testing.expect(t, call.resolution.kind == .Call, "call was not classified during resolution")
	testing.expect(t, call.resolution.chosen_overload != INVALID_SYMBOL, "direct call has no selected target")
	main_symbol := symbol_of(c, main_decl.symbols[0])
	testing.expect(t, main_symbol != nil && main_symbol.proc_type != INVALID_TYPE, "procedure signature has no canonical type")
}

@(test)
package_collection_crosses_file_boundaries :: proc(t: ^testing.T) {
	first_text := `package main;
main :: proc() { sink(N); }
sink :: proc(value: int) {}`
	second_text := `package main;
N :: 7;`
	c := test_compiler(first_text)
	defer destroy_compilation(&c)
	second_index := add_source(&c, "second.loke", second_text)
	first_tokens := lex(&c, 0)
	defer delete(first_tokens)
	first := parse(&c, 0, first_tokens)
	defer destroy_ast(&first)
	second_tokens := lex(&c, second_index)
	defer delete(second_tokens)
	second := parse(&c, second_index, second_tokens)
	defer destroy_ast(&second)
	pkg_id := new_package(&c, "main")
	add_package_file(&c, pkg_id, &first)
	add_package_file(&c, pkg_id, &second)
	check_one_package(&c, pkg_id)
	validate_executable(&c, pkg_id)
	if !testing.expectf(t, c.error_count == 0, "multi-file package produced %d diagnostics", c.error_count) {
		return
	}
	main_decl := first.items[0].(^Decl)
	testing.expect(t, c.entry_point == main_decl.symbols[0], "executable validation did not record the entry point")
	call_stmt := decl_proc(main_decl).body.stmts[0].(^Stmt_Expr)
	call := call_stmt.exprs[0].(^Expr_Call)
	n_use := call.args[0].value.(^Expr_Ident)
	n_decl := second.items[0].(^Decl)
	testing.expect(t, n_use.symbol == n_decl.symbols[0], "cross-file name did not bind to the package symbol")
}

@(test)
package_loading_handles_literal_paths_and_regular_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := fmt.tprintf("loke-packages-test-%d-[files]", os2.get_pid())
	_ = os2.remove_all(root)
	defer os2.remove_all(root)
	if !testing.expect(t, os2.make_directory_all(filepath.join({root, "ignored.loke"})) == nil) {
		return
	}
	if !testing.expect(
		t,
		os2.write_entire_file(filepath.join({root, "main.LOKE"}), transmute([]u8)string("package fixture;")) == nil,
	) {
		return
	}

	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	id, loaded := load_package_dir(&c, root, root, no_span())
	if !testing.expect(t, loaded, "a literal directory path containing glob syntax did not load") {
		report(&c)
		return
	}
	pkg := package_of(&c, id)
	testing.expect(t, pkg != nil && len(pkg.files) == 1, "a .loke directory was treated as a source file")
}

@(test)
failed_package_loads_are_not_cached :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := fmt.tprintf("loke-packages-retry-%d", os2.get_pid())
	_ = os2.remove_all(root)
	defer os2.remove_all(root)
	path := filepath.join({root, "main.loke"})
	if !testing.expect(t, os2.make_directory_all(root) == nil && os2.write_entire_file(path, []u8{0xff}) == nil) {
		return
	}

	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	before := len(c.packages)
	id, loaded := load_package_dir(&c, root, root, no_span())
	testing.expect(t, !loaded && id == INVALID_PACKAGE && len(c.packages) == before, "a failed load created a package")

	if !testing.expect(t, os2.write_entire_file(path, transmute([]u8)string("package retry;")) == nil) {
		return
	}
	id, loaded = load_package_dir(&c, root, root, no_span())
	testing.expect(t, loaded && id != INVALID_PACKAGE && len(package_of(&c, id).files) == 1, "a corrected package could not be retried")
}

@(test)
package_paths_handle_root_collections_and_trailing_slashes :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)
	root, ok := filepath.abs("/", context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	c.collections["drive"] = strings.clone(root, c.semantic_allocator)
	dir, why := resolve_import_path(&c, nil, "drive:tmp/loke")
	testing.expect(t, why == .Ok && dir != "", "a collection rooted at a volume root rejected its descendant")
	imported := Item_Import{path = `"core:fmt//"`}
	testing.expect(t, import_binding_name(&imported) == "fmt", "repeated trailing separators erased the default alias")
}

@(test)
nominal_shells_precede_recursive_field_resolution :: proc(t: ^testing.T) {
	text := `package main;
Node :: struct { next: ^Node, other: ^Node, value: int }
main :: proc() { }`
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, text)
	c, f := &p.c, &p.f

	testing.expectf(t, c.error_count == 0, "expected no diagnostics, got %d", c.error_count)
	node_decl := f.items[0].(^Decl)
	node_symbol := symbol_of(c, node_decl.symbols[0])
	record := node_decl.values[0].(^Type_Record)
	testing.expect(t, node_symbol != nil && node_symbol.kind == .Type, "record has no nominal symbol")
	testing.expect(t, record.denoted_type == node_symbol.type, "record shell and syntax disagree")
	first_field := symbol_of(c, record.fields[0].symbols[0])
	second_field := symbol_of(c, record.fields[1].symbols[0])
	testing.expect(t, first_field != nil && first_field.type != INVALID_TYPE, "recursive field type was not resolved")
	testing.expect(t, second_field != nil && second_field.type == first_field.type, "equal pointer types were not interned")
}

// Each member's value interns a new array type while the enum's own type is
// being filled in. The enum once kept a `^Type_Info` across that loop; when the
// type store grew, its members went into an abandoned copy and every use said
// the enum had no such member.
@(test)
enum_members_survive_type_store_growth :: proc(t: ^testing.T) {
	COUNT :: 300
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "package main;\nSizes :: enum {\n")
	for i in 1 ..= COUNT {
		strings.write_string(&b, "\tM")
		strings.write_int(&b, i)
		strings.write_string(&b, " = size_of([")
		strings.write_int(&b, i)
		strings.write_string(&b, "]u8),\n")
	}
	strings.write_string(&b, "}\nmain :: proc() { last := Sizes.M300; }\n")

	p: Checked
	defer destroy_checked(&p)
	check_source(&p, strings.to_string(b))
	testing.expectf(t, p.c.error_count == 0, "expected no diagnostics, got %d", p.c.error_count)
	sizes := symbol_of(&p.c, p.f.items[0].(^Decl).symbols[0])
	if testing.expect(t, sizes != nil && sizes.kind == .Type) {
		testing.expect_value(t, len(type_of(&p.c, sizes.type).fields), COUNT)
	}
}

@(test)
library_check_is_separate_from_executable_validation :: proc(t: ^testing.T) {
	text := `package utility;
helper :: proc() { }`
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, text)
	c, pkg_id := &p.c, p.pkg
	testing.expect(t, c.error_count == 0, "library package was treated as an executable")
	validate_executable(c, pkg_id)
	testing.expect(t, c.error_count == 2, "executable validation did not enforce package name and entry point")
	testing.expect(t, c.entry_point == INVALID_SYMBOL, "failed validation recorded an entry point")
}

@(test)
default_output_keeps_a_dotted_directory_name :: proc(t: ^testing.T) {
	actual := default_output_path("tests/pkg/mangle/a.b", .Obj)
	testing.expectf(
		t,
		actual == "tests/pkg/mangle/a.b.obj" || actual == `tests\pkg\mangle\a.b.obj`,
		"dotted directory defaulted to %q",
		actual,
	)
}

// `.` and `..` name a directory without spelling any component of it, so the
// sibling executable takes its name from the resolved path rather than from the
// dots themselves — `..exe` is not a name.
@(test)
default_output_resolves_a_dot_directory :: proc(t: ^testing.T) {
	for input in ([]string{".", "./", `.\`}) {
		actual := default_output_path(input, .Exe)
		testing.expectf(
			t,
			filepath.base(actual) != "..exe" && strings.has_suffix(actual, ".exe"),
			"%q defaulted to %q",
			input,
			actual,
		)
	}
}

@(test)
default_output_requires_a_name_for_a_root_directory :: proc(t: ^testing.T) {
	actual := default_output_path(`C:\`, .Exe)
	testing.expectf(t, actual == "", "drive root defaulted to %q", actual)
}

// The two properties the cross-volume package key leans on: one directory's
// name is not its identity, and Windows spellings of one path are.
@(test)
path_digest_separates_paths_and_folds_case :: proc(t: ^testing.T) {
	testing.expect(
		t,
		path_digest("C:/a/util") != path_digest("D:/x/util"),
		"two `util` directories on two volumes digest alike",
	)
	testing.expect(
		t,
		path_digest("C:/A/Util") == path_digest("c:/a/util"),
		"one path spelled two ways digests differently",
	)
}

@(test)
lexer_golden :: proc(t: ^testing.T) {
	text := `name 123 1.5 "text" ` + "`raw`" + ` 'x'
break case continue defer distinct dyn dynamic else enum for foreach foreign if impl import in inout interface map move mut operator or_else or_return package proc return struct switch type union via when where
static self slot using delegate thread_local manual
+ - * / % & &~ | ~ << >> && || ! == != < <= > >= = += -= *= /= %= |= ~= &= &~= <<= >>= : ; , . .. ..= ..< -> --- ? $ ^ @ ( ) [ ] { }
/* nested /* block */ comment */`
	c := test_compiler(text)
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	expected := []Token_Kind {
		.Ident, .Int, .Float, .String, .Raw_String, .Rune,
		.Break, .Case, .Continue, .Defer, .Distinct, .Dyn, .Dynamic, .Else,
		.Enum, .For, .Foreach, .Foreign, .If, .Impl, .Import, .In,
		.Inout, .Interface, .Map, .Move, .Mut, .Operator, .Or_Else, .Or_Return,
		.Package, .Proc, .Return, .Struct, .Switch, .Type, .Union, .Via, .When, .Where,
		.Ident, .Ident, .Ident, .Ident, .Ident, .Ident, .Ident,
		.Plus, .Minus, .Star, .Slash, .Percent, .Amp, .Amp_Tilde, .Pipe, .Tilde,
		.Shl, .Shr, .And_And, .Or_Or, .Not, .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq,
		.Gt, .Gt_Eq, .Assign, .Plus_Eq, .Minus_Eq, .Star_Eq, .Slash_Eq,
		.Percent_Eq, .Pipe_Eq, .Tilde_Eq, .Amp_Eq, .Amp_Tilde_Eq, .Shl_Eq,
		.Shr_Eq, .Colon, .Semicolon, .Comma, .Period, .Range, .Range_Incl,
		.Range_Excl, .Arrow, .Uninit, .Question, .Dollar, .Caret, .At, .Lparen,
		.Rparen, .Lbracket, .Rbracket, .Lbrace, .Rbrace, .EOF,
	}
	testing.expectf(t, c.error_count == 0, "valid golden input produced %d diagnostics", c.error_count)
	if !testing.expectf(t, len(tokens) == len(expected), "expected %d tokens, got %d", len(expected), len(tokens)) {
		return
	}
	for token, i in tokens {
		testing.expectf(t, token.kind == expected[i], "token %d: expected %v, got %v", i, expected[i], token.kind)
		testing.expectf(t, int(token.hi) <= len(text), "token %d extends beyond the source", i)
	}
}

// `operator` takes the first match in `OPERATORS`, so longer operators must
// come first to honour grammar.md's longest match.
@(test)
operator_table_is_ordered_longest_first :: proc(t: ^testing.T) {
	table := OPERATORS
	for op, i in table {
		for later in table[i + 1:] {
			testing.expectf(
				t,
				!strings.has_prefix(later.text, op.text),
				"`%s` is listed before `%s`, so `%s` can never lex",
				op.text,
				later.text,
				later.text,
			)
		}
	}
}

// A malformed literal is one bad token, never a good token plus junk the parser
// then has to explain.
@(test)
lexer_rejects_malformed_literals :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		code: string,
	} {
		{"0b12", "L0113"}, // 2 is not a binary digit
		{"0o8", "L0113"},
		{"0xzz", "L0113"},
		{"0x", "L0110"}, // a prefix with nothing after it
		{"0b_", "L0110"},
		{"0o_", "L0110"},
		{"0x_", "L0110"},
		{"123abc", "L0113"},
		{"1_000u", "L0113"},
		{"1e", "L0112"},
		{"1.5e+", "L0112"},
		{"1einvalid", "L0112"}, // the bad exponent takes the whole word, like `123abc`
		{"1e_5", "L0112"},
		{"''", "L0107"}, // terminated, just empty
		{`'\q'`, "L0105"},

		{`"\ud800"`, "L0114"}, // a surrogate half
		{`"\U00110000"`, "L0114"}, // past the last code point
		{`"\uZZZZ"`, "L0105"},
	}
	for test_case in cases {
		c := test_compiler(test_case.text)
		defer destroy_compilation(&c)
		tokens := lex(&c, 0)
		defer delete(tokens)
		testing.expectf(t, c.error_count == 1, "`%s`: expected one diagnostic, got %d", test_case.text, c.error_count)
		code := len(c.diagnostics) == 1 ? c.diagnostics[0].code : "<none>"
		testing.expectf(t, code == test_case.code, "`%s`: expected %s, got %s", test_case.text, test_case.code, code)
		testing.expectf(t, len(tokens) == 2 && tokens[0].kind == .Error, "`%s`: expected one error token, got %v", test_case.text, tokens)
		testing.expectf(t, int(tokens[0].hi) == len(test_case.text), "`%s`: the error token did not cover the literal", test_case.text)
	}

	// The valid neighbours of every rule above still lex.
	valid := test_compiler("0b101 0o777 0xff 1e9 1.5e+3 1_000 " + `"é\U0001f600\xff"`)
	defer destroy_compilation(&valid)
	tokens := lex(&valid, 0)
	defer delete(tokens)
	testing.expectf(t, valid.error_count == 0, "valid literals produced %d diagnostics", valid.error_count)
	testing.expectf(t, len(tokens) == 8, "expected seven literals, got %d tokens", len(tokens) - 1)
}

// A backslash escapes no line ending, so a string missing its closing quote is
// one bad line rather than two: the code below it still reaches the parser.
@(test)
a_string_missing_its_quote_stops_at_the_line_end :: proc(t: ^testing.T) {
	text := "bad := \"abc\\\n\tgood := 1;\n"
	c := test_compiler(text)
	defer destroy_compilation(&c)
	tokens := lex(&c, 0)
	defer delete(tokens)
	survived := false
	for token in tokens {
		if token.kind == .Ident && text[token.lo:token.hi] == "good" {
			survived = true
		}
	}
	testing.expect(t, survived, "the unterminated string swallowed the line after it")
	// One literal, one diagnostic: the escape reports the ending, so the loop
	// must not report it a second time.
	testing.expectf(t, c.error_count == 1, "expected one diagnostic, got %d", c.error_count)

	// The same shape at end of input.
	eof := test_compiler("bad := \"abc\\")
	defer destroy_compilation(&eof)
	eof_tokens := lex(&eof, 0)
	defer delete(eof_tokens)
	testing.expectf(t, eof.error_count == 1, "at end of input: expected one diagnostic, got %d", eof.error_count)
}

@(test)
malformed_escape_stays_in_bounds :: proc(t: ^testing.T) {
	text := `package main; main :: proc() { bad := "abc\`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c, tokens := &p.c, p.tokens
	testing.expect(t, c.error_count > 0, "malformed escape produced no diagnostic")
	for token in tokens {
		testing.expectf(t, int(token.hi) <= len(text), "error token extends beyond source: %d > %d", token.hi, len(text))
	}
}

@(test)
parser_recovery_retains_nodes :: proc(t: ^testing.T) {
	text := `package main;
import ;
main :: proc() {
	x := 1 + ;
	sink(2);
}`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c, f := &p.c, &p.f

	testing.expectf(t, c.error_count == 2, "expected two diagnostics, got %d", c.error_count)
	if !testing.expectf(t, len(f.items) == 2, "expected the import and main declaration, got %d items", len(f.items)) {
		return
	}
	_, first_is_import := f.items[0].(^Item_Import)
	_, second_is_decl := f.items[1].(^Decl)
	testing.expect(t, first_is_import, "the malformed import was not retained")
	testing.expect(t, item_base(f.items[0]).has_error, "the malformed import was not marked")
	if !testing.expect(t, second_is_decl, "recovery did not reach the following main declaration") {
		return
	}
	body := main_body(f)
	if !testing.expectf(t, body != nil && len(body.stmts) == 2, "expected the declaration plus the following call") {
		return
	}
	broken, first_is_decl := body.stmts[0].(^Decl)
	_, second_is_expr := body.stmts[1].(^Stmt_Expr)
	testing.expect(t, first_is_decl, "the broken declaration was not retained")
	testing.expect(t, first_is_decl && broken.has_error, "the broken declaration was not marked")
	testing.expect(t, second_is_expr, "delimiter-aware recovery lost the following statement")
}

@(test)
empty_defer_is_rejected_without_reaching_the_checker_as_nil :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
main :: proc() {
	defer ;
	x := 1;
}`)
	if !testing.expectf(t, p.c.error_count == 1, "expected one diagnostic, got %d", p.c.error_count) {
		report(&p.c)
		return
	}
	testing.expect(t, p.c.diagnostics[0].code == "L0216", "empty defer produced the wrong diagnostic")
	body := main_body(&p.f)
	if !testing.expect(t, body != nil && len(body.stmts) == 2, "empty defer swallowed the following statement") {
		return
	}
	deferred, ok := body.stmts[0].(^Stmt_Defer)
	testing.expect(t, ok && deferred.has_error && deferred.stmt != nil, "empty defer was retained as a clean nil statement")
}

@(test)
delimiter_failures_mark_retained_nodes :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, `package main;
zero: int
A :: [^int;
B :: [dynamic int;
C :: [?int;
sentinel :: 1;
`)
	if !testing.expectf(t, p.c.error_count == 4, "expected four diagnostics, got %d", p.c.error_count) {
		return
	}
	if !testing.expectf(t, len(p.f.items) == 5, "recovery retained %d declarations", len(p.f.items)) {
		return
	}
	for item, index in p.f.items[:4] {
		decl, ok := item.(^Decl)
		testing.expectf(t, ok && decl.has_error, "malformed declaration %d was not marked", index)
	}
}

@(test)
source_utf8_validation :: proc(t: ^testing.T) {
	invalid_bytes := []u8{0xf0, 0x28, 0x8c, 0x28}
	invalid := transmute(string)invalid_bytes
	valid, bad_offset := valid_utf8(invalid)
	testing.expect(t, !valid, "invalid UTF-8 was accepted")
	testing.expectf(t, bad_offset == 0, "expected the invalid sequence at byte 0, got %d", bad_offset)

	replacement_bytes := []u8{0xef, 0xbf, 0xbd}
	replacement_character := transmute(string)replacement_bytes
	valid, _ = valid_utf8(replacement_character)
	testing.expect(t, valid, "a valid encoded U+FFFD was rejected")
}

// A node's span ends at the last token *consumed*, never at the one an
// `expect` tripped over — otherwise a declaration missing its `;` would claim
// the construct that follows it.
@(test)
spans_end_at_the_last_consumed_token :: proc(t: ^testing.T) {
	text := `package main;

main :: proc() {
	x := 1
	sink(2);
}
`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c, f := &p.c, &p.f

	testing.expectf(t, c.error_count == 1, "expected one diagnostic, got %d", c.error_count)
	body := main_body(f)
	if !testing.expectf(
		t,
		body != nil && len(body.stmts) == 2,
		"expected the declaration and the following call",
	) {
		return
	}
	broken := body.stmts[0].(^Decl)
	testing.expectf(
		t,
		text[broken.span.lo:broken.span.hi] == "x := 1",
		"span reaches past the declaration: %q",
		text[broken.span.lo:broken.span.hi],
	)
}

// `Constant_Decl` binds one `Identifier` and has no `Storage_Modifiers` or
// `via`; `Variable_Decl` is the one that takes a list.
@(test)
constants_bind_one_plain_name :: proc(t: ^testing.T) {
	text := `package main;

A, B :: 1;
bad: static int : 2;
`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c := &p.c

	if !testing.expectf(t, c.error_count == 2, "expected two diagnostics, got %d", c.error_count) {
		return
	}
	testing.expectf(t, c.diagnostics[0].code == "L0233", "unexpected code %s", c.diagnostics[0].code)
	testing.expectf(t, c.diagnostics[1].code == "L0234", "unexpected code %s", c.diagnostics[1].code)
}

// Level 2 is non-associative: a range takes exactly two endpoints.
@(test)
range_does_not_chain :: proc(t: ^testing.T) {
	text := `package main;

main :: proc() {
	x := 1 ..< 2 ..< 3;
	sink(4);
}
`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c, f := &p.c, &p.f

	if !testing.expectf(t, c.error_count == 1, "expected one diagnostic, got %d", c.error_count) {
		return
	}
	testing.expectf(t, c.diagnostics[0].code == "L0223", "unexpected code %s", c.diagnostics[0].code)

	body := main_body(f)
	if !testing.expectf(
		t,
		body != nil && len(body.stmts) == 2,
		"recovery lost the statement after the bad range",
	) {
		return
	}
	_, sentinel_survived := body.stmts[1].(^Stmt_Expr)
	testing.expect(t, sentinel_survived, "the statement after the bad range did not survive recovery")
}

// Deep parentheses, operator chains, and prefix runs each give one L0222.
@(test)
parser_depth_is_bounded :: proc(t: ^testing.T) {
	sources := []string {
		strings.concatenate(
			{"package main;\n\nmain :: proc() {\n\tx := ", strings.repeat("(", 10_000, context.temp_allocator), "1;\n}\n"},
			context.temp_allocator,
		),
		strings.concatenate(
			{"package main;\n\nmain :: proc() {\n\tx := 1", strings.repeat(" + 1", 10_000, context.temp_allocator), ";\n}\n"},
			context.temp_allocator,
		),
		strings.concatenate(
			{"package main;\n\nmain :: proc() {\n\tx := ", strings.repeat("!", 10_000, context.temp_allocator), "true;\n}\n"},
			context.temp_allocator,
		),
		strings.concatenate(
			{
				"package main;\n\nmain :: proc() {\n\tforeach (",
				strings.repeat("(", 10_000, context.temp_allocator),
				"value",
				strings.repeat(")", 10_000, context.temp_allocator),
				" in values) { }\n}\n",
			},
			context.temp_allocator,
		),
	}

	for text in sources {
		c := test_compiler(text)
		defer destroy_compilation(&c)
		tokens := lex(&c, 0)
		defer delete(tokens)
		f := parse(&c, 0, tokens)
		defer destroy_ast(&f)

		if !testing.expectf(t, c.error_count == 1, "expected one diagnostic, got %d", c.error_count) {
			continue
		}
		testing.expectf(
			t,
			c.diagnostics[0].code == "L0222",
			"deep nesting was not reported as a nesting limit",
		)
		for token in tokens {
			testing.expectf(t, int(token.hi) <= len(text), "token extends beyond the source")
		}
		dump := ast_dump(&f)
		defer delete(dump)
		testing.expect(t, len(dump) > 0, "a depth-limited tree did not dump")
	}
}

// Every frame of this recursion is fat with nesting, so the stack runs out well
// before the call-depth limit; that must be a diagnostic, not a dead process.
@(test)
evaluation_runs_out_of_stack_cleanly :: proc(t: ^testing.T) {
	text := strings.concatenate(
		{
			"package main;\nDEEP :: fat_frames(250);\nfat_frames :: proc(n: int) -> int {\n\tif (n == 0) { return 0; }\n\treturn ",
			strings.repeat("1 + (", 500, context.temp_allocator),
			"fat_frames(n - 1)",
			strings.repeat(")", 500, context.temp_allocator),
			";\n}\nmain :: proc() { }\n",
		},
		context.temp_allocator,
	)
	p: Checked
	check_source(&p, text)
	defer destroy_checked(&p)
	out_of_stack := false
	for d in p.c.diagnostics {
		out_of_stack ||= d.code == "L0342" && strings.contains(d.message, "ran out of stack")
	}
	testing.expect(t, out_of_stack, "deep evaluation was not stopped by the stack guard")
}

@(test)
bare_types_are_not_expressions :: proc(t: ^testing.T) {
	invalid_text := `package main;

Bad :: struct($T: type) where ^T { }

main :: proc() {
	a := ^int;
	b := type;
	c := proc();
	sink(1);
}
`
	invalid := test_compiler(invalid_text)
	defer destroy_compilation(&invalid)
	invalid_tokens := lex(&invalid, 0)
	defer delete(invalid_tokens)
	invalid_file := parse(&invalid, 0, invalid_tokens)
	defer destroy_ast(&invalid_file)

	if testing.expectf(t, invalid.error_count == 4, "expected four diagnostics, got %d", invalid.error_count) {
		for diagnostic in invalid.diagnostics {
			testing.expectf(t, diagnostic.code == "L0220", "unexpected code %s", diagnostic.code)
		}
	}
	body := main_body(&invalid_file)
	testing.expectf(
		t,
		body != nil && len(body.stmts) == 4,
		"recovery lost the statement after invalid type expressions",
	)

	valid_text := `package main;

main :: proc() {
	f(^int, []int, proc(), []int{1});
}
`
	valid := test_compiler(valid_text)
	defer destroy_compilation(&valid)
	valid_tokens := lex(&valid, 0)
	defer delete(valid_tokens)
	valid_file := parse(&valid, 0, valid_tokens)
	defer destroy_ast(&valid_file)
	testing.expectf(t, valid.error_count == 0, "type arguments produced %d diagnostics", valid.error_count)
}

@(test)
attributes_parse_on_referenced_blocks :: proc(t: ^testing.T) {
	text := `package main;

worker :: proc() @(cold) {
	if (ready) @(hot) { } else @(cold) { }
	for (ready) @(hot) { }
	when (ready) @(hot) { } else @(cold) when (other) @(hot) { } else @(cold) { }
}
`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c := &p.c
	testing.expectf(t, c.error_count == 0, "attributed blocks produced %d diagnostics", c.error_count)
}

@(test)
missing_list_separators_are_diagnosed :: proc(t: ^testing.T) {
	text := `package main;

main :: proc() {
	a := f(1 2);
	b := Point{1 2};
	sink(3);
}
`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c, f := &p.c, &p.f

	if testing.expectf(t, c.error_count == 2, "expected two diagnostics, got %d", c.error_count) {
		for diagnostic in c.diagnostics {
			testing.expectf(t, diagnostic.code == "L0253", "unexpected code %s", diagnostic.code)
		}
	}
	body := main_body(f)
	testing.expectf(
		t,
		body != nil && len(body.stmts) == 3,
		"recovery lost the statement after malformed lists",
	)
}

// An empty group names nothing, which is the error. The trailing comma is not:
// grammar.md gives every delimited list a `","?`, and an attribute group is one.
@(test)
attribute_groups_require_elements :: proc(t: ^testing.T) {
	text := `package main;

main :: proc() {
	@() x := 1;
	@(cold,) y := 2;
	@(a b) z := 3;
	sink(4);
}
`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c, f := &p.c, &p.f

	if testing.expectf(t, c.error_count == 2, "expected two diagnostics, got %d", c.error_count) {
		testing.expectf(t, c.diagnostics[0].code == "L0249", "unexpected code %s", c.diagnostics[0].code)
		// A missing separator, like every other delimited list.
		testing.expectf(t, c.diagnostics[1].code == "L0253", "unexpected code %s", c.diagnostics[1].code)
	}
	body := main_body(f)
	testing.expectf(
		t,
		body != nil && len(body.stmts) == 4,
		"recovery lost a statement after a malformed attribute group",
	)
}

@(test)
where_recovery_does_not_consume_the_body :: proc(t: ^testing.T) {
	text := `package main;
Bad :: struct($T: type) where { }
sentinel :: proc() { }
`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c, f := &p.c, &p.f

	testing.expectf(t, c.error_count == 1, "expected one diagnostic, got %d", c.error_count)
	if !testing.expectf(t, len(f.items) == 2, "recovery lost the sentinel declaration") {
		return
	}
	sentinel, ok := f.items[1].(^Decl)
	testing.expect(t, ok, "the recovered sentinel is not a declaration")
	if ok && testing.expect(t, len(sentinel.names) == 1, "the sentinel declaration has no name") {
		testing.expectf(t, sentinel.names[0].text == "sentinel", "recovered %s instead of sentinel", sentinel.names[0].text)
	}
}

// grammar.md bars composite literals only at a `where` clause's top level, not
// inside a nested block.
@(test)
a_where_clause_restricts_only_its_own_top_level :: proc(t: ^testing.T) {
	text := `package main;
Cfg :: struct { a: int }
nested :: proc() -> int where proc() { c := Cfg{a = 1}; } { return 1; }
header :: proc() -> int where proc() { if (a) { } } == Cfg { return 1; }
top_level :: proc() -> int where Cfg { return 1; }
`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c, f := &p.c, &p.f

	testing.expectf(
		t,
		c.error_count == 0,
		"expected no diagnostics, got %d, first: %s",
		c.error_count,
		c.error_count > 0 ? c.diagnostics[0].message : "",
	)
	testing.expectf(t, len(f.items) == 4, "the clause swallowed a declaration: %d items", len(f.items))
}

// A bad element costs one diagnostic; the list resumes at the next element and
// the following declaration survives.
@(test)
member_lists_recover_at_the_next_element :: proc(t: ^testing.T) {
	cases := []struct {
		body: string,
		code: string,
	}{
		{"S :: struct { a: int b: int }", "L0253"},
		{"S :: struct { a: int, 123, b: int }", "L0241"},
		{"U :: union { a: int b: int }", "L0253"},
		{"U :: union { a: int, 123, b: int }", "L0239"},
		{"E :: enum { A B }", "L0253"},
		{"G :: proc { a b };", "L0253"},
		{"f :: proc(a: int b: int) {}", "L0253"},
		{"S :: struct($T: type $U: type) { a: T }", "L0253"},
		{"I :: interface($Self: type) { (a: Self b: Self) a == b -> bool; }", "L0253"},
	}
	for k in cases {
		text := strings.concatenate({"package main;\n", k.body, "\nsentinel :: proc() { }\n"})
		defer delete(text)
		c := test_compiler(text)
		defer destroy_compilation(&c)
		tokens := lex(&c, 0)
		defer delete(tokens)
		f := parse(&c, 0, tokens)
		defer destroy_ast(&f)

		if !testing.expectf(
			t,
			c.error_count == 1,
			"%s: expected one diagnostic, got %d",
			k.body,
			c.error_count,
		) {
			continue
		}
		testing.expectf(
			t,
			c.diagnostics[0].code == k.code,
			"%s: expected %s, got %s",
			k.body,
			k.code,
			c.diagnostics[0].code,
		)
		if !testing.expectf(
			t,
			len(f.items) == 2,
			"%s: recovery lost the sentinel declaration",
			k.body,
		) {
			continue
		}
		// The list is short a member, so the node must carry the error.
		d, is_decl := f.items[0].(^Decl)
		if !testing.expectf(t, is_decl && len(d.values) == 1, "%s: no declared value", k.body) {
			continue
		}
		testing.expectf(
			t,
			expr_has_error(d.values[0]),
			"%s: the recovered node does not carry the error",
			k.body,
		)
	}
}

// A nested body's `}` does not close the outer one, so the stray `)` is
// reported once.
@(test)
an_unclosed_body_still_resynchronises :: proc(t: ^testing.T) {
	cases := []string{
		"S :: struct { a: struct { b: int } )",
		"S :: struct { a: enum { A } )",
		"S :: struct { a: union { b: int } )",
	}
	for body in cases {
		text := strings.concatenate({"package main;\n", body, "\n"})
		defer delete(text)
		c := test_compiler(text)
		defer destroy_compilation(&c)
		tokens := lex(&c, 0)
		defer delete(tokens)
		f := parse(&c, 0, tokens)
		defer destroy_ast(&f)

		if !testing.expectf(t, c.error_count == 1, "%s: expected one diagnostic, got %d", body, c.error_count) {
			continue
		}
		testing.expectf(
			t,
			c.diagnostics[0].code == "L0239",
			"%s: expected L0239, got %s",
			body,
			c.diagnostics[0].code,
		)
	}
}

// A stray `}` inside a list must not swallow the rest of it.
@(test)
list_recovery_survives_a_stray_brace :: proc(t: ^testing.T) {
	text := `package main;
main :: proc() {
	a := f(1 g(}) , 4);
}
`
	p: Checked
	defer destroy_checked(&p)
	parse_source(&p, text)
	c, f := &p.c, &p.f

	testing.expectf(t, c.error_count == 1, "expected one diagnostic, got %d", c.error_count)

	body := main_body(f)
	if !testing.expect(t, body != nil && len(body.stmts) == 1, "the statement did not survive") {
		return
	}
	d, is_decl := body.stmts[0].(^Decl)
	if !testing.expect(t, is_decl && len(d.values) == 1, "the initializer did not survive") {
		return
	}
	call, is_call := d.values[0].(^Expr_Call)
	if !testing.expect(t, is_call, "the initializer is not a call") {
		return
	}
	// The second argument is what the runaway scan used to eat.
	testing.expectf(t, len(call.args) == 2, "recovered %d arguments, expected 2", len(call.args))
}

// Rejected candidates are cached, so a repeated call costs no new instance.
@(test)
rejected_generic_candidates_are_negative_cached :: proc(t: ^testing.T) {
	text := `package main;
large :: proc(values: [$N]int) -> int where N > 5 { return N; }
small :: proc(values: [2]int) -> int { return 2; }
choose :: proc{large, small};
sink :: proc(value: int) {}
main :: proc() {
	sink(choose([2]int{}));
	sink(choose([2]int{}));
	sink(choose([6]int{1, 2, 3, 4, 5, 6}));
}`
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, text, "main")
	validate_executable(&p.c, p.pkg)

	testing.expectf(t, p.c.error_count == 0, "negative generic cache produced %d diagnostics", p.c.error_count)
	testing.expectf(
		t,
		p.c.instantiation_count == 2 + BOOTSTRAP_INSTANCES,
		"one rejected and one selected unique entry should consume the budget, found %d",
		p.c.instantiation_count,
	)
	testing.expectf(t, len(p.c.instances) == 2 + BOOTSTRAP_INSTANCES, "expected one rejected and one successful cache entry, found %d", len(p.c.instances))
}

@(test)
compilation_destruction_releases_owned_front_end_state :: proc(t: ^testing.T) {
	c: Compiler
	source, loaded := load_source(&c, "examples/hello.loke")
	if !testing.expect(t, loaded, "could not load the lifecycle fixture") {
		destroy_compilation(&c)
		return
	}
	tokens := lex(&c, source)
	file := new(File)
	file^ = parse(&c, source, tokens)
	delete(tokens)
	append(&c.parsed_files, file)
	errorf(&c, file.package_span, "L9999", "owned diagnostic")
	add_notef(&c, file.package_span, "owned note")
	testing.expect(t, len(c.parsed_files) == 1, "parsed file was not registered with the compilation")
	testing.expect(t, len(c.sources) == 1, "source buffer was not registered with the compilation")
	testing.expect(t, len(c.diagnostics) == 1, "diagnostic was not registered with the compilation")

	destroy_compilation(&c)
	testing.expect(t, !c.semantic_initialized, "semantic arena remained initialized")
	testing.expect(t, len(c.parsed_files) == 0, "parsed-file ownership survived destruction")
	testing.expect(t, len(c.sources) == 0, "source ownership survived destruction")
	testing.expect(t, len(c.diagnostics) == 0, "diagnostic ownership survived destruction")
	// Destruction is intentionally idempotent for early-return paths in callers.
	destroy_compilation(&c)
}

// `core:sync` names the `Memory_Order` that `base:runtime` declares. When that
// declaration is missing or malformed the type never arrives, and binding the
// name to `<invalid>` anyway would report every use as a broken member of a type
// that exists.
@(test)
an_unresolved_contributed_type_binds_nothing :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	k := Checker{c = &c}
	id := new_package(&c, "sync", STD_SYNC)
	pkg := package_of(&c, id)
	pkg.scope = new_scope(&c, build_universe(&c), .Package)

	// No `base:runtime` was prepared, so `memory_order_type` cannot answer.
	contribute_standard_members(&k, pkg)
	_, bound := pkg.scope.names[intern_identifier(&c, "Memory_Order")]
	testing.expect(t, !bound, "an unresolved `Memory_Order` was bound anyway")
	// The rest of the arm still lands: one missing type is not a failed package.
	_, atomics := pkg.scope.names[intern_identifier(&c, "atomic_load")]
	testing.expect(t, atomics, "the atomic intrinsics were skipped with it")
}

// A speculative check reports, rolls back, and must leave the compilation
// exactly as it found it — including `error_count`, which decides the exit code.
@(test)
truncating_diagnostics_restores_the_error_count :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	errorf(&c, no_span(), "L9999", "kept")
	mark := len(c.diagnostics)
	errorf(&c, no_span(), "L9998", "speculative")
	warnf(&c, no_span(), "L9997", "speculative warning")
	add_notef(&c, no_span(), "speculative note")

	truncate_diagnostics(&c, mark)
	testing.expectf(t, len(c.diagnostics) == 1, "expected one diagnostic, got %d", len(c.diagnostics))
	testing.expectf(t, c.error_count == 1, "the rollback left the error count at %d", c.error_count)

	// A warning never raised the count, so dropping it must not lower it.
	mark = len(c.diagnostics)
	warnf(&c, no_span(), "L9997", "only a warning")
	truncate_diagnostics(&c, mark)
	testing.expectf(t, c.error_count == 1, "dropping a warning changed the error count to %d", c.error_count)
}

// Odin maps need cache-line-aligned allocations, and `append`/`make` swallow a
// refused oversized block, so the arena must honour alignment and any size.
@(test)
semantic_arena_serves_maps_and_large_blocks :: proc(t: ^testing.T) {
	c: Compiler
	defer destroy_compilation(&c)
	init_semantic_stores(&c)

	// Odd sizes, so a bump allocator that is not rounding is off the boundary by
	// the second allocation rather than by luck.
	for size in ([?]int{1, 17, 63, 65, 200}) {
		block, err := mem.alloc_bytes(size, runtime.MAP_CACHE_LINE_SIZE, c.semantic_allocator)
		testing.expectf(t, err == nil, "semantic arena refused %d bytes: %v", size, err)
		testing.expectf(
			t,
			uintptr(raw_data(block)) % runtime.MAP_CACHE_LINE_SIZE == 0,
			"a %d-byte allocation came back %d-aligned; maps on this arena will crash",
			size,
			uintptr(raw_data(block)) % runtime.MAP_CACHE_LINE_SIZE,
		)
	}

	// Well past any block size an arena is likely to be configured with.
	for size in ([?]int{64 * 1024, 1 << 20, 8 << 20}) {
		block, err := mem.alloc_bytes(size, allocator = c.semantic_allocator)
		testing.expectf(t, err == nil, "semantic arena refused a %d-byte block: %v", size, err)
		testing.expectf(t, len(block) == size, "semantic arena returned %d of %d bytes", len(block), size)
	}

	// The stores themselves: growth is what reallocates, so push well past the
	// initial capacity rather than trusting a single insert.
	before := len(c.identifier_names)
	for i in 0 ..< 4096 {
		intern_identifier(&c, fmt.tprintf("name%d", i))
	}
	testing.expect(t, len(c.identifier_names) == before + 4096, "identifier interning lost entries")
	for i in 0 ..< 4096 {
		id := new_symbol(&c, Symbol{name = intern_identifier(&c, fmt.tprintf("sym%d", i))})
		testing.expectf(t, symbol_of(&c, id) != nil, "symbol %d was given an ID it was never stored under", i)
	}
}

@(test)
ownership_worklist_converges_past_sixty_four_back_edges :: proc(t: ^testing.T) {
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	fmt.sbprintln(&b, "package main;")
	fmt.sbprintln(&b, "Box :: struct { value: int }")
	fmt.sbprintln(&b, "impl Box { release :: hook(drop) proc(self: inout Box) {} }")
	fmt.sbprintln(&b, "main :: proc() {")
	fmt.sbprintln(&b, "x := Box{1};")
	for _ in 0 ..< 70 {
		fmt.sbprintln(&b, "for (true) {")
	}
	fmt.sbprintln(&b, "y := move(x);")
	fmt.sbprintln(&b, "break;")
	for depth := 69; depth >= 0; depth -= 1 {
		fmt.sbprintln(&b, "}")
		if depth > 0 {
			fmt.sbprintln(&b, "break;")
		}
	}
	fmt.sbprintln(&b, "sink(x.value);")
	fmt.sbprintln(&b, "}")
	fmt.sbprintln(&b, "sink :: proc(value: int) {}")

	p: Checked
	defer destroy_checked(&p)
	check_source(&p, strings.to_string(b))

	found := false
	for diagnostic in p.c.diagnostics {
		if diagnostic.code == "L0500" {
			found = true
			break
		}
	}
	testing.expect(t, found, "deep ownership flow stopped before reporting the moved-value use")
}

// Catches a driver enum rename silently changing a language-level member name.
@(test)
build_config_constants_follow_the_driver :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	source := `package main;
static_assert(LOKE_OPTIMIZATION_MODE == .Speed);
static_assert(LOKE_BUILD_MODE == .Obj);
static_assert(LOKE_LOG_LEVEL == .Warning);
static_assert(LOKE_VENDOR == .Loke);
static_assert(LOKE_VERSION == "0.7.0");
static_assert(LOKE_OPTIMIZATION_MODE == .None);
main :: proc() {}`
	parse_source(&p, source)
	p.c.opt_mode, p.c.build_mode, p.c.log_level = .Speed, .Obj, .Warning
	check_parsed(&p)
	// Only the deliberately false last assertion fails.
	false_assert := u32(strings.index(source, "static_assert(LOKE_OPTIMIZATION_MODE == .None"))
	ok := p.c.error_count == 1 && p.c.diagnostics[0].span.lo >= false_assert
	if !testing.expect(t, ok, "build config constants disagree with the driver") {
		report(&p.c)
	}
}
