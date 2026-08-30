/*
    2026 (c) Zaya, https://github.com/zm69

    RPG inventory example using ODE_BRUTAL_ECS 

    Read more: ../../../docs/fat_struct_vs_ecs.md

    - Three independent ecs.Databases - actors (NPCs, players), item_templates, ability_templates.
    - Description reused as-is across all three databases; item_templates/ability_templates each have their own single-column Table(Description) - create_template is one helper shared by both.
    - An entity belongs to at most one Table, so the actors database has one archetype table per actor shape: player_actors (Description + Inventory + Abilities) and npc_actors (Description + Abilities, no Inventory).
    - Item_Instance/Ability_Instance in the Player's Inventory/Abilities hold a template_id plus per-owner data (count, min_damage/max_damage); print_inventory/print_abilities resolve those ids against the correct database's Description table explicitly - the code makes visible that a template_id only means something in the database it came from.
    - Goblin NPC has Description + Abilities but no Inventory, confirmed via is_in printing false against player_actors.
*/

package ode_ecs_fat_struct_rpg

// Core
    import "core:fmt"

// ODE_BRUTAL_ECS
    import ecs "../../../src"

//
// Shared component
    Description :: struct {
        text: string,
    }

//
// actors-side components: template reference + per-owner instance data
    Item_Instance :: struct {
        template_id: ecs.entity_id, // key into item_templates
        count:       int,
    }

    Inventory :: struct {
        items: [INVENTORY_CAP]Item_Instance,
        count: int, // slots in use
    }

    Ability_Instance :: struct {
        template_id: ecs.entity_id, // key into ability_templates
        min_damage:  f64,
        max_damage:  f64,
    }

    Abilities :: struct {
        list:  [ABILITIES_CAP]Ability_Instance, // could be map instead, but this is a simple example
        count: int,
    }

//
// Config
//

    INVENTORY_CAP  :: 8
    ABILITIES_CAP  :: 4

//
// Helpers
//

    // Shared by both item_templates and ability_templates - same Description
    // type, different database. A Table already knows its own db, so
    // create_entity here needs only the table.
    create_template :: proc(descriptions: ^ecs.Table, text: string) -> ecs.entity_id {
        eid, _ := ecs.create_entity(descriptions, Description{ text = text })
        return eid
    }

    add_item :: proc(inv: ^Inventory, template_id: ecs.entity_id, count: int) {
        inv.items[inv.count] = Item_Instance{ template_id = template_id, count = count }
        inv.count += 1
    }

    add_ability :: proc(abilities: ^Abilities, template_id: ecs.entity_id, min_damage, max_damage: f64) {
        abilities.list[abilities.count] = Ability_Instance{ template_id = template_id, min_damage = min_damage, max_damage = max_damage }
        abilities.count += 1
    }

    // Resolves each Item_Instance's template_id against item_templates's own
    // Description Table - the same template_id would be meaningless looked
    // up in any other database.
    print_inventory :: proc(inv: ^Inventory, item_descriptions: ^ecs.Table) {
        for i in 0..<inv.count {
            item := inv.items[i]
            desc := ecs.get_component(item_descriptions, item.template_id, Description)
            fmt.printfln("  x%d %s", item.count, desc.text)
        }
    }

    print_abilities :: proc(abilities: ^Abilities, ability_descriptions: ^ecs.Table) {
        for i in 0..<abilities.count {
            ab := abilities.list[i]
            desc := ecs.get_component(ability_descriptions, ab.template_id, Description)
            fmt.printfln("  %s (%.1f-%.1f dmg)", desc.text, ab.min_damage, ab.max_damage)
        }
    }

//
// Main
//

    main :: proc() {
        //
        // item_templates database
        //

        item_templates: ecs.Database
        defer ecs.terminate(&item_templates)
        ecs.init(&item_templates, 10)

        item_descriptions: ecs.Table
        ecs.table_init(&item_descriptions, &item_templates, 10, {Description})

        sword         := create_template(&item_descriptions, "Sword - a finely balanced blade.")
        health_potion := create_template(&item_descriptions, "Health Potion - restores a modest amount of health.")

        //
        // ability_templates database
        //

        ability_templates: ecs.Database
        defer ecs.terminate(&ability_templates)
        ecs.init(&ability_templates, 10)

        ability_descriptions: ecs.Table
        ecs.table_init(&ability_descriptions, &ability_templates, 10, {Description})

        fireball   := create_template(&ability_descriptions, "Fireball - hurls a bolt of fire at a single target.")
        frost_bolt := create_template(&ability_descriptions, "Frost Bolt - chills and slows a single target.")
        bite       := create_template(&ability_descriptions, "Bite - a vicious goblin bite.")

        //
        // actors database - players/NPCs
        //

        actors: ecs.Database
        defer ecs.terminate(&actors)
        ecs.init(&actors, 20)

        // One archetype table per actor shape — an entity belongs to
        // exactly one of these.
        player_actors: ecs.Table // Description + Inventory + Abilities
        npc_actors:    ecs.Table // Description + Abilities, no Inventory
        ecs.table_init(&player_actors, &actors, 20, {Description, Inventory, Abilities})
        ecs.table_init(&npc_actors, &actors, 20, {Description, Abilities})

        // Player: Description + Inventory + Abilities, one row.
        player, _ := ecs.create_entity(&player_actors)

        player_desc := ecs.get_component(&player_actors, player, Description)
        player_desc.text = "A lone adventurer."

        player_inv := ecs.get_component(&player_actors, player, Inventory)
        add_item(player_inv, sword, 1)
        add_item(player_inv, health_potion, 3)

        player_abilities := ecs.get_component(&player_actors, player, Abilities)
        add_ability(player_abilities, fireball, 12.0, 18.0)
        add_ability(player_abilities, frost_bolt, 8.0, 14.0)

        // Goblin NPC: Description + Abilities only - no Inventory
        goblin, _ := ecs.create_entity(&npc_actors)

        goblin_desc := ecs.get_component(&npc_actors, goblin, Description)
        goblin_desc.text = "A snarling forest goblin."

        goblin_abilities := ecs.get_component(&npc_actors, goblin, Abilities)
        add_ability(goblin_abilities, bite, 2.0, 5.0)

        //
        // Print
        //

        fmt.println(player_desc.text)
        fmt.println("Inventory:")
        print_inventory(player_inv, &item_descriptions)
        fmt.println("Abilities:")
        print_abilities(player_abilities, &ability_descriptions)

        fmt.println()
        fmt.println(goblin_desc.text)
        fmt.println("Has inventory?", ecs.is_in(&player_actors, goblin))
        fmt.println("Abilities:")
        print_abilities(goblin_abilities, &ability_descriptions)
    }
