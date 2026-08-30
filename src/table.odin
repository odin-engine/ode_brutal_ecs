/*
    2026 (c) Zaya, https://github.com/zm69

    Table — true-SoA archetype table: N type-erased columns sharing one
    eid_to_rid/rid_to_eid index; a row (every column) moves as a single unit
    in one swap.
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:slice"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Table
//

    @(private)
    TABLE_NO_RID :: max(u32)

    Table_Column :: struct {
        type_info: ^runtime.Type_Info,
        rows: []byte,
    }

    Table :: struct {
        state: Object_State,
        id: table_id,
        db: ^Database,
        pause_packing: bool,

        columns: []Table_Column, // sorted by typeid, for binary-search lookup
        col_payload_offsets: []int,
        payload_size: int,

        rid_to_eid: []entity_id,
        eid_to_rid: []u32,

        len: int,

        cap: int,

        holes_count: int,
        first_hole_rid: int,

        last_col_type: typeid,
        last_col_idx: int,

        sync_channels_cap: int,
        sync_watchers: oc.Dense_Arr(^Sync_Channel), // allocated lazily, on first attach
    }

    table__is_valid :: proc(self: ^Table) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.id < 0 do return false
        if self.db == nil do return false
        if self.columns == nil do return false
        if self.rid_to_eid == nil do return false
        if self.eid_to_rid == nil do return false
        if self.cap <= 0 do return false

        return true
    }

    table__init :: proc(self: ^Table, db: ^Database, cap: int, component_types: []typeid, sync_channels_cap: int = SYNC_CHANNELS_CAP, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(cap > 0, loc = loc)
            assert(cap <= db.overbase.id_factory.cap, loc = loc)
            assert(cap < int(max(u32)), loc = loc)
        }

        if len(component_types) == 0 do return API_Error.Tables_Array_Should_Not_Be_Empty

        when VALIDATIONS {
            for t in component_types {
                ti := type_info_of(t)
                assert(ti != nil && ti.size != 0, "Table: component type must not be zero-sized", loc = loc)
            }

            for i in 0..<len(component_types) {
                for j in i + 1..<len(component_types) {
                    assert(component_types[i] != component_types[j], "Table: duplicate component type in component_types", loc = loc)
                }
            }
        }

        for t in component_types {
            ti := type_info_of(t)
            if ti == nil || ti.size == 0 do return API_Error.Component_Size_Cannot_Be_Zero
        }

        // Columns are stored in ascending Type_Info-address order so
        // table__column_index can binary-search instead of scanning.
        tis := make([]^runtime.Type_Info, len(component_types), db.allocator) or_return
        defer delete(tis, db.allocator)
        for t, i in component_types do tis[i] = type_info_of(t)
        for i in 1..<len(tis) {
            key := tis[i]
            j := i - 1
            for j >= 0 && uintptr(tis[j]) > uintptr(key) {
                tis[j + 1] = tis[j]
                j -= 1
            }
            tis[j + 1] = key
        }

        self.state = Object_State.Not_Initialized
        self.id = table_id(DELETED_INDEX)
        self.db = db
        self.pause_packing = false

        self.cap = cap
        self.last_col_type = nil
        self.sync_channels_cap = sync_channels_cap

        self.columns = make([]Table_Column, len(tis), db.allocator) or_return
        self.col_payload_offsets = make([]int, len(tis), db.allocator) or_return

        offset := 0
        for ti, i in tis {
            self.columns[i].type_info = ti
            self.columns[i].rows = make([]byte, cap * ti.size, db.allocator) or_return

            offset = mem.align_forward_int(offset, ti.align)
            self.col_payload_offsets[i] = offset
            offset += ti.size
        }
        self.payload_size = offset

        self.rid_to_eid = make([]entity_id, cap, db.allocator) or_return
        self.eid_to_rid = make([]u32, db.overbase.id_factory.cap, db.allocator) or_return

        self.id = database__attach_table(db, self) or_return
        self.state = Object_State.Normal

        table__clear(self) or_return

        return nil
    }

    table__terminate :: proc(self: ^Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
            assert(self.db != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        for i in 0..<self.len {
            eid := self.rid_to_eid[i]
            if is_not_set(eid) do continue
            self.db.eid_to_table[eid.ix] = nil
        }

        for ch in self.sync_watchers.items do sync_channel__on_table_terminated(ch, self.id)
        if self.sync_watchers.items != nil do oc.dense_arr__terminate(&self.sync_watchers, self.db.allocator) or_return

        database__detach_table(self.db, self)

        for &col in self.columns {
            if col.rows != nil do delete(col.rows, self.db.allocator) or_return
        }
        delete(self.columns, self.db.allocator) or_return
        delete(self.col_payload_offsets, self.db.allocator) or_return
        delete(self.rid_to_eid, self.db.allocator) or_return
        delete(self.eid_to_rid, self.db.allocator) or_return

        self.db = nil
        self.id = table_id(DELETED_INDEX)
        self.pause_packing = false
        self.state = Object_State.Not_Initialized

        return nil
    }

    table__len :: #force_inline proc "contextless" (self: ^Table) -> int {
        return self.len
    }

    table__cap :: #force_inline proc "contextless" (self: ^Table) -> int {
        return self.cap
    }

    table__get_entity_by_row_number :: #force_inline proc "contextless" (self: ^Table, #any_int row_number: int) -> entity_id {
        return self.rid_to_eid[row_number]
    }

    @(require_results)
    table__has_entity :: proc(self: ^Table, eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return false

        return self.eid_to_rid[eid.ix] != TABLE_NO_RID
    }

    @(require_results)
    table__is_in :: proc(self: ^Table, eid: entity_id) -> bool {
        when VALIDATIONS {
            assert(self != nil)
        }

        if database__is_entity_correct(self.db, eid) != nil do return false

        return self.db.eid_to_table[eid.ix] == self
    }

    table__memory_usage :: proc(self: ^Table) -> int {
        total := size_of(self^)

        if self.columns != nil {
            total += size_of(Table_Column) * len(self.columns)
            for col in self.columns {
                if col.rows != nil do total += len(col.rows)
            }
        }

        if self.col_payload_offsets != nil do total += size_of(int) * len(self.col_payload_offsets)
        if self.rid_to_eid != nil do total += size_of(entity_id) * len(self.rid_to_eid)
        if self.eid_to_rid != nil do total += size_of(u32) * len(self.eid_to_rid)

        return total
    }

    @(private)
    table__is_packing_paused :: #force_inline proc "contextless" (self: ^Table) -> bool {
        return self.db.tail_swap_paused || self.pause_packing
    }

    @(private)
    table__attach_sync_channel :: proc(self: ^Table, ch: ^Sync_Channel) -> Error {
        if self.sync_watchers.items == nil {
            oc.dense_arr__init(&self.sync_watchers, self.sync_channels_cap, self.db.allocator) or_return
        }
        for existing in self.sync_watchers.items {
            if existing == ch do return nil
        }
        _, err := oc.dense_arr__add(&self.sync_watchers, ch)
        return err
    }

    @(private)
    table__detach_sync_channel :: proc(self: ^Table, ch: ^Sync_Channel) -> Error {
        return oc.dense_arr__remove_by_value(&self.sync_watchers, ch)
    }

    @(private)
    table__column_index :: proc "contextless" (self: ^Table, id: typeid) -> int {
        if id == self.last_col_type do return self.last_col_idx

        target := uintptr(type_info_of(id))

        lo, hi := 0, len(self.columns) - 1
        for lo <= hi {
            mid := (lo + hi) / 2
            mid_ti := uintptr(self.columns[mid].type_info)
            if mid_ti == target {
                self.last_col_type = id
                self.last_col_idx = mid
                return mid
            }
            if mid_ti < target {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return -1
    }

    table__get_column_ix :: proc(self: ^Table, $T: typeid) -> int {
        return table__column_index(self, typeid_of(T))
    }

    @(private)
    table__component_ptr_by_col :: #force_inline proc "contextless" (self: ^Table, #any_int row: int, #any_int col_idx: int, $T: typeid) -> ^T #no_bounds_check {
        col := &self.columns[col_idx]
        return cast(^T) rawptr(uintptr(raw_data(col.rows)) + uintptr(row) * uintptr(size_of(T)))
    }

    @(private)
    table__component_rawptr_by_col :: #force_inline proc "contextless" (self: ^Table, #any_int row: int, #any_int col_idx: int) -> rawptr #no_bounds_check {
        col := &self.columns[col_idx]
        return rawptr(uintptr(raw_data(col.rows)) + uintptr(row) * uintptr(col.type_info.size))
    }

    @(require_results)
    table__get_component_by_row :: proc(self: ^Table, #any_int row: int, $T: typeid) -> ^T {
        idx := table__column_index(self, typeid_of(T))
        when VALIDATIONS {
            assert(idx >= 0, "Table: component type is not one of this archetype's columns")
        }
        if idx < 0 do return nil

        col := &self.columns[idx]
        #no_bounds_check {
            return cast(^T) rawptr(uintptr(raw_data(col.rows)) + uintptr(row) * uintptr(col.type_info.size))
        }
    }

    @(require_results)
    table__get_component :: proc(self: ^Table, eid: entity_id, $T: typeid) -> ^T {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        #no_bounds_check {
            rid := self.eid_to_rid[eid.ix]
            if rid == TABLE_NO_RID do return nil
            return table__get_component_by_row(self, int(rid), T)
        }
    }

    @(require_results)
    table__get_component_by_col :: proc(self: ^Table, eid: entity_id, #any_int col_ix: int, $T: typeid) -> ^T {
        when VALIDATIONS {
            assert(self != nil)
            assert(eid.ix >= 0)
            assert(col_ix >= 0 && col_ix < len(self.columns))
        }

        err := database__is_entity_correct(self.db, eid)
        if err != nil do return nil

        #no_bounds_check {
            rid := self.eid_to_rid[eid.ix]
            if rid == TABLE_NO_RID do return nil
            return table__component_ptr_by_col(self, int(rid), col_ix, T)
        }
    }

    table__set_component :: proc(self: ^Table, eid: entity_id, value: $T) -> ^T {
        c := table__get_component(self, eid, T)
        if c != nil do c^ = value
        return c
    }

    @(require_results)
    table__column_slice :: proc(self: ^Table, $T: typeid) -> []T {
        idx := table__column_index(self, typeid_of(T))
        if idx < 0 do return nil

        col := &self.columns[idx]
        return slice.from_ptr(cast(^T) raw_data(col.rows), self.len)
    }

    table__entities_slice :: #force_inline proc "contextless" (self: ^Table) -> []entity_id {
        return self.rid_to_eid[:self.len]
    }

    // Zeroes every column of `new_rid` except the ones listed in `skip` — the
    // typed create_entity1..8 overloads below pass the columns they're about
    // to overwrite anyway, so that byte range is never zeroed just to be
    // immediately clobbered. `skip` is nil (zero everything) from the plain,
    // untyped add_entity/create_entity path.
    @(private)
    table__zero_row_except :: #force_inline proc(self: ^Table, new_rid: int, skip: []int) {
        col_loop: for &col, i in self.columns {
            for s in skip {
                if i == s do continue col_loop
            }
            elem_size := col.type_info.size
            dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(new_rid) * uintptr(elem_size))
            mem.zero(dst, elem_size)
        }
    }

    @(private)
    table__add_entity_impl :: proc(self: ^Table, eid: entity_id, skip_zero: []int, loc := #caller_location) -> (err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(eid.ix >= 0, loc = loc)
        }

        database__is_entity_correct(self.db, eid) or_return

        existing := self.db.eid_to_table[eid.ix]
        if existing == self do return API_Error.Component_Already_Exist
        if existing != nil do return API_Error.Entity_Already_In_Table

        if self.len >= self.cap do return oc.Core_Error.Container_Is_Full

        new_rid := self.len

        table__zero_row_except(self, new_rid, skip_zero)

        self.eid_to_rid[eid.ix] = u32(new_rid)
        self.rid_to_eid[new_rid] = eid
        self.db.eid_to_table[eid.ix] = self

        self.len += 1

        for ch in self.sync_watchers.items do sync_channel__notify_structural(ch, self.id, eid, true)

        return nil
    }

    // Entity should not be in other table
    table__add_entity :: proc(self: ^Table, eid: entity_id, loc := #caller_location) -> (err: Error) {
        return table__add_entity_impl(self, eid, nil, loc)
    }

    @(require_results)
    table__create_entity :: proc(self: ^Table, loc := #caller_location) -> (eid: entity_id, err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
        }

        eid, err = database__create_entity(self.db)
        if err != nil do return eid, err

        aerr := table__add_entity(self, eid, loc)
        if aerr != nil {
            database__destroy_entity(self.db, eid)
            return entity_id{ix = DELETED_INDEX}, aerr
        }

        return eid, nil
    }

    // Like table__create_entity, but zeroes every column except `skip` — used
    // by create_entity1..8, which immediately overwrite those columns anyway.
    @(private)
    @(require_results)
    table__create_entity_with_rid_skip :: proc(self: ^Table, skip: []int, loc := #caller_location) -> (eid: entity_id, rid: int, err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
        }

        eid, err = database__create_entity(self.db)
        if err != nil do return eid, 0, err

        aerr := table__add_entity_impl(self, eid, skip, loc)
        if aerr != nil {
            database__destroy_entity(self.db, eid)
            return entity_id{ix = DELETED_INDEX}, 0, aerr
        }

        return eid, int(self.eid_to_rid[eid.ix]), nil
    }

    @(require_results)
    table__create_entity1 :: proc(self: ^Table, c1: $T1, loc := #caller_location) -> (eid: entity_id, err: Error) {
        i1 := table__column_index(self, typeid_of(T1))
        when VALIDATIONS do assert(i1 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)

        rid: int
        eid, rid, err = table__create_entity_with_rid_skip(self, []int{i1}, loc)
        if err != nil do return eid, err
        table__component_ptr_by_col(self, rid, i1, T1)^ = c1
        return eid, nil
    }

    @(require_results)
    table__create_entity2 :: proc(self: ^Table, c1: $T1, c2: $T2, loc := #caller_location) -> (eid: entity_id, err: Error) {
        i1 := table__column_index(self, typeid_of(T1))
        i2 := table__column_index(self, typeid_of(T2))
        when VALIDATIONS {
            assert(i1 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i2 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
        }

        rid: int
        eid, rid, err = table__create_entity_with_rid_skip(self, []int{i1, i2}, loc)
        if err != nil do return eid, err
        table__component_ptr_by_col(self, rid, i1, T1)^ = c1
        table__component_ptr_by_col(self, rid, i2, T2)^ = c2
        return eid, nil
    }

    @(require_results)
    table__create_entity3 :: proc(self: ^Table, c1: $T1, c2: $T2, c3: $T3, loc := #caller_location) -> (eid: entity_id, err: Error) {
        i1 := table__column_index(self, typeid_of(T1))
        i2 := table__column_index(self, typeid_of(T2))
        i3 := table__column_index(self, typeid_of(T3))
        when VALIDATIONS {
            assert(i1 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i2 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i3 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
        }

        rid: int
        eid, rid, err = table__create_entity_with_rid_skip(self, []int{i1, i2, i3}, loc)
        if err != nil do return eid, err
        table__component_ptr_by_col(self, rid, i1, T1)^ = c1
        table__component_ptr_by_col(self, rid, i2, T2)^ = c2
        table__component_ptr_by_col(self, rid, i3, T3)^ = c3
        return eid, nil
    }

    @(require_results)
    table__create_entity4 :: proc(self: ^Table, c1: $T1, c2: $T2, c3: $T3, c4: $T4, loc := #caller_location) -> (eid: entity_id, err: Error) {
        i1 := table__column_index(self, typeid_of(T1))
        i2 := table__column_index(self, typeid_of(T2))
        i3 := table__column_index(self, typeid_of(T3))
        i4 := table__column_index(self, typeid_of(T4))
        when VALIDATIONS {
            assert(i1 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i2 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i3 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i4 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
        }

        rid: int
        eid, rid, err = table__create_entity_with_rid_skip(self, []int{i1, i2, i3, i4}, loc)
        if err != nil do return eid, err
        table__component_ptr_by_col(self, rid, i1, T1)^ = c1
        table__component_ptr_by_col(self, rid, i2, T2)^ = c2
        table__component_ptr_by_col(self, rid, i3, T3)^ = c3
        table__component_ptr_by_col(self, rid, i4, T4)^ = c4
        return eid, nil
    }

    @(require_results)
    table__create_entity5 :: proc(self: ^Table, c1: $T1, c2: $T2, c3: $T3, c4: $T4, c5: $T5, loc := #caller_location) -> (eid: entity_id, err: Error) {
        i1 := table__column_index(self, typeid_of(T1))
        i2 := table__column_index(self, typeid_of(T2))
        i3 := table__column_index(self, typeid_of(T3))
        i4 := table__column_index(self, typeid_of(T4))
        i5 := table__column_index(self, typeid_of(T5))
        when VALIDATIONS {
            assert(i1 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i2 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i3 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i4 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i5 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
        }

        rid: int
        eid, rid, err = table__create_entity_with_rid_skip(self, []int{i1, i2, i3, i4, i5}, loc)
        if err != nil do return eid, err
        table__component_ptr_by_col(self, rid, i1, T1)^ = c1
        table__component_ptr_by_col(self, rid, i2, T2)^ = c2
        table__component_ptr_by_col(self, rid, i3, T3)^ = c3
        table__component_ptr_by_col(self, rid, i4, T4)^ = c4
        table__component_ptr_by_col(self, rid, i5, T5)^ = c5
        return eid, nil
    }

    @(require_results)
    table__create_entity6 :: proc(self: ^Table, c1: $T1, c2: $T2, c3: $T3, c4: $T4, c5: $T5, c6: $T6, loc := #caller_location) -> (eid: entity_id, err: Error) {
        i1 := table__column_index(self, typeid_of(T1))
        i2 := table__column_index(self, typeid_of(T2))
        i3 := table__column_index(self, typeid_of(T3))
        i4 := table__column_index(self, typeid_of(T4))
        i5 := table__column_index(self, typeid_of(T5))
        i6 := table__column_index(self, typeid_of(T6))
        when VALIDATIONS {
            assert(i1 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i2 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i3 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i4 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i5 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i6 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
        }

        rid: int
        eid, rid, err = table__create_entity_with_rid_skip(self, []int{i1, i2, i3, i4, i5, i6}, loc)
        if err != nil do return eid, err
        table__component_ptr_by_col(self, rid, i1, T1)^ = c1
        table__component_ptr_by_col(self, rid, i2, T2)^ = c2
        table__component_ptr_by_col(self, rid, i3, T3)^ = c3
        table__component_ptr_by_col(self, rid, i4, T4)^ = c4
        table__component_ptr_by_col(self, rid, i5, T5)^ = c5
        table__component_ptr_by_col(self, rid, i6, T6)^ = c6
        return eid, nil
    }

    @(require_results)
    table__create_entity7 :: proc(self: ^Table, c1: $T1, c2: $T2, c3: $T3, c4: $T4, c5: $T5, c6: $T6, c7: $T7, loc := #caller_location) -> (eid: entity_id, err: Error) {
        i1 := table__column_index(self, typeid_of(T1))
        i2 := table__column_index(self, typeid_of(T2))
        i3 := table__column_index(self, typeid_of(T3))
        i4 := table__column_index(self, typeid_of(T4))
        i5 := table__column_index(self, typeid_of(T5))
        i6 := table__column_index(self, typeid_of(T6))
        i7 := table__column_index(self, typeid_of(T7))
        when VALIDATIONS {
            assert(i1 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i2 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i3 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i4 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i5 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i6 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i7 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
        }

        rid: int
        eid, rid, err = table__create_entity_with_rid_skip(self, []int{i1, i2, i3, i4, i5, i6, i7}, loc)
        if err != nil do return eid, err
        table__component_ptr_by_col(self, rid, i1, T1)^ = c1
        table__component_ptr_by_col(self, rid, i2, T2)^ = c2
        table__component_ptr_by_col(self, rid, i3, T3)^ = c3
        table__component_ptr_by_col(self, rid, i4, T4)^ = c4
        table__component_ptr_by_col(self, rid, i5, T5)^ = c5
        table__component_ptr_by_col(self, rid, i6, T6)^ = c6
        table__component_ptr_by_col(self, rid, i7, T7)^ = c7
        return eid, nil
    }

    @(require_results)
    table__create_entity8 :: proc(self: ^Table, c1: $T1, c2: $T2, c3: $T3, c4: $T4, c5: $T5, c6: $T6, c7: $T7, c8: $T8, loc := #caller_location) -> (eid: entity_id, err: Error) {
        i1 := table__column_index(self, typeid_of(T1))
        i2 := table__column_index(self, typeid_of(T2))
        i3 := table__column_index(self, typeid_of(T3))
        i4 := table__column_index(self, typeid_of(T4))
        i5 := table__column_index(self, typeid_of(T5))
        i6 := table__column_index(self, typeid_of(T6))
        i7 := table__column_index(self, typeid_of(T7))
        i8 := table__column_index(self, typeid_of(T8))
        when VALIDATIONS {
            assert(i1 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i2 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i3 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i4 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i5 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i6 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i7 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
            assert(i8 >= 0, "Table: component type is not one of this archetype's columns", loc = loc)
        }

        rid: int
        eid, rid, err = table__create_entity_with_rid_skip(self, []int{i1, i2, i3, i4, i5, i6, i7, i8}, loc)
        if err != nil do return eid, err
        table__component_ptr_by_col(self, rid, i1, T1)^ = c1
        table__component_ptr_by_col(self, rid, i2, T2)^ = c2
        table__component_ptr_by_col(self, rid, i3, T3)^ = c3
        table__component_ptr_by_col(self, rid, i4, T4)^ = c4
        table__component_ptr_by_col(self, rid, i5, T5)^ = c5
        table__component_ptr_by_col(self, rid, i6, T6)^ = c6
        table__component_ptr_by_col(self, rid, i7, T7)^ = c7
        table__component_ptr_by_col(self, rid, i8, T8)^ = c8
        return eid, nil
    }

    table__remove_entity :: proc(self: ^Table, target_eid: entity_id, loc := #caller_location) -> (err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(target_eid.ix >= 0, loc = loc)
        }

        database__is_entity_correct(self.db, target_eid) or_return

        if self.len <= 0 do return oc.Core_Error.Not_Found

        target_rid := self.eid_to_rid[target_eid.ix]
        if target_rid == TABLE_NO_RID do return oc.Core_Error.Not_Found

        for ch in self.sync_watchers.items do sync_channel__notify_structural(ch, self.id, target_eid, false)

        paused := table__is_packing_paused(self)

        if paused {
            self.eid_to_rid[target_eid.ix] = TABLE_NO_RID
            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for &col in self.columns {
                elem_size := col.type_info.size
                dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(target_rid) * uintptr(elem_size))
                mem.zero(dst, elem_size)
            }

            if int(target_rid) == self.len - 1 {
                self.len -= 1
                for self.len > 0 && is_not_set(self.rid_to_eid[self.len - 1]) {
                    self.len -= 1
                    self.holes_count -= 1
                }
            } else {
                self.holes_count += 1
                if int(target_rid) < self.first_hole_rid do self.first_hole_rid = int(target_rid)
            }

            if self.db.eid_to_table[target_eid.ix] == self do self.db.eid_to_table[target_eid.ix] = nil
            return nil
        }

        tail_rid := self.len - 1

        if int(target_rid) == tail_rid {
            self.eid_to_rid[target_eid.ix] = TABLE_NO_RID
            self.rid_to_eid[target_rid].ix = DELETED_INDEX

            for &col in self.columns {
                elem_size := col.type_info.size
                dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(target_rid) * uintptr(elem_size))
                mem.zero(dst, elem_size)
            }
        } else {
            tail_eid := self.rid_to_eid[tail_rid]
            when VALIDATIONS do assert(!is_not_set(tail_eid))

            for &col in self.columns {
                elem_size := col.type_info.size
                dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(target_rid) * uintptr(elem_size))
                src := rawptr(uintptr(raw_data(col.rows)) + uintptr(tail_rid) * uintptr(elem_size))
                mem.copy(dst, src, elem_size)
                mem.zero(src, elem_size)
            }

            self.eid_to_rid[tail_eid.ix] = target_rid
            self.eid_to_rid[target_eid.ix] = TABLE_NO_RID

            self.rid_to_eid[target_rid] = tail_eid
            self.rid_to_eid[tail_rid].ix = DELETED_INDEX
        }

        self.len -= 1

        if self.db.eid_to_table[target_eid.ix] == self do self.db.eid_to_table[target_eid.ix] = nil

        return nil
    }

    @(private)
    table__has_column :: #force_inline proc "contextless" (self: ^Table, id: typeid) -> bool {
        return table__column_index(self, id) >= 0
    }

    @(private)
    table__move_entity_impl :: proc(eid: entity_id, from: ^Table, to: ^Table, sudo: bool, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(from != nil, loc = loc)
            assert(to != nil, loc = loc)
        }

        db := from.db
        database__is_entity_correct(db, eid) or_return

        if db.eid_to_table[eid.ix] != from do return API_Error.Entity_Not_In_Table

        // Checked unconditionally (not just under VALIDATIONS) so a plain
        // move never silently degrades into sudo_move's drop-what-doesn't-fit
        // behavior in a release build (-define:ECS_VALIDATIONS=false).
        if !sudo {
            for col in from.columns {
                if !table__has_column(to, col.type_info.id) do return API_Error.Table_To_Cannot_Contain_Entity
            }
        }

        src_rid := int(from.eid_to_rid[eid.ix])

        // Temporarily untable the entity so table__add_entity below doesn't
        // see it as already belonging to from.
        db.eid_to_table[eid.ix] = nil
        if aerr := table__add_entity(to, eid, loc); aerr != nil {
            db.eid_to_table[eid.ix] = from
            return aerr
        }

        dst_rid := int(to.eid_to_rid[eid.ix])

        for &col in from.columns {
            dst_idx := table__column_index(to, col.type_info.id)
            if dst_idx < 0 do continue // sudo: to doesn't have this column, drop it
            elem_size := col.type_info.size
            src := rawptr(uintptr(raw_data(col.rows)) + uintptr(src_rid) * uintptr(elem_size))
            dst := table__component_rawptr_by_col(to, dst_rid, dst_idx)
            mem.copy(dst, src, elem_size)
        }

        return table__remove_entity(from, eid, loc)
    }

    table__move_entity :: proc(eid: entity_id, from: ^Table, to: ^Table, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(from != nil, loc = loc)
            assert(to != nil, loc = loc)
            for col in from.columns {
                assert(table__has_column(to, col.type_info.id), "move_entity: to does not contain all of from's component types", loc = loc)
            }
        }
        return table__move_entity_impl(eid, from, to, sudo = false, loc = loc)
    }

    table__sudo_move_entity :: proc(eid: entity_id, from: ^Table, to: ^Table, loc := #caller_location) -> Error {
        return table__move_entity_impl(eid, from, to, sudo = true, loc = loc)
    }

    @(private)
    table__copy_entity_impl :: proc(eid: entity_id, from: ^Table, to: ^Table, sudo: bool, loc := #caller_location) -> (new_eid: entity_id, err: Error) {
        when VALIDATIONS {
            assert(from != nil, loc = loc)
            assert(to != nil, loc = loc)
        }

        if ierr := database__is_entity_correct(from.db, eid); ierr != nil do return entity_id{ix = DELETED_INDEX}, ierr

        if from.db.eid_to_table[eid.ix] != from do return entity_id{ix = DELETED_INDEX}, API_Error.Entity_Not_In_Table

        // Checked unconditionally (not just under VALIDATIONS) so a plain
        // copy never silently degrades into sudo_copy's drop-what-doesn't-fit
        // behavior in a release build (-define:ECS_VALIDATIONS=false).
        if !sudo {
            for col in from.columns {
                if !table__has_column(to, col.type_info.id) do return entity_id{ix = DELETED_INDEX}, API_Error.Table_To_Cannot_Contain_Entity
            }
        }

        src_rid := int(from.eid_to_rid[eid.ix])

        new_eid, err = table__create_entity(to, loc)
        if err != nil do return entity_id{ix = DELETED_INDEX}, err

        dst_rid := int(to.eid_to_rid[new_eid.ix])

        for &col in from.columns {
            dst_idx := table__column_index(to, col.type_info.id)
            if dst_idx < 0 do continue // sudo: to doesn't have this column, drop it
            elem_size := col.type_info.size
            src := rawptr(uintptr(raw_data(col.rows)) + uintptr(src_rid) * uintptr(elem_size))
            dst := table__component_rawptr_by_col(to, dst_rid, dst_idx)
            mem.copy(dst, src, elem_size)
        }

        return new_eid, nil
    }

    @(require_results)
    table__copy_entity :: proc(eid: entity_id, from: ^Table, to: ^Table, loc := #caller_location) -> (new_eid: entity_id, err: Error) {
        when VALIDATIONS {
            assert(from != nil, loc = loc)
            assert(to != nil, loc = loc)
            for col in from.columns {
                assert(table__has_column(to, col.type_info.id), "copy_entity: to does not contain all of from's component types", loc = loc)
            }
        }
        return table__copy_entity_impl(eid, from, to, sudo = false, loc = loc)
    }

    @(require_results)
    table__sudo_copy_entity :: proc(eid: entity_id, from: ^Table, to: ^Table, loc := #caller_location) -> (new_eid: entity_id, err: Error) {
        return table__copy_entity_impl(eid, from, to, sudo = true, loc = loc)
    }

    table__pack :: proc(self: ^Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        if self.state != Object_State.Normal do return API_Error.Object_Invalid
        if self.holes_count <= 0 {
            self.first_hole_rid = max(int)
            return nil
        }

        front := self.first_hole_rid
        back := self.len - 1

        for self.holes_count > 0 {
            for back >= 0 && is_not_set(self.rid_to_eid[back]) {
                back -= 1
                self.holes_count -= 1
            }
            if self.holes_count <= 0 do break

            for !is_not_set(self.rid_to_eid[front]) do front += 1

            for &col in self.columns {
                elem_size := col.type_info.size
                dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(front) * uintptr(elem_size))
                src := rawptr(uintptr(raw_data(col.rows)) + uintptr(back) * uintptr(elem_size))
                mem.copy(dst, src, elem_size)
                mem.zero(src, elem_size)
            }

            moved_eid := self.rid_to_eid[back]
            self.rid_to_eid[front] = moved_eid
            self.rid_to_eid[back].ix = DELETED_INDEX
            self.eid_to_rid[moved_eid.ix] = u32(front)

            back -= 1
            front += 1
            self.holes_count -= 1
        }

        self.len = back + 1
        self.first_hole_rid = max(int)

        return nil
    }

    table__pause_packing :: proc(self: ^Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = true
        return nil
    }

    table__resume_packing :: proc(self: ^Table) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        self.pause_packing = false
        return table__pack(self)
    }

    table__clear :: proc(self: ^Table) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        if self.rid_to_eid != nil {
            for i := 0; i < self.cap; i += 1 do self.rid_to_eid[i].ix = DELETED_INDEX
        }

        slice.fill(self.eid_to_rid, TABLE_NO_RID)

        for &col in self.columns {
            if col.rows != nil do mem.zero(raw_data(col.rows), len(col.rows))
        }

        self.len = 0
        self.holes_count = 0
        self.first_hole_rid = max(int)

        return nil
    }

    @(private)
    table__swap_rows :: proc(self: ^Table, #any_int rid_a: int, #any_int rid_b: int) #no_bounds_check {
        if rid_a == rid_b do return

        for &col in self.columns {
            elem_size := col.type_info.size
            pa := rawptr(uintptr(raw_data(col.rows)) + uintptr(rid_a) * uintptr(elem_size))
            pb := rawptr(uintptr(raw_data(col.rows)) + uintptr(rid_b) * uintptr(elem_size))
            slice.ptr_swap_non_overlapping(pa, pb, elem_size)
        }

        eid_a := self.rid_to_eid[rid_a]
        eid_b := self.rid_to_eid[rid_b]
        self.rid_to_eid[rid_a] = eid_b
        self.rid_to_eid[rid_b] = eid_a
        self.eid_to_rid[eid_a.ix] = u32(rid_b)
        self.eid_to_rid[eid_b.ix] = u32(rid_a)
    }

    @(private)
    table__add_entity_from_payload :: proc(self: ^Table, eid: entity_id, data: rawptr) -> (component: rawptr, err: Error) {
        aerr := table__add_entity(self, eid)
        if aerr != nil && aerr != API_Error.Component_Already_Exist do return nil, aerr

        if data != nil {
            rid := self.eid_to_rid[eid.ix]
            for &col, i in self.columns {
                elem_size := col.type_info.size
                src := rawptr(uintptr(data) + uintptr(self.col_payload_offsets[i]))
                dst := rawptr(uintptr(raw_data(col.rows)) + uintptr(rid) * uintptr(elem_size))
                mem.copy(dst, src, elem_size)
            }
        }

        return nil, aerr
    }
