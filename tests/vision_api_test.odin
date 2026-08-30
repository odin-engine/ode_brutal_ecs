/*
    2026 (c) Zaya, https://github.com/zm69

    Typed create_entity1..N, set_component, get_column_ix/get_component-by-col,
    is_in, get_table, move/sudo_move, copy/sudo_copy.
*/

package ode_ecs__tests

// Core
    import "core:testing"
    import "core:log"
    import "core:mem"

// ODE
    import ecs "../src"

    @(test)
    create_entity_typed_values__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        pos_ai: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table__init(&pos_ai, &db, 10, {Position, AI}) == nil)

        // Argument order need not match column order.
        eid1, err1 := ecs.create_entity(&pos_ai, AI{ IQ = 50, neurons_count = 5 }, Position{ x = 1, y = 2 })
        testing.expect(t, err1 == nil)

        p1 := ecs.get_component(&pos_ai, eid1, Position)
        testing.expect(t, p1 != nil && p1.x == 1 && p1.y == 2)
        a1 := ecs.get_component(&pos_ai, eid1, AI)
        testing.expect(t, a1 != nil && a1.IQ == 50 && a1.neurons_count == 5)

        eid2, err2 := ecs.create_entity(&pos_ai, Position{ x = 9, y = 9 })
        testing.expect(t, err2 == nil)
        testing.expect(t, eid2 != eid1)
        testing.expect(t, ecs.table_len(&pos_ai) == 2)
    }

    @(test)
    set_component_and_column_ix__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        pos_ai: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table__init(&pos_ai, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.table__create_entity(&pos_ai)
        testing.expect(t, err == nil)

        p := ecs.set_component(&pos_ai, eid, Position{ x = 3, y = 4 })
        testing.expect(t, p != nil && p.x == 3 && p.y == 4)
        testing.expect(t, ecs.get_component(&pos_ai, eid, Position)^ == Position{ x = 3, y = 4 })

        pos_col := ecs.get_column_ix(&pos_ai, Position)
        ai_col := ecs.get_column_ix(&pos_ai, AI)
        testing.expect(t, pos_col >= 0 && ai_col >= 0 && pos_col != ai_col)

        via_col := ecs.get_component(&pos_ai, eid, pos_col, Position)
        testing.expect(t, via_col == ecs.get_component(&pos_ai, eid, Position))
    }

    @(test)
    is_in_and_get_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table
        ais: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)
        testing.expect(t, ecs.table__init(&ais, &db, 10, {AI}) == nil)

        eid, err := ecs.create_entity(&positions, Position{ x = 1, y = 1 })
        testing.expect(t, err == nil)

        testing.expect(t, ecs.is_in(&positions, eid))
        testing.expect(t, !ecs.is_in(&ais, eid))
        testing.expect(t, ecs.is_in(&db, eid, &positions))
        testing.expect(t, !ecs.is_in(&db, eid, &ais))

        tbl, terr := ecs.get_table(&db, eid)
        testing.expect(t, terr == nil && tbl == &positions)

        untabled, uerr := ecs.database__create_entity(&db)
        testing.expect(t, uerr == nil)
        utbl, uterr := ecs.get_table(&db, untabled)
        testing.expect(t, uterr == nil && utbl == nil)
        testing.expect(t, !ecs.is_in(&positions, untabled))
    }

    @(test)
    move__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table
        pos_ai: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)
        testing.expect(t, ecs.table__init(&pos_ai, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&positions, Position{ x = 7, y = 8 })
        testing.expect(t, err == nil)

        testing.expect(t, ecs.move(eid, &positions, &pos_ai) == nil)

        testing.expect(t, !ecs.is_in(&positions, eid))
        testing.expect(t, ecs.is_in(&pos_ai, eid))
        p := ecs.get_component(&pos_ai, eid, Position)
        testing.expect(t, p != nil && p.x == 7 && p.y == 8) // data carried over
        a := ecs.get_component(&pos_ai, eid, AI)
        testing.expect(t, a != nil && a^ == AI{}) // new column zero-initialized

        testing.expect(t, ecs.table_len(&positions) == 0)
        testing.expect(t, ecs.table_len(&pos_ai) == 1)
    }

    @(test)
    sudo_move_drops_missing_columns__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        pos_ai: ecs.Table
        positions: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table__init(&pos_ai, &db, 10, {Position, AI}) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)

        eid, err := ecs.create_entity(&pos_ai, Position{ x = 5, y = 6 }, AI{ IQ = 1, neurons_count = 2 })
        testing.expect(t, err == nil)

        // positions lacks AI — a plain move would assert; sudo tolerates it.
        testing.expect(t, ecs.sudo_move(eid, &pos_ai, &positions) == nil)

        testing.expect(t, !ecs.is_in(&pos_ai, eid))
        testing.expect(t, ecs.is_in(&positions, eid))
        p := ecs.get_component(&positions, eid, Position)
        testing.expect(t, p != nil && p.x == 5 && p.y == 6)
    }

    @(test)
    copy__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table
        pos_ai: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10, {Position}) == nil)
        testing.expect(t, ecs.table_init(&pos_ai, &db, 10, {Position, AI}) == nil)

        eid, err := ecs.create_entity(&positions, Position{ x = 7, y = 8 })
        testing.expect(t, err == nil)

        new_eid, cerr := ecs.copy(eid, &positions, &pos_ai)
        testing.expect(t, cerr == nil)
        testing.expect(t, new_eid != eid)

        // Source entity/table is untouched by copy.
        testing.expect(t, ecs.is_in(&positions, eid))
        testing.expect(t, ecs.get_component(&positions, eid, Position).x == 7)
        testing.expect(t, ecs.table_len(&positions) == 1)

        testing.expect(t, !ecs.is_in(&pos_ai, eid))
        testing.expect(t, ecs.is_in(&pos_ai, new_eid))
        p := ecs.get_component(&pos_ai, new_eid, Position)
        testing.expect(t, p != nil && p.x == 7 && p.y == 8) // data copied over
        a := ecs.get_component(&pos_ai, new_eid, AI)
        testing.expect(t, a != nil && a^ == AI{}) // new column zero-initialized

        testing.expect(t, ecs.table_len(&pos_ai) == 1)
    }

    @(test)
    sudo_copy_drops_missing_columns__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        pos_ai: ecs.Table
        positions: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table_init(&pos_ai, &db, 10, {Position, AI}) == nil)
        testing.expect(t, ecs.table_init(&positions, &db, 10, {Position}) == nil)

        eid, err := ecs.create_entity(&pos_ai, Position{ x = 5, y = 6 }, AI{ IQ = 1, neurons_count = 2 })
        testing.expect(t, err == nil)

        // positions lacks AI — a plain copy would assert; sudo tolerates it.
        new_eid, cerr := ecs.sudo_copy(eid, &pos_ai, &positions)
        testing.expect(t, cerr == nil)
        testing.expect(t, new_eid != eid)

        testing.expect(t, ecs.is_in(&pos_ai, eid)) // source untouched
        testing.expect(t, ecs.is_in(&positions, new_eid))
        p := ecs.get_component(&positions, new_eid, Position)
        testing.expect(t, p != nil && p.x == 5 && p.y == 6)
    }

    @(test)
    table_destroy_entity__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)

        eid, err := ecs.create_entity(&positions, Position{ x = 1, y = 1 })
        testing.expect(t, err == nil)

        testing.expect(t, ecs.destroy_entity(&db, eid) == nil)
        testing.expect(t, ecs.is_expired(&db, eid))
        testing.expect(t, ecs.table_len(&positions) == 0)
    }

    @(test)
    entity_already_in_table__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        a: ecs.Table
        b: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, entities_cap = 10, allocator = allocator) == nil)
        testing.expect(t, ecs.table__init(&a, &db, 10, {Position}) == nil)
        testing.expect(t, ecs.table__init(&b, &db, 10, {AI}) == nil)

        eid, err := ecs.create_entity(&a, Position{})
        testing.expect(t, err == nil)

        testing.expect(t, ecs.table__add_entity(&b, eid) == ecs.API_Error.Entity_Already_In_Table)
        testing.expect(t, ecs.table__add_entity(&a, eid) == ecs.API_Error.Component_Already_Exist)
    }
