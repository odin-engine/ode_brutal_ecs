/*
    2026 (c) Zaya, https://github.com/zm69

    Many-to-many relations ("pairs"), unlike Relations_Table's single-parent
    model: a holder can point at any number of targets, and a target can be
    pointed at by any number of holders.
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:math"

// ODE
    import oc "ode_core"
    import oc_maps "ode_core/maps"

    Pair_Row_Id :: distinct int // index into the pair-row arrays; DELETED_INDEX = none

///////////////////////////////////////////////////////////////////////////////
// Pair_Table

    Pair_Table_Base :: struct {
        db:    ^Database,
        state: Object_State,
        id:    pair_table_id,

        presence: oc_maps.Rh_Map32, // holder eid.ix -> marker, for holders with >= 1 pair
        holders_cap: int, // enforced explicitly: Rh_Map32 rounds its own capacity up to >= 8

        pairs_cap:   int,
        pairs_count: int,

        targets:    []entity_id,   // pairs_cap
        row_holder: []entity_id,   // pairs_cap — owning holder, for freelist recycling

        // Doubly-linked list of a holder's pair rows, head-insert.
        next_pair:  []Pair_Row_Id, // pairs_cap
        prev_pair:  []Pair_Row_Id, // pairs_cap
        first_pair: []Pair_Row_Id, // entities_cap, indexed by holder.ix

        next_pair_by_target:  []Pair_Row_Id, // pairs_cap
        prev_pair_by_target:  []Pair_Row_Id, // pairs_cap
        first_pair_by_target: []Pair_Row_Id, // entities_cap, indexed by target.ix

        free_rows:  []Pair_Row_Id, // pairs_cap, freelist stack
        free_count: int,

        // targets_of() result buffer — valid only until the next call or any
        // structural change, same contract as relations_table__children_of.
        scratch: []entity_id, // pairs_cap

        data_type_info: ^runtime.Type_Info,
    }

    Pair_Table :: struct($T: typeid) {
        using base: Pair_Table_Base,
        data: []T, // pairs_cap — the only field that needs T
    }

    @(private)
    Pair_Table_Raw :: struct {
        using base: Pair_Table_Base,
        data: []byte,
    }

    @(private)
    pair_table_base__is_valid :: proc(self: ^Pair_Table_Base) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if !oc_maps.rh_map32__is_valid(&self.presence) do return false
        if self.targets == nil do return false
        if self.row_holder == nil do return false
        if self.next_pair == nil do return false
        if self.prev_pair == nil do return false
        if self.first_pair == nil do return false
        if self.next_pair_by_target == nil do return false
        if self.prev_pair_by_target == nil do return false
        if self.first_pair_by_target == nil do return false
        if self.free_rows == nil do return false
        if self.scratch == nil do return false
        if self.pairs_cap <= 0 do return false
        if self.data_type_info == nil do return false

        return true
    }

    pair_table__is_valid :: proc(self: ^Pair_Table($T)) -> bool {
        if self == nil do return false
        return pair_table_base__is_valid(&self.base)
    }

    @(private)
    pair_table_base__init :: proc(self: ^Pair_Table_Base, db: ^Database, holders_cap: int, pairs_cap: int, data_type_info: ^runtime.Type_Info, loc := #caller_location) -> Error {
        // Load factor 0.5, power of two — same convention Tag_Table used.
        oc_maps.rh_map32__init(&self.presence, math.next_power_of_two(holders_cap * 2), db.allocator, loc) or_return
        self.holders_cap = holders_cap

        self.db = db
        self.pairs_cap = pairs_cap
        self.data_type_info = data_type_info

        entities_cap := db.overbase.id_factory.cap

        self.targets    = make([]entity_id,   pairs_cap,    db.allocator) or_return
        self.row_holder = make([]entity_id,   pairs_cap,    db.allocator) or_return
        self.next_pair  = make([]Pair_Row_Id, pairs_cap,    db.allocator) or_return
        self.prev_pair  = make([]Pair_Row_Id, pairs_cap,    db.allocator) or_return
        self.first_pair = make([]Pair_Row_Id, entities_cap, db.allocator) or_return

        self.next_pair_by_target  = make([]Pair_Row_Id, pairs_cap,    db.allocator) or_return
        self.prev_pair_by_target  = make([]Pair_Row_Id, pairs_cap,    db.allocator) or_return
        self.first_pair_by_target = make([]Pair_Row_Id, entities_cap, db.allocator) or_return

        self.free_rows = make([]Pair_Row_Id, pairs_cap, db.allocator) or_return
        self.scratch   = make([]entity_id,   pairs_cap, db.allocator) or_return

        // database__attach_pair_table grows the registry on demand, so failure
        // here is only a rare OOM case — no special rollback needed.
        self.id = database__attach_pair_table(db, self) or_return

        self.state = Object_State.Normal

        pair_table_base__clear(self) or_return

        return nil
    }

    pair_table__init :: proc(self: ^Pair_Table($T), db: ^Database, holders_cap: int, pairs_cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(holders_cap > 0, loc = loc)
            assert(pairs_cap > 0, loc = loc)
        }

        pair_table_base__init(&self.base, db, holders_cap, pairs_cap, type_info_of(typeid_of(T)), loc) or_return

        self.data = make([]T, pairs_cap, db.allocator) or_return

        return nil
    }

    @(private)
    pair_table_base__terminate :: proc(self: ^Pair_Table_Base) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        database__detach_pair_table(self.db, self)

        oc_maps.rh_map32__terminate(&self.presence, self.db.allocator) or_return

        delete(self.targets, self.db.allocator) or_return
        delete(self.row_holder, self.db.allocator) or_return
        delete(self.next_pair, self.db.allocator) or_return
        delete(self.prev_pair, self.db.allocator) or_return
        delete(self.first_pair, self.db.allocator) or_return
        delete(self.next_pair_by_target, self.db.allocator) or_return
        delete(self.prev_pair_by_target, self.db.allocator) or_return
        delete(self.first_pair_by_target, self.db.allocator) or_return
        delete(self.free_rows, self.db.allocator) or_return
        delete(self.scratch, self.db.allocator) or_return

        raw := cast(^Pair_Table_Raw) self
        if raw.data != nil do delete(raw.data, self.db.allocator) or_return
        raw.data = nil

        self.targets = nil
        self.row_holder = nil
        self.next_pair = nil
        self.prev_pair = nil
        self.first_pair = nil
        self.next_pair_by_target = nil
        self.prev_pair_by_target = nil
        self.first_pair_by_target = nil
        self.free_rows = nil
        self.scratch = nil
        self.pairs_count = 0
        self.pairs_cap = 0
        self.free_count = 0
        self.data_type_info = nil

        self.db = nil
        // Not_Initialized (not Terminated), so the same struct can be re-init'd —
        // same convention as relations_table__terminate (issue #8).
        self.state = Object_State.Not_Initialized

        return nil
    }

    pair_table__terminate :: proc(self: ^Pair_Table($T)) -> Error {
        return pair_table_base__terminate(&self.base)
    }

    @(private)
    pair_table_base__reset_rows :: proc(self: ^Pair_Table_Base) {
        for i := 0; i < len(self.first_pair); i += 1 {
            self.first_pair[i] = Pair_Row_Id(DELETED_INDEX)
            self.first_pair_by_target[i] = Pair_Row_Id(DELETED_INDEX)
        }
        for i := 0; i < self.pairs_cap; i += 1 {
            self.row_holder[i].ix = DELETED_INDEX
            self.next_pair[i] = Pair_Row_Id(DELETED_INDEX)
            self.prev_pair[i] = Pair_Row_Id(DELETED_INDEX)
            self.next_pair_by_target[i] = Pair_Row_Id(DELETED_INDEX)
            self.prev_pair_by_target[i] = Pair_Row_Id(DELETED_INDEX)
            self.free_rows[i] = Pair_Row_Id(i)
        }
        self.free_count = self.pairs_cap
        self.pairs_count = 0
    }

    @(private)
    pair_table_base__clear :: proc(self: ^Pair_Table_Base) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        oc_maps.rh_map32__clear(&self.presence)
        pair_table_base__reset_rows(self)

        return nil
    }

    @(private)
    pair_table_base__memory_usage :: proc(self: ^Pair_Table_Base) -> int {
        total := oc_maps.rh_map32__memory_usage(&self.presence)

        if self.targets != nil               do total += size_of(entity_id) * self.pairs_cap
        if self.row_holder != nil            do total += size_of(entity_id) * self.pairs_cap
        if self.next_pair != nil             do total += size_of(Pair_Row_Id) * self.pairs_cap
        if self.prev_pair != nil             do total += size_of(Pair_Row_Id) * self.pairs_cap
        if self.next_pair_by_target != nil   do total += size_of(Pair_Row_Id) * self.pairs_cap
        if self.prev_pair_by_target != nil   do total += size_of(Pair_Row_Id) * self.pairs_cap
        if self.free_rows != nil             do total += size_of(Pair_Row_Id) * self.pairs_cap
        if self.scratch != nil               do total += size_of(entity_id) * self.pairs_cap
        if self.first_pair != nil            do total += size_of(Pair_Row_Id) * len(self.first_pair)
        if self.first_pair_by_target != nil  do total += size_of(Pair_Row_Id) * len(self.first_pair_by_target)
        if self.data_type_info != nil        do total += self.data_type_info.size * self.pairs_cap

        return total
    }

    pair_table__memory_usage :: proc(self: ^Pair_Table($T)) -> int {
        return size_of(self^) + pair_table_base__memory_usage(&self.base)
    }

    pair_table__len :: #force_inline proc "contextless" (self: ^Pair_Table($T)) -> int {
        return self.pairs_count
    }

    pair_table__cap :: #force_inline proc "contextless" (self: ^Pair_Table($T)) -> int {
        return self.pairs_cap
    }

    @(private)
    pair_table_base__unlink_row :: #force_inline proc(self: ^Pair_Table_Base, row: Pair_Row_Id) #no_bounds_check {
        holder := self.row_holder[row]
        target := self.targets[row]

        pv, nx := self.prev_pair[row], self.next_pair[row]
        if pv != Pair_Row_Id(DELETED_INDEX) do self.next_pair[pv] = nx
        else do self.first_pair[holder.ix] = nx
        if nx != Pair_Row_Id(DELETED_INDEX) do self.prev_pair[nx] = pv

        tpv, tnx := self.prev_pair_by_target[row], self.next_pair_by_target[row]
        if tpv != Pair_Row_Id(DELETED_INDEX) do self.next_pair_by_target[tpv] = tnx
        else do self.first_pair_by_target[target.ix] = tnx
        if tnx != Pair_Row_Id(DELETED_INDEX) do self.prev_pair_by_target[tnx] = tpv

        self.row_holder[row].ix = DELETED_INDEX
        self.next_pair[row] = Pair_Row_Id(DELETED_INDEX)
        self.prev_pair[row] = Pair_Row_Id(DELETED_INDEX)
        self.next_pair_by_target[row] = Pair_Row_Id(DELETED_INDEX)
        self.prev_pair_by_target[row] = Pair_Row_Id(DELETED_INDEX)

        self.free_rows[self.free_count] = row
        self.free_count += 1
        self.pairs_count -= 1
    }

    @(private)
    pair_table_base__add_raw :: proc(self: ^Pair_Table_Base, holder, target: entity_id, data: rawptr, loc := #caller_location) -> (row: Pair_Row_Id, err: Error) #no_bounds_check {
        row = Pair_Row_Id(DELETED_INDEX)

        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc)
        }

        database__is_entity_correct(self.db, holder) or_return
        database__is_entity_correct(self.db, target) or_return

        // Dedupe: O(#pairs for holder), same complexity class as remove/targets_of.
        r := self.first_pair[holder.ix]
        for r != Pair_Row_Id(DELETED_INDEX) {
            if self.targets[r] == target do return r, nil
            r = self.next_pair[r]
        }

        is_new_holder := oc_maps.rh_map32__get(&self.presence, u32(holder.ix)) == oc_maps.RH_MAP32_DELETED

        if self.free_count <= 0 do return Pair_Row_Id(DELETED_INDEX), oc.Core_Error.Container_Is_Full
        if is_new_holder && oc_maps.rh_map32__len(&self.presence) >= self.holders_cap {
            return Pair_Row_Id(DELETED_INDEX), oc.Core_Error.Container_Is_Full
        }

        if is_new_holder {
            oc_maps.rh_map32__add(&self.presence, u32(holder.ix), 1) or_return
        }

        self.free_count -= 1
        new_row := self.free_rows[self.free_count]

        self.targets[new_row] = target
        self.row_holder[new_row] = holder

        self.next_pair[new_row] = self.first_pair[holder.ix]
        self.prev_pair[new_row] = Pair_Row_Id(DELETED_INDEX)
        if self.first_pair[holder.ix] != Pair_Row_Id(DELETED_INDEX) do self.prev_pair[self.first_pair[holder.ix]] = new_row
        self.first_pair[holder.ix] = new_row

        self.next_pair_by_target[new_row] = self.first_pair_by_target[target.ix]
        self.prev_pair_by_target[new_row] = Pair_Row_Id(DELETED_INDEX)
        if self.first_pair_by_target[target.ix] != Pair_Row_Id(DELETED_INDEX) do self.prev_pair_by_target[self.first_pair_by_target[target.ix]] = new_row
        self.first_pair_by_target[target.ix] = new_row

        self.pairs_count += 1

        if data != nil && self.data_type_info.size > 0 {
            raw := cast(^Pair_Table_Raw) self
            dst := rawptr(uintptr(raw_data(raw.data)) + uintptr(new_row) * uintptr(self.data_type_info.size))
            mem.copy(dst, data, self.data_type_info.size)
        }

        return new_row, nil
    }

    pair_table__add :: proc(self: ^Pair_Table($T), holder: entity_id, target: entity_id, data: T, loc := #caller_location) -> (row: Pair_Row_Id, err: Error) {
        value := data
        return pair_table_base__add_raw(&self.base, holder, target, &value, loc)
    }

    @(private)
    pair_table_base__remove :: proc(self: ^Pair_Table_Base, holder: entity_id, target: entity_id, loc := #caller_location) -> Error #no_bounds_check {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc)
        }

        database__is_entity_correct(self.db, holder) or_return

        r := self.first_pair[holder.ix]
        for r != Pair_Row_Id(DELETED_INDEX) {
            if self.targets[r] == target do break
            r = self.next_pair[r]
        }

        if r == Pair_Row_Id(DELETED_INDEX) do return oc.Core_Error.Not_Found

        pair_table_base__unlink_row(self, r)

        if self.first_pair[holder.ix] == Pair_Row_Id(DELETED_INDEX) {
            oc_maps.rh_map32__remove(&self.presence, u32(holder.ix)) or_return
        }

        return nil
    }

    pair_table__remove :: proc(self: ^Pair_Table($T), holder: entity_id, target: entity_id, loc := #caller_location) -> Error {
        return pair_table_base__remove(&self.base, holder, target, loc)
    }

    @(private)
    pair_table_base__remove_all :: proc(self: ^Pair_Table_Base, holder: entity_id, loc := #caller_location) -> Error #no_bounds_check {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(self.state == Object_State.Normal, loc = loc)
        }

        database__is_entity_correct(self.db, holder) or_return

        r := self.first_pair[holder.ix]
        if r == Pair_Row_Id(DELETED_INDEX) do return nil

        for r != Pair_Row_Id(DELETED_INDEX) {
            next := self.next_pair[r]
            pair_table_base__unlink_row(self, r)
            r = next
        }

        return oc_maps.rh_map32__remove(&self.presence, u32(holder.ix))
    }

    pair_table__remove_all :: proc(self: ^Pair_Table($T), holder: entity_id, loc := #caller_location) -> Error {
        return pair_table_base__remove_all(&self.base, holder, loc)
    }

    @(private)
    pair_table_base__remove_target :: proc(self: ^Pair_Table_Base, target: entity_id) -> Error #no_bounds_check {
        r := self.first_pair_by_target[target.ix]
        for r != Pair_Row_Id(DELETED_INDEX) {
            next := self.next_pair_by_target[r]
            holder := self.row_holder[r]

            pair_table_base__unlink_row(self, r)

            if self.first_pair[holder.ix] == Pair_Row_Id(DELETED_INDEX) {
                oc_maps.rh_map32__remove(&self.presence, u32(holder.ix)) or_return
            }

            r = next
        }

        return nil
    }

    @(private)
    pair_table_base__has_pair :: proc(self: ^Pair_Table_Base, holder: entity_id, target: entity_id) -> bool #no_bounds_check {
        if database__is_entity_correct(self.db, holder) != nil do return false

        r := self.first_pair[holder.ix]
        for r != Pair_Row_Id(DELETED_INDEX) {
            if self.targets[r] == target do return true
            r = self.next_pair[r]
        }

        return false
    }

    pair_table__has_pair :: proc(self: ^Pair_Table($T), holder: entity_id, target: entity_id) -> bool {
        return pair_table_base__has_pair(&self.base, holder, target)
    }

    pair_table__has_any :: #force_inline proc(self: ^Pair_Table($T), holder: entity_id) -> bool {
        return oc_maps.rh_map32__get(&self.presence, u32(holder.ix)) != oc_maps.RH_MAP32_DELETED
    }

    @(private)
    pair_table_base__first_row :: #force_inline proc "contextless" (self: ^Pair_Table_Base, holder: entity_id) -> (row: Pair_Row_Id, ok: bool) #no_bounds_check {
        r := self.first_pair[holder.ix]
        if r == Pair_Row_Id(DELETED_INDEX) do return Pair_Row_Id(DELETED_INDEX), false
        return r, true
    }

    pair_table__first_target :: proc(self: ^Pair_Table($T), holder: entity_id) -> (target: entity_id, ok: bool) #no_bounds_check {
        target.ix = DELETED_INDEX
        if database__is_entity_correct(self.db, holder) != nil do return target, false

        r, found := pair_table_base__first_row(&self.base, holder)
        if !found do return target, false

        return self.targets[r], true
    }

    // O(1) counterpart to first_target: a pointer to that same row's payload.
    pair_table__first_data :: proc(self: ^Pair_Table($T), holder: entity_id) -> (data: ^T, ok: bool) #no_bounds_check {
        if database__is_entity_correct(self.db, holder) != nil do return nil, false

        r, found := pair_table_base__first_row(&self.base, holder)
        if !found do return nil, false

        return &self.data[r], true
    }

    @(private)
    pair_table_base__targets_of :: proc(self: ^Pair_Table_Base, holder: entity_id) -> (res: []entity_id, err: Error) #no_bounds_check {
        database__is_entity_correct(self.db, holder) or_return

        n := 0
        r := self.first_pair[holder.ix]
        for r != Pair_Row_Id(DELETED_INDEX) {
            when VALIDATIONS do assert(n < len(self.scratch), "pair links corrupted — more pairs than cap")
            self.scratch[n] = self.targets[r]
            n += 1
            r = self.next_pair[r]
        }

        return self.scratch[:n], nil
    }

    pair_table__targets_of :: proc(self: ^Pair_Table($T), holder: entity_id) -> (res: []entity_id, err: Error) {
        return pair_table_base__targets_of(&self.base, holder)
    }
