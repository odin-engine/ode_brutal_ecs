/*
    2026 (c) Zaya, https://github.com/zm69 
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:slice"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Database

    Database :: struct {
        allocator: runtime.Allocator,
        state: Object_State,

        overbase: ^Overbase,
        owns_overbase: bool,
        overbase_storage: Overbase,

        tables: oc.Sparse_Arr(Table),

        // Every entity belongs to at most one Table; nil means untabled.
        eid_to_table: []^Table,

        relations: ^Relations_Table,

        pair_tables: oc.Sparse_Arr(Pair_Table_Base),

        tail_swap_paused: bool,

        destroying_eid_ix: int,
    }

    database__is_valid :: proc(self: ^Database) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.overbase == nil do return false
        if !overbase__is_valid(self.overbase) do return false
        if !oc.sparse_arr__is_valid(&self.tables) do return false
        if !oc.sparse_arr__is_valid(&self.pair_tables) do return false
        if self.eid_to_table == nil do return false

        return true
    }

    database__init :: proc(self: ^Database, entities_cap: u32, allocator := context.allocator, tables_cap: int = TABLES_CAP, pair_tables_cap: int = PAIR_TABLES_CAP) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Not_Initialized)
            assert(tables_cap > 1)
        }

        if entities_cap == 0 do return API_Error.Entities_Cap_Should_Be_Greater_Than_Zero

        self.tail_swap_paused = false
        self.destroying_eid_ix = DELETED_INDEX

        self.allocator = allocator

        overbase__init(&self.overbase_storage, entities_cap, databases_cap = 1, allocator = self.allocator) or_return
        self.overbase = &self.overbase_storage
        self.owns_overbase = true
        overbase__attach_database(self.overbase, self) or_return

        oc.sparse_arr__init(&self.tables, tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.pair_tables, pair_tables_cap, self.allocator) or_return

        self.eid_to_table = make([]^Table, int(entities_cap), self.allocator) or_return

        self.state = Object_State.Normal

        assert(database__is_valid(self))

        return nil
    }

    database__init_from_overbase :: proc(self: ^Database, overbase: ^Overbase, allocator: Maybe(runtime.Allocator) = nil, tables_cap: int = TABLES_CAP, pair_tables_cap: int = PAIR_TABLES_CAP) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Not_Initialized)
            assert(overbase != nil)
            assert(overbase__is_valid(overbase))
            assert(tables_cap > 1)
        }

        self.tail_swap_paused = false
        self.destroying_eid_ix = DELETED_INDEX

        self.allocator = allocator.? or_else overbase.allocator
        self.overbase = overbase
        self.owns_overbase = false
        overbase__attach_database(self.overbase, self) or_return

        oc.sparse_arr__init(&self.tables, tables_cap, self.allocator) or_return
        oc.sparse_arr__init(&self.pair_tables, pair_tables_cap, self.allocator) or_return

        self.eid_to_table = make([]^Table, self.overbase.id_factory.cap, self.allocator) or_return

        self.state = Object_State.Normal

        assert(database__is_valid(self))

        return nil
    }

    database__terminate :: proc(self: ^Database) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        for pt in self.pair_tables.items {
            if pt == nil do continue
            if pt.state == Object_State.Normal do pair_table_base__terminate(pt) or_return
        }
        oc.sparse_arr__terminate(&self.pair_tables, self.allocator) or_return

        for table in self.tables.items {
            if table == nil do continue
            if table.state == Object_State.Normal do table__terminate(table) or_return
        }
        oc.sparse_arr__terminate(&self.tables, self.allocator) or_return

        if self.eid_to_table != nil {
            delete(self.eid_to_table, self.allocator) or_return
            self.eid_to_table = nil
        }

        if self.relations != nil && self.relations.state == Object_State.Normal {
            relations_table__terminate(self.relations) or_return
        }
        self.relations = nil

        if self.overbase != nil {
            overbase__detach_database(self.overbase, self)
            if self.owns_overbase {
                overbase__terminate(self.overbase) or_return
            }
        }
        self.overbase = nil
        self.owns_overbase = false

        self.state = Object_State.Not_Initialized
        return nil
    }

    database__clear :: proc(self: ^Database) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.eid_to_table != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        err: Error

        for table in self.tables.items {
            if table == nil do continue
            terr := table__clear(table)
            if err == nil do err = terr
        }

        if self.relations != nil {
            rerr := relations_table__clear(self.relations)
            if err == nil do err = rerr
        }

        slice.zero(self.eid_to_table)

        if self.owns_overbase {
            oc.ix_gen_factory__clear(&self.overbase.id_factory, bump_gen = true)
        }

        self.tail_swap_paused = false

        return err
    }

    @(require_results)
    database__create_entity :: proc(self: ^Database) -> (entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }

        return overbase__create_entity(self.overbase)
    }

    database__destroy_entity :: #force_inline proc(self: ^Database, eid: entity_id, destroy_children := false) -> Error  {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }

        return overbase__destroy_entity(self.overbase, eid, destroy_children)
    }

    @(private)
    database__destroy_entity_local :: #force_inline proc(self: ^Database, eid: entity_id, destroy_children: bool) -> Error {
        rt := self.relations
        if rt != nil && rt.state == Object_State.Normal {
            if destroy_children && rt.children_count[eid.ix] > 0 {
                tail := 0
                #no_bounds_check {
                    c := rt.first_child[eid.ix]
                    for !is_not_set(c) {
                        when VALIDATIONS do assert(tail < len(rt.scratch), "relations links corrupted — descendant count exceeds cap")
                        rt.scratch[tail] = c
                        tail += 1
                        c = rt.next_sibling[c.ix]
                    }

                    for head := 0; head < tail; head += 1 {
                        c = rt.first_child[rt.scratch[head].ix]
                        for !is_not_set(c) {
                            when VALIDATIONS do assert(tail < len(rt.scratch), "relations links corrupted — descendant count exceeds cap")
                            rt.scratch[tail] = c
                            tail += 1
                            c = rt.next_sibling[c.ix]
                        }
                    }
                }

                for i := tail - 1; i >= 0; i -= 1 {
                    overbase__destroy_entity_impl(self.overbase, rt.scratch[i], false, tolerate_expired = true) or_return
                }
            }

            relations_table__unlink_entity(rt, eid)
        }

        self.destroying_eid_ix = eid.ix
        defer self.destroying_eid_ix = DELETED_INDEX

        table := self.eid_to_table[eid.ix]
        if table != nil {
            table__remove_entity(table, eid) or_return
        }

        for pt in self.pair_tables.items {
            if pt == nil || pt.state != Object_State.Normal do continue
            pair_table_base__remove_target(pt, eid) or_return
            pair_table_base__remove_all(pt, eid) or_return
        }

        return nil
    }

    @(require_results)
    database__get_entity :: #force_inline proc "contextless" (self: ^Database, #any_int index: int, loc := #caller_location) -> entity_id {
        return overbase__get_entity(self.overbase, index, loc)
    }

    @(require_results)
    database__entities_len :: #force_inline proc "contextless" (self: ^Database) -> int {
        return overbase__entities_len(self.overbase)
    }

    @(require_results)
    database__is_entity_expired :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> bool {
        return overbase__is_entity_expired(self.overbase, eid)
    }

    @(require_results)
    database__get_table :: proc(self: ^Database, eid: entity_id) -> (table: ^Table, err: Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        database__is_entity_correct(self, eid) or_return
        return self.eid_to_table[eid.ix], nil
    }

    @(require_results)
    database__is_in :: proc(self: ^Database, eid: entity_id, table: ^Table) -> bool {
        when VALIDATIONS {
            assert(self != nil)
        }
        if database__is_entity_correct(self, eid) != nil do return false
        return self.eid_to_table[eid.ix] == table
    }

    database__pause_packing :: proc(self: ^Database) {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Normal)
        }

        self.tail_swap_paused = true
    }

    database__resume_packing :: proc(self: ^Database) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.state == Object_State.Normal)
        }

        self.tail_swap_paused = false

        // Pack all tables even if one reports an error; first error is reported.
        err: Error
        for table in self.tables.items {
            if table == nil || table.state != Object_State.Normal do continue
            terr := table__pack(table)
            if err == nil do err = terr
        }

        return err
    }

    database__memory_usage :: proc (self: ^Database) -> int {
        total := size_of(self^)

        if self.owns_overbase do total += overbase__memory_usage(self.overbase)
        for table in self.tables.items {
            if table != nil do total += table__memory_usage(table)
        }

        if self.relations != nil do total += relations_table__memory_usage(self.relations)

        for pt in self.pair_tables.items {
            if pt != nil do total += pair_table_base__memory_usage(pt)
        }

        return total
    }

    database__set_parent :: proc(self: ^Database, child: entity_id, parent: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
        }
        if self.relations == nil do return API_Error.Relations_Table_Not_Created
        return relations_table__set_parent(self.relations, child, parent, loc)
    }

    database__remove_parent :: proc(self: ^Database, child: entity_id, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
        }
        if self.relations == nil do return API_Error.Relations_Table_Not_Created
        return relations_table__remove_parent(self.relations, child, loc)
    }

    database__parent_of :: proc(self: ^Database, eid: entity_id) -> (entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return entity_id{ix = DELETED_INDEX}, API_Error.Relations_Table_Not_Created
        return relations_table__parent_of(self.relations, eid)
    }

    database__children_of :: proc(self: ^Database, parent: entity_id) -> ([]entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return nil, API_Error.Relations_Table_Not_Created
        return relations_table__children_of(self.relations, parent)
    }

    database__children_count :: proc(self: ^Database, eid: entity_id) -> (int, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return 0, API_Error.Relations_Table_Not_Created
        return relations_table__children_count(self.relations, eid)
    }

    database__is_child_of :: proc(self: ^Database, a: entity_id, b: entity_id) -> (bool, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return false, API_Error.Relations_Table_Not_Created
        return relations_table__is_child_of(self.relations, a, b)
    }

    database__is_parent_of :: proc(self: ^Database, a: entity_id, b: entity_id) -> (bool, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return false, API_Error.Relations_Table_Not_Created
        return relations_table__is_parent_of(self.relations, a, b)
    }

    database__has_relations :: proc(self: ^Database, eid: entity_id) -> (bool, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return false, API_Error.Relations_Table_Not_Created
        return relations_table__has_relations(self.relations, eid)
    }

    database__is_relation_of :: proc(self: ^Database, target: entity_id, eid: entity_id) -> (bool, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return false, API_Error.Relations_Table_Not_Created
        return relations_table__is_relation_of(self.relations, target, eid)
    }

    database__is_root :: proc(self: ^Database, eid: entity_id) -> (bool, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return false, API_Error.Relations_Table_Not_Created
        return relations_table__is_root(self.relations, eid)
    }

    database__roots :: proc(self: ^Database) -> ([]entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return nil, API_Error.Relations_Table_Not_Created
        return relations_table__roots(self.relations)
    }

    database__walk_subtree :: proc(self: ^Database, root: entity_id) -> ([]entity_id, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return nil, API_Error.Relations_Table_Not_Created
        return relations_table__walk_subtree(self.relations, root)
    }

    database__walk_hierarchy :: proc(self: ^Database) -> ([]entity_id, []int, Error) {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.relations == nil do return nil, nil, API_Error.Relations_Table_Not_Created
        return relations_table__walk_hierarchy(self.relations)
    }

///////////////////////////////////////////////////////////////////////////////
// Private

    @(private)
    database__attach_table :: proc(self: ^Database, table: ^Table) -> (id: table_id, err: Error) {
        raw_id: int
        raw_id, err = oc.sparse_arr__add_growing(&self.tables, table, self.allocator)
        if err != nil do return DELETED_INDEX, err

        return cast(table_id) raw_id, nil
    }

    @(private)
    database__detach_table :: proc(self: ^Database, table: ^Table) {
        oc.sparse_arr__remove_by_index(&self.tables, cast(int) table.id)
    }

    @(private)
    database__attach_pair_table :: proc(self: ^Database, pt: ^Pair_Table_Base) -> (pair_table_id, Error) {
        id, err := oc.sparse_arr__add_growing(&self.pair_tables, pt, self.allocator)
        if err != nil do return DELETED_INDEX, err

        return cast(pair_table_id) id, nil
    }

    @(private)
    database__detach_pair_table :: proc(self: ^Database, pt: ^Pair_Table_Base) {
        oc.sparse_arr__remove_by_index(&self.pair_tables, cast(int) pt.id)
    }

    @(private)
    database__is_entity_correct :: #force_inline proc "contextless" (self: ^Database, eid: entity_id) -> Error {
        return overbase__is_entity_correct(self.overbase, eid)
    }