// Why a provenance path was merged, for diagnostics. A flagged step also no
// longer names one place.
package lokec

Precision_Limit :: enum { Array_Elements, Depth, Width, Map_Width, Map_Keys, Map_Summary, Places, Storages }
Precision_Loss :: bit_set[Precision_Limit; u8]

path_precision :: proc(path: []Proj_Step) -> (loss: Precision_Loss) {
	for step in path { loss |= step.precision }
	return
}

merge_precision :: proc(into: ^Precision_Loss, from: Precision_Loss) -> bool {
	changed := (from & ~into^) != {}
	into^ |= from
	return changed
}

add_precision_notes :: proc(c: ^Compiler, span: Span, loss: Precision_Loss, crowded_regions := false, crowded_params := false) {
	if loss == {} && !crowded_regions && !crowded_params {
		return
	}
	if .Array_Elements in loss {
		add_notef(c, span, "provenance precision limit: fixed arrays longer than %d elements merge element borrows, as a dynamic array does past that many elements or where telling them apart would pass %d carrier paths; this value may therefore depend on other elements", CARRIER_ARRAY_ELEMENTS, CARRIER_WIDTH)
	}
	if .Depth in loss {
		add_notef(c, span, "provenance precision limit: paths below %d aggregate projection steps, or %d through a written alias, are merged", CARRIER_DEPTH, WRITTEN_ALIAS_DEPTH)
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
	if .Places in loss {
		add_notef(c, span, "provenance precision limit: a pointer that may point at more than %d places of one storage, or %d in all, is taken to point at a place they share", PROV_OFFSET_LIMIT, PROV_OFFSET_TOTAL)
	}
	if .Storages in loss {
		add_notef(c, span, "provenance precision limit: a pointer that may point into more than one storage is taken to point at each of its places in every one")
	}
	if crowded_regions {
		add_notef(c, span, "provenance precision limit: more than %d local allocator regions merge region identities", REGION_LOCAL_LIMIT)
	}
	if crowded_params {
		add_notef(c, span, "provenance precision limit: an allocator parameter past the first %d is taken for an unknown region", REGION_PARAM_LIMIT)
	}
	advice := "pass or return the needed field or element separately to preserve its provenance"
	if loss == {} && crowded_params {
		advice = "pass the allocator among the procedure's first parameters to keep its region known"
	} else if loss == {} {
		advice = "use fewer local allocator regions in the procedure to keep them apart"
	} else if loss == {.Storages} {
		advice = "choose the pointer among places of one storage to keep them apart"
	} else if loss <= {.Places, .Storages} {
		advice = "choose the pointer among fewer places to keep them apart"
	}
	add_notef(c, span, "this conservative dependency may cause the rejection; %s", advice)
}
