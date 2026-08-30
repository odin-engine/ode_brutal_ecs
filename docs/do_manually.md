# You do stuff manually

## Why No Queries

Queries/views add a lot of overhead and change the ECS library in ways that reduce its performance. And I'm not talking only about records/components iteration. I'm talking about everything else (complexity/CPU time/memory) required to keep up queries/views functionality. You can avoid all that if you do stuff manually instead of having the ECS library provide that comfort.

So how do we do it manually? First we need to understand some rules of ODE_BRUTAL_ECS.

### RULE #1: An entity exists only in one Table. In other words, it cannot exist in two or more tables at the same time.

It means all components an entity requires for its existence/functionality should be in that table. ODE_BRUTAL_ECS enforces that rule — you cannot have the same entity_id linked to more than one table. But it doesn't mean you can't have Tables with the same or similar component sets and move entities between them. This is what you should abuse when working with ODE_BRUTAL_ECS.

Imagine we have a `players` table and a `dead_players` table for player entities in a multiplayer game:

```Odin
players: ecs.Table
dead_players: ecs.Table

ecs.table_init(&players, &db, 100, {C1, C2, C3, C4, C5}) // C1, C2, C3, C4, C5 are player components

ecs.table_init(&dead_players, &db, 100, {C1, C2, C3, C4, C5, DeathInfo}) // we added DeathInfo component for info like death time and what caused it
```

Basically, these two tables express different (manually coded) states of players — tags! Now, based on RULE #1, when a player is killed we just move that entity from the `players` table to `dead_players`:

```Odin
    // player_eid = player entity_id
    ecs.move(player_eid, from = &players, to = &dead_players)
```

When an entity is moved to a new table, all components that can be copied will be copied. New zeroed components (in our example, DeathInfo) will be added to the entity if they exist in that table.

What happens if the destination table doesn't contain all the components the source table has? For example, what if the `dead_players` table were defined like this:

```Odin 
    ecs.table_init(&dead_players, &db, 100, {C1, C3, C5, DeathInfo})
```
The `C2` and `C4` components don't exist in the `dead_players` table but do exist in the `players` table. If this happens, `move` refuses: it asserts (under `ECS_VALIDATIONS`, on by default) for a loud dev-time failure, and even in a release build with validations compiled out, it still returns `API_Error.Table_To_Cannot_Contain_Entity` instead of silently corrupting data.

But what if you still want to do it? In that case, use the `sudo_move` proc.

```Odin
    ecs.sudo_move(player_eid, from = &players, to = &dead_players)
```

`sudo_move` will strip the `C2` and `C4` components from the `player_eid` entity, and they will be lost forever.

Similar to the `move` and `sudo_move` procs, ODE_BRUTAL_ECS also has `copy` and `sudo_copy` procs that, you guessed it, create NEW entities with the same component set, if possible — `copy` follows the exact same assert-and-refuse behavior as `move`, and `sudo_copy` is its drop-what-doesn't-fit escape hatch, same as `sudo_move`.

## What about tags?

What if I want to tag entities with different tag sets (states)? There are two approaches to this. I think you've already guessed one: you create a Table for that state and move your entity there when it reaches that state.

In the previous example we had two tables: `players` and `dead_players`. What if we want dead players who were burned by fire, so we can render burned, smoking bodies instead of just regular dead bodies? In that case, you create another table:

```Odin
    ecs.table_init(&burned_players, &db, 100, {C1, C2, C3, C4, C5, DeathInfo})
```

And if `player_eid` was killed by burning with fire, you `move` its entity to the `burned_players` table. Now, during the rendering process, you render `dead_players` as normal bodies and `burned_players` as burned bodies:

```Odin
    // Imagine that we need C1 and C3 for info to render bodies
    render_dead_players :: proc() {

        //
        // Render dead players
        //
        c1_slice := ecs.slice(&dead_players, C1)
        c3_slice := ecs.slice(&dead_players, C3)

        // All slices from the same table always have the same length
        for i in 0..< len(c1_slice) {  
            render_dead_player(&c1_slice[i], &c3_slice[i])
        }

        //
        // Render burned players
        //
        c1_slice = ecs.slice(&burned_players, C1)
        c3_slice = ecs.slice(&burned_players, C3)

        for i in 0..< len(c1_slice) {  
            render_burned_player(&c1_slice[i], &c3_slice[i])
        }
    }
``` 

The second approach is to add info about how the player died into one of the components, like `DeathInfo`. In this case you don't have a `burned_players` table, and the previous code could look like this:

```Odin
    render_dead_players :: proc() {

        c1_slice := ecs.slice(&dead_players, C1)
        c3_slice := ecs.slice(&dead_players, C3)
        death_info_slice := ecs.slice(&dead_players, DeathInfo)

        for i in 0..< len(c1_slice) {  
            if death_info_slice[i].source_of_death == .Fire {
                render_burned_player(&c1_slice[i], &c3_slice[i])
            } else {
                render_dead_player(&c1_slice[i], &c3_slice[i])
            }
        }
    }
``` 

## What if I want to iterate over all C1 and C3 components in the game, regardless of which table they're in? How can I do that?

No luck, dudesses and dudes. I'd do it like this: I'd create a generic iteration proc:

```Odin
    do_something_with_c1_and_c3 :: proc(table: ^Table) {
        c1_slice := ecs.slice(table, C1)
        c3_slice := ecs.slice(table, C3)

        for i in 0..< len(c1_slice) {  
            do_something(&c1_slice[i], c3_slice[i])
        }
    }
```

Then I would call that proc for every single table that contains both C1 and C3:

```Odin
    do_something_with_c1_and_c3(&table1)
    do_something_with_c1_and_c3(&table2)
    //...
    do_something_with_c1_and_c3(&tableN)
```

That's it, very brutal 👊🙂.

## How to add/remove components to an entity?

Same as before — you create a table that has more or fewer components and move your entity to that table.

## Sample
[Sample01](/samples/sample01/main.odin) demonstrates the "do stuff manually" workflow as runnable code.