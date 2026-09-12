// Explanatory metadata for bounded provenance analysis. These facts never
// affect acceptance, type identity, or the generated program.
package lokec

Precision_Limit :: enum { Array_Elements, Depth, Width, Map_Width, Map_Keys, Map_Summary }
Precision_Loss :: bit_set[Precision_Limit; u8]

path_precision :: proc(path: []Proj_Step) -> (loss: Precision_Loss) {
	for step in path { loss |= step.precision }
	return
}

precision_equal :: proc(a, b: []Precision_Loss) -> bool {
	for value, index in a { if value != b[index] { return false } }
	return true
}

merge_precision :: proc(into: ^Precision_Loss, from: Precision_Loss) -> bool {
	changed := (from & ~into^) != {}
	into^ |= from
	return changed
}

add_precision_notes :: proc(c: ^Compiler, span: Span, loss: Precision_Loss) {
	if .Array_Elements in loss {
		add_notef(c, span, "provenance precision limit: fixed arrays longer than %d elements merge element borrows; this value may therefore depend on other elements", CARRIER_ARRAY_ELEMENTS)
	}
	if .Depth in loss {
		add_notef(c, span, "provenance precision limit: paths below %d aggregate projection steps are merged", CARRIER_DEPTH)
	}
	if .Width in loss {
		add_notef(c, span, "provenance precision limit: more than %d carrier paths collapse to one whole-value dependency", CARRIER_WIDTH)
	}
	if .Map_Width in loss {
		add_notef(c, span, "provenance precision limit: recursive map entries or entries with more than %d key/value carrier paths merge borrows across keys", MAP_KEY_PATH_LIMIT)
	}
	if .Map_Keys in loss {
		add_notef(c, span, "provenance precision limit: only %d constant map keys per procedure are distinguished; additional keys overlap all entries", MAP_KEY_SLOTS)
	}
	if .Map_Summary in loss {
		add_notef(c, span, "provenance precision loss: procedure result contracts merge map entry identities across calls, preserving only enclosing paths and the key/value distinction")
	}
	if loss != {} {
		add_notef(c, span, "this conservative dependency may cause the rejection; pass or return the needed field or element separately to preserve its provenance")
	}
}
