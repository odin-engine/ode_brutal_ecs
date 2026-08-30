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
// Components

    Position :: struct {
        x, y: int
    }

    AI :: struct {
        IQ: f32,
        neurons_count: int
    }

    Marker :: struct {
        v: u8,
    }

///////////////////////////////////////////////////////////////////////////////
// Helpers

    arch_add :: proc(at: ^ecs.Table, eid: ecs.entity_id, $T: typeid) -> (^T, ecs.Error) {
        err := ecs.table__add_entity(at, eid)
        if err != nil && err != ecs.API_Error.Component_Already_Exist do return nil, err
        return ecs.table__get_component(at, eid, T), err
    }

///////////////////////////////////////////////////////////////////////////////
    when !ecs.SYNC_ENABLED {
        @(test)
        sync_register_disabled_by_default__test :: proc(t: ^testing.T) {
            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            defer ecs.terminate(&db)
            testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)

            tbl: ecs.Table
            defer ecs.table__terminate(&tbl)
            testing.expect(t, ecs.table__init(&tbl, &db, 10, {Marker}) == nil)

            ch: ecs.Sync_Channel
            defer ecs.sync_channel_terminate(&ch)
            testing.expect(t, ecs.sync_channel_init(&ch, &db, 4) == nil)

            testing.expect(t, ecs.sync_register(&ch, &tbl) == ecs.API_Error.Sync_Feature_Disabled)
        }
    }

///////////////////////////////////////////////////////////////////////////////
// Database

    @(test)
    attaching_detaching_tables__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ecs_1: ecs.Database
            ais: ecs.Table
            ais_table2: ecs.Table
            positions: ecs.Table
            pos_table2: ecs.Table

        //
        // Test
        //
            defer ecs.terminate(&ecs_1)

            testing.expect(t, ecs.init(&ecs_1, entities_cap=0, allocator=allocator) == ecs.API_Error.Entities_Cap_Should_Be_Greater_Than_Zero)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            testing.expect(t, ecs.table__init(&ais, &ecs_1, 10, {Marker}) == nil)
            testing.expect(t, ais.id == 0)

            testing.expect(t, ecs.table__init(&ais_table2, &ecs_1, 10, {Marker}) == nil)
            defer ecs.table__terminate(&positions)
            testing.expect(t, ecs.table__init(&positions, &ecs_1, 10, {Marker}) == nil)

            testing.expect(t, ais.id == 0)
            testing.expect(t, positions.id == 2)

            ecs.table__terminate(&ais_table2)

            testing.expect(t, ais_table2.id == ecs.DELETED_INDEX)
            testing.expect(t, ecs_1.tables.items[1] == nil)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == true)

            defer ecs.table__terminate(&pos_table2)
            testing.expect(t, ecs.table__init(&pos_table2, &ecs_1, 10, {Marker}) == nil)
            testing.expect(t, pos_table2.id == 1)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == false)

            ecs.table__terminate(&ais)

            testing.expect(t, ais.id == ecs.DELETED_INDEX)
            testing.expect(t, ecs_1.tables.items[0] == nil)
            testing.expect(t, oc.sparse_arr__len(&ecs_1.tables) == 3)
            testing.expect(t, ecs_1.tables.has_nil_item == true)
    }

    @(test)
    database__tables_growth_is_unbounded__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator, tables_cap = 2) == nil)

        TABLE_COUNT :: 200 // comfortably past the old fixed bitset-index ceiling
        tabs: [TABLE_COUNT]ecs.Table
        defer for &tb in tabs do ecs.table__terminate(&tb)
        for i in 0..<TABLE_COUNT {
            testing.expect(t, ecs.table__init(&tabs[i], &db, 10, {Marker}) == nil)
        }
        testing.expect(t, oc.sparse_arr__len(&db.tables) == TABLE_COUNT, "table count has no compile-time ceiling now that table ids aren't bitset indices")
    }

    @(test)
    terminate_then_reinit__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            db: ecs.Database
            positions: ecs.Table

        //
        // Test
        //
            defer ecs.terminate(&db)

            run_cycle :: proc(t: ^testing.T, db: ^ecs.Database, positions: ^ecs.Table, allocator: mem.Allocator) {
                testing.expect(t, ecs.init(db, entities_cap=100, allocator=allocator) == nil)
                testing.expect(t, ecs.table__init(positions, db, 100, {Position}) == nil)

                eid, err := ecs.create_entity(db)
                testing.expect(t, err == nil)

                pos, perr := arch_add(positions, eid, Position)
                testing.expect(t, perr == nil)
                testing.expect(t, pos != nil)
                if pos != nil do pos^ = Position{ x = 1, y = 2 }

                testing.expect(t, ecs.table_len(positions) == 1)
            }

            run_cycle(t, &db, &positions, allocator)

            testing.expect(t, ecs.terminate(&db) == nil)

            testing.expect(t, db.state == ecs.Object_State.Not_Initialized)
            testing.expect(t, positions.state == ecs.Object_State.Not_Initialized)

            run_cycle(t, &db, &positions, allocator)
    }

