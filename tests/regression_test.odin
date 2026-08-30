/*
    2026 (c) Zaya, https://github.com/zm69

    Regression tests for stale-state bugs around the terminate + re-init
    pattern (issue #8) and a few API consistency fixes.

    View, Iterator, Table, Compact_Table, Tiny_Table, and Group were removed
    from ode_ecs2 (see the removal plan). Every regression proc that existed
    purely to guard internal behavior of those removed types was deleted
    along with them — the bug class it guarded no longer exists because the
    code it guarded is gone. The procs below guard behavior that is still
    present, ported onto Table where a component-carrying fixture is
    needed.
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
// Re-init (issue #8) must not leak state from the previous life

    @(test)
    database_reinit_resets_tail_swap_pause__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator() // no allocations outside provided allocator

        db: ecs.Database
        positions: ecs.Table

        // Terminate while paused, then re-init
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        ecs.pause_packing(&db)
        testing.expect(t, ecs.terminate(&db) == nil)

        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, db.tail_swap_paused == false)

        // Normal (unpaused) removal must tail-swap, not leave a hole
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)
        e1, _ := ecs.create_entity(&db)
        e2, _ := ecs.create_entity(&db)
        _ = ecs.table__add_entity(&positions, e1)
        _ = ecs.table__add_entity(&positions, e2)

        testing.expect(t, ecs.table__remove_entity(&positions, e1) == nil)
        testing.expect_value(t, ecs.table_len(&positions), 1)

        // clear() returns the database to its post-init state, unpaused
        ecs.pause_packing(&db)
        testing.expect(t, ecs.clear(&db) == nil)
        testing.expect(t, db.tail_swap_paused == false)

        testing.expect(t, ecs.terminate(&db) == nil)
    }

    @(test)
    table_pause_survives_database_resume__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table

        defer ecs.terminate(&db)
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)

        eids: [3]ecs.entity_id
        for i in 0..<3 {
            eids[i], _ = ecs.create_entity(&db)
            _ = ecs.table__add_entity(&positions, eids[i])
        }

        ecs.pause_packing(&db)
        testing.expect(t, ecs.pause_packing(&positions) == nil)

        testing.expect(t, ecs.table__remove_entity(&positions, eids[1]) == nil)
        testing.expect(t, positions.holes_count == 1)

        // db-wide resume packs the still-individually-paused table...
        testing.expect(t, ecs.resume_packing(&db) == nil)
        testing.expect(t, db.tail_swap_paused == false)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 2)

        // ...but the table's own pause survives: a later removal still defers
        testing.expect(t, ecs.table__remove_entity(&positions, eids[0]) == nil)
        testing.expect(t, positions.holes_count == 1)
        testing.expect(t, ecs.table_len(&positions) == 2) // row span unchanged: hole, not tail-swapped

        testing.expect(t, ecs.resume_packing(&positions) == nil)
        testing.expect(t, positions.holes_count == 0)
        testing.expect(t, ecs.table_len(&positions) == 1)
    }

    @(test)
    table_pause_packing_reinit_clear__test :: proc(t: ^testing.T) {
        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

        db: ecs.Database
        positions: ecs.Table

        // Terminate while table-paused, then re-init: flag must reset
        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)
        testing.expect(t, ecs.pause_packing(&positions) == nil)
        testing.expect(t, ecs.terminate(&db) == nil)

        testing.expect(t, ecs.init(&db, 10, allocator) == nil)
        testing.expect(t, ecs.table__init(&positions, &db, 10, {Position}) == nil)
        testing.expect(t, positions.pause_packing == false)

        // clear() is a data-only reset: the pause must survive it
        testing.expect(t, ecs.pause_packing(&positions) == nil)
        testing.expect(t, ecs.clear(&positions) == nil)
        testing.expect(t, positions.pause_packing == true)

        testing.expect(t, ecs.resume_packing(&positions) == nil)
        testing.expect(t, ecs.terminate(&db) == nil)
    }

///////////////////////////////////////////////////////////////////////////////
// API consistency

