/*
    2026 (c) Zaya, https://github.com/zm69

    This example shows how to optimize your ECS (Approach 1 vs. Approach 2).

    Run this sample with speed optimizations to see results closer to real-world performance:

    odin run . -o:speed
*/

package ode_ecs_sample2

// Base
    import "base:runtime"

// Core
    import "core:fmt"
    import "core:log"
    import "core:mem"
    import "core:math/rand"
    import "core:time"

// ODE_BRUTAL_ECS
    import ecs "../../src"
    import oc "../../src/ode_core"

//
// Defines
    NUMBER_OF_ENTITIES :: 100_000

//
// Approach 1
//
    Enemy1 :: struct {
        id: int,

        // State
        dead: bool,
        frenzy: bool,
    }

    db1: ecs.Database

    all_enemies : ecs.Table

//
// Approach 2
    Enemy2 :: struct {
        id: int,
    }

    db2: ecs.Database

    dead_enemies : ecs.Table
    frenzy_enemies: ecs.Table
    normal_enemies: ecs.Table

//
// Approach 1 with payload (more data to make things more realistic)
//
    Enemy1_With_Payload :: struct {
        id: int,

        // State
        dead: bool,
        frenzy: bool,

        // Payload to make things more realistic
        some_data: [20]int,
    }

    db1_with_payload: ecs.Database

    all_enemies_with_payload : ecs.Table

//
// Approach 2 with payload
    Enemy2_With_Payload :: struct {
        id: int,

        // Payload
        some_data: [20]int,
    }

    db2_with_payload: ecs.Database

    dead_enemies_with_payload : ecs.Table
    frenzy_enemies_with_payload: ecs.Table
    normal_enemies_with_payload: ecs.Table