///////////////////////////////////////////////////////////////////////////////
// Entity
    @(test)
    creating_destroying_entities__test :: proc(t: ^testing.T) {
        //
        // Prepare
        //

            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ecs_1: ecs.Database

            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=2, allocator=allocator) == nil)

            testing.expect(t,  ecs_1.overbase.id_factory.created_count == 0)

            eid_1, eid_2, eid_3: ecs.entity_id
            err: ecs.Error

        //
        // Test
        //

            eid_1, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_1.ix == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs_1.overbase.id_factory.created_count == 1)

            eid_2, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_2.ix == 1)
            testing.expect(t, err == nil)
            testing.expect(t, ecs_1.overbase.id_factory.created_count == 2)

            eid_3, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_3.ix == ecs.DELETED_INDEX)
            testing.expect(t, err == oc.Core_Error.Container_Is_Full)
            testing.expect(t, ecs_1.overbase.id_factory.created_count == 2)

            testing.expect(t, ecs.database__destroy_entity(&ecs_1, eid_1) == nil)
            testing.expect(t, ecs_1.overbase.id_factory.created_count == 2)

            testing.expect(t, ecs.database__destroy_entity(&ecs_1, eid_1) == ecs.API_Error.Entity_Id_Expired)
            testing.expect(t, ecs_1.overbase.id_factory.created_count == 2)
    }
