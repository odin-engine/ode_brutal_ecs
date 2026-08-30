/*
    2026 (c) Zaya, https://github.com/zm69

    WARNING: This feature is in experimental stage and is not yet considered stable.
             The API may change in future releases.

    Off by default — build with -define:ECS_SYNC_ENABLED=true to compile it in
    (see SYNC_ENABLED's doc comment in ecs.odin).

    Sync — delta-change replication, built for sending over an unreliable
    transport (UDP) with minimal traffic: collect_delta emits only the bytes
    of the COLUMNS that actually changed, for only the entities currently
    live in a registered Table, since the last collect. Reliability (acks,
    retries, sequencing) is deliberately NOT this file's job — a Sync_Channel
    only answers "what changed since I last asked", and a Sync_Decoder only
    answers "apply these bytes"; the caller owns the socket and the delivery
    guarantees. For a full one-shot dump of the whole Database (e.g. a
    client's very first sync on join), use serialization.odin's
    database__serialize/deserialize instead — sync_channel__resync makes the
    two compose correctly.

    A whole Table is registered at once (every one of its columns); the diff
    granularity is per-column, not per-struct-field, since a Table can carry
    an arbitrary number of typed columns. There is no per-write touch
    tracking — a write goes through a raw pointer returned by get_component,
    with no interception point — so collect_delta instead diffs every live
    row of a registered table against its shadow copy each call. Structural
    add/remove events are still tracked explicitly (from table__add_entity/
    remove_entity) so a decoder can add/remove rows and the shadow is zeroed
    on remove — keyed by entity_id.ix, not row id, since rid moves under
    tail-swap/pack while entity_id does not.
*/
package ode_ecs

// Base
    import "base:runtime"

// Core
    import "core:mem"
    import "core:testing"

// ODE
    import oc "ode_core"

///////////////////////////////////////////////////////////////////////////////
// Wire format — tight, unpadded (every byte matters for UDP, unlike the
// 8-byte-aligned snapshot format in serialization.odin).

    @(private)
    SYNC_MAGIC :: u32(0x5345_444F) // "ODES" as little-endian bytes

    @(private)
    SYNC_VERSION :: u8(2)

    @(private)
    Sync_Header :: struct #packed {
        magic:                u32,
        version:              u8,
        _pad:                 u8,
        structural_count:     u16,
        table_section_count:  u16,
        _pad2:                u16,
    }

    @(private)
    Sync_Structural_Wire :: struct #packed {
        eid:      entity_id,
        table_id: u16,
        added:    u8,
    }

    @(private)
    Sync_Table_Section_Header :: struct #packed {
        table_id:     u32,
        entity_count: u32,
    }

