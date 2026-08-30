/*
    2026 (c) Zaya, https://github.com/zm69

    ODE_BRUTAL_ECS port of hybrid Fat Struct architecture from ../fat/main.odin.
    Same scenario (a static rock, a moving player with an inventory, an enemy
    with simple aggro-range AI), rebuilt with ODE_BRUTAL_ECS instead of hand-rolling it.

    An entity belongs to at most one Table, so each entity "shape" gets its
    own archetype table (rocks/players/enemies) instead of one table per
    component — physics and inventory columns for a player live in the same
    row, so update_physics/update_inventories walk one table directly.

    NOTE: errors aren't handled here, to keep the code short.
*/

package ode_ecs_fat_struct_ecs

// Core
    import "core:fmt"

// ODE_BRUTAL_ECS
    import ecs "../../../src"

//
// Components
//

    Position :: struct { x, y, z: f32 }
    Velocity :: struct { dx, dy, dz: f32 }
    Health   :: struct { hp: f32 }

    // No owner_id — get_entity(&table, index) recovers it.
    Inventory :: struct {
        gold:  u32,
        items: [16]u16,
    }

    // Same reasoning — no owner_id.
    AI_State :: struct {
        target:      ecs.entity_id,
        aggro_range: f32,
    }

//
// Config
//

    MAX_ENTITIES :: 100

//
// Systems
//

    // Position and Velocity are columns of the same row now — no cross-table lookup needed.
    update_physics :: proc(players: ^ecs.Table, dt: f32) {
        positions := ecs.slice(players, Position)
        velocities := ecs.slice(players, Velocity)

        for i in 0..<len(positions) {
            positions[i].x += velocities[i].dx * dt
            positions[i].y += velocities[i].dy * dt
            positions[i].z += velocities[i].dz * dt
        }
    }

    // Cold loop — get_entity replaces the manual owner_id back-reference.
    update_inventories :: proc(players: ^ecs.Table) {
        dense := ecs.slice(players, Inventory)
        entities := ecs.entities_slice(players)
        for i in 0..<len(dense) {
            inv := &dense[i]
            owner := entities[i]

            if inv.gold > 0 {
                // Process owner-specific inventory logic
                _ = owner
            }
        }
    }

    update_ai :: proc(enemies: ^ecs.Table, players: ^ecs.Table) {
        dense := ecs.slice(enemies, AI_State)
        owner_positions := ecs.slice(enemies, Position)
        for i in 0..<len(dense) {
            ai := &dense[i]
            owner_pos := &owner_positions[i]

            target_pos := ecs.get_component(players, ai.target, Position)
            if target_pos == nil do continue

            // Example logic: simple aggro-range check
            dx := owner_pos.x - target_pos.x
            dy := owner_pos.y - target_pos.y
            dz := owner_pos.z - target_pos.z
            dist_sq := dx*dx + dy*dy + dz*dz
            if dist_sq <= ai.aggro_range * ai.aggro_range {
                // Process aggro'd AI logic
            }
        }
    }

main :: proc() {
        db: ecs.Database
        defer ecs.terminate(&db)
        ecs.init(&db, MAX_ENTITIES)

        // One archetype table per entity shape — an entity belongs to
        // exactly one of these.
        rocks:   ecs.Table // Position only
        players: ecs.Table // Position + Velocity + Health + Inventory
        enemies: ecs.Table // Position + AI_State

        ecs.table_init(&rocks, &db, MAX_ENTITIES, {Position})
        ecs.table_init(&players, &db, MAX_ENTITIES, {Position, Velocity, Health, Inventory})
        ecs.table_init(&enemies, &db, 10, {Position, AI_State})

        // Rock: Position only.
        rock, _ := ecs.create_entity(&rocks, Position{ 10.0, 0.0, 5.0 })

        // Player: Position + Velocity + Health + Inventory, all one row.
        player, _ := ecs.create_entity(&players,
            Position{ 0.0, 0.0, 0.0 },
            Velocity{ 1.0, 0.0, 0.0 },
            Health{ hp = 100.0 },
            Inventory{ gold = 100 },
        )

        // Enemy: Position + AI, targets the player.
        enemy, _ := ecs.create_entity(&enemies,
            Position{ 3.0, 0.0, 0.0 },
            AI_State{ target = player, aggro_range = 5.0 },
        )

        fmt.println("Rock has velocity (physics-eligible)?", ecs.is_in(&players, rock))
        fmt.println("Player has velocity (physics-eligible)?", ecs.is_in(&players, player))
        fmt.println("AI entities:", ecs.table_len(&enemies))

        update_physics(&players, 0.016)
        update_inventories(&players)
        update_ai(&enemies, &players)

        fmt.println()
        fmt.printfln("Player position after tick: %v", ecs.get_component(&players, player, Position)^)
        fmt.printfln("Rock position after tick (untouched): %v", ecs.get_component(&rocks, rock, Position)^)
}