///////////////////////////////////////////////////////////////////////////////
// Table (stand-in for the removed Table(T) — generic component add/remove/get)

    @(test)
    adding_removing_components__test :: proc(t: ^testing.T) {
        //
        // Prepare
            context.logger = log.create_console_logger()
            defer log.destroy_console_logger(context.logger)

            allocator := context.allocator
            context.allocator = mem.panic_allocator()

            ecs_1: ecs.Database
            pos_ai: ecs.Table

            defer ecs.terminate(&ecs_1)
            testing.expect(t, ecs.init(&ecs_1, entities_cap=10, allocator=allocator) == nil)

            defer ecs.table__terminate(&pos_ai)
            testing.expect(t, ecs.table__init(&pos_ai, &ecs_1, 10, {Position, AI}) == nil)
            testing.expect(t, ecs.table_cap(&pos_ai) == 10)

            eid_1, eid_2: ecs.entity_id
            err: ecs.Error

            eid_1, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_1.ix == 0)
            testing.expect(t, err == nil)

            eid_2, err = ecs.database__create_entity(&ecs_1)
            testing.expect(t, eid_2.ix == 1)
            testing.expect(t, err == nil)

        //
        // Test
        //

            pos, pos2: ^Position
            ai, ai2: ^AI

            // Boundaries check
            pos, err = arch_add(&pos_ai, ecs.entity_id{ix = 99999}, Position)
            testing.expect(t, pos == nil)
            testing.expect(t, err == ecs.API_Error.Entity_Id_Out_of_Bounds)

            pos, err = arch_add(&pos_ai, eid_1, Position)
            testing.expect(t, err == nil)
            testing.expect(t, pos != nil)
            testing.expect(t, pos.x == 0 && pos.y == 0)
            testing.expect(t, ecs.table_len(&pos_ai) == 1)

            pos2, err = arch_add(&pos_ai, eid_2, Position)
            testing.expect(t, pos2 != nil)
            testing.expect(t, pos2.x == 0 && pos2.y == 0)
            testing.expect(t, err == nil)
            testing.expect(t, ecs.table_len(&pos_ai) == 2)

            ai, err = arch_add(&pos_ai, eid_1, AI)
            testing.expect(t, ai != nil)
            testing.expect(t, ai.IQ == 0)
            testing.expect(t, err == ecs.API_Error.Component_Already_Exist)
            testing.expect(t, ecs.table_len(&pos_ai) == 2)

            ai2, err = arch_add(&pos_ai, eid_2, AI)
            testing.expect(t, ai2 != nil)
            testing.expect(t, ai2.IQ == 0)
            testing.expect(t, err == ecs.API_Error.Component_Already_Exist)
            testing.expect(t, ecs.table_len(&pos_ai) == 2)

            pos.x = 44
            pos.y = 77

            pos2.x = 55
            pos2.y = 88

            ai.IQ = 66
            ai2.IQ = 42

            testing.expect(t, pos_ai.eid_to_rid[eid_1.ix] == 0)
            testing.expect(t, pos_ai.eid_to_rid[eid_2.ix] == 1)
            testing.expect(t, pos_ai.rid_to_eid[0] == eid_1)
            testing.expect(t, pos_ai.rid_to_eid[1] == eid_2)
            testing.expect(t, ecs.table_len(&pos_ai) == 2)

            testing.expect(t, ecs.table__remove_entity(&pos_ai, eid_1) == nil)

            testing.expect(t, pos.x == 55)
            testing.expect(t, pos.y == 88)

            testing.expect(t, pos2.x == 0)
            testing.expect(t, pos2.y == 0)

            testing.expect(t, pos_ai.eid_to_rid[eid_1.ix] == max(u32))
            testing.expect(t, pos_ai.eid_to_rid[eid_2.ix] == 0)
            testing.expect(t, pos_ai.rid_to_eid[0] == eid_2)
            testing.expect(t, pos_ai.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            testing.expect(t, ecs.table_len(&pos_ai) == 1)

            testing.expect(t, ecs.table__remove_entity(&pos_ai, eid_1) == oc.Core_Error.Not_Found)
            testing.expect(t, ecs.table__remove_entity(&pos_ai, eid_2) == nil)

            testing.expect(t, pos_ai.eid_to_rid[eid_1.ix] == max(u32))
            testing.expect(t, pos_ai.eid_to_rid[eid_2.ix] == max(u32))
            testing.expect(t, pos_ai.rid_to_eid[0].ix == ecs.DELETED_INDEX)
            testing.expect(t, pos_ai.rid_to_eid[1].ix == ecs.DELETED_INDEX)
            testing.expect(t, ecs.table_len(&pos_ai) == 0)

            testing.expect(t, ecs.table__remove_entity(&pos_ai, eid_2) == oc.Core_Error.Not_Found)

            // Get Component (re-add since remove above emptied the table)
            eid_3, err3 := ecs.database__create_entity(&ecs_1)
            testing.expect(t, err3 == nil)
            eid_4, err4 := ecs.database__create_entity(&ecs_1)
            testing.expect(t, err4 == nil)
            _, aerr1 := arch_add(&pos_ai, eid_3, Position)
            testing.expect(t, aerr1 == nil)
            _, aerr2 := arch_add(&pos_ai, eid_4, Position)
            testing.expect(t, aerr2 == nil)
            testing.expect(t, ecs.table_len(&pos_ai) == 2)

            a : ^AI

            a = ecs.table__get_component(&pos_ai, eid_3, AI)
            testing.expect(t, a != nil)

            a.neurons_count = 111

            a = ecs.table__get_component(&pos_ai, eid_4, AI)
            testing.expect(t, a != nil)

            a.neurons_count = 222

            pos = ecs.table__get_component(&pos_ai, eid_2, Position)
            testing.expect(t, pos == nil)

            ecs.clear(&pos_ai)
    }