///////////////////////////////////////////////////////////////////////////////

    @(private)
    Sync_Column :: struct {
        offset: int, // byte offset into a row's shadow slot
        size:   int,
    }

    @(private)
    Sync_Table_Entry :: struct {
        table:    ^Table, // nil once the table has been terminated
        table_id: table_id,
        row_size: int,
        columns:  []Sync_Column,

        shadow: []byte, // entities_cap * row_size, keyed by eid.ix
    }

    @(private)
    Sync_Structural_Event :: struct {
        eid:      entity_id,
        table_id: table_id,
        added:    bool,
    }

    Sync_Channel :: struct {
        state: Object_State,
        db:    ^Database,

        table_id_to_entry: []int, // len == TABLES_CAP, DELETED_INDEX when that table_id isn't registered
        entries:            []Sync_Table_Entry, // preallocated, len == tables_cap passed to init
        entries_count:      int,

        structural_events: oc.Dense_Arr(Sync_Structural_Event),
    }

    sync_channel__is_valid :: proc(self: ^Sync_Channel) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.db == nil do return false
        if self.table_id_to_entry == nil do return false
        if self.entries == nil do return false
        if !oc.dense_arr__is_valid(&self.structural_events) do return false

        return true
    }

    sync_channel__init :: proc(self: ^Sync_Channel, db: ^Database, tables_cap: int, structural_events_cap: int = 256, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(tables_cap > 0, loc = loc)
            assert(structural_events_cap > 0, loc = loc)
        }

        self.db = db
        self.entries_count = 0

        self.table_id_to_entry = make([]int, TABLES_CAP, db.allocator) or_return
        for i in 0..<len(self.table_id_to_entry) do self.table_id_to_entry[i] = DELETED_INDEX

        self.entries = make([]Sync_Table_Entry, tables_cap, db.allocator) or_return

        oc.dense_arr__init(&self.structural_events, structural_events_cap, db.allocator) or_return

        self.state = Object_State.Normal
        return nil
    }

    sync_channel__terminate :: proc(self: ^Sync_Channel) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        for i in 0..<self.entries_count {
            e := &self.entries[i]
            if e.table != nil {
                derr := table__detach_sync_channel(e.table, self)
                if derr != nil && derr != oc.Core_Error.Not_Found do return derr
            }
            if e.shadow != nil do delete(e.shadow, self.db.allocator) or_return
            if e.columns != nil do delete(e.columns, self.db.allocator) or_return
        }

        delete(self.entries, self.db.allocator) or_return
        delete(self.table_id_to_entry, self.db.allocator) or_return
        oc.dense_arr__terminate(&self.structural_events, self.db.allocator) or_return

        self.entries = nil
        self.table_id_to_entry = nil
        self.entries_count = 0
        self.db = nil

        self.state = Object_State.Not_Initialized
        return nil
    }

    sync_channel__clear :: proc(self: ^Sync_Channel) -> Error {
        if self.state != Object_State.Normal do return API_Error.Object_Invalid

        for i in 0..<self.entries_count {
            e := &self.entries[i]
            if e.shadow != nil do mem.zero(raw_data(e.shadow), len(e.shadow))
        }
        oc.dense_arr__zero(&self.structural_events)

        return nil
    }

    sync_channel__memory_usage :: proc(self: ^Sync_Channel) -> int {
        total := size_of(self^)
        total += size_of(int) * len(self.table_id_to_entry)
        total += size_of(Sync_Table_Entry) * len(self.entries)
        for i in 0..<self.entries_count {
            e := &self.entries[i]
            total += len(e.shadow)
            total += size_of(Sync_Column) * len(e.columns)
        }
        total += oc.dense_arr__memory_usage(&self.structural_events)
        return total
    }

    sync_channel__register_table :: proc(self: ^Sync_Channel, table: ^Table, allow_non_pod := false, loc := #caller_location) -> Error {
        when !SYNC_ENABLED {
            return API_Error.Sync_Feature_Disabled
        }

        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_channel__is_valid(self), loc = loc)
            assert(table__is_valid(table), loc = loc)
            assert(table.db == self.db, loc = loc)
        }

        if len(table.columns) > SYNC_MAX_FIELDS do return API_Error.Sync_Too_Many_Fields
        if self.table_id_to_entry[table.id] != DELETED_INDEX do return API_Error.Sync_Table_Already_Registered
        if self.entries_count >= len(self.entries) do return oc.Core_Error.Container_Is_Full

        if !allow_non_pod {
            for col in table.columns {
                if !snapshot__type_is_pod(col.type_info) do return API_Error.Snapshot_Component_Not_POD
            }
        }

        columns := make([]Sync_Column, len(table.columns), self.db.allocator) or_return
        row_size := 0
        for col, i in table.columns {
            columns[i] = Sync_Column{ offset = row_size, size = col.type_info.size }
            row_size += col.type_info.size
        }

        entities_cap := self.db.overbase.id_factory.cap
        shadow, serr := make([]byte, entities_cap * row_size, self.db.allocator)
        if serr != nil {
            delete(columns, self.db.allocator)
            return serr
        }

        idx := self.entries_count
        self.entries[idx] = Sync_Table_Entry{
            table = table, table_id = table.id, row_size = row_size, columns = columns, shadow = shadow,
        }

        aerr := table__attach_sync_channel(table, self)
        if aerr != nil {
            delete(columns, self.db.allocator)
            delete(shadow, self.db.allocator)
            return aerr
        }

        self.table_id_to_entry[table.id] = idx
        self.entries_count += 1

        return nil
    }

    sync_channel__unregister_table :: proc(self: ^Sync_Channel, table: ^Table, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_channel__is_valid(self), loc = loc)
        }

        if int(table.id) >= len(self.table_id_to_entry) do return oc.Core_Error.Not_Found
        idx := self.table_id_to_entry[table.id]
        if idx == DELETED_INDEX do return oc.Core_Error.Not_Found

        e := &self.entries[idx]
        derr := table__detach_sync_channel(table, self)

        if e.shadow != nil do delete(e.shadow, self.db.allocator) or_return
        if e.columns != nil do delete(e.columns, self.db.allocator) or_return

        // swap-remove the entry; entries[0, entries_count) must stay dense
        last := self.entries_count - 1
        self.table_id_to_entry[table.id] = DELETED_INDEX
        if idx != last {
            self.entries[idx] = self.entries[last]
            self.table_id_to_entry[self.entries[idx].table_id] = idx
        }
        self.entries_count -= 1

        if derr != nil && derr != oc.Core_Error.Not_Found do return derr
        return nil
    }

    sync_channel__resync :: proc(self: ^Sync_Channel, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_channel__is_valid(self), loc = loc)
        }

        for i in 0..<self.entries_count {
            e := &self.entries[i]
            if e.table == nil do continue

            mem.zero(raw_data(e.shadow), len(e.shadow))

            n := table__len(e.table)
            for rid in 0..<n {
                eid := table__get_entity_by_row_number(e.table, rid)
                if is_not_set(eid) do continue

                dst := &e.shadow[eid.ix * e.row_size]
                for col, ci in e.columns {
                    src := table__component_rawptr_by_col(e.table, rid, ci)
                    mem.copy(rawptr(uintptr(dst) + uintptr(col.offset)), src, col.size)
                }
            }
        }

        oc.dense_arr__zero(&self.structural_events)
        return nil
    }

    sync_delta_max_size :: proc(self: ^Sync_Channel) -> int {
        size := size_of(Sync_Header)
        size += len(self.structural_events.items) * size_of(Sync_Structural_Wire)

        for i in 0..<self.entries_count {
            e := &self.entries[i]
            if e.table == nil do continue
            n := table__len(e.table)
            if n == 0 do continue
            size += size_of(Sync_Table_Section_Header)
            size += n * (size_of(entity_id) + size_of(u32) + e.row_size)
        }

        return size
    }

    sync_collect_delta :: proc(self: ^Sync_Channel, buf: []byte, loc := #caller_location) -> (written: int, err: Error) {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_channel__is_valid(self), loc = loc)
        }

        if len(buf) < size_of(Sync_Header) do return 0, API_Error.Sync_Buffer_Too_Small

        offset := size_of(Sync_Header)
        stop := false

        structural_written := 0
        {
            i := len(self.structural_events.items) - 1
            for i >= 0 {
                if offset + size_of(Sync_Structural_Wire) > len(buf) {
                    stop = true
                    break
                }
                ev := self.structural_events.items[i]
                wire := Sync_Structural_Wire{ eid = ev.eid, table_id = u16(ev.table_id), added = ev.added ? u8(1) : u8(0) }
                mem.copy(&buf[offset], &wire, size_of(wire))
                offset += size_of(wire)
                structural_written += 1
                oc.dense_arr__remove_by_index(&self.structural_events, i)
                i -= 1
            }
        }

        table_sections_written := 0

        if !stop {
            for ei in 0..<self.entries_count {
                if stop do break

                e := &self.entries[ei]
                if e.table == nil do continue

                n := table__len(e.table)
                if n == 0 do continue

                if offset + size_of(Sync_Table_Section_Header) > len(buf) {
                    stop = true
                    break
                }
                section_header_offset := offset
                offset += size_of(Sync_Table_Section_Header)

                section_entity_count := 0
                for rid in 0..<n {
                    if stop do break

                    eid := table__get_entity_by_row_number(e.table, rid)
                    if is_not_set(eid) do continue

                    max_record_size := size_of(entity_id) + size_of(u32) + e.row_size
                    if offset + max_record_size > len(buf) {
                        stop = true
                        break
                    }

                    shadow_ptr := &e.shadow[eid.ix * e.row_size]

                    mask: u32 = 0
                    write_cursor := offset + size_of(entity_id) + size_of(u32)
                    for col, ci in e.columns {
                        live_field := table__component_rawptr_by_col(e.table, rid, ci)
                        shadow_field := rawptr(uintptr(shadow_ptr) + uintptr(col.offset))
                        if !runtime.memory_equal(live_field, shadow_field, col.size) {
                            mask |= u32(1) << uint(ci)
                            mem.copy(&buf[write_cursor], live_field, col.size)
                            mem.copy(shadow_field, live_field, col.size)
                            write_cursor += col.size
                        }
                    }

                    if mask != 0 {
                        eid_copy := eid
                        mem.copy(&buf[offset], &eid_copy, size_of(entity_id))
                        mem.copy(&buf[offset + size_of(entity_id)], &mask, size_of(u32))
                        offset = write_cursor
                        section_entity_count += 1
                    }
                }

                if section_entity_count == 0 {
                    offset = section_header_offset // reclaim: nothing from this table made it in
                } else {
                    sh := Sync_Table_Section_Header{ table_id = u32(e.table_id), entity_count = u32(section_entity_count) }
                    mem.copy(&buf[section_header_offset], &sh, size_of(sh))
                    table_sections_written += 1
                }
            }
        }

        hdr := Sync_Header{
            magic                = SYNC_MAGIC,
            version              = SYNC_VERSION,
            structural_count     = u16(structural_written),
            table_section_count  = u16(table_sections_written),
        }
        mem.copy(&buf[0], &hdr, size_of(hdr))

        return offset, nil
    }

    @(private)
    sync_channel__on_table_terminated :: proc(self: ^Sync_Channel, tid: table_id) {
        if self == nil || self.state != Object_State.Normal do return
        if int(tid) >= len(self.table_id_to_entry) do return
        idx := self.table_id_to_entry[tid]
        if idx == DELETED_INDEX do return
        self.entries[idx].table = nil
    }

    @(private)
    sync_channel__notify_structural :: proc(self: ^Sync_Channel, tid: table_id, eid: entity_id, added: bool) {
        if self == nil || self.state != Object_State.Normal do return
        if int(tid) >= len(self.table_id_to_entry) do return
        idx := self.table_id_to_entry[tid]
        if idx == DELETED_INDEX do return
        e := &self.entries[idx]
        if e.table == nil do return

        if !added {
            // See this file's header note on why the shadow is entity-indexed
            // and must not leak a departed entity's bytes to whoever reuses eid.ix.
            off := eid.ix * e.row_size
            mem.zero(&e.shadow[off], e.row_size)
        }

        // structural_events has a small fixed cap (not entities_cap-sized) — silently
        // drop on overflow rather than error; same loss-tolerance a dropped UDP packet already implies.
        _, _ = oc.dense_arr__add(&self.structural_events, Sync_Structural_Event{ eid = eid, table_id = tid, added = added })
    }

