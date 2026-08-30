/*
    2026 (c) Zaya, https://github.com/zm69

    Overbase serialization example.

    Builds on sample05's world_ecs/render_ecs sharing one Overbase. Here we
    save all three pieces (the shared Overbase's entity-id space, plus each
    Database's own tables) and restore them into a fresh set of instances —
    the workflow docs/overbase.md's "Serialization" section describes.

    Key points demonstrated:
      - overbase_serialize/overbase_deserialize save/restore just the shared
        id-space, independent of which Databases are attached.
      - world_ecs/render_ecs's own serialize omits the entity-id section
        entirely (they don't own the Overbase) — only their own tables.
      - Restore order matters: the Overbase must be deserialized BEFORE the
        Databases attached to it, since a Database's own rows are validated
        against whichever id-space is live at that moment.
*/

package ode_ecs_sample06

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
    Sprite   :: struct { texture_id: int }

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

    ///////////////////////////////////////////////////////////////////////////////
    // Save side: the same shared-Overbase setup as sample05.
    //
        overbase: ecs.Overbase
        defer {
            err = ecs.overbase_terminate(&overbase)
            if err != nil do report_error(err)
        }
        err = ecs.overbase_init(&overbase, entities_cap = 10, databases_cap = 2, allocator = allocator)
        if err != nil { report_error(err); return }

        world_ecs, render_ecs: ecs.Database
        defer {
            err = ecs.terminate(&render_ecs)
            if err != nil do report_error(err)
        }
        defer {
            err = ecs.terminate(&world_ecs)
            if err != nil do report_error(err)
        }
        err = ecs.init_from_overbase(&world_ecs, &overbase)
        if err != nil { report_error(err); return }
        err = ecs.init_from_overbase(&render_ecs, &overbase)
        if err != nil { report_error(err); return }

        world: ecs.Table
        err = ecs.table_init(&world, &world_ecs, 10, {Position, Velocity})
        if err != nil { report_error(err); return }

        sprites: ecs.Table
        err = ecs.table_init(&sprites, &render_ecs, 10, {Sprite})
        if err != nil { report_error(err); return }

        robot, cerr := ecs.create_entity(&overbase)
        if cerr != nil { report_error(cerr); return }

        werr := ecs.add_entity(&world, robot)
        if werr != nil { report_error(werr); return }
        ecs.set_component(&world, robot, Position{ 10, 20 })
        ecs.set_component(&world, robot, Velocity{ 1, 0 })

        sprerr := ecs.add_entity(&sprites, robot)
        if sprerr != nil { report_error(sprerr); return }
        ecs.set_component(&sprites, robot, Sprite{ texture_id = 42 })

        fmt.println("--- Before save ---")
        fmt.println("robot:", robot)
        fmt.println("  Position:", ecs.get_component(&world, robot, Position)^)
        fmt.println("  Velocity:", ecs.get_component(&world, robot, Velocity)^)
        fmt.println("  Sprite:  ", ecs.get_component(&sprites, robot, Sprite)^)

    ///////////////////////////////////////////////////////////////////////////////
        ob_size, ob_size_err := ecs.overbase_serialized_size(&overbase)
        if ob_size_err != nil { report_error(ob_size_err); return }
        buf_overbase := make([]byte, ob_size, allocator)
        defer delete(buf_overbase, allocator)
        _, err = ecs.overbase_serialize(&overbase, buf_overbase)
        if err != nil { report_error(err); return }

        world_size, world_size_err := ecs.serialized_size(&world_ecs)
        if world_size_err != nil { report_error(world_size_err); return }
        buf_world := make([]byte, world_size, allocator)
        defer delete(buf_world, allocator)
        _, err = ecs.serialize(&world_ecs, buf_world)
        if err != nil { report_error(err); return }

        render_size, render_size_err := ecs.serialized_size(&render_ecs)
        if render_size_err != nil { report_error(render_size_err); return }
        buf_render := make([]byte, render_size, allocator)
        defer delete(buf_render, allocator)
        _, err = ecs.serialize(&render_ecs, buf_render)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Saved", ob_size + world_size + render_size, "bytes total",
            "(overbase:", ob_size, " world:", world_size, " render:", render_size, ")")

    ///////////////////////////////////////////////////////////////////////////////
    // Load side: fresh Overbase + fresh Databases with the same schema
    // (same tables, same init order) as the originals.
    //
        overbase2: ecs.Overbase
        defer {
            err = ecs.overbase_terminate(&overbase2)
            if err != nil do report_error(err)
        }
        err = ecs.overbase_init(&overbase2, entities_cap = 10, databases_cap = 2, allocator = allocator)
        if err != nil { report_error(err); return }

        world_ecs2, render_ecs2: ecs.Database
        defer {
            err = ecs.terminate(&render_ecs2)
            if err != nil do report_error(err)
        }
        defer {
            err = ecs.terminate(&world_ecs2)
            if err != nil do report_error(err)
        }
        err = ecs.init_from_overbase(&world_ecs2, &overbase2)
        if err != nil { report_error(err); return }
        err = ecs.init_from_overbase(&render_ecs2, &overbase2)
        if err != nil { report_error(err); return }

        world2: ecs.Table
        err = ecs.table_init(&world2, &world_ecs2, 10, {Position, Velocity})
        if err != nil { report_error(err); return }

        sprites2: ecs.Table
        err = ecs.table_init(&sprites2, &render_ecs2, 10, {Sprite})
        if err != nil { report_error(err); return }

        // Restore order: the shared Overbase FIRST — it makes `robot` a
        // valid id again in overbase2's live id-space, which is what lets
        // world_ecs2/render_ecs2's own row validation below succeed.
        err = ecs.overbase_deserialize(&overbase2, buf_overbase)
        if err != nil { report_error(err); return }
        err = ecs.deserialize(&world_ecs2, buf_world)
        if err != nil { report_error(err); return }
        err = ecs.deserialize(&render_ecs2, buf_render)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("--- After restore into fresh instances ---")
        fmt.println("robot known to world_ecs2: ", ecs.is_expired(&world_ecs2, robot) == false)
        fmt.println("robot known to render_ecs2:", ecs.is_expired(&render_ecs2, robot) == false)
        fmt.println("  Position:", ecs.get_component(&world2, robot, Position)^)
        fmt.println("  Velocity:", ecs.get_component(&world2, robot, Velocity)^)
        fmt.println("  Sprite:  ", ecs.get_component(&sprites2, robot, Sprite)^)
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}