///////////////////////////////////////////////////////////////////////////////
// Regression tests (2026-07 bug audit)

    @(test)
    database_clear_expires_old_ids__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)

        old_eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.clear(&db) == nil)
        testing.expect(t, ecs.entities_len(&db) == 0)
        testing.expect(t, ecs.is_expired(&db, old_eid))

        new_eid, err2 := ecs.create_entity(&db)
        testing.expect(t, err2 == nil)
        testing.expect(t, new_eid.ix == old_eid.ix)
        testing.expect(t, new_eid != old_eid)
        testing.expect(t, ecs.is_expired(&db, old_eid))
    }

    @(test)
    table_terminate_reinit_leak_check__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        defer mem.tracking_allocator_destroy(&track)
        allocator := mem.tracking_allocator(&track)
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table
        ais: ecs.Table
        ais2: ecs.Table

        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)
        testing.expect(t, ecs.table__init(&ais, &db, 10, {AI}) == nil)

        eid, cerr := ecs.create_entity(&db)
        testing.expect(t, cerr == nil)
        eid2, cerr2 := ecs.create_entity(&db)
        testing.expect(t, cerr2 == nil)

        _, err := arch_add(&positions, eid, Position)
        testing.expect(t, err == nil)
        _, err = arch_add(&ais, eid2, AI)
        testing.expect(t, err == nil)

        testing.expect(t, ecs.table__terminate(&ais) == nil)

        testing.expect(t, ecs.table__init(&ais2, &db, 10, {AI}) == nil)
        testing.expect(t, ais2.id == 1)

        testing.expect(t, ecs.destroy_entity(&db, eid) == nil)
        testing.expect(t, ecs.destroy_entity(&db, eid2) == nil)
        testing.expect(t, ecs.entities_len(&db) == 0)

        testing.expect(t, ecs.terminate(&db) == nil)

        testing.expect(t, len(track.allocation_map) == 0)
        testing.expect(t, len(track.bad_free_array) == 0)
    }

    @(test)
    add_component_at_cap_already_exists__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 2, {Position}) == nil)

        e1, err1 := ecs.create_entity(&db)
        testing.expect(t, err1 == nil)
        e2, err2 := ecs.create_entity(&db)
        testing.expect(t, err2 == nil)
        e3, err3 := ecs.create_entity(&db)
        testing.expect(t, err3 == nil)

        _, err := arch_add(&positions, e1, Position)
        testing.expect(t, err == nil)
        _, err = arch_add(&positions, e2, Position)
        testing.expect(t, err == nil)

        p: ^Position
        p, err = arch_add(&positions, e1, Position)
        testing.expect(t, err == ecs.API_Error.Component_Already_Exist)
        testing.expect(t, p != nil)

        p, err = arch_add(&positions, e3, Position)
        testing.expect(t, err == oc.Core_Error.Container_Is_Full)
        testing.expect(t, p == nil)
    }

    @(test)
    table_expired_entity_id__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        _, aerr := arch_add(&positions, eid, Position)
        testing.expect(t, aerr == nil)

        testing.expect(t, ecs.destroy_entity(&db, eid) == nil)

        _, err2 := arch_add(&positions, eid, Position)
        testing.expect(t, err2 == ecs.API_Error.Entity_Id_Expired)
        testing.expect(t, ecs.table__remove_entity(&positions, eid) == ecs.API_Error.Entity_Id_Expired)
        testing.expect(t, ecs.get_component(&positions, eid, Position) == nil)
        testing.expect(t, ecs.has_component(&positions, eid) == false)
    }

    @(test)
    table_pause_resume_edge_cases__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)

        eid, err := ecs.create_entity(&db)
        testing.expect(t, err == nil)
        _, aerr := arch_add(&positions, eid, Position)
        testing.expect(t, aerr == nil)

        testing.expect(t, ecs.pause_packing(&positions) == nil)
        testing.expect(t, ecs.resume_packing(&positions) == nil)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 1)
        testing.expect(t, ecs.has_component(&positions, eid))

        testing.expect(t, ecs.table__terminate(&positions) == nil)
        testing.expect(t, ecs.pause_packing(&positions) == ecs.API_Error.Object_Invalid)
        testing.expect(t, ecs.resume_packing(&positions) == ecs.API_Error.Object_Invalid)
        testing.expect(t, ecs.pack(&positions) == ecs.API_Error.Object_Invalid)
    }

    @(test)
    destroy_entity_high_table_id__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        tabs: [68]ecs.Table
        positions: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)

        for i in 0..<68 {
            testing.expect(t, ecs.table__init(&tabs[i], &db, 10, {Marker}) == nil)
        }
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)
        testing.expect(t, int(positions.id) == 68)

        eid, cerr := ecs.create_entity(&db)
        testing.expect(t, cerr == nil)
        _, aerr := arch_add(&positions, eid, Position)
        testing.expect(t, aerr == nil)

        testing.expect(t, ecs.destroy_entity(&db, eid) == nil)
        testing.expect(t, ecs.entities_len(&db) == 0)
        testing.expect(t, ecs.table_len(&positions) == 0)
        testing.expect(t, ecs.has_component(&positions, eid) == false)
    }

