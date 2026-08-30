/*
    2026 (c) Zaya, https://github.com/zm69

    Pair_Table (many-to-many relations) example.

    A runnable companion to docs/pair_table.md and tests/pair_table_test.odin,
    not a restatement of either — this uses a directional "guard protects VIP"
    relation instead of the doc's "likes" example. Unlike Relations_Table's
    single-parent tree (see sample03/sample08), a Pair_Table holder can point
    at any number of targets, and a target can be pointed at by any number of
    holders.
*/

package ode_ecs_sample09

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

    Protection :: struct { priority: int }

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

        assignments: ecs.Pair_Table(Protection)
        err = ecs.pair_init(&assignments, &db, holders_cap=10, pairs_cap=20)
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Setup
    //
        alpha, beta, gamma, king, queen, diplomat: ecs.entity_id

        for e in ([]^ecs.entity_id{&alpha, &beta, &gamma, &king, &queen, &diplomat}) {
            e^, err = ecs.create_entity(&db)
            if err != nil { report_error(err); return }
        }

        _, err = ecs.pair_add(&assignments, alpha, king, Protection{priority=1})
        if err != nil { report_error(err); return }
        _, err = ecs.pair_add(&assignments, alpha, queen, Protection{priority=2})
        if err != nil { report_error(err); return }
        _, err = ecs.pair_add(&assignments, beta, king, Protection{priority=1})
        if err != nil { report_error(err); return }
        _, err = ecs.pair_add(&assignments, gamma, diplomat, Protection{priority=1})
        if err != nil { report_error(err); return }

    ///////////////////////////////////////////////////////////////////////////////
    // Idempotent add
    //
        _, err = ecs.pair_add(&assignments, beta, king, Protection{priority=99})
        if err != nil { report_error(err); return }

        fmt.println("Re-adding beta->king with priority=99 is a no-op:")
        fmt.println("  has_pair(beta, king):", ecs.pair_has_pair(&assignments, beta, king))
        beta_data, _ := ecs.pair_first_data(&assignments, beta)
        fmt.println("  beta's priority for king is still 1, not 99:", beta_data.priority)

    ///////////////////////////////////////////////////////////////////////////////
    // Queries
    //
        fmt.println()
        fmt.println("Queries:")
        fmt.println("  has_pair(alpha, king):", ecs.pair_has_pair(&assignments, alpha, king))
        fmt.println("  has_any(gamma):", ecs.pair_has_any(&assignments, gamma))

        alpha_target, _ := ecs.pair_first_target(&assignments, alpha)
        fmt.println("  first_target(alpha):", alpha_target, "(most-recently-added: queen)")

        alpha_targets, terr := ecs.pair_targets_of(&assignments, alpha)
        if terr != nil { report_error(terr); return }
        fmt.println("  targets_of(alpha):", alpha_targets, "(king and queen)")

    ///////////////////////////////////////////////////////////////////////////////
    // Automatic cleanup
    //
        err = ecs.destroy_entity(&db, queen)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Destroyed queen (one of alpha's two targets):")
        fmt.println("  has_pair(alpha, queen):", ecs.pair_has_pair(&assignments, alpha, queen))
        alpha_targets2, terr2 := ecs.pair_targets_of(&assignments, alpha)
        if terr2 != nil { report_error(terr2); return }
        fmt.println("  targets_of(alpha):", alpha_targets2, "(king only now)")

        err = ecs.destroy_entity(&db, diplomat)
        if err != nil { report_error(err); return }

        fmt.println()
        fmt.println("Destroyed diplomat (gamma's only target):")
        fmt.println("  has_any(gamma) (auto-evicted, no explicit pair_remove call):", ecs.pair_has_any(&assignments, gamma))

    ///////////////////////////////////////////////////////////////////////////////
    // Explicit remove / remove_all.
    //
        err = ecs.pair_remove(&assignments, alpha, king)
        if err != nil { report_error(err); return }
        fmt.println()
        fmt.println("Removed alpha's last pair (king) -> has_any(alpha):", ecs.pair_has_any(&assignments, alpha))

        err = ecs.pair_remove_all(&assignments, beta)
        if err != nil { report_error(err); return }
        fmt.println("remove_all(beta) -> has_any(beta):", ecs.pair_has_any(&assignments, beta))

        fmt.println("total live pairs:", ecs.table_len(&assignments))

        fmt.println()
        fmt.println("Full serialization round-trips are documented in docs/pair_table.md and")
        fmt.println("demonstrated generally in Sample04 (serialization).")
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}
