// Stable semantic identities and compilation-owned stores (compiler-plan
// A8/B5-B8). Syntax nodes contain IDs into these stores, never pointers to
// reallocating arrays or backend-specific state.
package lokec

import "core:mem"

Identifier_Id :: distinct u32
Symbol_Id     :: distinct u32
Type_Id       :: distinct u32
Package_Id    :: distinct u32

INVALID_IDENTIFIER :: Identifier_Id(0)
INVALID_SYMBOL     :: Symbol_Id(0)
INVALID_TYPE       :: Type_Id(0)
INVALID_PACKAGE    :: Package_Id(0)

TYPE_VOID        :: Type_Id(1)
TYPE_UNTYPED_INT :: Type_Id(2)
TYPE_INT         :: Type_Id(3)
TYPE_TYPE        :: Type_Id(4)

Type_Kind :: enum {
	Invalid,
	Void,
	Untyped_Int,
	Bool,
	Int,
	Float,
	String,
	Rune,
	Pointer,
	Multi_Pointer,
	Slice,
	Dynamic_Array,
	Array,
	Map,
	Distinct,
	Proc,
	Struct,
	Enum,
	Union,
	Interface,
	Dyn,
	Type,
}

Type_Info :: struct {
	kind:       Type_Kind,
	name:       Identifier_Id,
	symbol:     Symbol_Id,
	element:    Type_Id,
	key:        Type_Id,
	count:      u64,
	mutable:    bool,
	parameters: []Type_Id,
	param_modes: []Param_Mode,
	results:    []Type_Id,
	result_inout: []bool,
	convention: string,
}

Type_Key :: struct {
	kind:    Type_Kind,
	element: Type_Id,
	key:     Type_Id,
	count:   u64,
}

Const_Kind :: enum {
	Invalid,
	Integer,
	Boolean,
	Float,
	String,
	Rune,
	Nil,
	Type,
}

// Text is source/compilation backed. M2 can replace integer/float payloads
// with arbitrary-precision values without changing AST or symbol identity.
Const_Value :: struct {
	kind:       Const_Kind,
	integer:    i64,
	float:      f64,
	text:       string,
	type_value: Type_Id,
}

integer_const :: proc(value: i64) -> Const_Value {
	return Const_Value{kind = .Integer, integer = value}
}

Resolution_Kind :: enum {
	Unresolved,
	Error,
	Value,
	Type,
	Package,
	Field,
	Method,
	Procedure_Group,
	Call,
	Conversion,
	Generic_Application,
	Builtin_Operator,
	User_Operator,
}

Value_Category :: enum {
	Invalid,
	Value,
	Place,
	Type,
}

Resolution :: struct {
	kind:            Resolution_Kind,
	symbol:          Symbol_Id,
	chosen_overload: Symbol_Id,
}

Symbol_Kind :: enum {
	Invalid,
	Var,
	Const,
	Proc,
	Proc_Group,
	Type,
	Package_Alias,
	Parameter,
	Result,
	Field,
	Enum_Member,
	Builtin,
}

Symbol :: struct {
	name:        Identifier_Id,
	span:        Span,
	kind:        Symbol_Kind,
	type:        Type_Id,
	const_value: Const_Value,
	params:      []Type_Id,
	results:     []Type_Id,
	proc_type:   Type_Id,
	members:     []Symbol_Id,
	decl:        ^Decl,
	pkg:         Package_Id,
}

Scope_Kind :: enum {
	Universe,
	Package,
	Procedure,
	Local,
}

Scope :: struct {
	parent: ^Scope,
	names:  map[Identifier_Id]Symbol_Id,
	kind:   Scope_Kind,
}

Operator_Set :: struct {
	candidates: [dynamic]Symbol_Id,
}

Package :: struct {
	id:             Package_Id,
	name:           Identifier_Id,
	canonical_path: string,
	files:          [dynamic]^File,
	scope:          ^Scope,
	operators:      map[string]^Operator_Set,
}

init_semantic_stores :: proc(c: ^Compiler) {
	if c.semantic_initialized {
		return
	}
	c.semantic_initialized = true
	mem.dynamic_arena_init(&c.semantic_arena)
	c.semantic_allocator = mem.dynamic_arena_allocator(&c.semantic_arena)
	c.identifier_names = make([dynamic]string, 0, 64, c.semantic_allocator)
	c.identifier_by_name = make(map[string]Identifier_Id, c.semantic_allocator)
	c.types = make([dynamic]Type_Info, 0, 64, c.semantic_allocator)
	c.type_by_shape = make(map[Type_Key]Type_Id, c.semantic_allocator)
	c.symbols = make([dynamic]Symbol, 0, 128, c.semantic_allocator)
	c.packages = make([dynamic]Package, 0, 8, c.semantic_allocator)

	append(&c.identifier_names, "")
	append(&c.types,
		Type_Info{kind = .Invalid},
		Type_Info{kind = .Void},
		Type_Info{kind = .Untyped_Int},
		Type_Info{kind = .Int},
		Type_Info{kind = .Type},
	)
	append(&c.symbols, Symbol{})
	append(&c.packages, Package{})
}

intern_identifier :: proc(c: ^Compiler, text: string) -> Identifier_Id {
	init_semantic_stores(c)
	if text == "" {
		return INVALID_IDENTIFIER
	}
	if id, ok := c.identifier_by_name[text]; ok {
		return id
	}
	id := Identifier_Id(len(c.identifier_names))
	append(&c.identifier_names, text)
	c.identifier_by_name[text] = id
	return id
}

identifier_text :: proc(c: ^Compiler, id: Identifier_Id) -> string {
	index := int(id)
	if index <= 0 || index >= len(c.identifier_names) {
		return ""
	}
	return c.identifier_names[index]
}