main :: proc() {

    //
    // OPTIONAL: Setup memory tracking and logger.
    //
        mem_track: oc.Mem_Track

        context.allocator = oc.mem_track__init(&mem_track, context.allocator)
        defer oc.mem_track__terminate(&mem_track)
        defer oc.mem_track__panic_if_bad_frees_or_leaks(&mem_track) // Defers run in reverse declaration order

        context.logger = log.create_console_logger()
        defer log.destroy_console_logger(context.logger)

        // Panic allocator ensures no allocations happen outside the provided allocator
        allocator := context.allocator
        context.allocator = mem.panic_allocator()

    //
    // Variables
        err: ecs.Error
        eid1: ecs.entity_id
        eid2: ecs.entity_id

        eid1_with_payload: ecs.entity_id
        eid2_with_payload: ecs.entity_id

        enemy1: ^Enemy1
        enemy2: ^Enemy2

        enemy1_with_payload: ^Enemy1_With_Payload
        enemy2_with_payload: ^Enemy2_With_Payload

        sw: time.Stopwatch
    //
    // Init db1
        defer ecs.terminate(&db1)
        err = ecs.init(&db1, NUMBER_OF_ENTITIES, allocator)
        if err != nil { report_error(err); return }

        err = ecs.table_init(&all_enemies, &db1, NUMBER_OF_ENTITIES, {Enemy1})
        if err != nil { report_error(err); return }

    // Init db2
        defer ecs.terminate(&db2)
        ecs.init(&db2, NUMBER_OF_ENTITIES, allocator)

        err = ecs.table_init(&normal_enemies, &db2, NUMBER_OF_ENTITIES, {Enemy2})
        if err != nil { report_error(err); return }

        err = ecs.table_init(&dead_enemies, &db2, NUMBER_OF_ENTITIES, {Enemy2})
        if err != nil { report_error(err); return }

        err = ecs.table_init(&frenzy_enemies, &db2, NUMBER_OF_ENTITIES, {Enemy2})
        if err != nil { report_error(err); return }

    //
    // Init db1 with payload
        defer ecs.terminate(&db1_with_payload)
        err = ecs.init(&db1_with_payload, NUMBER_OF_ENTITIES, allocator)
        if err != nil { report_error(err); return }

        err = ecs.table_init(&all_enemies_with_payload, &db1_with_payload, NUMBER_OF_ENTITIES, {Enemy1_With_Payload})
        if err != nil { report_error(err); return }

    //
    // Init db2 with payload
        defer ecs.terminate(&db2_with_payload)
        ecs.init(&db2_with_payload, NUMBER_OF_ENTITIES, allocator)

        err = ecs.table_init(&normal_enemies_with_payload, &db2_with_payload, NUMBER_OF_ENTITIES, {Enemy2_With_Payload})
        if err != nil { report_error(err); return }

        err = ecs.table_init(&dead_enemies_with_payload, &db2_with_payload, NUMBER_OF_ENTITIES, {Enemy2_With_Payload})
        if err != nil { report_error(err); return }

        err = ecs.table_init(&frenzy_enemies_with_payload, &db2_with_payload, NUMBER_OF_ENTITIES, {Enemy2_With_Payload})
        if err != nil { report_error(err); return }

    //
    // Fill both dbs with the "same" data
    //
        EnemyState :: enum { Normal, Dead, Frenzy }
        choose_state: []EnemyState = { .Normal, .Dead, .Frenzy }

        for i:=0; i < NUMBER_OF_ENTITIES; i+=1 {
            eid1, err = ecs.create_entity(&all_enemies)
            if err != nil { report_error(err); return }
            enemy1 = ecs.get_component(&all_enemies, eid1, Enemy1)
            enemy1.id = i

            eid2, err = ecs.create_entity(&db2)
            if err != nil { report_error(err); return }

            // With payload:

            eid1_with_payload, err = ecs.create_entity(&all_enemies_with_payload)
            if err != nil { report_error(err); return }
            enemy1_with_payload = ecs.get_component(&all_enemies_with_payload, eid1_with_payload, Enemy1_With_Payload)
            enemy1_with_payload.id = i

            eid2_with_payload, err = ecs.create_entity(&db2_with_payload)
            if err != nil { report_error(err); return }

            switch rand.choice(choose_state[:]) {
                case .Normal:
                    enemy1.dead = false
                    enemy1.frenzy = false

                    err = ecs.add_entity(&normal_enemies, eid2)
                    enemy2 = ecs.get_component(&normal_enemies, eid2, Enemy2)
                    enemy2.id = i

                    // With payload:

                    enemy1_with_payload.dead = false
                    enemy1_with_payload.frenzy = false

                    err = ecs.add_entity(&normal_enemies_with_payload, eid2_with_payload)
                    enemy2_with_payload = ecs.get_component(&normal_enemies_with_payload, eid2_with_payload, Enemy2_With_Payload)
                    enemy2_with_payload.id = i

                case .Dead:
                    enemy1.dead = true
                    enemy1.frenzy = false

                    err = ecs.add_entity(&dead_enemies, eid2)
                    enemy2 = ecs.get_component(&dead_enemies, eid2, Enemy2)
                    enemy2.id = i

                    // With payload:

                    enemy1_with_payload.dead = true
                    enemy1_with_payload.frenzy = false

                    err = ecs.add_entity(&dead_enemies_with_payload, eid2_with_payload)
                    enemy2_with_payload = ecs.get_component(&dead_enemies_with_payload, eid2_with_payload, Enemy2_With_Payload)
                    enemy2_with_payload.id = i

                case .Frenzy:
                    enemy1.dead = false
                    enemy1.frenzy = true

                    err = ecs.add_entity(&frenzy_enemies, eid2)
                    enemy2 = ecs.get_component(&frenzy_enemies, eid2, Enemy2)
                    enemy2.id = i

                    // With payload:

                    enemy1_with_payload.dead = false
                    enemy1_with_payload.frenzy = true

                    err = ecs.add_entity(&frenzy_enemies_with_payload, eid2_with_payload)
                    enemy2_with_payload = ecs.get_component(&frenzy_enemies_with_payload, eid2_with_payload, Enemy2_With_Payload)
                    enemy2_with_payload.id = i
            }
        }

    //
    // Test speed
        // Approach 1
        time.stopwatch_start(&sw)

            for &en, index in ecs.slice(&all_enemies, Enemy1) {

                if en.dead {
                    en.id += 1
                } else if en.frenzy {
                    en.id += 2
                } else {
                    en.id += 3
                }

            }

        time.stopwatch_stop(&sw)
        _, _, _, nanos1 := time.precise_clock_from_stopwatch(sw)

        // Approach 2
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            for &en, index in ecs.slice(&dead_enemies, Enemy2) {
                en.id += 1
            }

            for &en, index in ecs.slice(&frenzy_enemies, Enemy2) {
                en.id += 2
            }

            for &en, index in ecs.slice(&normal_enemies, Enemy2) {
                en.id += 3
            }


        time.stopwatch_stop(&sw)
        _, _, _, nanos2 := time.precise_clock_from_stopwatch(sw)

    //
    // Test speed with payload
    //
        // Approach 1 with payload
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            for &en, index in ecs.slice(&all_enemies_with_payload, Enemy1_With_Payload) {

                if en.dead {
                    en.id += 1
                } else if en.frenzy {
                    en.id += 2
                } else {
                    en.id += 3
                }

            }

        time.stopwatch_stop(&sw)
        _, _, _, nanos1_with_payload := time.precise_clock_from_stopwatch(sw)

        // Approach 2 with payload
        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

            for &en, index in ecs.slice(&dead_enemies_with_payload, Enemy2_With_Payload) {
                en.id += 1
            }

            for &en, index in ecs.slice(&frenzy_enemies_with_payload, Enemy2_With_Payload) {
                en.id += 2
            }

            for &en, index in ecs.slice(&normal_enemies_with_payload, Enemy2_With_Payload) {
                en.id += 3
            }


        time.stopwatch_stop(&sw)
        _, _, _, nanos2_with_payload := time.precise_clock_from_stopwatch(sw)

    //
    // Print results
        s:= oc.add_thousand_separator(NUMBER_OF_ENTITIES, sep=',', allocator=allocator)
        fmt.println("Iterating over", s, "entities.")
        delete(s, allocator)

        fmt.println("")

        difference := f64(nanos1) / f64(nanos2)

        fmt.printfln("%-30s %.4f ms", "Approach 1 time:", f64(nanos1)/1_000_000.0)
        fmt.printfln("%-30s %.4f ms", "Approach 2 time:", f64(nanos2)/1_000_000.0)
        fmt.println("-----------------------------------------------------------")
        fmt.printfln("%-30s %.4f times", "Difference is ", difference)

        fmt.println("")

        difference_with_payload := f64(nanos1_with_payload) / f64(nanos2_with_payload)

        fmt.printfln("%-30s %.4f ms", "Approach 1 with payload time:", f64(nanos1_with_payload)/1_000_000.0)
        fmt.printfln("%-30s %.4f ms", "Approach 2 with payload time:", f64(nanos2_with_payload)/1_000_000.0)
        fmt.println("-----------------------------------------------------------")
        fmt.printfln("%-30s %.4f times", "Difference is ", difference_with_payload)

        fmt.println("")
        fmt.println("")

        fmt.printfln("%-30s \"Approach 2\" is %.1f to %.1f times faster than \"Approach 1\", depending on the component size", "End result: ", difference_with_payload, difference)
}

report_error :: proc (err: ecs.Error, loc := #caller_location) {
    log.error("Error:", err, location = loc)
}