///////////////////////////////////////////////////////////////////////////////

    @(private)
    Sync_Decoder_Entry :: struct {
        table:    ^Table,
        table_id: table_id,
        columns:  []Sync_Column,
    }

    Sync_Decoder :: struct {
        state: Object_State,
        db:    ^Database,

        table_id_to_entry: []int,
        entries:            []Sync_Decoder_Entry,
        entries_count:      int,
    }

    sync_decoder__is_valid :: proc(self: ^Sync_Decoder) -> bool {
        if self == nil do return false
        if self.state != Object_State.Normal do return false
        if self.db == nil do return false
        if self.table_id_to_entry == nil do return false
        if self.entries == nil do return false

        return true
    }

    sync_decoder__init :: proc(self: ^Sync_Decoder, db: ^Database, tables_cap: int, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(database__is_valid(db), loc = loc)
            assert(self.state == Object_State.Not_Initialized, loc = loc)
            assert(tables_cap > 0, loc = loc)
        }

        self.db = db
        self.entries_count = 0

        self.table_id_to_entry = make([]int, TABLES_CAP, db.allocator) or_return
        for i in 0..<len(self.table_id_to_entry) do self.table_id_to_entry[i] = DELETED_INDEX

        self.entries = make([]Sync_Decoder_Entry, tables_cap, db.allocator) or_return

        self.state = Object_State.Normal
        return nil
    }

    sync_decoder__terminate :: proc(self: ^Sync_Decoder) -> Error {
        when VALIDATIONS {
            assert(self != nil)
        }

        for i in 0..<self.entries_count {
            e := &self.entries[i]
            if e.columns != nil do delete(e.columns, self.db.allocator) or_return
        }

        delete(self.entries, self.db.allocator) or_return
        delete(self.table_id_to_entry, self.db.allocator) or_return

        self.entries = nil
        self.table_id_to_entry = nil
        self.entries_count = 0
        self.db = nil

        self.state = Object_State.Not_Initialized
        return nil
    }

    sync_decoder__memory_usage :: proc(self: ^Sync_Decoder) -> int {
        total := size_of(self^)
        total += size_of(int) * len(self.table_id_to_entry)
        total += size_of(Sync_Decoder_Entry) * len(self.entries)
        for i in 0..<self.entries_count {
            total += size_of(Sync_Column) * len(self.entries[i].columns)
        }
        return total
    }

    sync_decoder__register_table :: proc(self: ^Sync_Decoder, table: ^Table, allow_non_pod := false, loc := #caller_location) -> Error {
        when !SYNC_ENABLED {
            return API_Error.Sync_Feature_Disabled
        }

        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_decoder__is_valid(self), loc = loc)
            assert(table__is_valid(table), loc = loc)
            assert(table.db == self.db, loc = loc)
        }

        if len(table.columns) > SYNC_MAX_FIELDS do return API_Error.Sync_Too_Many_Fields
        if self.table_id_to_entry[table.id] != DELETED_INDEX do return API_Error.Sync_Table_Already_Registered
        if self.entries_count >= len(self.entries) do return oc.Core_Error.Container_Is_Full

        if !allow_non_pod {
            for col in table.columns {
                if !snapshot__type_is_pod(col.type_info) do return API_Error.Snapshot_Component_Not_POD
            }
        }

        columns := make([]Sync_Column, len(table.columns), self.db.allocator) or_return
        row_size := 0
        for col, i in table.columns {
            columns[i] = Sync_Column{ offset = row_size, size = col.type_info.size }
            row_size += col.type_info.size
        }

        idx := self.entries_count
        self.entries[idx] = Sync_Decoder_Entry{ table = table, table_id = table.id, columns = columns }
        self.table_id_to_entry[table.id] = idx
        self.entries_count += 1

        return nil
    }

    sync_apply_delta :: proc(self: ^Sync_Decoder, data: []byte, loc := #caller_location) -> Error {
        when VALIDATIONS {
            assert(self != nil, loc = loc)
            assert(sync_decoder__is_valid(self), loc = loc)
        }

        if len(data) < size_of(Sync_Header) do return API_Error.Snapshot_Invalid

        hdr: Sync_Header
        mem.copy(&hdr, raw_data(data), size_of(hdr))
        if hdr.magic != SYNC_MAGIC do return API_Error.Snapshot_Invalid
        if hdr.version != SYNC_VERSION do return API_Error.Snapshot_Version_Mismatch

        offset := size_of(Sync_Header)

        for _ in 0..<int(hdr.structural_count) {
            if offset + size_of(Sync_Structural_Wire) > len(data) do return API_Error.Snapshot_Invalid
            wire: Sync_Structural_Wire
            mem.copy(&wire, &data[offset], size_of(wire))
            offset += size_of(wire)

            eid := wire.eid
            tid := table_id(wire.table_id)

            if database__is_entity_correct(self.db, eid) != nil do continue // tolerated: unknown/expired
            if int(tid) >= len(self.table_id_to_entry) do continue
            idx := self.table_id_to_entry[tid]
            if idx == DELETED_INDEX do continue // not registered on this decoder — tolerated skip
            e := &self.entries[idx]
            if e.table == nil do continue

            if wire.added != 0 {
                _ = table__add_entity(e.table, eid) // Already_Exist tolerated (idempotent)
            } else {
                _ = table__remove_entity(e.table, eid) // Not_Found tolerated (idempotent)
            }
        }

        for _ in 0..<int(hdr.table_section_count) {
            if offset + size_of(Sync_Table_Section_Header) > len(data) do return API_Error.Snapshot_Invalid
            sh: Sync_Table_Section_Header
            mem.copy(&sh, &data[offset], size_of(sh))
            offset += size_of(sh)

            tid := table_id(sh.table_id)
            idx := DELETED_INDEX
            if int(tid) < len(self.table_id_to_entry) do idx = self.table_id_to_entry[tid]

            e: ^Sync_Decoder_Entry
            if idx != DELETED_INDEX do e = &self.entries[idx]
            if e == nil || e.table == nil do return API_Error.Snapshot_Schema_Mismatch

            for _ in 0..<int(sh.entity_count) {
                if offset + size_of(entity_id) + size_of(u32) > len(data) do return API_Error.Snapshot_Invalid
                eid: entity_id
                mem.copy(&eid, &data[offset], size_of(entity_id))
                offset += size_of(entity_id)
                mask: u32
                mem.copy(&mask, &data[offset], size_of(u32))
                offset += size_of(u32)

                rid := TABLE_NO_RID
                if database__is_entity_correct(self.db, eid) == nil {
                    rid = e.table.eid_to_rid[eid.ix]
                }

                for col, ci in e.columns {
                    if mask & (u32(1) << uint(ci)) == 0 do continue
                    if offset + col.size > len(data) do return API_Error.Snapshot_Invalid
                    if rid != TABLE_NO_RID {
                        dst := table__component_rawptr_by_col(e.table, int(rid), ci)
                        mem.copy(dst, &data[offset], col.size)
                    }
                    offset += col.size
                }
            }
        }

        return nil
    }

