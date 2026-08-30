/*
    2026 (c) Zaya, https://github.com/zm69

    Mix of hybrid Fat Struct + ECS architectures: a middle ground between
    ../fat/main.odin (fully hand-rolled) and ../ecs/main.odin (fully ODE_BRUTAL_ECS).
    Keeps the monolithic Entity struct + Entity_Flags + plain array for the
    hot path (position/velocity/health - ../fat/main.odin's update_physics,
    unchanged), but replaces the hand-rolled Inventory/AI_State pools with
    real ODE_BRUTAL_ECS Tables, same as ../ecs/main.odin. Demonstrates
    adopting ODE_BRUTAL_ECS incrementally for sparse/rare data only, without
    converting the hot path.

    NOTE: errors aren't handled here, to keep the code short.
*/

package ode_ecs_fat_struct_mix

// Core
    import "core:fmt"

// ODE_BRUTAL_ECS
    import ecs "../../../src"

//
// Hot-path data: monolithic Entity struct, same as ../fat/main.odin
//

    Entity_Flags :: bit_set[Entity_Flag; u16]
    Entity_Flag  :: enum u16 {
        Active,
        Has_Physics,
    }

    Entity :: struct #align(16) {
        eid:      ecs.entity_id, // also the key into World.inventories/ais below
        flags:    Entity_Flags,

        position: [3]f32,
        velocity: [3]f32,
        health:   f32,
    }

    Inventory :: struct {
        gold:  u32,
        items: [16]u16,
    }

    AI_State :: struct {
        target:      ecs.entity_id,
        aggro_range: f32,
    }

//
// World
//

    World :: struct {
        entities: [dynamic]Entity, // hot path: plain array, walked directly

        // cold path: entity id allocation + sparse/rare component tables
        db:          ecs.Database,
        inventories: ecs.Table,
        ais:         ecs.Table,
    }

//
// Config
//

    MAX_ENTITIES :: 100

//
// World setup/teardown
//

    world_init :: proc(world: ^World, max_entities: u32) {
        world.entities = make([dynamic]Entity, 0, int(max_entities))

        ecs.init(&world.db, max_entities)
        ecs.table_init(&world.inventories, &world.db, 10, {Inventory})
        ecs.table_init(&world.ais, &world.db, 10, {AI_State})
    }

    world_terminate :: proc(world: ^World) {
        // Tables are attached to db and cleaned up automatically by
        // ecs.terminate — no manual ecs.table_terminate calls needed.
        delete(world.entities)
        ecs.terminate(&world.db)
    }

    // Creates the entity on both sides at once: the ODE_BRUTAL_ECS id (keys
    // Inventory/AI_State) and the matching Entity row in the hot-path array.
    world_create_entity :: proc(world: ^World) -> ecs.entity_id {
        eid, _ := ecs.create_entity(&world.db)
        append(&world.entities, Entity{ eid = eid })
        return eid
    }

    world_entity :: #force_inline proc(world: ^World, eid: ecs.entity_id) -> ^Entity {
        return &world.entities[eid.ix]
    }

//
// Systems
//

    // Hot loop — unchanged from ../fat/main.odin: no ECS involvement at all.
    update_physics :: proc(world: ^World, dt: f32) {
        for &e in world.entities {
            if .Active not_in e.flags || .Has_Physics not_in e.flags {
                continue
            }

            e.position += e.velocity * dt
        }
    }

    // Cold loop — get_entity + world_entity replaces the manual owner_id
    // back-reference field.
    update_inventories :: proc(world: ^World, inventories: ^ecs.Table) {
        dense := ecs.slice(inventories, Inventory)
        entities := ecs.entities_slice(inventories)
        for i in 0..<len(dense) {
            inv := &dense[i]
            owner := world_entity(world, entities[i])

            if inv.gold > 0 {
                // Process owner-specific inventory logic
                _ = owner
            }
        }
    }

    update_ai :: proc(world: ^World, ais: ^ecs.Table) {
        dense := ecs.slice(ais, AI_State)
        entities := ecs.entities_slice(ais)
        for i in 0..<len(dense) {
            ai := &dense[i]
            owner  := world_entity(world, entities[i])
            target := world_entity(world, ai.target)

            // Example logic: simple aggro-range check
            d := owner.position - target.position
            dist_sq := d[0]*d[0] + d[1]*d[1] + d[2]*d[2]
            if dist_sq <= ai.aggro_range * ai.aggro_range {
                // Process aggro'd AI logic
            }
        }
    }

main :: proc() {
        world: World
        defer world_terminate(&world)
        world_init(&world, MAX_ENTITIES)

        // Rock: Position only.
        rock_eid := world_create_entity(&world)

        rock := world_entity(&world, rock_eid)
        rock.flags = { .Active }
        rock.position = { 10.0, 0.0, 5.0 }

        // Player: physics + inventory.
        player_eid := world_create_entity(&world)

        player := world_entity(&world, player_eid)
        player.flags = { .Active, .Has_Physics }
        player.position = { 0.0, 0.0, 0.0 }
        player.velocity = { 1.0, 0.0, 0.0 }
        player.health = 100.0

        ecs.add_entity(&world.inventories, player_eid)
        ecs.set_component(&world.inventories, player_eid, Inventory{ gold = 100 })

        // Enemy: Position + AI, targets the player.
        enemy_eid := world_create_entity(&world)

        enemy := world_entity(&world, enemy_eid)
        enemy.flags = { .Active }
        enemy.position = { 3.0, 0.0, 0.0 }

        ecs.add_entity(&world.ais, enemy_eid)
        ecs.set_component(&world.ais, enemy_eid, AI_State{ target = player_eid, aggro_range = 5.0 })

        fmt.println("Rock has inventory?", ecs.has_component(&world.inventories, rock_eid))
        fmt.println("Player has inventory?", ecs.has_component(&world.inventories, player_eid))
        fmt.println("AI entities:", ecs.table_len(&world.ais))

        update_physics(&world, 0.016)
        update_inventories(&world, &world.inventories)
        update_ai(&world, &world.ais)

        fmt.println()
        fmt.printfln("Player position after tick: %v", world.entities[player_eid.ix].position)
        fmt.printfln("Rock position after tick (untouched): %v", world.entities[rock_eid.ix].position)
}
