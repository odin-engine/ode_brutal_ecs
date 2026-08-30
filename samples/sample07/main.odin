/*
    2026 (c) Zaya, https://github.com/zm69

    Table (Archetype Table) example.

    A Table is ODE_BRUTAL_ECS's archetype-style table: a single struct holding N
    component columns that share ONE row index, so every column of a row moves
    together as one unit.

    This sample shows basic Table usage: init, whole-row create/add/remove,
    get_component, and iterating with slice(&units) + slice(&units, T) — the
    entities_slice + column_slice idiom.
*/

package ode_ecs_sample07

// Core
    import "core:fmt"
    import "core:log"
    import "core:mem"

// ODE_BRUTAL_ECS
    import ecs "../../src"
    import oc "../../src/ode_core"

//
// Components
//

    Position :: struct { x, y: f32 }
    Velocity :: struct { dx, dy: f32 }

main :: proc() {

    //
    // OPTIONAL: Setup memory tracking and logger.
    //
        mem_track: oc.Mem_Track

        context.allocator = oc.mem_track__init(&mem_track, context.allocator)
        defer oc.mem_track__terminate(&mem_track)
        defer oc.mem_track__panic_if_bad_frees_or_leaks(&mem_track)

        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        allocator := context.allocator
        context.allocator = mem.panic_allocator()

    //
    // Actual ODE_BRUTAL_ECS sample starts here.
    //
        err: ecs.Error

        db: ecs.Database

        defer {
            err = ecs.terminate(&db)
            if err != nil do report_error(err)
        }

        err = ecs.init(&db, entities_cap = 100, allocator = allocator)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Part 1: Table basics
    //
        fmt.println("=== Part 1: Table basics ===")
        fmt.println()

        units: ecs.Table
        err = ecs.table_init(&units, &db, cap = 100, component_types = {Position, Velocity})
        if err != nil { report_error(err); return }

        eids: [5]ecs.entity_id
        for i in 0..<5 {
            eids[i], err = ecs.create_entity(&units)
            if err != nil { report_error(err); return }

            pos := ecs.get_component(&units, eids[i], Position)
            pos.x = f32(i)
            pos.y = 0

            vel := ecs.get_component(&units, eids[i], Velocity)
            vel.dx = 1
            vel.dy = f32(i)
        }

        fmt.println("units row count:", ecs.table_len(&units))

        eids_col := ecs.slice(&units)
        pos_col := ecs.slice(&units, Position)
        vel_col := ecs.slice(&units, Velocity)

        fmt.println()
        fmt.println("Iterating units with slice(&units) + slice(&units, T) (one movement step):")
        for i in 0..<len(eids_col) {
            pos_col[i].x += vel_col[i].dx
            pos_col[i].y += vel_col[i].dy
            fmt.println("  entity", eids_col[i], "pos =", pos_col[i])
        }

        err = ecs.remove_entity(&units, eids[2])
        if err != nil { report_error(err); return }
        fmt.println()
        fmt.println("After removing entity 2 from units, row count:", ecs.table_len(&units))
        fmt.println("  has_component(units, eids[2]):", ecs.has_component(&units, eids[2]))
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}
