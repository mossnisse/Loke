// Emission on demand: a procedure, a compiler-contributed member, or a witness
// table is written once something written names it.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:strings"

// A procedure that has a body to write.
@(private)
Listed_Proc :: struct {
	symbol:  Symbol_Id,
	literal: ^Expr_Proc,
}

// Everything written only once it is named, each in a slot, and the slots in
// the order the module holds them: every package's procedures as declared,
// then each member of `synth_procs` followed by its consuming body
// (`consuming_op_name`), then each witness of `witness_order`.
//
// A program calls few of the procedures it imports, so most were written only
// for `prune_unreachable` to drop. What a linker can see is named from the
// start, and each one written names more through `symbol_name` and
// `witness_name`.
@(private)
Demand :: struct {
	procs:        [dynamic]Listed_Proc,
	synth_base:   int,
	witness_base: int,
	// A symbol's slot plus one, by `Symbol_Id`, and a witness's.
	slot_of_symbol:  []int,
	slot_of_witness: map[^Witness]int,
	// Per slot, whether it was named, and its text once written, which is ""
	// for one that has no body after all.
	named: []bool,
	text:  []string,
	// The named slots in the order they were named: written before `next`.
	queue: [dynamic]int,
	next:  int,
}

// Lists `pkg`'s procedures, generic instances and local procedures included,
// in the order their bodies are written.
@(private)
list_package_procs :: proc(e: ^Emitter, pkg: ^Package) {
	for file in pkg.files {
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				// design.md "Test procedures": only a test build calls one.
				if len(v.symbols) > 0 && !omitted_with_test(e.c, v.symbols[0]) {
					list_proc(e, v.symbols[0], decl_proc_literal(v))
				}
			case ^Item_Impl:
				for member in v.members {
					if d, is_decl := member.(^Decl); is_decl && len(d.symbols) > 0 {
						list_proc(e, d.symbols[0], decl_proc_literal(d))
					}
				}
			}
		}
	}
	for literal in pkg.hoisted_procs {
		if !omitted_with_test(e.c, literal.symbol) {
			list_proc(e, literal.symbol, literal, templates = true)
		}
	}
	for instance in pkg.instances {
		if !omitted_with_test(e.c, instance.symbol) {
			list_proc(e, instance.symbol, decl_proc_literal(instance.decl))
		}
	}
}

// A template has only its instances' bodies, and a generic method of an
// instantiated `impl` is still one; a local procedure is listed as it is.
@(private = "file")
list_proc :: proc(e: ^Emitter, symbol_id: Symbol_Id, literal: ^Expr_Proc, templates := false) {
	symbol := symbol_of(e.c, symbol_id)
	if symbol == nil || literal == nil || literal.body == nil || compile_time_only_procedure(e.c, symbol) ||
	   !templates && symbol_is_template(e.c, symbol_id) {
		return
	}
	// compiler-architecture.md "CPU dispatch": what a copy for a higher level may
	// copy in turn, which a foreign entry's guard is not.
	if !convention_is_foreign(proc_convention_of(e, symbol)) {
		e.bodies[symbol_id] = literal
	}
	append(&e.demand.procs, Listed_Proc{symbol_id, literal})
}

// Gives everything listed its slot, and names what the linker can see: nothing
// in the module needs to name an export for its host to call it.
@(private)
begin_demand :: proc(e: ^Emitter) {
	d := &e.demand
	d.synth_base = len(d.procs)
	d.witness_base = d.synth_base + 2 * len(e.c.synth_procs)
	slots := d.witness_base + len(e.c.witness_order)
	d.named, d.text = make([]bool, slots), make([]string, slots)
	d.slot_of_symbol = make([]int, len(e.c.symbols))
	for listed, index in d.procs {
		d.slot_of_symbol[listed.symbol] = index + 1
	}
	for symbol_id, index in e.c.synth_procs {
		d.slot_of_symbol[symbol_id] = d.synth_base + 2 * index + 1
	}
	for witness, index in e.c.witness_order {
		d.slot_of_witness[witness] = d.witness_base + index + 1
	}
	for listed, index in d.procs {
		if llvm_linkage(e.names[listed.symbol]) == "" {
			demand_slot(e, index + 1)
		}
	}
}

// Has the slot numbered `slot - 1` written, unless `slot` is the 0 of something
// that has none.
@(private = "file")
demand_slot :: proc(e: ^Emitter, slot: int) {
	d := &e.demand
	if slot > 0 && !d.named[slot - 1] {
		d.named[slot - 1] = true
		append(&d.queue, slot - 1)
	}
}

// Has `symbol_id`'s body written, if it is one written on demand.
@(private)
demand_symbol :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	if int(symbol_id) < len(e.demand.slot_of_symbol) {
		demand_slot(e, e.demand.slot_of_symbol[symbol_id])
	}
}

// Has the consuming body of the container operation `symbol_id` written, which
// follows the operation's own.
@(private)
demand_consuming_body :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	if int(symbol_id) < len(e.demand.slot_of_symbol) && e.demand.slot_of_symbol[symbol_id] > 0 {
		demand_slot(e, e.demand.slot_of_symbol[symbol_id] + 1)
	}
}

@(private)
demand_witness :: proc(e: ^Emitter, witness: ^Witness) {
	demand_slot(e, e.demand.slot_of_witness[witness])
}

// Writes everything named, and what that names in turn, into the module in slot
// order, so that the bodies' order does not follow the order things were named
// in. The copies for a higher CPU level go last, in the order they were asked
// for.
@(private)
write_demanded :: proc(e: ^Emitter) {
	d := &e.demand
	module, copies := e.b, strings.builder_make()
	for d.next < len(d.queue) || len(e.unwritten_copies) > 0 {
		for d.next < len(d.queue) {
			slot := d.queue[d.next]
			d.next += 1
			e.b = strings.builder_make()
			write_slot(e, slot)
			d.text[slot] = strings.to_string(e.b)
		}
		e.b = copies
		emit_cpu_copies(e)
		copies = e.b
	}
	e.b = module
	for text in d.text {
		strings.write_string(&e.b, text)
	}
	strings.write_string(&e.b, strings.to_string(copies))
}

@(private = "file")
write_slot :: proc(e: ^Emitter, slot: int) {
	d := &e.demand
	switch {
	case slot < d.synth_base:
		emit_proc(e, d.procs[slot].symbol, d.procs[slot].literal)
	case slot < d.witness_base:
		member := slot - d.synth_base
		emit_synth_proc(e, e.c.synth_procs[member / 2], consuming = member % 2 == 1)
	case:
		emit_witness(e, slot - d.witness_base)
	}
}
