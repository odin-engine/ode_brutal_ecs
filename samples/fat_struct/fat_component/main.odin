/*
    2026 (c) Zaya, https://github.com/zm69

    "Fat component" architecture: same scenario as ../fat/main.odin, but the
    whole monolithic hot-path struct (flags/position/velocity/health) becomes
    ONE ODE_BRUTAL_ECS component.

    Demonstrates: ODE_BRUTAL_ECS doesn't force fine-grained decomposition — you can
    unite hot-path data into a single fat component and still get entity
    lifecycle and O(1) lookups. An entity belongs to at most one Table, so
    sparse/rare components (Inventory, AI_State) live as extra columns on
    the archetype table for the entity shapes that need them, rather than
    in their own tables layered on top of a shared one.

    NOTE: errors aren't handled here, to keep the code short.
*/

package ode_ecs_fat_struct_fat_component

// Core
    import "core:fmt"

// ODE_BRUTAL_ECS
    import ecs "../../../src"

//
// Components
//

    Entity_Flags :: bit_set[Entity_Flag; u16]
    Entity_Flag  :: enum u16 {
        Active,
        Has_Physics,
    }

    // The fat component: position/velocity/health/flags bundled into ONE
    // ODE_BRUTAL_ECS component instead of split into separate Position/Velocity/
    // Health columns of a Table.
    Entity :: struct #align(16) {
        flags:    Entity_Flags,
        position: [3]f32,
        velocity: [3]f32,
        health:   f32,
    }

    // No owner_id — get_entity(&table, index) recovers it.
    Inventory :: struct {
        gold:  u32,
        items: [16]u16,
    }

    // Same reasoning — no owner_id/target_id.
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

    // Hot loop — a single Table(Entity) column walk.
    update_physics :: proc(table: ^ecs.Table, dt: f32) {
        for &e in ecs.slice(table, Entity) {
            if .Active not_in e.flags || .Has_Physics not_in e.flags {
                continue
            }

            e.position += e.velocity * dt
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
        owner_entities := ecs.slice(enemies, Entity)
        for i in 0..<len(dense) {
            ai := &dense[i]
            owner_e := &owner_entities[i]

            target_e := ecs.get_component(players, ai.target, Entity)
            if target_e == nil do continue

            // Example logic: simple aggro-range check
            d := owner_e.position - target_e.position
            dist_sq := d[0]*d[0] + d[1]*d[1] + d[2]*d[2]
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
        rocks:   ecs.Table // Entity only
        players: ecs.Table // Entity + Inventory
        enemies: ecs.Table // Entity + AI_State

        ecs.table_init(&rocks, &db, MAX_ENTITIES, {Entity})
        ecs.table_init(&players, &db, 10, {Entity, Inventory})
        ecs.table_init(&enemies, &db, 10, {Entity, AI_State})

        // Rock: Active only — no physics, no inventory, no AI.
        rock, _ := ecs.create_entity(&rocks, Entity{ flags = {.Active}, position = {10.0, 0.0, 5.0} })

        // Player: physics + inventory, one row.
        player, _ := ecs.create_entity(&players,
            Entity{
                flags    = {.Active, .Has_Physics},
                position = {0.0, 0.0, 0.0},
                velocity = {1.0, 0.0, 0.0},
                health   = 100.0,
            },
            Inventory{ gold = 100 },
        )

        // Enemy: Position (via Entity) + AI, targets the player.
        enemy, _ := ecs.create_entity(&enemies,
            Entity{ flags = {.Active}, position = {3.0, 0.0, 0.0} },
            AI_State{ target = player, aggro_range = 5.0 },
        )

        fmt.println("Rock has physics flag?", .Has_Physics in ecs.get_component(&rocks, rock, Entity).flags)
        fmt.println("Player has physics flag?", .Has_Physics in ecs.get_component(&players, player, Entity).flags)
        fmt.println("AI entities:", ecs.table_len(&enemies))

        update_physics(&rocks, 0.016)
        update_physics(&players, 0.016)
        update_physics(&enemies, 0.016)
        update_inventories(&players)
        update_ai(&enemies, &players)

        fmt.println()
        fmt.printfln("Player position after tick: %v", ecs.get_component(&players, player, Entity).position)
        fmt.printfln("Rock position after tick (untouched): %v", ecs.get_component(&rocks, rock, Entity).position)
}