///////////////////////////////////////////////////////////////////////////////

when SYNC_ENABLED {

    @(private="file")
    Sync_XY :: struct { x: int, y: int }

    @(test)
    sync__structural_roundtrip_and_tolerated_skip__test :: proc(t: ^testing.T) {
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        ob: Overbase
        db_send: Database
        db_recv: Database
        table_send: Table
        table_recv: Table
        ch: Sync_Channel
        dec: Sync_Decoder
        defer overbase__terminate(&ob)
        defer database__terminate(&db_send)
        defer database__terminate(&db_recv)
        defer sync_channel__terminate(&ch)
        defer sync_decoder__terminate(&dec)

        testing.expect(t, overbase__init(&ob, 10, 2, allocator) == nil)
        testing.expect(t, database__init_from_overbase(&db_send, &ob) == nil)
        testing.expect(t, database__init_from_overbase(&db_recv, &ob) == nil)

        testing.expect(t, table__init(&table_send, &db_send, 10, {Sync_XY}) == nil)
        testing.expect(t, table__init(&table_recv, &db_recv, 10, {Sync_XY}) == nil)

        testing.expect(t, sync_channel__init(&ch, &db_send, 4) == nil)
        testing.expect(t, sync_channel__register_table(&ch, &table_send) == nil)
        testing.expect(t, sync_decoder__init(&dec, &db_recv, 4) == nil)
        testing.expect(t, sync_decoder__register_table(&dec, &table_recv) == nil)

        buf := make([]byte, 4096, allocator)
        defer delete(buf, allocator)

        eid, eerr := overbase__create_entity(&ob)
        testing.expect(t, eerr == nil)

        testing.expect(t, table__add_entity(&table_send, eid) == nil)
        table__get_component(&table_send, eid, Sync_XY).x = 42

        written, werr := sync_collect_delta(&ch, buf)
        testing.expect(t, werr == nil)
        testing.expect(t, sync_apply_delta(&dec, buf[:written]) == nil)
        testing.expect(t, table__has_entity(&table_recv, eid))
        testing.expect(t, table__get_component(&table_recv, eid, Sync_XY).x == 42)

        // tolerated skip: a structural event naming an entity the receiver
        // doesn't (yet) recognize as live must not error
        bogus := entity_id{ ix = 9999 }
        testing.expect(t, database__is_entity_correct(&db_recv, bogus) != nil) // sanity: really is invalid

        hdr := Sync_Header{ magic = SYNC_MAGIC, version = SYNC_VERSION, structural_count = 1 }
        mem.copy(&buf[0], &hdr, size_of(hdr))
        wire := Sync_Structural_Wire{ eid = bogus, table_id = u16(table_send.id), added = 1 }
        mem.copy(&buf[size_of(Sync_Header)], &wire, size_of(wire))
        testing.expect(t, sync_apply_delta(&dec, buf[:size_of(Sync_Header) + size_of(Sync_Structural_Wire)]) == nil)

        testing.expect(t, table__remove_entity(&table_send, eid) == nil)
        written2, werr2 := sync_collect_delta(&ch, buf)
        testing.expect(t, werr2 == nil)
        testing.expect(t, sync_apply_delta(&dec, buf[:written2]) == nil)
        testing.expect(t, !table__has_entity(&table_recv, eid))
    }

} // when SYNC_ENABLED
