/*
    2026 (c) Zaya, https://github.com/zm69

    "You do stuff manually" example.
*/

package ode_ecs_sample01

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

    Position :: struct { x, y: f32 }                // C1 — used for rendering
    Velocity :: struct { dx, dy: f32 }              // C2 — dropped in the sudo_move/sudo_copy demos
    Sprite   :: struct { id: int }                  // C3 — used for rendering
    Mana     :: struct { current, max: int }        // C4 — dropped in the sudo_move/sudo_copy demos
    Inventory :: struct { gold: int }               // C5

    Death_Source :: enum { Sword, Fire, Poison }
    DeathInfo :: struct { time_of_death: f32, source_of_death: Death_Source }

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

        err = ecs.init(&db, entities_cap=100, allocator=allocator)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Setup: players plus three "dead" state Tables, each with a different component set.
    //
        players: ecs.Table
        err = ecs.table_init(&players, &db, 10, {Position, Velocity, Sprite, Mana, Inventory}) // C1..C5
        if err != nil { report_error(err); return }

        // Superset of `players` (adds DeathInfo) — the plain `move`/`copy` target.
        dead_players: ecs.Table
        err = ecs.table_init(&dead_players, &db, 10, {Position, Velocity, Sprite, Mana, Inventory, DeathInfo})
        if err != nil { report_error(err); return }

        // Missing Velocity/Mana on purpose — a plain move/copy here would assert; only sudo_move/sudo_copy can target it.
        dead_players_lean: ecs.Table
        err = ecs.table_init(&dead_players_lean, &db, 10, {Position, Sprite, Inventory, DeathInfo})
        if err != nil { report_error(err); return }

        // Same shape as dead_players — a second Table used purely to tag entities as burned.
        burned_players: ecs.Table
        err = ecs.table_init(&burned_players, &db, 10, {Position, Velocity, Sprite, Mana, Inventory, DeathInfo})
        if err != nil { report_error(err); return }

        conan, torvald, ember, merlin, scout: ecs.entity_id

        conan, err = ecs.create_entity(&players, Position{1, 1}, Velocity{1, 0}, Sprite{101}, Mana{50, 50}, Inventory{10})
        if err != nil { report_error(err); return }
        torvald, err = ecs.create_entity(&players, Position{2, 2}, Velocity{0, 1}, Sprite{102}, Mana{80, 80}, Inventory{20})
        if err != nil { report_error(err); return }
        ember, err = ecs.create_entity(&players, Position{3, 3}, Velocity{1, 1}, Sprite{103}, Mana{30, 30}, Inventory{5})
        if err != nil { report_error(err); return }
        merlin, err = ecs.create_entity(&players, Position{4, 4}, Velocity{0, 0}, Sprite{104}, Mana{99, 99}, Inventory{40})
        if err != nil { report_error(err); return }
        scout, err = ecs.create_entity(&players, Position{5, 5}, Velocity{2, 0}, Sprite{105}, Mana{10, 10}, Inventory{2})
        if err != nil { report_error(err); return }

        fmt.println("Created 5 players in `players`:", ecs.table_len(&players), "rows")

    ///////////////////////////////////////////////////////////////////////////////
    // RULE #1: an entity exists in only one Table, so killing conan means moving him from players to dead_players.
    //
        fmt.println()
        fmt.println("RULE #1: move conan from `players` to `dead_players` (superset table)")

        conan_pos_before := ecs.get_component(&players, conan, Position)^

        err = ecs.move(conan, from = &players, to = &dead_players)
        if err != nil { report_error(err); return }

        fmt.println("  conan is_in(players):", ecs.is_in(&players, conan), "(false - RULE #1: at most one Table at a time)")
        fmt.println("  conan is_in(dead_players):", ecs.is_in(&dead_players, conan))
        fmt.println("  conan Position carried over:", ecs.get_component(&dead_players, conan, Position)^ == conan_pos_before)
        fmt.println("  conan DeathInfo is zero-valued (new column):", ecs.get_component(&dead_players, conan, DeathInfo)^ == DeathInfo{})

        // conan died by the sword — set his DeathInfo now that the row exists.
        ecs.get_component(&dead_players, conan, DeathInfo)^ = DeathInfo{ time_of_death = 10.0, source_of_death = .Sword }

        // torvald died by fire but stays in dead_players, to fuel the discriminant-field render approach below.
        err = ecs.move(torvald, from = &players, to = &dead_players)
        if err != nil { report_error(err); return }
        ecs.get_component(&dead_players, torvald, DeathInfo)^ = DeathInfo{ time_of_death = 12.0, source_of_death = .Fire }

    ///////////////////////////////////////////////////////////////////////////////
    // Fail early — this would assert, since dead_players_lean is missing Velocity/Mana:
    //
    //     ecs.move(merlin, from = &players, to = &dead_players_lean)
    //
    // Use sudo_move instead to silently drop whatever doesn't fit.
    //
        fmt.println()
        fmt.println("sudo_move merlin into `dead_players_lean` (missing Velocity/Mana)")

        err = ecs.sudo_move(merlin, from = &players, to = &dead_players_lean)
        if err != nil { report_error(err); return }

        fmt.println("  merlin is_in(dead_players_lean):", ecs.is_in(&dead_players_lean, merlin))
        fmt.println("  dead_players_lean has no Velocity column:", ecs.get_column_ix(&dead_players_lean, Velocity) < 0)
        fmt.println("  dead_players_lean has no Mana column:", ecs.get_column_ix(&dead_players_lean, Mana) < 0)
        ecs.get_component(&dead_players_lean, merlin, DeathInfo)^ = DeathInfo{ time_of_death = 15.0, source_of_death = .Poison }

    ///////////////////////////////////////////////////////////////////////////////
    // copy/sudo_copy: same superset/subset rule as move/sudo_move, but the source entity is left untouched.
    //
        fmt.println()
        fmt.println("copy/sudo_copy: duplicate the still-alive `scout` without touching the original")

        scout_pos_before := ecs.get_component(&players, scout, Position)^

        scout_ghost, cerr := ecs.copy(scout, &players, &dead_players)
        if cerr != nil { report_error(cerr); return }

        fmt.println("  scout is still alive in players:", ecs.is_in(&players, scout))
        fmt.println("  scout position unchanged:", ecs.get_component(&players, scout, Position)^ == scout_pos_before)
        fmt.println("  scout_ghost is a distinct new entity:", scout_ghost != scout)
        fmt.println("  scout_ghost is_in(dead_players):", ecs.is_in(&dead_players, scout_ghost))
        fmt.println("  scout_ghost's DeathInfo is zero-valued, since scout never had one to copy:", ecs.get_component(&dead_players, scout_ghost, DeathInfo)^ == DeathInfo{})

        // sudo_copy into the lean table drops Velocity/Mana on the copy; a plain copy here would assert.
        scout_lean_ghost, scerr := ecs.sudo_copy(scout, &players, &dead_players_lean)
        if scerr != nil { report_error(scerr); return }

        fmt.println("  scout still alive after sudo_copy too:", ecs.is_in(&players, scout))
        fmt.println("  scout_lean_ghost is_in(dead_players_lean):", ecs.is_in(&dead_players_lean, scout_lean_ghost))

    ///////////////////////////////////////////////////////////////////////////////
    // Tagging via a dedicated Table: ember died by fire, so she moves to burned_players instead of dead_players.
    //
        fmt.println()
        fmt.println("Tagging: move ember to `burned_players` instead of `dead_players`")

        err = ecs.move(ember, from = &players, to = &burned_players)
        if err != nil { report_error(err); return }
        ecs.get_component(&burned_players, ember, DeathInfo)^ = DeathInfo{ time_of_death = 20.0, source_of_death = .Fire }

        fmt.println("  ember is_in(burned_players):", ecs.is_in(&burned_players, ember))
        fmt.println("  ember is_in(dead_players):", ecs.is_in(&dead_players, ember), "(false - she's tagged via a different Table entirely)")

    ///////////////////////////////////////////////////////////////////////////////
    // Render approach 1: separate Tables per tag/state, sliced and rendered independently.
    //
        fmt.println()
        fmt.println("Render approach 1 (separate Tables):")
        render_dead_players_two_tables(&dead_players, &burned_players)

    ///////////////////////////////////////////////////////////////////////////////
    // Render approach 2: one Table, branching on the DeathInfo.source_of_death discriminant field.
    //
        fmt.println()
        fmt.println("Render approach 2 (single Table + DeathInfo.source_of_death discriminant):")
        render_dead_players_discriminant(&dead_players)

    ///////////////////////////////////////////////////////////////////////////////
    // Cross-table iteration: no built-in query, so write a generic proc and call it once per table.
    //
        fmt.println()
        fmt.println("Cross-table generic iteration (Position + Sprite, every table):")

        do_something_with_position_and_sprite(&players)
        do_something_with_position_and_sprite(&dead_players)
        do_something_with_position_and_sprite(&dead_players_lean)
        do_something_with_position_and_sprite(&burned_players)

    ///////////////////////////////////////////////////////////////////////////////
    // Adding/removing components is just moving to a table with more or fewer columns.
    //
        fmt.println()
        fmt.println("Adding/removing components is just move/sudo_move to a differently-shaped table:")
        fmt.println("  - \"adding\" DeathInfo to conan = the RULE #1 move into `dead_players` above.")
        fmt.println("  - \"removing\" Velocity+Mana from merlin = the sudo_move into `dead_players_lean` above.")
}

