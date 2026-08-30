/*
    2026 (c) Zaya, https://github.com/zm69
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs "../src"
    import oc "../src/ode_core"

///////////////////////////////////////////////////////////////////////////////
// Table

    @(test)
    table__init_terminate__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        defer ecs.table__terminate(&at)

        testing.expect(t, ecs.table__init(&at, &db, 5, {Position, AI}) == nil)
        testing.expect(t, ecs.table__is_valid(&at))
        testing.expect(t, ecs.table_len(&at) == 0)
        testing.expect(t, ecs.table_cap(&at) == 5)

        id_before := at.id
        testing.expect(t, ecs.table__terminate(&at) == nil)
        testing.expect(t, ecs.table__init(&at, &db, 5, {Position, AI}) == nil)
        testing.expect(t, at.id == id_before)
    }

    @(test)
    table__init_errors__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        testing.expect(t, ecs.table__init(&at, &db, 5, {}) == ecs.API_Error.Tables_Array_Should_Not_Be_Empty)
    }

    @(test)
    table__create_entity_and_get_component__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        defer ecs.table__terminate(&at)
        testing.expect(t, ecs.table__init(&at, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&at)
        testing.expect(t, err == nil)
        testing.expect(t, ecs.table_len(&at) == 1)
        testing.expect(t, ecs.has_component(&at, eid))

        pos := ecs.get_component(&at, eid, Position)
        testing.expect(t, pos != nil)
        pos.x = 1
        pos.y = 2

        ai := ecs.get_component(&at, eid, AI)
        testing.expect(t, ai != nil)
        ai.IQ = 100
        ai.neurons_count = 42

        pos2 := ecs.get_component(&at, eid, Position)
        testing.expect(t, pos2.x == 1 && pos2.y == 2)
        ai2 := ecs.get_component(&at, eid, AI)
        testing.expect(t, ai2.IQ == 100 && ai2.neurons_count == 42)

        aerr := ecs.table__add_entity(&at, eid)
        testing.expect(t, aerr == ecs.API_Error.Component_Already_Exist)
        testing.expect(t, ecs.table_len(&at) == 1)

        other, oerr := ecs.create_entity(&db)
        testing.expect(t, oerr == nil)
        testing.expect(t, !ecs.has_component(&at, other))
        testing.expect(t, ecs.get_component(&at, other, Position) == nil)
    }

    @(test)
    table__add_entity_to_existing__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        defer ecs.table__terminate(&at)
        testing.expect(t, ecs.table__init(&at, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        testing.expect(t, !ecs.has_component(&at, eid))

        testing.expect(t, ecs.table__add_entity(&at, eid) == nil)
        testing.expect(t, ecs.has_component(&at, eid))
        testing.expect(t, ecs.table_len(&at) == 1)
    }

    @(test)
    table__remove_entity_swaps_every_column__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        defer ecs.table__terminate(&at)
        testing.expect(t, ecs.table__init(&at, &db, 10, {Position, AI}) == nil)

        e0, _ := ecs.create_entity(&at)
        e1, _ := ecs.create_entity(&at)
        e2, _ := ecs.create_entity(&at)

        ecs.get_component(&at, e0, Position).x = 100
        ecs.get_component(&at, e0, AI).neurons_count = 1000

        ecs.get_component(&at, e1, Position).x = 200
        ecs.get_component(&at, e1, AI).neurons_count = 2000

        ecs.get_component(&at, e2, Position).x = 300
        ecs.get_component(&at, e2, AI).neurons_count = 3000

        testing.expect(t, ecs.table__remove_entity(&at, e1) == nil)

        testing.expect(t, ecs.table_len(&at) == 2)
        testing.expect(t, !ecs.has_component(&at, e1))
        testing.expect(t, ecs.has_component(&at, e0))
        testing.expect(t, ecs.has_component(&at, e2))

        testing.expect(t, ecs.get_component(&at, e0, Position).x == 100)
        testing.expect(t, ecs.get_component(&at, e0, AI).neurons_count == 1000)

        testing.expect(t, ecs.get_component(&at, e2, Position).x == 300)
        testing.expect(t, ecs.get_component(&at, e2, AI).neurons_count == 3000)

        testing.expect(t, ecs.table__remove_entity(&at, e2) == nil)
        testing.expect(t, ecs.table_len(&at) == 1)
        testing.expect(t, !ecs.has_component(&at, e2))
        testing.expect(t, ecs.get_component(&at, e0, Position).x == 100)
    }

    @(test)
    table__pause_resume_packing__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        defer ecs.table__terminate(&at)
        testing.expect(t, ecs.table__init(&at, &db, 10, {Position, AI}) == nil)

        e0, _ := ecs.create_entity(&at)
        e1, _ := ecs.create_entity(&at)
        e2, _ := ecs.create_entity(&at)

        ecs.get_component(&at, e0, Position).x = 1
        ecs.get_component(&at, e1, Position).x = 2
        ecs.get_component(&at, e2, Position).x = 3

        testing.expect(t, ecs.pause_packing(&at) == nil)

        testing.expect(t, ecs.table__remove_entity(&at, e1) == nil)
        testing.expect(t, ecs.get_component(&at, e0, Position).x == 1)
        testing.expect(t, ecs.get_component(&at, e2, Position).x == 3)
        testing.expect(t, !ecs.has_component(&at, e1))

        testing.expect(t, ecs.resume_packing(&at) == nil)

        testing.expect(t, ecs.table_len(&at) == 2)
        testing.expect(t, ecs.get_component(&at, e0, Position).x == 1)
        testing.expect(t, ecs.get_component(&at, e2, Position).x == 3)
    }

    @(test)
    table__slice_skips_hole_while_paused__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        defer ecs.table__terminate(&at)
        testing.expect(t, ecs.table__init(&at, &db, 10, {Position, AI}) == nil)

        e0, _ := ecs.create_entity(&at)
        e1, _ := ecs.create_entity(&at)
        e2, _ := ecs.create_entity(&at)

        ecs.get_component(&at, e0, Position).x = 1
        ecs.get_component(&at, e1, Position).x = 2
        ecs.get_component(&at, e2, Position).x = 3

        testing.expect(t, ecs.pause_packing(&at) == nil)
        testing.expect(t, ecs.table__remove_entity(&at, e1) == nil)

        eids := ecs.entities_slice(&at)
        pos_slice := ecs.slice(&at, Position)

        seen_x := 0
        visited := 0
        for i in 0..<len(eids) {
            if ecs.is_not_set(eids[i]) do continue // hole left by the paused removal
            testing.expect(t, pos_slice[i].x == 1 || pos_slice[i].x == 3)
            seen_x += pos_slice[i].x
            visited += 1
        }
        testing.expect(t, visited == 2)
        testing.expect(t, seen_x == 4)

        testing.expect(t, ecs.resume_packing(&at) == nil)
    }

    @(test)
    destroy_entity_removes_row_from_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        defer ecs.table__terminate(&at)
        testing.expect(t, ecs.table__init(&at, &db, 10, {Position, AI}) == nil)

        eid, _ := ecs.create_entity(&at)
        testing.expect(t, ecs.table_len(&at) == 1)

        testing.expect(t, ecs.destroy_entity(&db, eid) == nil)
        testing.expect(t, ecs.table_len(&at) == 0)
        testing.expect(t, !ecs.has_component(&at, eid))
    }

    @(test)
    table__slice_multi_column_walk__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        defer ecs.table__terminate(&at)
        testing.expect(t, ecs.table__init(&at, &db, 10, {Position, AI}) == nil)

        e0, _ := ecs.create_entity(&at)
        e1, _ := ecs.create_entity(&at)
        e2, _ := ecs.create_entity(&at)

        ecs.get_component(&at, e0, Position).x = 1
        ecs.get_component(&at, e1, Position).x = 2
        ecs.get_component(&at, e2, Position).x = 3

        ecs.get_component(&at, e0, AI).neurons_count = 10
        ecs.get_component(&at, e1, AI).neurons_count = 20
        ecs.get_component(&at, e2, AI).neurons_count = 30

        pos_slice := ecs.slice(&at, Position)
        ai_slice := ecs.slice(&at, AI)

        count := 0
        sum_x := 0
        sum_neurons := 0
        for i in 0..<len(pos_slice) {
            pos_slice[i].x += 100
            sum_x += pos_slice[i].x
            sum_neurons += ai_slice[i].neurons_count
            count += 1
        }

        testing.expect(t, count == 3)
        testing.expect(t, sum_x == 101 + 102 + 103)
        testing.expect(t, sum_neurons == 10 + 20 + 30)

        testing.expect(t, ecs.get_component(&at, e0, Position).x == 101)
        testing.expect(t, ecs.get_component(&at, e2, Position).x == 103)
    }

    @(test)
    table__slice_batches_and_column_not_found__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        defer ecs.table__terminate(&at)
        testing.expect(t, ecs.table__init(&at, &db, 10, {Position, AI}) == nil)

        for i in 0 ..< 6 {
            eid, _ := ecs.create_entity(&at)
            ecs.get_component(&at, eid, Position).x = i
        }

        pos_slice := ecs.slice(&at, Position)

        count := 0
        for i in 0..<3 {
            _ = pos_slice[i]
            count += 1
        }
        testing.expect(t, count == 3)

        count2 := 0
        for i in 3..<6 {
            _ = pos_slice[i]
            count2 += 1
        }
        testing.expect(t, count2 == 3)

        no_ai: ecs.Table
        defer ecs.table__terminate(&no_ai)
        testing.expect(t, ecs.table__init(&no_ai, &db, 5, {Position}) == nil)

        _, _ = ecs.create_entity(&no_ai)

        testing.expect(t, ecs.slice(&no_ai, AI) == nil)
    }

    @(test)
    table__entities_slice_type_free_walk__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        at: ecs.Table
        defer ecs.table__terminate(&at)
        testing.expect(t, ecs.table__init(&at, &db, 10, {Position, AI}) == nil)

        e0, _ := ecs.create_entity(&at)
        e1, _ := ecs.create_entity(&at)

        ecs.get_component(&at, e0, Position).x = 11
        ecs.get_component(&at, e0, AI).neurons_count = 111
        ecs.get_component(&at, e1, Position).x = 22
        ecs.get_component(&at, e1, AI).neurons_count = 222

        eids := ecs.entities_slice(&at)

        seen := 0
        sum_x := 0
        sum_neurons := 0
        for eid in eids {
            pos := ecs.table__get_component(&at, eid, Position)
            ai := ecs.table__get_component(&at, eid, AI)
            testing.expect(t, pos != nil && ai != nil)
            sum_x += pos.x
            sum_neurons += ai.neurons_count
            seen += 1
        }
        testing.expect(t, seen == 2)
        testing.expect(t, sum_x == 33)
        testing.expect(t, sum_neurons == 333)
    }

    @(test)
    table__slice_wide_arity__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

        C1 :: struct { v: int }
        C2 :: struct { v: int }
        C3 :: struct { v: int }
        C4 :: struct { v: int }
        C5 :: struct { v: int }
        C6 :: struct { v: int }
        C7 :: struct { v: int }

        wide: ecs.Table
        defer ecs.table__terminate(&wide)
        testing.expect(t, ecs.table__init(&wide, &db, 5, {C1, C2, C3, C4, C5, C6, C7}) == nil)

        eid, err := ecs.create_entity(&wide)
        testing.expect(t, err == nil)
        ecs.get_component(&wide, eid, C1).v = 1
        ecs.get_component(&wide, eid, C2).v = 2
        ecs.get_component(&wide, eid, C3).v = 3
        ecs.get_component(&wide, eid, C4).v = 4
        ecs.get_component(&wide, eid, C5).v = 5
        ecs.get_component(&wide, eid, C6).v = 6
        ecs.get_component(&wide, eid, C7).v = 7

        c1 := ecs.slice(&wide, C1)
        c2 := ecs.slice(&wide, C2)
        c3 := ecs.slice(&wide, C3)
        c4 := ecs.slice(&wide, C4)
        c5 := ecs.slice(&wide, C5)
        c6 := ecs.slice(&wide, C6)
        c7 := ecs.slice(&wide, C7)

        count := 0
        for i in 0..<len(c1) {
            testing.expect(t, c1[i].v == 1 && c2[i].v == 2 && c3[i].v == 3 && c4[i].v == 4 && c5[i].v == 5 && c6[i].v == 6 && c7[i].v == 7)
            count += 1
        }
        testing.expect(t, count == 1)
    }

    @(test)
    table__serialization_round_trip__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        src_db: ecs.Database
        defer ecs.terminate(&src_db)
        testing.expect(t, ecs.init(&src_db, entities_cap = 20, allocator = allocator) == nil)

        src_at: ecs.Table
        testing.expect(t, ecs.table__init(&src_at, &src_db, 10, {Position, AI}) == nil)

        eids: [5]ecs.entity_id
        for i in 0 ..< 5 {
            eid, err := ecs.create_entity(&src_at)
            testing.expect(t, err == nil)
            eids[i] = eid
            ecs.get_component(&src_at, eid, Position).x = i * 10
            ecs.get_component(&src_at, eid, AI).neurons_count = i * 100
        }

        size, serr := ecs.serialized_size(&src_db)
        testing.expect(t, serr == nil)
        buf := make([]byte, size, allocator)
        defer delete(buf, allocator)

        written, werr := ecs.serialize(&src_db, buf)
        testing.expect(t, werr == nil)
        testing.expect(t, written == size)

        dst_db: ecs.Database
        defer ecs.terminate(&dst_db)
        testing.expect(t, ecs.init(&dst_db, entities_cap = 20, allocator = allocator) == nil)

        dst_at: ecs.Table
        testing.expect(t, ecs.table__init(&dst_at, &dst_db, 10, {Position, AI}) == nil)

        testing.expect(t, ecs.deserialize(&dst_db, buf) == nil)

        testing.expect(t, ecs.table_len(&dst_at) == 5)
        for i in 0 ..< 5 {
            eid := eids[i]
            testing.expect(t, ecs.has_component(&dst_at, eid))
            testing.expect(t, ecs.get_component(&dst_at, eid, Position).x == i * 10)
            testing.expect(t, ecs.get_component(&dst_at, eid, AI).neurons_count == i * 100)
        }
    }

    @(test)
    table__serialization_schema_mismatch__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        src_db: ecs.Database
        defer ecs.terminate(&src_db)
        testing.expect(t, ecs.init(&src_db, entities_cap = 10, allocator = allocator) == nil)

        src_at: ecs.Table
        testing.expect(t, ecs.table__init(&src_at, &src_db, 5, {Position, AI}) == nil)

        _, cerr := ecs.create_entity(&src_at)
        testing.expect(t, cerr == nil)

        size, serr := ecs.serialized_size(&src_db)
        testing.expect(t, serr == nil)
        buf := make([]byte, size, allocator)
        defer delete(buf, allocator)
        _, werr := ecs.serialize(&src_db, buf)
        testing.expect(t, werr == nil)

        dst_db: ecs.Database
        defer ecs.terminate(&dst_db)
        testing.expect(t, ecs.init(&dst_db, entities_cap = 10, allocator = allocator) == nil)

        dst_at: ecs.Table
        testing.expect(t, ecs.table__init(&dst_at, &dst_db, 5, {Position}) == nil)

        testing.expect(t, ecs.deserialize(&dst_db, buf) == ecs.API_Error.Snapshot_Schema_Mismatch)
    }