///////////////////////////////////////////////////////////////////////////////
// Deferred tail swap (pause_packing / resume_packing / pack)

    @(test)
    pause_packing__table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)

        eids: [5]ecs.entity_id
        for i in 0..<5 {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)
            p, aerr := arch_add(&positions, eid, Position)
            testing.expect(t, aerr == nil)
            p.x = i + 1
            eids[i] = eid
        }

        testing.expect(t, ecs.table_len(&positions) == 5)

        ecs.pause_packing(&db)

        p1 := ecs.get_component(&positions, eids[1], Position)
        p4 := ecs.get_component(&positions, eids[4], Position)

        testing.expect(t, ecs.table__remove_entity(&positions, eids[2]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 5)
        testing.expect(t, positions.holes_count == 1)
        testing.expect(t, ecs.has_component(&positions, eids[2]) == false)
        testing.expect(t, ecs.get_entity(&positions, 2).ix == ecs.DELETED_INDEX)
        testing.expect(t, ecs.get_component(&positions, eids[1], Position) == p1)
        testing.expect(t, ecs.get_component(&positions, eids[4], Position) == p4)
        testing.expect(t, p4.x == 5)

        testing.expect(t, ecs.table__remove_entity(&positions, eids[4]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 4)
        testing.expect(t, positions.holes_count == 1)

        testing.expect(t, ecs.table__remove_entity(&positions, eids[3]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 2)
        testing.expect(t, positions.holes_count == 0)

        testing.expect(t, ecs.table__remove_entity(&positions, eids[0]) == nil)
        testing.expect(t, positions.holes_count == 1)

        testing.expect(t, ecs.pack(&positions) == nil)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 1)
        testing.expect(t, ecs.get_entity(&positions, 0) == eids[1])
        testing.expect(t, ecs.get_component(&positions, eids[1], Position).x == 2)

        testing.expect(t, ecs.resume_packing(&db) == nil)
        testing.expect(t, ecs.table__remove_entity(&positions, eids[1]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 0)
    }

    @(test)
    pause_packing__standalone_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)

        eids: [3]ecs.entity_id
        for i in 0..<3 {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)
            p, aerr := arch_add(&positions, eid, Position)
            testing.expect(t, aerr == nil)
            p.x = i + 1
            eids[i] = eid
        }

        testing.expect(t, ecs.pause_packing(&positions) == nil)
        testing.expect(t, db.tail_swap_paused == false)

        testing.expect(t, ecs.table__remove_entity(&positions, eids[1]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 3)
        testing.expect(t, positions.holes_count == 1)
        testing.expect(t, ecs.get_entity(&positions, 1).ix == ecs.DELETED_INDEX)

        testing.expect(t, ecs.resume_packing(&positions) == nil)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 2)

        testing.expect(t, ecs.table__remove_entity(&positions, eids[0]) == nil)
        testing.expect(t, ecs.table_len(&positions) == 1)
    }

    @(test)
    pause_packing__database__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        pos_ai: ecs.Table
        others: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap=10, allocator=allocator) == nil)
        testing.expect(t, ecs.table__init(&pos_ai, &db, 10, {Position, AI}) == nil)
        testing.expect(t, ecs.table__init(&others, &db, 10, {Marker}) == nil)

        eids: [6]ecs.entity_id
        for i in 0..<6 {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)

            p, perr := arch_add(&pos_ai, eid, Position)
            testing.expect(t, perr == nil)
            p.x = i

            a, aerr := arch_add(&pos_ai, eid, AI)
            testing.expect(t, aerr == ecs.API_Error.Component_Already_Exist)
            a.neurons_count = i * 10

            eids[i] = eid
        }

        other_eids: [3]ecs.entity_id
        for i in 0..<3 {
            eid, cerr := ecs.create_entity(&db)
            testing.expect(t, cerr == nil)
            _, merr := arch_add(&others, eid, Marker)
            testing.expect(t, merr == nil)
            other_eids[i] = eid
        }

        ecs.pause_packing(&db)

        destroyed := 0
        for i in 0..<ecs.table_len(&pos_ai) {
            eid := ecs.get_entity(&pos_ai, i)
            if eid.ix == ecs.DELETED_INDEX do continue
            if i % 2 == 0 {
                testing.expect(t, ecs.destroy_entity(&db, eid) == nil)
                destroyed += 1
            }
        }
        testing.expect(t, destroyed == 3)

        testing.expect(t, ecs.destroy_entity(&db, other_eids[0]) == nil)

        testing.expect(t, pos_ai.holes_count == 3)
        testing.expect(t, others.holes_count == 1)

        testing.expect(t, ecs.resume_packing(&db) == nil)
        testing.expect(t, pos_ai.holes_count == 0)
        testing.expect(t, others.holes_count == 0)
        testing.expect(t, ecs.table_len(&pos_ai) == 3)
        testing.expect(t, ecs.table_len(&others) == 2)
        testing.expect(t, ecs.entities_len(&db) == 5)

        for i in 0..<6 {
            if i % 2 == 0 do continue
            eid := eids[i]

            p := ecs.get_component(&pos_ai, eid, Position)
            testing.expect(t, p != nil && p.x == i)

            a := ecs.get_component(&pos_ai, eid, AI)
            testing.expect(t, a != nil && a.neurons_count == i * 10)
        }

        testing.expect(t, ecs.table__remove_entity(&pos_ai, eids[1]) == nil)
        testing.expect(t, ecs.table_len(&pos_ai) == 2)
    }