new_symbol :: proc(c: ^Compiler, value: Symbol) -> Symbol_Id {
	init_semantic_stores(c)
	id := Symbol_Id(len(c.symbols))
	append(&c.symbols, value)
	return id
}

symbol_of :: proc(c: ^Compiler, id: Symbol_Id) -> ^Symbol {
	index := int(id)
	if index <= 0 || index >= len(c.symbols) {
		return nil
	}
	return &c.symbols[index]
}

new_type :: proc(c: ^Compiler, value: Type_Info) -> Type_Id {
	init_semantic_stores(c)
	id := Type_Id(len(c.types))
	append(&c.types, value)
	return id
}

intern_proc_type :: proc(
	c: ^Compiler,
	parameters: []Type_Id,
	param_modes: []Param_Mode,
	results: []Type_Id,
	result_inout: []bool,
	convention: string,
) -> Type_Id {
	init_semantic_stores(c)
	for info, index in c.types {
		if info.kind == .Proc &&
		   info.convention == convention &&
		   equal_type_ids(info.parameters, parameters) &&
		   equal_param_modes(info.param_modes, param_modes) &&
		   equal_type_ids(info.results, results) &&
		   equal_bools(info.result_inout, result_inout) {
			return Type_Id(index)
		}
	}
	parameter_copy := make([]Type_Id, len(parameters), c.semantic_allocator)
	mode_copy := make([]Param_Mode, len(param_modes), c.semantic_allocator)
	result_copy := make([]Type_Id, len(results), c.semantic_allocator)
	inout_copy := make([]bool, len(result_inout), c.semantic_allocator)
	copy(parameter_copy, parameters)
	copy(mode_copy, param_modes)
	copy(result_copy, results)
	copy(inout_copy, result_inout)
	return new_type(c, Type_Info {
		kind          = .Proc,
		parameters    = parameter_copy,
		param_modes   = mode_copy,
		results       = result_copy,
		result_inout  = inout_copy,
		convention    = convention,
	})
}

@(private = "file")
equal_type_ids :: proc(a, b: []Type_Id) -> bool {
	if len(a) != len(b) { return false }
	for value, index in a { if value != b[index] { return false } }
	return true
}

@(private = "file")
equal_param_modes :: proc(a, b: []Param_Mode) -> bool {
	if len(a) != len(b) { return false }
	for value, index in a { if value != b[index] { return false } }
	return true
}

@(private = "file")
equal_bools :: proc(a, b: []bool) -> bool {
	if len(a) != len(b) { return false }
	for value, index in a { if value != b[index] { return false } }
	return true
}

intern_type :: proc(c: ^Compiler, key: Type_Key, value: Type_Info) -> Type_Id {
	init_semantic_stores(c)
	if id, ok := c.type_by_shape[key]; ok {
		return id
	}
	id := new_type(c, value)
	c.type_by_shape[key] = id
	return id
}

type_of :: proc(c: ^Compiler, id: Type_Id) -> ^Type_Info {
	index := int(id)
	if index < 0 || index >= len(c.types) {
		return nil
	}
	return &c.types[index]
}

type_name :: proc(c: ^Compiler, id: Type_Id) -> string {
	switch id {
	case INVALID_TYPE:
		return "<invalid>"
	case TYPE_VOID:
		return "()"
	case TYPE_UNTYPED_INT:
		return "untyped int"
	case TYPE_INT:
		return "int"
	case TYPE_TYPE:
		return "type"
	}
	if info := type_of(c, id); info != nil && info.name != INVALID_IDENTIFIER {
		return identifier_text(c, info.name)
	}
	return "<type>"
}

new_scope :: proc(c: ^Compiler, parent: ^Scope, kind: Scope_Kind) -> ^Scope {
	init_semantic_stores(c)
	scope := new(Scope, c.semantic_allocator)
	scope.parent = parent
	scope.kind = kind
	scope.names = make(map[Identifier_Id]Symbol_Id, c.semantic_allocator)
	return scope
}

lookup_symbol :: proc(scope: ^Scope, name: Identifier_Id) -> Symbol_Id {
	for current := scope; current != nil; current = current.parent {
		if symbol, ok := current.names[name]; ok {
			return symbol
		}
	}
	return INVALID_SYMBOL
}

lookup_symbol_with_scope :: proc(scope: ^Scope, name: Identifier_Id) -> (Symbol_Id, ^Scope) {
	for current := scope; current != nil; current = current.parent {
		if symbol, ok := current.names[name]; ok {
			return symbol, current
		}
	}
	return INVALID_SYMBOL, nil
}

new_package :: proc(c: ^Compiler, name, canonical_path: string) -> Package_Id {
	init_semantic_stores(c)
	id := Package_Id(len(c.packages))
	pkg := Package {
		id             = id,
		name           = intern_identifier(c, name),
		canonical_path = canonical_path,
		files          = make([dynamic]^File, 0, 4, c.semantic_allocator),
		operators      = make(map[string]^Operator_Set, c.semantic_allocator),
	}
	append(&c.packages, pkg)
	return id
}

package_of :: proc(c: ^Compiler, id: Package_Id) -> ^Package {
	index := int(id)
	if index <= 0 || index >= len(c.packages) {
		return nil
	}
	return &c.packages[index]
}

add_package_file :: proc(c: ^Compiler, package_id: Package_Id, file: ^File) -> bool {
	pkg := package_of(c, package_id)
	if pkg == nil || file == nil {
		return false
	}
	append(&pkg.files, file)
	return true
}

destroy_compilation :: proc(c: ^Compiler) {
	if c.semantic_initialized {
		mem.dynamic_arena_destroy(&c.semantic_arena)
		c.semantic_initialized = false
	}
}