//
// Renders dead_players and burned_players as two independent Tables.
//
render_dead_players_two_tables :: proc(dead_players: ^ecs.Table, burned_players: ^ecs.Table) {

    //
    // Render normal dead bodies.
    //
    pos_slice := ecs.slice(dead_players, Position)
    sprite_slice := ecs.slice(dead_players, Sprite)

    // All slices from the same table always have the same length.
    for i in 0..<len(pos_slice) {
        fmt.println("  [normal body]", pos_slice[i], sprite_slice[i])
    }

    //
    // Render burned bodies.
    //
    pos_slice = ecs.slice(burned_players, Position)
    sprite_slice = ecs.slice(burned_players, Sprite)

    for i in 0..<len(pos_slice) {
        fmt.println("  [burned body] ", pos_slice[i], sprite_slice[i])
    }
}

//
// Renders dead_players by branching on DeathInfo.source_of_death instead of a second Table.
//
render_dead_players_discriminant :: proc(dead_players: ^ecs.Table) {

    pos_slice := ecs.slice(dead_players, Position)
    sprite_slice := ecs.slice(dead_players, Sprite)
    death_info_slice := ecs.slice(dead_players, DeathInfo)

    for i in 0..<len(pos_slice) {
        if death_info_slice[i].source_of_death == .Fire {
            fmt.println("  [burned body] ", pos_slice[i], sprite_slice[i])
        } else {
            fmt.println("  [normal body]", pos_slice[i], sprite_slice[i])
        }
    }
}

//
// Generic proc that works on any Table with Position and Sprite columns, regardless of what else it has.
//
do_something_with_position_and_sprite :: proc(table: ^ecs.Table) {

    pos_slice := ecs.slice(table, Position)
    sprite_slice := ecs.slice(table, Sprite)

    for i in 0..<len(pos_slice) {
        fmt.println("  ", pos_slice[i], sprite_slice[i])
    }
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}
