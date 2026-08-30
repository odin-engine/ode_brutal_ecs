/*
    2026 (c) Zaya, https://github.com/zm69
*/

package ode_ecs_basics

// Core
    import "core:fmt"

// ODE_BRUTAL_ECS
    import ecs "../../src"

//
// Components
//
    Position :: struct { x, y: int }
    AI :: struct { neurons_count: int }

main :: proc() {

    //
    // Init ECS database
    //
    my_ecs: ecs.Database

    defer ecs.terminate(&my_ecs)
    ecs.init(&my_ecs, entities_cap=100)

    //
    // Init a Table: a true-SoA archetype table holding Position and AI
    // columns side by side for every entity that has both.
    //
    robots : ecs.Table
    ecs.table_init(&robots, &my_ecs, 10, {Position, AI})

    //
    // Create entity and add components
    //
    robot, _ := ecs.create_entity(&robots)

    fmt.println("Robot entity:", robot)

    pos1 := ecs.get_component(&robots, robot, Position)
    pos1.x = 67
    pos1.y = 43

    pos2 := ecs.get_component(&robots, robot, Position)

    assert(pos1 == pos2)

    ai := ecs.get_component(&robots, robot, AI)
    ai.neurons_count = 88

    //
    // Iterate over the archetype table column-by-column (SoA)
    pos_slice := ecs.slice(&robots, Position)
    ai_slice := ecs.slice(&robots, AI)
    eids := ecs.entities_slice(&robots)

    for i in 0..<len(pos_slice) {
        fmt.println("Iterating over Table: ", eids[i], pos_slice[i], ai_slice[i])
    }

    fmt.println("Total memory usage:", ecs.memory_usage(&my_ecs), "bytes")
}
